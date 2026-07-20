//
//  LassoMXLookupCacheTests.swift
//  LassoPerfectSMTPTests
//
//  `LassoMXLookupCache` (§4.4) unit tests, plus `LassoEmailProviderImpl
//  .mxLookup(_:context:)` end-to-end tests rendered through a real
//  `[email_mxlookup(...)]` call. `DNSResolver` is a concrete `struct` with
//  no test seam of its own for MX-record-content-level tests -- exactly
//  the same problem `Perfect-SMTP`'s own `DirectMXTransport` tests solved
//  via the already-public `MXResolving` protocol seam
//  (`Sources/PerfectSMTP/DirectMX/MXResolving.swift`) and its own
//  `FakeMXResolver` fixture
//  (`Perfect-SMTP/Tests/PerfectSMTPTests/DirectMX/FakeMXResolver.swift`).
//  This file's `FakeMXResolver` reuses that exact pattern (a fully scripted
//  `MXResolving` conformer with call-count tracking) rather than inventing
//  a new mocking layer, standing up a real fake DNS server being
//  disproportionate for cache-hit/`-refresh`/error-mapping tests that don't
//  care about wire encoding at all -- exactly Perfect-SMTP's own stated
//  rationale for adding the seam in the first place.
//

import Foundation

import Testing
@testable import LassoParser
@testable import LassoPerfectSMTP
import PerfectSMTP

/// A fully scripted `MXResolving` fake with call-count tracking (needed
/// here specifically to prove cache hits avoid a second resolver call --
/// Perfect-SMTP's own `FakeMXResolver` doesn't need this since its tests
/// aren't about caching). Unregistered domains throw `.noRecordsFound` by
/// default, matching a real resolver's NODATA/NXDOMAIN behavior. An actor
/// (rather than a lock-guarded class) since `resolveMX` is itself async --
/// the simplest async-safe way to track call counts across concurrent
/// callers.
private actor FakeMXResolver: MXResolving {
    private var mxRecordsByDomain: [String: [DNSResolver.MXRecord]]
    private var mxErrorsByDomain: [String: DNSResolver.ResolveError]
    /// An artificial per-call delay (nanoseconds) -- needed only by the
    /// cache-stampede test below, to widen the race window between the
    /// cache-miss check and the resolver call/cache write enough to
    /// reliably prove two concurrent callers for the same uncached domain
    /// share one resolver call rather than issuing two.
    private let delayNanoseconds: UInt64
    private(set) var resolveMXCallCount = 0
    private(set) var resolveMXCallDomains: [String] = []

    init(
        mxRecords: [String: [DNSResolver.MXRecord]] = [:],
        mxErrors: [String: DNSResolver.ResolveError] = [:],
        delayNanoseconds: UInt64 = 0
    ) {
        self.mxRecordsByDomain = mxRecords
        self.mxErrorsByDomain = mxErrors
        self.delayNanoseconds = delayNanoseconds
    }

    func resolveMX(domain: String) async throws -> [DNSResolver.MXRecord] {
        resolveMXCallCount += 1
        resolveMXCallDomains.append(domain)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        // Case-insensitive lookup key -- DNS names are conventionally
        // case-insensitive (RFC 4343), and `LassoMXLookupCache` itself only
        // lowercases its own cache KEY, passing the caller's original
        // casing straight through to `resolver.resolveMX(domain:)` (a real
        // nameserver doesn't care about casing at all) -- this fake must
        // do the same case-insensitive match a real resolver effectively
        // would, or a mixed-casing test would spuriously miss.
        let key = domain.lowercased()
        if let error = mxErrorsByDomain[key] { throw error }
        // Sorted ascending by preference, matching `DNSResolver.resolveMX`'s
        // own documented contract (`MXResolving`'s shared doc comment) --
        // `LassoEmailProviderImpl.mxLookup` deliberately trusts that
        // contract rather than re-sorting, so this fake must actually
        // uphold it for that trust to be validly tested.
        if let records = mxRecordsByDomain[key] { return records.sorted { $0.preference < $1.preference } }
        throw DNSResolver.ResolveError.noRecordsFound
    }

    func resolveAddresses(hostname: String) async throws -> [DNSAddress] {
        throw DNSResolver.ResolveError.noRecordsFound
    }
}

// MARK: - LassoMXLookupCache unit tests

struct LassoMXLookupCacheTests {
    @Test func cacheMissCallsTheResolverAndCachesTheResult() async throws {
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        let cache = LassoMXLookupCache()

        let records = try await cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        #expect(records == [DNSResolver.MXRecord(preference: 10, exchange: "mail.example.com")])
        #expect(await resolver.resolveMXCallCount == 1)
    }

    @Test func cacheHitAvoidsASecondResolverCall() async throws {
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        let cache = LassoMXLookupCache()

        _ = try await cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        _ = try await cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        _ = try await cache.lookup(domain: "example.com", refresh: false, resolver: resolver)

        #expect(await resolver.resolveMXCallCount == 1)
    }

    @Test func refreshBypassesTheCacheAndCallsTheResolverAgain() async throws {
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        let cache = LassoMXLookupCache()

        _ = try await cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        _ = try await cache.lookup(domain: "example.com", refresh: true, resolver: resolver)
        _ = try await cache.lookup(domain: "example.com", refresh: true, resolver: resolver)

        #expect(await resolver.resolveMXCallCount == 3)
    }

    @Test func domainKeysAreNormalizedCaseInsensitively() async throws {
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        let cache = LassoMXLookupCache()

        _ = try await cache.lookup(domain: "Example.COM", refresh: false, resolver: resolver)
        _ = try await cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        _ = try await cache.lookup(domain: "EXAMPLE.COM", refresh: false, resolver: resolver)

        #expect(await resolver.resolveMXCallCount == 1)
    }

    @Test func aFailedLookupIsNotCachedAndPropagates() async throws {
        let resolver = FakeMXResolver(mxErrors: ["broken.example.com": .timeout])
        let cache = LassoMXLookupCache()

        await #expect(throws: DNSResolver.ResolveError.timeout) {
            _ = try await cache.lookup(domain: "broken.example.com", refresh: false, resolver: resolver)
        }
        // A second attempt still calls the resolver again -- nothing was
        // cached from the failed attempt.
        await #expect(throws: DNSResolver.ResolveError.timeout) {
            _ = try await cache.lookup(domain: "broken.example.com", refresh: false, resolver: resolver)
        }
        #expect(await resolver.resolveMXCallCount == 2)
    }

    // MARK: - Size bound (Phase C milestone review BLOCKING FIX #2)

    @Test func cacheEvictsTheOldestEntryOnceAtCapacityRatherThanGrowingUnbounded() async throws {
        // 10_000 is `LassoMXLookupCache`'s documented cap
        // (`maxCachedDomains`). Filling it to capacity with distinct
        // domains, then adding one more, must evict the single
        // oldest-inserted entry (domain0.example.com) -- proven by
        // observing that a subsequent lookup for domain0 has to hit the
        // resolver again (it's no longer cached), while a lookup for the
        // most-recently-inserted domain does NOT (it's still cached).
        var mxRecords: [String: [DNSResolver.MXRecord]] = [:]
        for index in 0..<10_001 {
            mxRecords["domain\(index).example.com"] = [.init(preference: 10, exchange: "mail\(index).example.com")]
        }
        let resolver = FakeMXResolver(mxRecords: mxRecords)
        let cache = LassoMXLookupCache()

        for index in 0..<10_001 {
            _ = try await cache.lookup(domain: "domain\(index).example.com", refresh: false, resolver: resolver)
        }
        let callCountAfterFilling = await resolver.resolveMXCallCount
        #expect(callCountAfterFilling == 10_001)

        // domain0 was evicted to make room for domain10000 -- looking it
        // up again must re-hit the resolver.
        _ = try await cache.lookup(domain: "domain0.example.com", refresh: false, resolver: resolver)
        #expect(await resolver.resolveMXCallCount == callCountAfterFilling + 1)

        // The most recently inserted entry (domain10000) is still cached
        // -- looking it up again must NOT re-hit the resolver.
        _ = try await cache.lookup(domain: "domain10000.example.com", refresh: false, resolver: resolver)
        #expect(await resolver.resolveMXCallCount == callCountAfterFilling + 1)
    }

    @Test func refreshingAnExistingEntryDoesNotEvictAnythingSinceItIsNotGrowingTheDistinctKeyCount() async throws {
        // A `-refresh=true` overwrite of an ALREADY-cached key must not
        // trigger eviction logic at all -- it isn't adding a new distinct
        // key, so treating it as "growth" would incorrectly evict some
        // other still-live entry for no reason.
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        let cache = LassoMXLookupCache()

        _ = try await cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        _ = try await cache.lookup(domain: "example.com", refresh: true, resolver: resolver)
        _ = try await cache.lookup(domain: "example.com", refresh: true, resolver: resolver)

        #expect(await resolver.resolveMXCallCount == 3)
    }

    // MARK: - Cache-stampede protection (Phase C milestone review
    // NON-BLOCKING A)

    @Test func concurrentLookupsForTheSameUncachedDomainShareOneResolverCall() async throws {
        // Reproduces the exact race the review flagged: two concurrent
        // callers for the same uncached domain must not both pass the
        // cache-miss check and issue their own resolver call. An
        // artificial delay on the fake resolver widens the race window
        // enough to make this reliably observable rather than flaky.
        let resolver = FakeMXResolver(
            mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]],
            delayNanoseconds: 200_000_000 // 200ms
        )
        let cache = LassoMXLookupCache()

        async let first = cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        async let second = cache.lookup(domain: "example.com", refresh: false, resolver: resolver)
        async let third = cache.lookup(domain: "example.com", refresh: false, resolver: resolver)

        let results = try await [first, second, third]
        for records in results {
            #expect(records == [DNSResolver.MXRecord(preference: 10, exchange: "mail.example.com")])
        }
        #expect(await resolver.resolveMXCallCount == 1)
    }

    @Test func aFailedInFlightLookupDoesNotPermanentlyBlockFutureAttemptsForTheSameKey() async throws {
        // The in-flight entry must be cleared on failure too (not just
        // success) -- otherwise a transient DNS failure during a
        // concurrent burst would wedge that domain's cache entry forever.
        let resolver = FakeMXResolver(mxErrors: ["broken.example.com": .timeout], delayNanoseconds: 50_000_000)
        let cache = LassoMXLookupCache()

        async let first: [DNSResolver.MXRecord]? = try? await cache.lookup(domain: "broken.example.com", refresh: false, resolver: resolver)
        async let second: [DNSResolver.MXRecord]? = try? await cache.lookup(domain: "broken.example.com", refresh: false, resolver: resolver)
        _ = await (first, second)

        // A subsequent attempt (after both in-flight failures cleared)
        // must still be able to try again, not be wedged.
        await #expect(throws: DNSResolver.ResolveError.timeout) {
            _ = try await cache.lookup(domain: "broken.example.com", refresh: false, resolver: resolver)
        }
    }
}

// MARK: - email_mxlookup end-to-end tests (LassoEmailProviderImpl.mxLookup)

struct LassoEmailMXLookupEndToEndTests {
    private static func makeContext(resolver: any MXResolving, cache: LassoMXLookupCache = LassoMXLookupCache()) throws -> LassoContext {
        struct UnusedTransport: SMTPTransport {
            func send(_ envelope: SMTPEnvelope, _ message: SignedMessage) async throws -> [DeliveryResult] { [] }
        }
        let registry = try LassoSMTPMailerRegistry(
            mailers: ["primary": SMTPMailer(transport: UnusedTransport())],
            defaultRelay: "primary"
        )
        return LassoContext(emailProvider: LassoEmailProviderImpl(
            registry: registry,
            siteRoot: FileManager.default.temporaryDirectory,
            mxResolver: resolver,
            mxLookupCache: cache
        ))
    }

    @Test func happyPathReturnsDomainHostPriorityShapeMatchingTheWorkedExample() async throws {
        // Matches lassoguide.com's own worked example shape exactly:
        // map(domain = gmail.com, host = gmail-smtp-in.l.google.com,
        // priority = 5) -- three keys, not the prose's six.
        let resolver = FakeMXResolver(mxRecords: ["gmail.com": [.init(preference: 5, exchange: "gmail-smtp-in.l.google.com")]])
        var context = try Self.makeContext(resolver: resolver)

        let output = try await LassoRenderer().render(
            "[var(result = email_mxlookup('gmail.com'))][$result->find('domain')]|[$result->find('host')]|[$result->find('priority')]",
            context: &context
        )
        #expect(output == "gmail.com|gmail-smtp-in.l.google.com|5")
    }

    @Test func mostPreferredRecordIsChosenWhenMultipleMXRecordsExist() async throws {
        let resolver = FakeMXResolver(mxRecords: [
            "example.com": [
                .init(preference: 20, exchange: "backup.example.com"),
                .init(preference: 5, exchange: "primary.example.com"),
            ],
        ])
        var context = try Self.makeContext(resolver: resolver)

        let output = try await LassoRenderer().render(
            "[email_mxlookup('example.com')->find('host')]",
            context: &context
        )
        #expect(output == "primary.example.com")
    }

    @Test func repeatedLookupsThroughOneContextHitTheSharedCache() async throws {
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        var context = try Self.makeContext(resolver: resolver)

        _ = try await LassoRenderer().render("[email_mxlookup('example.com')]", context: &context)
        _ = try await LassoRenderer().render("[email_mxlookup('example.com')]", context: &context)

        #expect(await resolver.resolveMXCallCount == 1)
    }

    @Test func refreshFlagForcesABypassOfTheCache() async throws {
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        var context = try Self.makeContext(resolver: resolver)

        _ = try await LassoRenderer().render("[email_mxlookup('example.com')]", context: &context)
        _ = try await LassoRenderer().render("[email_mxlookup: 'example.com', -refresh=true]", context: &context)

        #expect(await resolver.resolveMXCallCount == 2)
    }

    @Test func nullMXConvertsToAClearCatchableErrorNotACrash() async throws {
        let resolver = FakeMXResolver(mxErrors: ["norelay.example.com": .nullMX])
        var context = try Self.makeContext(resolver: resolver)

        let output = try await LassoRenderer().render(
            "[protect][email_mxlookup('norelay.example.com')][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("null MX") || output.contains("does not accept email"))
    }

    @Test func noRecordsFoundConvertsToAClearCatchableErrorNotACrash() async throws {
        let resolver = FakeMXResolver(mxErrors: ["nowhere.example.com": .noRecordsFound])
        var context = try Self.makeContext(resolver: resolver)

        let output = try await LassoRenderer().render(
            "[protect][email_mxlookup('nowhere.example.com')][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("no MX records"))
    }

    @Test func hostnameParameterThrowsNotYetSupportedRatherThanBeingSilentlyIgnored() async throws {
        let resolver = FakeMXResolver(mxRecords: ["example.com": [.init(preference: 10, exchange: "mail.example.com")]])
        var context = try Self.makeContext(resolver: resolver)

        let output = try await LassoRenderer().render(
            "[protect][email_mxlookup: 'example.com', -hostname='ns1.example.com'][/protect]after",
            context: &context
        )
        #expect(output == "after")
        // Never even attempted the lookup — -hostname is checked first.
        #expect(await resolver.resolveMXCallCount == 0)
    }

    @Test func noResolverWiredThrowsAClearCatchableErrorRatherThanCrashing() async throws {
        struct UnusedTransport: SMTPTransport {
            func send(_ envelope: SMTPEnvelope, _ message: SignedMessage) async throws -> [DeliveryResult] { [] }
        }
        let registry = try LassoSMTPMailerRegistry(
            mailers: ["primary": SMTPMailer(transport: UnusedTransport())],
            defaultRelay: "primary"
        )
        // No mxResolver/mxLookupCache passed -- defaults to nil, matching a
        // deployment that wires `email_send` but somehow not MX lookup
        // (not reachable via `main.swift` today, since both share one
        // gate, but this constructor-level path must still fail cleanly,
        // not force-unwrap-crash).
        var context = LassoContext(emailProvider: LassoEmailProviderImpl(registry: registry, siteRoot: FileManager.default.temporaryDirectory))

        let output = try await LassoRenderer().render(
            "[protect][email_mxlookup('example.com')][/protect]after",
            context: &context
        )
        #expect(output == "after")
    }
}

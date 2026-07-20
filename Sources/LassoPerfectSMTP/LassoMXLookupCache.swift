//
//  LassoMXLookupCache.swift
//  LassoPerfectSMTP
//
//  Backs `email_mxlookup`'s documented caching behavior (§4.4):
//  lassoguide.com states real Lasso caches MX lookups per domain — "The
//  first time an MX record is looked up its result is cached and the same
//  information will be returned on subsequent lookups" — with `-refresh`
//  the only documented way to force a fresh lookup. `DNSResolver` itself
//  has no caching at all (a stateless struct that dials a fresh query every
//  call, by its own design) — this actor is the small caching layer that
//  sits in front of it.
//
//  ## Process-lifetime caching — a deliberate, flagged judgment call
//
//  Neither lassoguide.com nor the local Lasso 8.5 Language Guide documents
//  any TTL/expiry for the cached MX result. Process-lifetime caching (never
//  expiring on its own, only ever refreshed via `-refresh`) is the
//  literal, conservative reading of "the same information will be returned
//  on subsequent lookups" — it matches the documented behavior exactly
//  without inventing an unconfirmed expiry policy. This does mean a
//  long-running server process can serve a stale MX record indefinitely
//  after a real DNS change, until either the process restarts or a caller
//  happens to pass `-refresh` — an accepted, explicitly-documented
//  trade-off, not an oversight.
//
//  ## Injected `any MXResolving`, not a concrete `DNSResolver`
//
//  `Sources/PerfectSMTP/DirectMX/MXResolving.swift` already defines exactly
//  the protocol seam this cache needs (`resolveMX(domain:)`,
//  `resolveAddresses(hostname:)`) — added specifically so
//  `DirectMXTransport`'s own tests could inject a fake resolver instead of
//  a real `DNSResolver` (which is a concrete `struct` with no seam of its
//  own). `DNSResolver` already conforms (`extension DNSResolver:
//  MXResolving {}`). Typing `lookup(domain:refresh:resolver:)`'s parameter
//  as `any MXResolving` rather than concretely `DNSResolver` reuses that
//  existing, reviewed seam rather than inventing a second one — real
//  callers (`main.swift`) pass a real `DNSResolver`; this target's own
//  tests pass a `MXResolving`-conforming fake, exactly mirroring
//  `DirectMXTransportTests`' own established pattern
//  (`Tests/PerfectSMTPTests/DirectMX/FakeMXResolver.swift`).
//
//  ## Domain key normalization
//
//  DNS names are conventionally case-insensitive (RFC 4343) — cache keys
//  are lowercased so `email_mxlookup('Example.com')` and
//  `email_mxlookup('example.com')` share one cache entry rather than
//  silently double-querying/double-caching for what a real caller would
//  consider the same domain.
//
//  ## Size bound — Phase C milestone review BLOCKING FIX #2
//
//  `email_mxlookup`'s domain argument comes straight from Lasso call
//  arguments (plausibly request-derived, e.g. a user-submitted email
//  address's domain) — with no cap, an attacker driving many distinct
//  domain strings through repeated calls could grow `cachedRecords`
//  unboundedly, a real memory-exhaustion vector (the same class of gap
//  this project already hardened `LassoSMTPAttachmentLoader` against with
//  an explicit count ceiling, not just a byte ceiling). `maxCachedDomains`
//  (10,000) is a generous, documented cap: real legitimate usage queries a
//  bounded set of actual recipient-domain MX records, so 10,000 distinct
//  domains comfortably exceeds any real workload while still bounding
//  worst-case memory. Eviction strategy, chosen for simplicity over
//  cleverness: once at the cap, a NEW domain evicts the single
//  oldest-inserted entry (tracked via `insertionOrder`, a plain array of
//  keys in insertion order) to make room — simpler than an LRU, and
//  sufficient here since this is a defensive ceiling, not a
//  performance-tuned production cache.
//
//  ## Cache-stampede protection — Phase C milestone review NON-BLOCKING A
//
//  The naive "check cache, await resolver, write cache" pattern lets two
//  concurrent callers for the same uncached domain both pass the
//  cache-miss check before either writes, causing duplicate resolver calls
//  (not a correctness bug, just redundant work under a real, plausible
//  race window — e.g. a busy site emailing several messages to gmail.com
//  concurrently). `inFlightLookups` tracks one `Task` per key currently
//  being resolved; a concurrent caller for the same key awaits that
//  existing `Task` instead of issuing a second resolver call. The
//  in-flight entry is cleared once the task completes, success or failure,
//  so a failed lookup doesn't leave a stale in-flight entry blocking
//  future attempts.
//

import PerfectSMTP

/// Process-lifetime, domain-keyed cache of `MXResolving.resolveMX(domain:)`
/// results — see the file doc comment for the full design/rationale.
public actor LassoMXLookupCache {
    /// Maximum distinct domain keys retained at once — see the file doc
    /// comment's "Size bound" section for the reasoning behind this exact
    /// number and the eviction strategy.
    private static let maxCachedDomains = 10_000

    private var cachedRecords: [String: [DNSResolver.MXRecord]] = [:]
    /// Insertion order of `cachedRecords`' keys, oldest first — the sole
    /// bookkeeping needed for the "evict the oldest entry" strategy. Kept
    /// in lockstep with `cachedRecords`: a key is appended here exactly
    /// when it's first added to `cachedRecords`, and removed from both
    /// together on eviction.
    private var insertionOrder: [String] = []
    /// One in-flight resolver `Task` per key currently being looked up —
    /// see the file doc comment's "Cache-stampede protection" section.
    private var inFlightLookups: [String: Task<[DNSResolver.MXRecord], Error>] = [:]

    public init() {}

    /// - Parameters:
    ///   - domain: Looked up case-insensitively (normalized internally) —
    ///     see the file doc comment.
    ///   - refresh: `true` forces a fresh `resolver.resolveMX(domain:)`
    ///     call and overwrites any cached entry, matching `-refresh`'s
    ///     documented "force a fresh lookup" contract. `false` (the
    ///     default absent `-refresh`) returns the cached entry if one
    ///     exists, only calling the resolver on a genuine cache miss.
    ///   - resolver: Anything conforming to `MXResolving` — a real
    ///     `DNSResolver` in production, a fake in tests. See the file doc
    ///     comment for why this is the injected type rather than a
    ///     concrete `DNSResolver`.
    public func lookup(domain: String, refresh: Bool, resolver: any MXResolving) async throws -> [DNSResolver.MXRecord] {
        let key = domain.lowercased()
        if refresh == false, let cached = cachedRecords[key] {
            return cached
        }
        // A concurrent lookup for this exact key is already in flight —
        // await its result rather than issuing a second resolver call.
        // `-refresh` still joins the same in-flight task rather than
        // starting a redundant second one; the very next call (once this
        // one completes and clears the in-flight entry) will see the
        // freshly-cached result.
        if let existing = inFlightLookups[key] {
            return try await existing.value
        }
        let task = Task<[DNSResolver.MXRecord], Error> {
            try await resolver.resolveMX(domain: domain)
        }
        inFlightLookups[key] = task
        defer { inFlightLookups[key] = nil }
        let records = try await task.value
        store(records, for: key)
        return records
    }

    /// Inserts a freshly-resolved record set, evicting the single
    /// oldest-inserted entry first if this is a NEW key that would push
    /// the cache over `maxCachedDomains`. Overwriting an EXISTING key (the
    /// `-refresh=true` path) never evicts — it's not growing the cache's
    /// distinct-key count.
    private func store(_ records: [DNSResolver.MXRecord], for key: String) {
        if cachedRecords[key] == nil {
            if cachedRecords.count >= Self.maxCachedDomains, insertionOrder.isEmpty == false {
                let oldest = insertionOrder.removeFirst()
                cachedRecords[oldest] = nil
            }
            insertionOrder.append(key)
        }
        cachedRecords[key] = records
    }
}

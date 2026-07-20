//
//  LassoEmailJobTrackerTests.swift
//  LassoPerfectSMTPTests
//
//  Direct, non-Lasso-rendering unit tests of `LassoEmailJobTracker` itself
//  (Phase E, §4.7/§4.7b) — the eviction policy (TTL expiry, hard-cap
//  eviction) actually bounds the store, matching this project's own
//  established discipline (`LassoMXLookupCacheTests.swift` tests
//  `LassoMXLookupCache` the same direct way, separately from any
//  Lasso-rendering end-to-end coverage). `email_result`/`email_status`'s
//  own end-to-end behavior through real `[email_send]`/`[email_result]`/
//  `[email_status]` calls is covered by
//  `LassoEmailResultStatusEndToEndTests.swift`.
//

import Foundation

import Testing
@testable import LassoPerfectSMTP

struct LassoEmailJobTrackerTests {
    @Test func recordQueuedReturnsAFreshUUIDStyleIDEachTimeNeverSequential() async throws {
        let tracker = LassoEmailJobTracker()
        let first = await tracker.recordQueued()
        let second = await tracker.recordQueued()

        #expect(first != second)
        // A CSPRNG-backed UUID, not a sequential/incrementing scheme (§4.7's
        // explicit instruction) -- confirm the returned string actually
        // parses as a UUID rather than e.g. "1"/"2".
        #expect(UUID(uuidString: first) != nil)
        #expect(UUID(uuidString: second) != nil)
    }

    @Test func statusOfAnUnknownIDIsNil() async throws {
        let tracker = LassoEmailJobTracker()
        #expect(await tracker.status(of: "does-not-exist") == nil)
    }

    @Test func recordQueuedThenUpdateTransitionsStateCorrectly() async throws {
        let tracker = LassoEmailJobTracker()
        let id = await tracker.recordQueued()
        #expect(await tracker.status(of: id) == .queued)

        await tracker.update(id, to: .sent)
        #expect(await tracker.status(of: id) == .sent)

        await tracker.update(id, to: .error("boom"))
        #expect(await tracker.status(of: id) == .error("boom"))
    }

    @Test func updatingAnUnknownIDIsSilentlyIgnoredNotACrash() async throws {
        let tracker = LassoEmailJobTracker()
        // No corresponding recordQueued() call -- must not trap/crash, and
        // must not spuriously create an entry either.
        await tracker.update("bogus", to: .sent)
        #expect(await tracker.status(of: "bogus") == nil)
        #expect(await tracker.jobCount == 0)
    }

    // MARK: - Eviction: hard entry-count cap (§4.7b)

    @Test func hardCapEvictsTheOldestEntriesFirstOnceOverTheLimit() async throws {
        let tracker = LassoEmailJobTracker()
        var ids: [String] = []
        // `recordQueued()` always enforces the REAL default cap (10,000)
        // inline, which isn't practical to exercise directly in a unit test
        // (inserting 10,001 real entries). `sweepExpiredJobs(maxEntries:)`
        // shares the exact same eviction algorithm (`enforceHardCap`,
        // `LassoEmailJobTracker.swift`'s own doc comment) -- passing a
        // small `maxEntries` here exercises that identical algorithm
        // deterministically and quickly.
        for _ in 0..<5 {
            let id = await tracker.recordQueued()
            ids.append(id)
        }
        #expect(await tracker.jobCount == 5)

        // Force the cap down to 3 via an explicit sweep call -- the oldest
        // two (ids[0], ids[1]) must be the ones evicted, never the most
        // recently-inserted ones.
        let evicted = await tracker.sweepExpiredJobs(ttl: 999_999, maxEntries: 3)
        #expect(evicted == 2)
        #expect(await tracker.jobCount == 3)
        #expect(await tracker.status(of: ids[0]) == nil)
        #expect(await tracker.status(of: ids[1]) == nil)
        #expect(await tracker.status(of: ids[2]) != nil)
        #expect(await tracker.status(of: ids[3]) != nil)
        #expect(await tracker.status(of: ids[4]) != nil)
    }

    @Test func hardCapPrefersEvictingByLastUpdatedNotByInsertionOrderAlone() async throws {
        let tracker = LassoEmailJobTracker()
        let first = await tracker.recordQueued()
        let second = await tracker.recordQueued()
        let third = await tracker.recordQueued()

        // Touch `first` (the oldest by insertion) most recently -- it must
        // NOT be the one evicted, since eviction orders by `lastUpdated`,
        // not raw insertion order.
        await tracker.update(first, to: .sent)

        let evicted = await tracker.sweepExpiredJobs(ttl: 999_999, maxEntries: 2)
        #expect(evicted == 1)
        #expect(await tracker.status(of: first) == .sent)
        #expect(await tracker.status(of: second) == nil)
        #expect(await tracker.status(of: third) != nil)
    }

    // MARK: - Eviction: TTL expiry (§4.7b)

    @Test func ttlExpiryRemovesEntriesOlderThanTheGivenTTLButKeepsRecentOnes() async throws {
        let tracker = LassoEmailJobTracker()
        let stale = await tracker.recordQueued()
        try await Task.sleep(for: .milliseconds(60))
        let fresh = await tracker.recordQueued()

        // A TTL shorter than the real sleep above but longer than the
        // second insert's own age -- `stale` should expire, `fresh` should
        // not.
        let evicted = await tracker.sweepExpiredJobs(ttl: 0.03, maxEntries: LassoEmailJobTracker.defaultMaxEntries)
        #expect(evicted == 1)
        #expect(await tracker.status(of: stale) == nil)
        #expect(await tracker.status(of: fresh) != nil)
    }

    @Test func ttlExpiryIsMeasuredFromLastUpdatedNotFromCreation() async throws {
        let tracker = LassoEmailJobTracker()
        let id = await tracker.recordQueued()
        try await Task.sleep(for: .milliseconds(60))
        // Touching the entry resets its own `lastUpdated` -- a sweep with a
        // TTL shorter than the elapsed time since CREATION, but longer than
        // the time since this update, must not expire it.
        await tracker.update(id, to: .sent)

        let evicted = await tracker.sweepExpiredJobs(ttl: 0.03, maxEntries: LassoEmailJobTracker.defaultMaxEntries)
        #expect(evicted == 0)
        #expect(await tracker.status(of: id) == .sent)
    }

    @Test func sweepAppliesBothTTLAndHardCapTogether() async throws {
        let tracker = LassoEmailJobTracker()
        let stale = await tracker.recordQueued()
        try await Task.sleep(for: .milliseconds(60))
        var recent: [String] = []
        for _ in 0..<4 {
            recent.append(await tracker.recordQueued())
        }

        // TTL first evicts `stale`; the hard cap (3) then evicts one more
        // from what's left (the oldest of the four `recent` entries).
        let evicted = await tracker.sweepExpiredJobs(ttl: 0.03, maxEntries: 3)
        #expect(evicted == 2)
        #expect(await tracker.jobCount == 3)
        #expect(await tracker.status(of: stale) == nil)
        #expect(await tracker.status(of: recent[0]) == nil)
        #expect(await tracker.status(of: recent[1]) != nil)
        #expect(await tracker.status(of: recent[2]) != nil)
        #expect(await tracker.status(of: recent[3]) != nil)
    }
}

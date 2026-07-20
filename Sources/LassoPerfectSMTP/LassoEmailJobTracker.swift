//
//  LassoEmailJobTracker.swift
//  LassoPerfectSMTP
//
//  The backing store for `email_result`/`email_status` (Phase E, §4.7/
//  §4.7b) — a plain in-memory `[jobID: state]` map, matching
//  `DirectMXRetryQueue`'s/`MTASTSPolicyManager`'s own documented
//  in-memory-only scope boundary in Perfect-SMTP (no cross-restart
//  persistence, stated explicitly here rather than left implicit).
//
//  ## Job ID scheme
//
//  `Foundation.UUID()` — CSPRNG-backed, 122 bits of entropy — per §4.7's
//  explicit instruction that this must NOT be a sequential/incrementing
//  scheme (so a future "optimization" doesn't quietly weaken it: a
//  sequential ID would let one caller guess/enumerate another's job IDs,
//  which is a a real information-disclosure concern for any status endpoint
//  keyed by a bare string with no other authentication).
//
//  ## Eviction — bounded from the start (Phase E milestone review discipline,
//  §4.7b), not deferred
//
//  Every prior unbounded-growth gap in this project (`LassoMXLookupCache` in
//  Phase C is the concrete precedent) was found by review AFTER the fact,
//  not designed in from the start. This actor ships two independent bounds
//  from day one:
//  - **TTL (24 hours, `defaultTTL`)** — matches lassoguide.com's own loose
//    framing of `email_status` as something that "would be checked sometime
//    later," long enough that no plausible real caller polls past it, short
//    enough that a long-running server process doesn't accumulate entries
//    from every send it's ever attempted.
//  - **Hard entry-count cap (10,000, `defaultMaxEntries`)**, as a defensive
//    backstop for whatever a TTL sweep hasn't caught up with yet (e.g. a
//    burst of sends between sweep intervals) — evicts the OLDEST entries by
//    `lastUpdated`, not insertion order, so an entry that was just updated
//    (e.g. a `-date`-scheduled send that only just completed) is never the
//    one evicted ahead of a truly stale one.
//
//  Both bounds are enforced from TWO call sites: `recordQueued()` enforces
//  the hard cap immediately on every insert (so growth is bounded even if
//  no external sweep ever runs), and `sweepExpiredJobs(ttl:maxEntries:)`
//  additionally applies the TTL — intended to be called periodically by an
//  external `Task`, mirroring `LassoSMTPConnectionRegistry.sweepIdleConnections`'s
//  own established "the periodic Task lives in the caller, the resource
//  type just exposes a sweep method" convention (see that file's own doc
//  comment) — `main.swift`'s `smtp` wiring block owns the
//  `while !Task.isCancelled { ...; try? await Task.sleep(...) }` loop and
//  the cancellable `Task` handle, wired into `LassoAdminDelegate`'s restart
//  action alongside `smtpConnectionReaperTask`/`cwpJanitorTask` (Phase E,
//  §4.7b answer to open question #2).
//
//  ## Per-send background `Task`s are NOT individually tracked for restart
//  cancellation — a deliberate, explicitly-documented scope decision
//
//  §4.7b's third open question asks whether a per-send deferred/scheduled-
//  send `Task` needs its own cancellation tracking (e.g. a `Task`-group-like
//  collection inside this actor) or whether only this tracker's OWN
//  periodic eviction-sweep `Task` needs the singleton cancellable-on-restart
//  treatment. This implementation chooses the latter: `LassoEmailProviderImpl.send`
//  spawns one plain, untracked `Task` per deferred/scheduled send (see that
//  file's own doc comment). These are NOT registered anywhere for explicit
//  cancellation on "Restart Server." This is safe and deliberate, not an
//  oversight, for three reasons: (1) each one is short-lived and
//  self-terminating (it runs to completion — success or failure — and
//  updates this tracker, then its Task naturally completes and is released;
//  there is no unbounded loop the way `DirectMXRetryQueue`'s own
//  previously-fixed leak involved), (2) the actual admin "Restart Server"
//  action (`AdminConsoleIntegration.swift`) already forcibly `exit(0)`s the
//  old process after at most a 10-second drain window regardless of what
//  else is still running, so any in-flight deferred send simply terminates
//  along with the rest of the process at that point — there is no separate
//  leak to plug beyond what already happens to every other in-flight
//  request, and (3) the alternative (a tracked, cancellable set of per-send
//  Tasks) would need its own unbounded collection with its own eviction
//  story once a Task completes -- solving exactly the kind of "bounded
//  growth" problem this file's eviction policy already exists to prevent,
//  just for a second, redundant collection. Only this tracker's periodic
//  sweep Task is a genuine indefinite-loop leak risk (the same class of bug
//  `smtpConnectionReaperTask`'s own restart-cancellation wiring exists to
//  prevent) — that is the one this phase tracks and cancels.
//

import Foundation

/// One job's outcome, keyed by the job ID `recordQueued()` returns.
/// `email_status(id)` (`LassoEmailProviderImpl.status`) maps every case to
/// exactly one of the three real, lowercase strings lassoguide.com
/// documents ("sent"/"queued"/"error") — `.error`'s associated
/// human-readable description is carried here for potential future richer
/// diagnostics/logging, but `email_status` itself only ever reports the
/// bare string "error" regardless of what it says.
public enum LassoEmailJobState: Sendable, Equatable {
    case queued
    case sent
    case error(String)
}

public actor LassoEmailJobTracker {
    /// See the file doc comment's "Eviction" section for the reasoning
    /// behind these two exact numbers.
    public static let defaultTTL: TimeInterval = 86_400
    public static let defaultMaxEntries = 10_000

    private struct Entry {
        var state: LassoEmailJobState
        var lastUpdated: Date
        /// Deterministic tie-breaker for eviction ordering — see
        /// `enforceHardCap()`'s doc comment for why `lastUpdated` alone
        /// isn't sufficient (empirically confirmed flaky: two entries
        /// recorded back-to-back with no delay can land in the same
        /// `Date()` tick, making `sorted(by:)`'s tie order depend on
        /// `Dictionary`'s unspecified iteration order). Assigned from
        /// `nextSequence` at both creation and every `update(_:to:)` call,
        /// so it tracks the exact same "most recently touched" semantics
        /// `lastUpdated` is meant to, just with guaranteed strict ordering.
        var sequence: UInt64
    }

    private var jobs: [String: Entry] = [:]
    /// Monotonically increasing, process-lifetime counter — purely an
    /// internal tie-breaker for eviction ordering, never exposed as or
    /// confused with the public job ID (which must stay CSPRNG-backed per
    /// §4.7's explicit "not sequential" instruction; this counter is never
    /// returned to a caller, so it doesn't reintroduce that risk).
    private var nextSequence: UInt64 = 0

    public init() {}

    private func advanceSequence() -> UInt64 {
        nextSequence += 1
        return nextSequence
    }

    /// Called once a real send has genuinely been attempted (relay
    /// resolved, `SMTPMailer.send`/the background-dispatch equivalent about
    /// to be invoked) — never for a pre-send validation failure (§4.7b's
    /// job-ID scoping rule; enforced by `LassoEmailProviderImpl.send`, not
    /// here). Generates a fresh CSPRNG-backed `UUID` (see the file doc
    /// comment's "Job ID scheme" section), records it `.queued`, and
    /// immediately enforces the hard entry-count cap so growth is bounded
    /// even between periodic `sweepExpiredJobs` calls.
    public func recordQueued() -> String {
        let id = UUID().uuidString
        jobs[id] = Entry(state: .queued, lastUpdated: Date(), sequence: advanceSequence())
        enforceHardCap()
        return id
    }

    /// Deferred-send-only variant of `recordQueued()` (Phase E milestone
    /// review, BLOCKING FIX #1) — atomically checks the current number of
    /// `.queued` entries against `cap` and refuses (returns `nil`,
    /// recording nothing at all) rather than inserting over the limit.
    /// `LassoEmailProviderImpl.send`'s deferred branch (`-immediate=false`/
    /// `-date`) calls this instead of `recordQueued()`; the synchronous
    /// path keeps calling `recordQueued()` unconditionally and is never
    /// subject to this cap.
    ///
    /// Deliberately a single actor-isolated check-and-insert, not a
    /// separate `queuedCount()` read followed by the caller's own
    /// `recordQueued()` call — two concurrent deferred `email_send` calls
    /// both reading "under cap" before either has inserted would race past
    /// the limit (classic check-then-act TOCTOU), exactly the class of bug
    /// this actor's single-method-call boundary already prevents for every
    /// other operation here.
    ///
    /// "Number of `.queued` entries" is a clean, already-available proxy
    /// for "number of currently in-flight deferred sends": every deferred
    /// job starts `.queued` and only transitions to `.sent`/`.error` once
    /// its background `Task` completes, while synchronous-path jobs
    /// transition out of `.queued` within the same `send(_:context:)` call
    /// that recorded them (before `send` even returns) — so they never
    /// meaningfully count here, with no separate semaphore/counter
    /// mechanism needed.
    public func recordQueuedIfUnderCap(_ cap: Int) -> String? {
        let queuedCount = jobs.values.reduce(into: 0) { count, entry in
            if case .queued = entry.state { count += 1 }
        }
        guard queuedCount < cap else { return nil }
        let id = UUID().uuidString
        jobs[id] = Entry(state: .queued, lastUpdated: Date(), sequence: advanceSequence())
        enforceHardCap()
        return id
    }

    /// Called once a deferred/synchronous send attempt resolves — updates
    /// an existing job's state and its `lastUpdated` timestamp (which both
    /// `sweepExpiredJobs`' TTL check and the hard-cap eviction's "oldest by
    /// `lastUpdated`" ordering key off of). A `jobID` this tracker has never
    /// seen (or has already evicted) is silently ignored — there is no
    /// caller-visible failure mode for "the job this update was meant for
    /// is already gone," since eviction is this tracker's own documented,
    /// accepted behavior, not a caller error.
    public func update(_ jobID: String, to state: LassoEmailJobState) {
        guard jobs[jobID] != nil else { return }
        jobs[jobID] = Entry(state: state, lastUpdated: Date(), sequence: advanceSequence())
    }

    /// `nil` means an unrecognized (or already-evicted) job ID — callers
    /// turn that into a clear, catchable "unknown job" error rather than
    /// guessing at one of the three real status strings.
    public func status(of jobID: String) -> LassoEmailJobState? {
        jobs[jobID]?.state
    }

    /// Test/introspection-only: how many jobs this tracker currently holds
    /// — used by the eviction regression tests to confirm bounds actually
    /// apply without reaching into otherwise-private state (mirrors
    /// `LassoSMTPConnectionRegistry.openConnectionCount`'s identical
    /// precedent).
    public var jobCount: Int {
        jobs.count
    }

    /// Intended to be called periodically by an external `Task` (see the
    /// file doc comment) — removes every entry older than `ttl` seconds
    /// (measured from `lastUpdated`, not creation time, so a job that's
    /// still being actively updated never expires out from under a caller
    /// still polling it), then applies the hard entry-count cap on top,
    /// evicting oldest-by-`lastUpdated` first. Returns the number of
    /// entries actually removed (surfaced for logging/tests, mirroring
    /// `LassoSMTPConnectionRegistry.sweepIdleConnections`'s own return-value
    /// convention).
    @discardableResult
    public func sweepExpiredJobs(
        ttl: TimeInterval = LassoEmailJobTracker.defaultTTL,
        maxEntries: Int = LassoEmailJobTracker.defaultMaxEntries
    ) -> Int {
        let before = jobs.count
        let now = Date()
        jobs = jobs.filter { now.timeIntervalSince($0.value.lastUpdated) < ttl }
        enforceHardCap(maxEntries: maxEntries)
        return before - jobs.count
    }

    /// Shared by `recordQueued()` (so growth is bounded even between
    /// periodic sweeps) and `sweepExpiredJobs` (so the hard cap still
    /// applies even when a TTL sweep alone hasn't brought the count down
    /// enough — e.g. a burst of very recent, not-yet-expired entries past
    /// the cap).
    ///
    /// Sorts by `(lastUpdated, sequence)`, not `lastUpdated` alone —
    /// empirically confirmed necessary: entries recorded back-to-back with
    /// no delay can land in the same `Date()` tick (reproduced directly,
    /// not a hypothetical), and `Dictionary`'s iteration order is
    /// unspecified, so a `lastUpdated`-only sort has no deterministic
    /// tie-break and can evict either of two "tied" entries depending on
    /// incidental iteration order. `sequence` (a private, monotonically
    /// increasing counter, never exposed as or confused with the public
    /// CSPRNG job ID) guarantees a strict order matching each entry's real
    /// creation/last-touch order even when their timestamps coincide.
    private func enforceHardCap(maxEntries: Int = LassoEmailJobTracker.defaultMaxEntries) {
        guard jobs.count > maxEntries else { return }
        let overflow = jobs.count - maxEntries
        let oldestFirst = jobs.sorted {
            $0.value.lastUpdated != $1.value.lastUpdated
                ? $0.value.lastUpdated < $1.value.lastUpdated
                : $0.value.sequence < $1.value.sequence
        }
        for (key, _) in oldestFirst.prefix(overflow) {
            jobs.removeValue(forKey: key)
        }
    }
}

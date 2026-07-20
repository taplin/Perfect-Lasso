//
//  LassoPerfectSMTPEndToEndTests.swift
//  LassoPerfectSMTPTests
//
//  Renders a real `[email_send: ...]` call (Lasso 8's bare colon-call form,
//  matching `LassoParserTests.swift`'s existing corpus-shaped precedent)
//  through a `LassoContext` wired with a real `LassoEmailProviderImpl`,
//  backed by `LassoSMTPMailerRegistry`'s test-only initializer and a
//  fake `SMTPTransport` conformer -- no real network access anywhere in
//  this file. Confirms:
//  - a successful send evaluates to `.void` (empty rendered output);
//  - a delivery failure (a fake transport returning a
//    `.permanentlyFailed` `DeliveryResult`) surfaces as a
//    `[protect]`-catchable error, not an uncaught crash;
//  - Phase E (§4.7/§4.7b): `-immediate=false`/`-date` now perform REAL
//    deferred sending -- a job is recorded `"queued"` and the call returns
//    immediately, with a background `Task` performing the actual send and
//    transitioning the job to `"sent"`/`"error"` once it completes; a
//    malformed `-date` is still a pre-send validation failure (no job
//    recorded), and the background Task genuinely outlives (and survives
//    the cancellation of) the request that spawned it;
//  - `-host` naming an unconfigured relay throws a clear error;
//  - `-host` naming a configured relay actually routes to that relay
//    (verified by which fake transport recorded the call);
//  - Phase B: a real `-attachments` path entry round-trips end to end
//    (dash-params -> resolved file bytes -> the fake transport's recorded
//    `SignedMessage`), and a path escaping `siteRoot` is a
//    `[protect]`-catchable failure, not a crash.
//

import Foundation

import Testing
@testable import LassoParser
@testable import LassoPerfectSMTP
import PerfectSMTP

/// Lock-protected, not just `@unchecked Sendable` on faith: Phase F's
/// `-tokens`/`-merge` batch-send path (`SMTPMailer.send(_ messages:
/// envelopeFrom:)`) fans a batch out across several concurrent child
/// `Task`s (its own bounded-concurrency task-group), each of which calls
/// this recorder's `record(_:_:)` independently — every test before Phase F
/// only ever sent one message at a time, so a lock was never load-bearing
/// until now.
private final class SendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sendCount = 0
    private var _lastEnvelope: SMTPEnvelope?
    private var _lastMessage: SignedMessage?
    /// Every call this recorder has seen, in completion order — needed by
    /// Phase F's batch-send tests to inspect EACH recipient's own
    /// personalized message, not just the last one.
    private var _messages: [(envelope: SMTPEnvelope, message: SignedMessage)] = []

    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return _sendCount }
    var lastEnvelope: SMTPEnvelope? { lock.lock(); defer { lock.unlock() }; return _lastEnvelope }
    var lastMessage: SignedMessage? { lock.lock(); defer { lock.unlock() }; return _lastMessage }
    var messages: [(envelope: SMTPEnvelope, message: SignedMessage)] {
        lock.lock(); defer { lock.unlock() }; return _messages
    }

    func record(_ envelope: SMTPEnvelope, _ message: SignedMessage) {
        lock.lock()
        defer { lock.unlock() }
        _sendCount += 1
        _lastEnvelope = envelope
        _lastMessage = message
        _messages.append((envelope, message))
    }
}

/// Lets a test hold open a fake send in flight until it explicitly
/// `release()`s it — used by the Phase E (§4.7/§4.7b) deferred-send tests
/// below to observe a job's `"queued"` state deterministically (rather than
/// racing the background `Task` that performs the real send) before letting
/// it complete and observing the transition to `"sent"`/`"error"`.
private actor DelayGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

private struct FakeSMTPTransport: SMTPTransport {
    enum Behavior {
        case succeed
        case permanentlyFail
        case throwTransportError
        /// Phase F (§4.9c): fails ONLY the named recipient (a
        /// `.permanentlyFailed` outcome), succeeds every other recipient —
        /// needed to exercise `-tokens`/`-merge`'s aggregate job-status
        /// check (job resolves to `.error` if ANY one recipient's clone
        /// fails, `.sent` only if every recipient succeeds) with a batch
        /// send that's a realistic mix of outcomes, not all-fail/all-succeed.
        case failForRecipient(String)
    }
    struct SimulatedTransportFailure: Error, Sendable {}

    let behavior: Behavior
    let recorder: SendRecorder
    /// `nil` (every pre-Phase-E test) means "resolve immediately" — Phase
    /// E's deferred-send tests pass a real `DelayGate` so the test can
    /// deterministically observe a job's `"queued"` state before releasing
    /// it and observing the transition to `"sent"`/`"error"`.
    var gate: DelayGate? = nil

    func send(_ envelope: SMTPEnvelope, _ message: SignedMessage) async throws -> [DeliveryResult] {
        if let gate { await gate.wait() }
        recorder.record(envelope, message)
        switch behavior {
        case .succeed:
            return envelope.recipients.map {
                DeliveryResult(recipient: $0, outcome: .delivered(SMTPReply(code: 250, lines: ["OK"])))
            }
        case .permanentlyFail:
            return envelope.recipients.map {
                DeliveryResult(recipient: $0, outcome: .permanentlyFailed(SMTPReply(code: 550, lines: ["Mailbox not found"])))
            }
        case .throwTransportError:
            throw SimulatedTransportFailure()
        case .failForRecipient(let target):
            return envelope.recipients.map { recipient in
                recipient == target
                    ? DeliveryResult(recipient: recipient, outcome: .permanentlyFailed(SMTPReply(code: 550, lines: ["Mailbox not found"])))
                    : DeliveryResult(recipient: recipient, outcome: .delivered(SMTPReply(code: 250, lines: ["OK"])))
            }
        }
    }
}

struct LassoPerfectSMTPEndToEndTests {
    private static func makeContext(
        primaryBehavior: FakeSMTPTransport.Behavior = .succeed,
        primaryRecorder: SendRecorder = SendRecorder(),
        marketingRecorder: SendRecorder = SendRecorder(),
        siteRoot: URL = FileManager.default.temporaryDirectory,
        primaryGate: DelayGate? = nil,
        jobTracker: LassoEmailJobTracker = LassoEmailJobTracker(),
        // BLOCKING FIX #1 (Phase E milestone review, concurrency pass):
        // defaults to the real production default
        // (`LassoEmailProviderImpl.defaultMaxConcurrentDeferredSends`) --
        // only the cap-enforcement test below overrides this with a small
        // number, so it can exercise the rejection path without spawning
        // 1,000 real deferred sends.
        maxConcurrentDeferredSends: Int = LassoEmailProviderImpl.defaultMaxConcurrentDeferredSends,
        // Phase F (§4.9a/§4.9b): `nil` (every pre-Phase-F test) means no
        // DKIM signing and no direct-mx entry -- both new, purely additive
        // parameters, matching this helper's existing "every new knob
        // defaults to the pre-existing behavior" convention.
        signer: (any MessageSigner)? = nil,
        directMX: SMTPMailer? = nil
    ) throws -> LassoContext {
        let primaryMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: primaryBehavior, recorder: primaryRecorder, gate: primaryGate), signer: signer)
        let marketingMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: .succeed, recorder: marketingRecorder), signer: signer)
        let registry = try LassoSMTPMailerRegistry(
            mailers: ["primary": primaryMailer, "marketing": marketingMailer],
            defaultRelay: "primary",
            directMX: directMX
        )
        return LassoContext(emailProvider: LassoEmailProviderImpl(
            registry: registry,
            siteRoot: siteRoot,
            maxConcurrentDeferredSends: maxConcurrentDeferredSends,
            jobTracker: jobTracker
        ))
    }

    /// GMT-formatted `-date` string in one of `LassoDateParsing`'s
    /// recognized formats (`"yyyy-MM-dd H:mm:ss"`) — `LassoDateComponents`'
    /// own model is whole-seconds only (no sub-second field), so a
    /// meaningfully "in the future" `-date` needs at least a 1-2 second
    /// offset, not truly sub-second, for its parsed due-`Date` to actually
    /// land in the future by the time it's compared against "now".
    private static func dateString(secondsFromNow: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd H:mm:ss"
        return formatter.string(from: Date().addingTimeInterval(secondsFromNow))
    }

    /// Fresh, real, uniquely-named temp directory standing in for
    /// `siteRoot` — Phase B's attachment tests need a real filesystem, not
    /// a fake, since `LassoSMTPAttachmentLoader` does real containment
    /// checks/`open`/`fstat`/`read` against it.
    private static func makeSiteRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-smtp-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func successfulSendEvaluatesToVoidAndRoutesThroughTheDefaultRelay() async throws {
        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder)

        let output = try await LassoRenderer().render(
            "before-[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']-after",
            context: &context
        )

        #expect(output == "before--after") // .void's outputString is ""
        #expect(primaryRecorder.sendCount == 1)
        #expect(primaryRecorder.lastEnvelope?.recipients == ["a@example.com"])
    }

    @Test func deliveryFailureSurfacesAsACatchableProtectErrorNotACrash() async throws {
        var context = try Self.makeContext(primaryBehavior: .permanentlyFail)

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b'][/protect]after-[error_currenterror]",
            context: &context
        )

        #expect(output.hasPrefix("after-"))
        #expect(output.contains("delivery failed"))
    }

    @Test func transportLevelThrowSurfacesAsACatchableProtectErrorNotACrash() async throws {
        var context = try Self.makeContext(primaryBehavior: .throwTransportError)

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b'][/protect]after",
            context: &context
        )

        #expect(output == "after")
    }

    @Test func uncaughtDeliveryFailurePropagatesAsLassoRecoverableError() async throws {
        var context = try Self.makeContext(primaryBehavior: .permanentlyFail)

        await #expect(throws: LassoRecoverableError.self) {
            try await LassoRenderer().render(
                "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']",
                context: &context
            )
        }
    }

    // MARK: - Phase E: `-immediate=false`/`-date` real deferred sending (§4.7/§4.7b)

    @Test func immediateFalseReturnsImmediatelyAsQueuedThenTransitionsToSentOnceTheBackgroundSendCompletes() async throws {
        let gate = DelayGate()
        let recorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        var context = try Self.makeContext(primaryRecorder: recorder, primaryGate: gate, jobTracker: tracker)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -immediate=false]",
            context: &context
        )

        // Returns immediately with `.void` (empty output) -- the fake
        // transport is still blocked on `gate`, proving this genuinely
        // didn't wait for the real send.
        #expect(output == "")
        #expect(recorder.sendCount == 0)
        let jobID = try #require(context.lastEmailJobID)
        let statusWhileBlocked = await tracker.status(of: jobID)
        #expect(statusWhileBlocked == .queued)

        await gate.release()
        // Poll with a short delay, matching this project's established
        // async-completion test convention (`LassoEmailSMTPEndToEndTests`'
        // idle-reaper test does the same).
        var finalStatus: LassoEmailJobState?
        for _ in 0..<20 {
            finalStatus = await tracker.status(of: jobID)
            if finalStatus == .sent { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finalStatus == .sent)
        #expect(recorder.sendCount == 1)
    }

    @Test func immediateFalseJobTransitionsToErrorWhenTheBackgroundSendFails() async throws {
        let gate = DelayGate()
        let tracker = LassoEmailJobTracker()
        var context = try Self.makeContext(primaryBehavior: .permanentlyFail, primaryGate: gate, jobTracker: tracker)

        _ = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -immediate=false]",
            context: &context
        )
        let jobID = try #require(context.lastEmailJobID)
        await gate.release()

        var finalStatus: LassoEmailJobState?
        for _ in 0..<20 {
            finalStatus = await tracker.status(of: jobID)
            if case .error = finalStatus { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .error = finalStatus else {
            Issue.record("expected job \(jobID) to end in .error, got \(String(describing: finalStatus))")
            return
        }
    }

    @Test func dateInThePastSendsImmediately() async throws {
        let recorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        var context = try Self.makeContext(primaryRecorder: recorder, jobTracker: tracker)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -date='2020-01-01 00:00:00']",
            context: &context
        )
        #expect(output == "")
        let jobID = try #require(context.lastEmailJobID)

        // A due-date already in the past means the background Task's own
        // "sleep until due" step is skipped entirely (no negative-duration
        // sleep) -- poll briefly rather than asserting synchronously, since
        // the send still happens on a background Task, not inline.
        var finalStatus: LassoEmailJobState?
        for _ in 0..<20 {
            finalStatus = await tracker.status(of: jobID)
            if finalStatus == .sent { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finalStatus == .sent)
        #expect(recorder.sendCount == 1)
    }

    @Test func dateInTheFutureGenuinelyWaitsWithQueuedObservableDuringTheWaitWindow() async throws {
        let recorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        var context = try Self.makeContext(primaryRecorder: recorder, jobTracker: tracker)

        let futureDate = Self.dateString(secondsFromNow: 1.5)
        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -date='\(futureDate)']",
            context: &context
        )
        #expect(output == "")
        let jobID = try #require(context.lastEmailJobID)

        // Immediately after the call returns, the due time hasn't arrived
        // yet -- the background Task should still be sleeping, so the fake
        // transport must not have been invoked and the job must still read
        // "queued".
        #expect(recorder.sendCount == 0)
        #expect(await tracker.status(of: jobID) == .queued)

        var finalStatus: LassoEmailJobState?
        for _ in 0..<100 {
            finalStatus = await tracker.status(of: jobID)
            if finalStatus == .sent { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(finalStatus == .sent)
        #expect(recorder.sendCount == 1)
    }

    @Test func malformedDateThrowsAClearPreSendValidationErrorWithNoJobRecorded() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -date='not a real date'][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("-date"))
        // Pre-send validation failure -- §4.7b's scoping rule -- no job
        // should ever have been recorded.
        #expect(context.lastEmailJobID == nil)
    }

    // MARK: - Phase E milestone review: BLOCKING FIX #1 (concurrency cap on deferred sends)

    @Test func deferredSendIsRejectedOnceTheConcurrencyCapIsReachedButSynchronousSendsAreUnaffected() async throws {
        let gate = DelayGate()
        let recorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        // A small, injectable cap (3) rather than the real production
        // default (1,000) -- exercises the exact same enforcement path
        // (`LassoEmailJobTracker.recordQueuedIfUnderCap`) deterministically
        // and quickly, matching this project's established
        // `LassoEmailJobTrackerTests.swift` precedent of passing a small
        // `maxEntries` to exercise `enforceHardCap`'s identical algorithm.
        var context = try Self.makeContext(primaryRecorder: recorder, primaryGate: gate, jobTracker: tracker, maxConcurrentDeferredSends: 3)

        // Fill the cap with deferred sends that never resolve (the fake
        // transport blocks on `gate`, which this test never releases) --
        // each one must still succeed in being recorded as `.queued`.
        for i in 0..<3 {
            let output = try await LassoRenderer().render(
                "[email_send: -to='a@example.com', -from='b@example.com', -subject='s\(i)', -body='b', -immediate=false]",
                context: &context
            )
            #expect(output == "")
            #expect(context.lastEmailJobID != nil)
        }
        #expect(await tracker.jobCount == 3)

        // The next deferred send, still over the cap, must be rejected
        // BEFORE a job is recorded and BEFORE any Task is spawned -- a
        // clear, catchable pre-send validation error, not a crash and not
        // a silently-accepted job.
        let rejectedOutput = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='overflow', -body='b', -immediate=false][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(rejectedOutput.hasPrefix("after-"))
        #expect(rejectedOutput.contains("too many deferred"))
        #expect(await tracker.jobCount == 3)

        // A burst of ordinary SYNCHRONOUS sends (no `-immediate=false`/
        // `-date`) must never hit this cap at all -- they resolve to
        // `.sent`/`.error` before `send` even returns, so they never
        // linger `.queued` long enough to count against it.
        let syncRecorder = SendRecorder()
        var syncContext = try Self.makeContext(primaryRecorder: syncRecorder, jobTracker: tracker, maxConcurrentDeferredSends: 3)
        for i in 0..<5 {
            let output = try await LassoRenderer().render(
                "[email_send: -to='a@example.com', -from='b@example.com', -subject='sync\(i)', -body='b']",
                context: &syncContext
            )
            #expect(output == "")
        }
        #expect(syncRecorder.sendCount == 5)
    }

    // MARK: - Phase E milestone review: BLOCKING FIX #2 (max future `-date` window)

    @Test func dateFurtherInTheFutureThanTheMaximumScheduleWindowIsRejectedWithNoJobRecorded() async throws {
        var context = try Self.makeContext()

        // The real default window is 30 days -- 40 days out is comfortably
        // past it, and this is a pure pre-send validation check (no actual
        // waiting is ever involved), so this resolves immediately.
        let farFutureDate = Self.dateString(secondsFromNow: 40 * 24 * 60 * 60)
        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -date='\(farFutureDate)'][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("-date"))
        #expect(output.contains("future"))
        // Pre-send validation failure -- no job should ever have been
        // recorded.
        #expect(context.lastEmailJobID == nil)
    }

    // MARK: - Cheap non-blocking fix A: the two untested immediate/date routing combinations

    @Test func explicitImmediateTrueWithNoDateSendsSynchronouslyJustLikeTheDefault() async throws {
        let recorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: recorder)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -immediate=true]",
            context: &context
        )

        // Synchronous -- the fake transport (no gate here) has already run
        // by the time `render` returns.
        #expect(output == "")
        #expect(recorder.sendCount == 1)
        #expect(context.lastEmailJobID != nil)
    }

    @Test func dateCombinedWithExplicitImmediateTrueStillDefersSinceDatesPresenceOverrides() async throws {
        let recorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        // No `DelayGate` here -- matches `dateInTheFutureGenuinelyWaitsWithQueuedObservableDuringTheWaitWindow`'s
        // own pattern above: the deferred Task's real "sleep until due"
        // step is itself what proves the wait happened, so a gate would
        // only add an extra, unnecessary block to remember to release.
        var context = try Self.makeContext(primaryRecorder: recorder, jobTracker: tracker)

        let futureDate = Self.dateString(secondsFromNow: 1.5)
        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -date='\(futureDate)', -immediate=true]",
            context: &context
        )
        #expect(output == "")
        let jobID = try #require(context.lastEmailJobID)

        // `-date`'s presence overrides `-immediate=true` -- this must still
        // defer (still `.queued`, transport not yet invoked) despite the
        // explicit `-immediate=true`.
        #expect(recorder.sendCount == 0)
        #expect(await tracker.status(of: jobID) == .queued)

        var finalStatus: LassoEmailJobState?
        for _ in 0..<100 {
            finalStatus = await tracker.status(of: jobID)
            if finalStatus == .sent { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(finalStatus == .sent)
        #expect(recorder.sendCount == 1)
    }

    /// The Phase E critical requirement (§4.7b open question #3): the
    /// background `Task` a deferred/scheduled send spawns must be
    /// genuinely detached from the request that created it, not implicitly
    /// cancelled when that request's own async context completes (or is
    /// even explicitly cancelled, the strictest version of "not scoped to
    /// it"). Wraps the triggering `render` call in its own `Task`, awaits
    /// and then CANCELS that task (simulating the originating request
    /// fully finishing/being torn down), and confirms the deferred send
    /// still genuinely completes afterward.
    @Test func backgroundTaskSurvivesPastTheTriggeringRequestsOwnCompletionAndCancellation() async throws {
        let gate = DelayGate()
        let recorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        let initialContext = try Self.makeContext(primaryRecorder: recorder, primaryGate: gate, jobTracker: tracker)

        // `LassoRenderer().render(_:context:)` takes `context` as `inout`,
        // which can't be captured by reference into an escaping `Task {}`
        // closure -- a fresh local copy is made INSIDE the closure instead
        // (captured by value; `LassoContext` is `Sendable`), and the
        // mutated copy travels back out via the Task's own result.
        let requestTask = Task<(String, LassoContext), Error> {
            var localContext = initialContext
            let output = try await LassoRenderer().render(
                "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -immediate=false]",
                context: &localContext
            )
            return (output, localContext)
        }
        let (output, context) = try await requestTask.value
        #expect(output == "")
        // The "triggering request" is now fully finished -- go one step
        // further and explicitly cancel its Task too, simulating a dropped
        // connection/torn-down request context.
        requestTask.cancel()

        let jobID = try #require(context.lastEmailJobID)
        #expect(await tracker.status(of: jobID) == .queued)

        await gate.release()
        var finalStatus: LassoEmailJobState?
        for _ in 0..<20 {
            finalStatus = await tracker.status(of: jobID)
            if finalStatus == .sent { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finalStatus == .sent)
        #expect(recorder.sendCount == 1)
    }

    @Test func hostNamingAnUnconfiguredRelayThrowsAClearCatchableError() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -host='doesnotexist'][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("doesnotexist"))
    }

    @Test func hostNamingAConfiguredRelayActuallyRoutesThroughThatRelay() async throws {
        let primaryRecorder = SendRecorder()
        let marketingRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder, marketingRecorder: marketingRecorder)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -host='marketing']",
            context: &context
        )

        #expect(output == "")
        #expect(marketingRecorder.sendCount == 1)
        #expect(primaryRecorder.sendCount == 0)
    }

    // MARK: - Phase B: -attachments end to end (§4.5)

    @Test func attachmentsPathEntryRoundTripsEndToEndIntoTheComposedMessage() async throws {
        let siteRoot = try Self.makeSiteRoot()
        try Data("hello attachment".utf8).write(to: siteRoot.appendingPathComponent("report.txt"))

        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder, siteRoot: siteRoot)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='hi', -attachments=array('report.txt')]",
            context: &context
        )

        #expect(output == "")
        #expect(primaryRecorder.sendCount == 1)
        let rfc5322 = String(decoding: primaryRecorder.lastMessage?.rfc5322 ?? [], as: UTF8.self)
        #expect(rfc5322.contains("report.txt"))
        #expect(rfc5322.contains(Data("hello attachment".utf8).base64EncodedString()))
    }

    @Test func attachmentPathEscapingSiteRootIsACatchableFailureNotACrash() async throws {
        let siteRoot = try Self.makeSiteRoot()
        var context = try Self.makeContext(siteRoot: siteRoot)

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='hi', -attachments=array('../../../../../../etc/passwd')][/protect]after",
            context: &context
        )
        #expect(output == "after")
    }

    // MARK: - Phase F (§4.9a): DKIM signing

    /// A real 2048-bit RSA private key, reused verbatim from Perfect-SMTP's
    /// own `SMTPMailerDKIMIntegrationTests.swift` (`rsa2048PEM`) — a real,
    /// already-reviewed test vector, not a fresh one generated here.
    private static let rsa2048PEM = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEAwYYqnvIW69nFbGXs/1MlUxvZ6omQwRUQG4vXQvOsScGMPXXR
    ZiYhxblhM3IB+qJ1/x21yT0h0NaFSWMPE2uKxlG8+PPlYEdo7J0RdzX6zPP9AEz9
    eJGl0qEo2hIdHI/rXe5ROXFeG4c/cl4i3I1nDWlcS/g+A6dGtWbtCONlYnGXE5wS
    B6oVuJxOvKMlC0x1HuxQxeJ1K8gHfLg4LT4At4eNI8tuNMDPCLUbqmKvrmOO0SDO
    FD26mxiVoRHQxVX+Fm8xi4f2j2x1H2/rY+dpr8chepCCXGnqHA1GqYuq5zhgfx+o
    SGQgk1UJibN+ffvFxfXeVJIcrLaWYUe81XJg6wIDAQABAoIBAHKB6pIl+L4RGynq
    nXLuRbWJU0XdpBM7XU6PTg3FlPoHVe2/2ukwQud1qzf/i4A7xMnxUHEEhQ/G/xLP
    VEpPZcu27bP4zI5Ncp4eygjZnc7Lx7X32DsRIycgSMXP1f3igogPzWvJ0r9DJZ2M
    aeBKouFiqEQjXL5YqhQIFNUfiAvY1vvzz/xxV7bUQo1S7gmLKI6LGqbNiFTHo/sK
    RiRjO2G6/8G6R4pzOkE2rf1/gqckI/wVBCdaSeTym/tTw3/oFEgdA2qhwPisPhPv
    0BI30eJDtAhBuhUgXhVr5RZVYF84DcZPGQZq/l6mEvclDGJR6WisaAFqnq7fu0P0
    Pq2lB8ECgYEA4Gh+XDXngVVspP3LKg6p0udqW6C5IbjN0RUIHfhQhH6Lu3zrTFpX
    VZqd+aYciKD9HPxov+7YSMUjCFaDsJjqg75TRZuHbLVJkONhdiaOO0PU7588wNHm
    pwh/vneV5w6bqtiJCxOfH3FzH2CC5G5RQ2FBLBixZqoc5hQQLMKkqBsCgYEA3MSi
    BYNgSvL/VGN0EyVYuHdqBnSUFLRmdj0hvGR6JGaShoh7K8Oaz4a4v06jf9PUCdA5
    JJpBnZ+IFwQTyoMkbesleIQcFVRg0tTVU7PxEng2+Beg5qnNPuRuIYz7HvVn5xuu
    5kN2+wWEyz5oVhguJg7zg2p7RNWS+v7AsFEZV3ECgYEAofgJq/hkHZ9QiU19A+AN
    huHsjDHXLZW7R7uMXkVJqDfGFw60rilOe8TbXMMeOScpSXCNEmsLxIo1HOGEr0PP
    kEMgy07UUgwPCvpy79ooMnJlEIa4TNuzRMAHo6ugkGKkzIz5bPs+kG1MEEuSbdmJ
    4b4iUfeIo3cI4K9+dTAPtB0CgYBQeBvWhpyCtS/8QoP8tpAwLNaoo7WWFmuCjaXO
    VZFv0zN1dinvOc0j96c/lBpkbYHMUemCPffMzGl+ei38kvCkYCG4W+8glzDzqEBZ
    0iz83nSq2XH8ocf+NKUv9YNTNYA57Q1DQTQNK2XL72N4fjfUB38bV6S24mJAurrh
    ia4DAQKBgQDOmIn9iyXgGFMbldehPMU9RGKyJCMG47lBIaG9lg63SNLByJTdcn96
    6kNXD9cRbEEz86ebdtmC/4knKOSyN6ymPv7z5UPVvN8ezpNQiQ0ixS5AkTL3yYKv
    Qjb87l8lMbWyR5WKYbWVpsTPiEmw7iU4GptR5DXAbhzOBWY5VEo0WQ==
    -----END RSA PRIVATE KEY-----
    """

    /// A real RFC 8463 test-vector Ed25519 seed (base64 of the raw 32-byte
    /// seed), reused verbatim from Perfect-SMTP's own
    /// `DKIMRealVectorTests.swift` (`ed25519SeedBase64`) — matches this
    /// implementation's own documented ed25519 DKIM key file format
    /// (`SMTPDKIMSettings`'s doc comment, `main.swift`).
    private static let ed25519SeedBase64 = "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="

    @Test func dkimSignerConfiguredOnARelayProducesASignedMessageWithADKIMSignatureHeader() async throws {
        let signer = try DKIMSigner(
            domain: "example.com",
            selector: "s1",
            signedHeaders: [],
            keys: [try SigningKey.rsa(pem: Self.rsa2048PEM)]
        )
        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder, signer: signer)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']",
            context: &context
        )

        #expect(output == "")
        let rfc5322 = String(decoding: primaryRecorder.lastMessage?.rfc5322 ?? [], as: UTF8.self)
        #expect(rfc5322.hasPrefix("DKIM-Signature: v=1; a=rsa-sha256;"))
        #expect(rfc5322.contains("d=example.com"))
        #expect(rfc5322.contains("s=s1"))
    }

    @Test func noDKIMSignerConfiguredSendsCompletelyUnsignedExactlyAsBeforePhaseF() async throws {
        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder)

        _ = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']",
            context: &context
        )

        let rfc5322 = String(decoding: primaryRecorder.lastMessage?.rfc5322 ?? [], as: UTF8.self)
        #expect(rfc5322.contains("DKIM-Signature") == false)
    }

    @Test func ed25519DKIMKeyLoadingPathAlsoProducesASignedMessageWithADKIMSignatureHeader() async throws {
        // Decodes the same way `LassoSiteServer.makeDKIMSigner(_:)`
        // (`main.swift`, `LassoPerfectServer` target) does for
        // `keyType == "ed25519"` -- UTF-8 base64 text -> raw 32-byte seed
        // -> `SigningKey.ed25519(rawRepresentation:)`. That function
        // itself lives in a different target this one doesn't depend on
        // (`LassoPerfectServer`; see `LassoPerfectServerTests.swift` for
        // its own direct coverage of `resolveSMTPDKIM`/`makeDKIMSigner`) --
        // this test instead proves the RESULTING signer, once wired into a
        // real mailer, produces a genuinely signed send exactly like the
        // rsa path above.
        guard let rawKey = Data(base64Encoded: Self.ed25519SeedBase64) else {
            Issue.record("test vector's own base64 seed failed to decode")
            return
        }
        let signer = try DKIMSigner(
            domain: "example.com",
            selector: "s1",
            signedHeaders: [],
            keys: [try SigningKey.ed25519(rawRepresentation: rawKey)]
        )

        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder, signer: signer)

        _ = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']",
            context: &context
        )

        let rfc5322 = String(decoding: primaryRecorder.lastMessage?.rfc5322 ?? [], as: UTF8.self)
        #expect(rfc5322.contains("DKIM-Signature: v=1; a=ed25519-sha256;"))
        #expect(rfc5322.contains("d=example.com"))
        #expect(rfc5322.contains("s=s1"))
    }

    // MARK: - Phase F (§4.9b): direct-MX relay selection

    @Test func hostDirectMXSelectsTheDirectMXMailerWhenConfigured() async throws {
        let directMXRecorder = SendRecorder()
        let directMXMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: .succeed, recorder: directMXRecorder))
        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder, directMX: directMXMailer)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -host='direct-mx']",
            context: &context
        )

        #expect(output == "")
        #expect(directMXRecorder.sendCount == 1)
        #expect(primaryRecorder.sendCount == 0)
    }

    @Test func hostDirectMXThrowsUnknownRelayWhenDirectMXIsNotConfigured() async throws {
        // `directMX` defaults to `nil` -- matching every other unconfigured-
        // relay case (§4.9b: absence of the flag means the name simply
        // isn't registered, no special-casing).
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -host='direct-mx'][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("direct-mx"))
    }

    @Test func registryConstructionThrowsOnAReservedRelayNameCollisionBetweenRelaysAndDirectMX() throws {
        let mailerA = SMTPMailer(transport: FakeSMTPTransport(behavior: .succeed, recorder: SendRecorder()))
        let mailerB = SMTPMailer(transport: FakeSMTPTransport(behavior: .succeed, recorder: SendRecorder()))

        #expect(throws: LassoSMTPRelayError.reservedRelayNameCollision("direct-mx")) {
            _ = try LassoSMTPMailerRegistry(mailers: ["direct-mx": mailerA], defaultRelay: "direct-mx", directMX: mailerB)
        }
    }

    // MARK: - Phase F (§4.9c): `-tokens`/`-merge` mail-merge templating

    @Test func tokensAndMergeProduceOnePersonalizedMessagePerRecipientInASingleBatchSend() async throws {
        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder)

        let output = try await LassoRenderer().render(
            """
            [email_send: \
            -to='john@example.com, jane@example.com', \
            -from='b@example.com', \
            -subject='Hello #FirstName#', \
            -body='Dear #FirstName#, your code is #Code#.', \
            -tokens=map('Code'='DEFAULT-CODE'), \
            -merge=map(\
            'john@example.com'=map('FirstName'='John', 'Code'='J123'), \
            'jane@example.com'=map('FirstName'='Jane', 'Code'='J456')\
            )\
            ]
            """,
            context: &context
        )

        #expect(output == "")
        // One batch call, not two sequential single-message sends -- see
        // `SMTPMailer.send(_:envelopeFrom:)`'s own doc comment; `sendCount`
        // here counts underlying transport calls, one per personalized
        // clone, which is the correct, documented shape for the batch API.
        #expect(primaryRecorder.sendCount == 2)

        let messages = primaryRecorder.messages
        let john = try #require(messages.first { $0.envelope.recipients == ["john@example.com"] })
        let jane = try #require(messages.first { $0.envelope.recipients == ["jane@example.com"] })
        let johnText = String(decoding: john.message.rfc5322, as: UTF8.self)
        let janeText = String(decoding: jane.message.rfc5322, as: UTF8.self)

        #expect(johnText.contains("Hello John"))
        #expect(johnText.contains("Dear John, your code is J123."))
        #expect(janeText.contains("Hello Jane"))
        #expect(janeText.contains("Dear Jane, your code is J456."))
        // Each recipient's own personalized content is genuinely distinct
        // -- not a shared/last-write-wins message.
        #expect(johnText != janeText)
    }

    @Test func mergeOverridesTheSameNamedTokenFromTokensForThatRecipientOnly() async throws {
        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder)

        let output = try await LassoRenderer().render(
            """
            [email_send: \
            -to='john@example.com, jane@example.com', \
            -from='b@example.com', \
            -subject='s', \
            -body='Dear #FirstName#,', \
            -tokens=map('FirstName'='Lasso User'), \
            -merge=map('john@example.com'=map('FirstName'='John'))\
            ]
            """,
            context: &context
        )

        #expect(output == "")
        let messages = primaryRecorder.messages
        let john = try #require(messages.first { $0.envelope.recipients == ["john@example.com"] })
        let jane = try #require(messages.first { $0.envelope.recipients == ["jane@example.com"] })
        // John has a `-merge` override -> "John" wins over -tokens' default.
        #expect(String(decoding: john.message.rfc5322, as: UTF8.self).contains("Dear John,"))
        // Jane has no `-merge` entry at all -> falls back to -tokens' default.
        #expect(String(decoding: jane.message.rfc5322, as: UTF8.self).contains("Dear Lasso User,"))
    }

    @Test func anUnmatchedTokenMarkerIsLeftVerbatimNotDeletedOrThrown() async throws {
        let primaryRecorder = SendRecorder()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder)

        let output = try await LassoRenderer().render(
            """
            [email_send: \
            -to='john@example.com', \
            -from='b@example.com', \
            -subject='s', \
            -body='Dear #FirstName#, your #NeverResolved# marker stays.', \
            -tokens=map('FirstName'='John')\
            ]
            """,
            context: &context
        )

        #expect(output == "")
        let rfc5322 = String(decoding: primaryRecorder.lastMessage?.rfc5322 ?? [], as: UTF8.self)
        #expect(rfc5322.contains("Dear John,"))
        #expect(rfc5322.contains("#NeverResolved#"))
    }

    @Test func ccTogetherWithTokensThrowsACatchablePreSendValidationError() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            """
            [protect]\
            [email_send: -to='a@example.com', -cc='c@example.com', -from='b@example.com', -subject='s', -body='b', \
            -tokens=map('FirstName'='X')]\
            [/protect]after-[error_currenterror]
            """,
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("-cc/-bcc"))
    }

    @Test func bccTogetherWithMergeThrowsACatchablePreSendValidationError() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            """
            [protect]\
            [email_send: -to='a@example.com', -bcc='d@example.com', -from='b@example.com', -subject='s', -body='b', \
            -merge=map('a@example.com'=map('FirstName'='X'))]\
            [/protect]after-[error_currenterror]
            """,
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("-cc/-bcc"))
    }

    @Test func aggregateJobStatusIsSentOnlyWhenEveryRecipientsCloneSucceeds() async throws {
        let primaryRecorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder, jobTracker: tracker)

        _ = try await LassoRenderer().render(
            """
            [email_send: -to='john@example.com, jane@example.com', -from='b@example.com', -subject='s', -body='Dear #FirstName#,', \
            -tokens=map('FirstName'='X'), \
            -merge=map('john@example.com'=map('FirstName'='John'), 'jane@example.com'=map('FirstName'='Jane'))]
            """,
            context: &context
        )
        let jobID = try #require(context.lastEmailJobID)
        #expect(await tracker.status(of: jobID) == .sent)
    }

    @Test func aggregateJobStatusIsErrorWhenAnyOneRecipientsCloneFails() async throws {
        let primaryRecorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        let primaryMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: .failForRecipient("jane@example.com"), recorder: primaryRecorder))
        let registry = try LassoSMTPMailerRegistry(mailers: ["primary": primaryMailer], defaultRelay: "primary")
        var context = LassoContext(emailProvider: LassoEmailProviderImpl(
            registry: registry,
            siteRoot: FileManager.default.temporaryDirectory,
            jobTracker: tracker
        ))

        let output = try await LassoRenderer().render(
            """
            [protect]\
            [email_send: -to='john@example.com, jane@example.com', -from='b@example.com', -subject='s', -body='Dear #FirstName#,', \
            -tokens=map('FirstName'='X'), \
            -merge=map('john@example.com'=map('FirstName'='John'), 'jane@example.com'=map('FirstName'='Jane'))]\
            [/protect]after-[error_currenterror]
            """,
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        let jobID = try #require(context.lastEmailJobID)
        guard case .error = await tracker.status(of: jobID) else {
            Issue.record("expected job \(jobID) to end in .error, got \(String(describing: await tracker.status(of: jobID)))")
            return
        }
    }

    @Test func deferredImmediateFalseWithMergeStillCompletesTheBatchSendInTheBackgroundAndUpdatesTheOneJobID() async throws {
        let gate = DelayGate()
        let primaryRecorder = SendRecorder()
        let tracker = LassoEmailJobTracker()
        var context = try Self.makeContext(primaryRecorder: primaryRecorder, primaryGate: gate, jobTracker: tracker)

        let output = try await LassoRenderer().render(
            """
            [email_send: -to='john@example.com, jane@example.com', -from='b@example.com', -subject='s', -body='Dear #FirstName#,', \
            -tokens=map('FirstName'='X'), \
            -merge=map('john@example.com'=map('FirstName'='John'), 'jane@example.com'=map('FirstName'='Jane')), \
            -immediate=false]
            """,
            context: &context
        )

        // Returns immediately, still blocked on `gate` -- proves the batch
        // send genuinely didn't happen synchronously.
        #expect(output == "")
        #expect(primaryRecorder.sendCount == 0)
        let jobID = try #require(context.lastEmailJobID)
        #expect(await tracker.status(of: jobID) == .queued)

        await gate.release()
        var finalStatus: LassoEmailJobState?
        for _ in 0..<20 {
            finalStatus = await tracker.status(of: jobID)
            if finalStatus == .sent { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finalStatus == .sent)
        // Both personalized clones actually sent, in one background batch
        // send, updating the SAME one job ID.
        #expect(primaryRecorder.sendCount == 2)
        #expect(Set(primaryRecorder.messages.flatMap(\.envelope.recipients)) == ["john@example.com", "jane@example.com"])
    }
}

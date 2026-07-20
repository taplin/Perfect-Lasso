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

private final class SendRecorder: @unchecked Sendable {
    private(set) var sendCount = 0
    private(set) var lastEnvelope: SMTPEnvelope?
    private(set) var lastMessage: SignedMessage?
    func record(_ envelope: SMTPEnvelope, _ message: SignedMessage) {
        sendCount += 1
        lastEnvelope = envelope
        lastMessage = message
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
        maxConcurrentDeferredSends: Int = LassoEmailProviderImpl.defaultMaxConcurrentDeferredSends
    ) throws -> LassoContext {
        let primaryMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: primaryBehavior, recorder: primaryRecorder, gate: primaryGate))
        let marketingMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: .succeed, recorder: marketingRecorder))
        let registry = try LassoSMTPMailerRegistry(
            mailers: ["primary": primaryMailer, "marketing": marketingMailer],
            defaultRelay: "primary"
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
}

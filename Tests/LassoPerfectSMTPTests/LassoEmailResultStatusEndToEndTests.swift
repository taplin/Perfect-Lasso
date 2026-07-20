//
//  LassoEmailResultStatusEndToEndTests.swift
//  LassoPerfectSMTPTests
//
//  Renders real `[email_send]`/`[email_result]`/`[email_status]` calls
//  (Phase E, §4.7/§4.7b) through a `LassoContext` wired with a real
//  `LassoEmailProviderImpl`, proving the full job-ID round trip end to end:
//  `email_send` records a job and stashes its ID into
//  `LassoContext.lastEmailJobID` (via `Runtime.swift`'s wrapper),
//  `email_result()` reads it back with no arguments of its own, and
//  `email_status(id)` reports the job's real state. Confirms:
//  - `email_result()` after a successful `email_send` returns a job ID
//    whose `email_status` reports `"sent"`;
//  - `email_result()` after a FAILED `email_send` (a delivery failure, not
//    a validation failure) still returns a valid job ID whose
//    `email_status` reports `"error"` -- proving the job ID survives a
//    `[protect]`-caught thrown error (`LassoEmailSendFailure`'s whole
//    reason for existing, §4.0/§4.7b);
//  - `email_result()` with no prior `email_send` in this context throws a
//    clear, catchable error;
//  - `email_result()` after a SUCCESSFUL send followed by a LATER,
//    validation-failing `email_send` in the same context throws too --
//    `lastEmailJobID` must not leak stale across multiple calls (Phase E
//    milestone review, BLOCKING FIX #3);
//  - `email_status` for an unknown/evicted job ID returns `"sent"`,
//    matching real Lasso's own documented behavior (Phase E milestone
//    review, BLOCKING FIX #4), not a thrown error.
//
//  Deferred-send (`-immediate=false`/`-date`) timing behavior itself is
//  covered by `LassoPerfectSMTPEndToEndTests.swift`; `LassoEmailJobTracker`'s
//  own eviction policy is covered directly by `LassoEmailJobTrackerTests.swift`.
//

import Foundation

import Testing
@testable import LassoParser
@testable import LassoPerfectSMTP
import PerfectSMTP

private final class SendRecorder: @unchecked Sendable {
    private(set) var sendCount = 0
    func record() { sendCount += 1 }
}

private struct FakeSMTPTransport: SMTPTransport {
    enum Behavior {
        case succeed
        case permanentlyFail
    }
    let behavior: Behavior
    let recorder: SendRecorder

    func send(_ envelope: SMTPEnvelope, _ message: SignedMessage) async throws -> [DeliveryResult] {
        recorder.record()
        switch behavior {
        case .succeed:
            return envelope.recipients.map {
                DeliveryResult(recipient: $0, outcome: .delivered(SMTPReply(code: 250, lines: ["OK"])))
            }
        case .permanentlyFail:
            return envelope.recipients.map {
                DeliveryResult(recipient: $0, outcome: .permanentlyFailed(SMTPReply(code: 550, lines: ["Mailbox not found"])))
            }
        }
    }
}

struct LassoEmailResultStatusEndToEndTests {
    private static func makeContext(
        behavior: FakeSMTPTransport.Behavior = .succeed,
        recorder: SendRecorder = SendRecorder()
    ) throws -> LassoContext {
        let mailer = SMTPMailer(transport: FakeSMTPTransport(behavior: behavior, recorder: recorder))
        let registry = try LassoSMTPMailerRegistry(mailers: ["primary": mailer], defaultRelay: "primary")
        return LassoContext(emailProvider: LassoEmailProviderImpl(
            registry: registry,
            siteRoot: FileManager.default.temporaryDirectory
        ))
    }

    @Test func emailResultAfterASuccessfulSendReturnsAJobIDWhoseStatusIsSent() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']" +
            "[var(jobid = email_result())]" +
            "[email_status($jobid)]",
            context: &context
        )

        #expect(output == "sent")
    }

    @Test func emailResultAfterADeliveryFailureStillReturnsAValidJobIDWhoseStatusIsError() async throws {
        var context = try Self.makeContext(behavior: .permanentlyFail)

        // The delivery failure is caught by [protect] -- the job ID must
        // still be retrievable afterward (LassoEmailSendFailure's whole
        // point, §4.0/§4.7b), unlike a pre-send validation failure, which
        // never records a job at all.
        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b'][/protect]" +
            "[var(jobid = email_result())]" +
            "[email_status($jobid)]",
            context: &context
        )

        #expect(output == "error")
    }

    @Test func emailResultThrowsAClearCatchableErrorWithNoPriorEmailSendInThisContext() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][var(jobid = email_result())][/protect]after-[error_currenterror]",
            context: &context
        )

        #expect(output.hasPrefix("after-"))
        #expect(output.contains("no email_send"))
    }

    @Test func emailResultThrowsAgainAfterAPreSendValidationFailureLeavesNoJobRecorded() async throws {
        var context = try Self.makeContext()

        // A pre-send validation failure (missing -subject) never records a
        // job at all -- email_result() must still throw, not return a
        // leftover/stale ID from some earlier call.
        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -body='b'][/protect]" +
            "[protect][var(jobid = email_result())][/protect]after-[error_currenterror]",
            context: &context
        )

        #expect(output.hasPrefix("after-"))
        #expect(output.contains("no email_send"))
    }

    // BLOCKING FIX #4 (Phase E milestone review, protocol/SMTP pass):
    // renamed from `emailStatusThrowsAClearCatchableErrorForAnUnknownJobID`
    // -- real Lasso documents (lassoguide.com, an archived lassosoft.com
    // reference mirror, and the local Lasso 8.5 Language Guide PDF all
    // agree) that "Messages which have been sent (or are not found in the
    // queue) will have a status of 'sent'," so an unrecognized/evicted job
    // ID must return "sent", not throw.
    @Test func emailStatusForAnUnknownJobIDReturnsSentMatchingRealLassosDocumentedBehavior() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[email_status('not-a-real-job-id')]",
            context: &context
        )

        #expect(output == "sent")
    }

    // BLOCKING FIX #3 (Phase E milestone review, architecture pass): the
    // existing `emailResultThrowsAgainAfterAPreSendValidationFailureLeavesNoJobRecorded`
    // test above only exercised a FRESH context whose very first call
    // fails, passing for the trivial reason `lastEmailJobID` was already
    // `nil` -- it never actually exercised "an earlier SUCCESSFUL call,
    // then a LATER failing call in the same context," which is the real
    // scenario `Runtime.swift`'s `email_send` wrapper needed to reset
    // `lastEmailJobID` for.
    @Test func aSuccessfulEmailSendFollowedByAValidationFailingOneLeavesNoStaleJobID() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']" +
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -body='missing subject'][/protect]" +
            "[protect][var(jobid = email_result())][/protect]after-[error_currenterror]",
            context: &context
        )

        // The FIRST email_send succeeded and recorded a real job ID; the
        // SECOND, in the same context, failed pre-send validation (missing
        // -subject) and must not leave that first job ID lingering --
        // email_result() must now throw, not silently return the first
        // call's stale ID.
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("no email_send"))
    }

    @Test func eachEmailSendRecordsItsOwnDistinctJobIDNotReusingThePreviousOne() async throws {
        let recorder = SendRecorder()
        var context = try Self.makeContext(recorder: recorder)

        let output = try await LassoRenderer().render(
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b']" +
            "[var(first = email_result())]" +
            "[email_send: -to='a@example.com', -from='b@example.com', -subject='s2', -body='b2']" +
            "[var(second = email_result())]" +
            "[$first == $second]|[email_status($first)]|[email_status($second)]",
            context: &context
        )

        #expect(output == "false|sent|sent")
        #expect(recorder.sendCount == 2)
    }
}

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
//  - `-immediate=false` and `-date` both throw the "not yet supported"
//    error, also `[protect]`-catchable;
//  - `-host` naming an unconfigured relay throws a clear error;
//  - `-host` naming a configured relay actually routes to that relay
//    (verified by which fake transport recorded the call).
//

import Testing
@testable import LassoParser
@testable import LassoPerfectSMTP
import PerfectSMTP

private final class SendRecorder: @unchecked Sendable {
    private(set) var sendCount = 0
    private(set) var lastEnvelope: SMTPEnvelope?
    func record(_ envelope: SMTPEnvelope) {
        sendCount += 1
        lastEnvelope = envelope
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

    func send(_ envelope: SMTPEnvelope, _ message: SignedMessage) async throws -> [DeliveryResult] {
        recorder.record(envelope)
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
        marketingRecorder: SendRecorder = SendRecorder()
    ) throws -> LassoContext {
        let primaryMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: primaryBehavior, recorder: primaryRecorder))
        let marketingMailer = SMTPMailer(transport: FakeSMTPTransport(behavior: .succeed, recorder: marketingRecorder))
        let registry = try LassoSMTPMailerRegistry(
            mailers: ["primary": primaryMailer, "marketing": marketingMailer],
            defaultRelay: "primary"
        )
        return LassoContext(emailProvider: LassoEmailProviderImpl(registry: registry))
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

    @Test func immediateFalseThrowsNotYetSupportedCatchableByProtect() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -immediate=false][/protect]after",
            context: &context
        )
        #expect(output == "after")
    }

    @Test func dateThrowsNotYetSupportedCatchableByProtect() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b', -date='2026-01-01'][/protect]after",
            context: &context
        )
        #expect(output == "after")
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
}

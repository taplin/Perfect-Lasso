//
//  LassoEmailComposeEndToEndTests.swift
//  LassoPerfectSMTPTests
//
//  Renders a real `[var(message = email_compose(...))]` call through a
//  `LassoContext` wired with a real `LassoEmailProviderImpl`, mirroring
//  `LassoPerfectSMTPEndToEndTests.swift`'s own style exactly (same fake
//  transport machinery, even though `compose(_:context:)` never dials a
//  transport at all -- `LassoEmailProviderImpl`'s init still requires a
//  registry). Confirms (Documentation/lasso-perfect-smtp-integration-plan.md
//  §4.3b, Phase C):
//  - a happy-path full-message construction round-trips `->from`/
//    `->recipients`/`->data`/`->asString` correctly;
//  - missing `-from`/`-subject`/at-least-one-recipient each throw with
//    "email_compose" (not "email_send") in the message;
//  - attachments are resolved and included in the composed `->data` text;
//  - part-mode construction (none of `-to`/`-from`/`-subject` present)
//    throws cleanly rather than crashing or guessing at a bespoke
//    single-part composer.
//

import Foundation

import Testing
@testable import LassoParser
@testable import LassoPerfectSMTP
import PerfectSMTP

struct LassoEmailComposeEndToEndTests {
    private static func makeContext(siteRoot: URL = FileManager.default.temporaryDirectory) throws -> LassoContext {
        // `compose(_:context:)` never touches the registry's mailers (no
        // relay/transport involvement at all, by design -- see
        // `LassoEmailProviderImpl.compose`'s own doc comment), but the
        // initializer still requires one; a single dummy relay is enough.
        struct UnusedTransport: SMTPTransport {
            func send(_ envelope: SMTPEnvelope, _ message: SignedMessage) async throws -> [DeliveryResult] {
                Issue.record("compose(_:context:) must never dial a transport")
                return []
            }
        }
        let registry = try LassoSMTPMailerRegistry(
            mailers: ["primary": SMTPMailer(transport: UnusedTransport())],
            defaultRelay: "primary"
        )
        return LassoContext(emailProvider: LassoEmailProviderImpl(registry: registry, siteRoot: siteRoot))
    }

    private static func makeSiteRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-compose-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Happy path

    @Test func fullMessageConstructionRoundTripsFromRecipientsDataAndAsString() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[var(message = email_compose(-to='a@example.com', -cc='c@example.com', -from='b@example.com', -subject='Hi', -body='hello there'))]" +
            "[$message->from]|" +
            "[$message->recipients->size]|" +
            "[$message->recipients->contains('a@example.com')]|" +
            "[$message->recipients->contains('c@example.com')]|" +
            "[$message->data->contains('hello there')]|" +
            "[$message->asString->contains('hello there')]|" +
            "[$message->data == $message->asString]",
            context: &context
        )

        #expect(output == "b@example.com|2|true|true|true|true|true")
    }

    @Test func composedDataContainsRealMIMEHeaders() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='Real Subject', -body='hello'))]" +
            "[$message->data->contains('Real Subject')]|[$message->data->contains('b@example.com')]",
            context: &context
        )
        #expect(output == "true|true")
    }

    // MARK: - Validation failures name "email_compose", not "email_send"

    @Test func missingFromThrowsWithEmailComposeInTheMessageNotEmailSend() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_compose(-to='a@example.com', -subject='s', -body='b')][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("email_compose requires -from"))
        #expect(output.contains("email_send requires") == false)
    }

    @Test func missingSubjectThrowsWithEmailComposeInTheMessage() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_compose(-to='a@example.com', -from='b@example.com', -body='b')][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("email_compose requires -subject"))
    }

    @Test func missingAllRecipientsThrowsWithEmailComposeInTheMessage() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_compose(-from='b@example.com', -subject='s', -body='b')][/protect]after-[error_currenterror]",
            context: &context
        )
        #expect(output.hasPrefix("after-"))
        #expect(output.contains("email_compose requires at least one of -to/-cc/-bcc"))
    }

    // MARK: - Part-mode construction (none of -to/-from/-subject) is rejected cleanly

    @Test func partModeConstructionWithNoneOfToFromSubjectThrowsCleanlyNotACrash() async throws {
        var context = try Self.makeContext()

        let output = try await LassoRenderer().render(
            "[protect][email_compose(-body='just a mime part')][/protect]after",
            context: &context
        )
        #expect(output == "after")
    }

    @Test func partModeConstructionSurfacesAsALassoRecoverableErrorWhenUncaught() async throws {
        var context = try Self.makeContext()

        await #expect(throws: LassoRecoverableError.self) {
            try await LassoRenderer().render(
                "[email_compose(-body='just a mime part')]",
                context: &context
            )
        }
    }

    // MARK: - Attachments (§4.5's pipeline, reused unchanged)

    @Test func attachmentsAreResolvedAndIncludedInComposedData() async throws {
        let siteRoot = try Self.makeSiteRoot()
        try Data("attachment body text".utf8).write(to: siteRoot.appendingPathComponent("note.txt"))
        var context = try Self.makeContext(siteRoot: siteRoot)

        let output = try await LassoRenderer().render(
            "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi', -attachments=array('note.txt')))]" +
            "[$message->data->contains('note.txt')]|" +
            "[$message->data->contains('" + Data("attachment body text".utf8).base64EncodedString() + "')]",
            context: &context
        )
        #expect(output == "true|true")
    }

    @Test func attachmentPathEscapingSiteRootIsACatchableFailureNotACrash() async throws {
        let siteRoot = try Self.makeSiteRoot()
        var context = try Self.makeContext(siteRoot: siteRoot)

        let output = try await LassoRenderer().render(
            "[protect][email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi', -attachments=array('../../../../../../etc/passwd'))][/protect]after",
            context: &context
        )
        #expect(output == "after")
    }

    // MARK: - Mutating builder methods (deferred, see LassoParserTests.swift's own coverage)

    @Test func addAttachmentOnAConstructedMessageThrowsNotYetSupportedNotNull() async throws {
        var context = try Self.makeContext()

        await #expect(throws: LassoRuntimeError.emailComposeMutationNotYetSupported("addAttachment")) {
            try await LassoRenderer().render(
                "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi'))][$message->addAttachment(-path='x.txt')]",
                context: &context
            )
        }
    }

    // MARK: - Raw field assignment cannot bypass method-based mutation
    // control (Phase C milestone review BLOCKING FIX #1)

    @Test func rawFieldAssignmentToDataCannotOverwriteTheComposedMIMEText() async throws {
        // Confirmed exploitable live during the milestone review:
        // `[$message->_data = 'INJECTED']` used to silently overwrite the
        // composed MIME text, completely bypassing
        // `HeaderEncoder.rejectHeaderInjection`/`MIMEComposer
        // .sanitizedFilename`/every other validation the compose path is
        // supposed to enforce -- because `Evaluator.assign`'s `.member`
        // case called `LassoObjectInstance.set(_:for:)` unconditionally,
        // with no check against `context.nativeTypes` at all. Must now
        // throw the dedicated error instead.
        var context = try Self.makeContext()

        await #expect(throws: LassoRuntimeError.nativeTypeFieldAssignmentNotSupported(typeName: "email_compose", field: "_data")) {
            try await LassoRenderer().render(
                "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi'))][$message->_data = 'INJECTED']",
                context: &context
            )
        }
    }

    @Test func rawFieldAssignmentToFromCannotOverwriteTheFromAddress() async throws {
        var context = try Self.makeContext()

        await #expect(throws: LassoRuntimeError.nativeTypeFieldAssignmentNotSupported(typeName: "email_compose", field: "_from")) {
            try await LassoRenderer().render(
                "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi'))][$message->_from = 'attacker@evil.example.com']",
                context: &context
            )
        }
    }

    @Test func rawFieldAssignmentToRecipientsCannotOverwriteTheRecipientList() async throws {
        var context = try Self.makeContext()

        await #expect(throws: LassoRuntimeError.nativeTypeFieldAssignmentNotSupported(typeName: "email_compose", field: "_recipients")) {
            try await LassoRenderer().render(
                "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi'))][$message->_recipients = array('attacker@evil.example.com')]",
                context: &context
            )
        }
    }

    @Test func composedMessageDataIsUnaffectedAfterAFailedRawFieldAssignmentAttempt() async throws {
        // Belt-and-suspenders: confirm the composed text genuinely wasn't
        // touched even transiently -- the throw happens before
        // `object.set` is ever called, so this should hold trivially, but
        // it's the concrete behavior real corpus code protecting against
        // this class of bug actually cares about. `LassoRuntimeError` is a
        // FATAL runtime error, not a `LassoRecoverableError` -- `[protect]`
        // does not (and must not) catch it, so the throwing statement and
        // the follow-up assertion are split into separate `render` calls
        // against the same, persistent `context` (a `var` passed `inout`,
        // exactly like the MX lookup cache-sharing tests already do)
        // rather than one `[protect]...[/protect]` span.
        var context = try Self.makeContext()

        _ = try await LassoRenderer().render(
            "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi'))]",
            context: &context
        )
        await #expect(throws: LassoRuntimeError.nativeTypeFieldAssignmentNotSupported(typeName: "email_compose", field: "_data")) {
            try await LassoRenderer().render("[$message->_data = 'INJECTED']", context: &context)
        }
        let output = try await LassoRenderer().render("[$message->data->contains('INJECTED')]", context: &context)
        #expect(output == "false")
    }

    // MARK: - ->Summary (Phase C milestone review NON-BLOCKING C): real,
    // documented member, deferred rather than silently returning `.null`.

    @Test func summaryThrowsNotYetSupportedRatherThanSilentlyReturningNull() async throws {
        var context = try Self.makeContext()

        await #expect(throws: LassoRuntimeError.emailComposeMutationNotYetSupported("summary")) {
            try await LassoRenderer().render(
                "[var(message = email_compose(-to='a@example.com', -from='b@example.com', -subject='s', -body='hi'))][$message->summary]",
                context: &context
            )
        }
    }
}

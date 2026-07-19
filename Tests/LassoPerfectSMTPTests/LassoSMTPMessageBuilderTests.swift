//
//  LassoSMTPMessageBuilderTests.swift
//  LassoPerfectSMTPTests
//
//  Dash-param -> `EmailMessage` mapping tests for `LassoSMTPMessageBuilder`
//  — §4.3's finalized table, Phase A scope. Pure unit tests: no relay
//  registry, no network, no `LassoContext` — `LassoSMTPMessageBuilder.build`
//  takes `[EvaluatedArgument]` directly.
//

import Testing
@testable import LassoParser
@testable import LassoPerfectSMTP
import PerfectSMTP

private func arg(_ label: String, _ value: String) -> EvaluatedArgument {
    EvaluatedArgument(label: label, value: .string(value))
}

private func flag(_ label: String, _ value: Bool) -> EvaluatedArgument {
    EvaluatedArgument(label: label, value: .boolean(value))
}

/// A minimally-complete, valid call — every test that isn't specifically
/// exercising one of these fields starts from this and overrides/extends.
private let validBaseArguments: [EvaluatedArgument] = [
    arg("to", "recipient@example.com"),
    arg("from", "sender@example.com"),
    arg("subject", "Hello"),
    arg("body", "Body text"),
]

struct LassoSMTPMessageBuilderTests {
    // MARK: - Core field mapping

    @Test func fullFieldSetMapsOntoEmailMessage() throws {
        let arguments: [EvaluatedArgument] = [
            arg("to", "a@example.com, b@example.com"),
            arg("cc", "c@example.com"),
            arg("bcc", "d@example.com"),
            arg("from", "sender@example.com"),
            arg("subject", "Hello there"),
            arg("body", "plain body"),
            arg("html", "<p>html body</p>"),
            arg("replyTo", "reply@example.com"),
            arg("sender", "onbehalf@example.com"),
            arg("priority", "High"),
            arg("extraMIMEHeaders", "X-Custom: 1"),
            arg("ContentDisposition", "inline"),
        ]

        let result = try LassoSMTPMessageBuilder.build(arguments)

        #expect(result.message.to.map(\.address) == ["a@example.com", "b@example.com"])
        #expect(result.message.cc.map(\.address) == ["c@example.com"])
        #expect(result.bcc == ["d@example.com"]) // [String], not [EmailAddress] -- see doc comment
        #expect(result.message.from == EmailAddress(address: "sender@example.com"))
        #expect(result.message.subject == "Hello there")
        #expect(result.message.textBody == "plain body")
        #expect(result.message.htmlBody == "<p>html body</p>")
        #expect(result.message.replyTo == [EmailAddress(address: "reply@example.com")])
        #expect(result.message.sender == EmailAddress(address: "onbehalf@example.com"))
        #expect(result.message.priority == .high)
        #expect(result.message.extraHeaders.count == 1)
        #expect(result.message.extraHeaders[0].name == "X-Custom")
        #expect(result.message.extraHeaders[0].value == "1")
        #expect(result.message.defaultDisposition == .inline)
        #expect(result.envelopeFrom == .address("sender@example.com"))
        #expect(result.relayName == nil)
    }

    @Test func bccIsMappedToStringAddressesNotEmailAddresses() throws {
        let result = try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("bcc", "hidden@example.com")])
        #expect(result.bcc == ["hidden@example.com"])
        // EmailMessage itself has no bcc field at all -- Perfect-SMTP's
        // structural Bcc-leak fix, §4.3's table.
    }

    @Test func priorityDefaultsToNormalWhenAbsent() throws {
        let result = try LassoSMTPMessageBuilder.build(validBaseArguments)
        #expect(result.message.priority == .normal)
    }

    @Test func priorityLowMapsToLowPriority() throws {
        let result = try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("priority", "Low")])
        #expect(result.message.priority == .low)
    }

    @Test func unrecognizedPriorityFallsBackToNormal() throws {
        let result = try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("priority", "Urgent")])
        #expect(result.message.priority == .normal)
    }

    // MARK: - -host relay-name selection (not resolved here -- see
    // LassoSMTPMailerRegistry/LassoEmailProviderImpl for the actual
    // SSRF-safe name resolution).

    @Test func hostAbsentLeavesRelayNameNil() throws {
        let result = try LassoSMTPMessageBuilder.build(validBaseArguments)
        #expect(result.relayName == nil)
    }

    @Test func hostPresentIsCarriedAsARawRelayNameUnresolved() throws {
        let result = try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("host", "marketing")])
        #expect(result.relayName == "marketing")
    }

    // MARK: - Required-field validation

    @Test func missingFromThrows() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "from" }
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(arguments)
        }
    }

    @Test func missingSubjectThrows() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "subject" }
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(arguments)
        }
    }

    @Test func emptySubjectIsToleratedWhenExplicitlyGiven() throws {
        // An explicitly empty -subject="" is a legal (if unusual) blank
        // subject line -- only a wholly missing -subject is rejected.
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "subject" } + [arg("subject", "")]
        let result = try LassoSMTPMessageBuilder.build(arguments)
        #expect(result.message.subject == "")
    }

    @Test func noRecipientsAtAllThrows() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "to" }
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(arguments)
        }
    }

    @Test func ccOnlyIsSufficientRecipientCoverage() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "to" } + [arg("cc", "c@example.com")]
        let result = try LassoSMTPMessageBuilder.build(arguments)
        #expect(result.message.to.isEmpty)
        #expect(result.message.cc.map(\.address) == ["c@example.com"])
    }

    @Test func bccOnlyIsSufficientRecipientCoverage() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "to" } + [arg("bcc", "hidden@example.com")]
        let result = try LassoSMTPMessageBuilder.build(arguments)
        #expect(result.bcc == ["hidden@example.com"])
    }

    @Test func malformedToThrows() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "to" } + [arg("to", "not-an-address")]
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(arguments)
        }
    }

    @Test func multipleFromAddressesThrows() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "from" } + [arg("from", "a@example.com, b@example.com")]
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(arguments)
        }
    }

    @Test func invalidContentDispositionThrows() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("ContentDisposition", "sideways")])
        }
    }

    // MARK: - -simpleform: legitimately no body at all (not faked here --
    // see LassoEmailProviderImpl's doc comment for the real, flagged
    // Perfect-SMTP MIMEComposer.missingBody gap this reaches).

    @Test func bothBodiesAbsentBuildsSuccessfullyWithNilBodies() throws {
        let arguments = validBaseArguments.filter { $0.label?.lowercased() != "body" }
        let result = try LassoSMTPMessageBuilder.build(arguments)
        #expect(result.message.textBody == nil)
        #expect(result.message.htmlBody == nil)
    }

    // MARK: - Not-yet-supported params (§4.3/§7): always throw, regardless
    // of value.

    @Test func dateAlwaysThrowsRegardlessOfValue() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("date", "2026-01-01")])
        }
    }

    @Test func immediateFalseThrows() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [flag("immediate", false)])
        }
    }

    @Test func immediateTrueOrAbsentDoesNotThrow() throws {
        _ = try LassoSMTPMessageBuilder.build(validBaseArguments)
        _ = try LassoSMTPMessageBuilder.build(validBaseArguments + [flag("immediate", true)])
    }

    @Test func tokensThrows() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("tokens", "a=1")])
        }
    }

    @Test func mergeThrows() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("merge", "true")])
        }
    }

    @Test func contentTypeThrows() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("contentType", "text/plain")])
        }
    }

    @Test func transferEncodingThrows() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("transferEncoding", "base64")])
        }
    }

    @Test func characterSetThrows() throws {
        #expect(throws: LassoSMTPError.self) {
            try LassoSMTPMessageBuilder.build(validBaseArguments + [arg("characterSet", "iso-8859-1")])
        }
    }

    // MARK: - Silently-ignored connection-only params (§4.3/§5): recognized,
    // never honored as per-call overrides, never an error either.

    @Test func portUsernamePasswordSSLTimeoutAreSilentlyIgnored() throws {
        let arguments = validBaseArguments + [
            arg("port", "2525"),
            arg("username", "someone"),
            arg("password", "secret"),
            flag("ssl", true),
            arg("timeout", "5"),
        ]
        let result = try LassoSMTPMessageBuilder.build(arguments)
        // Build succeeds normally; none of these five params show up
        // anywhere on the resulting message/relay selection.
        #expect(result.relayName == nil)
        #expect(result.message.subject == "Hello")
    }
}

//
//  LassoSMTPAddressListTests.swift
//  LassoPerfectSMTPTests
//
//  Pure unit tests for `LassoSMTPAddressList.parse(_:)` — §4.2's
//  quote/comma/whitespace edge cases. No I/O, no `LassoContext` — the
//  parser is fully standalone.
//

import Testing
@testable import LassoPerfectSMTP
import PerfectSMTP

struct LassoSMTPAddressListTests {
    @Test func emptyStringParsesToNoAddresses() throws {
        #expect(try LassoSMTPAddressList.parse("") == [])
        #expect(try LassoSMTPAddressList.parse("   ") == [])
    }

    @Test func bareAddressParsesWithNoDisplayName() throws {
        let result = try LassoSMTPAddressList.parse("a@example.com")
        #expect(result == [EmailAddress(address: "a@example.com")])
    }

    @Test func displayNameWithAngleAddressParses() throws {
        let result = try LassoSMTPAddressList.parse("John Doe <john@example.com>")
        #expect(result == [EmailAddress(displayName: "John Doe", address: "john@example.com")])
    }

    @Test func quotedDisplayNameContainingCommaDoesNotSplitTheEntry() throws {
        let result = try LassoSMTPAddressList.parse("\"Doe, John\" <john@example.com>")
        #expect(result.count == 1)
        #expect(result[0].displayName == "Doe, John")
        #expect(result[0].address == "john@example.com")
    }

    @Test func multipleCommaSeparatedEntriesAllParse() throws {
        let result = try LassoSMTPAddressList.parse("a@example.com, b@example.com")
        #expect(result == [
            EmailAddress(address: "a@example.com"),
            EmailAddress(address: "b@example.com"),
        ])
    }

    @Test func mixedBareDisplayNameAndQuotedCommaEntriesAllParseTogether() throws {
        let raw = "Jane <jane@example.com>, \"Smith, Bob\" <bob@example.com>, plain@example.com"
        let result = try LassoSMTPAddressList.parse(raw)
        #expect(result.count == 3)
        #expect(result[0] == EmailAddress(displayName: "Jane", address: "jane@example.com"))
        #expect(result[1].displayName == "Smith, Bob")
        #expect(result[1].address == "bob@example.com")
        #expect(result[2] == EmailAddress(address: "plain@example.com"))
    }

    @Test func extraWhitespaceAroundEntriesIsTolerated() throws {
        let result = try LassoSMTPAddressList.parse("  a@example.com  ,   Jane Doe   <  jane@example.com  >  ")
        #expect(result.count == 2)
        #expect(result[0] == EmailAddress(address: "a@example.com"))
        #expect(result[1] == EmailAddress(displayName: "Jane Doe", address: "jane@example.com"))
    }

    @Test func trailingCommaIsTolerated() throws {
        let result = try LassoSMTPAddressList.parse("a@example.com,")
        #expect(result == [EmailAddress(address: "a@example.com")])
    }

    @Test func doubledCommaIsTolerated() throws {
        let result = try LassoSMTPAddressList.parse("a@example.com,,b@example.com")
        #expect(result == [
            EmailAddress(address: "a@example.com"),
            EmailAddress(address: "b@example.com"),
        ])
    }

    @Test func escapedQuoteInsideDisplayNameIsUnescaped() throws {
        let result = try LassoSMTPAddressList.parse("\"Jane \\\"J\\\" Doe\" <jane@example.com>")
        #expect(result.count == 1)
        #expect(result[0].displayName == "Jane \"J\" Doe")
    }

    @Test func bareTokenWithNoAtSignThrowsMissingAddress() throws {
        #expect(throws: LassoSMTPAddressListError.self) {
            try LassoSMTPAddressList.parse("not-an-email")
        }
    }

    @Test func unterminatedQuoteThrows() throws {
        #expect(throws: LassoSMTPAddressListError.self) {
            try LassoSMTPAddressList.parse("\"Doe, John <john@example.com>")
        }
    }

    @Test func unterminatedAngleBracketThrows() throws {
        #expect(throws: LassoSMTPAddressListError.self) {
            try LassoSMTPAddressList.parse("John Doe <john@example.com")
        }
    }

    @Test func emptyAngleAddressThrowsMissingAddress() throws {
        #expect(throws: LassoSMTPAddressListError.self) {
            try LassoSMTPAddressList.parse("John Doe <>")
        }
    }

    @Test func onlyCommasParsesToNoAddresses() throws {
        // Consistent with trailing/doubled-comma tolerance above -- every
        // split segment is empty-after-trim, so this is treated the same
        // as "no addresses supplied," not malformed content.
        #expect(try LassoSMTPAddressList.parse(",,,") == [])
    }

    // MARK: - Regression tests for the four-way milestone review's three
    // parseEntry bugs (missing-comma silent drop, comment-syntax
    // corruption, nested-angle-bracket corruption) -- all now throw
    // instead of silently losing or corrupting data.

    @Test func missingCommaBetweenAngleAddressAndBareAddressThrowsInsteadOfDroppingRecipient() throws {
        // Previously parsed to ONE address (a@example.com) with
        // " b@example.com" silently discarded.
        #expect(throws: LassoSMTPAddressListError.self) {
            try LassoSMTPAddressList.parse("Name <a@example.com> b@example.com")
        }
    }

    @Test func rfc5322CommentSyntaxThrowsInsteadOfCorruptingTheAddress() throws {
        // Previously the whole string "(John Doe) a@example.com" -- parens
        // included -- became EmailAddress.address.
        #expect(throws: LassoSMTPAddressListError.self) {
            try LassoSMTPAddressList.parse("(John Doe) a@example.com")
        }
    }

    @Test func nestedAngleBracketsThrowInsteadOfCorruptingTheAddress() throws {
        // Previously addressPart retained a literal "<"/">" baked into
        // EmailAddress.address: "<addr@example.com>".
        #expect(throws: LassoSMTPAddressListError.self) {
            try LassoSMTPAddressList.parse("<<addr@example.com>>")
        }
    }
}

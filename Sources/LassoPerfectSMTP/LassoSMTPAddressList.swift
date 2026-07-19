//
//  LassoSMTPAddressList.swift
//  LassoPerfectSMTP
//
//  RFC-5322-aware, quote-comma-aware address-list parsing for Lasso's
//  `-to`/`-cc`/`-bcc` dash-params — see
//  Documentation/lasso-perfect-smtp-integration-plan.md §4.2. Real Lasso
//  8.5/9 accepts a single comma-delimited string for each of these params
//  (bare addresses, `Display Name <addr>`, and `"Quoted, Name" <addr>`, any
//  mixture, comma-separated). Neither `Perfect-SMTP` nor the pre-existing
//  Perfect-Lasso codebase has an equivalent splitter — confirmed absent by
//  the integration plan's research pass — so this is written from scratch.
//
//  Deliberately pure string parsing: no I/O, no `LassoContext`/
//  `EvaluatedArgument` dependency, so it's usable and testable completely
//  standalone before anything else in this target exists.
//

import Foundation
import PerfectSMTP

/// Malformed-input errors `LassoSMTPAddressList.parse(_:)` throws. Fail-loud
/// on malformed input (never silently drops a malformed entry) — matches
/// this codebase's adapter posture elsewhere (e.g.
/// `LassoFileMakerLassoError`/`LassoDatabaseActionError`'s "structural
/// problems throw fatally" convention), since a mangled `-to` is far more
/// likely to be a real caller bug (a busted mail-merge template, a stray
/// quote) than something safe to skip past silently.
public enum LassoSMTPAddressListError: Error, Equatable, Sendable {
    /// An entry (after splitting on top-level commas) was empty once
    /// trimmed — e.g. two commas in a row with nothing between them, `",,"`.
    case emptyEntry(String)
    /// A `"..."` quoted phrase was opened but never closed by end of input.
    case unterminatedQuote(String)
    /// A `<...>` angle-bracket address was opened but never closed by end
    /// of input.
    case unterminatedAngleBracket(String)
    /// An entry had no `@`-containing address at all — either a bare
    /// token with no `@`, or an empty/malformed `<...>` payload.
    case missingAddress(String)
    /// An entry had *some* `@`-containing address, but the surrounding
    /// structure doesn't fully account for the entry's content — e.g. a
    /// missing comma left extra text trailing after a `<...>` address
    /// (`Name <a@example.com> b@example.com`), RFC 5322 comment syntax the
    /// bare-address branch can't safely interpret (`(John Doe)
    /// a@example.com`), or nested angle brackets (`<<addr@example.com>>`).
    /// Thrown instead of silently dropping the extra text or baking stray
    /// punctuation into `EmailAddress.address` — see this enum's doc
    /// comment.
    case malformedAddress(String)
}

/// See file doc comment. `parse(_:)` is the only public entry point;
/// everything else is a private implementation detail of the tokenizer/
/// entry-parser split.
public enum LassoSMTPAddressList {
    /// Parses a single comma-delimited address-list string (the shape every
    /// one of `-to`/`-cc`/`-bcc` takes) into `EmailAddress` values.
    ///
    /// - An empty or whitespace-only `raw` returns `[]` — a Lasso page
    ///   omitting `-cc` still evaluates that dash-param's value as an empty
    ///   string in some call shapes, and "no recipients supplied" is not
    ///   itself malformed input worth throwing over; the caller (
    ///   `LassoSMTPMessageBuilder`) is responsible for enforcing "at least
    ///   one of to/cc/bcc" if that's required.
    /// - Every other malformed shape throws rather than silently dropping
    ///   or best-effort-guessing — see `LassoSMTPAddressListError`.
    public static func parse(_ raw: String) throws -> [EmailAddress] {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let entries = try splitTopLevelEntries(raw)
        return try entries.map(parseEntry)
    }

    // MARK: - Tokenizer: split on commas, but never inside a quoted phrase
    // or inside `<...>`.

    /// Splits `raw` on `,` characters, except where the comma appears
    /// inside a `"..."` quoted phrase (RFC 5322 `quoted-string`, with
    /// `\`-escaped characters honored so `\"` doesn't end the quote early)
    /// or inside a `<...>` angle-address. The `<...>` case matters less for
    /// real-world commas (an addr-spec itself can't legally contain one),
    /// but guarding it too costs nothing and avoids a surprise if a caller
    /// ever hands in a genuinely malformed angle-address containing one.
    private static func splitTopLevelEntries(_ raw: String) throws -> [String] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", inQuotes {
                // RFC 5322 quoted-pair: the backslash and the character it
                // escapes both pass through literally, and the escaped
                // character (even a `"`) never toggles quote state.
                current.append(c)
                if i + 1 < chars.count {
                    current.append(chars[i + 1])
                    i += 1
                }
            } else if c == "\"" {
                inQuotes.toggle()
                current.append(c)
            } else if c == "<", !inQuotes {
                angleDepth += 1
                current.append(c)
            } else if c == ">", !inQuotes {
                if angleDepth > 0 { angleDepth -= 1 }
                current.append(c)
            } else if c == ",", !inQuotes, angleDepth == 0 {
                entries.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        if inQuotes { throw LassoSMTPAddressListError.unterminatedQuote(raw) }
        if angleDepth != 0 { throw LassoSMTPAddressListError.unterminatedAngleBracket(raw) }
        entries.append(current)

        // Trim whitespace around each entry, then drop entries that are
        // empty only because of a trailing/leading/doubled comma (e.g.
        // "a@example.com," or "a@example.com,,b@example.com") — real-world
        // mail-merge templates routinely leave a trailing separator; that's
        // whitespace-tolerance, not malformed content. An entry that's
        // non-empty but still has no usable address (e.g. a bare `,` with
        // stray text) is caught later, in `parseEntry`.
        return entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    // MARK: - Per-entry parse: `addr`, `Name <addr>`, or `"Quoted, Name" <addr>`

    private static func parseEntry(_ entry: String) throws -> EmailAddress {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw LassoSMTPAddressListError.emptyEntry(entry)
        }

        if let angleStart = trimmed.firstIndex(of: "<") {
            guard let angleEnd = trimmed.lastIndex(of: ">"), angleStart < angleEnd else {
                throw LassoSMTPAddressListError.unterminatedAngleBracket(entry)
            }
            let namePart = String(trimmed[trimmed.startIndex..<angleStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let addressPart = String(trimmed[trimmed.index(after: angleStart)..<angleEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard addressPart.isEmpty == false, addressPart.contains("@") else {
                throw LassoSMTPAddressListError.missingAddress(entry)
            }
            // Bug C: nested/duplicated angle brackets (`<<addr@example.com>>`)
            // -- `firstIndex(of: "<")`/`lastIndex(of: ">")` alone would
            // happily bake the extra `<`/`>` into `addressPart`.
            guard addressPart.contains("<") == false, addressPart.contains(">") == false else {
                throw LassoSMTPAddressListError.malformedAddress(entry)
            }
            // Bug A: anything left over after `angleEnd` (once
            // whitespace-trimmed) means the consumed `<...>` structure
            // didn't cover the whole entry -- e.g. a missing comma between
            // two would-be recipients (`Name <a@example.com> b@example.com`)
            // would otherwise silently discard everything after `angleEnd`.
            let trailing = trimmed[trimmed.index(after: angleEnd)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trailing.isEmpty else {
                throw LassoSMTPAddressListError.malformedAddress(entry)
            }
            let displayName = try unquote(namePart)
            return EmailAddress(displayName: displayName.isEmpty ? nil : displayName, address: addressPart)
        }

        // Bare address, no display name and no angle brackets at all.
        guard trimmed.contains("@") else {
            throw LassoSMTPAddressListError.missingAddress(entry)
        }
        // Bug B: no `<...>` structure present at all, so this must be a
        // single bare address token -- reject RFC 5322 comment syntax
        // (`(John Doe) a@example.com`) and any other internal whitespace,
        // rather than folding parens/spaces into `EmailAddress.address`.
        guard trimmed.contains("(") == false,
              trimmed.contains(")") == false,
              trimmed.contains(">") == false,
              trimmed.contains(where: { $0.isWhitespace }) == false
        else {
            throw LassoSMTPAddressListError.malformedAddress(entry)
        }
        return EmailAddress(address: trimmed)
    }

    /// Strips a surrounding `"..."` quoted-string wrapper (if present) and
    /// un-escapes `\`-escaped characters inside it. A display name with no
    /// quotes at all (the common case, `Display Name <addr>`) passes
    /// through unchanged.
    private static func unquote(_ namePart: String) throws -> String {
        guard namePart.hasPrefix("\"") else { return namePart }
        guard namePart.hasSuffix("\""), namePart.count >= 2 else {
            throw LassoSMTPAddressListError.unterminatedQuote(namePart)
        }
        let inner = namePart.dropFirst().dropLast()
        var result = ""
        var iterator = inner.makeIterator()
        while let c = iterator.next() {
            if c == "\\", let next = iterator.next() {
                result.append(next)
            } else {
                result.append(c)
            }
        }
        return result
    }
}

import Foundation

/// Shared implementation for Lasso 8.5 Language Guide Ch. 25 Table 11
/// ("Character Information Member Tags") — every one of these inspects a
/// single character (already resolved to a 1-based position by the caller)
/// and returns a value describing one of its documented Unicode
/// properties. Centralized here (rather than inline per-case in
/// `Evaluator.swift`, as most other string members are) because these 16
/// tags share one dispatch shape and one source of truth for "which
/// Unicode property backs which tag name" — duplicating that mapping
/// across call sites would be the real risk, not the individual checks
/// themselves.
///
/// `->CharName` (the documented Unicode Character Database display name,
/// e.g. "LATIN SMALL LETTER B") is deliberately NOT implemented anywhere
/// in this file or its Runtime.swift free-tag sibling `String_CharFromName`
/// — Swift/Foundation expose no UCD name table, and Unicode has no simple
/// algorithmic name-generation rule outside a few narrow ranges (Hangul
/// syllables, CJK/Tangut/etc. ideographs). Guessing a name for only some
/// code points would silently produce wrong answers for everything else
/// rather than a clear, disclosed gap — left unimplemented, matching this
/// project's precedent for genuinely-needs-external-data features (e.g.
/// Blowfish cipher support).
enum LassoStringInformation {
    private static let names: Set<String> = [
        "chardigitvalue", "chartype", "digit", "getnumericvalue",
        "isalnum", "isalpha", "isbase", "iscntrl", "isdigit", "islower",
        "isprint", "isspace", "istitle", "isupper", "iswhitespace",
        "isualphabetic", "isulowercase", "isuuppercase", "isuwhitespace",
    ]

    static func isCharacterMemberName(_ name: String) -> Bool {
        names.contains(name)
    }

    static func characterMember(_ name: String, of character: Character, radix: Int) -> LassoValue {
        let scalar = character.unicodeScalars.first
        let properties = scalar?.properties
        switch name {
        case "chardigitvalue":
            // "Returns the integer value of a character or -1 if the
            // character is [not a digit]" — the Guide's own wording says
            // "if the character is alphabetic", which reads as an
            // editing artifact (an alphabetic character trivially has no
            // digit value either, but so does punctuation/whitespace);
            // implemented against Swift's own `wholeNumberValue` (nil for
            // any non-digit character), matching `->Digit`'s sibling
            // entry immediately below and every worked example's own use
            // on genuine digit characters.
            return .integer(character.wholeNumberValue ?? -1)
        case "chartype":
            // Ch. 25's own worked example: `'b'->(CharType: 1)` →
            // `LOWERCASE_LETTER`; a CJK ideograph → `OTHER_LETTER`. Maps
            // directly onto Unicode's General Category property, upper-
            // snake-cased to match those exact worked-example strings.
            guard let category = properties?.generalCategory else { return .string("") }
            return .string(generalCategoryName(category))
        case "digit":
            // "the integer value of a character according to a
            // particular radix (e.g. 16 for hexadecimal)" — worked
            // example: `'b'->(Digit: 1, 16)` → 11. An earlier version
            // only special-cased radix 16 (`hexDigitValue`) and fell
            // back to a plain-decimal `wholeNumberValue` for every other
            // radix — not just narrower than documented but ACTIVELY
            // WRONG: `Digit('5', 2)` returned 5, a value with no valid
            // representation in binary, instead of signaling "not a
            // digit in this radix." `Int(_:radix:)` handles every radix
            // 2...36 correctly (case-insensitive a-z as digits 10-35)
            // and returns `nil` for an invalid digit, matching the -1
            // sentinel convention already used throughout this table —
            // found by architect review.
            guard (2...36).contains(radix), let value = Int(String(character), radix: radix) else {
                return .integer(-1)
            }
            return .integer(value)
        case "getnumericvalue":
            // Table 11's wording for this tag ("the DECIMAL value of a
            // character or A NEGATIVE NUMBER") is subtly broader than
            // `->CharDigitValue`'s own wording ("the integer value... or
            // -1") just above — this maps closely onto ICU's own
            // documented split between `u_charDigitValue` (narrow:
            // decimal digits only, sentinel exactly -1) and
            // `u_getNumericValue` (broad: any Unicode character with a
            // Numeric_Type, including vulgar fractions and Roman
            // numerals, which can be non-integer) — this project's own
            // established practice is to default to real ICU semantics
            // when the Guide's wording is ambiguous. Uses Swift's own
            // broader `Unicode.Scalar.Properties.numericValue` (a
            // `Double?`) rather than `wholeNumberValue`, returning a
            // whole `.integer` when the value happens to be a whole
            // number (matching every digit-character worked example
            // elsewhere in this table) and a `.decimal` only for a
            // genuinely fractional Unicode numeric value. Found by
            // architect review — an earlier version collapsed this to
            // the exact same narrow `wholeNumberValue ?? -1` as
            // `->CharDigitValue`, discarding the documented distinction.
            guard let value = scalar?.properties.numericValue else { return .integer(-1) }
            return value == value.rounded() ? .integer(Int(value)) : .decimal(value)
        case "isalnum": return .boolean(character.isLetter || character.isNumber)
        case "isalpha": return .boolean(character.isLetter)
        case "isbase":
            // "part of the base characters of Unicode" — a base
            // character is one that does not combine with a preceding
            // character, i.e. canonical combining class 0.
            return .boolean((properties?.canonicalCombiningClass ?? .notReordered) == .notReordered)
        case "iscntrl": return .boolean(properties?.generalCategory == .control)
        case "isdigit": return .boolean(character.isNumber)
        case "islower": return .boolean(character.isLowercase)
        case "isprint": return .boolean(properties?.generalCategory != .control)
        case "isspace": return .boolean(character.isWhitespace)
        case "istitle": return .boolean(properties?.generalCategory == .titlecaseLetter)
        case "isupper": return .boolean(character.isUppercase)
        case "iswhitespace": return .boolean(character.isWhitespace)
        case "isualphabetic": return .boolean(properties?.isAlphabetic ?? false)
        case "isulowercase": return .boolean(properties?.isLowercase ?? false)
        case "isuuppercase": return .boolean(properties?.isUppercase ?? false)
        case "isuwhitespace": return .boolean(properties?.isWhitespace ?? false)
        default: return .void
        }
    }

    private static func generalCategoryName(_ category: Unicode.GeneralCategory) -> String {
        switch category {
        case .uppercaseLetter: return "UPPERCASE_LETTER"
        case .lowercaseLetter: return "LOWERCASE_LETTER"
        case .titlecaseLetter: return "TITLECASE_LETTER"
        case .modifierLetter: return "MODIFIER_LETTER"
        case .otherLetter: return "OTHER_LETTER"
        case .nonspacingMark: return "NON_SPACING_MARK"
        case .spacingMark: return "COMBINING_SPACING_MARK"
        case .enclosingMark: return "ENCLOSING_MARK"
        case .decimalNumber: return "DECIMAL_DIGIT_NUMBER"
        case .letterNumber: return "LETTER_NUMBER"
        case .otherNumber: return "OTHER_NUMBER"
        case .connectorPunctuation: return "CONNECTOR_PUNCTUATION"
        case .dashPunctuation: return "DASH_PUNCTUATION"
        case .openPunctuation: return "START_PUNCTUATION"
        case .closePunctuation: return "END_PUNCTUATION"
        case .initialPunctuation: return "INITIAL_QUOTE_PUNCTUATION"
        case .finalPunctuation: return "FINAL_QUOTE_PUNCTUATION"
        case .otherPunctuation: return "OTHER_PUNCTUATION"
        case .mathSymbol: return "MATH_SYMBOL"
        case .currencySymbol: return "CURRENCY_SYMBOL"
        case .modifierSymbol: return "MODIFIER_SYMBOL"
        case .otherSymbol: return "OTHER_SYMBOL"
        case .spaceSeparator: return "SPACE_SEPARATOR"
        case .lineSeparator: return "LINE_SEPARATOR"
        case .paragraphSeparator: return "PARAGRAPH_SEPARATOR"
        case .control: return "CONTROL"
        case .format: return "FORMAT"
        case .surrogate: return "SURROGATE"
        case .privateUse: return "PRIVATE_USE"
        case .unassigned: return "UNASSIGNED"
        @unknown default: return "UNASSIGNED"
        }
    }
}

import Foundation

/// `Valid_Email`/`Valid_CreditCard` — Lasso 8.5 Language Guide, Chapter 27
/// "String Operations" (`Valid_Email`: "Accepts a single string parameter
/// containing an email address. Returns True if the email address appears
/// to be in a valid format."; `Valid_CreditCard`: "...Returns True if the
/// credit card number is valid according to the [Luhn] algorithm" — the
/// guide's own text says "ROT-13," almost certainly an OCR/transcription
/// error, since ROT-13 is a text cipher with no meaningful application to
/// numeric-checksum validation; the Luhn algorithm is the universal
/// real-world standard for this exact purpose and every other credit-card
/// format validator, past or present, implements it).
///
/// No Lasso 9 dot-notation equivalent found in the local reference docs or
/// this project's real site corpus — the site's own production code only
/// ever calls these via the classic tag form (`Valid_Email($email)`,
/// `Valid_CreditCard(field('card_number'))`), confirmed live 2026-07-18.
enum LassoValidation {
    /// A permissive, real-world "does this look like an email" check —
    /// matches the documented "appears to be in a valid format" wording,
    /// not full RFC 5322 grammar.
    static func isValidEmail(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    /// The Luhn checksum: strips spaces and dashes (common real-world
    /// card-number separators), requires everything left to be a digit,
    /// then validates that doubling every second digit from the right
    /// (subtracting 9 from any result over 9) sums to a multiple of 10.
    /// Empty or non-numeric input is never valid.
    static func isValidCreditCard(_ text: String) -> Bool {
        let cleaned = text.filter { $0.isWhitespace == false && $0 != "-" }
        guard cleaned.isEmpty == false, cleaned.allSatisfy(\.isNumber) else { return false }
        let digits = cleaned.compactMap(\.wholeNumberValue)
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

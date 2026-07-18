import Foundation

/// `Valid_Email`/`Valid_CreditCard` — confirmed against three independent
/// sources: the local Lasso 8.5 Language Guide PDF, LassoSoft's own
/// canonical tag reference (reference.lassosoft.com), and lassoguide.com's
/// Lasso 9.3 documentation. `Valid_CreditCard`'s "ROT-13 algorithm" wording
/// is verbatim on reference.lassosoft.com's own page too (not an artifact
/// of this project's PDF text extraction, as first assumed) -- it's a
/// genuine, long-standing documentation defect that's been copied forward
/// across Lasso doc revisions for decades: ROT-13 is a letter-substitution
/// cipher with no defined operation on numeric digits, and the same page's
/// own claimed behavior ("returns True for all valid credit card numbers
/// from Visa/Mastercard/AmEx/Discover") exactly matches Luhn, the real,
/// universal standard for this purpose -- not ROT-13, which is inapplicable
/// to a numeric checksum by definition.
///
/// No Lasso 9 dot-notation equivalent found in the local reference docs,
/// lassoguide.com, or this project's real site corpus -- the site's own
/// production code only ever calls these via the classic tag form
/// (`Valid_Email($email)`, `Valid_CreditCard(field('card_number'))`),
/// confirmed live 2026-07-18.
enum LassoValidation {
    /// A permissive, real-world "does this look like an email" check --
    /// matches the documented "appears to be a valid email address"
    /// wording, not full RFC 5322 grammar.
    ///
    /// reference.lassosoft.com documents three optional parameters not
    /// covered by the local 8.5 PDF alone (real corpus never uses any of
    /// them -- every call site is a single positional argument -- but
    /// they're implemented here per this project's own established
    /// convention of matching documented semantics, not just corpus usage):
    /// - `-HostName`: email's host (the part after `@`) must exactly match.
    /// - `-Domain`: comma-separated list of top-level domains; the email's
    ///   TLD must be one of them.
    /// - `-StandardDomains`: shorthand for a fixed TLD list. The reference
    ///   page's own two sections disagree on the exact list -- its
    ///   narrative description says `com,gov,mil,net,org,int` (6 TLDs) but
    ///   its structured Parameters table says `com, edu, gov, mil, net,
    ///   org, int` (7, adding `edu`) -- so this uses the more specific,
    ///   structured Parameters-table list.
    static func isValidEmail(_ text: String, hostName: String? = nil, domains: [String]? = nil) -> Bool {
        guard text.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil else {
            return false
        }
        guard let host = text.split(separator: "@", maxSplits: 1).last else { return false }
        if let hostName, host.caseInsensitiveCompare(hostName) != .orderedSame {
            return false
        }
        if let domains {
            guard let tld = host.split(separator: ".").last else { return false }
            let normalized = domains.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard normalized.contains(tld.lowercased()) else { return false }
        }
        return true
    }

    static let standardDomains = ["com", "edu", "gov", "mil", "net", "org", "int"]

    /// The Luhn checksum: strips spaces and dashes (common real-world
    /// card-number separators), requires everything left to be a digit,
    /// then validates that doubling every second digit from the right
    /// (subtracting 9 from any result over 9) sums to a multiple of 10.
    /// Empty or non-numeric input is never valid. Also rejects an
    /// all-zero digit string -- Luhn's checksum alone can't distinguish
    /// it from valid (0 is trivially a multiple of 10), but
    /// reference.lassosoft.com's own worked example
    /// (`[Valid_CreditCard: '0000000000000000']` => `False`) confirms real
    /// Lasso treats it as invalid, so this needs an explicit guard beyond
    /// the bare mathematical checksum.
    static func isValidCreditCard(_ text: String) -> Bool {
        let cleaned = text.filter { $0.isWhitespace == false && $0 != "-" }
        guard cleaned.isEmpty == false, cleaned.allSatisfy(\.isNumber) else { return false }
        guard cleaned.contains(where: { $0 != "0" }) else { return false }
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

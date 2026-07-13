import Foundation

/// `[Currency]`/`[Percent]` — Lasso 8.5 Language Guide Chapter 28 "Math
/// Operations", Table 13 "Locale Formatting Tags". Each takes one
/// required number parameter plus optional positional language/country
/// codes; default is language "en", country "US". `Scientific`/
/// `Locale_Format` (documented siblings in the same table) have zero
/// corpus evidence and are deliberately not implemented this pass,
/// matching this codebase's evidence-gated scope precedent (see
/// `Date_Format`'s own deferred siblings). See
/// `Documentation/outstanding-compatibility-project-plans.md`.
enum LassoNumberFormatting {
    static func format(_ value: Double, style: NumberFormatter.Style, language: String, country: String) -> String {
        // Fresh instance per call — NumberFormatter is not Sendable/
        // thread-safe, and native functions are @Sendable closures that
        // may run across concurrent requests. Never cache or share,
        // matching LassoDateFormatting.formatter(pattern:)'s identical
        // precedent for the same hazard.
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "\(language.lowercased())_\(country.uppercased())")
        formatter.numberStyle = style
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

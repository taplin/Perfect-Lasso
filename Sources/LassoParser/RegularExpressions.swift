import Foundation

/// Backs the `regexp` native type and the `String_FindRegExp`/
/// `String_ReplaceRegExp` free tags — Lasso 8.5 Language Guide Chapter 26
/// "Regular Expressions", verified directly against the PDF (pp. 350-356,
/// Tables 7-9 and 11), including every worked example. Scoped to the
/// "convenience" surface (constructor, accessors, `->ReplaceAll`/
/// `->ReplaceFirst`/`->Split`, and the two `String_*` free tags) —
/// Table 10's "Interactive Find/Replace" tags (`->Find`, `->MatchString`,
/// `->AppendReplacement`, etc., a stateful position-advancing interface
/// for intervening in each replacement as it happens) are a meaningfully
/// larger, separate feature and deliberately left for a follow-up pass.
///
/// Built on `NSRegularExpression` (ICU-backed, available on Linux via
/// swift-corelibs-foundation with no new dependency) rather than a
/// hand-rolled engine — Lasso's own documented wildcard/grouping/
/// combination-symbol vocabulary (Tables 1-6) is standard PCRE/ICU-style
/// syntax, so patterns pass through unmodified.
enum LassoRegularExpressions {
    static func makeRegex(pattern: String, ignoreCase: Bool) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    /// Translates a Lasso replacement pattern's documented group-
    /// placeholder syntax into `NSRegularExpression`'s own template
    /// syntax. Ch. 26 Table 5 "Regular Expression Replacement Symbols"
    /// (p.349) documents TWO equivalent placeholder forms — `\0`-`\9`
    /// AND, per the table's own second Note, a `$0`-`$9` alternate form
    /// — plus a documented `\$` escape for a literal `$` (Note 2: "In
    /// order to place a literal $ in a replacement string it is
    /// necessary to escape it as \$"). `$0`-`$9` already matches
    /// `NSRegularExpression`'s own template dialect exactly and passes
    /// through unmodified; a literal `$`/`\` (bare, or via the
    /// documented `\$` escape) is re-escaped for that dialect
    /// (`NSRegularExpression` uses a leading `\` to mark `$`/`\` as
    /// literal) so it can never be misread as the start of a `$<digit>`
    /// group reference by whatever follows it in the string. The Guide's
    /// own worked examples write group references as `\\1` etc. inside a
    /// Lasso string literal — by the time that string reaches here
    /// (after Lasso's own string-literal escape processing), it's
    /// already a single real backslash followed by a digit, matching
    /// what this function expects.
    static func translateReplacementTemplate(_ lassoReplace: String) -> String {
        let characters = Array(lassoReplace)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "$" {
                if index + 1 < characters.count, characters[index + 1].isNumber {
                    // Table 5's own `$0`-`$9` alternate form — already
                    // valid NSRegularExpression template syntax.
                    result.append(character)
                    result.append(characters[index + 1])
                    index += 2
                } else {
                    result += "\\$"
                    index += 1
                }
            } else if character == "\\" {
                guard index + 1 < characters.count else {
                    result += "\\\\"
                    break
                }
                let next = characters[index + 1]
                if next.isNumber {
                    result += "$\(next)"
                } else if next == "$" || next == "\\" {
                    // The documented `\$` literal-dollar escape (Note 2)
                    // and a literal `\\` — re-escape for
                    // NSRegularExpression's own dialect rather than
                    // emitting the character raw, so a `$` this
                    // produces can't be misread as a group reference if
                    // a digit happens to follow it elsewhere in the
                    // replacement string.
                    result += "\\\(next)"
                } else {
                    result.append(next)
                }
                index += 2
            } else {
                result.append(character)
                index += 1
            }
        }
        return result
    }

    /// `Array/String_FindRegExp` (Ch. 26 Table 11): a single FLAT array
    /// across every match in the source string — for each match, the
    /// full matched text followed by each capture group's text, all
    /// concatenated into one array (not one sub-array per match).
    /// Confirmed by the Guide's own worked example: a 2-group pattern
    /// matching once yields a 3-element array (full + group1 + group2);
    /// a 1-group pattern matching 9 times yields an 18-element array
    /// (full+group1, full+group1, ... — 2 elements per match; the
    /// Guide's own prose on that page says "16 elements", but its own
    /// example array has 18 — the prose is the copy-paste artifact
    /// here, not this implementation).
    ///
    /// A group that didn't participate in a given match (`range(at:)`
    /// returns `NSNotFound`) is represented as `""` rather than omitted
    /// — a reasonable, common convention, but not confirmed against any
    /// worked example in the chapter (none exercise this case).
    static func findAll(in text: String, pattern: String, ignoreCase: Bool) -> [LassoValue] {
        guard let regex = makeRegex(pattern: pattern, ignoreCase: ignoreCase) else { return [] }
        let nsText = text as NSString
        var results: [LassoValue] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            for groupIndex in 0..<match.numberOfRanges {
                let range = match.range(at: groupIndex)
                results.append(.string(range.location == NSNotFound ? "" : nsText.substring(with: range)))
            }
        }
        return results
    }

    /// `String->forEachMatch` (Ch. "String Operations",
    /// operations/strings.html): "Executes a given capture block once
    /// for every match in the base string... The match can be accessed
    /// in the capture block through the special local variable #1" — ONE
    /// element per match, the full matched text only. A genuinely
    /// DIFFERENT contract from `findAll` just above (`String_FindRegExp`'s
    /// own documented "full match + every capture group's text,
    /// flattened") — found by architect + code-reviewer: `forEachMatch`
    /// was originally built on top of `findAll` directly, so any pattern
    /// with a capture group produced extra spurious invocations (the
    /// group text(s)) interleaved with the real per-match ones instead
    /// of one invocation per actual match. This function exists
    /// specifically so `forEachMatch` never touches `findAll`'s own
    /// flattened shape at all.
    static func findAllWholeMatches(in text: String, pattern: String, ignoreCase: Bool) -> [LassoValue] {
        guard let regex = makeRegex(pattern: pattern, ignoreCase: ignoreCase) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map {
            .string(nsText.substring(with: $0.range))
        }
    }

    /// `RegExp->ReplaceAll`/`String_ReplaceRegExp` (no `-ReplaceOnlyOne`).
    static func replaceAll(in text: String, pattern: String, replacement: String, ignoreCase: Bool) -> String {
        guard let regex = makeRegex(pattern: pattern, ignoreCase: ignoreCase) else { return text }
        let nsText = text as NSString
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: translateReplacementTemplate(replacement)
        )
    }

    /// `RegExp->ReplaceFirst`/`String_ReplaceRegExp -ReplaceOnlyOne` — only
    /// the first match is replaced, everything else in the string is
    /// left untouched. `NSRegularExpression` has no built-in "replace
    /// only the first occurrence" convenience, so this finds the first
    /// match manually and splices in its own template-expanded
    /// replacement around it.
    static func replaceFirst(in text: String, pattern: String, replacement: String, ignoreCase: Bool) -> String {
        guard let regex = makeRegex(pattern: pattern, ignoreCase: ignoreCase) else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: fullRange) else { return text }
        let replaced = regex.replacementString(
            for: match,
            in: text,
            offset: 0,
            template: translateReplacementTemplate(replacement)
        )
        let before = nsText.substring(with: NSRange(location: 0, length: match.range.location))
        let after = nsText.substring(
            with: NSRange(location: match.range.location + match.range.length, length: nsText.length - (match.range.location + match.range.length))
        )
        return before + replaced + after
    }

    /// `RegExp->Split` (Ch. 26, "To split a string using a regular
    /// expression"): splits on every match; if the find pattern has
    /// capture groups, each group's text is interleaved into the result
    /// array between the split segments (confirmed by the Guide's own
    /// worked example: `-Find='(\W+)'` on a sentence yields alternating
    /// word/whitespace-punctuation elements, not just the words).
    static func split(_ text: String, pattern: String, ignoreCase: Bool) -> [LassoValue] {
        guard let regex = makeRegex(pattern: pattern, ignoreCase: ignoreCase) else { return [.string(text)] }
        let nsText = text as NSString
        var results: [LassoValue] = []
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let segmentRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            results.append(.string(nsText.substring(with: segmentRange)))
            // Groups 1..<numberOfRanges — group 0 is the whole match,
            // which isn't part of the documented split-with-groups output.
            for groupIndex in 1..<match.numberOfRanges {
                let range = match.range(at: groupIndex)
                results.append(.string(range.location == NSNotFound ? "" : nsText.substring(with: range)))
            }
            lastEnd = match.range.location + match.range.length
        }
        // The final trailing segment is only included when non-empty —
        // confirmed by the Guide's own worked example: splitting "The
        // quick ... lazy dog." on `\W+` (which matches the trailing
        // period, consuming all the way to the string's end) yields an
        // array ending in `(dog)`, not `(dog), ()`. An earlier version
        // appended this segment unconditionally, producing a spurious
        // trailing empty element whenever the input ends exactly at a
        // match — caught by testing against this exact worked example.
        //
        // The leading segment above (appended unconditionally, no
        // matching guard) has no worked example either way in the
        // chapter — a pattern matching at the very start of the input
        // would produce a leading empty-string element. This mirrors
        // the common split-family convention (keep leading empty, drop
        // trailing empty) but is a deliberate, undisclosed-by-the-
        // source default rather than a doc-verified fact.
        if lastEnd < nsText.length {
            results.append(.string(nsText.substring(from: lastEnd)))
        }
        return results
    }
}

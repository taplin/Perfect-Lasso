import Foundation

/// Matchers (Lasso 8.5 Language Guide Ch. 30 Table 22, pp.420-422).
/// Verified directly against the PDF (`pdftotext -layout`) including every
/// worked example: literal-value membership (`(Array:1..7) >> 7`),
/// `Match_Range`/`Match_NotRange`, `Match_RegExp`/`Match_NotRegExp`,
/// `Match_Comparator` (both `-RHS`/`-LHS` forms), and the `->RemoveAll`
/// worked examples for each.
///
/// **Distinct from, but consumed alongside, Comparators** (`Comparators.swift`):
/// "Matchers are used with the […->Iterator], […->RemoveAll]... tags to
/// determine which elements... should be operated on" — a DIFFERENT
/// vocabulary from Comparators' own sort/compare role, even though
/// `Match_Comparator` wraps a Comparator as one of its five kinds.
///
/// **Distinct from RegExp Table 10** (see `RegularExpressions.swift`'s own
/// doc comment): `Match_RegExp`/`Match_NotRegExp` are stateless, one-shot
/// predicate values consumed by `->Contains`/`>>`/`->RemoveAll`/
/// `->Iterator` — NOT the stateful, position-advancing "Interactive
/// Find/Replace" tags (`->Find`/`->MatchString`/`->AppendReplacement`)
/// that remain deliberately deferred there. Confirmed these do not
/// overlap: genuinely new scope.
///
/// **Architecture**: mirrors `LassoComparatorValue`'s own design exactly
/// — `.object`-wrapped constants carrying an enum-tag `_kind`, built by
/// ordinary free-tag constructors (`Match_Range(1, 4)` etc.), consumed by
/// a single shared `matches(_:element:context:)` predicate function. Real
/// Lasso represents even a bare literal (`'Alpha'`, `7`) as a valid
/// matcher too (Table 22's own first row) — `matches` handles that case
/// by falling back to the exact same `LassoCollectionValue.equals`
/// case-insensitive/type-coercing equality every other collection method
/// already uses, so passing a plain non-matcher value to any of the
/// matcher-aware call sites below is a no-op behavior change for existing
/// callers.
enum LassoMatcherValue {
    static let typeName = "matcher"

    static func makeObject(kind: String, data: [String: LassoValue] = [:]) -> LassoObjectInstance {
        var payload = data
        payload["_kind"] = .string(kind)
        return LassoObjectInstance(typeName: typeName, data: payload)
    }

    static func kind(of value: LassoValue) -> String? {
        guard case let .object(instance) = value, instance.typeName == typeName else { return nil }
        let stored = instance.value(for: "_kind").outputString
        return stored.isEmpty ? nil : stored
    }

    /// "Matchers do not return True or False. Matchers generally return
    /// an integer value. A match is signaled by the return value of 0"
    /// (p.420 Note) — this returns the simpler `Bool` equivalent (0 →
    /// `true`) since every consumer in this codebase (`->Contains`/`>>`/
    /// `->RemoveAll`/`->Iterator`) only ever needs match/no-match, never
    /// the raw integer — matching how `LassoComparatorValue`'s own
    /// `isOrderedBefore` similarly simplifies `evaluate`'s raw 0/-1
    /// contract for its own internal Swift consumers.
    ///
    /// "Only the first part of pairs or the key value for maps is
    /// compared" (Table 22's literal-matcher row) — applied UNIFORMLY
    /// here for every matcher kind, not just literals: map/tree-map
    /// entries and pair-arrays always arrive at every call site below as
    /// `.pair(key, value)` regardless of which matcher kind is being
    /// evaluated, and nothing in Table 22 suggests a `Match_Range`/
    /// `Match_RegExp`/etc. matcher should behave differently against a
    /// pair's second half than a literal matcher does.
    ///
    /// **`async throws`, Stage 7b** — was sync/non-throwing before;
    /// still takes `context` BY VALUE (not `inout`), deliberately. Only
    /// the "comparator" case's NEW custom-tag dispatch branch below
    /// needs to actually invoke a tag body (`LassoTagInvocationService`,
    /// Stage 7a), which requires `inout` access — rather than making
    /// `context` `inout` here and rippling that through every one of
    /// this function's ~12-15 call sites across the codebase (List/Set/
    /// TreeMap's native methods, Array/Map's Evaluator cases, `>>`,
    /// Iterator's own matcher-filter), a local mutable COPY is made
    /// only inside that one branch. This is a disclosed, real scope
    /// limit: side effects from WITHIN a custom comparator/matcher
    /// tag's own body (setting a global variable, triggering an
    /// include, logging) do not propagate back out to the caller's
    /// context once the match/sort/filter completes — only the tag's
    /// RETURN VALUE (the actual comparison result) does. A comparator
    /// tag producing such side effects would be unusual regardless
    /// (the Guide's own worked example is pure `Return(-1)`/`Return(0)`
    /// logic, and a comparator may run an unpredictable number of times
    /// during a sort/filter pass, making side effects there ill-advised
    /// in real Lasso code even where technically possible).
    static func matches(_ matcherOrLiteral: LassoValue, element rawElement: LassoValue, context: LassoContext) async throws -> Bool {
        let element: LassoValue
        if case let .pair(key, _) = rawElement {
            element = key
        } else {
            element = rawElement
        }
        guard case let .object(instance) = matcherOrLiteral, let kind = kind(of: matcherOrLiteral) else {
            // Plain literal matcher — "Automatic casting is performed
            // just as it is for the == symbol" (Table 22).
            return LassoCollectionValue.equals(element, matcherOrLiteral, context: context)
        }
        switch kind {
        case "regexp", "notregexp":
            // "If the regular expression matches PART OF a string value
            // then a match is signaled" — a partial/substring match, not
            // a full-string anchor, matching `NSRegularExpression
            // .firstMatch`'s own default (unanchored) behavior.
            let pattern = instance.value(for: "_pattern").outputString
            let text = element.outputString
            guard let regex = LassoRegularExpressions.makeRegex(pattern: pattern, ignoreCase: false) else {
                return false
            }
            let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
            return kind == "regexp" ? found : !found
        case "range", "notrange":
            // "Signals a match if the compared value is equal to either
            // end-value or within the specified range" — inclusive both
            // ends, verified against the numeric worked example
            // (`Match_Range(1,4)` matching 1 and 4 themselves, not just
            // strictly between).
            //
            // Uses the shared `Evaluator.lassoLessThan` — verified against
            // this stage's own Iterator+Matcher worked example (p.426):
            // `Match_Range('a','m')` against `('One','Two','Three',
            // 'Four')` must yield ONLY "Four". `lassoLessThan`'s string
            // bucket is case-insensitive (see its own doc comment), so
            // "four" alphabetically falls within 'a'-'m' while "one"/
            // "two"/"three" do not.
            let low = instance.value(for: "_low")
            let high = instance.value(for: "_high")
            let inRange = !Evaluator.lassoLessThan(element, low) && !Evaluator.lassoLessThan(high, element)
            return kind == "range" ? inRange : !inRange
        case "comparator":
            // "-RHS parameter... used by default to compare the value to
            // each element. The -LHS parameter can be used to instead
            // compare each element to the value" — i.e. RHS given means
            // evaluate(element, RHS); LHS given means evaluate(LHS,
            // element). Verified against both worked examples
            // (`\Compare_LessThan, -RHS=5` → true for every element of
            // `(1,2,3)`; `-LHS=5` → false for the same array, since none
            // of 1,2,3 is greater than 5).
            let comparatorValue = instance.value(for: "_comparator")
            let hasLHS = instance.value(for: "_haslhs").isTruthy
            let lhs = instance.value(for: "_lhs")
            let rhs = instance.value(for: "_rhs")
            // Stage 7b: a genuine custom (non-built-in) `\TagName`
            // reference dispatches for real now — see `matches`'s own
            // doc comment above for the context-by-value/local-copy
            // tradeoff this requires.
            if let customTagName = LassoComparatorValue.customTagName(of: comparatorValue) {
                var mutableContext = context
                let result = hasLHS
                    ? try await LassoComparatorValue.evaluateCustom(tagName: customTagName, left: lhs, right: element, context: &mutableContext)
                    : try await LassoComparatorValue.evaluateCustom(tagName: customTagName, left: element, right: rhs, context: &mutableContext)
                return result == 0
            }
            guard let comparatorKind = LassoComparatorValue.kind(of: comparatorValue) else { return false }
            if hasLHS {
                return LassoComparatorValue.evaluate(kind: comparatorKind, left: lhs, right: element, context: context) == 0
            }
            return LassoComparatorValue.evaluate(kind: comparatorKind, left: element, right: rhs, context: context) == 0
        default:
            return false
        }
    }

    /// Stage 7b: small shared helpers so every one of `matches`'s
    /// ~10 call sites (List/Set/TreeMap's native methods, Array/Map's
    /// Evaluator cases, `>>`, Iterator's own matcher-filter) doesn't
    /// hand-roll the same async-for-loop-in-place-of-a-sync-closure
    /// conversion — `.contains{}`/`.filter{}` can't take an `async`
    /// predicate, so each site would otherwise repeat this by hand.
    static func anyMatches(_ matcherOrLiteral: LassoValue, in elements: [LassoValue], context: LassoContext) async throws -> Bool {
        for element in elements where try await matches(matcherOrLiteral, element: element, context: context) {
            return true
        }
        return false
    }

    static func filterMatching(_ matcherOrLiteral: LassoValue, in elements: [LassoValue], context: LassoContext) async throws -> [LassoValue] {
        var result: [LassoValue] = []
        for element in elements where try await matches(matcherOrLiteral, element: element, context: context) {
            result.append(element)
        }
        return result
    }

    static func filterNotMatching(_ matcherOrLiteral: LassoValue, in elements: [LassoValue], context: LassoContext) async throws -> [LassoValue] {
        var result: [LassoValue] = []
        for element in elements where try await !matches(matcherOrLiteral, element: element, context: context) {
            result.append(element)
        }
        return result
    }

    /// Shared by the `>>` operator fix and any future matcher-aware
    /// membership check that needs to walk an arbitrary compound
    /// value's elements — extracts a flat `[LassoValue]` for every type
    /// this codebase already knows how to iterate, `nil` for anything
    /// else (scalars fall back to their own pre-existing behavior at the
    /// call site, e.g. `>>`'s original string-contains semantics).
    static func iterableElements(of value: LassoValue) -> [LassoValue]? {
        switch value {
        case let .array(values):
            values
        case let .map(values):
            values.keys.sorted().map { .pair(.string($0), values[$0] ?? .null) }
        case let .object(instance) where instance.typeName == LassoTreeMapValue.typeName:
            LassoTreeMapValue.entries(from: instance)
        case let .object(instance) where LassoCollectionValue.typeNames.contains(instance.typeName):
            LassoCollectionValue.elements(from: instance)
        default:
            nil
        }
    }
}

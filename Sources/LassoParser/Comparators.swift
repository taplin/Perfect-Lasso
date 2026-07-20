import Foundation

/// Built-in Comparators (Lasso 8.5 Language Guide Ch. 30 Table 21, p.419)
/// — the sort/compare vocabulary consumed by `PriorityQueue`, `TreeMap`,
/// and `Array->SortWith`/`List->SortWith`. Verified directly against the
/// PDF (`pdftotext -layout`, pp.405-406, 419-420) including every worked
/// example.
///
/// **Scope decision, UPDATED by Stage 6** (see
/// `Documentation/collections-subsystem-plan.md` §3.3): real Lasso passes
/// a comparator by REFERENCE using the `\TagName` bareword syntax
/// (`\Compare_LessThan`, Table 21) — this codebase's parser had no
/// support for that syntax when the 8 built-in comparators first shipped
/// (Stage 2), so they shipped as a stand-in ordinary zero-or-two-argument
/// free-tag form instead: `(Compare_LessThan)` (no parens/args) returns a
/// passable comparator VALUE; `(Compare_LessThan: 1, 2)` (two args)
/// evaluates the comparator directly, matching the Guide's own documented
/// `(Left, Right) -> Integer` contract for a comparator TAG (Table 21's
/// own worked custom-comparator example, p.420, is exactly a `Define_Tag`
/// with this same two-argument shape). **Stage 6 (`TagReference.swift`)
/// now ships real `\identifier` bareword parsing** — `kind(of:)` below
/// recognizes a tag reference naming one of these 8 built-in kinds and
/// treats it identically to the free-tag form, so `\Compare_LessThan`
/// and `(Compare_LessThan)` are now equivalent everywhere a Comparator is
/// consumed. The free-tag form is kept, not removed — real corpus never
/// uses `\`-prefixed syntax (grepped: zero hits across all corpus
/// fixtures) and existing tests/call sites already depend on it.
/// **Stage 7b now dispatches real CUSTOM (user-`Define_Tag`'d)
/// comparators too** — `evaluateCustom(tagName:left:right:context:)`
/// below actually invokes the referenced tag's body via
/// `LassoTagInvocationService` (`Providers.swift`, Stage 7a
/// plumbing), consumed by `LassoMatcherValue.matches`'s "comparator"
/// case for `Match_Comparator`. Still NOT wired into default collection
/// ordering (`PriorityQueue`/`TreeMap` construction, `Array`/
/// `List->Sort`/`->SortWith`) — those stay on the SYNC `evaluate`/
/// `isOrderedBefore` below, which have no async-dispatch path; a custom
/// comparator given there still falls back to natural/lessthan order
/// (Stage 2's own pre-existing "unrecognized comparator" behavior).
/// That's Stage 7c's scope, not this one.
enum LassoComparatorValue {
    static let typeName = "comparator"

    /// The 8 Table 21 kinds, lowercased to match this codebase's
    /// established case-insensitive dispatch convention.
    static let builtInKinds: Set<String> = [
        "lessthan", "greaterthan", "contains", "notcontains",
        "equalto", "notequalto", "strictequalto", "strictnotequalto",
    ]

    static func makeObject(kind: String) -> LassoObjectInstance {
        LassoObjectInstance(typeName: typeName, data: ["_kind": .string(kind)])
    }

    static func kind(of value: LassoValue) -> String? {
        if case let .object(instance) = value, instance.typeName == typeName {
            let stored = instance.value(for: "_kind").outputString
            return stored.isEmpty ? nil : stored
        }
        // `\Compare_LessThan` etc. (Table 21's own bareword-reference
        // syntax, `TagReference.swift`) — recognized identically to the
        // free-tag form `(Compare_LessThan)` above. A tag reference
        // naming anything else (a genuine custom comparator) returns
        // `nil` here — same as any other unrecognized value — see
        // `TagReference.swift`'s own doc comment for why real custom-
        // comparator dispatch is deferred, not silently mishandled.
        if let referencedName = LassoTagReferenceValue.name(of: value) {
            var candidate = referencedName.lowercased()
            if candidate.hasPrefix("compare_") { candidate.removeFirst("compare_".count) }
            return builtInKinds.contains(candidate) ? candidate : nil
        }
        return nil
    }

    /// The as-written tag name from a `\TagName` reference (`kind(of:)`
    /// unwraps and normalizes for a BUILT-IN match; this is its
    /// complement — returns non-`nil` only when the reference does NOT
    /// name a built-in, i.e. a genuine custom comparator). Stage 7b
    /// uses this to dispatch real invocation (`evaluateCustom` below);
    /// every pre-Stage-7b consumer of `kind(of:)` alone still gets
    /// `nil` for a custom reference and falls back to its own existing
    /// "unrecognized comparator" behavior unchanged.
    static func customTagName(of value: LassoValue) -> String? {
        guard let referencedName = LassoTagReferenceValue.name(of: value) else { return nil }
        var candidate = referencedName.lowercased()
        if candidate.hasPrefix("compare_") { candidate.removeFirst("compare_".count) }
        return builtInKinds.contains(candidate) ? nil : referencedName
    }

    /// The Guide's own documented `(Left, Right) -> Integer` contract:
    /// "Comparators do not return True or False... A valid comparison is
    /// signaled by the return value of 0. Any other result signals that
    /// the comparison was not valid" (p.420 Note). `-1` is this project's
    /// choice for "not valid", matching the Note's own worked custom-
    /// comparator example (`Return: -1`) rather than inventing a new
    /// convention.
    static func evaluate(kind: String, left: LassoValue, right: LassoValue, context: LassoContext) -> Int {
        switch kind {
        case "lessthan": Evaluator.lassoLessThan(left, right) ? 0 : -1
        case "greaterthan": Evaluator.lassoLessThan(right, left) ? 0 : -1
        case "equalto": LassoCollectionValue.equals(left, right, context: context) ? 0 : -1
        case "notequalto": !LassoCollectionValue.equals(left, right, context: context) ? 0 : -1
        case "strictequalto": left == right ? 0 : -1
        case "strictnotequalto": left != right ? 0 : -1
        case "contains": left.outputString.contains(right.outputString) ? 0 : -1
        case "notcontains": !left.outputString.contains(right.outputString) ? 0 : -1
        default: -1
        }
    }

    /// Stage 7b: real dispatch for a CUSTOM (`\TagName`-referenced,
    /// user-`Define_Tag`'d) comparator — the counterpart `evaluate`
    /// above never had (custom kinds fell through its `default: -1`).
    /// Invokes the tag with exactly `[left, right]` positional
    /// arguments via `LassoTagInvocationService` (`Providers.swift`,
    /// Stage 7a), matching Table 21's own worked custom-comparator
    /// example (`Define_Tag` with exactly 2 required params). Coerces
    /// the tag's returned `LassoValue` to the same 0/"not 0" contract
    /// `evaluate` documents — a non-numeric return (a malformed
    /// comparator tag) degrades to `-1` ("not valid") rather than
    /// crashing.
    ///
    /// `async throws` — genuinely unlike `evaluate`/`isOrderedBefore`
    /// above, which stay synchronous specifically because they're
    /// still called from inside `sorted(by:)`/`.filter{}`/`.contains{}`
    /// closures elsewhere in this codebase that this stage did not
    /// touch (Stage 7c's own scope, not this one). Only call sites this
    /// stage itself converted to async (`LassoMatcherValue.matches` and
    /// its callers) may call this.
    static func evaluateCustom(
        tagName: String,
        left: LassoValue,
        right: LassoValue,
        context: inout LassoContext
    ) async throws -> Int {
        guard let definition = context.tagRegistry.tag(named: tagName) else {
            throw LassoRuntimeError.unknownFunction(tagName)
        }
        // Extracted to a local `let` before use, per
        // `LassoTagInvocationService`'s own documented Swift-exclusivity
        // requirement (`Providers.swift`) — `context.tagInvocationService?
        // .invoke(..., context: &context)` inline would be overlapping
        // access to the same storage.
        let service = context.tagInvocationService
        guard let service else { throw LassoRuntimeError.tagInvocationNotConfigured }
        let result = try await service.invoke(definition, positionalArguments: [left, right], context: &context)
        return Int(result.number ?? -1)
    }

    /// The internal Swift-`sorted(by:)`-shaped strict-weak-ordering
    /// predicate used by `PriorityQueue`/`TreeMap`/`Array->SortWith`/
    /// `List->SortWith` — a DIFFERENT concept from `evaluate`'s own
    /// 0/-1 "is this pair validly ordered" contract above (which,
    /// notably, doesn't carry enough information to drive a sort by
    /// itself: knowing a pair is "invalid" per LessThan doesn't say
    /// which of the two should come first). Only `lessthan`/
    /// `greaterthan` are documented as genuine sort orders (Table 21:
    /// "Sorts the elements..."); the other 6 are documented as Matcher-
    /// only (Table 21: "Can be used with the matcher to..." — Stage 5
    /// scope). Reusing natural order as the fallback for those 6 here
    /// is a harmless default for an undocumented combination, not a
    /// meaningful implementation of their real semantics as a sort.
    static func isOrderedBefore(kind: String, _ lhs: LassoValue, _ rhs: LassoValue) -> Bool {
        kind == "greaterthan" ? Evaluator.lassoLessThan(rhs, lhs) : Evaluator.lassoLessThan(lhs, rhs)
    }
}

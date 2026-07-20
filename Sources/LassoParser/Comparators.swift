import Foundation

/// Built-in Comparators (Lasso 8.5 Language Guide Ch. 30 Table 21, p.419)
/// — the sort/compare vocabulary consumed by `PriorityQueue`, `TreeMap`,
/// and `Array->SortWith`/`List->SortWith`. Verified directly against the
/// PDF (`pdftotext -layout`, pp.405-406, 419-420) including every worked
/// example.
///
/// **Scope decision** (see `Documentation/collections-subsystem-plan.md`
/// §3.3): real Lasso passes a comparator by REFERENCE using a dedicated
/// `\TagName` bareword syntax (`\Compare_LessThan`) — this codebase's
/// parser has no support for that syntax at all yet (confirmed: zero
/// backslash-tag-reference handling anywhere in `ExpressionParser.swift`)
/// and adding it is explicitly deferred to Stage 6 alongside the more
/// general custom-comparator/custom-matcher `\TagName` mechanism. Per the
/// plan, the 8 BUILT-IN comparators need "NO new parser work" — they ship
/// here as ordinary zero-or-two-argument free tags instead:
/// `(Compare_LessThan)` (no parens/args) returns a passable comparator
/// VALUE, matching how `\Compare_LessThan` is used as an argument
/// elsewhere in this stage (`PriorityQueue: (Compare_LessThan)`,
/// `$array->SortWith(Compare_LessThan)`); `(Compare_LessThan: 1, 2)`
/// (two args) evaluates the comparator directly, matching the Guide's own
/// documented `(Left, Right) -> Integer` contract for a comparator TAG
/// (Table 21's own worked custom-comparator example, p.420, is exactly a
/// `Define_Tag` with this same two-argument shape). Real corpus never
/// uses `\`-prefixed syntax (grepped: zero hits across all corpus
/// fixtures), so this substitution has no known real-world impact.
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
        guard case let .object(instance) = value, instance.typeName == typeName else { return nil }
        let stored = instance.value(for: "_kind").outputString
        return stored.isEmpty ? nil : stored
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

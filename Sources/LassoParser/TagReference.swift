import Foundation

/// `\identifier` bareword tag reference (Ch. 30 Table 21, e.g.
/// `\Compare_LessThan`) — a value that names an already-defined tag
/// (built-in or custom), resolved and invoked later by whatever consumes
/// it, rather than invoked at the reference site itself. See
/// `Documentation/collections-subsystem-plan.md` §3.3 for the design
/// rationale (this is Lasso 8.5's general "pass a callable tag by
/// reference" mechanism, predating Lasso 9's Captures).
///
/// **Scope**: `LassoComparatorValue.kind(of:)` recognizes a tag
/// reference naming one of the 8 built-in comparators (Table 21) and
/// treats it identically to that comparator's own free-tag form
/// (`\Compare_LessThan` ≡ `(Compare_LessThan)`) — wired into every
/// existing built-in-comparator consumer (PriorityQueue/TreeMap
/// construction, Array/List->SortWith, Match_Comparator) with no
/// additional work.
///
/// **Custom (user-`Define_Tag`'d) comparators now dispatch for real,
/// as of Stage 7a+7b**: `LassoTagInvocationService` (`Providers.swift`,
/// Stage 7a) gives a way to invoke a named tag by evaluated arguments
/// from inside a `LassoNativeType.register` closure — the architecture
/// gap this doc comment used to describe as blocking real dispatch.
/// `LassoComparatorValue.evaluateCustom` (Stage 7b) uses it to actually
/// run a `\MyCustomComparator` reference's tag body when consumed via
/// `Match_Comparator`/`LassoMatcherValue.matches`. **Stage 7c extends
/// this to `Array->SortWith`/`List->SortWith`** too, via a hand-rolled
/// async merge sort (`LassoComparatorValue.sortedByCustomComparator`) —
/// Swift's `sorted(by:)` has no async-predicate overload, so a genuine
/// custom comparator couldn't reuse the sync `isOrderedBefore` path.
/// **Still NOT wired into `PriorityQueue`/`TreeMap` construction** —
/// unlike `->SortWith` (a one-shot call given a comparator argument
/// directly), those two types STORE their comparator identity once at
/// construction (as a plain `_kind: String`, with no way to represent
/// "invoke custom tag X") and reuse it across every future `->Insert`;
/// supporting that needs an actual storage-model change to those types,
/// separate scope beyond the sort-algorithm work Stage 7c did. A custom
/// comparator given to `PriorityQueue`/`TreeMap`'s constructor still
/// falls back to Stage 2's own pre-existing "unrecognized comparator
/// value" natural/lessthan-order behavior — unchanged, not a
/// regression. Custom Matchers via `Define_Type`+`onCompare` remain
/// wholly undispatched — still this plan's own highest-risk item,
/// deferred separately (needs an IMPLICIT auto-dispatch trigger, not
/// an explicit call site the way `Match_Comparator`/`->SortWith` are).
enum LassoTagReferenceValue {
    static let typeName = "tagreference"

    static func makeObject(name: String) -> LassoObjectInstance {
        LassoObjectInstance(typeName: typeName, data: ["_name": .string(name)])
    }

    static func name(of value: LassoValue) -> String? {
        guard case let .object(instance) = value, instance.typeName == typeName else { return nil }
        let stored = instance.value(for: "_name").outputString
        return stored.isEmpty ? nil : stored
    }
}

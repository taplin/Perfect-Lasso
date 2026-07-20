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
/// additional work. A tag reference naming a genuinely CUSTOM
/// (user-`Define_Tag`'d) comparator is recognized as a valid reference
/// (evaluating `\MyCustomComparator` does not throw, as long as
/// `MyCustomComparator` is actually defined) but is NOT YET dispatched
/// as a real comparator — every current comparator-consuming call site
/// falls back to its own existing "unrecognized comparator value"
/// behavior (natural/lessthan order), exactly as it already does for any
/// other non-comparator value.
///
/// Real custom-comparator dispatch needs a way to invoke a named tag by
/// evaluated arguments from inside a `LassoNativeType.register` closure
/// (`NativeTypes.swift`'s `LassoNativeMethod` typealias — receiver/
/// arguments/`inout context` only, no access to `Evaluator.renderNodes`,
/// which is what actually runs a tag body). That's a genuine, newly-
/// discovered architecture gap — `LassoNativeMethod`'s signature would
/// need to carry tag-invocation capability, a change touching every
/// already-shipped native-type method table in this codebase (session,
/// web_request, web_response, and every Collections type), not just
/// Collections' own code. Deferred alongside custom Matchers via
/// `onCompare` (already flagged as this plan's highest-risk item) as its
/// own follow-up scoping pass — see plan §5/§6.
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

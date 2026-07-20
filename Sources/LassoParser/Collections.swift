import Foundation

/// `List`/`Queue`/`Stack`/`Set` (Lasso 8.5 Language Guide Ch. 30 "Arrays,
/// Maps, and Compound Data Types", Tables 4/5 List, 12/13 Queue, 15/16
/// Set, 17/18 Stack) plus the `Series` constructor (Table 14). Verified
/// directly against the PDF (`pdftotext -layout`, pp. 397-415) including
/// every worked example.
///
/// **Architecture** (see `Documentation/collections-subsystem-plan.md`
/// §3.1/§3.5 for the full reasoning this follows): each type is an
/// `.object`-wrapped `LassoNativeType`, following the exact same
/// value-semantics-via-`Evaluator.selfMutatingMethods`-write-back
/// discipline `date`/`bytes`/`regexp` already established — mutating
/// methods build and return a NEW `LassoObjectInstance` rather than ever
/// mutating `receiver` in place, avoiding the exact aliasing bug
/// `Date->Add`/`->Subtract` hit and fixed earlier in this project
/// (`NativeTypes.swift`'s own `makeDateType()` doc comment has the full
/// incident writeup).
///
/// **One deliberate, narrow, disclosed exception**: `Queue->Get`/
/// `Stack->Get` genuinely cannot fit that pattern. Every documented
/// mutating method on these types EXCEPT `->Get` is explicitly "Returns
/// no value" (Table 13/18) — exactly what `selfMutatingMethods`'s
/// bare-statement write-back mechanism already exists for. `->Get` is
/// the one exception: it's documented to return the POPPED ELEMENT
/// (not the new collection) and to visibly display that value even as
/// a bare top-level statement (confirmed directly by the Guide's own
/// worked example, p.409: `$myQueue->Get;` alone as a statement prints
/// `One`, not nothing) — `member()`'s return value can't simultaneously
/// BE "the popped element" (needed for that display, and for nested use
/// like `Var('x' = $myQueue->Get)`) AND "the new reduced collection"
/// (needed for `selfMutatingMethods`'s write-back to correctly persist
/// the pop). Since native-type method closures have no way to identify
/// which VARIABLE the receiver came from (only `evaluateStatement`'s
/// AST-level inspection can do that, and only for the exact bare-
/// statement shape), there is no way to thread "write this different
/// value back to the caller's variable" through the existing mechanism.
/// `->Get` alone mutates `receiver` directly instead — a real, narrow
/// re-introduction of the aliasing risk Date's own fix eliminated, but
/// confined to exactly this one method on Queue/Stack: two variables
/// referencing the SAME queue instance (`var(q2 = $q1)`, no intervening
/// `->Insert`/other write-back-triggering call) would both observe a
/// `$q1->Get` pop. No worked example in the chapter exercises that
/// specific scenario either way. `->Insert`/`->Remove`/`->RemoveFirst`
/// (all documented "Returns no value") use the safe pattern like
/// everything else.
enum LassoCollectionValue {
    static func makeObject(typeName: String, elements: [LassoValue]) -> LassoObjectInstance {
        LassoObjectInstance(typeName: typeName, data: ["_elements": .array(elements)])
    }

    static func elements(from receiver: LassoObjectInstance) -> [LassoValue] {
        guard case let .array(values) = receiver.value(for: "_elements") else { return [] }
        return values
    }

    /// The collection types' documented type names that get the
    /// "TypeName: elem1, elem2, elem3" auto-stringification below.
    /// `priorityqueue` reuses this same helper directly — it's stored
    /// under the identical `_elements` data key convention (see
    /// `LassoPriorityQueueValue`) and Table 11's own worked example
    /// (`PriorityQueue: One, Two`, p.406) uses the exact same flat
    /// comma-joined, no-per-element-parens format as List/Queue/Stack.
    static let typeNames: Set<String> = ["list", "queue", "stack", "set", "priorityqueue"]

    /// Bare/`String:`-cast auto-stringification — Ch. 30's own worked
    /// examples show this isn't the generic "just the type name"
    /// fallback every other native type gets (`outputString`'s `.object`
    /// case in Runtime.swift): `[String: $myList]` → `List: Uno, Dos,
    /// Tres, Quatro` (p.399-400), `[String: $myQueue]` → `Queue: One,
    /// Two` (p.409), `[String: $myStack]` → `Stack: One, Two` (p.415).
    /// `Series`, which is intentionally NOT one of these four
    /// object-wrapped types — it stays a plain `.array` per its own
    /// "supports the same member tags as array" design — uses a
    /// different per-element-parens format the Guide shows (`Series:
    /// (1), (2)...`), and that format is deliberately not reproduced
    /// here since Series isn't object-wrapped.
    ///
    /// `Set` is a genuine documentation inconsistency: p.411's own
    /// basic-Insert example shows `Set: (One, Three)` (one wrapping
    /// paren pair around the whole list — indistinguishable from
    /// List/Queue/Stack's flat format for this purpose), but p.412's
    /// three Difference/Intersection/Union examples all consistently
    /// show PER-ELEMENT parens instead — `Set: (Alpha)`, `Set: (Beta),
    /// (Gamma))` (note the dangling extra `)`, itself a defect matching
    /// this project's other found-and-rejected PDF artifacts, e.g.
    /// Math_Div/String->Compare/Bytes->Contains), and `Set: (Alpha),
    /// (Beta), (Gamma), (Delta)`. Verified directly against the PDF
    /// (`pdftotext`, with and without `-layout`, pp.411-412) — not a
    /// text-extraction artifact. Since 3 of the 4 worked examples agree
    /// on per-element parens and the 1 outlier is a single-wrap that's
    /// visually identical to the majority format only by coincidence of
    /// having no way to tell "(One, Three)" apart from a would-be
    /// "(One), (Three)" typo, Set uses per-element parens here.
    /// Naive first-letter capitalization (`list`→`List`) breaks for
    /// `priorityqueue`, which needs internal capitalization too
    /// (`PriorityQueue`, confirmed by its own worked example, p.406:
    /// `➜ PriorityQueue: One, Two`) — a real bug this project's own
    /// test suite caught (`priorityQueueDefaultComparatorReturns...`
    /// initially failed with `Priorityqueue: One, Two`).
    private static let displayNameOverrides: [String: String] = ["priorityqueue": "PriorityQueue"]

    static func autoStringDescription(for receiver: LassoObjectInstance) -> String {
        let prefix = displayNameOverrides[receiver.typeName]
            ?? receiver.typeName.prefix(1).uppercased() + receiver.typeName.dropFirst()
        let values = elements(from: receiver)
        let joined = receiver.typeName == "set"
            ? values.map { "(\($0.outputString))" }.joined(separator: ", ")
            : values.map(\.outputString).joined(separator: ", ")
        return "\(prefix): \(joined)"
    }

    /// `Evaluator.lassoEquals`/`.binary` are `internal` (widened from
    /// `private`) specifically so this file can reuse them — see their
    /// own doc comments in `Evaluator.swift` for why that's safe
    /// (neither reads/mutates `self.context`, so a throwaway
    /// `Evaluator(context:)` built from whatever `LassoContext` a
    /// native-type closure already has on hand is just a cheap value
    /// copy, not aliasing).
    static func equals(_ lhs: LassoValue, _ rhs: LassoValue, context: LassoContext) -> Bool {
        Evaluator(context: context).lassoEquals(lhs, rhs)
    }

    /// Reuses `Array->Sort`'s own battle-tested natural-ordering key —
    /// see `Evaluator.lassoSortKey`'s doc comment for the strict-weak-
    /// ordering/`NaN` edge cases it already guards against. This is
    /// Set's default (only, this stage — built-in `Comparator` values
    /// are Stage 2) sort order, and the ordering `->Sort` uses for
    /// List.
    static func naturalSort(_ values: [LassoValue]) -> [LassoValue] {
        values.sorted { Evaluator.lassoLessThan($0, $1) }
    }
}

/// `PriorityQueue` (Table 10/11, pp. 404-407) — storage is always kept
/// sorted (ascending per its own comparator's `isOrderedBefore`), with
/// `->First`/`->Get` reading from the END (see `makePriorityQueueType()`'s
/// own doc comment for the verified greatest-first-by-default reasoning).
enum LassoPriorityQueueValue {
    static let typeName = "priorityqueue"

    static func makeObject(kind: String, elements: [LassoValue]) -> LassoObjectInstance {
        let sorted = elements.sorted { LassoComparatorValue.isOrderedBefore(kind: kind, $0, $1) }
        return LassoObjectInstance(typeName: typeName, data: ["_kind": .string(kind), "_elements": .array(sorted)])
    }

    static func kind(of receiver: LassoObjectInstance) -> String {
        let stored = receiver.value(for: "_kind").outputString
        return stored.isEmpty ? "lessthan" : stored
    }

    static func elements(from receiver: LassoObjectInstance) -> [LassoValue] {
        guard case let .array(values) = receiver.value(for: "_elements") else { return [] }
        return values
    }

    /// Inserts into the correct sorted position directly (an insertion-
    /// sort step), rather than appending then re-sorting the whole
    /// array on every call — matches the Guide's own description: "it
    /// is automatically placed in the proper position based on its
    /// value in comparison to the elements already within the queue."
    static func inserting(_ value: LassoValue, into receiver: LassoObjectInstance) -> [LassoValue] {
        let comparatorKind = kind(of: receiver)
        var updated = elements(from: receiver)
        let insertIndex = updated.firstIndex { !LassoComparatorValue.isOrderedBefore(kind: comparatorKind, $0, value) }
            ?? updated.count
        updated.insert(value, at: insertIndex)
        return updated
    }

    /// Rebuilds a NEW instance carrying `receiver`'s own comparator kind
    /// forward — following this file's established value-semantics-via-
    /// write-back discipline (never mutate `receiver` in place, except
    /// `->Get`'s own disclosed exception below).
    static func rebuild(from receiver: LassoObjectInstance, elements: [LassoValue]? = nil) -> LassoObjectInstance {
        LassoObjectInstance(
            typeName: typeName,
            data: ["_kind": .string(kind(of: receiver)), "_elements": .array(elements ?? self.elements(from: receiver))]
        )
    }
}

/// `TreeMap` (Table 19/20, pp. 416-419) — see `makeTreeMapType()`'s own
/// doc comment for why `->Insert`/`->Find`/`->Remove`/`->RemoveAll` are
/// NOT registered there and instead special-cased inline in
/// `Evaluator.member`.
enum LassoTreeMapValue {
    static let typeName = "treemap"

    static func makeObject(kind: String, entries: [LassoValue]) -> LassoObjectInstance {
        LassoObjectInstance(
            typeName: typeName,
            data: ["_kind": .string(kind), "_elements": .array(sortEntries(entries, kind: kind))]
        )
    }

    static func kind(of receiver: LassoObjectInstance) -> String {
        let stored = receiver.value(for: "_kind").outputString
        return stored.isEmpty ? "lessthan" : stored
    }

    static func entries(from receiver: LassoObjectInstance) -> [LassoValue] {
        guard case let .array(values) = receiver.value(for: "_elements") else { return [] }
        return values
    }

    static func sortEntries(_ entries: [LassoValue], kind: String) -> [LassoValue] {
        entries.sorted { lhs, rhs in
            guard case let .pair(lhsKey, _) = lhs, case let .pair(rhsKey, _) = rhs else { return false }
            return LassoComparatorValue.isOrderedBefore(kind: kind, lhsKey, rhsKey)
        }
    }

    /// TreeMap-specific key equality — NOT the same as `LassoCollectionValue
    /// .equals`'s loose, `outputString`-based coercion (which List/Set/
    /// Queue/Stack use for their own element comparisons). That
    /// coercion is exactly right for SCALARS — the DaysOfWeek worked
    /// example (p.417) genuinely needs `->Find(2)` (an integer
    /// argument) to match a key that may have been stored as
    /// `.string("2")` (the constructor's own name/value-pair-labeled
    /// form) — but is actively WRONG for compound keys: `.array`'s
    /// `outputString` is a bare no-separator concatenation
    /// (`Runtime.swift`'s `LassoValue.outputString`), so DISTINCT
    /// arrays like `(1, 23)` and `(12, 3)` both stringify to `"123"`
    /// and would be treated as the SAME tree-map key under loose
    /// comparison — a real bug found by code review, confirmed by
    /// reproducing it (`->Insert((array(1,23))='A')` followed by
    /// `->Insert((array(12,3))='B')` collapsed to one entry instead of
    /// two). Compound types (array/map/pair/object) use `LassoValue`'s
    /// own structural `Equatable` conformance instead — cross-type
    /// coercion never makes sense for these anyway (an array key
    /// "equal to" a string key isn't a meaningful concept the way
    /// `2 == '2'` is for scalars).
    static func keysEqual(_ lhs: LassoValue, _ rhs: LassoValue, context: LassoContext) -> Bool {
        switch (lhs, rhs) {
        case (.array, .array), (.map, .map), (.pair, .pair), (.object, .object):
            lhs == rhs
        default:
            LassoCollectionValue.equals(lhs, rhs, context: context)
        }
    }

    /// Insert-or-replace-by-key — "Tree maps can only store one value
    /// per key. When a new value with the same key is inserted... it
    /// replaces the previous value" (p.416), same replace-not-duplicate
    /// semantics as Map.
    static func inserting(key: LassoValue, value: LassoValue, into receiver: LassoObjectInstance, context: LassoContext) -> [LassoValue] {
        var updated = entries(from: receiver)
        if let index = updated.firstIndex(where: { entry in
            guard case let .pair(entryKey, _) = entry else { return false }
            return keysEqual(entryKey, key, context: context)
        }) {
            updated[index] = .pair(key, value)
        } else {
            updated.append(.pair(key, value))
        }
        return sortEntries(updated, kind: kind(of: receiver))
    }

    static func find(key: LassoValue, in receiver: LassoObjectInstance, context: LassoContext) -> LassoValue {
        for entry in entries(from: receiver) {
            if case let .pair(entryKey, entryValue) = entry, keysEqual(entryKey, key, context: context) {
                return entryValue
            }
        }
        return .null
    }

    /// Used by `->Remove` only — a single EXACT-key removal (structurally
    /// can't express "remove several distinct keys at once" the way a
    /// Matcher can; see `removingAllMatchingKey` below for `->RemoveAll`'s
    /// own, now-diverged, Matcher-aware sibling this doc comment
    /// originally deferred to "Stage 5").
    static func removingByKey(_ needle: LassoValue, from receiver: LassoObjectInstance, context: LassoContext) -> [LassoValue] {
        entries(from: receiver).filter { entry in
            guard case let .pair(entryKey, _) = entry else { return true }
            return !keysEqual(entryKey, needle, context: context)
        }
    }

    /// Used by `->RemoveAll` — Table 20's own wording ("the value to
    /// compare to EACH KEY of the map") means it's key-based, not
    /// value-based like Set/List's `->RemoveAll`, AND Matcher-aware
    /// (e.g. `Match_Range` can match several distinct keys in one call,
    /// which `->Remove`'s single-exact-key contract structurally can't
    /// express — the real distinction between these two methods that
    /// `removingByKey` above could only fully realize once Matchers
    /// existed).
    static func removingAllMatchingKey(
        _ matcherOrLiteral: LassoValue, from receiver: LassoObjectInstance, context: LassoContext
    ) async throws -> [LassoValue] {
        // A plain literal key must go through `keysEqual`, NOT
        // `LassoMatcherValue.matches`'s own generic literal fallback
        // (`LassoCollectionValue.equals`, which compares compound values
        // via case-insensitive `outputString` concatenation) — that's
        // exactly the compound-key collision `keysEqual` exists to
        // prevent (e.g. `(array(1,23))` and `(array(12,3))` both
        // stringify to `"123"`), already fixed for `->Remove`/`->Insert`/
        // `->Find` but reintroduced here for `->RemoveAll` until this
        // fix — found by code review. Only route through the
        // Matcher-aware predicate when an actual `Match_*` object is
        // given, so `Match_Range` etc. still work as documented.
        let isMatcherObject = LassoMatcherValue.kind(of: matcherOrLiteral) != nil
        var kept: [LassoValue] = []
        for entry in entries(from: receiver) {
            guard case let .pair(entryKey, _) = entry else {
                kept.append(entry)
                continue
            }
            let matched = isMatcherObject
                ? try await LassoMatcherValue.matches(matcherOrLiteral, element: entryKey, context: context)
                : keysEqual(entryKey, matcherOrLiteral, context: context)
            if !matched { kept.append(entry) }
        }
        return kept
    }

    static func autoStringDescription(for receiver: LassoObjectInstance) -> String {
        let joined = entries(from: receiver).map { entry -> String in
            guard case let .pair(key, value) = entry else { return entry.outputString }
            return "(\(key.outputString))=(\(value.outputString))"
        }.joined(separator: ", ")
        return "TreeMap: \(joined)"
    }
}

extension LassoNativeTypeRegistry {
    // MARK: - list
    //
    // Table 4/5 (pp. 397-399). `->ForEach`/`->InsertFrom`/`->Iterator`/
    // `->ReverseIterator`/`->SortWith` are deliberately deferred
    // (disclosed, not silently dropped): `->ForEach`/`->InsertFrom` need
    // a passable tag-reference value (Stage 6's `\TagName` primitive);
    // `->Iterator`/`->ReverseIterator` need the reference-typed Iterator
    // mechanism (Stage 3); `->SortWith` needs Comparator values
    // (Stage 2). `->Insert`'s documented optional iterator-position
    // parameter (defaulting to the end) is also deferred — implemented
    // here as always-append, matching that documented default, since
    // position-by-iterator needs Stage 3's Iterator too.
    static func makeListType() -> LassoNativeType {
        var type = LassoNativeType(name: "list")

        type.register("contains") { receiver, arguments, context in
            // Ch. 30 Table 22 (p.420-421) — Matcher-aware; falls back to
            // plain coercing equality for a non-matcher argument.
            guard let needle = arguments.first?.value else { return .boolean(false) }
            let elements = LassoCollectionValue.elements(from: receiver)
            return .boolean(try await LassoMatcherValue.anyMatches(needle, in: elements, context: context))
        }
        type.register("difference") { receiver, arguments, context in
            let elements = LassoCollectionValue.elements(from: receiver)
            guard case let .object(other)? = arguments.first?.value else {
                return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
            }
            let otherElements = LassoCollectionValue.elements(from: other)
            let result = elements.filter { element in
                !otherElements.contains { LassoCollectionValue.equals($0, element, context: context) }
            }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: result))
        }
        type.register("find") { receiver, arguments, context in
            // "Returns an ARRAY of elements that match" — a plain
            // `.array`, not a new List, confirmed by Table 5's own
            // wording (distinct from Set->Find, which returns a Set —
            // see `makeSetType()` below).
            guard let needle = arguments.first?.value else { return .array([]) }
            let elements = LassoCollectionValue.elements(from: receiver)
            return .array(try await LassoMatcherValue.filterMatching(needle, in: elements, context: context))
        }
        type.register("first") { receiver, _, _ in
            LassoCollectionValue.elements(from: receiver).first ?? .null
        }
        type.register("second") { receiver, _, _ in
            let elements = LassoCollectionValue.elements(from: receiver)
            return elements.count > 1 ? elements[1] : .null
        }
        type.register("last") { receiver, _, _ in
            LassoCollectionValue.elements(from: receiver).last ?? .null
        }
        type.register("size") { receiver, _, _ in
            .integer(LassoCollectionValue.elements(from: receiver).count)
        }
        type.register("join") { receiver, arguments, _ in
            let separator = arguments.first?.value.outputString ?? ""
            let elements = LassoCollectionValue.elements(from: receiver)
            return .string(elements.map(\.outputString).joined(separator: separator))
        }
        type.register("insert") { receiver, arguments, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value { elements.append(value) }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("insertfirst") { receiver, arguments, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value { elements.insert(value, at: 0) }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("insertlast") { receiver, arguments, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value { elements.append(value) }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("intersection") { receiver, arguments, context in
            let elements = LassoCollectionValue.elements(from: receiver)
            guard case let .object(other)? = arguments.first?.value else {
                return .object(LassoCollectionValue.makeObject(typeName: "list", elements: []))
            }
            let otherElements = LassoCollectionValue.elements(from: other)
            let result = elements.filter { element in
                otherElements.contains { LassoCollectionValue.equals($0, element, context: context) }
            }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: result))
        }
        type.register("union") { receiver, arguments, context in
            var elements = LassoCollectionValue.elements(from: receiver)
            if case let .object(other)? = arguments.first?.value {
                for candidate in LassoCollectionValue.elements(from: other)
                where !elements.contains(where: { LassoCollectionValue.equals($0, candidate, context: context) }) {
                    elements.append(candidate)
                }
            }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("remove") { receiver, arguments, _ in
            // "Accepts an iterator parameter identifying the item to be
            // removed. Defaults to the last item." Iterator-based
            // removal deferred to Stage 3 — only the no-argument
            // (remove-last) form is implemented this stage.
            var elements = LassoCollectionValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeLast() }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("removeall") { receiver, arguments, context in
            guard let needle = arguments.first?.value else {
                return .object(LassoCollectionValue.makeObject(
                    typeName: "list", elements: LassoCollectionValue.elements(from: receiver)
                ))
            }
            let elements = try await LassoMatcherValue.filterNotMatching(
                needle, in: LassoCollectionValue.elements(from: receiver), context: context
            )
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("removefirst") { receiver, _, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeFirst() }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("removelast") { receiver, _, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeLast() }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: elements))
        }
        type.register("reverse") { receiver, _, _ in
            .object(LassoCollectionValue.makeObject(
                typeName: "list", elements: LassoCollectionValue.elements(from: receiver).reversed()
            ))
        }
        type.register("sort") { receiver, arguments, _ in
            // "Sorts in ascending order by default or if the parameter
            // is True and in descending order if the parameter is
            // False" — matches `Array->Sort`'s own documented parameter
            // convention exactly.
            let ascending = arguments.first?.value.isTruthy ?? true
            var sorted = LassoCollectionValue.naturalSort(LassoCollectionValue.elements(from: receiver))
            if !ascending { sorted.reverse() }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: sorted))
        }
        type.register("sortwith") { receiver, arguments, _ in
            // Table 21: same Comparator-driven ordering as
            // `Array->SortWith` (see its own doc comment in
            // `Evaluator.swift` for the worked-example citation) —
            // "Reorders the elements of the list in the order defined
            // by a comparator... Modifies the list in place and returns
            // no value" (Table 5).
            let comparatorArgument: LassoValue = arguments.first?.value ?? .null
            guard let kind = LassoComparatorValue.kind(of: comparatorArgument) else {
                return .object(LassoCollectionValue.makeObject(
                    typeName: "list", elements: LassoCollectionValue.elements(from: receiver)
                ))
            }
            let sorted = LassoCollectionValue.elements(from: receiver)
                .sorted { LassoComparatorValue.isOrderedBefore(kind: kind, $0, $1) }
            return .object(LassoCollectionValue.makeObject(typeName: "list", elements: sorted))
        }
        type.register("iterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: false, matcher: matcher, context: context) ?? .null
        }
        type.register("reverseiterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: true, matcher: matcher, context: context) ?? .null
        }

        return type
    }

    // MARK: - queue
    //
    // Table 12/13 (pp. 407-410), FIFO. See this file's own top-level
    // doc comment for why `->Get` alone mutates `receiver` directly
    // while `->Insert`/`->Remove` use the safe build-new pattern.
    static func makeQueueType() -> LassoNativeType {
        var type = LassoNativeType(name: "queue")

        type.register("first") { receiver, _, _ in
            LassoCollectionValue.elements(from: receiver).first ?? .null
        }
        type.register("size") { receiver, _, _ in
            .integer(LassoCollectionValue.elements(from: receiver).count)
        }
        type.register("insert") { receiver, arguments, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value { elements.append(value) }
            return .object(LassoCollectionValue.makeObject(typeName: "queue", elements: elements))
        }
        type.register("insertlast") { receiver, arguments, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value { elements.append(value) }
            return .object(LassoCollectionValue.makeObject(typeName: "queue", elements: elements))
        }
        type.register("remove") { receiver, _, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeFirst() }
            return .object(LassoCollectionValue.makeObject(typeName: "queue", elements: elements))
        }
        type.register("removefirst") { receiver, _, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeFirst() }
            return .object(LassoCollectionValue.makeObject(typeName: "queue", elements: elements))
        }
        type.register("get") { receiver, _, _ in
            // `receiver.withLock` performs the read-pop-write as ONE
            // atomic critical section (not `value(for:)` then a
            // separate `set(_:for:)`) — composing two separately-locked
            // calls left a lost-update race window where two concurrent
            // `->Get`s on the SAME instance could both read the
            // pre-pop snapshot and the second write would clobber the
            // first, popping only one element for two callers instead
            // of one each. Flagged by swift-concurrency-pro review.
            receiver.withLock("_elements") { stored in
                guard case var .array(elements) = stored, !elements.isEmpty else { return .null }
                let popped = elements.removeFirst()
                stored = .array(elements)
                return popped
            }
        }
        type.register("iterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: false, matcher: matcher, context: context) ?? .null
        }
        type.register("reverseiterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: true, matcher: matcher, context: context) ?? .null
        }

        return type
    }

    // MARK: - stack
    //
    // Table 17/18 (pp. 413-415), LIFO. Same `->Get` exception as Queue
    // above (see this file's own top-level doc comment).
    static func makeStackType() -> LassoNativeType {
        var type = LassoNativeType(name: "stack")

        type.register("first") { receiver, _, _ in
            LassoCollectionValue.elements(from: receiver).last ?? .null
        }
        type.register("size") { receiver, _, _ in
            .integer(LassoCollectionValue.elements(from: receiver).count)
        }
        type.register("insert") { receiver, arguments, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value { elements.append(value) }
            return .object(LassoCollectionValue.makeObject(typeName: "stack", elements: elements))
        }
        type.register("insertfirst") { receiver, arguments, _ in
            // Table 18: "[Stack->Insert] ... Equivalent to a push
            // operation", and `InsertFirst` is documented as its alias
            // — so, like `->Insert`, this APPENDS (the stack's "front"/
            // next-`->Get` position is the array's tail, matching
            // `->First`'s `.last` read above), not `elements.insert(_,
            // at: 0)` like `List->InsertFirst`. Confirmed against
            // reference.lassosoft.com's Stack docs, not just inferred
            // from the name — the same method name means something
            // different here than on List.
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value { elements.append(value) }
            return .object(LassoCollectionValue.makeObject(typeName: "stack", elements: elements))
        }
        type.register("remove") { receiver, _, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeLast() }
            return .object(LassoCollectionValue.makeObject(typeName: "stack", elements: elements))
        }
        type.register("removefirst") { receiver, _, _ in
            var elements = LassoCollectionValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeLast() }
            return .object(LassoCollectionValue.makeObject(typeName: "stack", elements: elements))
        }
        type.register("get") { receiver, _, _ in
            // Atomic read-pop-write — see Queue's own `->Get` comment
            // above for why composing `value(for:)`/`set(_:for:)`
            // separately was a lost-update race.
            receiver.withLock("_elements") { stored in
                guard case var .array(elements) = stored, !elements.isEmpty else { return .null }
                let popped = elements.removeLast()
                stored = .array(elements)
                return popped
            }
        }
        type.register("iterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: false, matcher: matcher, context: context) ?? .null
        }
        type.register("reverseiterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: true, matcher: matcher, context: context) ?? .null
        }

        return type
    }

    // MARK: - set
    //
    // Table 15/16 (pp. 410-412). Elements are always sorted (natural
    // order this stage — built-in `Comparator` constructor parameter is
    // Stage 2) and deduplicated on insert, verified against the Guide's
    // own worked example (inserting "Three" three times yields
    // `Set: (One, Three)`). `->Get`'s documented assignment-target
    // setter form ("can be used as the left parameter of an assignment
    // operator") is deferred to Stage 4 alongside `Pair->First=`/
    // `Stack->First=` — this stage only implements the plain getter.
    // `->ForEach`/`->InsertFrom`/`->Iterator`/`->ReverseIterator`
    // deferred for the same reasons as List's above.
    static func makeSetType() -> LassoNativeType {
        var type = LassoNativeType(name: "set")

        type.register("contains") { receiver, arguments, context in
            // Ch. 30 Table 22 (p.420-421) — Matcher-aware.
            guard let needle = arguments.first?.value else { return .boolean(false) }
            let elements = LassoCollectionValue.elements(from: receiver)
            return .boolean(try await LassoMatcherValue.anyMatches(needle, in: elements, context: context))
        }
        type.register("size") { receiver, _, _ in
            .integer(LassoCollectionValue.elements(from: receiver).count)
        }
        type.register("get") { receiver, arguments, _ in
            // 1-based, read-only this stage (see this function's own
            // doc comment above).
            let elements = LassoCollectionValue.elements(from: receiver)
            let position = (arguments.first?.value.number).map(Int.init) ?? 0
            let index = position - 1
            guard elements.indices.contains(index) else { return .null }
            return elements[index]
        }
        type.register("join") { receiver, arguments, _ in
            let separator = arguments.first?.value.outputString ?? ""
            let elements = LassoCollectionValue.elements(from: receiver)
            return .string(elements.map(\.outputString).joined(separator: separator))
        }
        type.register("find") { receiver, arguments, context in
            // Unlike List->Find (returns a plain array), Set->Find
            // "Returns a SET of elements that match" (Table 16's own
            // wording).
            guard let needle = arguments.first?.value else {
                return .object(LassoCollectionValue.makeObject(typeName: "set", elements: []))
            }
            let elements = try await LassoMatcherValue.filterMatching(
                needle, in: LassoCollectionValue.elements(from: receiver), context: context
            )
            return .object(LassoCollectionValue.makeObject(typeName: "set", elements: elements))
        }
        type.register("insert") { receiver, arguments, context in
            var elements = LassoCollectionValue.elements(from: receiver)
            if let value = arguments.first?.value,
               !elements.contains(where: { LassoCollectionValue.equals($0, value, context: context) }) {
                elements.append(value)
                elements = LassoCollectionValue.naturalSort(elements)
            }
            return .object(LassoCollectionValue.makeObject(typeName: "set", elements: elements))
        }
        type.register("remove") { receiver, arguments, _ in
            // "Accepts a single integer parameter identifying the
            // position of the item to be removed. Defaults to the last
            // item in the set." — position-based, matching
            // `Array->Remove`'s own established convention.
            var elements = LassoCollectionValue.elements(from: receiver)
            let position = (arguments.first?.value.number).map(Int.init) ?? elements.count
            let index = position - 1
            if elements.indices.contains(index) { elements.remove(at: index) }
            return .object(LassoCollectionValue.makeObject(typeName: "set", elements: elements))
        }
        type.register("removeall") { receiver, arguments, context in
            guard let needle = arguments.first?.value else {
                return .object(LassoCollectionValue.makeObject(
                    typeName: "set", elements: LassoCollectionValue.elements(from: receiver)
                ))
            }
            let elements = try await LassoMatcherValue.filterNotMatching(
                needle, in: LassoCollectionValue.elements(from: receiver), context: context
            )
            return .object(LassoCollectionValue.makeObject(typeName: "set", elements: elements))
        }
        type.register("difference") { receiver, arguments, context in
            let elements = LassoCollectionValue.elements(from: receiver)
            guard case let .object(other)? = arguments.first?.value else {
                return .object(LassoCollectionValue.makeObject(typeName: "set", elements: elements))
            }
            let otherElements = LassoCollectionValue.elements(from: other)
            let result = elements.filter { element in
                !otherElements.contains { LassoCollectionValue.equals($0, element, context: context) }
            }
            return .object(LassoCollectionValue.makeObject(typeName: "set", elements: result))
        }
        type.register("intersection") { receiver, arguments, context in
            let elements = LassoCollectionValue.elements(from: receiver)
            guard case let .object(other)? = arguments.first?.value else {
                return .object(LassoCollectionValue.makeObject(typeName: "set", elements: []))
            }
            let otherElements = LassoCollectionValue.elements(from: other)
            let result = elements.filter { element in
                otherElements.contains { LassoCollectionValue.equals($0, element, context: context) }
            }
            return .object(LassoCollectionValue.makeObject(typeName: "set", elements: result))
        }
        type.register("union") { receiver, arguments, context in
            var elements = LassoCollectionValue.elements(from: receiver)
            if case let .object(other)? = arguments.first?.value {
                for candidate in LassoCollectionValue.elements(from: other)
                where !elements.contains(where: { LassoCollectionValue.equals($0, candidate, context: context) }) {
                    elements.append(candidate)
                }
            }
            elements = LassoCollectionValue.naturalSort(elements)
            return .object(LassoCollectionValue.makeObject(typeName: "set", elements: elements))
        }
        type.register("iterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: false, matcher: matcher, context: context) ?? .null
        }
        type.register("reverseiterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: true, matcher: matcher, context: context) ?? .null
        }

        return type
    }

    // MARK: - priorityqueue
    //
    // Table 10/11 (pp. 404-407). "When an element is inserted into a
    // priority queue it is automatically placed in the proper position
    // based on its value in comparison to the elements already within
    // the queue. Only the first or greatest value of the queue can be
    // retrieved" — storage is kept SORTED (via the queue's own
    // comparator, `\Compare_LessThan` by default) on every insert, and
    // `->First`/`->Get` always read from the END of that sorted array.
    //
    // **The greatest-first-by-default gotcha, verified directly against
    // the Guide's own worked examples (p.405-406), not assumed from the
    // comparator's name**: "priority queues pull their next value off
    // the end of the list of contained elements. Using the
    // \Compare_LessThan comparator will result in the GREATEST element
    // being returned first. Using \Compare_GreaterThan will result in
    // the LEAST element being returned first." Confirmed by both worked
    // examples: default comparator, insert One then Two → `->First` is
    // "Two" (greatest, alphabetically); `\Compare_GreaterThan` comparator,
    // same inserts → `->First` is "One" (least). This is exactly why
    // `LassoComparatorValue.isOrderedBefore(kind: "greaterthan", ...)`
    // REVERSES the comparison (produces a descending-sorted array) rather
    // than naively using GreaterThan's own name as the sort direction —
    // reversing it is what makes `.last` correctly yield the least value
    // for that comparator, matching the worked example.
    static func makePriorityQueueType() -> LassoNativeType {
        var type = LassoNativeType(name: "priorityqueue")

        type.register("first") { receiver, _, _ in
            LassoPriorityQueueValue.elements(from: receiver).last ?? .null
        }
        type.register("size") { receiver, _, _ in
            .integer(LassoPriorityQueueValue.elements(from: receiver).count)
        }
        type.register("insert") { receiver, arguments, _ in
            guard let value = arguments.first?.value else {
                return .object(LassoPriorityQueueValue.rebuild(from: receiver))
            }
            let elements = LassoPriorityQueueValue.inserting(value, into: receiver)
            return .object(LassoPriorityQueueValue.rebuild(from: receiver, elements: elements))
        }
        type.register("insertlast") { receiver, arguments, _ in
            guard let value = arguments.first?.value else {
                return .object(LassoPriorityQueueValue.rebuild(from: receiver))
            }
            let elements = LassoPriorityQueueValue.inserting(value, into: receiver)
            return .object(LassoPriorityQueueValue.rebuild(from: receiver, elements: elements))
        }
        type.register("remove") { receiver, _, _ in
            var elements = LassoPriorityQueueValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeLast() }
            return .object(LassoPriorityQueueValue.rebuild(from: receiver, elements: elements))
        }
        type.register("removefirst") { receiver, _, _ in
            var elements = LassoPriorityQueueValue.elements(from: receiver)
            if !elements.isEmpty { elements.removeLast() }
            return .object(LassoPriorityQueueValue.rebuild(from: receiver, elements: elements))
        }
        type.register("get") { receiver, _, _ in
            // Atomic read-pop-write — same lost-update race Queue/
            // Stack->Get already guard against (see their own comments
            // in `makeQueueType()`/`makeStackType()` above).
            receiver.withLock("_elements") { stored in
                guard case var .array(elements) = stored, !elements.isEmpty else { return .null }
                let popped = elements.removeLast()
                stored = .array(elements)
                return popped
            }
        }
        type.register("iterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: false, matcher: matcher, context: context) ?? .null
        }
        type.register("reverseiterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: true, matcher: matcher, context: context) ?? .null
        }

        return type
    }

    // MARK: - treemap
    //
    // Table 19/20 (pp. 416-419). Two real, documented distinctions from
    // plain Map (Evaluator.swift's own `.map` handling): **(1)** keys can
    // be ANY Lasso data type, not string-coerced — **(2)** entries are
    // kept sorted by key via a comparator (default `\Compare_LessThan`,
    // same default as PriorityQueue). Storage mirrors the other
    // collection types (`_elements` under the shared `_elements` data
    // key) but holds `.pair(key, value)` entries instead of bare values,
    // sorted by each pair's `->First` (the key) — reusing
    // `LassoComparatorValue.isOrderedBefore` gives TreeMap's sort-by-
    // comparator behavior for free, no new ordering infrastructure.
    //
    // **Architectural exception, distinct from Queue/Stack->Get's own**:
    // `->Insert`/`->Find`/`->Remove`/`->RemoveAll` are NOT registered as
    // ordinary native-type methods here. The generic `.object` dispatch
    // path (`Evaluator.member`'s `case let (.object(object), _)`)
    // pre-evaluates every argument via `evaluate(arguments)` BEFORE
    // calling a native-type closure — and that pre-evaluation step
    // ALWAYS collapses a `key = value` argument's key down to a bare
    // `String` label (`Evaluator.swift`'s own `evaluate(_
    // arguments:)`, via `assignmentLabel`/the dynamic-field-keyword
    // path), discarding whatever real type the key literal had. That's
    // fine for Map (which string-coerces keys anyway, so no information
    // is lost) but would silently defeat TreeMap's entire "any Lasso
    // data type" key requirement — an integer key `8` would arrive here
    // as the STRING `"8"`, indistinguishable from a real string key.
    // `.map`'s own `->insert`/`->remove` already avoid exactly this trap
    // by being special-cased INLINE in `Evaluator.member`, ahead of the
    // generic dispatch, where the RAW unevaluated `[LassoArgument]` is
    // still available and `.assignment(target, value)`'s `target` can be
    // evaluated directly to recover its real type. TreeMap's
    // `->Insert`/`->Find`/`->Remove`/`->RemoveAll` follow that exact
    // same precedent (see the new cases in `Evaluator.member`, placed
    // immediately before the generic `.map`/`.object` cases) instead of
    // being registered here. `->Get`/`->Keys`/`->Values`/`->Size` need
    // no typed-key argument, so they use the ordinary native-type
    // pattern like every other type in this file.
    static func makeTreeMapType() -> LassoNativeType {
        var type = LassoNativeType(name: "treemap")

        type.register("size") { receiver, _, _ in
            .integer(LassoTreeMapValue.entries(from: receiver).count)
        }
        type.register("keys") { receiver, _, _ in
            .array(LassoTreeMapValue.entries(from: receiver).compactMap {
                if case let .pair(key, _) = $0 { return key }
                return nil
            })
        }
        type.register("values") { receiver, _, _ in
            .array(LassoTreeMapValue.entries(from: receiver).compactMap {
                if case let .pair(_, value) = $0 { return value }
                return nil
            })
        }
        type.register("get") { receiver, arguments, _ in
            // "Returns a PAIR from the tree map by integer position"
            // (Table 20) — matching `Map->Get`'s own identical wording
            // and this codebase's existing sorted-by-key precedent for
            // `Map->Keys`/`->Values` (Evaluator.swift's own doc comment:
            // "the order of elements in a map is not defined"). 1-based.
            let entries = LassoTreeMapValue.entries(from: receiver)
            let position = (arguments.first?.value.number).map(Int.init) ?? 0
            let index = position - 1
            guard entries.indices.contains(index) else { return .null }
            return entries[index]
        }
        type.register("iterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: false, matcher: matcher, context: context) ?? .null
        }
        type.register("reverseiterator") { receiver, arguments, context in
            let matcher = arguments.first?.value
            return try await LassoIteratorValue.build(from: .object(receiver), reverse: true, matcher: matcher, context: context) ?? .null
        }

        return type
    }
}

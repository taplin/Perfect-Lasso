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

    /// The four collection types' documented type names that get the
    /// "TypeName: elem1, elem2, elem3" auto-stringification below.
    static let typeNames: Set<String> = ["list", "queue", "stack", "set"]

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
    static func autoStringDescription(for receiver: LassoObjectInstance) -> String {
        let prefix = receiver.typeName.prefix(1).uppercased() + receiver.typeName.dropFirst()
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
            guard let needle = arguments.first?.value else { return .boolean(false) }
            let elements = LassoCollectionValue.elements(from: receiver)
            return .boolean(elements.contains { LassoCollectionValue.equals($0, needle, context: context) })
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
            return .array(elements.filter { LassoCollectionValue.equals($0, needle, context: context) })
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
            let elements = LassoCollectionValue.elements(from: receiver)
                .filter { !LassoCollectionValue.equals($0, needle, context: context) }
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
            guard let needle = arguments.first?.value else { return .boolean(false) }
            let elements = LassoCollectionValue.elements(from: receiver)
            return .boolean(elements.contains { LassoCollectionValue.equals($0, needle, context: context) })
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
            let elements = LassoCollectionValue.elements(from: receiver)
                .filter { LassoCollectionValue.equals($0, needle, context: context) }
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
            let elements = LassoCollectionValue.elements(from: receiver)
                .filter { !LassoCollectionValue.equals($0, needle, context: context) }
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

        return type
    }
}

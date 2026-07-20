import Foundation

/// `Iterator`/`ReverseIterator` (Lasso 8.5 Language Guide Ch. 30 Tables
/// 23/24, pp. 422-426). Verified directly against the PDF including all
/// three `While`-loop worked examples (array forward, array reverse, map
/// key+value).
///
/// **Architecture, deliberately DIFFERENT from every other type in this
/// file** (see `Documentation/collections-subsystem-plan.md` §3.2): an
/// Iterator genuinely needs live mutable per-call position state tied to
/// one specific traversal — "It has a position and the iterator can be
/// moved forward or backward" (p.422). Every mutating member method here
/// calls `receiver.set(...)` DIRECTLY, unlike the build-new-instance-and-
/// write-back discipline `List`/`Queue`/`Stack`/`Set`/`PriorityQueue`/
/// `TreeMap` all use. This is safe specifically because no real Lasso
/// code is expected to alias one Iterator into two variables and expect
/// independent cursors — the Guide's own worked examples never do this —
/// mirroring the same reasoning already applied to the RegExp Table 10
/// stateful tags (`RegularExpressions.swift`'s own doc comment). Because
/// mutation is unconditional and immediate, NONE of these method names
/// need `Evaluator.selfMutatingMethods` entries: `->Forward`'s own
/// return value (`Bool`) is exactly what should be displayed/discarded
/// as normal — no write-back suppression trick needed, unlike `Queue`/
/// `Stack`/`PriorityQueue->Get`'s narrower exception.
///
/// **Scope decision**: `->RemoveCurrent`/`->InsertAtCurrent` have NO
/// worked example anywhere in Ch. 30 to verify exact behavior against
/// (confirmed: neither name appears in any `<?LassoScript...?>` block in
/// the extracted PDF text, only in Table 24's own terse one-line
/// descriptions). Implemented as best-effort against that literal
/// wording, mutating only the iterator's OWN internal snapshot — NOT
/// propagated back to the live source collection. `Array`/`Map` sources
/// are Swift value types with no addressable identity to write back to
/// regardless (matching this project's established acceptance of similar
/// value-type limits elsewhere), and propagating back to `.object`-typed
/// sources (`List`/`Set`/etc.) reliably, including correctly un-reversing
/// a `ReverseIterator`'s position and re-sorting a `Set`/`TreeMap` after
/// an out-of-order insert, is real unverified new complexity with no
/// primary-source example to check the result against — left as a
/// disclosed gap rather than guessed at.
///
/// **Left/Right/Up/Down and AtFarLeft/AtFarRight/AtTop/AtBottom**:
/// "The iterators for the built-in types only support the
/// forward/backward dimension. The left/right and up/down tags will
/// return False if a move is attempted and the test tags will return
/// True since moving in that dimension is not possible" (p.424,
/// verbatim) — implemented as fixed constants, not stubs pending future
/// work; this really is the documented terminal behavior for every
/// built-in type.
enum LassoIteratorValue {
    static let typeName = "iterator"

    static func makeObject(elements: [LassoValue], hasKeys: Bool) -> LassoObjectInstance {
        LassoObjectInstance(
            typeName: typeName,
            data: ["_elements": .array(elements), "_position": .integer(0), "_haskeys": .boolean(hasKeys)]
        )
    }

    /// Builds an iterator snapshot from any of this project's own
    /// compound types (Table 23's own "e.g. array, list, map, set, and
    /// tree map" is an illustrative, not exhaustive, list — implemented
    /// uniformly across every collection type built in Stages 1-2 for
    /// consistency, since nothing in the Guide actually documents
    /// `Queue`/`Stack`/`PriorityQueue` as EXCLUDED from `->Iterator`
    /// support). `reverse` pre-reverses the snapshot once, up front, so
    /// every member method below can share one forward-only walking
    /// implementation — "[ReverseIterator] The same as [Iterator], but
    /// returns a reverse iterator" (Table 23) needs no separate
    /// backward-walking code path this way.
    static func build(from source: LassoValue, reverse: Bool) -> LassoValue? {
        var elements: [LassoValue]
        var hasKeys = false
        switch source {
        case let .array(values):
            elements = values
        case let .map(values):
            elements = values.keys.sorted().map { .pair(.string($0), values[$0] ?? .null) }
            hasKeys = true
        case let .object(instance) where instance.typeName == LassoTreeMapValue.typeName:
            elements = LassoTreeMapValue.entries(from: instance)
            hasKeys = true
        case let .object(instance) where LassoCollectionValue.typeNames.contains(instance.typeName):
            elements = LassoCollectionValue.elements(from: instance)
        default:
            return nil
        }
        if reverse { elements.reverse() }
        return .object(makeObject(elements: elements, hasKeys: hasKeys))
    }

    static func elements(from receiver: LassoObjectInstance) -> [LassoValue] {
        guard case let .array(values) = receiver.value(for: "_elements") else { return [] }
        return values
    }

    static func position(of receiver: LassoObjectInstance) -> Int {
        Int(receiver.value(for: "_position").number ?? 0)
    }

    static func hasKeys(_ receiver: LassoObjectInstance) -> Bool {
        receiver.value(for: "_haskeys").isTruthy
    }
}

extension LassoNativeTypeRegistry {
    static func makeIteratorType() -> LassoNativeType {
        var type = LassoNativeType(name: LassoIteratorValue.typeName)

        type.register("forward") { receiver, _, _ in
            // "Moves the iterator forward one element. Returns True if
            // the move was successful" — verified against the p.423
            // worked example's own loop shape (`While($myIterator
            // ->atEnd == False)` then `->Value` then `->Forward`,
            // discarding its return via `Null:`), though that example
            // doesn't itself exercise the return value. Interpreted as
            // "landed on a valid (non-end) element", the common
            // iterator-API convention.
            //
            // Reads `_elements`' count and `_position`, then writes a
            // derived `_position` — all under ONE `receiver.withLock`
            // hold, not three separate locked calls. Composing separate
            // `value(for:)`/`set(_:for:)` calls here would reintroduce
            // the exact lost-update race already found and fixed for
            // `Queue`/`Stack`/`PriorityQueue->Get` (two concurrent
            // callers on the SAME instance — no variable aliasing
            // required — could both read the same pre-move snapshot and
            // the second write clobbers the first, silently dropping a
            // move). Flagged by swift-concurrency-pro review, which
            // also confirmed the "no aliasing expected" reasoning this
            // file's own top-level doc comment gives for direct
            // mutation is a SEMANTICS argument, not a concurrency-
            // safety one — it doesn't excuse skipping atomic
            // read-modify-write.
            receiver.withLock { data in
                guard case let .array(elements)? = data["_elements"] else { return .boolean(false) }
                let position = Int(data["_position"]?.number ?? 0)
                guard position < elements.count else { return .boolean(false) }
                let newPosition = position + 1
                data["_position"] = .integer(newPosition)
                return .boolean(newPosition < elements.count)
            }
        }
        type.register("backward") { receiver, _, _ in
            receiver.withLock { data in
                let position = Int(data["_position"]?.number ?? 0)
                guard position > 0 else { return .boolean(false) }
                data["_position"] = .integer(position - 1)
                return .boolean(true)
            }
        }
        type.register("atend") { receiver, _, _ in
            .boolean(LassoIteratorValue.position(of: receiver) >= LassoIteratorValue.elements(from: receiver).count)
        }
        type.register("atbegin") { receiver, _, _ in
            .boolean(LassoIteratorValue.position(of: receiver) <= 0)
        }
        // Left/Right/Up/Down/AtFarLeft/AtFarRight/AtTop/AtBottom — see
        // this file's own top-level doc comment for the verbatim p.424
        // citation these fixed constants come from.
        type.register("left") { _, _, _ in .boolean(false) }
        type.register("right") { _, _, _ in .boolean(false) }
        type.register("up") { _, _, _ in .boolean(false) }
        type.register("down") { _, _, _ in .boolean(false) }
        type.register("atfarleft") { _, _, _ in .boolean(true) }
        type.register("atfarright") { _, _, _ in .boolean(true) }
        type.register("attop") { _, _, _ in .boolean(true) }
        type.register("atbottom") { _, _, _ in .boolean(true) }
        type.register("reset") { receiver, _, _ in
            receiver.set(.integer(0), for: "_position")
            return .void
        }
        type.register("key") { receiver, _, _ in
            let elements = LassoIteratorValue.elements(from: receiver)
            let position = LassoIteratorValue.position(of: receiver)
            guard elements.indices.contains(position), LassoIteratorValue.hasKeys(receiver) else { return .null }
            guard case let .pair(key, _) = elements[position] else { return .null }
            return key
        }
        type.register("value") { receiver, _, _ in
            let elements = LassoIteratorValue.elements(from: receiver)
            let position = LassoIteratorValue.position(of: receiver)
            guard elements.indices.contains(position) else { return .null }
            if LassoIteratorValue.hasKeys(receiver), case let .pair(_, value) = elements[position] {
                return value
            }
            return elements[position]
        }
        type.register("removecurrent") { receiver, _, _ in
            // "Removes the current element... and advances to the next
            // value using [Iterator->Forward]" — taken literally as TWO
            // steps (remove, then also move forward), even though that
            // means the element that shifted into the just-vacated
            // position gets skipped. No worked example exists to verify
            // this against (see this file's own top-level doc comment).
            // Atomic across both `_elements` and `_position` — same
            // reasoning as `->Forward` above.
            return receiver.withLock { data in
                guard case var .array(elements)? = data["_elements"] else { return LassoValue.void }
                let position = Int(data["_position"]?.number ?? 0)
                guard elements.indices.contains(position) else { return .void }
                elements.remove(at: position)
                data["_elements"] = .array(elements)
                if position < elements.count {
                    data["_position"] = .integer(position + 1)
                }
                return .void
            }
        }
        type.register("insertatcurrent") { receiver, arguments, _ in
            // "Inserts an element into the compound data type at the
            // current location" — the new element takes the current
            // slot; position is left unchanged so it now points at the
            // newly-inserted element. Same "no worked example" caveat
            // as `->RemoveCurrent` above.
            guard let value = arguments.first?.value else { return .void }
            return receiver.withLock { data in
                guard case var .array(elements)? = data["_elements"] else { return LassoValue.void }
                let position = Int(data["_position"]?.number ?? 0)
                let insertIndex = min(max(position, 0), elements.count)
                elements.insert(value, at: insertIndex)
                data["_elements"] = .array(elements)
                return .void
            }
        }

        return type
    }
}

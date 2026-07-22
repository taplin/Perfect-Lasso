import Foundation

public final class LassoObjectInstance: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    public let typeName: String
    private var data: [String: LassoValue]

    public init(typeName: String, data: [String: LassoValue] = [:]) {
        self.typeName = typeName
        self.data = Dictionary(uniqueKeysWithValues: data.map { ($0.key.lowercased(), $0.value) })
    }

    public static func == (lhs: LassoObjectInstance, rhs: LassoObjectInstance) -> Bool {
        lhs === rhs
    }

    public func value(for name: String) -> LassoValue {
        lock.lock()
        defer { lock.unlock() }
        return data[name.lowercased()] ?? .null
    }

    public func set(_ value: LassoValue, for name: String) {
        lock.lock()
        defer { lock.unlock() }
        data[name.lowercased()] = value
    }

    public func snapshotData() -> [String: LassoValue] {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    /// Atomic read-modify-write under a single lock hold — for callers
    /// that need to read a value and write a derived value back without
    /// a race window between the two (e.g. `Queue->Get`/`Stack->Get`
    /// popping an element: composing `value(for:)` then `set(_:for:)`
    /// as two separate critical sections lets two concurrent callers
    /// both read the same pre-pop snapshot and clobber each other's
    /// write, silently losing an element instead of popping one each).
    /// `name` is looked up/stored pre-lowercased, matching `value(for:)`
    /// /`set(_:for:)`'s own normalization.
    public func withLock<T>(_ name: String, _ body: (inout LassoValue) -> T) -> T {
        let key = name.lowercased()
        lock.lock()
        defer { lock.unlock() }
        var current = data[key] ?? .null
        let result = body(&current)
        data[key] = current
        return result
    }

    /// Same atomicity guarantee as `withLock(_:_:)` above, but across
    /// the WHOLE data dictionary rather than a single named key — for
    /// callers whose read-modify-write genuinely spans more than one
    /// key at once (e.g. Iterator's `->Forward`/`->RemoveCurrent`,
    /// which must read both `_elements` and `_position` and write a
    /// derived value back to one or both under a single critical
    /// section; composing per-key `withLock(_:_:)` calls would just
    /// reintroduce the same lost-update race window it exists to
    /// close, one level up).
    public func withLock<T>(_ body: (inout [String: LassoValue]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&data)
    }
}

struct LassoResolvedMethod {
    let definition: LassoMethodDefinition
    let evaluatedArguments: [EvaluatedArgument]
}

struct LassoMethodDispatcher {
    static func resolve(
        method name: String,
        on type: LassoTypeDefinition,
        arguments: [EvaluatedArgument]
    ) -> LassoResolvedMethod? {
        let candidates = type.methods
            .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .compactMap { method -> (method: LassoMethodDefinition, score: Int)? in
                guard let score = score(method: method, arguments: arguments) else { return nil }
                return (method, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.method.parameters.count > rhs.method.parameters.count
            }
        guard let selected = candidates.first else { return nil }
        return LassoResolvedMethod(definition: selected.method, evaluatedArguments: arguments)
    }

    private static func score(method: LassoMethodDefinition, arguments: [EvaluatedArgument]) -> Int? {
        let positional = arguments.filter { $0.label == nil }
        // Ch. "Defining Methods" > "Rest Parameters": a rest parameter
        // (`consumeRestParameterMarker`'s `"..."`-labeled argument,
        // guaranteed last per the documented signature grammar) accepts
        // "any number of additional parameters" beyond the fixed ones —
        // it must not count toward `requiredCount`, and the caller's
        // positional count must not be capped at the fixed count.
        let hasRestParameter = method.parameters.last?.label == "..."
        let fixedParameters = hasRestParameter ? Array(method.parameters.dropLast()) : method.parameters
        let requiredCount = fixedParameters.filter { parameter in
            let (_, defaultExpression, _) = parameterMetadata(parameter.value)
            return defaultExpression == nil
        }.count

        guard positional.count >= requiredCount,
              hasRestParameter || positional.count <= fixedParameters.count else {
            return nil
        }

        var score = 0
        for (index, parameter) in fixedParameters.enumerated() {
            let (_, defaultExpression, typeConstraint) = parameterMetadata(parameter.value)
            if index < positional.count {
                if let typeConstraint {
                    guard matches(typeConstraint: typeConstraint, value: positional[index].value) else {
                        return nil
                    }
                    score += (fixedParameters.count - index) * 10
                }
                if defaultExpression == nil {
                    score += 1
                }
            } else if defaultExpression != nil {
                score += 1
            }
        }
        return score
    }

    static func parameterMetadata(
        _ expression: LassoExpression
    ) -> (name: String?, defaultExpression: LassoExpression?, typeConstraint: String?) {
        switch expression {
        case let .assignment(target, value):
            let metadata = parameterMetadata(target)
            return (metadata.name, value, metadata.typeConstraint)
        case let .binary(left, "::", right):
            return (parameterName(left), nil, typeName(right))
        default:
            return (parameterName(expression), nil, nil)
        }
    }

    static func matches(typeConstraint: String, value: LassoValue) -> Bool {
        let normalized = typeConstraint.lowercased()
        if normalized == "any" { return true }
        // Trait constraints (Ch. "Traits" — `trait_searchable`,
        // `trait_positionallykeyed`, etc.) describe an INTERFACE a value
        // must satisfy, not a concrete type name — this codebase has no
        // trait/protocol-conformance system to check structurally
        // against, so (matching the established "type constraints are
        // parsed and discarded where they can't be meaningfully
        // enforced" precedent used elsewhere in this codebase) any
        // `trait_*` constraint is accepted permissively rather than
        // rejecting a real value that would satisfy it. Found live: real
        // corpus (zeroloop/ds's `ds_result.lasso`) declares its own
        // 8-parameter constructor as `index::trait_searchable,
        // cols::trait_positionallykeyed, ...` — rejecting these silently
        // dropped the WHOLE `oncreate` candidate from dispatch (`resolve`
        // filters out any `score(...) == nil` candidate entirely), so
        // `instantiate` found no matching overload and simply never ran
        // it, leaving every data member at its bare `.null` default with
        // no error at all — exactly the kind of silent-wrong-result this
        // project's own conventions try hard to avoid.
        if normalized.hasPrefix("trait_") { return true }
        // `staticarray` is aliased to this codebase's ordinary `.array`
        // runtime representation everywhere else a `staticarray`-typed
        // VALUE is constructed/assigned (see
        // `[[lasso-staticarray-future-enhancement]]`) — a PARAMETER
        // constrained to `::staticarray` must accept the exact same
        // `.array` values that alias already produces, or (same finding
        // as `trait_*` above, same real corpus source) every method
        // declaring one silently never matches.
        if normalized == "staticarray" { return value.typeName == "array" }
        return value.typeName.caseInsensitiveCompare(normalized) == .orderedSame
    }

    private static func parameterName(_ expression: LassoExpression) -> String? {
        switch expression {
        case let .identifier(name), let .string(name):
            return name
        case let .variable(name, _):
            return name
        case let .binary(left, "::", _):
            return parameterName(left)
        default:
            return nil
        }
    }

    private static func typeName(_ expression: LassoExpression) -> String? {
        switch expression {
        case let .identifier(name), let .string(name):
            return name
        default:
            return nil
        }
    }
}

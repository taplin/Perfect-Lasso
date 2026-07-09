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
        let requiredCount = method.parameters.filter { parameter in
            let (_, defaultExpression, _) = parameterMetadata(parameter.value)
            return defaultExpression == nil
        }.count

        guard positional.count >= requiredCount,
              positional.count <= method.parameters.count else {
            return nil
        }

        var score = 0
        for (index, parameter) in method.parameters.enumerated() {
            let (_, defaultExpression, typeConstraint) = parameterMetadata(parameter.value)
            if index < positional.count {
                if let typeConstraint {
                    guard matches(typeConstraint: typeConstraint, value: positional[index].value) else {
                        return nil
                    }
                    score += (method.parameters.count - index) * 10
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

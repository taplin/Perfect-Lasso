import Foundation

struct Evaluator {
    var context: LassoContext
    /// Lets expression evaluation invoke full node rendering (for custom
    /// tag bodies) without `Evaluator` depending on `Renderer.swift`, which
    /// already wraps `Evaluator` — injected by `RendererEngine.init`.
    var renderNodes: ((_ nodes: [LassoNode], _ context: inout LassoContext) throws -> String)? = nil

    mutating func evaluate(_ expression: LassoExpression) throws -> LassoValue {
        switch expression {
        case let .string(value): return .string(value)
        case let .integer(value): return .integer(value)
        case let .decimal(value): return .decimal(value)
        case let .boolean(value): return .boolean(value)
        case .null: return .null
        case let .variable(name, scope): return context.value(for: name, scope: scope)
        case let .identifier(name):
            if name.caseInsensitiveCompare("self") == .orderedSame, let object = context.currentSelf {
                return .object(object)
            }
            if let function = context.natives.function(named: name) {
                return try function([], &context)
            }
            if let definition = context.tagRegistry.tag(named: name) {
                return try invokeCustomTag(definition, callArguments: [])
            }
            return context.value(for: name)
        case let .assignment(target, value):
            let evaluated = try evaluate(value)
            try assign(evaluated, to: target, defaultScope: .unscoped)
            return .void
        case let .unary(op, value):
            return try unary(op, try evaluate(value))
        case let .binary(left, op, right):
            if op == "&&" {
                let lhs = try evaluate(left)
                return lhs.isTruthy ? .boolean(try evaluate(right).isTruthy) : .boolean(false)
            }
            if op == "||" {
                let lhs = try evaluate(left)
                return lhs.isTruthy ? .boolean(true) : .boolean(try evaluate(right).isTruthy)
            }
            return try binary(try evaluate(left), op, try evaluate(right))
        case let .call(callee, arguments):
            guard case let .identifier(name) = callee else {
                throw LassoRuntimeError.unsupportedExpression("Dynamic call")
            }
            if name.caseInsensitiveCompare("var") == .orderedSame ||
                name.caseInsensitiveCompare("local") == .orderedSame {
                return try declare(arguments, local: name.lowercased() == "local")
            }
            if let function = context.natives.function(named: name) {
                return try function(try evaluate(arguments), &context)
            }
            if let type = context.tagRegistry.type(named: name) {
                return try instantiate(type, callArguments: arguments)
            }
            if let definition = context.tagRegistry.tag(named: name) {
                return try invokeCustomTag(definition, callArguments: arguments)
            }
            throw LassoRuntimeError.unknownFunction(name)
        case let .member(base, name, arguments):
            if case let .identifier(baseName) = base {
                return try nativeMember(baseName: baseName, memberName: name, arguments: arguments ?? [])
            }
            return try member(try evaluate(base), name, arguments ?? [])
        case let .unknown(value):
            throw LassoRuntimeError.unsupportedExpression(value)
        }
    }

    private mutating func evaluate(_ arguments: [LassoArgument]) throws -> [EvaluatedArgument] {
        try arguments.map { argument in
            if argument.label == nil,
               case let .assignment(target, value) = argument.value,
               let label = Self.assignmentLabel(target) {
                return EvaluatedArgument(label: label, value: try evaluate(value))
            }
            return EvaluatedArgument(label: argument.label, value: try evaluate(argument.value))
        }
    }

    mutating func evaluateArguments(_ arguments: [LassoArgument]) throws -> [EvaluatedArgument] {
        try evaluate(arguments)
    }

    /// Invokes a compiled custom tag: binds call-site arguments to the
    /// definition's declared parameters in a fresh, isolated local scope
    /// (so the tag body's `#locals` can't leak into or clobber the
    /// caller's), runs the body, and returns whatever `return` produced
    /// (or `.void` if the body never hit one). Any incidental text the body
    /// emits is discarded — a called tag produces a *value*, not output,
    /// mirroring real Lasso method-call semantics.
    private mutating func invokeCustomTag(
        _ definition: LassoCustomTagDefinition,
        callArguments: [LassoArgument]
    ) throws -> LassoValue {
        let evaluatedCallArguments = try evaluate(callArguments)
        let boundLocals = try bindParameters(definition.parameters, to: evaluatedCallArguments)

        let savedLocals = context.snapshotLocals()
        try context.pushTagCall(definition.name)
        context.replaceLocals(boundLocals)
        defer {
            context.replaceLocals(savedLocals)
            context.popTagCall()
        }

        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        _ = try renderNodes(definition.body, &context)
        return context.consumeReturnSignal() ?? .void
    }

    private mutating func bindParameters(
        _ parameters: [LassoArgument],
        to callArguments: [EvaluatedArgument]
    ) throws -> [String: LassoValue] {
        let positional = callArguments.filter { $0.label == nil }
        var positionalIndex = 0
        var bound: [String: LassoValue] = [:]

        for parameter in parameters {
            let (name, defaultExpression) = Self.parameterNameAndDefault(parameter.value)
            guard let name else { continue }

            if let labeled = callArguments.first(where: {
                $0.label?.caseInsensitiveCompare(name) == .orderedSame
            }) {
                bound[name.lowercased()] = labeled.value
            } else if positionalIndex < positional.count {
                bound[name.lowercased()] = positional[positionalIndex].value
                positionalIndex += 1
            } else if let defaultExpression {
                bound[name.lowercased()] = try evaluate(defaultExpression)
            } else {
                bound[name.lowercased()] = .null
            }
        }
        return bound
    }

    private static func parameterNameAndDefault(
        _ expression: LassoExpression
    ) -> (String?, LassoExpression?) {
        let metadata = LassoMethodDispatcher.parameterMetadata(expression)
        return (metadata.name, metadata.defaultExpression)
    }

    private mutating func instantiate(
        _ type: LassoTypeDefinition,
        callArguments: [LassoArgument]
    ) throws -> LassoValue {
        let object = LassoObjectInstance(typeName: type.name)
        for member in type.dataMembers {
            if let defaultValue = member.defaultValue {
                object.set(try evaluate(defaultValue), for: member.name)
            } else {
                object.set(.null, for: member.name)
            }
        }
        if let onCreate = try invokeMemberMethod(
            named: "onCreate",
            on: object,
            type: type,
            arguments: callArguments,
            missingIsVoid: true
        ) {
            _ = onCreate
        }
        return .object(object)
    }

    private mutating func invokeMemberMethod(
        named name: String,
        on object: LassoObjectInstance,
        type: LassoTypeDefinition,
        arguments: [LassoArgument],
        missingIsVoid: Bool = false
    ) throws -> LassoValue? {
        let evaluatedCallArguments = try evaluate(arguments)
        guard let resolved = LassoMethodDispatcher.resolve(
            method: name,
            on: type,
            arguments: evaluatedCallArguments
        ) else {
            if missingIsVoid { return .void }
            return nil
        }
        let boundLocals = try bindParameters(resolved.definition.parameters, to: resolved.evaluatedArguments)
        let savedLocals = context.snapshotLocals()
        context.replaceLocals(boundLocals)
        context.pushSelf(object)
        defer {
            context.popSelf()
            context.replaceLocals(savedLocals)
        }

        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        _ = try renderNodes(resolved.definition.body, &context)
        return context.consumeReturnSignal() ?? .void
    }

    private mutating func declare(_ arguments: [LassoArgument], local: Bool) throws -> LassoValue {
        let scope: VariableScope = local ? .local : .global
        for argument in arguments {
            guard case let .assignment(target, value) = argument.value else { continue }
            let evaluated = try evaluate(value)
            try assign(evaluated, to: target, defaultScope: scope)
        }
        return .void
    }

    private mutating func assign(
        _ value: LassoValue,
        to target: LassoExpression,
        defaultScope: VariableScope
    ) throws {
        switch target {
        case let .binary(left, "::", _):
            try assign(value, to: left, defaultScope: defaultScope)
        case let .variable(name, scope):
            context.set(value, for: name, scope: scope == .unscoped ? defaultScope : scope)
        case let .identifier(name):
            context.set(value, for: name, scope: defaultScope)
        case let .string(name):
            context.set(value, for: name, scope: defaultScope)
        case let .member(base, name, _):
            let baseValue: LassoValue
            if case let .identifier(baseName) = base,
               baseName.caseInsensitiveCompare("self") == .orderedSame,
               let object = context.currentSelf {
                baseValue = .object(object)
            } else {
                baseValue = try evaluate(base)
            }
            guard case let .object(object) = baseValue else {
                throw LassoRuntimeError.invalidAssignment
            }
            object.set(value, for: name)
        default:
            throw LassoRuntimeError.invalidAssignment
        }
    }

    private func unary(_ op: String, _ value: LassoValue) throws -> LassoValue {
        switch op.lowercased() {
        case "!", "not": .boolean(!value.isTruthy)
        case "-": .decimal(-(value.number ?? 0))
        case "+": .decimal(value.number ?? 0)
        default: throw LassoRuntimeError.unsupportedExpression("Unary \(op)")
        }
    }

    private func binary(_ left: LassoValue, _ op: String, _ right: LassoValue) throws -> LassoValue {
        switch op {
        case "+":
            if case .string = left { return .string(left.outputString + right.outputString) }
            if case .string = right { return .string(left.outputString + right.outputString) }
            return numeric(left, right, +)
        case "-": return numeric(left, right, -)
        case "*": return numeric(left, right, *)
        case "/": return numeric(left, right, /)
        case "%": return .integer(Int(left.number ?? 0) % max(Int(right.number ?? 0), 1))
        case "==": return .boolean(left.outputString == right.outputString)
        case "!=": return .boolean(left.outputString != right.outputString)
        case ">", ">>": return compare(left, right, >)
        case "<": return compare(left, right, <)
        case ">=": return compare(left, right, >=)
        case "<=": return compare(left, right, <=)
        default: throw LassoRuntimeError.unsupportedExpression("Binary \(op)")
        }
    }

    private func numeric(
        _ left: LassoValue,
        _ right: LassoValue,
        _ operation: (Double, Double) -> Double
    ) -> LassoValue {
        let result = operation(left.number ?? 0, right.number ?? 0)
        return result.rounded() == result ? .integer(Int(result)) : .decimal(result)
    }

    private func compare(
        _ left: LassoValue,
        _ right: LassoValue,
        _ operation: (Double, Double) -> Bool
    ) -> LassoValue {
        if let lhs = left.number, let rhs = right.number { return .boolean(operation(lhs, rhs)) }
        return .boolean(operation(Double(left.outputString.count), Double(right.outputString.count)))
    }

    private mutating func member(
        _ base: LassoValue,
        _ name: String,
        _ arguments: [LassoArgument]
    ) throws -> LassoValue {
        let normalized = name.lowercased()
        switch (base, normalized) {
        case let (.string(value), "size"): return .integer(value.count)
        case let (.string(value), "uppercase"): return .string(value.uppercased())
        case let (.string(value), "lowercase"): return .string(value.lowercased())
        case let (.string(value), "asstring"): return .string(value)
        case let (.string(value), "encodehtml"): return .string(value.htmlEncoded)
        case let (.string(value), "encodeurl"):
            return .string(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)
        case let (.string(value), "contains"):
            let needle = try arguments.first.map { try evaluate($0.value).outputString } ?? ""
            return .boolean(value.contains(needle))
        case let (.string(value), "split"):
            let separator = try arguments.first.map { try evaluate($0.value).outputString } ?? ""
            return .array(value.components(separatedBy: separator).map(LassoValue.string))
        case let (.array(values), "size"): return .integer(values.count)
        case let (.array(values), "get"):
            let requested = try arguments.first.map { try evaluate($0.value).number } ?? 1
            let index = max(Int(requested ?? 1) - 1, 0)
            return values.indices.contains(index) ? values[index] : .null
        case let (.map(values), _): return values[normalized] ?? .null
        case let (.object(object), _):
            guard let type = context.tagRegistry.type(named: object.typeName) else {
                return object.value(for: name)
            }
            if let value = try invokeMemberMethod(named: name, on: object, type: type, arguments: arguments) {
                return value
            }
            return object.value(for: name)
        default: throw LassoRuntimeError.unsupportedExpression("Member \(name)")
        }
    }

    private mutating func nativeMember(
        baseName: String,
        memberName: String,
        arguments: [LassoArgument]
    ) throws -> LassoValue {
        let base = baseName.lowercased()
        let normalizedMember = memberName.lowercased()
        let evaluated = try evaluate(arguments)
        let first = evaluated.first?.value.outputString ?? ""

        switch (base, normalizedMember) {
        case ("web_request", "param"):
            return context.requestProvider?.parameter(named: first) ?? .null
        case ("web_request", "params"):
            return .map(context.requestProvider?.parameters ?? [:])
        case ("web_request", "header"):
            return context.requestProvider?.header(named: first) ?? .null
        case ("web_request", "cookie"):
            return context.requestProvider?.cookie(named: first) ?? .null
        case ("session", "value"), ("session", "get"):
            return context.sessionProvider?.value(for: first) ?? .null
        case ("web_response", "replaceheader"):
            return .void
        default:
            return try member(try evaluate(.identifier(baseName)), memberName, arguments)
        }
    }

    private static func assignmentLabel(_ expression: LassoExpression) -> String? {
        switch expression {
        case let .identifier(name), let .string(name):
            return name
        case let .variable(name, _):
            return name
        case let .binary(left, "::", _):
            return assignmentLabel(left)
        default:
            return nil
        }
    }
}

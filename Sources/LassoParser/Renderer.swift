public struct LassoRenderer: Sendable {
    public init() {}

    public func render(_ source: String, context: inout LassoContext) throws -> String {
        let document = LassoParser().parse(source)
        return try render(document, context: &context)
    }

    public func render(_ document: LassoDocument, context: inout LassoContext) throws -> String {
        var engine = RendererEngine(context: context)
        let output = try engine.render(document.nodes)
        context = engine.evaluator.context
        return output
    }
}

private struct RendererEngine {
    var evaluator: Evaluator

    init(context: LassoContext) {
        evaluator = Evaluator(context: context)
    }

    mutating func render(_ nodes: [LassoNode]) throws -> String {
        var output = ""
        for node in nodes {
            switch node {
            case let .text(text, _):
                output += text
            case let .expression(expression, _, _, _):
                if case let .identifier(name) = expression, name.lowercased() == "no_square_brackets" {
                    continue
                }
                output += try renderExpression(expression)
            case let .code(expressions, _, _, _):
                for expression in expressions {
                    output += try renderExpression(expression)
                }
            case let .block(name, arguments, body, alternate, _, _):
                output += try renderBlock(
                    name: name,
                    arguments: arguments,
                    body: body,
                    alternate: alternate
                )
            case .tag:
                continue
            }
        }
        return output
    }

    private mutating func renderBlock(
        name: String,
        arguments: [LassoArgument],
        body: [LassoNode],
        alternate: [LassoNode]?
    ) throws -> String {
        switch name.lowercased() {
        case "if":
            let condition = try arguments.first.map { try evaluator.evaluate($0.value) } ?? .boolean(false)
            return condition.isTruthy ? try render(body) : try render(alternate ?? [])
        case "loop":
            let count: Int
            if let argument = arguments.first {
                count = Int(try evaluator.evaluate(argument.value).number ?? 0)
            } else {
                count = 0
            }
            var output = ""
            if count > 0 {
                for iteration in 1...count {
                    evaluator.context.set(.integer(iteration), for: "loop_count", scope: .local)
                    output += try render(body)
                }
            }
            return output
        case "while":
            var output = ""
            var iterations = 0
            while iterations < 10_000 {
                let condition = try arguments.first.map { try evaluator.evaluate($0.value) } ?? .boolean(false)
                if !condition.isTruthy { break }
                output += try render(body)
                iterations += 1
            }
            return output
        case "protect":
            return try render(body)
        case "inline":
            guard let inlineProvider = evaluator.context.inlineProvider else {
                throw LassoRuntimeError.inlineNotConfigured
            }
            let frame = try inlineProvider.executeInline(
                arguments: try evaluator.evaluateArguments(arguments),
                context: evaluator.context
            )
            evaluator.context.pushInlineFrame(frame)
            evaluator.context.set(.array(frame.rows.map { .map($0.mapValue) }), for: "records_map", scope: .local)
            defer { evaluator.context.popInlineFrame() }
            return try render(body)
        case "records", "rows":
            guard let frame = evaluator.context.currentInlineFrame else { return "" }
            var output = ""
            for (index, row) in frame.rows.enumerated() {
                evaluator.context.setCurrentRow(row)
                evaluator.context.set(.integer(index + 1), for: "record_count", scope: .local)
                evaluator.context.set(.integer(index + 1), for: "row_count", scope: .local)
                output += try render(body)
            }
            evaluator.context.setCurrentRow(nil)
            return output
        case "iterate":
            let values: [LassoValue]
            if let argument = arguments.first {
                switch try evaluator.evaluate(argument.value) {
                case let .array(items): values = items
                case let .map(items): values = items.values.map { $0 }
                case .void, .null: values = []
                case let value: values = [value]
                }
            } else {
                values = []
            }
            var output = ""
            for (index, value) in values.enumerated() {
                evaluator.context.set(value, for: "loop_value", scope: .local)
                evaluator.context.set(.integer(index + 1), for: "loop_count", scope: .local)
                output += try render(body)
            }
            return output
        default:
            if let function = evaluator.context.natives.function(named: name) {
                _ = try function(try evaluator.evaluateArguments(arguments), &evaluator.context)
            }
            return try render(body)
        }
    }

    private mutating func renderExpression(_ expression: LassoExpression) throws -> String {
        if case let .call(callee, arguments) = expression,
           case let .identifier(name) = callee,
           name.caseInsensitiveCompare("include") == .orderedSame {
            return try renderInclude(arguments)
        }
        return try evaluator.evaluate(expression).outputString
    }

    private mutating func renderInclude(_ arguments: [LassoArgument]) throws -> String {
        guard let loader = evaluator.context.includeLoader else {
            throw LassoRuntimeError.includeNotConfigured
        }
        let evaluated = try evaluator.evaluateArguments(arguments)
        let path = evaluated.firstValue(named: "file")?.outputString ??
            evaluated.firstValue(named: "path")?.outputString ??
            evaluated.first?.value.outputString ?? ""
        guard !evaluator.context.includeStack.contains(path) else {
            throw LassoRuntimeError.includeCycle(path)
        }
        guard evaluator.context.includeStack.count < 32 else {
            throw LassoRuntimeError.includeDepthExceeded
        }

        let previousPath = evaluator.context.includePath
        evaluator.context.includeStack.append(path)
        evaluator.context.includePath = path
        defer {
            evaluator.context.includePath = previousPath
            _ = evaluator.context.includeStack.popLast()
        }

        let source = try loader.loadInclude(path: path, from: previousPath)
        return try render(LassoParser().parse(source).nodes)
    }
}

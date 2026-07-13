public struct LassoRenderer: Sendable {
    public init() {}

    public func render(_ source: String, context: inout LassoContext) throws -> String {
        let document = LassoParser().parse(source)
        return try render(document, context: &context)
    }

    public func render(_ document: LassoDocument, context: inout LassoContext) throws -> String {
        var engine = RendererEngine(context: context)
        var output = try engine.render(document.nodes)
        // A `return` at page/include level (not inside a called custom tag,
        // which already consumes its own signal) contributes its value to
        // the page's output — the same behavior `<?lassoscript ... return
        // json_serialize(...) ?>`-style API pages already relied on before
        // `return` gained real short-circuiting control flow.
        if let returned = engine.evaluator.context.consumeReturnSignal() {
            output += returned.outputString
        }
        engine.evaluator.context.finalizeSessions()
        context = engine.evaluator.context
        return output
    }
}

private struct RendererEngine {
    var evaluator: Evaluator

    init(context: LassoContext) {
        evaluator = Evaluator(context: context)
        evaluator.renderNodes = { nodes, context in
            var engine = RendererEngine(context: context)
            let output = try engine.render(nodes)
            context = engine.evaluator.context
            return output
        }
        if evaluator.context.includeRenderService == nil {
            evaluator.context.includeRenderService = RendererIncludeService()
        }
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
                    if evaluator.context.returnSignal != nil { break }
                }
            case let .block(name, arguments, body, alternate, _, _):
                output += try renderBlock(
                    name: name,
                    arguments: arguments,
                    body: body,
                    alternate: alternate
                )
            case let .typeDefinition(definition, _, _):
                evaluator.context.tagRegistry.registerType(definition)
            case .tag:
                continue
            }
            if evaluator.context.returnSignal != nil { break }
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
            // Catches only LassoRecoverableError — real Lasso failures a page
            // is expected to inspect and continue past (failed database
            // actions, etc.). Deliberately does NOT catch the returnSignal
            // short-circuit `return`/`abort` use (that's Swift control flow,
            // not a thrown error, so it already passes through untouched)
            // and does NOT catch LassoRuntimeError or any other fatal
            // adapter/parser error — those stay fatal per
            // Documentation/error-protect-model-plan.md's three-way split.
            // Conservative first-pass output behavior: a protected body that
            // fails partway discards everything it had already rendered up
            // to the failure point, since it's unconfirmed real Lasso
            // preserves partial protected-block output (see the plan's open
            // question) — safer to under-output than to guess and be wrong.
            do {
                let output = try render(body)
                evaluator.context.clearError()
                return output
            } catch let recoverable as LassoRecoverableError {
                evaluator.context.setError(recoverable.state)
                return ""
            }
        case "define":
            guard case let .string(tagName)? = arguments.first?.value else { return "" }
            evaluator.context.tagRegistry.registerTag(LassoCustomTagDefinition(
                name: tagName,
                parameters: Array(arguments.dropFirst()),
                body: body
            ))
            return ""
        case "define_tag":
            // A standalone legacy custom tag (`Define_Tag('name', -flags)
            // ... /Define_Tag`), reusing the exact model modern `define`
            // already registers with — see LegacyDefinitions.swift and
            // Documentation/legacy-define-tag-type-plan.md. A `define_tag`
            // nested inside a `define_type` body never reaches here: the
            // "define_type" case below walks its own body directly rather
            // than delegating to this generic block-name switch.
            guard case let .string(tagName)? = arguments.first?.value else { return "" }
            evaluator.context.tagRegistry.registerTag(LassoCustomTagDefinition(
                name: tagName,
                parameters: LegacyDefinitions.translateParameters(Array(arguments.dropFirst())),
                body: body
            ))
            return ""
        case "define_type":
            // `Define_Type('name', ...) ... /Define_Type` — legacy parenthesized
            // or colon-call type definition. Any positional string arguments
            // after the name (parent/base type names) and flags like
            // -Prototype are parsed but not yet acted on (deferred — see
            // Documentation/legacy-define-tag-type-plan.md's "Recommended
            // Scope Boundaries"). The body is walked directly (not rendered)
            // so nested define_tag blocks become methods, not standalone tags.
            guard case let .string(typeName)? = arguments.first?.value else { return "" }
            let lowered = LegacyDefinitions.lowerTypeBody(body)
            evaluator.context.tagRegistry.registerType(LassoTypeDefinition(
                name: typeName,
                dataMembers: lowered.dataMembers,
                methods: lowered.methods
            ))
            return ""
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
        case "with":
            // `with name in <expr> do { ... }` — same array/map/scalar
            // iteration as `iterate`, but binding whatever variable name
            // the source used (carried as arguments[0]) instead of the
            // fixed `loop_value`.
            guard arguments.count >= 2, case let .string(variableName) = arguments[0].value else {
                return ""
            }
            let withValues: [LassoValue]
            switch try evaluator.evaluate(arguments[1].value) {
            case let .array(items): withValues = items
            case let .map(items): withValues = items.values.map { $0 }
            case .void, .null: withValues = []
            case let value: withValues = [value]
            }
            var withOutput = ""
            for value in withValues {
                evaluator.context.set(value, for: variableName, scope: .local)
                withOutput += try render(body)
            }
            return withOutput
        case "output_none":
            // Processes the tags within (side effects like var()/local()
            // assignments still happen — `render(body)` evaluates
            // everything normally) but hides the rendered text from the
            // page, per Lasso 8.5 Language Guide Chapter 14's "Table 1:
            // Output Tags". See Documentation/output-tags-plan.md.
            _ = try render(body)
            return ""
        case "html_comment":
            // Wraps the body's rendered output in an HTML comment — the
            // contents still reach the client (visible via "View Source")
            // but aren't part of the visible page.
            return "<!--\(try render(body))-->"
        case "encode_set":
            // Changes the default encoding for nested `Output` calls
            // (those with no -Encode* keyword of their own) for the
            // duration of the body — see LassoEncoding.keyword(in:) and
            // the `output` native. An unrecognized/missing keyword falls
            // through to rendering the body with no override, matching
            // this interpreter's existing "unknown flag ignored, not
            // fatal" convention elsewhere.
            let evaluatedArguments = try evaluator.evaluateArguments(arguments)
            if let keyword = LassoEncoding.keyword(in: evaluatedArguments) {
                evaluator.context.encodingOverrideStack.append(keyword)
                defer { evaluator.context.encodingOverrideStack.removeLast() }
                return try render(body)
            }
            return try render(body)
        default:
            if let function = evaluator.context.natives.function(named: name) {
                _ = try function(try evaluator.evaluateArguments(arguments), &evaluator.context)
            }
            return try render(body)
        }
    }

    private mutating func renderExpression(_ expression: LassoExpression) throws -> String {
        if case let .call(callee, arguments) = expression,
           case let .identifier(name) = callee {
            if name.caseInsensitiveCompare("include") == .orderedSame {
                return try renderInclude(arguments)
            }
            if name.caseInsensitiveCompare("library") == .orderedSame {
                try renderLibrary(arguments)
                return ""
            }
        }
        return try evaluator.evaluate(expression).outputString
    }

    /// Loads and runs a library exactly once per path *for this request's
    /// render* (`evaluator.context.loadedLibraries`, not the shared
    /// `tagRegistry`) — repeat calls for an already-loaded path within the
    /// same render are no-ops, matching LassoSoft's own `library_once`
    /// documentation ("if used multiple times referencing the same Lasso
    /// page then only the first will actually perform the include"). Tag/
    /// type definitions the library registers land on the shared
    /// `tagRegistry` and so persist process-wide as normal, but any other
    /// top-level executable code in the file (e.g. a per-request check like
    /// a bot-exclusion redirect) genuinely re-runs on every new request,
    /// since `loadedLibraries` starts empty on every fresh `LassoContext`.
    /// The library's own text output, if any, is intentionally discarded.
    private mutating func renderLibrary(_ arguments: [LassoArgument]) throws {
        let evaluated = try evaluator.evaluateArguments(arguments)
        let path = evaluated.firstValue(named: "file")?.outputString ??
            evaluated.firstValue(named: "path")?.outputString ??
            evaluated.first?.value.outputString ?? ""
        guard let service = evaluator.context.includeRenderService else {
            throw LassoRuntimeError.includeNotConfigured
        }
        try service.performLibrary(path: path, once: true, context: &evaluator.context)
    }

    private mutating func renderInclude(_ arguments: [LassoArgument]) throws -> String {
        let evaluated = try evaluator.evaluateArguments(arguments)
        let path = evaluated.firstValue(named: "file")?.outputString ??
            evaluated.firstValue(named: "path")?.outputString ??
            evaluated.first?.value.outputString ?? ""
        guard let service = evaluator.context.includeRenderService else {
            throw LassoRuntimeError.includeNotConfigured
        }
        return try service.performInclude(path: path, once: false, context: &evaluator.context) ?? ""
    }
}

/// Concrete `LassoIncludeRenderService` conformer — the only place that
/// can reconstruct a `RendererEngine` to actually render loaded nodes.
/// Wired onto every context by `RendererEngine.init`, the same
/// underlying trick as `evaluator.renderNodes` (`Renderer.swift:29-37`),
/// exposed as a protocol conformer instead of a bare closure so
/// evaluator-level native type methods (`web_response->include*`, which
/// only see `LassoContext`, not an `Evaluator`) can reach it too.
struct RendererIncludeService: LassoIncludeRenderService {
    func performInclude(path: String, once: Bool, context: inout LassoContext) throws -> String? {
        guard let loader = context.includeLoader else {
            throw LassoRuntimeError.includeNotConfigured
        }
        if once {
            guard context.includedOncePaths.insert(path).inserted else { return nil }
        }
        guard !context.includeStack.contains(path) else {
            throw LassoRuntimeError.includeCycle(path)
        }
        guard context.includeStack.count < 32 else {
            throw LassoRuntimeError.includeDepthExceeded
        }

        let previousPath = context.includePath
        context.includeStack.append(path)
        context.includePath = path
        defer {
            context.includePath = previousPath
            _ = context.includeStack.popLast()
        }

        // Always read the source — it's the only way to detect a change,
        // since LassoIncludeLoader exposes no separate staleness signal —
        // but skip re-parsing (and update the cache) only when it differs
        // from what was cached last time. Unlike a library, an include can
        // produce output on every use, so its cached document is always
        // re-rendered fresh here rather than reused wholesale.
        let source = try loader.loadInclude(path: path, from: previousPath)
        let cacheKey = "\(previousPath ?? "")\u{0}\(path)"
        let document: LassoDocument
        if let cached = context.tagRegistry.cachedInclude(forKey: cacheKey, matchingSource: source) {
            document = cached
        } else {
            document = LassoParser().parse(source)
            context.tagRegistry.cacheInclude(forKey: cacheKey, source: source, document: document)
        }
        var engine = RendererEngine(context: context)
        let output = try engine.render(document.nodes)
        context = engine.evaluator.context
        return output
    }

    /// Loads and runs a library. `once`, when true, applies LassoSoft's
    /// documented `library_once` dedup ("if used multiple times
    /// referencing the same Lasso page then only the first will actually
    /// perform the include") against `loadedLibraries` — deliberately
    /// per-`LassoContext`, not the shared `tagRegistry`, since the dedup
    /// scopes to a single page's own render, not the server process's
    /// lifetime. Tag/type definitions the library registers land on the
    /// shared `tagRegistry` and so persist process-wide as normal, but any
    /// other top-level executable code in the file genuinely re-runs on
    /// every new request, since `loadedLibraries` starts empty on every
    /// fresh `LassoContext`. The library's own text output, if any, is
    /// intentionally discarded — library bodies run for side effects only.
    func performLibrary(path: String, once: Bool, context: inout LassoContext) throws {
        guard let loader = context.includeLoader else {
            throw LassoRuntimeError.includeNotConfigured
        }
        if once {
            guard context.loadedLibraries.insert(path).inserted else { return }
        }
        // Independent of the `once` dedup above: `includeLibrary`'s
        // `once: false` call has no dedup to fall back on, so a self- or
        // mutually-recursive library chain needs its own cycle/depth
        // guard — otherwise it recurses through native Swift calls
        // unboundedly and crashes the process (a Swift stack overflow
        // traps, it isn't a catchable Lasso error). Mirrors
        // `performInclude`'s `includeStack` guard exactly, on a separate
        // stack so `includes()` keeps reflecting include-family calls
        // only, per its documented scope.
        guard !context.libraryStack.contains(path) else {
            throw LassoRuntimeError.includeCycle(path)
        }
        guard context.libraryStack.count < 32 else {
            throw LassoRuntimeError.includeDepthExceeded
        }
        context.libraryStack.append(path)
        defer { _ = context.libraryStack.popLast() }

        let source = try loader.loadInclude(path: path, from: context.includePath)
        var engine = RendererEngine(context: context)
        _ = try engine.render(LassoParser().parse(source).nodes)
        context = engine.evaluator.context
    }
}

public struct LassoRenderer: Sendable {
    public init() {}

    public func render(_ source: String, context: inout LassoContext) async throws -> String {
        let document = LassoParser().parse(source)
        return try await render(document, context: &context)
    }

    public func render(_ document: LassoDocument, context: inout LassoContext) async throws -> String {
        // Seed the request's fire-count accumulator from this top-level
        // document's own recognition counts (Phase 3 of tag-form
        // consolidation) before the engine's context copy is made, so it
        // flows through to every include/library merge below and survives
        // the same success/failure write-back `lastErrorLocation` does.
        for (fire, count) in document.openFormFires {
            context.openFormFires[fire, default: 0] += count
        }
        var engine = RendererEngine(context: context)
        do {
            var output = try await engine.render(document.nodes)
            // A `return` at page/include level (not inside a called custom
            // tag, which already consumes its own signal) contributes its
            // value to the page's output — the same behavior
            // `<?lassoscript ... return json_serialize(...) ?>`-style API
            // pages already relied on before `return` gained real
            // short-circuiting control flow. Stage 2 (Captures): must use
            // the depth-aware consume here too, not a bare
            // `consumeReturnSignal()` — a capture invoked directly at THIS
            // page's own top level (home == this exact level) leaves a
            // still-live, correctly-targeted signal that only reaches this
            // point because every invocation boundary in between declined
            // to consume it (see `LassoContext
            // .consumeReturnSignalRespectingNonLocalTarget`'s own doc
            // comment); a bare unconditional consume here would also
            // wrongly swallow a signal that's still non-locally targeting
            // some OTHER, unrelated depth (impossible for a genuine
            // top-level document render, whose own active depth this
            // always is, but shared here for one uniform rule everywhere).
            if let returned = engine.evaluator.context.consumeReturnSignalRespectingNonLocalTarget(
                activeDepth: engine.evaluator.context.tagCallStack.count
            ) {
                output += returned.outputString
            }
            // Ch. "Web Requests and Responses" > "define_atBegin and
            // define_atEnd": whole-request scope, drained exactly once
            // here (this function is the single top-level entry point
            // every request goes through) — NOT per nested body render,
            // unlike `handle`'s own frame-stack draining just above.
            output += try await engine.evaluator.drainAtEndRegistrations()
            engine.evaluator.context.finalizeSessions()
            context = engine.evaluator.context
            return output
        } catch {
            // Write back the engine's mutated context even on failure —
            // this is what actually exposes `lastErrorLocation`/
            // `lastErrorIncludeStack` (set inside `RendererEngine.render`
            // at the moment the error first surfaces) to the caller.
            // Without this, `context` here is `inout`, but the local
            // `engine` variable's own copy is a completely separate value
            // that was never written back on the throw path — the
            // caller's `context` argument would silently stay exactly as
            // it was *before* rendering ever started.
            // At-end registrations still run on a thrown error too —
            // real-corpus usage (`ds_close_connections`) is cleanup that
            // must not leak just because the page itself failed,
            // matching `handle`'s own "still runs on error" precedent.
            _ = try? await engine.evaluator.drainAtEndRegistrations()
            context = engine.evaluator.context
            throw error
        }
    }
}

private struct RendererEngine {
    var evaluator: Evaluator

    init(context: LassoContext) {
        evaluator = Evaluator(context: context)
        evaluator.renderNodes = { nodes, context in
            var engine = RendererEngine(context: context)
            do {
                let output = try await engine.render(nodes)
                context = engine.evaluator.context
                return output
            } catch {
                // Write back even on failure — see `LassoRenderer.render`'s
                // matching comment; without this, `lastErrorLocation`/
                // `lastErrorIncludeStack` set deeper in this same call
                // chain (e.g. inside a custom tag body rendered through
                // this closure) never reach the caller.
                context = engine.evaluator.context
                throw error
            }
        }
        if evaluator.context.includeRenderService == nil {
            evaluator.context.includeRenderService = RendererIncludeService()
        }
        if evaluator.context.tagInvocationService == nil {
            evaluator.context.tagInvocationService = RendererTagInvocationService()
        }
    }

    /// Ch. "Error Handling" > "handle and handle_failure": pushes a fresh
    /// `LassoContext.pendingHandlerFrames` frame before rendering `nodes`
    /// and drains it (running any `handle`/`handle_failure` blocks
    /// registered during this exact call, in registration order) once
    /// `nodes` finishes — whether that's a normal return or a thrown
    /// error unwinding through it. This makes every nested body this
    /// codebase renders (a loop iteration, an invoked capture, the
    /// top-level page — `render(_:)` is the single choke point all of
    /// them go through) its own independent "handle" registration scope,
    /// matching the Guide's own "container" wording with no separate
    /// per-construct logic needed.
    ///
    /// On the error path, handlers still run (so side-effecting cleanup —
    /// e.g. `error_msg`-based logging — still gets a chance to execute,
    /// per the Guide's own examples) but their own rendered text output
    /// is deliberately discarded rather than threaded onto the eventual
    /// thrown-error path: real Lasso replaces an unprotected failing
    /// page's output with an error message rather than appending to it,
    /// and this codebase's existing render()/protect() plumbing has no
    /// channel for a thrown call to also return a partial string. The
    /// original error always propagates unchanged afterward — `handle`
    /// observes a failure, it never swallows one (that stays `protect`'s
    /// job, unaffected by this).
    mutating func render(_ nodes: [LassoNode]) async throws -> String {
        evaluator.context.pushHandlerFrame()
        do {
            let output = try await renderBody(nodes)
            return output + (try await evaluator.drainPendingHandlers(afterError: nil))
        } catch {
            _ = try? await evaluator.drainPendingHandlers(afterError: error)
            throw error
        }
    }

    private mutating func renderBody(_ nodes: [LassoNode]) async throws -> String {
        var output = ""
        for node in nodes {
            do {
                switch node {
                case let .text(text, _):
                    output += text
                case let .expression(expression, _, _, _):
                    if case let .identifier(name) = expression, name.lowercased() == "no_square_brackets" {
                        continue
                    }
                    output += try await renderExpression(expression)
                case let .code(expressions, _, _, _):
                    for expression in expressions {
                        output += try await renderExpression(expression)
                        if evaluator.context.shouldStopRenderingCurrentBody() { break }
                    }
                case let .block(name, arguments, body, alternate, _, _):
                    output += try await renderBlock(
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
            } catch let recoverable as LassoRecoverableError {
                // Must stay unwrapped and unrecorded: `[protect]` (below)
                // catches this exact type via `catch let recoverable as
                // LassoRecoverableError` around its own `render(body)`
                // call, and a recoverable error is by definition handled,
                // not a real page failure worth an error-location report.
                throw recoverable
            } catch {
                // Record where this first surfaced, then rethrow the
                // *original, unwrapped* error — many tests assert on the
                // concrete thrown type (`LassoRuntimeError.xyz`, etc.) and
                // a wrapper type here would break all of them. Recording
                // onto `context` instead works because `context` is
                // `inout` all the way up: Swift writes back an `inout`
                // parameter's final value even when the function exits by
                // throwing, so `lastErrorLocation`/`lastErrorIncludeStack`
                // still reach the top-level caller intact — unlike
                // `includeStack` itself, which every enclosing
                // `performInclude`/`performLibrary` frame's own `defer`
                // pops back to empty during that same unwind. Guarding on
                // `== nil` keeps the *first* (deepest, most precise) catch
                // as the one that sticks — this same catch block re-fires
                // for every enclosing `render(_:)` call the error
                // unwinds through (nested blocks, then include frames),
                // and each of those is progressively shallower.
                if evaluator.context.lastErrorLocation == nil {
                    evaluator.context.lastErrorLocation = node.range
                    evaluator.context.lastErrorIncludeStack = evaluator.context.includeStack
                }
                throw error
            }
            if evaluator.context.shouldStopRenderingCurrentBody() { break }
        }
        return output
    }

    private mutating func renderBlock(
        name: String,
        arguments: [LassoArgument],
        body: [LassoNode],
        alternate: [LassoNode]?
    ) async throws -> String {
        switch name.lowercased() {
        case "if":
            let condition: LassoValue
            if let argument = arguments.first {
                condition = try await evaluator.evaluate(argument.value)
            } else {
                condition = .boolean(false)
            }
            return condition.isTruthy ? try await render(body) : try await render(alternate ?? [])
        case "loop":
            evaluator.context.loopDepth += 1
            defer { evaluator.context.loopDepth -= 1 }
            let count: Int
            if let argument = arguments.first {
                count = Int(try await evaluator.evaluate(argument.value).number ?? 0)
            } else {
                count = 0
            }
            var output = ""
            if count > 0 {
                for iteration in 1...count {
                    evaluator.context.set(.integer(iteration), for: "loop_count", scope: .local)
                    output += try await render(body)
                    if evaluator.context.consumeLoopControlSignal() { break }
                    if evaluator.context.shouldStopRenderingCurrentBody() { break }
                }
            }
            return output
        case "while":
            evaluator.context.loopDepth += 1
            defer { evaluator.context.loopDepth -= 1 }
            var output = ""
            var iterations = 0
            while iterations < 10_000 {
                let condition: LassoValue
                if let argument = arguments.first {
                    condition = try await evaluator.evaluate(argument.value)
                } else {
                    condition = .boolean(false)
                }
                if !condition.isTruthy { break }
                output += try await render(body)
                iterations += 1
                if evaluator.context.consumeLoopControlSignal() { break }
                if evaluator.context.shouldStopRenderingCurrentBody() { break }
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
                let output = try await render(body)
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
            let frame = try await inlineProvider.executeInline(
                arguments: try await evaluator.evaluateArguments(arguments),
                context: evaluator.context
            )
            evaluator.context.pushInlineFrame(frame)
            evaluator.context.set(.array(frame.rows.map { .map($0.mapValue) }), for: "records_map", scope: .local)
            defer { evaluator.context.popInlineFrame() }
            return try await render(body)
        case "records", "rows":
            guard let frame = evaluator.context.currentInlineFrame else { return "" }
            evaluator.context.loopDepth += 1
            defer { evaluator.context.loopDepth -= 1 }
            var output = ""
            for (index, row) in frame.rows.enumerated() {
                evaluator.context.setCurrentRow(row)
                evaluator.context.set(.integer(index + 1), for: "record_count", scope: .local)
                evaluator.context.set(.integer(index + 1), for: "row_count", scope: .local)
                output += try await render(body)
                if evaluator.context.consumeLoopControlSignal() { break }
                if evaluator.context.shouldStopRenderingCurrentBody() { break }
            }
            evaluator.context.setCurrentRow(nil)
            return output
        case "iterate":
            evaluator.context.loopDepth += 1
            defer { evaluator.context.loopDepth -= 1 }
            let values: [LassoValue]
            // `loop_key()` — the current iteration's key/position: the
            // map key for a map source (parallel to `values`, built from
            // the same materialized `items.map { ... }` snapshot so the
            // two stay in lockstep regardless of Dictionary iteration
            // order), or the 1-based position for every other source.
            var mapKeys: [LassoValue]?
            if let argument = arguments.first {
                switch try await evaluator.evaluate(argument.value) {
                case let .array(items): values = items
                // Real Lasso map iteration yields Pair(key, value)
                // elements, not bare values — real corpus:
                // includes/detail_by_size.lasso's
                // `iterate($skuArrayItem, var(skuItem))` (where
                // `$skuArrayItem` is a `map`) followed by
                // `$skuItem->second->get(1)`.
                case let .map(items):
                    let pairs = items.map { (key: $0.key, value: $0.value) }
                    values = pairs.map { .pair(.string($0.key), $0.value) }
                    mapKeys = pairs.map { .string($0.key) }
                case .void, .null: values = []
                case let value: values = [value]
                }
            } else {
                values = []
            }
            // `iterate(collection, var(name))`/`local(name)` binds each
            // element to that name (in addition to the always-set
            // `loop_value`) — real corpus: the same
            // `iterate($skuArrayItem, var(skuItem))` call above, whose
            // body only ever references `$skuItem`/`#skuItem`, never
            // `loop_value`.
            let binding = arguments.count > 1 ? Self.iterateBinding(arguments[1].value) : nil
            var output = ""
            for (index, value) in values.enumerated() {
                evaluator.context.set(value, for: "loop_value", scope: .local)
                if let binding {
                    evaluator.context.set(value, for: binding.name, scope: binding.scope)
                }
                evaluator.context.set(.integer(index + 1), for: "loop_count", scope: .local)
                evaluator.context.set(mapKeys?[index] ?? .integer(index + 1), for: "loop_key", scope: .local)
                output += try await render(body)
                if evaluator.context.consumeLoopControlSignal() { break }
                if evaluator.context.shouldStopRenderingCurrentBody() { break }
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
            evaluator.context.loopDepth += 1
            defer { evaluator.context.loopDepth -= 1 }
            let withValues: [LassoValue]
            switch try await evaluator.evaluate(arguments[1].value) {
            case let .array(items): withValues = items
            case let .map(items): withValues = items.values.map { $0 }
            case .void, .null: withValues = []
            case let value: withValues = [value]
            }
            var withOutput = ""
            for value in withValues {
                evaluator.context.set(value, for: variableName, scope: .local)
                withOutput += try await render(body)
                if evaluator.context.consumeLoopControlSignal() { break }
                if evaluator.context.shouldStopRenderingCurrentBody() { break }
            }
            return withOutput
        case "output_none":
            // Processes the tags within (side effects like var()/local()
            // assignments still happen — `render(body)` evaluates
            // everything normally) but hides the rendered text from the
            // page, per Lasso 8.5 Language Guide Chapter 14's "Table 1:
            // Output Tags". See Documentation/output-tags-plan.md.
            _ = try await render(body)
            return ""
        case "html_comment":
            // Wraps the body's rendered output in an HTML comment — the
            // contents still reach the client (visible via "View Source")
            // but aren't part of the visible page.
            return "<!--\(try await render(body))-->"
        case "encode_set":
            // Changes the default encoding for nested `Output` calls
            // (those with no -Encode* keyword of their own) for the
            // duration of the body — see LassoEncoding.keyword(in:) and
            // the `output` native. An unrecognized/missing keyword falls
            // through to rendering the body with no override, matching
            // this interpreter's existing "unknown flag ignored, not
            // fatal" convention elsewhere.
            let evaluatedArguments = try await evaluator.evaluateArguments(arguments)
            if let keyword = LassoEncoding.keyword(in: evaluatedArguments) {
                evaluator.context.encodingOverrideStack.append(keyword)
                defer { evaluator.context.encodingOverrideStack.removeLast() }
                return try await render(body)
            }
            return try await render(body)
        default:
            if let function = evaluator.context.natives.function(named: name) {
                _ = try await function(try await evaluator.evaluateArguments(arguments), &evaluator.context)
            }
            return try await render(body)
        }
    }

    private mutating func renderExpression(_ expression: LassoExpression) async throws -> String {
        if case let .call(callee, arguments) = expression,
           case let .identifier(name) = callee {
            // `lassoapp_include` (LassoGuide "Operations > LassoApps" >
            // "LassoApp Includes") is real Lasso 9's app-scoped include —
            // for the "library" use of LassoApps this adapter supports
            // (see `loadLassoApps`'s doc comment), it needs no separate
            // resolution logic of its own: `loadLassoApps` already builds
            // each app's `_init*.lasso` context with an app-scoped
            // `LassoFileSystemIncludeLoader` as `context.includeLoader`,
            // so aliasing straight into the existing `include()` mechanism
            // resolves relative to that same app's own directory, never
            // another app's or the site's own root.
            if name.caseInsensitiveCompare("include") == .orderedSame
                || name.caseInsensitiveCompare("lassoapp_include") == .orderedSame {
                return try await renderInclude(arguments)
            }
            if name.caseInsensitiveCompare("library") == .orderedSame {
                try await renderLibrary(arguments)
                return ""
            }
        }
        return try await evaluator.evaluateStatement(expression).outputString
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
    private mutating func renderLibrary(_ arguments: [LassoArgument]) async throws {
        let evaluated = try await evaluator.evaluateArguments(arguments)
        let path = evaluated.firstValue(named: "file")?.outputString ??
            evaluated.firstValue(named: "path")?.outputString ??
            evaluated.first?.value.outputString ?? ""
        guard let service = evaluator.context.includeRenderService else {
            throw LassoRuntimeError.includeNotConfigured
        }
        try await service.performLibrary(path: path, once: true, context: &evaluator.context)
    }

    private mutating func renderInclude(_ arguments: [LassoArgument]) async throws -> String {
        let evaluated = try await evaluator.evaluateArguments(arguments)
        let path = evaluated.firstValue(named: "file")?.outputString ??
            evaluated.firstValue(named: "path")?.outputString ??
            evaluated.first?.value.outputString ?? ""
        guard let service = evaluator.context.includeRenderService else {
            throw LassoRuntimeError.includeNotConfigured
        }
        return try await service.performInclude(path: path, once: false, context: &evaluator.context) ?? ""
    }

    /// Extracts the loop-variable name and scope from
    /// `iterate(collection, var(name))`/`local(name)`'s second argument —
    /// real corpus: includes/detail_by_size.lasso's
    /// `iterate($skuArrayItem, var(skuItem))`, later read back as
    /// `$skuItem` (not `#skuItem`) — `var(...)` binds in the same
    /// default/global-ish scope `declare(_:local:)` uses for a bare
    /// `var(...)` declaration, `local(...)` binds in `.local` scope,
    /// matching that same function's `local ? .local : .global` mapping.
    private static func iterateBinding(_ expression: LassoExpression) -> (name: String, scope: VariableScope)? {
        switch expression {
        case let .identifier(name), let .string(name):
            return (name, .global)
        case let .variable(name, scope):
            return (name, scope)
        case let .call(callee, arguments):
            guard case let .identifier(calleeName) = callee,
                  let firstArgument = arguments.first,
                  let inner = iterateBinding(firstArgument.value) else { return nil }
            if calleeName.caseInsensitiveCompare("local") == .orderedSame {
                return (inner.name, .local)
            }
            if calleeName.caseInsensitiveCompare("var") == .orderedSame
                || calleeName.caseInsensitiveCompare("variable") == .orderedSame {
                return (inner.name, .global)
            }
            return nil
        default:
            return nil
        }
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
    func performInclude(path: String, once: Bool, context: inout LassoContext) async throws -> String? {
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
        // Merge this include's fire counts into the per-request accumulator
        // (Phase 3) — on a cache hit too, since the document (and its
        // counts, computed once at parse time) still reflects a real use of
        // this include on this render, which is exactly the traffic-weighted
        // signal live fire-counting is for.
        for (fire, count) in document.openFormFires {
            context.openFormFires[fire, default: 0] += count
        }
        var engine = RendererEngine(context: context)
        do {
            let output = try await engine.render(document.nodes)
            context = engine.evaluator.context
            return output
        } catch {
            // Write back even on failure — see `LassoRenderer.render`'s
            // matching comment. This also matters for the `defer` above:
            // it pops exactly one `includeStack`/`includePath` frame off
            // `context` at whatever `context` holds when this function
            // exits, so it must reflect this include's real final state
            // (including any deeper, already-failed nested includes)
            // rather than silently reverting to what `context` looked
            // like before this include even started.
            context = engine.evaluator.context
            throw error
        }
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
    func performLibrary(path: String, once: Bool, context: inout LassoContext) async throws {
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
        let document = LassoParser().parse(source)
        // Merge this library's fire counts into the per-request accumulator
        // (Phase 3) — the library's own text output is discarded by design
        // (see this function's doc comment), but its tag-open-form counts
        // are real evidence about this render regardless.
        for (fire, count) in document.openFormFires {
            context.openFormFires[fire, default: 0] += count
        }
        var engine = RendererEngine(context: context)
        do {
            _ = try await engine.render(document.nodes)
            context = engine.evaluator.context
        } catch {
            // Write back even on failure — see `performInclude`'s
            // matching comment just above.
            context = engine.evaluator.context
            throw error
        }
    }
}

/// Concrete `LassoTagInvocationService` conformer — the only place that
/// can reconstruct a `RendererEngine` to actually run a resolved custom
/// tag's body. Wired onto every context by `RendererEngine.init`, same
/// convention as `RendererIncludeService` immediately above. See
/// `LassoTagInvocationService`'s own doc comment (`Providers.swift`) for
/// why this binds positionally rather than reusing
/// `Evaluator.invokeCustomTag`'s full call-site binding (default-
/// parameter expressions require recursive `Evaluator.evaluate`
/// access, which a bare `LassoContext` doesn't have).
struct RendererTagInvocationService: LassoTagInvocationService {
    func invoke(
        _ definition: LassoCustomTagDefinition,
        positionalArguments: [LassoValue],
        context: inout LassoContext
    ) async throws -> LassoValue {
        // Stage 2 (Captures): mirrors `Evaluator
        // .skipIfNonLocalReturnAlreadyPending()` — this call must not
        // even start (bind parameters, push a new frame, render a body)
        // if a return/yield is ALREADY mid-propagation from earlier in
        // the same statement's expression evaluation. Without this, this
        // boundary's own `context.clearReturnSignal()` below would
        // silently clobber that still-live signal before the enclosing
        // statement's poll ever gets a chance to see it.
        if context.returnSignal != nil { return .void }
        // A separate `positionalIndex` counter, only advanced on an
        // actual bind — NOT the `enumerated()` loop index directly —
        // matching `Evaluator.bindParameters`'s own defensive shape
        // (`Evaluator.swift`). A parameter declaration whose name can't
        // be resolved (malformed/unusual shape; unreachable for
        // well-formed `-Required='name'`/`-Optional='name'=default`
        // declarations) is skipped via `continue` without consuming a
        // positional slot — using the raw loop index there instead would
        // silently shift every SUBSEQUENT parameter's binding one
        // position off, a wrong-value bug that wouldn't throw. Found by
        // code review during Stage 7a.
        // Stage 3 (Captures): a fresh box per bound parameter, matching
        // `Evaluator.bindParameters`'s identical treatment — a tag call
        // always starts an entirely new, isolated local scope.
        var bound: [String: LassoLocalBox] = [:]
        var positionalIndex = 0
        for parameter in definition.parameters {
            guard let name = LassoMethodDispatcher.parameterMetadata(parameter.value).name else { continue }
            guard positionalIndex < positionalArguments.count else {
                throw LassoRuntimeError.tagInvocationArityMismatch(definition.name)
            }
            bound[name.lowercased()] = LassoLocalBox(positionalArguments[positionalIndex])
            positionalIndex += 1
        }

        // Same snapshot/restore/push/pop shape as
        // `Evaluator.invokeCustomTag` (`Evaluator.swift`) — kept in sync
        // deliberately; see that function's own doc comment for why each
        // step exists (fresh local scope, loop-depth reset so a stray
        // Loop_Abort/Continue inside this body doesn't leak to an
        // enclosing loop the CALLER happened to be inside).
        let savedLocals = context.snapshotLocals()
        let savedLoopDepth = context.loopDepth
        try context.pushTagCall(definition.name)
        context.replaceLocals(bound)
        context.loopDepth = 0
        context.clearReturnSignal()
        defer {
            context.replaceLocals(savedLocals)
            context.popTagCall()
            context.loopDepth = savedLoopDepth
        }

        var engine = RendererEngine(context: context)
        do {
            _ = try await engine.render(definition.body)
            context = engine.evaluator.context
        } catch {
            context = engine.evaluator.context
            throw error
        }
        // Stage 2 (Captures): same depth-aware consume as
        // `Evaluator.invokeCustomTag`/`invokeMemberMethod`/`invokeCapture`
        // (see `LassoContext.consumeReturnSignalRespectingNonLocalTarget`'s
        // doc comment) — this boundary pushed `definition.name` via
        // `pushTagCall` above and hasn't popped it yet (that's in the
        // `defer`), so `context.tagCallStack.count` here is this
        // invocation's own active depth, exactly like every other boundary.
        return context.consumeReturnSignalRespectingNonLocalTarget(
            activeDepth: context.tagCallStack.count
        ) ?? .void
    }
}

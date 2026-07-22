import Foundation

struct Evaluator {
    var context: LassoContext
    /// Lets expression evaluation invoke full node rendering (for custom
    /// tag bodies) without `Evaluator` depending on `Renderer.swift`, which
    /// already wraps `Evaluator` — injected by `RendererEngine.init`.
    var renderNodes: ((_ nodes: [LassoNode], _ context: inout LassoContext) async throws -> String)? = nil

    mutating func evaluate(_ expression: LassoExpression) async throws -> LassoValue {
        switch expression {
        case let .string(value): return .string(value)
        case let .integer(value): return .integer(value)
        case let .decimal(value): return .decimal(value)
        case let .boolean(value): return .boolean(value)
        case .null: return .null
        case .void: return .void
        case let .captureLiteral(body, autoCollect):
            // Stage 3 (live-reference closures — see `Captures.swift`'s
            // own doc comment): `context.snapshotLocals()` returns a
            // dictionary COPY, but its VALUES are `LassoLocalBox` object
            // references, not plain `LassoValue`s — so this shares the
            // SAME storage cells the live scope's locals use, not a
            // frozen value-type copy. A later write to one of those
            // names (via `LassoContext.set`, which mutates an existing
            // box in place) is visible through THIS capture's own
            // `capturedLocals` too, since it's the identical box object.
            // Stage 2: `homeDepth` records the call-stack depth active
            // right now (this capture's creating frame's own depth) —
            // a later `return`/`yield` inside this capture's body
            // unwinds back down to exactly this depth, no matter how
            // many frames deep the capture is eventually invoked from.
            //
            // Ch. "Captures": "A capture that is created within a
            // capture that does have a home will have its home set to
            // its parent capture's home. This means that nested captures
            // will all have the same home." — a capture literal
            // evaluated WHILE another capture's own body is currently
            // executing must inherit THAT capture's home verbatim
            // (`context.currentCaptureHomeDepth`, itself `nil` if the
            // enclosing capture is detached — nested captures inherit
            // detachment too, per "will all have the same home"), not
            // recompute its own from the raw current stack depth. Found
            // by code review: using the raw depth here silently caught a
            // nested capture's non-local return ONE FRAME TOO EARLY (at
            // the enclosing capture's own invocation boundary) whenever
            // the OUTER capture itself was invoked from a different
            // depth than it was created at — invisible for the narrower
            // "invoked immediately, in place" shape this file's own
            // nested-capture test exercises, but a real, confirmed
            // divergence from the documented rule.
            return .capture(LassoCaptureValue(
                body: body,
                autoCollect: autoCollect,
                capturedLocals: context.snapshotLocals(),
                homeDepth: context.currentCaptureHomeDepth ?? context.tagCallStack.count
            ))
        case let .queryExpression(withClauses, operations, action):
            return try await evaluateQueryExpression(withClauses: withClauses, operations: operations, action: action)
        case let .variable(name, scope): return context.value(for: name, scope: scope)
        case let .identifier(name):
            if name.caseInsensitiveCompare("self") == .orderedSame, let object = context.currentSelf {
                return .object(object)
            }
            // Ch. "Captures": "A method that receives an associated
            // block accesses it via the `givenBlock` keyword" — a bare
            // identifier, not `#givenBlock`/`$givenBlock`, matching the
            // real docs' own worked example (`local(gb) = givenBlock`).
            // `.void` (not an error) when the current call has no
            // associated block, matching this codebase's established
            // "no lookup-miss throws by default" convention elsewhere.
            if name.caseInsensitiveCompare("givenblock") == .orderedSame {
                return context.currentGivenBlock
            }
            // Checked before native functions: a couple of names (e.g.
            // "session") are registered as both a zero-arg-callable native
            // function (colon-call style, "session:'cart'" — a .call
            // expression, unaffected by this order since .call resolves
            // separately and always checks natives first) and a native
            // type (for "session->value(...)" member access, which must
            // evaluate this bare identifier to a real .object first).
            // Bare identifier evaluation is the only place these collide;
            // resolving the type here is what makes member access work.
            if context.nativeTypes.containsType(named: name) {
                return .object(LassoObjectInstance(typeName: name))
            }
            if let function = context.natives.function(named: name) {
                return try await function([], &context)
            }
            if let definition = context.tagRegistry.tag(named: name) {
                return try await invokeCustomTag(definition, callArguments: [])
            }
            return context.value(for: name)
        case let .tagReference(name):
            // Ch. 30 Table 21 — `\identifier` names an already-defined
            // tag (built-in or custom) without invoking it. Validated
            // here (mirrors `.identifier`'s own "does this name resolve
            // to anything real?" checks just above) so `\NoSuchTag`
            // fails loudly at the reference site rather than silently
            // producing an inert value that only misbehaves later,
            // wherever it's eventually consumed.
            // Custom TYPES (`Define_Type`) are a real, separate category
            // from custom TAGS (`Define_Tag`) — `context.tagRegistry`
            // keeps them in two distinct dictionaries (`TagRegistry.swift`
            // `tags`/`types`), and `context.nativeTypes.containsType(
            // named:)` only covers BUILT-IN types, never learns about
            // user `Define_Type` types (confirmed by architect review:
            // an earlier version of this guard omitted
            // `context.tagRegistry.containsType(named:)` entirely, so
            // `\MyCustomType` on a genuinely defined custom type threw
            // `unknownFunction` — worse than the disclosed "valid
            // reference, not yet dispatched" behavior `\MyCustomTag`
            // already gets). This matters concretely, not just for
            // completeness: the Guide itself (p.420) says "custom
            // comparators can be created as custom tags or as custom
            // types by overriding the onCompare callback tag" — so
            // `\MyComparatorType` is a real, documented shape this guard
            // must accept.
            guard context.natives.contains(name)
                || context.tagRegistry.containsTag(named: name)
                || context.tagRegistry.containsType(named: name)
                || context.nativeTypes.containsType(named: name) else {
                throw LassoRuntimeError.unknownFunction(name)
            }
            return .object(LassoTagReferenceValue.makeObject(name: name))
        case let .assignment(target, value):
            let evaluated = try await evaluate(value)
            try await assign(evaluated, to: target, defaultScope: .unscoped)
            return .void
        case let .ternary(condition, whenTrue, whenFalse):
            return try await evaluate(condition).isTruthy ? try await evaluate(whenTrue) : try await evaluate(whenFalse)
        case let .unary(op, value):
            return try unary(op, try await evaluate(value))
        case let .binary(left, op, right):
            if op == "&&" {
                let lhs = try await evaluate(left)
                return lhs.isTruthy ? .boolean(try await evaluate(right).isTruthy) : .boolean(false)
            }
            if op == "||" {
                let lhs = try await evaluate(left)
                return lhs.isTruthy ? .boolean(true) : .boolean(try await evaluate(right).isTruthy)
            }
            if op == ">>" {
                // Ch. 30 Table 22 (p.420-421): "The ->Contains member tag
                // of each compound data type and the contains symbol >>
                // both accept a matcher as a parameter" — worked example
                // `(Array: 1,2,3,4,5,6,7) >> 7` → True.
                //
                // PRE-EXISTING BUG this fix closes (found during this
                // stage's own scoping pass, not new): `binary(_:_:_:)`'s
                // own `>>` case is pure `left.outputString.contains(
                // right.outputString)` — it never branched on `.array`
                // (or any other collection type) at all, so
                // `(Array:1,2,3) >> 7`-shaped array-membership was
                // silently degrading to string-concatenation-then-
                // substring-search (worked by coincidence for short/
                // single-token elements, wrong in general — e.g.
                // `(Array: 12, 3) >> 23` would false-positive on the
                // concatenated string "1233" containing "23"). Real
                // corpus's own ~32-file reliance on `left >> 'substring'`
                // for host/environment detection (plain strings, not
                // collections) is completely unaffected — this only
                // intercepts `>>` when the LEFT side is a collection-
                // shaped value; a scalar left side falls through to the
                // exact same `binary(...)` call, unchanged, below.
                let leftValue = try await evaluate(left)
                let rightValue = try await evaluate(right)
                if let elements = LassoMatcherValue.iterableElements(of: leftValue) {
                    return .boolean(try await LassoMatcherValue.anyMatches(rightValue, in: elements, context: context))
                }
                return try binary(leftValue, op, rightValue)
            }
            return try binary(try await evaluate(left), op, try await evaluate(right))
        case let .call(callee, arguments):
            // `expr->get:1` (bare colon-call on a member access, no `(`)
            // parses as `.call(callee: .member(base, "get", nil), args)` —
            // the colon-call's arguments belong to the member call, not a
            // second, separate call on its result. Real corpus:
            // includes/detail_by_color.lasso's
            // `#skuItem->second->get:1`.
            if case let .member(base, name, nil) = callee {
                return try await member(try await evaluate(base), name, arguments)
            }
            guard case let .identifier(name) = callee else {
                // `#cap(...)` — Ch. "Captures": "`#cap() // Shorthand
                // invocation`" — a capture value stored in a variable
                // (or produced by any other non-identifier expression)
                // called directly with `()`. Falls back to the existing
                // "Dynamic call" error for every other callee shape,
                // unchanged.
                let calleeValue = try await evaluate(callee)
                if case let .capture(capture) = calleeValue {
                    return try await invokeCapture(capture, arguments: try await evaluate(arguments))
                }
                throw LassoRuntimeError.unsupportedExpression("Dynamic call")
            }
            if let scope = Self.declarationScope(for: name) {
                return try await declare(arguments, scope: scope)
            }
            if name.caseInsensitiveCompare("treemap") == .orderedSame {
                // Special-cased HERE, ahead of the generic
                // `context.natives.function(named:)` dispatch just
                // below — for the EXACT same reason
                // `TreeMap->Insert`/`->Find`/`->Remove`/`->RemoveAll`
                // are special-cased in `member(_:_:_:)` (see those
                // cases' own doc comment): the generic path's argument
                // pre-evaluation (`evaluate(_ arguments:)` below)
                // collapses a `key = value` argument's key down to a
                // bare `String` label before any closure sees it,
                // which would silently defeat TreeMap's documented
                // "any Lasso data type" key requirement (Ch. 30
                // p.416). Found missing here by architect review: an
                // earlier version of this fix covered the mutating
                // METHOD path but left the CONSTRUCTOR form
                // (`treemap(1='Sunday', ...)`, Table 19's own
                // documented form) going through the same lossy path
                // it was supposed to avoid. The `register("treemap")`
                // free function in `Runtime.swift` still exists and is
                // intentionally left in place — it's still reachable
                // via `context.natives.contains(name)` (used by
                // introspection/`HasMethod`-style checks), just no
                // longer via actual invocation, which this case now
                // handles instead.
                return try await evaluateTreeMapConstructorCall(arguments)
            }
            if let function = context.natives.function(named: name) {
                return try await function(try await evaluate(arguments), &context)
            }
            if let type = context.tagRegistry.type(named: name) {
                return try await instantiate(type, callArguments: arguments)
            }
            if let definition = context.tagRegistry.tag(named: name) {
                return try await invokeCustomTag(definition, callArguments: arguments)
            }
            throw LassoRuntimeError.unknownFunction(name)
        case let .member(base, name, arguments):
            // Self-mutating methods (`->insert`, `->replace`, etc.) are
            // handled here as *plain, value-returning* calls — real Lasso
            // only suppresses their return value and treats the mutation
            // as the whole point when the call is the entire top-level
            // statement (see `evaluateStatement(_:)`, called by
            // `Renderer.renderExpression` for exactly that case). Nested
            // usage still needs the real computed value: real corpus
            // `_begin.lasso`/`components/_begin_tags.inc`'s
            // `#out = '-' + #out->replace('-','')` reads `->replace`'s
            // result as part of a larger expression, which would silently
            // collapse to `'-' + ''` if this case voided it unconditionally.
            return try await member(try await evaluate(base), name, arguments ?? [])
        case let .unknown(value):
            if value == "@" {
                // Lasso 8.5 Language Guide Ch. 15 pp.230-232: `@` is the
                // prefix half of real Lasso's variable-reference/aliasing
                // operator ([Reference] aliasing) — a corpus assessment
                // found zero real-world usage of the FULL aliasing feature
                // (two variable names sharing one mutable storage cell),
                // but confirmed bare `@#var`/`@$var`/`@self->member`-style
                // usage in 6 real production files (e.g. `return:
                // @#url_string;`), always in a "hand back the actual
                // value, not a copy" shape. This DELIBERATELY stays
                // unsupported rather than being silently treated as a
                // no-op pass-through: real Lasso's `@` genuinely changes
                // assignment/storage semantics, and this codebase's
                // storage model (`LassoLocalBox`-per-variable, see
                // `Captures.swift`'s own doc comment) has no cheap way to
                // honor that difference correctly — silently ignoring `@`
                // would risk a subtly WRONG result state (a copy where
                // real Lasso shares storage) rather than a clearly visible
                // failure. A dedicated message (rather than the generic,
                // single-character `unsupportedExpression("@")`) so a page
                // hitting this shows up clearly in server logs/error pages
                // instead of a cryptic one-character diagnostic — this is
                // still an ordinary, catchable `throws`, not a process
                // crash: `LassoPerfectServer`'s own request-render pipeline
                // already wraps any thrown error into `LassoSiteRenderError`
                // and returns a normal HTTP error response for that one
                // request, verified live against every one of the 6 real
                // corpus usage shapes plus several adversarial inputs.
                throw LassoRuntimeError.unsupportedExpression(
                    "@ (variable-reference/aliasing operator) is not supported"
                )
            }
            throw LassoRuntimeError.unsupportedExpression(value)
        }
    }

    private mutating func evaluate(_ arguments: [LassoArgument]) async throws -> [EvaluatedArgument] {
        var results: [EvaluatedArgument] = []
        results.reserveCapacity(arguments.count)
        for argument in arguments {
            if argument.label == nil, case let .assignment(target, value) = argument.value {
                if case let .variable(name, scope) = target {
                    // `#dynamicField = value` — a real variable on the
                    // left is a Lasso idiom for a RUNTIME-CHOSEN argument
                    // keyword, not an assignment: the variable's current
                    // VALUE becomes the label, not its name. Real corpus:
                    // pages/detail.page.lasso's `#product_search =
                    // #search_by` inside an Inline(...) -search call,
                    // where #product_search holds 'mfr_style_no' or
                    // 'scrubs_style_color' at runtime, picking which
                    // column the search filters on. Previously this fell
                    // through to `assignmentLabel`, which matches
                    // `.variable` too and returned the variable's own
                    // NAME ("product_search") — used verbatim as a raw
                    // SQL column downstream, throwing "Unknown column
                    // 'product_search'".
                    let resolvedLabel = context.value(for: name, scope: scope).outputString
                    // This label can now reach `DynamicPredicate.field`
                    // (PerfectCRUDLassoExecutor.swift) as a runtime value
                    // rather than a parse-time-fixed literal — and
                    // Perfect-MySQL's `quote(identifier:)` only wraps in
                    // backticks without escaping embedded ones, so an
                    // unvalidated dynamic label would be a real SQL
                    // identifier-injection path. Literal labels
                    // (`'active' = 'active'`) stay exempt: those are
                    // fixed in the template source by its own author, the
                    // same trust boundary as the rest of the page.
                    try Self.validateDynamicFieldLabel(resolvedLabel)
                    results.append(EvaluatedArgument(label: resolvedLabel, value: try await evaluate(value)))
                    continue
                }
                if let label = Self.assignmentLabel(target) {
                    results.append(EvaluatedArgument(label: label, value: try await evaluate(value)))
                    continue
                }
            }
            results.append(EvaluatedArgument(label: argument.label, value: try await evaluate(argument.value)))
        }
        return results
    }

    /// `treemap(...)` construction with real (non-string-coerced) key
    /// types preserved — see the `.call` case's own doc comment above
    /// for why this can't just reuse `evaluate(_ arguments:)`. Mirrors
    /// `Runtime.swift`'s `register("treemap")` free function's own
    /// leading-optional-comparator-then-name/value-pairs shape, but
    /// works from the RAW, unevaluated `[LassoArgument]` list so each
    /// key keeps whatever real type its literal had.
    private mutating func evaluateTreeMapConstructorCall(_ arguments: [LassoArgument]) async throws -> LassoValue {
        var kind = "lessthan"
        var remaining = arguments
        if let first = arguments.first, first.label == nil {
            if case .assignment = first.value {
                // A `key = value` first argument is a real entry, not
                // a leading comparator — leave `remaining` as-is.
            } else {
                let evaluatedFirst = try await evaluate(first.value)
                if let comparatorKind = LassoComparatorValue.kind(of: evaluatedFirst) {
                    kind = comparatorKind
                    remaining = Array(arguments.dropFirst())
                }
            }
        }
        var entries: [LassoValue] = []
        for argument in remaining {
            if argument.label == nil, case let .assignment(target, value) = argument.value {
                let key = try await evaluate(target)
                let entryValue = try await evaluate(value)
                entries.append(.pair(key, entryValue))
            } else if let label = argument.label {
                entries.append(.pair(.string(label), try await evaluate(argument.value)))
            }
        }
        return .object(LassoTreeMapValue.makeObject(kind: kind, entries: entries))
    }

    mutating func evaluateArguments(_ arguments: [LassoArgument]) async throws -> [EvaluatedArgument] {
        try await evaluate(arguments)
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
    ) async throws -> LassoValue {
        // Stage 2 (Captures): must not even START this call if a
        // return/yield is ALREADY mid-propagation — see this file's own
        // `skipIfNonLocalReturnAlreadyPending()` doc comment for the
        // real hazard this guards against (found by architect review).
        if skipIfNonLocalReturnAlreadyPending() { return .void }
        let (givenBlock, evaluatedCallArguments) = Self.extractGivenBlock(from: try await evaluate(callArguments))
        let boundLocals = try await bindParameters(definition.parameters, to: evaluatedCallArguments)

        let savedLocals = context.snapshotLocals()
        let savedLoopDepth = context.loopDepth
        try context.pushTagCall(definition.name)
        context.replaceLocals(boundLocals)
        context.pushGivenBlock(givenBlock)
        // A tag call starts a fresh scope with no loop of its own yet —
        // without this, a stray Loop_Abort/Loop_Continue inside this
        // tag's own body (which has no loop) would be mistaken by
        // `shouldStopRenderingCurrentBody()` for "some enclosing loop out
        // there wants this" just because the *caller* happened to be
        // inside one, and leak back out to abort/skip whatever loop
        // iteration is calling this tag. See `LassoContext.loopDepth`.
        context.loopDepth = 0
        defer {
            context.popGivenBlock()
            context.replaceLocals(savedLocals)
            context.popTagCall()
            context.loopDepth = savedLoopDepth
        }

        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        _ = try await renderNodes(definition.body, &context)
        return consumeReturnValueRespectingNonLocalTarget(activeDepth: context.tagCallStack.count) ?? .void
    }

    /// Thin wrapper around `LassoContext.consumeReturnSignalRespectingNonLocalTarget`
    /// (see that method's own doc comment for the full propagation
    /// mechanism) — shared by `invokeCustomTag`/`invokeMemberMethod`/
    /// `invokeCapture`. `activeDepth` must be measured BEFORE this
    /// frame's own `defer`-scheduled `popTagCall()` runs (i.e. while
    /// `tagCallStack.count` still reflects this frame's own pushed
    /// depth) — every call site here does that naturally, since this is
    /// always the last thing evaluated before the function returns.
    private mutating func consumeReturnValueRespectingNonLocalTarget(activeDepth: Int) -> LassoValue? {
        context.consumeReturnSignalRespectingNonLocalTarget(activeDepth: activeDepth)
    }

    /// Guards every invocation boundary (`invokeCustomTag`/
    /// `invokeMemberMethod`/`invokeCapture`) against a real hazard found
    /// by architect review: `shouldStopRenderingCurrentBody()` is only
    /// ever polled at STATEMENT granularity (between top-level nodes, or
    /// between the pieces of one `.code` node) — never mid-expression.
    /// So if a capture's non-local `return`/`yield` fires while it's
    /// being invoked as a SUB-expression (a call argument, an operand of
    /// `+`, an array element...) and something ELSE that goes through one
    /// of these three boundaries runs afterward within that SAME
    /// statement (another capture invocation, a plain tag call, a
    /// member-method call), that later call would previously run to
    /// completion as if nothing were happening — silently re-executing
    /// side effects, and its own `context.clearReturnSignal()` (called
    /// right before rendering ITS OWN body) would wipe out the still-
    /// propagating signal before the enclosing statement's poll ever got
    /// a chance to see it. Concretely: `#cap->invoke + '-' + #cap->invoke`
    /// would silently invoke `cap`'s body TWICE instead of once once the
    /// first invocation's `return` starts propagating; two SIBLING
    /// captures with DIFFERENT homes in the same expression could have
    /// the wrong one's value win entirely.
    ///
    /// The fix: a call that's about to start MUST NOT run at all — not
    /// even evaluate its own arguments — if a return/yield is already
    /// live and unconsumed. Real stack-unwinding semantics would never
    /// even reach this call in the first place once an ancestor's
    /// non-local exit is underway; this reproduces that by checking as
    /// early as possible, before doing any of this boundary's own work.
    private func skipIfNonLocalReturnAlreadyPending() -> Bool {
        context.returnSignal != nil
    }

    /// `capture->invoke(...)` / `#cap(...)` shorthand — see
    /// `Captures.swift`'s own doc comment for the full design. Mirrors
    /// `invokeCustomTag` above almost exactly (same snapshot/restore
    /// discipline, same per-call return-signal reuse, same fresh
    /// `loopDepth`/recursion-depth-guarded call-stack push) — the one
    /// real difference is WHICH locals a capture's invocation starts
    /// from: `capturedLocals` (a snapshot of the scope the capture
    /// literal was evaluated in), not a fresh empty dictionary the way a
    /// custom tag call always starts from just its own bound parameters.
    /// Positional arguments bind to `#1`/`#2`/... (Ch. "Captures":
    /// "Parameters arrive via positional special locals"), OVERWRITING
    /// any same-named entry already present in `capturedLocals` — the
    /// call site's own arguments win over whatever the capture's
    /// creation scope happened to have stored under the same numeric
    /// name.
    private mutating func invokeCapture(
        _ capture: LassoCaptureValue,
        arguments: [EvaluatedArgument],
        updatesAutoCollectBuffer: Bool = true
    ) async throws -> LassoValue {
        // Stage 2 (Captures): see `skipIfNonLocalReturnAlreadyPending()`'s
        // own doc comment — without this, a SECOND `#cap->invoke` in the
        // same expression as a first one whose `return`/`yield` is still
        // propagating would silently re-run this capture's body and
        // clobber the still-live signal.
        if skipIfNonLocalReturnAlreadyPending() { return .void }
        // Stage 7 fix (found by architect review): a capture invoked
        // WITH its own `=>`-associated block (`#cap->invoke => {...}`,
        // `#cap() => {...}`) reaches here with a `"givenblock"`-labeled
        // argument, exactly like any other call `foldAssociatedCapture`
        // folds onto (`ExpressionParser.swift`'s own comment: "any other
        // call/member/identifier expression followed by `=> {...}`" —
        // NOT `->forEach`-specific). Every OTHER call-dispatch path
        // (`invokeCustomTag`/`invokeMemberMethod`) extracts this via
        // `extractGivenBlock` and pushes/pops it on
        // `context.givenBlockStack` around the body so `givenBlock`/
        // `currentCapture->givenBlock()` reads it back correctly. Before
        // this fix, `invokeCapture` never did either — the block was
        // evaluated (for side effects) then silently discarded, and
        // `givenBlock`/`currentCapture->givenBlock()` read inside the
        // capture's own body leaked whatever unrelated value an
        // ENCLOSING `invokeCustomTag`/`invokeMemberMethod` frame had
        // pushed (or `.void` with no such frame) instead — confirmed via
        // a live reproduction (a capture given its own distinct block
        // from inside a custom tag with a DIFFERENT given block; the
        // capture's own block was dropped and the tag's leaked through).
        let (givenBlock, remaining) = Self.extractGivenBlock(from: arguments)
        var boundLocals = capture.capturedLocals
        for (offset, argument) in remaining.filter({ $0.label == nil }).enumerated() {
            // Stage 3 (Captures): a FRESH box per invocation, not a
            // mutation of whatever box (if any) already occupied this
            // slot — `#1`/`#2`/... are this call's own arguments, never
            // shared with the creating scope or persisted across separate
            // invocations of the same capture.
            boundLocals[String(offset + 1)] = LassoLocalBox(argument.value)
        }

        let savedLocals = context.snapshotLocals()
        let savedLoopDepth = context.loopDepth
        try context.pushTagCall("capture")
        context.replaceLocals(boundLocals)
        context.loopDepth = 0
        // Stage 2: this capture's OWN `homeDepth` (`nil` if `->detach()`ed)
        // becomes the target a `return`/`yield` fired directly inside this
        // body should unwind back down to — read via
        // `context.currentCaptureHomeDepth` by `setNonLocalReturnSignal`.
        context.pushCaptureHomeDepth(capture.homeDepth)
        // Stage 7: `currentCapture()`/the member form of `->givenBlock()`
        // both read the top of this stack — see its own doc comment.
        context.pushCurrentCapture(capture)
        context.pushGivenBlock(givenBlock)
        defer {
            context.replaceLocals(savedLocals)
            context.popTagCall()
            context.loopDepth = savedLoopDepth
            context.popCaptureHomeDepth()
            context.popCurrentCapture()
            context.popGivenBlock()
        }

        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        let output = try await renderNodes(capture.body, &context)
        if let returned = consumeReturnValueRespectingNonLocalTarget(activeDepth: context.tagCallStack.count) {
            // An explicit `return`/`yield` bypasses auto-collect
            // concatenation entirely (pre-existing Stage 2 behavior,
            // unchanged here) — the docs' own `autoCollectBuffer` worked
            // example only covers the normal fall-off-the-end
            // concatenation path below, so this Stage 7 addition
            // deliberately leaves the buffer untouched here rather than
            // guessing at undocumented explicit-return interaction.
            return returned
        }
        // Ch. "Captures": a plain capture that falls off the end without
        // an explicit `return`/`yield` produces `.void`; an auto-collect
        // capture instead "concatenates the result of calling the
        // `asString` method on every value produced inside the
        // capture... and produces that value" — approximated here as the
        // body's own rendered output string, matching every other value
        // this codebase's `asString`-family conversions already reduce
        // to a plain string representation. Also correctly covers the
        // "still propagating to an outer target" case: if a nested
        // return/yield hasn't reached ITS target yet, this capture's own
        // invocation must not manufacture an auto-collect/void value of
        // its own — it produces `.void` here and its caller's render loop
        // keeps unwinding, exactly like `invokeCustomTag`/`invokeMemberMethod`.
        let result: LassoValue = capture.autoCollect ? .string(output) : .void
        // Stage 7: "the auto-collected value will be returned and can be
        // accessed using `capture->autoCollectBuffer`" — retained on the
        // capture itself after a normal `->invoke()`/`()` call so a LATER,
        // separate `->autoCollectBuffer()` read sees the same value, per
        // the docs' own worked example. `->invokeAutoCollect()` explicitly
        // "will not update `capture->autoCollectBuffer`" (skipped via
        // `updatesAutoCollectBuffer: false`), and a non-auto-collect
        // capture never touches the buffer at all (stays `.void`).
        if capture.autoCollect, updatesAutoCollectBuffer {
            capture.setAutoCollectBuffer(result)
        }
        return result
    }

    /// Pulls a `=>`-associated capture block out of an already-evaluated
    /// argument list, returning it separately from the REMAINING
    /// arguments — used by every call site that can be invoked with an
    /// associated block (`invokeCustomTag`/`invokeMemberMethod`) so the
    /// block never participates in ordinary positional parameter
    /// binding or multiple-dispatch arity/type resolution.
    ///
    /// `foldAssociatedCapture` (`ExpressionParser.swift`) labels the
    /// capture argument `"givenblock"` specifically so it can be found
    /// and removed HERE, before `bindParameters`/`LassoMethodDispatcher
    /// .resolve` ever see it — architect review found a real bug in an
    /// earlier version that instead appended the capture as an ordinary
    /// UNLABELED positional argument: whenever a call provided fewer
    /// explicit arguments than a tag/method declares parameters (a
    /// completely normal shape, relying on trailing defaults), the
    /// appended capture would silently land in and overwrite an
    /// unrelated later parameter's default value instead of throwing or
    /// being recognizable — and when the explicit argument count already
    /// matched the parameter count exactly, the capture argument would
    /// be silently dropped with no signal at all, since `bindParameters`'
    /// own loop only ever binds up to `parameters.count`. Labeling it
    /// removes it from `callArguments.filter { $0.label == nil }`
    /// entirely, so neither failure mode can occur — the body reads it
    /// back via the real, documented `givenBlock` keyword (see
    /// `Evaluator.evaluate(_:)`'s own `.identifier` case) instead of an
    /// ordinary declared parameter.
    private static func extractGivenBlock(
        from arguments: [EvaluatedArgument]
    ) -> (givenBlock: LassoValue, remaining: [EvaluatedArgument]) {
        var remaining: [EvaluatedArgument] = []
        remaining.reserveCapacity(arguments.count)
        var givenBlock: LassoValue = .void
        for argument in arguments {
            if argument.label?.caseInsensitiveCompare("givenblock") == .orderedSame {
                givenBlock = argument.value
            } else {
                remaining.append(argument)
            }
        }
        return (givenBlock, remaining)
    }

    /// Stage 4 (Captures): the real, shared `->forEach` mechanism —
    /// invokes the call's associated `=>` block (its `givenBlock`) once
    /// per element of `elements`, in order. NOT itself a genuine
    /// invocation boundary the way `invokeCustomTag`/`invokeMemberMethod`/
    /// `invokeCapture` are (no `pushTagCall`/depth tracking of its own):
    /// it's sugar over a Swift-level loop of ordinary `invokeCapture`
    /// calls, deliberately mirroring `loop`/`iterate`/`with`'s own
    /// existing "native block construct, not a call boundary" shape
    /// (`Renderer.swift`) — checking `context.shouldStopRenderingCurrentBody()`
    /// after each invocation and stopping early is exactly what those
    /// blocks do too (recently fixed to do so for `return`/`yield`, not
    /// just `Loop_Abort`/`Loop_Continue`), so a non-local `return`/`yield`
    /// fired from inside the block correctly aborts remaining iterations
    /// and propagates on up to its real target — matching Ch. "Captures"'s
    /// own `contains()` worked example (`#a->forEach => { #val == #1 ?
    /// return true }`) exactly. Returns `.void` if no capture was
    /// associated at all (real Lasso's own forEach has no meaningful
    /// return value of its own; callers rely on side effects or a
    /// non-local exit, never this function's own result).
    private mutating func invokeForEachCapture(
        over elements: [LassoValue],
        evaluatedArguments: [EvaluatedArgument]
    ) async throws -> LassoValue {
        let (givenBlock, _) = Self.extractGivenBlock(from: evaluatedArguments)
        guard case let .capture(capture) = givenBlock else { return .void }
        for element in elements {
            _ = try await invokeCapture(capture, arguments: [EvaluatedArgument(label: nil, value: element)])
            if context.shouldStopRenderingCurrentBody() { break }
        }
        return .void
    }

    /// The real, documented Lasso 9.3 contract (Ch. "Query Expressions",
    /// "Making an Object Queriable") ties `forEach`-style iteration to
    /// `trait_forEach`/`trait_queriable` conformance in the abstract —
    /// concretely, for the collection types this interpreter already
    /// implements, that always cashes out to "produce this value's own
    /// element sequence." Shared by `->forEach` (this file) and
    /// `->insertFrom` (`Collections.swift`, Queue only — the one real,
    /// documented Lasso 9.3 `trait_forEach`-typed parameter) so both
    /// accept the SAME set of sources. A `.map` yields `Pair(key, value)`
    /// per element, sorted by key — matching `LassoIteratorValue.build`'s
    /// own already-established element-extraction shape
    /// (`Iterator.swift`), not `iterate`/`with`'s (`Renderer.swift`):
    /// found by review that those two iterate a `.map`'s raw, hash-order
    /// Swift `Dictionary` directly, with NO sorting, and `with` doesn't
    /// even yield `Pair`s for a map source (bare values only) — a real,
    /// pre-existing, benign inconsistency between `->forEach` (this
    /// stage, deterministic) and `iterate`/`with` (unspecified order)
    /// over the identical Map value, worth a future look but out of
    /// scope for this stage to fix. Not itself a separate documented
    /// `->forEachPair` method (real Lasso 9.3 has no such method;
    /// checked directly against lassoguide.com and
    /// reference.lassosoft.com, see the plan doc's own Stage 4 note).
    /// `nil` (not `.array([])`) for a value that doesn't conform at all,
    /// so callers can distinguish "empty collection" from "not a
    /// collection" if they need to. `static` (needs no `Evaluator`
    /// instance/`LassoContext`) so `Collections.swift`'s native-type
    /// method closures — which only ever receive `(receiver, arguments,
    /// context)`, never a full `Evaluator` — can call it directly for
    /// `->insertFrom`, exactly like this file's own `member(_:_:_:)` does
    /// for `->forEach`.
    static func forEachElements(of value: LassoValue) -> [LassoValue]? {
        switch value {
        case let .array(values): return values
        case let .map(entries):
            return entries.keys.sorted().map { .pair(.string($0), entries[$0] ?? .null) }
        case let .object(object):
            switch object.typeName.lowercased() {
            case "list", "queue", "stack", "set":
                return LassoCollectionValue.elements(from: object)
            case "queriable_grouping":
                // Ch. "Query Expressions": "a queriable_grouping object
                // maintains a reference to each of the original elements
                // within the group" — reuses the SAME `_elements`
                // storage-key convention as List/Set/etc. (Stage 8.4).
                return LassoCollectionValue.elements(from: object)
            case "priorityqueue":
                return LassoPriorityQueueValue.elements(from: object)
            case "treemap":
                // Already `.pair(key, value)` entries — matching the
                // `.map` case above's own Pair-yielding convention.
                return LassoTreeMapValue.entries(from: object)
            case "generateseries":
                // Ch. "Query Expressions", "GenerateSeries Type" — see
                // `Runtime.swift`'s `generateSeries` free-function
                // registration for how `_elements` is populated (Stage
                // 8.5). Same `_elements` convention as every other
                // collection-shaped native type here.
                return LassoCollectionValue.elements(from: object)
            case "eacher":
                // Ch. "Query Expressions", "Making an Object Queriable"
                // — see `member(_:_:_:)`'s `->eachCharacter` case for how
                // this is populated (Stage 8.5).
                return LassoCollectionValue.elements(from: object)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Materializes a with-clause source's element sequence, trying the
    /// closed set of built-in collection types `forEachElements(of:)`
    /// already recognizes FIRST, then falling back to the general,
    /// documented "Making an Object Queriable" mechanism (Ch. "Query
    /// Expressions") for a CUSTOM (user-defined) type: "An object can be
    /// used as the source of a `with` clause... if its type has
    /// implemented... the `forEach` member method." `nil` (not an empty
    /// array) for a value that's neither — lets the caller distinguish
    /// "genuinely not queriable" from "queriable but empty," matching
    /// `forEachElements(of:)`'s own established `nil` convention.
    private mutating func materializeQueriableElements(from value: LassoValue) async throws -> [LassoValue]? {
        if let native = Self.forEachElements(of: value) { return native }
        guard case let .object(object) = value else { return nil }
        return try await materializeCustomQueriableElements(from: object)
    }

    /// Bridges a CUSTOM type's own `forEach` member method into this
    /// interpreter's eager with-source materialization — see the docs'
    /// own worked `user_list` example (Ch. "Query Expressions", "Making
    /// an Object Queriable"): `public forEach() => { local(gb) =
    /// givenBlock #gb->invoke('Krinn'='Jones') ... }`. There's no Lasso
    /// SOURCE to parse a real `=>` capture literal from here (the given
    /// block this needs is entirely a Swift-side bookkeeping device), so
    /// this pushes a synthetic native `query_collector` object as the
    /// given block instead of a real `LassoCaptureValue` — `#gb
    /// ->invoke(element)` inside the user's `forEach` body dispatches
    /// through the exact SAME native-method lookup every other `.object`
    /// member call already uses (`context.nativeTypes.type(named:)?
    /// .method(named:)`, `member(_:_:_:)`'s own `.object` case), so
    /// `query_collector->invoke` (registered in `NativeTypes.swift`,
    /// alongside every other native type) just appends its one argument
    /// into the collector's own `_elements` array — reusing the SAME
    /// storage-key convention `LassoCollectionValue`/`queriable_grouping`
    /// already established, rather than inventing a new value shape or a
    /// new `LassoValue` case just to hold a Swift closure. Previously (
    /// Stages 8.1-8.4) this whole mechanism was a disclosed, out-of-scope
    /// gap — see `materializeQueriableElements`'s own doc comment for
    /// where that's now resolved.
    private mutating func materializeCustomQueriableElements(from object: LassoObjectInstance) async throws -> [LassoValue]? {
        guard let type = context.tagRegistry.type(named: object.typeName) else { return nil }
        let collector = LassoObjectInstance(typeName: "query_collector", data: ["_elements": .array([])])
        guard try await invokeMemberMethodWithNativeGivenBlock(
            named: "forEach",
            on: object,
            type: type,
            givenBlock: .object(collector)
        ) != nil else { return nil }
        return LassoCollectionValue.elements(from: collector)
    }

    /// Mirrors `invokeMemberMethod` (below) almost exactly — same
    /// resolve/bind/push-frame/render/pop-frame shape — but pushes a
    /// PRE-BUILT `LassoValue` given block directly instead of extracting
    /// one from a parsed `=>` call argument, since
    /// `materializeCustomQueriableElements` has no Lasso source to parse
    /// one from at all. A separate function rather than threading an
    /// optional pre-built given block through `invokeMemberMethod`
    /// itself, so that function's existing, already-reviewed argument-
    /// evaluation path stays untouched for its many other call sites.
    /// Always called with zero arguments — real Lasso's own `forEach`
    /// contract for this mechanism is nullary (`public forEach() => {...}`
    /// in the docs' own worked example).
    private mutating func invokeMemberMethodWithNativeGivenBlock(
        named name: String,
        on object: LassoObjectInstance,
        type: LassoTypeDefinition,
        givenBlock: LassoValue
    ) async throws -> LassoValue? {
        if skipIfNonLocalReturnAlreadyPending() { return .void }
        guard let resolved = LassoMethodDispatcher.resolve(method: name, on: type, arguments: []) else {
            return nil
        }
        let boundLocals = try await bindParameters(resolved.definition.parameters, to: resolved.evaluatedArguments)
        let savedLocals = context.snapshotLocals()
        let savedLoopDepth = context.loopDepth
        try context.pushTagCall(name)
        context.replaceLocals(boundLocals)
        context.pushSelf(object)
        context.pushGivenBlock(givenBlock)
        context.loopDepth = 0
        defer {
            context.popGivenBlock()
            context.popSelf()
            context.popTagCall()
            context.replaceLocals(savedLocals)
            context.loopDepth = savedLoopDepth
        }
        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        _ = try await renderNodes(resolved.definition.body, &context)
        return consumeReturnValueRespectingNonLocalTarget(activeDepth: context.tagCallStack.count) ?? .void
    }

    /// Ch. "Query Expressions" — see `LassoExpression.queryExpression`'s
    /// own doc comment for this feature's overall scope across Stages
    /// 8.1-8.5.
    ///
    /// The with-source is materialized via `materializeQueriableElements`
    /// — real Lasso ties query-expression sourcing to `trait_queriable`
    /// in the abstract, which for every BUILT-IN collection type this
    /// interpreter implements already cashes out to
    /// `forEachElements(of:)`'s own existing element sequence (Ch. "Query
    /// Expressions", "Making an Object Queriable": "any object whose type
    /// supports the `trait_queriable` trait, such as an array or a
    /// list"). Stage 8.5 additionally resolves a CUSTOM user-defined
    /// type's own `forEach` member (the docs' own worked `user_list`
    /// example) — previously (Stages 8.1-8.4) a disclosed, out-of-scope
    /// gap — via `materializeCustomQueriableElements`'s synthetic
    /// `query_collector` given-block bridge; see that function's own doc
    /// comment for how it avoids needing a genuinely new `LassoValue`
    /// case just to hold a Swift closure.
    ///
    /// Real Lasso evaluates query expressions LAZILY ("creating the query
    /// expression does not execute it... only when something else
    /// attempts to draw elements from it") except `do`, which is always
    /// immediate. This implementation is EAGER for `select` too — the
    /// with-source is fully materialized and every operation/action runs
    /// to completion as soon as the query-expression EXPRESSION itself is
    /// evaluated, producing a plain `.array`/`.void` result rather than a
    /// reusable, re-drawable deferred object. A disclosed, deliberate
    /// simplification: laziness only differs OBSERVABLY from eager
    /// evaluation when the source/captured state mutates between
    /// creation and consumption, or when short-circuiting (`take`, added
    /// in Stage 8.2, but implemented eagerly here too — every upstream
    /// operation still runs to completion before the row list is
    /// trimmed) should skip upstream work entirely — neither shows up in
    /// any of the real docs' own worked examples, all of which show
    /// only a query expression's PRODUCED VALUE, and building a genuine
    /// deferred-execution runtime would be a materially larger, separate
    /// undertaking disproportionate to this project's zero corpus
    /// evidence for Query Expressions at all (built anyway for real
    /// Lasso 9 completeness, not corpus need — see this project's own
    /// corpus-evidence-not-sole-bar convention).
    private mutating func evaluateQueryExpression(
        withClauses: [QueryWithClause],
        operations: [QueryOperation],
        action: QueryAction
    ) async throws -> LassoValue {
        // "New variables introduced by a query expression clause will
        // not be available outside of the query expression that
        // introduces them" — same save/restore discipline `invokeCapture`
        // uses for its own `#1`/`#2` bindings. Covers every with-variable
        // AND every `let`-introduced name (Ch. "Query Expressions":
        // "variables introduced with a `let` operation have the SAME
        // SCOPE as those introduced in a `with` clause").
        let savedLocals = context.snapshotLocals()
        defer { context.replaceLocals(savedLocals) }
        // Every name this query expression can ever bind is known
        // STATICALLY from its own AST (every with-clause's own variable,
        // plus each `let`/`group by` operation's own name) — collected up
        // front so ONE box per name can be created ONCE, before any row
        // is processed, and then MUTATED in place (`box.value = ...`) as
        // rows/stages advance, rather than replaced with a fresh box each
        // time. Real bug found live while implementing this: an earlier
        // cut created a brand-new box PER ROW PER STAGE (the exact fix
        // Stage 8.1 needed to stop corrupting a same-named OUTER local —
        // see that box's own doc comment history) — but a `do` capture
        // literal is constructed ONCE, BEFORE any row is bound, and
        // needs a LIVE REFERENCE to the with-variable's box that later
        // per-row binding steps go on to update; creating fresh boxes
        // per row broke that reference entirely, since the capture's own
        // snapshot pointed at a box nothing else ever touched again.
        // Reusing ONE persistent box per name (still fresh relative to
        // `savedLocals`, so an outer same-named local is still never
        // touched) satisfies both constraints at once. Matches this
        // codebase's own established convention for ordinary loop
        // variables (`Renderer.swift`'s `iterate`/`with` block tags
        // already mutate ONE shared box per iteration via `context.set`,
        // doc-verified against lassoguide.com during Stage 3) — Stage
        // 8.2's query rows are the same "one box, mutated per element"
        // shape, not a new pattern. Same caveat applies here too, found
        // by architect review: a `select`/`do` payload that itself
        // STORES a capture literal per row for invocation LATER (outside
        // this function) would have every such capture share the SAME
        // box, observing whatever value it was left at when the whole
        // query expression finished — a classic "closure over a shared
        // loop variable" effect. No real corpus/doc evidence for this
        // shape (every worked example reads row values immediately), so
        // disclosed here rather than built around.
        var queryOwnedBoxes: [String: LassoLocalBox] = [:]
        for clause in withClauses {
            queryOwnedBoxes[clause.variable.lowercased()] = LassoLocalBox(.void)
        }
        for operation in operations {
            if case let .let(name, _) = operation {
                queryOwnedBoxes[name.lowercased()] = LassoLocalBox(.void)
            }
            if case let .groupBy(_, _, newName) = operation {
                queryOwnedBoxes[newName.lowercased()] = LassoLocalBox(.void)
            }
        }
        var scopedLocals = savedLocals
        for (name, box) in queryOwnedBoxes { scopedLocals[name] = box }
        context.replaceLocals(scopedLocals)

        func bind(_ row: [String: LassoValue]) {
            for (name, value) in row {
                queryOwnedBoxes[name]?.value = value
            }
        }

        // Stage 8.5: "Multiple with clauses define a nesting of
        // iterations" — the SECOND (and later) with-clause's own source
        // expression can reference an EARLIER clause's variable (`with
        // variable_name in source, another_name in #variable_name`), so
        // clauses are materialized LEFT TO RIGHT, cross-joining: for
        // every row surviving so far, bind it (making prior with-
        // variables visible), evaluate the NEXT clause's source, and fan
        // out one new row per element it produces. A single with-clause
        // (the only shape Stages 8.1-8.4 ever had) is just this loop
        // running once, starting from one empty seed row.
        var rows: [[String: LassoValue]] = [[:]]
        for clause in withClauses {
            var expanded: [[String: LassoValue]] = []
            expanded.reserveCapacity(rows.count)
            for row in rows {
                bind(row)
                let sourceValue = try await evaluate(clause.source)
                guard let elements = try await materializeQueriableElements(from: sourceValue) else {
                    throw LassoRuntimeError.unsupportedExpression("with \(clause.variable) in <non-queriable source>")
                }
                for element in elements {
                    var newRow = row
                    newRow[clause.variable.lowercased()] = element
                    expanded.append(newRow)
                }
                if context.shouldStopRenderingCurrentBody() { break }
            }
            rows = expanded
        }
        for operation in operations {
            switch operation {
            case let .filter(expr):
                var kept: [[String: LassoValue]] = []
                for row in rows {
                    bind(row)
                    if try await evaluate(expr).isTruthy { kept.append(row) }
                    if context.shouldStopRenderingCurrentBody() { break }
                }
                rows = kept
            case let .let(name, expr):
                var updated: [[String: LassoValue]] = []
                for row in rows {
                    bind(row)
                    let value = try await evaluate(expr)
                    var newRow = row
                    newRow[name.lowercased()] = value
                    updated.append(newRow)
                    if context.shouldStopRenderingCurrentBody() { break }
                }
                rows = updated
            case let .skip(expr):
                // Ch. "Query Expressions": "a `skip` operation permits a
                // specified number of values... to be skipped" — a
                // SEQUENCE-level count, not tied to any particular
                // element, so evaluated with NO row bound (the ambient
                // surrounding scope only, matching how `select`/`do`'s
                // own action expression is never implicitly evaluated
                // "per nothing" either).
                context.replaceLocals(savedLocals)
                let count = try await evaluate(expr).number.map(Int.init) ?? 0
                context.replaceLocals(scopedLocals)
                rows = Array(rows.dropFirst(max(0, count)))
            case let .take(expr):
                context.replaceLocals(savedLocals)
                let count = try await evaluate(expr).number.map(Int.init) ?? 0
                context.replaceLocals(scopedLocals)
                rows = Array(rows.prefix(max(0, count)))
            case let .orderBy(keys):
                // Ch. "Query Expressions", "Order By": each row's sort
                // key(s) are computed ONCE per row (async), then the row
                // list is sorted SYNCHRONOUSLY using
                // `Evaluator.lassoLessThan` — the SAME single source of
                // truth this codebase already uses for `Array->Sort`/
                // Set/PriorityQueue/TreeMap ordering and the raw `<`/`>`
                // operators, reused here rather than inventing a second,
                // parallel comparison (real Lasso's own wording: "the
                // standard less than and greater than operators are used
                // to find the result value"). Multiple keys compare
                // LEXICOGRAPHICALLY (first key decides unless tied, then
                // the next, and so on) — matching "further ordering
                // criteria can be specified... the next ordering
                // expression" as tiebreakers, not independent sorts.
                // `sorted(by:)` is a stable sort (guaranteed since Swift
                // 5), so fully-tied rows keep their relative order.
                var keyedRows: [(row: [String: LassoValue], keys: [LassoValue])] = []
                keyedRows.reserveCapacity(rows.count)
                for row in rows {
                    bind(row)
                    var rowKeys: [LassoValue] = []
                    rowKeys.reserveCapacity(keys.count)
                    for key in keys {
                        rowKeys.append(try await evaluate(key.expression))
                    }
                    keyedRows.append((row, rowKeys))
                    if context.shouldStopRenderingCurrentBody() { break }
                }
                let directions = keys.map(\.descending)
                keyedRows.sort { lhs, rhs in
                    for index in 0..<min(lhs.keys.count, rhs.keys.count) {
                        let descending = directions[index]
                        if Evaluator.lassoLessThan(lhs.keys[index], rhs.keys[index]) { return !descending }
                        if Evaluator.lassoLessThan(rhs.keys[index], lhs.keys[index]) { return descending }
                    }
                    return false
                }
                rows = keyedRows.map(\.row)
            case let .groupBy(objectExpression, keyExpression, newName):
                // Ch. "Query Expressions", "Group By": for each row,
                // evaluate the object and key expressions (using
                // whatever variables were bound BEFORE this group by
                // fired), then bucket rows sharing an EQUAL key value
                // together (reusing the existing `binary(_:"==",_:)` —
                // real Lasso doesn't document precisely which equality
                // group-by uses, so this reuses the SAME operator this
                // codebase's own `==` already implements, consistent
                // with `order by`/`min`/`max` reusing `<`/`>` rather than
                // inventing a parallel comparison). Groups are kept in
                // FIRST-OCCURRENCE order — the docs don't specify a
                // default order either, and this is the most natural
                // reading absent one (the docs' own worked example
                // re-sorts explicitly with a trailing `order by`
                // afterward, so its own output order doesn't depend on
                // this choice).
                var groupsInOrder: [(key: LassoValue, elements: [LassoValue])] = []
                for row in rows {
                    bind(row)
                    let objectValue = try await evaluate(objectExpression)
                    let keyValue = try await evaluate(keyExpression)
                    var matchedIndex: Int?
                    for (index, group) in groupsInOrder.enumerated() {
                        if try binary(group.key, "==", keyValue).isTruthy {
                            matchedIndex = index
                            break
                        }
                    }
                    if let matchedIndex {
                        groupsInOrder[matchedIndex].elements.append(objectValue)
                    } else {
                        groupsInOrder.append((keyValue, [objectValue]))
                    }
                    if context.shouldStopRenderingCurrentBody() { break }
                }
                // "From this point forward, no previously introduced
                // variables are available. Only [the new name] exists
                // now" — each resulting row is a FRESH dictionary with
                // ONLY the new name, not a superset of the old row (a
                // disclosed, minor imperfection: the OLD with-/let-
                // variables' own boxes still technically exist in
                // `queryOwnedBoxes`/`context.locals`, so reading them
                // after this point doesn't throw — it just reads
                // whatever STALE value the last-processed row left
                // behind, rather than becoming truly undefined; a real
                // user doing this would immediately notice something is
                // wrong, so this isn't a silent correctness trap, just
                // an imperfect enforcement of the documented hard
                // boundary — perfectly enforcing it would need either an
                // error-on-access mechanism or explicitly unbinding boxes
                // mid-query, neither of which fits this codebase's
                // existing box-lifetime model without deeper rework, and
                // there's zero corpus evidence pushing for it).
                rows = groupsInOrder.map { group in
                    let groupingObject = LassoObjectInstance(
                        typeName: "queriable_grouping",
                        data: ["_key": group.key, "_elements": .array(group.elements)]
                    )
                    return [newName.lowercased(): .object(groupingObject)]
                }
            }
        }
        switch action {
        case let .select(transform):
            var results: [LassoValue] = []
            results.reserveCapacity(rows.count)
            for row in rows {
                bind(row)
                results.append(try await evaluate(transform))
                if context.shouldStopRenderingCurrentBody() { break }
            }
            return .array(results)
        case let .perform(payload):
            // "It is important to note that when using `do` the query is
            // immediately evaluated and that the query expression
            // produces no result value... The block of code given to a
            // `do` remains attached to the surrounding method context,
            // such that one could return or yield" — a capture literal
            // payload is evaluated ONCE (so its home/capturedLocals
            // reflect the ambient surrounding context, matching every
            // other capture literal's own semantics) and then invoked
            // once per row, mirroring `invokeForEachCapture`'s own
            // established pattern; a bare-expression payload has no
            // capture semantics at all and is simply re-evaluated fresh
            // for each row, reading the with-variable (and any
            // `let`-introduced names) directly.
            if case let .captureLiteral(body, autoCollect) = payload {
                let capture = LassoCaptureValue(
                    body: body,
                    autoCollect: autoCollect,
                    capturedLocals: context.snapshotLocals(),
                    homeDepth: context.currentCaptureHomeDepth ?? context.tagCallStack.count
                )
                for row in rows {
                    bind(row)
                    _ = try await invokeCapture(capture, arguments: [])
                    if context.shouldStopRenderingCurrentBody() { break }
                }
            } else {
                // A bare-expression `do` payload occupies the SAME
                // "statement root" position a real top-level statement
                // would — the docs' own example is a bare self-mutating
                // method call (`with n in #ary do #n->upperCase`). Found
                // live: calling plain `evaluate(_:)` here silently
                // computed `$collected->insert(...)`'s result and threw
                // it away instead of writing it back, since `.array` is
                // a Swift value type and self-mutating write-back
                // (`->insert`/`->replace`/etc.) only happens via
                // `evaluateStatement`'s own dedicated check — the exact
                // same mechanism a real top-level `[...]`/script-mode
                // statement already goes through via
                // `Renderer.renderExpression`, which this do-loop must
                // replicate since it's evaluating each row OUTSIDE that
                // normal per-statement render path.
                for row in rows {
                    bind(row)
                    _ = try await evaluateStatement(payload)
                    if context.shouldStopRenderingCurrentBody() { break }
                }
            }
            return .void
        case let .sum(expr):
            // Ch. "Query Expressions": "the summation is performed using
            // the `+` operator, so each element in the sequence must
            // support the addition operator for the sum to succeed" —
            // reuses this codebase's own existing `binary(_:"+"​:_:)`
            // rather than a separate numeric-only accumulator, so
            // string-concatenation-style sums (real Lasso's `+` handles
            // both) work identically to the real operator. No worked
            // example covers an EMPTY result set — `.null` chosen for
            // consistency with `min`/`max` below (a fold with no seed
            // value has nothing to report), not an assumed `0` identity.
            var accumulated: LassoValue?
            for row in rows {
                bind(row)
                let value = try await evaluate(expr)
                accumulated = try accumulated.map { try binary($0, "+", value) } ?? value
                if context.shouldStopRenderingCurrentBody() { break }
            }
            return accumulated ?? .null
        case let .average(expr):
            // "As expected, using average will take the sum of each
            // element and then divide that value by the number of
            // elements" — literally sum via the same `+` fold as `.sum`
            // above, then a single `binary(_:"/"​:_:)` division; same
            // disclosed `.null`-on-empty choice (also sidesteps a
            // divide-by-zero for the genuinely-empty case, which isn't
            // really an ERROR condition here so much as "nothing to
            // average").
            var accumulated: LassoValue?
            var count = 0
            for row in rows {
                bind(row)
                let value = try await evaluate(expr)
                accumulated = try accumulated.map { try binary($0, "+", value) } ?? value
                count += 1
                if context.shouldStopRenderingCurrentBody() { break }
            }
            guard let sum = accumulated, count > 0 else { return .null }
            return try binary(sum, "/", .integer(count))
        case let .min(expr):
            // "The standard less than (<) and greater than (>) operators
            // are used to find the result value" — reuses the SAME
            // `Evaluator.lassoLessThan` `order by` above already reuses,
            // not a separate min/max-specific comparison. `.null` on
            // empty matches this codebase's own established
            // `Array->First`-on-empty convention (`Evaluator.swift`'s
            // `.array, "first"` case).
            var best: LassoValue?
            for row in rows {
                bind(row)
                let value = try await evaluate(expr)
                if best == nil || Evaluator.lassoLessThan(value, best!) { best = value }
                if context.shouldStopRenderingCurrentBody() { break }
            }
            return best ?? .null
        case let .max(expr):
            var best: LassoValue?
            for row in rows {
                bind(row)
                let value = try await evaluate(expr)
                if best == nil || Evaluator.lassoLessThan(best!, value) { best = value }
                if context.shouldStopRenderingCurrentBody() { break }
            }
            return best ?? .null
        }
    }

    /// Every bound parameter gets its OWN fresh box — a tag/method call
    /// always starts an entirely new, isolated local scope (see
    /// `invokeCustomTag`'s own doc comment: "a fresh, isolated local scope
    /// so the tag body's #locals can't leak into or clobber the caller's"),
    /// so nothing here should ever share a box with the caller's own
    /// scope, matching `invokeCapture`'s identical treatment of `#1`/`#2`.
    private mutating func bindParameters(
        _ parameters: [LassoArgument],
        to callArguments: [EvaluatedArgument]
    ) async throws -> [String: LassoLocalBox] {
        let positional = callArguments.filter { $0.label == nil }
        var positionalIndex = 0
        var bound: [String: LassoLocalBox] = [:]

        for parameter in parameters {
            let (name, defaultExpression) = Self.parameterNameAndDefault(parameter.value)
            guard let name else { continue }

            if let labeled = callArguments.first(where: {
                $0.label?.caseInsensitiveCompare(name) == .orderedSame
            }) {
                bound[name.lowercased()] = LassoLocalBox(labeled.value)
            } else if positionalIndex < positional.count {
                bound[name.lowercased()] = LassoLocalBox(positional[positionalIndex].value)
                positionalIndex += 1
            } else if let defaultExpression {
                bound[name.lowercased()] = LassoLocalBox(try await evaluate(defaultExpression))
            } else {
                bound[name.lowercased()] = LassoLocalBox(.null)
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
    ) async throws -> LassoValue {
        let object = LassoObjectInstance(typeName: type.name)
        // Legacy constructors (e.g. `local('ip' = (params->first ? ...))`)
        // reference the constructor call's own arguments as `params` while
        // data member defaults are evaluated — see
        // Documentation/legacy-define-tag-type-plan.md's "Constructor
        // params" note. Bound as an ordinary local (not passed through
        // invokeMemberMethod's own parameter binding) so it's visible here
        // and restored to whatever it was before once construction ends.
        //
        // Stage 3 (Captures) found a real, capture-unrelated bug in how
        // this "restore" used to work: `context.set(...)` MUTATES an
        // EXISTING box in place when one already exists for that name —
        // exactly what makes closures see later same-slot writes — so if
        // the CALLING scope already had its own local literally named
        // "params", the old `context.set(...)` here permanently
        // overwrote THAT box's value with the constructor's own argument
        // array, and `context.replaceLocals(savedLocals)` afterward
        // didn't undo it (it restores the name→box MAPPING, not a
        // mutated box's contents, and it's the identical box either
        // way). Fixed by inserting a FRESH box for "params" into a COPY
        // of the ambient scope instead of mutating whatever box (if any)
        // already occupied that name — every OTHER name in the ambient
        // scope still resolves to the SAME shared boxes as before (data
        // member defaults/`onCreate` keep seeing the calling scope's own
        // other locals, unchanged), but "params" specifically points at
        // a brand-new box this constructor call owns exclusively, so the
        // caller's own pre-existing "params" (if any) is never touched
        // at all and needs no real "restoring."
        let evaluatedCallArguments = try await evaluate(callArguments)
        let savedLocals = context.snapshotLocals()
        var scopedLocals = savedLocals
        scopedLocals["params"] = LassoLocalBox(.array(evaluatedCallArguments.map(\.value)))
        context.replaceLocals(scopedLocals)
        defer { context.replaceLocals(savedLocals) }
        for member in type.dataMembers {
            if let defaultValue = member.defaultValue {
                object.set(try await evaluate(defaultValue), for: member.name)
            } else {
                object.set(.null, for: member.name)
            }
        }
        if let onCreate = try await invokeMemberMethod(
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

    /// `.object`'s own `typeName` (e.g. "regexp", "date", or a custom
    /// user-defined type's name) is returned exactly as registered/
    /// defined — lassoguide.com's own doc says `null->type()` "Returns...
    /// the name that was used when the type was defined." Every other
    /// case is capitalized to match the Lasso 8.5 Language Guide's own
    /// worked examples verbatim (Ch. 43 p.560: `[123->Type] → Integer`,
    /// `[123.456->Type] → Decimal`, `['String'->Type] → String`,
    /// `[Null->Type] → Null`, `[(Array: 1,2,3)->Type] → Array`) —
    /// `.boolean`/`.map`/`.pair` have no worked example in the Guide but
    /// follow the same capitalization convention.
    static func introspectionTypeName(for value: LassoValue) -> String {
        if case .object = value { return value.typeName }
        return value.typeName.prefix(1).uppercased() + value.typeName.dropFirst()
    }

    /// `Null->Type`/`->IsA`/`->IsNotA`/`->HasMethod` (Lasso 8.5 Language
    /// Guide Ch. 43 Table 6 "Null Member Tags", pp.559-560; `->IsNotA`
    /// and `->HasMethod` verified against lassoguide.com's Lasso 9
    /// "Type/Object Introspection Methods" section, since 8.5's table
    /// doesn't list them). Returns `nil` when `normalized` isn't one of
    /// these four names, so every call site below treats it as a
    /// LOW-PRIORITY fallback — checked only after real data/methods have
    /// already had a chance to match: `.map`'s existing key-first design
    /// (a literal `"type"` key, e.g. a file upload's content type, must
    /// still win — an earlier version that checked this unconditionally
    /// broke exactly that, caught by
    /// `fileUploadsExposeMetadataUnderBothLasso9And8KeyNames` failing)
    /// and `.object`'s existing native-method-then-custom-method chain
    /// (a real user-defined `type`/`isA` method, however unlikely, wins
    /// too). This codebase has no type-inheritance/trait model at all (a
    /// custom `define_type`'s parent/base names are parsed but not yet
    /// acted on — see Renderer.swift's own "define_type" case), so
    /// `->IsA` here matches Lasso 8.5's simpler documented semantics
    /// ("Returns true if the object is of that type... or inherits from
    /// that type") as a flat, case-insensitive exact-type-name match —
    /// NOT Lasso 9's richer integer 0-3 trait/parent-aware return value.
    private mutating func introspectionResult(
        _ normalized: String,
        _ value: LassoValue,
        _ arguments: [LassoArgument]
    ) async throws -> LassoValue? {
        switch normalized {
        case "type":
            return .string(Self.introspectionTypeName(for: value))
        case "isa", "isnota":
            let requested = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            let matches = value.typeName.caseInsensitiveCompare(requested) == .orderedSame
            return .boolean(normalized == "isa" ? matches : !matches)
        case "hasmethod":
            let requested = (arguments.first != nil ? try await evaluate(arguments[0].value).outputString : "").lowercased()
            return .boolean(hasMethod(named: requested, on: value))
        default:
            return nil
        }
    }

    /// `.object`: consults the SAME two registries the `.object` case
    /// further below checks when actually dispatching a call (native
    /// type methods, then a user-defined `define_type`'s methods) —
    /// existence-only, no argument/overload matching. Primitives: no
    /// unified per-type method registry exists here (each is a
    /// hand-written `case` in `member()`'s own switch above), so this
    /// consults a hand-maintained mirror of those case labels instead —
    /// verified complete against `member()`'s switch as of this writing,
    /// but NOT auto-derived from it, so a future member-case addition
    /// needs a matching update here or `->HasMethod` will under-report.
    /// `type`/`isA`/`isNotA`/`hasMethod` themselves are always reported
    /// present, matching the Guide's own framing of these as base tags
    /// "available for use with values of any data type" — every OTHER
    /// Table 6 tag (`->Serialize`, `->Properties`, etc.) is intentionally
    /// excluded since this stage doesn't implement them; claiming one
    /// exists via `->HasMethod` while `->Serialize` itself still throws
    /// would be worse than not answering at all.
    private func hasMethod(named requested: String, on value: LassoValue) -> Bool {
        if Self.introspectionMethodNames.contains(requested) { return true }
        if case let .object(object) = value {
            if context.nativeTypes.type(named: object.typeName)?.method(named: requested) != nil {
                return true
            }
            if let type = context.tagRegistry.type(named: object.typeName) {
                return type.methods.contains { $0.name.lowercased() == requested }
            }
            return false
        }
        return Self.primitiveMethodNames[value.typeName]?.contains(requested) ?? false
    }

    private static let introspectionMethodNames: Set<String> = ["type", "isa", "isnota", "hasmethod"]

    private static let primitiveMethodNames: [String: Set<String>] = [
        "string": [
            "size", "uppercase", "lowercase", "asstring", "encodehtml", "encodeurl",
            "encodesmart", "encodebreak", "encodexml", "encodestricturl", "encodesql",
            "encodebase64", "decodebase64", "contains", "beginswith", "endswith",
            "equals", "compare", "comparecodepointorder", "find", "get", "split",
            "replace", "append", "trim", "padleading", "padtrailing", "removeleading",
            "removetrailing", "reverse", "titlecase", "substring", "sub",
        ],
        "integer": ["asstring", "ceil"],
        "decimal": ["asstring", "ceil"],
        "pair": ["first", "second", "size", "get"],
        "array": [
            "size", "first", "insert", "get", "last", "second", "reverse", "sort",
            "join", "contains", "find", "findposition", "remove", "removeall",
        ],
        "map": ["insert", "remove", "removeall", "size", "keys", "values", "contains", "find"],
    ]

    private mutating func invokeMemberMethod(
        named name: String,
        on object: LassoObjectInstance,
        type: LassoTypeDefinition,
        arguments: [LassoArgument],
        missingIsVoid: Bool = false
    ) async throws -> LassoValue? {
        // Stage 2 (Captures): see `skipIfNonLocalReturnAlreadyPending()`'s
        // own doc comment. `.void` here (not `nil`) — `nil` specifically
        // means "no such method", which would incorrectly redirect the
        // caller to some other fallback dispatch path instead of just
        // short-circuiting this already-resolved call.
        if skipIfNonLocalReturnAlreadyPending() { return .void }
        let (givenBlock, evaluatedCallArguments) = Self.extractGivenBlock(from: try await evaluate(arguments))
        guard let resolved = LassoMethodDispatcher.resolve(
            method: name,
            on: type,
            arguments: evaluatedCallArguments
        ) else {
            if missingIsVoid { return .void }
            return nil
        }
        let boundLocals = try await bindParameters(resolved.definition.parameters, to: resolved.evaluatedArguments)
        let savedLocals = context.snapshotLocals()
        let savedLoopDepth = context.loopDepth
        // Found missing while wiring up Stage 2's depth-based non-local
        // return propagation: unlike `invokeCustomTag`, this function
        // never pushed onto `tagCallStack` at all — meaning every type-
        // method call shared whatever depth was already active from any
        // ENCLOSING free-tag call, with no depth increment of its own.
        // Harmless before Stage 2 (nothing measured depth), but two
        // real, independent problems once something does: (1) a capture
        // created inside one method call's body would record the same
        // `homeDepth` as an unrelated SIBLING or NESTED method call at
        // the same free-tag nesting level, letting a non-local
        // return/yield be consumed by the wrong frame; (2) type-method
        // calls had no recursion-depth guard at all (only free-tag calls
        // did, via this same `pushTagCall`'s built-in max-depth-20
        // check) — a self-recursive method with no base case could
        // recurse unboundedly. Fixed by pushing here too, matching
        // `invokeCustomTag`'s own discipline exactly.
        try context.pushTagCall(name)
        context.replaceLocals(boundLocals)
        context.pushSelf(object)
        context.pushGivenBlock(givenBlock)
        // See the matching comment in `invokeCustomTag`.
        context.loopDepth = 0
        defer {
            context.popGivenBlock()
            context.popSelf()
            context.popTagCall()
            context.replaceLocals(savedLocals)
            context.loopDepth = savedLoopDepth
        }

        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        _ = try await renderNodes(resolved.definition.body, &context)
        return consumeReturnValueRespectingNonLocalTarget(activeDepth: context.tagCallStack.count) ?? .void
    }

    /// `Var`/`Variable` and `Global` are read/write tags (Ch. 15 Tables 1
    /// and 3); `Var_Reset`/`Local_Reset`/`Global_Reset` are documented as
    /// their "detach any references, then set" siblings. This codebase
    /// doesn't implement Lasso's `@`/`[Reference]` variable-aliasing
    /// system (deferred — see Documentation/lasso9-lassoguide-gap-analysis-plan.md's
    /// Stage 4 note: it needs new `@`-operator parser support and a
    /// variable-storage indirection layer neither of which exist today,
    /// a materially bigger and riskier change than every other gap
    /// closed this batch), so "detaching references" has nothing to do
    /// here — the `_Reset` variants are implemented as plain synonyms
    /// for their base tag, which is the correct, honest behavior for a
    /// codebase with no references to detach in the first place.
    private static func declarationScope(for name: String) -> VariableScope? {
        switch name.lowercased() {
        // `Var_Set` is Lasso 8.5's original free-tag name for what Lasso 9
        // shortened to `Var`/`Variable` (real corpus: TS_lasso9, 15/60
        // files use `[var_set:'name' = value]`, currently unknownFunction
        // since only the shortened names were registered) — same global
        // scope, no separate semantics.
        case "var", "variable", "var_reset", "var_set": .global
        case "local", "local_reset": .local
        case "global", "global_reset": .trueGlobal
        default: nil
        }
    }

    private mutating func declare(_ arguments: [LassoArgument], scope: VariableScope) async throws -> LassoValue {
        // Assignment-form calls (`local('x' = 1)`) keep returning `.void` —
        // real corpus code commonly uses this as a bare statement inside a
        // `[...]` template span and relies on it producing no output.
        // Only the legacy Lasso 8 READ form — `(Local: 'name')`/`(Var:
        // 'name')`, a call with no assignment at all — fetches and returns
        // the variable's current value. Real Lasso 8.5 docs: "The value
        // for the local variable can be returned with the [Local] tag."
        // See Documentation/legacy-define-tag-type-plan.md.
        var readValue: LassoValue?
        for argument in arguments {
            if case let .assignment(target, value) = argument.value {
                let evaluated = try await evaluate(value)
                try await assign(evaluated, to: target, defaultScope: scope)
            } else if let name = Self.assignmentLabel(argument.value) {
                readValue = context.value(for: name, scope: scope)
                // Stage 3 (Captures): a bare `local(name)` declaration (no
                // `=` value) must bring `name` into existence as a real,
                // addressable storage cell RIGHT NOW — not defer creation
                // until first assignment — so a capture literal evaluated
                // between this declaration and a LATER `#name = value`
                // assignment still closes over the SAME cell that
                // assignment mutates (Ch. "Captures" §1.5's own worked
                // example does exactly this shape). This same branch also
                // covers the legacy read-only `(Local: 'name')` form, but
                // that's harmless: `local_defined`/`var_defined` already
                // check for `.null`, not box existence (see
                // `LassoContext.trueGlobalDefined`'s own established
                // precedent for this exact simplification), so creating an
                // empty box here changes nothing observable for either
                // form.
                if scope == .local {
                    context.ensureLocalExists(name)
                }
            }
        }
        return readValue ?? .void
    }

    private mutating func assign(
        _ value: LassoValue,
        to target: LassoExpression,
        defaultScope: VariableScope
    ) async throws {
        switch target {
        case let .binary(left, "::", _):
            try await assign(value, to: left, defaultScope: defaultScope)
        case let .call(callee, arguments) where Self.isVarOrLocalCallee(callee) && arguments.count == 1 && arguments[0].label == nil:
            // `Var(name::type) = value` / `Local(name::type) = value` — the
            // declare-then-assign form (distinct from `var(name::type =
            // default)`, which is a single call already handled via
            // `declare(_:local:)`). Real corpus: pages/thumbs.page.lasso's
            // `[Var(cleaned_product_name::string) = string(Field(...))]`.
            // The `::type` annotation carries no runtime meaning here (this
            // codebase doesn't enforce declared types), so this just
            // unwraps to the same name/scope assignment as a bare
            // `$name = value`, reusing the `::` unwrap above.
            guard case let .identifier(callee) = callee else {
                throw LassoRuntimeError.invalidAssignment
            }
            let scope: VariableScope = callee.caseInsensitiveCompare("local") == .orderedSame ? .local : .global
            try await assign(value, to: arguments[0].value, defaultScope: scope)
        case let .variable(name, scope):
            context.set(value, for: name, scope: scope == .unscoped ? defaultScope : scope)
        case let .identifier(name):
            context.set(value, for: name, scope: defaultScope)
        case let .string(name):
            context.set(value, for: name, scope: defaultScope)
        case let .member(base, name, memberArguments):
            let normalizedName = name.lowercased()
            let baseValue: LassoValue
            if case let .identifier(baseName) = base,
               baseName.caseInsensitiveCompare("self") == .orderedSame,
               let object = context.currentSelf {
                baseValue = .object(object)
            } else {
                baseValue = try await evaluate(base)
            }
            // Stage 7 (Captures): `capture->autoCollectBuffer = value` —
            // the getter (`->autoCollectBuffer()`) and this setter are
            // both listed as their own distinct documented methods (Ch.
            // "Captures", "Capture Methods"). `LassoCaptureValue` is a
            // reference type (like `.object`, unlike `.pair`/`.map`
            // below), so this mutates the existing instance directly —
            // no recursive reassignment needed.
            if normalizedName == "autocollectbuffer", case let .capture(capture) = baseValue {
                capture.setAutoCollectBuffer(value)
                return
            }
            // `Pair->First=`/`->Second=` (Ch. 30 Table 9, p.404: "Can be
            // used as the left parameter of an assignment operator to
            // change the first/second element") and `Queue->First=`/
            // `Stack->First=` (Tables 13/18: "[Queue->First] returns
            // the first element of the queue BY REFERENCE so the value
            // of the element can be changed") — genuinely new
            // architectural work (§3.6 of the collections plan), not a
            // generic `object.set(value, for: name)` data-field write.
            // `Pair` is a VALUE-type `LassoValue` case, not `.object`-
            // wrapped at all — there is no instance to mutate, so the
            // only way to make `$myPair->First = X` visible is to
            // rebuild the WHOLE pair and recursively re-assign it to
            // whatever expression `base` itself was (mirroring exactly
            // how `Var(name::type) = value` above recurses into `assign`
            // again for its own unwrapped target). `Queue`/`Stack` ARE
            // `.object`-wrapped (reference types) — their `_elements`
            // array can be mutated in place through the existing
            // `LassoObjectInstance`, no recursive reassignment needed,
            // same pattern `Iterator`'s own mutating methods already
            // use. `Set->Get(n)=` (Table 16: "This tag can be used as
            // the left parameter of an assignment operator to set an
            // element of the set") is the third case — position-based,
            // matching `->Get`'s own read semantics; a direct positional
            // overwrite, not a re-insert-and-resort (no worked example
            // exists to check that choice against — Set's sortedness
            // invariant is not addressed by Table 16's terse wording).
            if normalizedName == "first" || normalizedName == "second" {
                if case let .pair(first, second) = baseValue {
                    let newPair: LassoValue = normalizedName == "first" ? .pair(value, second) : .pair(first, value)
                    try await assign(newPair, to: base, defaultScope: defaultScope)
                    return
                }
                // Atomic read-modify-write under a single lock hold —
                // composing separate `LassoCollectionValue.elements(from:)`
                // (a locked read) and `object.set(_:for:)` (a separate
                // locked write) reintroduces the exact lost-update race
                // already found and fixed for `Queue`/`Stack`/
                // `PriorityQueue->Get` and Iterator's own mutating
                // methods (see their own comments) — flagged again here
                // by swift-concurrency-pro/code-reviewer review.
                if normalizedName == "first", case let .object(object) = baseValue, object.typeName == "queue" {
                    object.withLock("_elements") { stored in
                        guard case var .array(elements) = stored, !elements.isEmpty else { return }
                        elements[0] = value
                        stored = .array(elements)
                    }
                    return
                }
                if normalizedName == "first", case let .object(object) = baseValue, object.typeName == "stack" {
                    object.withLock("_elements") { stored in
                        guard case var .array(elements) = stored, !elements.isEmpty else { return }
                        elements[elements.count - 1] = value
                        stored = .array(elements)
                    }
                    return
                }
            }
            if normalizedName == "get", case let .object(object) = baseValue, object.typeName == "set" {
                // The position argument is evaluated BEFORE acquiring
                // the lock — it may itself suspend (`await`), and
                // holding a lock across a suspension point is exactly
                // the kind of hazard `withLock`'s own synchronous-only
                // closure shape exists to prevent.
                let getArguments = memberArguments ?? []
                let position = getArguments.first != nil ? Int(try await evaluate(getArguments[0].value).number ?? 0) : 0
                let index = position - 1
                object.withLock("_elements") { stored in
                    guard case var .array(elements) = stored, elements.indices.contains(index) else { return }
                    elements[index] = value
                    stored = .array(elements)
                }
                return
            }
            // `Map->Get(n) = value` — the Lasso 9 divergence this
            // subsystem's own Stage 2 originally scoped and then never
            // followed through on (see `collections-subsystem-plan.md`'s
            // own status note). Cross-checked directly against
            // lassoguide.com/operations/collections.html (not assumed):
            // Lasso 9's REAL `map->get`/`->get=` contract turns out to
            // be a much bigger redesign than "add a setter" — it's
            // KEY-based (`map->get(key)`), returns the bare VALUE (not
            // a `.pair`), and "will FAIL" (throw) on a missing key,
            // wholesale replacing 8.5's position-based, Pair-returning,
            // never-fails `->Get(n)` (Table 7, already implemented and
            // tested above in the read-dispatch switch). Adopting that
            // full redesign would silently break the already-shipped,
            // worked-example-verified 8.5 behavior with no user sign-off
            // on such a disruptive change. Implemented here as the
            // NARROWER, disclosed reading instead: `->Get(n) = value`
            // reassigns the VALUE half of the pair at that same 1-based
            // sorted-by-key position — the same "just add assignment-
            // target support to the existing read contract" shape
            // already used for `Set->Get(n)=` right above, not a
            // wholesale Lasso 9 semantic swap. `.map` is a VALUE-type
            // `LassoValue` case (a Swift Dictionary, not `.object`-
            // wrapped) — same as `Pair` above, there's no instance to
            // mutate, so the whole map is rebuilt and recursively
            // re-assigned to whatever expression `base` was.
            if normalizedName == "get", case let .map(mapValues) = baseValue {
                let getArguments = memberArguments ?? []
                let position = getArguments.first != nil ? Int(try await evaluate(getArguments[0].value).number ?? 0) : 0
                let sortedKeys = mapValues.keys.sorted()
                let index = position - 1
                guard sortedKeys.indices.contains(index) else { return }
                var updated = mapValues
                updated[sortedKeys[index]] = value
                try await assign(.map(updated), to: base, defaultScope: defaultScope)
                return
            }
            guard case let .object(object) = baseValue else {
                throw LassoRuntimeError.invalidAssignment
            }
            // Native (Swift-implemented) types must never be mutable via
            // raw field assignment — their `_`-prefixed storage is an
            // implementation detail, and every enforced invariant (header
            // injection checks, filename sanitization, etc.) lives in their
            // registered native methods, not in plain dictionary storage.
            // A user-defined Lasso type (resolved via `tagRegistry`
            // instead) legitimately uses this exact same syntax
            // (`self->propname = value`) as its real instance-property
            // mutation mechanism, so only the native-type case is rejected
            // here. If neither registry resolves the type name at all, fall
            // through to the pre-existing (dictionary-backed) behavior —
            // no new failure mode is introduced for that untested edge
            // case. See `LassoRuntimeError.nativeTypeFieldAssignmentNotSupported`'s
            // doc comment for the full rationale (Phase C milestone review,
            // BLOCKING FIX #1).
            if context.nativeTypes.type(named: object.typeName) != nil {
                throw LassoRuntimeError.nativeTypeFieldAssignmentNotSupported(typeName: object.typeName, field: name)
            }
            object.set(value, for: name)
        default:
            throw LassoRuntimeError.invalidAssignment
        }
    }

    // `defaultPrecision` is the precision to use when the caller passes no
    // explicit `-precision` argument -- it differs by the invocant's real
    // type, which this shared helper otherwise has no way to know once
    // everything's flattened to a `Double`: real Lasso's
    // `decimal->asString` defaults to six decimal places ("Formatting
    // Decimal Objects", lassoguide.com Math chapter: "If no parameters are
    // passed to the method, the string will be the decimal value with six
    // places of precision"), while `integer->asString` has no such rule
    // and should print a bare whole number. Previously this always fell
    // back to plain `String(value)` regardless of invocant type --
    // `Double`'s own default stringification, which for an integer prints
    // a trailing `.0` (`123->asString` produced `"123.0"`, not `"123"`)
    // and for a decimal prints Swift's shortest-round-trip
    // representation, which leaks raw IEEE-754 binary-fraction noise
    // straight through for any value not exactly representable in binary
    // -- almost every two-decimal money amount (`(0.1 + 0.2)->asString`
    // produced `"0.30000000000000004"`, not the six-place `"0.300000"`
    // real Lasso guarantees). Found live: FileMaker's own CR_web
    // order_grandtotal field, after round-tripping through ordinary Lasso
    // arithmetic (subtotal + tax + shipping - discount), carried exactly
    // this kind of raw-noise value.
    private mutating func formattedNumber(_ value: Double, _ arguments: [LassoArgument], defaultPrecision: Int?) async throws -> String {
        var precision: Int?
        for argument in arguments {
            guard argument.label?.caseInsensitiveCompare("precision") == .orderedSame else { continue }
            precision = Int(try await evaluate(argument.value).number ?? 0)
        }
        guard let effectivePrecision = precision ?? defaultPrecision else { return String(value) }
        return String(format: "%.\(max(effectivePrecision, 0))f", value)
    }

    private func unary(_ op: String, _ value: LassoValue) throws -> LassoValue {
        switch op.lowercased() {
        case "!", "not": return .boolean(!value.isTruthy)
        // `-5`/`+5` previously always returned `.decimal`, unconditionally
        // — the number lexer (`ExpressionParser`) never consumes a
        // leading `-`/`+`, so every negative/explicitly-positive literal
        // parses as this unary operator applied to a plain number token,
        // not as part of the literal itself. That silently downgraded an
        // integer literal to a decimal purely because of how its sign was
        // written (`Math_Add(-5, 3)` printed `-2.0`, not `-2`, contrary
        // to the documented "if all the parameters are integers the
        // result will be an integer" rule the new Math_* family
        // implements) — caught by architect review of that work. Fixed
        // by mirroring `numeric(_:_:_:)`'s own established whole-number
        // convention right below, rather than inventing a stricter,
        // inconsistent rule.
        case "-":
            let result = -(value.number ?? 0)
            return result.rounded() == result ? .integer(Int(result)) : .decimal(result)
        case "+":
            let result = value.number ?? 0
            return result.rounded() == result ? .integer(Int(result)) : .decimal(result)
        default: throw LassoRuntimeError.unsupportedExpression("Unary \(op)")
        }
    }

    // `internal` (not `private`) since `Collections.swift`'s Set/List
    // implementation reuses this directly for element equality/ordering —
    // see `lassoEquals`'s own doc comment below. Purely functional on the
    // two passed-in values, no `self`/`context` state touched anywhere in
    // its body, so widening this doesn't change what it can observe.
    func binary(_ left: LassoValue, _ op: String, _ right: LassoValue) throws -> LassoValue {
        switch op {
        case "+":
            if case .string = left { return .string(left.outputString + right.outputString) }
            if case .string = right { return .string(left.outputString + right.outputString) }
            return numeric(left, right, +)
        case "-": return numeric(left, right, -)
        case "*": return numeric(left, right, *)
        case "/":
            // Previously plain Swift division: `.decimal` silently
            // produced `inf`/`nan`, `.integer` crashed the process
            // (Swift traps on integer division by zero) — neither
            // matches Ch. 19's documented, catchable
            // `error_code_divideByZero`/`error_msg_divideByZero`
            // (lassoguide.com's Lasso 9 "Error Handling" page; not in
            // the 8.5 PDF's own Appendix A, which predates that named
            // constant). `%`'s sibling case below already guards
            // divide-by-zero with `max(...,1)` rather than throwing —
            // deliberately left as-is, not revisited here.
            // `right.number ?? 0`, not `right.number != 0` — a
            // non-numeric right operand has `right.number == nil`,
            // which `numeric(_:_:_:)` below resolves to an effective
            // divisor of 0 via its own `?? 0` — comparing the raw
            // Optional directly would let that case slip past this
            // guard (`nil != 0` is true) straight into the exact crash
            // this fix exists to prevent.
            guard (right.number ?? 0) != 0 else {
                throw LassoRecoverableError(LassoErrorState(
                    code: LassoErrorHandling.Code.divideByZero,
                    message: "Divide by Zero",
                    kind: "runtime"
                ))
            }
            return numeric(left, right, /)
        case "%": return .integer(Int(left.number ?? 0) % max(Int(right.number ?? 0), 1))
        case "==":
            // Real Lasso 9 string equality is case-INSENSITIVE by default
            // (case-sensitive comparison needs an explicit `-case` flag on
            // `string->compare`, not the bare `==` operator). Found live:
            // pages/thumbs2.page.lasso's `if(string(field('new_item')) ==
            // 'yes')` ribbon check — the real `skus` table stores this
            // column as `'Yes'` (capital Y), and production still shows
            // the "New" ribbon on every New Items product, confirming the
            // comparison is meant to match regardless of case. A
            // case-sensitive `==` silently hid the ribbon on every item.
            return .boolean(left.outputString.caseInsensitiveCompare(right.outputString) == .orderedSame)
        case "!=":
            return .boolean(left.outputString.caseInsensitiveCompare(right.outputString) != .orderedSame)
        // `<`/`>`/`<=`/`>=` (Ch. 5 Table 11, p.78) — "check whether strings
        // come before or after each other in alphabetical order," verified
        // against the Guide's own worked example (`'abc' < 'def'` → True)
        // — that citation covers the pure-non-numeric-string case
        // specifically; it says nothing about numeric-looking string
        // operands. All four derived from the same `Evaluator.lassoLessThan`
        // this codebase already uses for `Array->Sort`/Set/PriorityQueue/
        // TreeMap ordering and `Match_Range` — the single existing,
        // already-reviewed source of truth for "how does Lasso order two
        // values," reused here instead of inventing a second, parallel
        // comparison. Note `lassoLessThan`'s own numeric-bucket-first
        // behavior for mixed/numeric-looking operands (e.g. `'10' < '9'`
        // compares NUMERICALLY, not alphabetically) is its own doc
        // comment's disclosed "best-effort" heuristic (invented for
        // `Array->Sort`'s mixed-array ordering, not verified against a
        // Guide worked example) — reusing it here inherits that same
        // unverified-but-pre-existing ambiguity for the raw operators too,
        // not a new one this fix introduces (the OLD `compare(_:_:_:)`
        // helper already special-cased "both operands numeric → compare
        // numerically" before its now-fixed broken fallback, so mixed/
        // numeric-string comparisons are no better- or worse-defined than
        // before). Previously these four routed through a private
        // `compare(_:_:_:)` helper whose non-numeric fallback compared
        // `Double(outputString.count)` — i.e. STRING LENGTH, not content —
        // so `'a' < 'b'` incorrectly returned `false` (both length 1).
        // Confirmed no existing test's expected output depended on that
        // broken behavior before fixing it.
        case ">": return .boolean(Evaluator.lassoLessThan(right, left))
        case ">>":
            // Real Lasso 8/9's documented string-contains operator
            // (`left >> right` — "does left contain right") — not a
            // synonym for `>`. Treating it as `>` silently compared
            // string *lengths* instead of content (the same bug the
            // `<`/`>`/`<=`/`>=` fix above closes), which happened to look
            // right for some inputs by sheer coincidence (e.g. `'' >>
            // 'www3'` is false either way, since 0 > 4 is also false)
            // but was wrong in general. Real corpus: ~32 files use this
            // exact `left >> 'substring'` shape for host/environment
            // detection (e.g. components/koi_setup.inc's
            // `server_name >> 'www2'` chain) and bot-string matching
            // (site_setup_tags.inc's `excludeBots`).
            return .boolean(left.outputString.contains(right.outputString))
        case "<": return .boolean(Evaluator.lassoLessThan(left, right))
        case ">=": return .boolean(!Evaluator.lassoLessThan(left, right))
        case "<=": return .boolean(!Evaluator.lassoLessThan(right, left))
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

    private mutating func member(
        _ base: LassoValue,
        _ name: String,
        _ arguments: [LassoArgument]
    ) async throws -> LassoValue {
        let normalized = name.lowercased()
        switch (base, normalized) {
        case (.void, _):
            // Real Lasso 9 returns `void` (not `null`) for lookup-miss
            // results — web_request->param/header/cookie et al. — and
            // keeps `null` itself strict (an unhandled member throws
            // unless the type defines `_unknowntag`). `void` is where
            // Lasso 8-style graceful degradation actually lives: treat it
            // as an empty string for member access, matching how it
            // already behaves for truthiness (`false`) and string output
            // (`""`) elsewhere in this runtime. This redirect means
            // `void->Type`/`->IsA`/`->HasMethod` report `"String"`/
            // string-typed answers rather than surfacing "this was a
            // lookup miss" — a deliberate extension of the same
            // graceful-degradation tradeoff already made above, not a
            // new one introduced by `introspectionResult` (flagged and
            // confirmed intentional by architect review).
            return try await member(.string(""), name, arguments)
        case let (.string(value), "size"): return .integer(value.count)
        case let (.string(value), "uppercase"): return .string(value.uppercased())
        case let (.string(value), "lowercase"): return .string(value.lowercased())
        case let (.string(value), "asstring"): return .string(value)
        case let (.string(value), "encodehtml"): return .string(value.htmlEncoded)
        case let (.string(value), "encodeurl"):
            return .string(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)
        case let (.string(value), "encodesmart"): return .string(LassoEncoding.smart(value))
        case let (.string(value), "encodebreak"): return .string(LassoEncoding.breakEncoded(value))
        case let (.string(value), "encodexml"): return .string(LassoEncoding.xml(value))
        case let (.string(value), "encodestricturl"): return .string(LassoEncoding.strictURL(value))
        case let (.string(value), "encodesql"): return .string(LassoEncoding.sql(value))
        case let (.string(value), "encodebase64"): return .string(LassoEncoding.base64(value))
        case let (.string(value), "decodebase64"):
            guard let decoded = LassoEncoding.decodeBase64(value) else { return .void }
            return .string(decoded)
        case let (.string(value), "contains"):
            // Lasso 8.5 Language Guide Ch. 25 Table 7: "[String->Contains]
            // Returns True if the string contains the parameter as a
            // substring. Comparison is case insensitive." An earlier
            // version used Swift's raw case-SENSITIVE `String.contains`,
            // contradicting the documented behavior — caught while
            // verifying `->BeginsWith`/`->EndsWith`/`->Equals` (the same
            // table's siblings, all explicitly documented case-
            // insensitive too) directly against this same page.
            let needle: String
            if let argument = arguments.first {
                needle = try await evaluate(argument.value).outputString
            } else {
                needle = ""
            }
            return .boolean(needle.isEmpty || value.range(of: needle, options: .caseInsensitive) != nil)
        case let (.string(value), "beginswith"):
            // Ch. 25 Table 7: case insensitive.
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            return .boolean(value.range(of: needle, options: [.caseInsensitive, .anchored]) != nil || needle.isEmpty)
        case let (.string(value), "endswith"):
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            return .boolean(needle.isEmpty || value.range(of: needle, options: [.caseInsensitive, .backwards, .anchored]) != nil)
        case let (.string(value), "equals"):
            // "Equivalent to the == symbol" — reuses the same
            // case-insensitive comparison `binary(_:"==",_:)` already
            // uses elsewhere (Evaluator.swift's own `==` doc comment
            // cites a real production bug this exact rule was needed to
            // fix: 'Yes' vs 'yes').
            let other = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            return .boolean(value.caseInsensitiveCompare(other) == .orderedSame)
        case let (.string(value), member) where member == "compare" || member == "comparecodepointorder":
            // Ch. 25 Table 7: three-way compare — 0 if equal, 1 if the
            // base string is bitwise greater, -1 if less. Case
            // insensitive by default; a bare `-Case` flag makes it case
            // sensitive. Only the single-parameter whole-string form is
            // implemented — the documented substring-offset/-length
            // overloads (comparing a slice of either string) are out of
            // scope here. `->CompareCodePointOrder` is documented as
            // accepting the same parameters with Unicode-code-point-
            // accurate ordering for characters above U+10000 — Swift's
            // native `String` comparison is already Unicode-scalar-aware
            // by default, so it shares this exact implementation rather
            // than needing a separate one.
            let evaluatedArguments = try await evaluate(arguments)
            let other = evaluatedArguments.positionalValue(at: 0)?.outputString ?? ""
            let caseSensitive = evaluatedArguments.hasTruthyFlag("case")
            let ordering = caseSensitive ? value.compare(other) : value.compare(other, options: .caseInsensitive)
            switch ordering {
            case .orderedSame: return .integer(0)
            case .orderedDescending: return .integer(1)
            case .orderedAscending: return .integer(-1)
            }
        case let (.string(value), "find"):
            // Ch. 25 Table 9: "Returns the position at which the first
            // parameter is found within the string or 0 if the first
            // parameter is not found." 1-based, matching `->substring`'s
            // own established 1-based convention (confirmed by that
            // member's own doc comment/tests).
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            guard !needle.isEmpty, let range = value.range(of: needle) else { return .integer(0) }
            return .integer(value.distance(from: value.startIndex, to: range.lowerBound) + 1)
        case let (.string(value), "get"):
            // Ch. 25 Table 9: a single character at a 1-based position.
            let position = arguments.first != nil ? Int(try await evaluate(arguments[0].value).number ?? 0) : 0
            let characters = Array(value)
            let index = position - 1
            guard characters.indices.contains(index) else { return .string("") }
            return .string(String(characters[index]))
        case let (.string(value), "foreachcharacter"):
            // Ch. "String Operations" (operations/strings.html, Lasso
            // 9.3): "Executes a given capture block once for every
            // character in the base string. The character can be
            // accessed in the capture block through the special local
            // variable #1." Real, directly-callable String method
            // (unlike Stage 4's array/list/etc. `->forEach`, which isn't
            // documented as callable at all) — checked directly against
            // lassoguide.com before implementing. `Character` is already
            // grapheme-cluster-aware (Unicode-correct), matching this
            // project's established "default to real Unicode/ICU
            // behavior" convention with no extra work needed.
            return try await invokeForEachCapture(
                over: value.map { .string(String($0)) },
                evaluatedArguments: evaluate(arguments)
            )
        case let (.string(value), "eachcharacter"):
            // Ch. "Query Expressions", "Making an Object Queriable":
            // "while a string cannot be iterated upon directly, it has
            // an iterator string->forEachCharacter, which is implemented
            // as an `eacher`" -- the docs' own worked example:
            // `with i in 'Hammershaimb'->eachCharacter select #i`. Real
            // Lasso implements this via the general `eacher(...)` free
            // function (an ESCAPED method reference + a generator
            // adapter) applied to `->forEachCharacter` above; this
            // codebase instead EAGERLY materializes the same character
            // sequence directly into an "eacher"-typed native object
            // (recognized by `forEachElements(of:)`), matching the
            // SAME disclosed eager-evaluation simplification already
            // established for the rest of Query Expressions (Stage 8.1's
            // own doc comment) rather than building the fully general
            // `eacher()` free function -- which would also need the
            // MEMBER-POSITION form of Lasso's real "Method Escaping"
            // operator (`object->\identifier`, producing a real
            // `memberstream`; this codebase already has the BARE form,
            // `\identifier`/`.tagReference` in `TagReference.swift`, but
            // not this one) with no existing precedent anywhere in this
            // parser and zero corpus evidence either way. Disclosed,
            // narrower scope: this
            // resolves the docs' own concrete worked example exactly,
            // not the general "wrap ANY iterator method" mechanism.
            return .object(LassoObjectInstance(
                typeName: "eacher",
                data: ["_elements": .array(value.map { .string(String($0)) })]
            ))
        case let (.string(value), "foreachwordbreak"):
            // "Executes a given capture block once for every word in
            // the base string." Real Lasso docs never define "word"
            // further — `String.enumerateSubstrings(options: .byWords)`
            // is Foundation's own ICU-backed Unicode word-boundary
            // segmentation (UAX #29), matching this project's
            // established "default to real ICU/Unicode behavior when
            // docs are ambiguous" convention (see memory:
            // lasso-standards-culture) rather than a hand-rolled
            // whitespace-split guess.
            var words: [LassoValue] = []
            value.enumerateSubstrings(in: value.startIndex..<value.endIndex, options: .byWords) { substring, _, _, _ in
                if let substring { words.append(.string(substring)) }
            }
            return try await invokeForEachCapture(over: words, evaluatedArguments: evaluate(arguments))
        case let (.string(value), "foreachlinebreak"):
            // "Executes a given capture block once for every substring
            // that would be generated by splitting the base string on a
            // line break. Every line break character is recognized:
            // \"\\r\", \"\\n\", and \"\\r\\n\"." Foundation's own
            // `.byLines` enumeration already treats "\r\n" as ONE break
            // (not two), matching this exact documented rule precisely
            // — not a hand-rolled `components(separatedBy:)` split
            // (which would need three separate passes to avoid
            // double-splitting "\r\n").
            var lines: [LassoValue] = []
            value.enumerateSubstrings(in: value.startIndex..<value.endIndex, options: .byLines) { substring, _, _, _ in
                if let substring { lines.append(.string(substring)) }
            }
            return try await invokeForEachCapture(over: lines, evaluatedArguments: evaluate(arguments))
        case let (.string(value), "foreachmatch"):
            // "string->forEachMatch(exp::string)" / "(exp::regexp) —
            // Executes a given capture block once for every match in
            // the base string. Matches can be specified as either
            // string or regexp objects." A bare string argument is used
            // directly AS a regex pattern (matching `Match_RegExp`'s own
            // established convention, `Runtime.swift`'s
            // `register("match_regexp")`, which stores whatever value
            // it's given verbatim as the pattern) — a `regexp` object
            // argument contributes its own pattern/`-IgnoreCase` fields
            // instead (`NativeTypes.swift`'s `makeRegExpType`'s own
            // `"find"`/`"ignorecase"` data keys).
            //
            // Found by architect review: an earlier version of this case
            // evaluated `arguments[0].value` (the `exp` expression)
            // manually to extract the pattern, THEN separately called
            // `evaluate(arguments)` again to build `invokeForEachCapture`'s
            // own evaluated-argument list — evaluating `exp` a SECOND,
            // independent time. Harmless for a plain literal pattern, but
            // a real bug the moment `exp` has any side effect (e.g.
            // `'x'->forEachMatch(someMethodWithASideEffect())`, which
            // would fire twice instead of once) — this codebase otherwise
            // carefully evaluates each argument exactly once. Fixed by
            // evaluating `arguments` ONCE and reading `exp` back out of
            // that same evaluated list (the first non-`"givenblock"`-
            // labeled entry — `exp` is always a plain positional
            // argument, never itself labeled).
            let evaluatedArguments = try await evaluate(arguments)
            let matchArgument = evaluatedArguments.first {
                $0.label?.caseInsensitiveCompare("givenblock") != .orderedSame
            }?.value ?? .string("")
            let pattern: String
            let ignoreCase: Bool
            if case let .object(regexpInstance) = matchArgument, regexpInstance.typeName == "regexp" {
                pattern = regexpInstance.value(for: "find").outputString
                ignoreCase = regexpInstance.value(for: "ignorecase").isTruthy
            } else {
                pattern = matchArgument.outputString
                ignoreCase = false
            }
            let matches = LassoRegularExpressions.findAllWholeMatches(in: value, pattern: pattern, ignoreCase: ignoreCase)
            return try await invokeForEachCapture(over: matches, evaluatedArguments: evaluatedArguments)
        case let (.string(value), "split"):
            let separator: String
            if let argument = arguments.first {
                separator = try await evaluate(argument.value).outputString
            } else {
                separator = ""
            }
            return .array(value.components(separatedBy: separator).map(LassoValue.string))
        case let (.string(value), "replace"):
            // `string->replace(find, replaceWith)` — real Lasso 8.5/9
            // documented positional form (also accepts `-Find=`/`-Replace=`
            // keyword form; only the positional shape has real corpus
            // evidence so far, see pages/subcats3.page.lasso's
            // `$uniform_restrictions->(Replace('!','<br>'))`). Replaces every
            // occurrence of `find` with `replaceWith`, matching Swift's own
            // `replacingOccurrences` semantics; a missing `find`/`replaceWith`
            // argument defaults to an empty string, same fallback this file
            // already uses for `contains`/`split`.
            let find: String
            if let argument = arguments.first {
                find = try await evaluate(argument.value).outputString
            } else {
                find = ""
            }
            let replacement: String
            if arguments.count > 1 {
                replacement = try await evaluate(arguments[1].value).outputString
            } else {
                replacement = ""
            }
            guard find.isEmpty == false else { return .string(value) }
            return .string(value.replacingOccurrences(of: find, with: replacement))
        case let (.string(value), "append"):
            // `string->append(value)` — real Lasso 8.5/9: appends value's
            // string representation to the end, mutating the invocant in
            // place when called as a bare statement (see
            // selfMutatingMethods below). Real corpus:
            // LassoStartup/hash_test.lasso's scrubs_hash custom tag,
            // `#hash->append('\r\n')` right after computing an
            // Encrypt_HMAC hash — confirmed live 2026-07-18.
            let suffix: String
            if let argument = arguments.first {
                suffix = try await evaluate(argument.value).outputString
            } else {
                suffix = ""
            }
            return .string(value + suffix)
        case let (.string(value), "trim"):
            // `string->trim` — Lasso 8.5 Language Guide, Chapter on String
            // Operations: "Removes all white space from the start and end
            // of the string. Modifies the string in place and returns no
            // value." Real corpus: login_check_top.lasso's
            // `$email->(trim)` and lost_password.page.lasso's
            // `#new_email->(trim)` — confirmed live 2026-07-18.
            return .string(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case let (.string(value), "padleading"):
            // Ch. 25 Table 3: pads the FRONT to a specified length
            // (default pad character space). A string already at or past
            // the target length is returned unchanged.
            let length = arguments.first != nil ? Int(try await evaluate(arguments[0].value).number ?? 0) : 0
            let padCharacter = arguments.count > 1 ? try await evaluate(arguments[1].value).outputString : " "
            let padCount = max(length - value.count, 0)
            let pad = padCharacter.isEmpty ? "" : String(repeating: padCharacter, count: padCount)
            return .string(String(pad.suffix(padCount)) + value)
        case let (.string(value), "padtrailing"):
            let length = arguments.first != nil ? Int(try await evaluate(arguments[0].value).number ?? 0) : 0
            let padCharacter = arguments.count > 1 ? try await evaluate(arguments[1].value).outputString : " "
            let padCount = max(length - value.count, 0)
            let pad = padCharacter.isEmpty ? "" : String(repeating: padCharacter, count: padCount)
            return .string(value + String(pad.prefix(padCount)))
        case let (.string(value), "removeleading"):
            // Ch. 25 Table 3: "Removes all instances of the parameter
            // from the beginning of the string" — repeated, not just one
            // occurrence (distinct from `->Trim`, which strips
            // whitespace specifically).
            let target = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            guard !target.isEmpty else { return .string(value) }
            var remaining = Substring(value)
            while remaining.hasPrefix(target) { remaining = remaining.dropFirst(target.count) }
            return .string(String(remaining))
        case let (.string(value), "removetrailing"):
            let target = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            guard !target.isEmpty else { return .string(value) }
            var remaining = Substring(value)
            while remaining.hasSuffix(target) { remaining = remaining.dropLast(target.count) }
            return .string(String(remaining))
        case let (.string(value), "reverse"):
            // Ch. 25 Table 3 documents optional offset/length parameters
            // to reverse only a substring range — only the default
            // (reverse the entire string) is implemented here.
            return .string(String(value.reversed()))
        case let (.string(value), "titlecase"):
            // Ch. 25 Table 5: "Converts the string to titlecase with the
            // first character of each word capitalized." Word boundaries
            // here are literal single spaces only, not general
            // whitespace (tabs/newlines) — low real-corpus risk, but a
            // real scope limitation, matching this file's own convention
            // of disclosing narrower-than-documented scope (see
            // `->reverse`/`->compare` just above and below) rather than
            // silently under-delivering. No locale parameter support
            // either.
            let titled = value.split(separator: " ", omittingEmptySubsequences: false)
                .map { word -> String in
                    guard let first = word.first else { return String(word) }
                    return first.uppercased() + word.dropFirst().lowercased()
                }
                .joined(separator: " ")
            return .string(titled)
        case let (.string(value), member) where member == "substring" || member == "sub":
            // `string->substring(start::integer, size::integer=?)` --
            // LassoGuide: "The starting point is specified by the first
            // parameter ... If the second parameter is not specified, all
            // characters from the specified starting position to the end
            // of the string are returned." 1-based start (confirmed via
            // the docs' own worked example: 'The String'->sub(5, 6) ==
            // 'String', where position 5 is the 5th character). `->sub`
            // is a real documented alias. Real corpus:
            // pages/checkout.page.lasso's
            // `string(field('card_number'))->(Substring: 1, 1)` (credit
            // card masking).
            let characters = Array(value)
            let start: Int
            if let first = arguments.first {
                let startValue = try await evaluate(first.value).number
                start = max(Int(startValue ?? 1) - 1, 0)
            } else {
                start = 0
            }
            guard start < characters.count else { return .string("") }
            let length: Int
            if arguments.count > 1 {
                let sizeNumber = try await evaluate(arguments[1].value).number
                length = max(Int(sizeNumber ?? 0), 0)
            } else {
                length = characters.count - start
            }
            let end = min(start + length, characters.count)
            guard end > start else { return .string("") }
            return .string(String(characters[start..<end]))
        case let (.string(value), "remove"):
            // Ch. 25 Table 3: "Removes a substring from the string. The
            // first parameter is the offset at which to start removing
            // characters. The second parameter is the number of
            // characters to remove. Defaults to removing to the end of
            // the string." 1-based offset, matching `->substring`'s own
            // established convention. Mutating (`"remove"` is already in
            // `selfMutatingMethods`, shared with `Array->Remove`).
            let characters = Array(value)
            let evaluatedArguments = try await evaluate(arguments)
            let offset = max(Int(evaluatedArguments.positionalValue(at: 0)?.number ?? 1) - 1, 0)
            guard offset < characters.count else { return .string(value) }
            let count = evaluatedArguments.positionalValue(at: 1).flatMap { $0.number.map(Int.init) } ?? (characters.count - offset)
            let end = min(offset + max(count, 0), characters.count)
            guard end > offset else { return .string(value) }
            return .string(String(characters[0..<offset]) + String(characters[end...]))
        case let (.string(value), "merge"):
            // Ch. 25 Table 3: "Inserts a merge string into the string.
            // Requires two parameters, the location at which to insert
            // the merge string and the string to insert. Optional third
            // and fourth parameters specify an offset into the merge
            // string and number of characters of the merge string to
            // insert." 1-based location, matching this file's other
            // position-based string members. No worked example exists
            // anywhere in the Guide for this specific tag (Table 3's own
            // "Note" only points to the separate Lasso Reference) — the
            // 1-based-offset assumption for the third/fourth parameters
            // is inferred from this file's own established convention
            // for every other position-based string member, not
            // directly verified against a worked example (flagged by
            // architect review).
            let characters = Array(value)
            let evaluatedArguments = try await evaluate(arguments)
            let location = max(Int(evaluatedArguments.positionalValue(at: 0)?.number ?? 1) - 1, 0)
            let mergeSource = Array(evaluatedArguments.positionalValue(at: 1)?.outputString ?? "")
            let mergeOffset = min(max(evaluatedArguments.positionalValue(at: 2).flatMap { $0.number.map(Int.init) }.map { $0 - 1 } ?? 0, 0), mergeSource.count)
            let mergeCount = evaluatedArguments.positionalValue(at: 3).flatMap { $0.number.map(Int.init) } ?? (mergeSource.count - mergeOffset)
            let mergeEnd = min(mergeOffset + max(mergeCount, 0), mergeSource.count)
            let mergeSlice = mergeEnd > mergeOffset ? String(mergeSource[mergeOffset..<mergeEnd]) : ""
            let insertAt = min(location, characters.count)
            return .string(String(characters[0..<insertAt]) + mergeSlice + String(characters[insertAt...]))
        case let (.string(value), "foldcase"):
            // Ch. 25 Table 5: "Converts all characters in the string for
            // a case-insensitive comparison." Real Lasso backs this with
            // ICU case folding; Swift/Foundation expose no direct case-
            // fold API, so this uses `.folding(options: .caseInsensitive,
            // locale: nil)` — Foundation's own closest equivalent, and a
            // strictly closer match to real ICU case folding than plain
            // `.lowercased()` for characters like German `ß` (which case-
            // folds to `ss`, not just lowercases to itself) — still a
            // disclosed approximation, not a full ICU case-fold
            // implementation (flagged by architect review).
            return .string(value.folding(options: .caseInsensitive, locale: nil))
        case let (.string(value), "unescape"):
            return .string(LassoEncoding.unescape(value))
        case let (.string(value), member) where member == "tolower" || member == "toupper" || member == "totitle":
            // Ch. 25 Table 5: `->toLower`/`->toUpper`/`->toTitle` convert
            // a SINGLE character at a 1-based position, distinct from the
            // whole-string `->lowercase`/`->uppercase`/`->titlecase`
            // members above.
            var characters = Array(value)
            let position = arguments.first != nil ? Int(try await evaluate(arguments[0].value).number ?? 0) : 0
            let index = position - 1
            guard characters.indices.contains(index) else { return .string(value) }
            let converted: String
            switch member {
            case "tolower": converted = String(characters[index]).lowercased()
            case "toupper": converted = String(characters[index]).uppercased()
            default:
                // `->toTitle`: Swift/Foundation expose no per-character
                // Unicode titlecase mapping, only whole-string
                // `.capitalized`, so this uses plain uppercasing as the
                // closest available approximation — identical to true
                // titlecase for ASCII (everything this file's own tests
                // exercise), but diverges for the small set of Unicode
                // digraph characters with a distinct titlecase form
                // (e.g. U+01C5 `ǅ`), matching this file's disclosed-
                // narrower-scope convention elsewhere (flagged by
                // architect review).
                converted = String(characters[index]).uppercased()
            }
            characters.replaceSubrange(index..<(index + 1), with: Array(converted))
            return .string(String(characters))
        case let (.string(value), member) where LassoStringInformation.isCharacterMemberName(member):
            // Ch. 25 Table 11: Character Information Member Tags — every
            // one of these inspects a SINGLE character at a 1-based
            // position. `->CharName` (full Unicode Character Database
            // name lookup, e.g. "LATIN SMALL LETTER B") is deliberately
            // NOT implemented here — Swift/Foundation expose no UCD name
            // table, and guessing at one for only some code points would
            // be worse than a clear, disclosed gap (see
            // `StringOperations.swift`'s own doc comment).
            let characters = Array(value)
            let position = arguments.first != nil ? Int(try await evaluate(arguments[0].value).number ?? 0) : 0
            let index = position - 1
            guard characters.indices.contains(index) else { return .null }
            let radix = arguments.count > 1 ? Int(try await evaluate(arguments[1].value).number ?? 10) : 10
            return LassoStringInformation.characterMember(member, of: characters[index], radix: radix)
        case let (.integer(value), "asstring"):
            return .string(try await formattedNumber(Double(value), arguments, defaultPrecision: 0))
        case let (.decimal(value), "asstring"):
            // Real corpus: pages/thumbs.page.lasso's
            // `decimal(field('starting_price'))->asString(-precision=2)`
            // (`-precision` fixes the number of digits after the decimal
            // point; real Lasso also accepts it on integers, e.g.
            // lassoBackup/scrubs/LassoApps/ds/_init.lasso's
            // `(...)->asstring(-precision=3)` on a `Double` literal
            // expression, hence the shared `formattedNumber` helper).
            return .string(try await formattedNumber(value, arguments, defaultPrecision: 6))
        case let (.decimal(value), "ceil"): return .decimal(value.rounded(.up))
        case let (.integer(value), "ceil"): return .integer(value)
        case let (.capture(capture), "invoke"):
            return try await invokeCapture(capture, arguments: try await evaluate(arguments))
        case let (.capture(capture), "detach"):
            // Ch. "Captures": "detaches the capture so that it no longer
            // has a home capture... After this, calling [capture->home]
            // will return void" — and "returns itself", so `->detach()`
            // chains naturally (e.g. `#cap->detach->invoke`).
            capture.detach()
            return .capture(capture)
        case let (.capture(capture), "restart"):
            // Ch. "Captures": "Resets the program counter (PC) for the
            // capture and begins executing the capture's code again." A
            // disclosed exact match, not an approximation: this
            // interpreter has no persistent PC at all — "every
            // invocation of a capture (yielded-from or not) re-executes
            // its body from the top" already (see this file's own
            // `LassoCaptureValue` doc comment, Stage 2) — so "reset the
            // PC and run again" and a plain `->invoke()` with no
            // arguments are already behaviorally identical today.
            return try await invokeCapture(capture, arguments: [])
        case let (.capture(capture), "givenblock"):
            // The MEMBER-method form (distinct from the pre-existing bare
            // `givenBlock` keyword — see `Evaluator.evaluate(_:)`'s
            // `.identifier` case): "Returns the capture block associated
            // with the CURRENT capture object, if any." Only meaningful
            // for the capture actively executing right now — `capture`
            // must be the top of `context.currentCaptureStack`, the same
            // frame `context.currentGivenBlock` already reflects; `.void`
            // for any other (not currently executing) capture reference,
            // since this codebase doesn't retain a given-block per
            // capture object outside its own active invocation.
            return capture === context.currentCapture ? context.currentGivenBlock : .void
        case let (.capture(capture), "autocollectbuffer"):
            // Ch. "Captures": "the auto-collected value will be returned
            // and can be accessed using capture->autoCollectBuffer" — see
            // `LassoCaptureValue._autoCollectBuffer`'s own doc comment.
            return capture.autoCollectBuffer()
        case let (.capture(capture), "invokeautocollect"):
            // "Invokes the capture. If it is an auto-collect capture,
            // this will return the auto-collect value, but will not
            // update capture->autoCollectBuffer."
            return try await invokeCapture(capture, arguments: try await evaluate(arguments), updatesAutoCollectBuffer: false)
        case let (.pair(key, _), "first"): return key
        case let (.pair(_, value), "second"): return value
        case (.pair, "size"):
            // Ch. 30 p.404 Note: "For compatibility with maps and
            // arrays the [Pair->Size] tag always returns 2".
            return .integer(2)
        case let (.pair(key, value), "get"):
            // Same Note: "[Pair->(Get:1)] and [Pair->(Get:2)] work to
            // extract the first and second elements from a pair."
            let position = arguments.first != nil ? Int(try await evaluate(arguments[0].value).number ?? 0) : 0
            switch position {
            case 1: return key
            case 2: return value
            default: return .null
            }
        case (_, "foreach") where Self.forEachElements(of: base) != nil:
            // Stage 4 (Captures): one shared case for every built-in
            // collection this interpreter implements (array, map, list,
            // queue, stack, set, priorityqueue, treemap) — see
            // `forEachElements(of:)`/`invokeForEachCapture`'s own doc
            // comments for the element-extraction and non-local-return
            // mechanics (Ch. "Captures" `contains()` worked example).
            // Placed ahead of the generic `.object` dispatch below so it
            // wins for THESE known collection type names specifically —
            // `forEachElements(of:)` returns `nil` for any OTHER
            // `.object` (a user-defined type), correctly falling through
            // to that type's OWN `forEach` method instead (already fully
            // supported via ordinary `=>`-association + `givenBlock`,
            // unchanged by this stage).
            return try await invokeForEachCapture(
                over: Self.forEachElements(of: base) ?? [],
                evaluatedArguments: evaluate(arguments)
            )
        case let (.array(values), "size"): return .integer(values.count)
        case let (.array(values), "first"): return values.first ?? .null
        case let (.array(values), "insert"):
            // Real corpus: includes/detail_a_sku.lasso's
            // `$skuArrayItem->insert(field('scrubs_sku') = $temp_array)`
            // (a bare `key = value` call argument constructs a `.pair`,
            // not an assignment — `field('scrubs_sku')` can't be a valid
            // assignment target anyway) and
            // `$skuArrayColor->insert(field('color'))` (plain value,
            // no pair). Mutation write-back to the invocant variable
            // happens in `evaluate(_:)`'s `.member` case, not here — this
            // just computes the new array value.
            let newElement: LassoValue
            if let argument = arguments.first {
                if case let .assignment(target, value) = argument.value {
                    newElement = .pair(try await evaluate(target), try await evaluate(value))
                } else {
                    newElement = try await evaluate(argument.value)
                }
            } else {
                newElement = .void
            }
            return .array(values + [newElement])
        case let (.map(values), "insert"):
            // Real corpus: includes/detail_by_size.lasso's
            // `$skuArrayItem->insert(field('scrubs_sku')=array(...))`,
            // where `$skuArrayItem` is declared `var(skuArrayItem = map)`
            // — the `key = value` argument here is a real map insertion
            // (add/overwrite the entry keyed by the left side), not a
            // Pair literal, unlike the `.array` case above.
            guard let argument = arguments.first, case let .assignment(target, value) = argument.value else {
                return .map(values)
            }
            var updated = values
            updated[try await evaluate(target).outputString] = try await evaluate(value)
            return .map(updated)
        case let (.map(values), "remove"):
            // Ch. 30 p.401: "[Map->Remove] ... Removes a value from the
            // map by key." Placed here, unconditionally ahead of the
            // key-first fallback further down, mirroring `->insert`
            // right above — NOT key-first like `->size`/`->keys`/etc.
            // `->remove`/`->removeall` are also in `selfMutatingMethods`,
            // so a key-first miss here wouldn't just misread a value (the
            // `->size` case's risk) — `evaluateStatement` would silently
            // overwrite the whole map variable with whatever was stored
            // under a literal "remove"/"removeall" key. Caught by
            // architect review.
            guard let argument = arguments.first else { return .map(values) }
            let key = try await evaluate(argument.value).outputString
            var updated = values
            updated.removeValue(forKey: key)
            return .map(updated)
        case (.map, "removeall"):
            // Not a documented Lasso 8.5 Map tag (only Array has a
            // documented `RemoveAll`) — this is a reasonable, low-risk
            // extension (clear the whole map), kept unconditional for the
            // same corruption-avoidance reason as `->remove` above.
            return .map([:])
        // `TreeMap->Insert`/`->Find`/`->Remove`/`->RemoveAll` — special-
        // cased here, ahead of the generic `.object` native-type
        // dispatch further below, for the EXACT same reason `.map`'s
        // own `->insert`/`->remove` are special-cased right above:
        // the generic path pre-evaluates every argument (collapsing a
        // `key = value` argument's key down to a bare `String` label)
        // before a native-type closure ever sees it, which would
        // silently defeat TreeMap's "any Lasso data type" key
        // requirement (Ch. 30 p.416) — see `Collections.swift`'s
        // `makeTreeMapType()` doc comment for the full reasoning.
        // `->Get`/`->Keys`/`->Values`/`->Size` need no typed-key
        // argument and stay registered normally in `makeTreeMapType()`.
        case let (.object(object), "insert") where object.typeName == LassoTreeMapValue.typeName:
            guard let argument = arguments.first, case let .assignment(target, value) = argument.value else {
                return .object(object)
            }
            let key = try await evaluate(target)
            let entryValue = try await evaluate(value)
            let updated = LassoTreeMapValue.inserting(key: key, value: entryValue, into: object, context: context)
            return .object(LassoTreeMapValue.makeObject(kind: LassoTreeMapValue.kind(of: object), entries: updated))
        case let (.object(object), "find") where object.typeName == LassoTreeMapValue.typeName:
            guard let argument = arguments.first else { return .null }
            let key = try await evaluate(argument.value)
            return LassoTreeMapValue.find(key: key, in: object, context: context)
        case let (.object(object), "remove") where object.typeName == LassoTreeMapValue.typeName:
            guard let argument = arguments.first else { return .object(object) }
            let key = try await evaluate(argument.value)
            let updated = LassoTreeMapValue.removingByKey(key, from: object, context: context)
            return .object(LassoTreeMapValue.makeObject(kind: LassoTreeMapValue.kind(of: object), entries: updated))
        case let (.object(object), "removeall") where object.typeName == LassoTreeMapValue.typeName:
            // Matcher-aware, unlike `->Remove` above — see
            // `LassoTreeMapValue.removingAllMatchingKey`'s own doc
            // comment for why these two now genuinely diverge (Stage 5).
            guard let argument = arguments.first else { return .object(object) }
            let matcherOrKey = try await evaluate(argument.value)
            let updated = try await LassoTreeMapValue.removingAllMatchingKey(matcherOrKey, from: object, context: context)
            return .object(LassoTreeMapValue.makeObject(kind: LassoTreeMapValue.kind(of: object), entries: updated))
        case let (.array(values), "get"):
            let requested: Double?
            if let argument = arguments.first {
                requested = try await evaluate(argument.value).number
            } else {
                requested = nil
            }
            let index = max(Int(requested ?? 1) - 1, 0)
            return values.indices.contains(index) ? values[index] : .null
        case let (.array(values), "last"): return values.last ?? .null
        case let (.array(values), "second"): return values.count > 1 ? values[1] : .null
        case let (.array(values), "reverse"): return .array(values.reversed())
        case let (.array(values), "sort"):
            // Lasso 8.5 Language Guide Ch. 30 p.391/397: "Accepts a single
            // boolean parameter. Sorts in ascending order by default or if
            // the parameter is True and in descending order if the
            // parameter is False." An earlier version of this ignored the
            // parameter entirely — caught reading the doc's own worked
            // example (`$DaysOfWeek->(Sort: False)`) during architect
            // review of this change.
            let ascending = arguments.first != nil ? try await evaluate(arguments[0].value).isTruthy : true
            let sorted = values.sorted(by: Self.lassoLessThan)
            return .array(ascending ? sorted : sorted.reversed())
        case let (.array(values), "sortwith"):
            // Table 21: "Comparators can also be used with the
            // [Array->SortWith] and [List->SortWith] tags to explicitly
            // order the elements" — verified against the worked example
            // (p.419-420): sorting `('aaa','bbb','ccc','aa','a','b','c',
            // 'bb','cc')` with `\Compare_LessThan` → ascending
            // (`a,aa,aaa,b,bb,bbb,c,cc,ccc`); with `\Compare_GreaterThan`
            // → descending. Unlike `->Sort` above, there's no separate
            // ascending/descending boolean — the comparator alone
            // determines direction (`LassoComparatorValue
            // .isOrderedBefore` already encodes GreaterThan's reversal).
            let comparatorArgument: LassoValue = arguments.first != nil ? try await evaluate(arguments[0].value) : .null
            // Stage 7c: a genuine custom (`\TagName`-referenced) comparator
            // routes through the hand-rolled async merge sort — the sync
            // path below is completely untouched for natural order/every
            // built-in comparator.
            if let customTagName = LassoComparatorValue.customTagName(of: comparatorArgument) {
                let sorted = try await LassoComparatorValue.sortedByCustomComparator(
                    values, tagName: customTagName, context: context
                )
                return .array(sorted)
            }
            guard let kind = LassoComparatorValue.kind(of: comparatorArgument) else {
                return .array(values)
            }
            return .array(values.sorted { LassoComparatorValue.isOrderedBefore(kind: kind, $0, $1) })
        case let (.array(values), "iterator"):
            // Table 23: array is one of the explicitly-named built-in
            // `->Iterator`-supporting types — verified against the
            // p.423 worked example's own `Array->Iterator` call.
            let matcher = arguments.first != nil ? try await evaluate(arguments[0].value) : nil
            return try await LassoIteratorValue.build(from: .array(values), reverse: false, matcher: matcher, context: context) ?? .null
        case let (.array(values), "reverseiterator"):
            let matcher = arguments.first != nil ? try await evaluate(arguments[0].value) : nil
            return try await LassoIteratorValue.build(from: .array(values), reverse: true, matcher: matcher, context: context) ?? .null
        case let (.array(values), "join"):
            // `array->join(separator)` — real corpus need: comma/CSV-list
            // and breadcrumb-trail building, previously requiring a manual
            // `loop`/`iterate` accumulator since no equivalent existed.
            let separator = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            return .string(values.map(\.outputString).joined(separator: separator))
        case let (.array(values), "contains"):
            // Ch. 30 p.389: "Returns True if the specified element is
            // contained in the array." Boolean existence test — distinct
            // from `->Find`/`->FindPosition` below, which both return
            // whole arrays of matches, not a boolean. An earlier version
            // of this conflated `->Find` with `->Contains` — caught by
            // architect review reading the doc's own text directly (p.390:
            // "[Array->Find] ... Returns an array of elements that match
            // the parameter").
            // Ch. 30 Table 22 (p.420-421): `->Contains` and `>>` both
            // accept a Matcher as their parameter — `LassoMatcherValue
            // .matches` falls back to plain `lassoEquals`-equivalent
            // coercing equality for a non-matcher argument, so this is
            // a behavior-preserving extension for existing callers.
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value) : .null
            return .boolean(try await LassoMatcherValue.anyMatches(needle, in: values, context: context))
        case let (.array(values), "find"):
            // Ch. 30 p.390/395-396: returns an ARRAY of every element that
            // matches the parameter, not a boolean and not a position. A
            // Pair-array (real corpus: Action_Params/Params results)
            // compares the parameter only against each pair's `->First`
            // half, per the doc's own worked example (p.396,
            // `$Pair_Array->(Find: 'Alpha')`) — confirmed by reading that
            // section directly, not inferred.
            // Matcher-aware — `LassoMatcherValue.matches` already does
            // the pair-first-half unwrapping this case's own body used
            // to do manually (Table 22: "Only the first part of pairs...
            // is compared").
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value) : .null
            return .array(try await LassoMatcherValue.filterMatching(needle, in: values, context: context))
        case let (.array(values), "findposition"):
            // Ch. 30 p.390 (previously named `->FindIndex`): returns an
            // array of the 1-based indices for EVERY match, not just the
            // first (confirmed by the worked example p.395-396: searching
            // `(6,1,4,1,5,1,2,3,1)` for `1` returns all four positions
            // `(2),(4),(6),(9)`, not just position 2).
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value) : .null
            let positions = values.enumerated()
                .filter { lassoEquals($0.element, needle) }
                .map { LassoValue.integer($0.offset + 1) }
            return .array(positions)
        case let (.array(values), "remove"):
            // Ch. 30 p.390/393: position-based (1-based), defaults to
            // removing the LAST item when no argument is given — real
            // Lasso's `Remove` and `RemoveAll` are opposite-shaped from
            // what an earlier version of this had them do (that version
            // had `->remove` doing value-based removal, which is actually
            // `->RemoveAll`'s documented job, and `->removeAll` clearing
            // unconditionally with no documented basis at all) — caught
            // by architect review checking both against the Guide's own
            // worked examples directly.
            let position: Int
            if let argument = arguments.first {
                position = Int(try await evaluate(argument.value).number ?? 0)
            } else {
                position = values.count
            }
            let index = position - 1
            guard values.indices.contains(index) else { return .array(values) }
            var updated = values
            updated.remove(at: index)
            return .array(updated)
        case let (.array(values), "removeall"):
            // Ch. 30 p.390/396: value-based — removes every element that
            // matches the parameter (confirmed by the worked example:
            // `$Delete_Array->(RemoveAll: 1)` drops every `1` from
            // `(6,1,4,1,5,1,2,3,1)`, leaving `(6,4,5,2,3)`).
            // Matcher-aware — verified against the p.421 worked example:
            // `$array->RemoveAll(Match_Range(2, 4))` on `(1..7)` leaves
            // `(1,5,6,7)`.
            guard let argument = arguments.first else { return .array(values) }
            let target = try await evaluate(argument.value)
            return .array(try await LassoMatcherValue.filterNotMatching(target, in: values, context: context))
        // `.map` dispatch tries a literal key match FIRST, falling back to
        // these documented methods only on a miss — NOT the other way
        // around. This codebase already uses `.map` for two different
        // things: a real Lasso `Map` value, and (via the file-upload/
        // request-metadata providers) plain field-name-keyed records —
        // e.g. `file_uploads->get(1)->size` reads a real `"size"` KEY
        // (the upload's byte count), not an entry count. An earlier
        // version of this fix gave `->size`/`->keys`/etc. unconditional
        // priority over key lookup (matching how real Lasso's own
        // documented Map methods always win) and broke that real,
        // already-tested upload-metadata path — caught by the existing
        // `fileUploadsExposeMetadataUnderBothLasso9And8KeyNames` test
        // failing. Key-first with a fallback keeps that working here for
        // the pure-read methods below (worst case on a collision: reads
        // the wrong value) — but NOT for `->remove`/`->removeall`, which
        // stay unconditional (see the cases right after `->insert`
        // above): those two are in `selfMutatingMethods`, so a key-first
        // miss there wouldn't just misread a value, it would let
        // `evaluateStatement` silently overwrite the whole map variable
        // with whatever was under a literal "remove"/"removeall" key —
        // caught by architect review. This still fixes the original bug:
        // a map with NO key named "size" previously fell all the way
        // through to `.null` instead of returning a real count (see
        // Documentation/lasso9-lassoguide-gap-analysis-plan.md Section 2).
        case let (.map(values), _) where values[normalized] != nil:
            return values[normalized] ?? .null
        case let (.map(values), "size"): return .integer(values.count)
        // `.map`'s backing `[String: LassoValue]` is a Swift Dictionary —
        // it has no stable, meaningful insertion order to preserve, so
        // `->keys`/`->values` iterate in sorted-by-key order instead of
        // raw (effectively arbitrary) Dictionary order. That's chosen
        // specifically so the two stay in lockstep with each other
        // (`values[i]` really is the value for `keys[i]`) and so output
        // is deterministic/testable, not because it's confirmed to match
        // real Lasso's own Map key ordering. Note this means `->keys`/
        // `->values` can disagree with `iterate`/`with`'s own raw
        // (undefined) Dictionary order over the same map — acceptable
        // since neither order is "more correct" per real Lasso (Ch. 30
        // p.400: "the order of elements in a map is not defined").
        case let (.map(values), "keys"): return .array(values.keys.sorted().map(LassoValue.string))
        case let (.map(values), "values"): return .array(values.keys.sorted().map { values[$0] ?? .null })
        case let (.map(values), "get"):
            // Ch. 30 p.402: "[Map->Get] Returns a PAIR from the map by
            // integer position" (1-based) — using the exact same
            // sorted-by-key order as `->Keys`/`->Values` right above, so
            // `Get(n)` genuinely corresponds to `Keys[n]`/`Values[n]`.
            // Confirmed via the worked example's own `[Loop:
            // ($DaysOfWeek->Size)] ... ($DaysOfWeek->(Get: (Loop_Count)))`
            // pattern producing keys 1..7 in order — that example's keys
            // happen to already be pre-sorted integers, so it can't by
            // itself distinguish sorted-order from insertion-order, but
            // matches this codebase's own established "order is
            // undefined, so pick sorted-by-key for determinism"
            // position on `->Keys`/`->Values` two lines up.
            let sortedKeys = values.keys.sorted()
            let position = (arguments.first != nil ? try await evaluate(arguments[0].value).number : nil).map(Int.init) ?? 0
            let index = position - 1
            guard sortedKeys.indices.contains(index) else { return .null }
            let key = sortedKeys[index]
            return .pair(.string(key), values[key] ?? .null)
        case let (.map(values), "iterator"):
            // Table 23: map is one of the explicitly-named built-in
            // `->Iterator`-supporting types — verified against the
            // p.424 worked example's own key+value `While` loop
            // (`$myIterator->Key + ' = ' + $myIterator->Value`).
            let matcher = arguments.first != nil ? try await evaluate(arguments[0].value) : nil
            return try await LassoIteratorValue.build(from: .map(values), reverse: false, matcher: matcher, context: context) ?? .null
        case let (.map(values), "reverseiterator"):
            let matcher = arguments.first != nil ? try await evaluate(arguments[0].value) : nil
            return try await LassoIteratorValue.build(from: .map(values), reverse: true, matcher: matcher, context: context) ?? .null
        case let (.map(values), "contains"):
            let key = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            return .boolean(values[key] != nil)
        case let (.map(values), "find"):
            // An explicit, argument-taking spelling of the same miss-safe
            // lookup the key-first case above already performs for a
            // literal `->keyName` call — useful when the key itself is a
            // dynamic/computed value rather than a fixed member name.
            let key = arguments.first != nil ? try await evaluate(arguments[0].value).outputString : ""
            return values[key] ?? .null
        // A genuinely unknown `.map` member falls through to `.null`
        // (not a throw, unlike `.array`'s `default: throw` further
        // below) — mirrors `.object`'s own miss behavior
        // (`TypeSystem.swift`'s `data[name.lowercased()] ?? .null`),
        // the more relevant precedent given `.map`'s dual use as a
        // record/object-like container for request/upload metadata.
        // `introspectionResult` is checked first so `->Type`/`->IsA`/
        // `->HasMethod` still work on a map — but only after the
        // key-first case above has already had first refusal, so a real
        // key named "type" (e.g. a file upload's content type) keeps
        // winning exactly as it did before this fallback existed.
        case (.map, _):
            if let introspected = try await introspectionResult(normalized, base, arguments) { return introspected }
            return .null
        case let (.object(object), _):
            if let nativeMethod = context.nativeTypes.type(named: object.typeName)?.method(named: name) {
                let evaluatedArguments = try await evaluate(arguments)
                return try await nativeMethod(object, evaluatedArguments, &context)
            }
            if let type = context.tagRegistry.type(named: object.typeName),
               let value = try await invokeMemberMethod(named: name, on: object, type: type, arguments: arguments) {
                return value
            }
            // A real native/custom-defined method (checked above) wins
            // over the synthetic introspection tags, which in turn win
            // over a plain data-field fallback — matching this case's
            // existing method-before-field priority (native method, then
            // custom method, then raw field) rather than `.map`'s
            // key-first design: unlike `.map`, `.object` already treats
            // methods as taking priority over generic field access, and
            // no real corpus type defines a data member literally named
            // "type"/"isa"/"isnota"/"hasmethod".
            if let introspected = try await introspectionResult(normalized, base, arguments) { return introspected }
            return object.value(for: name)
        default:
            if let introspected = try await introspectionResult(normalized, base, arguments) { return introspected }
            throw LassoRuntimeError.unsupportedExpression("Member \(name)")
        }
    }

    /// Only real Lasso identifier characters — a dynamically-resolved
    /// argument label (see `evaluate(_ arguments:)`'s `.variable` case)
    /// can reach `DynamicPredicate.field` as a runtime SQL column name.
    /// Perfect-MySQL's `quote(identifier:)` (Perfect-MySQL's
    /// MySQLCRUD.swift) only wraps an identifier in backticks — it does
    /// not escape embedded backticks — so this codebase can't rely on the
    /// connector to safely handle an arbitrary runtime string as an
    /// identifier. This check is deliberately stricter than MySQL's own
    /// unquoted-identifier grammar; both real corpus values
    /// ('mfr_style_no', 'scrubs_style_color') satisfy it comfortably.
    ///
    /// Not `private`: also called from `Providers.swift`'s
    /// `LassoInlineRequest.init(arguments:)` to validate `-Table`/
    /// `-ReturnField`/`-SortField`/`-KeyField` argument VALUES, a second,
    /// live-confirmed path to the same unescaped identifier sink — real
    /// corpus: components/inSite/results_navigation.inc builds
    /// `-sortfield=$sortCol` directly from `action_param('sortfield')`,
    /// completely unvalidated before this fix.
    static func validateDynamicFieldLabel(_ label: String) throws {
        // Empty is "no value provided," not unsafe — real corpus/tests use
        // `-KeyField=''` as this codebase's existing convention for an
        // absent key field (e.g. fileMakerExecutorGatesAddUpdateDeleteBehindAllowWrites),
        // and there's nothing an empty string can inject. The executor's
        // own missing-field handling (not this check) is what should
        // reject it as incomplete, same as before this validation existed.
        guard !label.isEmpty else { return }
        // `\A`/`\z` (absolute string boundaries), not `^`/`$` — ICU/NSRegularExpression's
        // `$` also matches immediately before a single trailing line terminator,
        // which would let a label like "colname\n" slip through unnoticed.
        guard label.range(of: "\\A[A-Za-z_][A-Za-z0-9_]*\\z", options: .regularExpression) != nil else {
            throw LassoRuntimeError.unsafeDynamicFieldName(label)
        }
    }

    private static func assignmentLabel(_ expression: LassoExpression) -> String? {
        switch expression {
        case let .identifier(name), let .string(name):
            return name
        case let .variable(name, _):
            return name
        // Lasso 8.5 Language Guide p.400: "[Map: 1='Sunday', 2='Monday', ...]"
        // — a map key written as an integer literal, coerced to a string
        // ("The name or key is always a string value"). Without this case
        // `1='Sunday'` fell through to the default `.assignment` evaluation
        // path, which tried to write-back to an `.integer` target and threw
        // `invalidAssignment`.
        case let .integer(value):
            return String(value)
        case let .decimal(value):
            return String(value)
        case let .binary(left, "::", _):
            return assignmentLabel(left)
        default:
            return nil
        }
    }

    private static func isVarOrLocalCallee(_ callee: LassoExpression) -> Bool {
        guard case let .identifier(name) = callee else { return false }
        return name.caseInsensitiveCompare("var") == .orderedSame
            || name.caseInsensitiveCompare("variable") == .orderedSame
            || name.caseInsensitiveCompare("var_set") == .orderedSame
            || name.caseInsensitiveCompare("local") == .orderedSame
    }

    /// Methods real Lasso mutates the invocant with, rather than returning
    /// a new value for the caller to reassign — array/map `->insert` and
    /// string `->replace` both qualify (real corpus: includes/detail_a_sku.lasso's
    /// bare `$skuArrayItem->insert(...)`; pages/thumbs2.page.lasso's bare
    /// `$cleaned_product_name->(Replace('(',''))` chain, and the same
    /// shape in templates/*/master.template.lasso's
    /// `$meta_keywords->(Replace('-',','))` — used across every template
    /// in the site). `->append` joins them for the same reason (real
    /// corpus: LassoStartup/hash_test.lasso's bare `#hash->append('\r\n')`).
    /// `->trim` joins them too (documented "modifies the string in place
    /// and returns no value"; real corpus: login_check_top.lasso's bare
    /// `$email->(trim)` and lost_password.page.lasso's bare
    /// `#new_email->(trim)`).
    /// Only consulted by `evaluateStatement(_:)`, not the generic
    /// recursive `evaluate(_:)` — see that method's doc for why.
    static let selfMutatingMethods: Set<String> = [
        "insert", "replace", "append", "trim",
        // `Queue->InsertFrom` (Ch. 30, operations/collections.html) is
        // documented the same "modifies the receiver" way `->Insert`
        // already is — same write-back shape, just for Stage 4
        // (Captures)'s new method.
        "insertfrom",
        // `Array->Sort`/`->Reverse`/`->Remove`/`->RemoveAll` are documented
        // (Lasso 8.5 Language Guide Ch. 30) as invocant-mutating, exactly
        // like `->Insert` above — real corpus need: sorted product/category
        // lists (`->Sort`) and building a list from search results while
        // dropping already-seen SKUs (`->Remove`).
        "sort", "reverse", "remove", "removeall",
        // `String->PadLeading`/`->PadTrailing`/`->RemoveLeading`/
        // `->RemoveTrailing`/`->Titlecase` (Ch. 25 Tables 3/5) —
        // documented "Modifies the string and returns no value",
        // exactly like `->Trim`/`->Append` above.
        "padleading", "padtrailing", "removeleading", "removetrailing", "titlecase",
        // `String->Merge`/`->Foldcase`/`->toLower`/`->toUpper`/`->toTitle`/
        // `->Unescape` (Ch. 25 Tables 3/5) — same "modifies the string
        // and returns no value" convention as the row above. `->Remove`
        // is already covered by the pre-existing `"remove"` entry
        // (shared with `Array->Remove`, purely name-based per this set's
        // own top-level doc comment).
        "merge", "foldcase", "tolower", "toupper", "totitle", "unescape",
        // `Date->Add`/`Date->Subtract` (Lasso 8.5 Language Guide Ch. 29
        // Table 7) — documented as changing "the values of variables
        // that contain date... data types" when called as a bare
        // statement. This check is purely syntactic (AST shape + name),
        // not type-scoped, so it's safe to share across every base type:
        // only `date` objects actually register "add"/"subtract" methods
        // (see `NativeTypes.makeDateType()`) — no `.array`/`.map`/
        // `.string` member case uses either name, so this has no effect
        // on those.
        "add", "subtract",
        // List/Queue/Stack/Set (Ch. 30 Tables 5/13/16/18) — each
        // documented "Returns no value" except `Queue->Get`/`Stack->Get`
        // (deliberately excluded here — see `Collections.swift`'s own
        // top-level doc comment for why those two need a different,
        // narrower mechanism instead). `Difference`/`Intersection`/
        // `Union` "return a new [list/set]" per their own Table
        // wording, but the Guide's own worked example
        // (`[$ResultSet->(Difference: $SecondSet)] [$ResultSet]`, Ch.
        // 30 p.412) calls one bare and shows the CALLING variable
        // reflecting the result afterward with no reassignment — the
        // exact same self-mutating write-back shape as everything else
        // in this set.
        "insertfirst", "insertlast", "removefirst", "removelast",
        "difference", "intersection", "union",
        // `Array->SortWith`/`List->SortWith` (Ch. 30 Table 21's own
        // text: "Comparators can also be used with the [Array->SortWith]
        // and [List->SortWith] tags") — documented "Modifies the list in
        // place and returns no value" for List (Table 5); Array's own
        // `->Sort` above already established the same bare-statement
        // mutation shape, so `->SortWith` follows it too now that
        // Comparator values exist (Stage 2, `Comparators.swift`).
        "sortwith",
    ]

    /// Best-effort ordering for `Array->Sort` — every numeric-parseable
    /// element sorts before every non-numeric one, numeric elements
    /// compare by value (not lexicographically, where `"10"` < `"9"` as
    /// strings but not as numbers), non-numeric elements compare by their
    /// string form. Deriving a fixed per-element sort key up front (rather
    /// than branching per-*pair* on whether both sides happen to be
    /// numeric) is what actually guarantees a valid strict weak ordering
    /// across a mixed array — a per-pair branch can otherwise violate
    /// transitivity: e.g. with elements `9`, `10`, and the non-numeric
    /// string `"5apple"`, a per-pair rule compares `9 < 10` numerically
    /// (true) and `10 < "5apple"` as strings via `"10" < "5apple"` (true,
    /// since `'1' < '5'`), but `9 < "5apple"` as strings via `"9" <
    /// "5apple"` is FALSE (`'9' > '5'`) — `9 < 10 < "5apple"` yet NOT
    /// `9 < "5apple"`, a transitivity violation Swift's `sorted(by:)`
    /// doesn't validate and would silently mis-sort on.
    // `internal`, same reason as `binary` above.
    static func lassoSortKey(_ value: LassoValue) -> (Int, Double, String) {
        // `.isFinite` guards against Swift's `Double(String)` parsing
        // tokens like `"nan"`/`"inf"`/`"infinity"` (matching C's `strtod`)
        // into real IEEE 754 NaN/infinity rather than returning `nil` —
        // `Double.nan`'s `<` never returns true in either direction, which
        // would silently reintroduce the exact strict-weak-ordering
        // violation this whole key-based design exists to prevent, if a
        // Lasso array ever contained a literal string like `'NaN'`.
        // Flagged in architect review; low real-world likelihood on this
        // project's corpus, but cheap enough to close outright.
        if let number = value.number, number.isFinite { return (0, number, "") }
        // Lowercased: Lasso string comparisons are case-insensitive by
        // convention throughout this interpreter — `==`/`lassoEquals`'s
        // own doc comment cites a real production incident for exactly
        // this (`'Yes'` vs `'yes'`), and Ch. 30's own Match_Range worked
        // example (p.426, `Match_Range('a','m')` against `('One','Two',
        // 'Three','Four')` yielding only "Four") only reproduces under
        // case-insensitive `<` — direct primary-source proof that Lasso's
        // ordering comparison, not just equality, ignores case. Previously
        // this bucket used raw `outputString`, and a separate, duplicate
        // `lassoLessThanCaseInsensitive` lived in `Matchers.swift` used
        // only by `Match_Range`/`Match_NotRange` — an inconsistency a
        // user code-review challenge caught directly ("shouldn't the
        // comparison methods all use the same case sensitivity?").
        // Unified here instead: no existing `->Sort`/Set/PriorityQueue/
        // TreeMap test exercises a case-collision, so this changes no
        // previously-verified behavior, only fixes unverified-and-wrong
        // behavior to match the one worked example that actually tests it.
        return (1, 0, value.outputString.lowercased())
    }

    // `internal`, same reason as `binary` above.
    static func lassoLessThan(_ lhs: LassoValue, _ rhs: LassoValue) -> Bool {
        lassoSortKey(lhs) < lassoSortKey(rhs)
    }

    /// Lasso element equality for array/map membership tests (`->Contains`/
    /// `->Find`/`->FindPosition`/`->RemoveAll`) — routes through the same
    /// case-insensitive `==` this interpreter already uses everywhere else
    /// (`binary(_:"==",_:)`, `Evaluator.swift:396-406`) rather than Swift's
    /// raw auto-synthesized `LassoValue: Equatable`, which is case-
    /// sensitive for `.string`. Using the raw form here would have
    /// reintroduced the exact bug class `==`'s own doc comment cites a
    /// real production incident for (`thumbs2.page.lasso`'s ribbon check
    /// silently breaking on `'Yes'` vs `'yes'`) — flagged in architect
    /// review before it shipped.
    // `internal`, same reason as `binary` above — `Collections.swift`
    // constructs a throwaway `Evaluator(context:)` (a cheap value-type
    // copy, not aliasing) purely to call this and `binary`, neither of
    // which read or mutate `self.context`.
    func lassoEquals(_ lhs: LassoValue, _ rhs: LassoValue) -> Bool {
        (try? binary(lhs, "==", rhs))?.isTruthy ?? false
    }

    /// Evaluates the *entire* root expression of a top-level statement —
    /// the whole content of a bare `[...]`/script-mode statement, called
    /// only from `Renderer.renderExpression` (never recursively from
    /// `evaluate(_:)` itself). Real Lasso's self-mutating methods
    /// (`->insert`, `->replace`, ...) mutate their invocant in place and
    /// produce no visible output when the call *is* the statement — but
    /// the same call nested inside a larger expression still needs its
    /// plain, computed value (see the `.member` case's comment on
    /// `_begin.lasso`'s `#out = '-' + #out->replace('-','')`), so this
    /// check only fires when the member call is the statement's own root,
    /// not buried in `evaluate(_:)`'s shared recursive path.
    mutating func evaluateStatement(_ expression: LassoExpression) async throws -> LassoValue {
        // A real *variable* base only — `assignmentLabel` also accepts
        // `.string`/`.identifier` bases (valid for its other use, labeling
        // a dynamic call argument), but those can't be written back to.
        // Real corpus: `pages/subcats3.page.lasso`'s
        // `('no!smoking!allowed')->(Replace('!','<br>'))`-shaped literal
        // base must still just return its computed value, not attempt a
        // write-back.
        if case let .member(base, name, arguments) = expression,
           Self.selfMutatingMethods.contains(name.lowercased()),
           case .variable = base {
            let result = try await member(try await evaluate(base), name, arguments ?? [])
            try await assign(result, to: base, defaultScope: .unscoped)
            return .void
        }
        return try await evaluate(expression)
    }
}

extension LassoNativeTypeRegistry {
    /// `queriable_grouping` (Ch. "Query Expressions", "Group By") — a
    /// `group ... by ... into NAME` operation's own result type (Stage
    /// 8.4). "A `queriable_grouping` object maintains a reference to
    /// each of the original elements within the group. It also
    /// possesses a `key` method which produces the value by which the
    /// particular elements were mutually grouped." `_elements` uses the
    /// SAME storage-key convention `LassoCollectionValue` already
    /// established for List/Set/etc. (`Collections.swift`), so
    /// `Evaluator.forEachElements(of:)` recognizing this type name for
    /// free makes a grouping "further usable throughout the query
    /// expression" (as a nested with-source, or via `->forEach`) with no
    /// additional plumbing — exactly matching that documented framing.
    static func makeQueriableGroupingType() -> LassoNativeType {
        var type = LassoNativeType(name: "queriable_grouping")
        type.register("key") { receiver, _, _ in
            receiver.value(for: "_key")
        }
        return type
    }
}

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
        case let .variable(name, scope): return context.value(for: name, scope: scope)
        case let .identifier(name):
            if name.caseInsensitiveCompare("self") == .orderedSame, let object = context.currentSelf {
                return .object(object)
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
                    return .boolean(elements.contains { LassoMatcherValue.matches(rightValue, element: $0, context: context) })
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
        let evaluatedCallArguments = try await evaluate(callArguments)
        let boundLocals = try await bindParameters(definition.parameters, to: evaluatedCallArguments)

        let savedLocals = context.snapshotLocals()
        let savedLoopDepth = context.loopDepth
        try context.pushTagCall(definition.name)
        context.replaceLocals(boundLocals)
        // A tag call starts a fresh scope with no loop of its own yet —
        // without this, a stray Loop_Abort/Loop_Continue inside this
        // tag's own body (which has no loop) would be mistaken by
        // `shouldStopRenderingCurrentBody()` for "some enclosing loop out
        // there wants this" just because the *caller* happened to be
        // inside one, and leak back out to abort/skip whatever loop
        // iteration is calling this tag. See `LassoContext.loopDepth`.
        context.loopDepth = 0
        defer {
            context.replaceLocals(savedLocals)
            context.popTagCall()
            context.loopDepth = savedLoopDepth
        }

        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        _ = try await renderNodes(definition.body, &context)
        return context.consumeReturnSignal() ?? .void
    }

    private mutating func bindParameters(
        _ parameters: [LassoArgument],
        to callArguments: [EvaluatedArgument]
    ) async throws -> [String: LassoValue] {
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
                bound[name.lowercased()] = try await evaluate(defaultExpression)
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
    ) async throws -> LassoValue {
        let object = LassoObjectInstance(typeName: type.name)
        // Legacy constructors (e.g. `local('ip' = (params->first ? ...))`)
        // reference the constructor call's own arguments as `params` while
        // data member defaults are evaluated — see
        // Documentation/legacy-define-tag-type-plan.md's "Constructor
        // params" note. Bound as an ordinary local (not passed through
        // invokeMemberMethod's own parameter binding) so it's visible here
        // and restored to whatever it was before once construction ends.
        let evaluatedCallArguments = try await evaluate(callArguments)
        let savedLocals = context.snapshotLocals()
        context.set(.array(evaluatedCallArguments.map(\.value)), for: "params", scope: .local)
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
        let evaluatedCallArguments = try await evaluate(arguments)
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
        context.replaceLocals(boundLocals)
        context.pushSelf(object)
        // See the matching comment in `invokeCustomTag`.
        context.loopDepth = 0
        defer {
            context.popSelf()
            context.replaceLocals(savedLocals)
            context.loopDepth = savedLoopDepth
        }

        guard let renderNodes else { return .void }
        context.clearReturnSignal()
        _ = try await renderNodes(resolved.definition.body, &context)
        return context.consumeReturnSignal() ?? .void
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
        case "var", "variable", "var_reset": .global
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
            object.set(value, for: name)
        default:
            throw LassoRuntimeError.invalidAssignment
        }
    }

    private mutating func formattedNumber(_ value: Double, _ arguments: [LassoArgument]) async throws -> String {
        var precision: Int?
        for argument in arguments {
            guard argument.label?.caseInsensitiveCompare("precision") == .orderedSame else { continue }
            precision = Int(try await evaluate(argument.value).number ?? 0)
        }
        guard let precision else { return String(value) }
        return String(format: "%.\(max(precision, 0))f", value)
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
        case ">": return compare(left, right, >)
        case ">>":
            // Real Lasso 8/9's documented string-contains operator
            // (`left >> right` — "does left contain right") — not a
            // synonym for `>`. Treating it as `>` silently compared
            // string *lengths* instead of content (`compare`'s
            // no-numeric-operand fallback), which happened to look
            // right for some inputs by sheer coincidence (e.g. `'' >>
            // 'www3'` is false either way, since 0 > 4 is also false)
            // but was wrong in general. Real corpus: ~32 files use this
            // exact `left >> 'substring'` shape for host/environment
            // detection (e.g. components/koi_setup.inc's
            // `server_name >> 'www2'` chain) and bot-string matching
            // (site_setup_tags.inc's `excludeBots`).
            return .boolean(left.outputString.contains(right.outputString))
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
        case let (.integer(value), "asstring"):
            return .string(try await formattedNumber(Double(value), arguments))
        case let (.decimal(value), "asstring"):
            // Real corpus: pages/thumbs.page.lasso's
            // `decimal(field('starting_price'))->asString(-precision=2)`
            // (`-precision` fixes the number of digits after the decimal
            // point; real Lasso also accepts it on integers, e.g.
            // lassoBackup/scrubs/LassoApps/ds/_init.lasso's
            // `(...)->asstring(-precision=3)` on a `Double` literal
            // expression, hence the shared `formattedNumber` helper).
            return .string(try await formattedNumber(value, arguments))
        case let (.decimal(value), "ceil"): return .decimal(value.rounded(.up))
        case let (.integer(value), "ceil"): return .integer(value)
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
            let updated = LassoTreeMapValue.removingAllMatchingKey(matcherOrKey, from: object, context: context)
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
            guard let kind = LassoComparatorValue.kind(of: comparatorArgument) else {
                return .array(values)
            }
            return .array(values.sorted { LassoComparatorValue.isOrderedBefore(kind: kind, $0, $1) })
        case let (.array(values), "iterator"):
            // Table 23: array is one of the explicitly-named built-in
            // `->Iterator`-supporting types — verified against the
            // p.423 worked example's own `Array->Iterator` call.
            let matcher = arguments.first != nil ? try await evaluate(arguments[0].value) : nil
            return LassoIteratorValue.build(from: .array(values), reverse: false, matcher: matcher, context: context) ?? .null
        case let (.array(values), "reverseiterator"):
            let matcher = arguments.first != nil ? try await evaluate(arguments[0].value) : nil
            return LassoIteratorValue.build(from: .array(values), reverse: true, matcher: matcher, context: context) ?? .null
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
            return .boolean(values.contains { LassoMatcherValue.matches(needle, element: $0, context: context) })
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
            return .array(values.filter { LassoMatcherValue.matches(needle, element: $0, context: context) })
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
            return .array(values.filter { !LassoMatcherValue.matches(target, element: $0, context: context) })
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
            return LassoIteratorValue.build(from: .map(values), reverse: false, matcher: matcher, context: context) ?? .null
        case let (.map(values), "reverseiterator"):
            let matcher = arguments.first != nil ? try await evaluate(arguments[0].value) : nil
            return LassoIteratorValue.build(from: .map(values), reverse: true, matcher: matcher, context: context) ?? .null
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

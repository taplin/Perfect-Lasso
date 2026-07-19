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
            if name.caseInsensitiveCompare("var") == .orderedSame ||
                name.caseInsensitiveCompare("variable") == .orderedSame ||
                name.caseInsensitiveCompare("local") == .orderedSame {
                return try await declare(arguments, local: name.lowercased() == "local")
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

    private mutating func declare(_ arguments: [LassoArgument], local: Bool) async throws -> LassoValue {
        let scope: VariableScope = local ? .local : .global
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
        case let .member(base, name, _):
            let baseValue: LassoValue
            if case let .identifier(baseName) = base,
               baseName.caseInsensitiveCompare("self") == .orderedSame,
               let object = context.currentSelf {
                baseValue = .object(object)
            } else {
                baseValue = try await evaluate(base)
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
            // (`""`) elsewhere in this runtime.
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
            let needle: String
            if let argument = arguments.first {
                needle = try await evaluate(argument.value).outputString
            } else {
                needle = ""
            }
            return .boolean(value.contains(needle))
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
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value) : .null
            return .boolean(values.contains { lassoEquals($0, needle) })
        case let (.array(values), "find"):
            // Ch. 30 p.390/395-396: returns an ARRAY of every element that
            // matches the parameter, not a boolean and not a position. A
            // Pair-array (real corpus: Action_Params/Params results)
            // compares the parameter only against each pair's `->First`
            // half, per the doc's own worked example (p.396,
            // `$Pair_Array->(Find: 'Alpha')`) — confirmed by reading that
            // section directly, not inferred.
            let needle = arguments.first != nil ? try await evaluate(arguments[0].value) : .null
            return .array(values.filter { element in
                if case let .pair(key, _) = element { return lassoEquals(key, needle) }
                return lassoEquals(element, needle)
            })
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
            guard let argument = arguments.first else { return .array(values) }
            let target = try await evaluate(argument.value)
            return .array(values.filter { !lassoEquals($0, target) })
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
        case (.map, _): return .null
        case let (.object(object), _):
            if let nativeMethod = context.nativeTypes.type(named: object.typeName)?.method(named: name) {
                let evaluatedArguments = try await evaluate(arguments)
                return try await nativeMethod(object, evaluatedArguments, &context)
            }
            guard let type = context.tagRegistry.type(named: object.typeName) else {
                return object.value(for: name)
            }
            if let value = try await invokeMemberMethod(named: name, on: object, type: type, arguments: arguments) {
                return value
            }
            return object.value(for: name)
        default: throw LassoRuntimeError.unsupportedExpression("Member \(name)")
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
    private static func lassoSortKey(_ value: LassoValue) -> (Int, Double, String) {
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
        return (1, 0, value.outputString)
    }

    private static func lassoLessThan(_ lhs: LassoValue, _ rhs: LassoValue) -> Bool {
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
    private func lassoEquals(_ lhs: LassoValue, _ rhs: LassoValue) -> Bool {
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

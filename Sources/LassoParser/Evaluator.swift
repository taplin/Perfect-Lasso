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
            let result = try await member(try await evaluate(base), name, arguments ?? [])
            // A handful of array methods mutate the invocant in place in
            // real Lasso (`->insert` etc.), rather than returning a new
            // array for the caller to reassign — real corpus:
            // includes/detail_a_sku.lasso's bare-statement
            // `$skuArrayItem->insert(...)` (no `=`), used purely for its
            // side effect. `LassoValue.array` is a value type here, so
            // that side effect has to be applied explicitly: write the
            // computed result back to `base` when it's an assignable
            // target shape (a plain variable, matching every real corpus
            // use of these methods so far).
            if Self.selfMutatingArrayMethods.contains(name.lowercased()), Self.assignmentLabel(base) != nil {
                try await assign(result, to: base, defaultScope: .unscoped)
                // The mutation itself is what matters here — real corpus
                // never uses `->insert`'s return value (every call is a
                // bare statement, `$x->insert(...)` on its own line).
                // Returning the mutated array/map as this *expression's*
                // own value made a bare `[...]`/script-mode statement
                // that calls `->insert` auto-echo the entire container's
                // contents as visible page text (found live: a raw
                // `KOI247-060-XS = Galaxy...` field dump appearing on a
                // real product detail page, right where `$skuArrayItem
                // ->insert(...)` runs as its own statement).
                return .void
            }
            return result
        case let .unknown(value):
            throw LassoRuntimeError.unsupportedExpression(value)
        }
    }

    private mutating func evaluate(_ arguments: [LassoArgument]) async throws -> [EvaluatedArgument] {
        var results: [EvaluatedArgument] = []
        results.reserveCapacity(arguments.count)
        for argument in arguments {
            if argument.label == nil,
               case let .assignment(target, value) = argument.value,
               let label = Self.assignmentLabel(target) {
                results.append(EvaluatedArgument(label: label, value: try await evaluate(value)))
            } else {
                results.append(EvaluatedArgument(label: argument.label, value: try await evaluate(argument.value)))
            }
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
        try context.pushTagCall(definition.name)
        context.replaceLocals(boundLocals)
        defer {
            context.replaceLocals(savedLocals)
            context.popTagCall()
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
        context.replaceLocals(boundLocals)
        context.pushSelf(object)
        defer {
            context.popSelf()
            context.replaceLocals(savedLocals)
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
        case let (.array(values), "get"):
            let requested: Double?
            if let argument = arguments.first {
                requested = try await evaluate(argument.value).number
            } else {
                requested = nil
            }
            let index = max(Int(requested ?? 1) - 1, 0)
            return values.indices.contains(index) ? values[index] : .null
        case let (.map(values), _): return values[normalized] ?? .null
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
        return name.caseInsensitiveCompare("var") == .orderedSame || name.caseInsensitiveCompare("local") == .orderedSame
    }

    /// Array methods real Lasso mutates the invocant with, rather than
    /// returning a new array for the caller to reassign. See the
    /// `.member` case's write-back comment above.
    private static let selfMutatingArrayMethods: Set<String> = ["insert"]
}

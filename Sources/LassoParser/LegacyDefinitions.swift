/// Lowers legacy `Define_Tag`/`Define_Type` syntax into the same runtime
/// models modern `define name(...) => { ... }` already uses
/// (`LassoCustomTagDefinition`, `LassoTypeDefinition`, `LassoMethodDefinition`,
/// `LassoDataMemberDefinition`) — see
/// `Documentation/legacy-define-tag-type-plan.md`. Deliberately does not
/// introduce a second runtime path: both syntaxes end up registered on the
/// same `LassoTagRegistry` and dispatched through the same
/// `LassoMethodDispatcher`/`invokeCustomTag` machinery.
enum LegacyDefinitions {
    /// Translates legacy flag-style parameter arguments (`-Required='name'`,
    /// `-Optional='name'`, with an immediately-following `-Type='typeName'`
    /// applying a type constraint) into the same `LassoArgument` shape
    /// `LassoMethodDispatcher.parameterMetadata` already understands for
    /// modern tags: a bare `.identifier(name)`, or `.binary(name, "::",
    /// type)` when type-constrained. Every other documented `Define_Tag`
    /// flag (`-Namespace`, `-Async`, `-Atomic`, `-Container`, `-Looping`,
    /// `-Priority`, `-Criteria`, `-Copy`, `-Description`, `-ReturnType`,
    /// `-RPC`, `-SOAP`, `-EncodeNone`, `-Privileged`) is recognized and
    /// discarded here rather than mistaken for a parameter declaration —
    /// see the plan's "Documented Flags And Parameters" section for which
    /// of those are acted on elsewhere vs. explicitly deferred.
    static func translateParameters(_ arguments: [LassoArgument]) -> [LassoArgument] {
        var parameters: [LassoArgument] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            defer { index += 1 }
            guard let label = argument.label?.lowercased(), label == "required" || label == "optional" else {
                continue
            }
            guard case let .string(paramName) = argument.value else { continue }

            if index + 1 < arguments.count,
               arguments[index + 1].label?.lowercased() == "type",
               case let .string(typeName) = arguments[index + 1].value {
                parameters.append(LassoArgument(
                    label: nil,
                    value: .binary(left: .identifier(paramName), operator: "::", right: .identifier(typeName))
                ))
                index += 1
            } else {
                parameters.append(LassoArgument(label: nil, value: .identifier(paramName)))
            }
        }
        return parameters
    }

    /// Walks an already-parsed `define_type` body (ordinary `[LassoNode]`,
    /// not a dedicated sub-parser) for the two shapes it can contain:
    /// nested `.block(name: "define_tag", ...)` nodes (member tags) and
    /// `local(...)`/`local:` calls (instance data members with defaults).
    /// Anything else (comments-as-text, stray whitespace) is ignored.
    static func lowerTypeBody(_ body: [LassoNode]) -> (dataMembers: [LassoDataMemberDefinition], methods: [LassoMethodDefinition]) {
        var dataMembers: [LassoDataMemberDefinition] = []
        var methods: [LassoMethodDefinition] = []

        for node in body {
            switch node {
            case let .block(name, arguments, methodBody, _, _, _) where name.caseInsensitiveCompare("define_tag") == .orderedSame:
                guard case let .string(methodName)? = arguments.first?.value else { continue }
                methods.append(LassoMethodDefinition(
                    name: methodName,
                    parameters: translateParameters(Array(arguments.dropFirst())),
                    returnType: nil,
                    visibility: .public,
                    body: methodBody
                ))
            case let .code(expressions, _, _, _):
                for expression in expressions {
                    dataMembers.append(contentsOf: legacyDataMembers(from: expression))
                }
            case let .expression(expression, _, _, _):
                dataMembers.append(contentsOf: legacyDataMembers(from: expression))
            default:
                continue
            }
        }
        return (dataMembers, methods)
    }

    private static func legacyDataMembers(from expression: LassoExpression) -> [LassoDataMemberDefinition] {
        guard case let .call(callee, arguments) = expression,
              case let .identifier(name) = callee,
              name.caseInsensitiveCompare("local") == .orderedSame else {
            return []
        }
        return arguments.compactMap { argument in
            guard case let .assignment(target, value) = argument.value,
                  case let .string(memberName) = target else {
                return nil
            }
            return LassoDataMemberDefinition(name: memberName, typeConstraint: nil, defaultValue: value, visibility: nil)
        }
    }
}

/// A literal `session_start(name, -flag=value, ...)` call found by scanning
/// a parsed page ahead of render. Real Lasso sessions are created/resumed
/// through `PerfectSessionCore.SessionDriver`, which is async, while the
/// renderer/evaluator is synchronous — see
/// `Documentation/session-upload-support-plan.md`'s "Session Recommendation"
/// for why the server boundary preloads named sessions this way rather than
/// giving the evaluator an async native-call path.
public struct LassoSessionStartCall: Equatable, Sendable {
    public let name: String
    public let expiresSeconds: Int?
    public let id: String?
    public let useCookie: Bool
    public let useLink: Bool
    public let useAuto: Bool
    public let useNone: Bool
    public let cookieExpires: String?
    public let domain: String?
    public let path: String?
    public let secure: Bool
    public let httpOnly: Bool
    public let rotate: Bool

    public init(
        name: String,
        expiresSeconds: Int? = nil,
        id: String? = nil,
        useCookie: Bool = true,
        useLink: Bool = false,
        useAuto: Bool = false,
        useNone: Bool = false,
        cookieExpires: String? = nil,
        domain: String? = nil,
        path: String? = nil,
        secure: Bool = false,
        httpOnly: Bool = false,
        rotate: Bool = false
    ) {
        self.name = name
        self.expiresSeconds = expiresSeconds
        self.id = id
        self.useCookie = useCookie
        self.useLink = useLink
        self.useAuto = useAuto
        self.useNone = useNone
        self.cookieExpires = cookieExpires
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.rotate = rotate
    }
}

/// Scans a parsed document for `session_start` calls so the server boundary
/// can create/resume named sessions before the synchronous render runs.
///
/// Only literal arguments are recognized — a dynamically computed session
/// name or flag value (e.g. `session_start(var(sessionName))`) is invisible
/// to this scan, and that call's `session_start` will find no preloaded
/// session at render time (`LassoSessionProvider.start` returns `nil`). This
/// is a documented limitation of the preflight-scan approach, not a crash;
/// see the plan's own allowance for "preload lazily requested sessions
/// before render if the page can be scanned... when feasible."
public enum LassoSessionPreflight {
    public static func scan(_ document: LassoDocument) -> [LassoSessionStartCall] {
        var found: [LassoSessionStartCall] = []
        scan(nodes: document.nodes, into: &found)
        return found
    }

    private static func scan(nodes: [LassoNode], into found: inout [LassoSessionStartCall]) {
        for node in nodes {
            switch node {
            case .text:
                break
            case .expression(let expression, _, _, _):
                scan(expression: expression, into: &found)
            case .tag(_, let arguments, _, _, _):
                for argument in arguments { scan(expression: argument.value, into: &found) }
            case .code(let expressions, _, _, _):
                for expression in expressions { scan(expression: expression, into: &found) }
            case .block(_, let arguments, let body, let alternate, _, _):
                for argument in arguments { scan(expression: argument.value, into: &found) }
                scan(nodes: body, into: &found)
                if let alternate { scan(nodes: alternate, into: &found) }
            case .typeDefinition(let typeDefinition, _, _):
                for method in typeDefinition.methods { scan(nodes: method.body, into: &found) }
            }
        }
    }

    private static func scan(expression: LassoExpression, into found: inout [LassoSessionStartCall]) {
        switch expression {
        case .call(let callee, let arguments):
            if case .identifier(let name) = callee, name.caseInsensitiveCompare("session_start") == .orderedSame,
               let call = makeCall(from: arguments) {
                found.append(call)
            }
            scan(expression: callee, into: &found)
            for argument in arguments { scan(expression: argument.value, into: &found) }
        case .member(let base, _, let arguments):
            scan(expression: base, into: &found)
            for argument in arguments ?? [] { scan(expression: argument.value, into: &found) }
        case .unary(_, let value):
            scan(expression: value, into: &found)
        case .binary(let left, _, let right):
            scan(expression: left, into: &found)
            scan(expression: right, into: &found)
        case .assignment(let target, let value):
            scan(expression: target, into: &found)
            scan(expression: value, into: &found)
        case .ternary(let condition, let whenTrue, let whenFalse):
            scan(expression: condition, into: &found)
            scan(expression: whenTrue, into: &found)
            scan(expression: whenFalse, into: &found)
        case .string, .integer, .decimal, .boolean, .null, .void, .variable, .identifier, .unknown:
            break
        }
    }

    private static func makeCall(from arguments: [LassoArgument]) -> LassoSessionStartCall? {
        let positional = arguments.filter { $0.label == nil }
        guard let first = positional.first, case .string(let name) = first.value else { return nil }

        func flagString(_ label: String) -> String? {
            guard let argument = arguments.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame }),
                  case .string(let value) = argument.value else { return nil }
            return value
        }
        func flagInt(_ label: String) -> Int? {
            guard let argument = arguments.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame }),
                  case .integer(let value) = argument.value else { return nil }
            return value
        }
        func flagBool(_ label: String, default defaultValue: Bool) -> Bool {
            guard let argument = arguments.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame }) else {
                return defaultValue
            }
            if case .boolean(let value) = argument.value { return value }
            return defaultValue
        }

        return LassoSessionStartCall(
            name: name,
            expiresSeconds: flagInt("expires"),
            id: flagString("id"),
            useCookie: flagBool("usecookie", default: true),
            useLink: flagBool("uselink", default: false),
            useAuto: flagBool("useauto", default: false),
            useNone: flagBool("usenone", default: false),
            cookieExpires: flagString("cookieexpires"),
            domain: flagString("domain"),
            path: flagString("path"),
            secure: flagBool("secure", default: false),
            httpOnly: flagBool("httponly", default: false),
            rotate: flagBool("rotate", default: false)
        )
    }
}

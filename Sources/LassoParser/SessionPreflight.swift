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
///
/// **`include(...)`/`library(...)` are followed recursively when an
/// `includeLoader` is supplied.** Real sites overwhelmingly put their
/// initial `Session_Start` call in a shared header/config include, not
/// directly in every top-level page — confirmed live 2026-07-18: a real
/// site's `koi.lasso` only ever calls `include('includes/
/// siteconfig_cookies.inc')`, and every `Session_Start` call lives inside
/// that included file. Without following includes, this scanner found
/// precisely zero session_start calls for that entire site, silently
/// disabling session tracking altogether — not a narrow edge case, the
/// standard real-world pattern this whole feature exists to support. Only
/// a *literal string* path argument can be followed (matching this scan's
/// existing "only literal args are visible" limitation for session_start
/// itself) — a dynamically computed include path is invisible here, same
/// as at any other node type this scanner already can't see through.
public enum LassoSessionPreflight {
    public static func scan(
        _ document: LassoDocument,
        includeLoader: (any LassoIncludeLoader)? = nil,
        includePath: String? = nil
    ) -> [LassoSessionStartCall] {
        var found: [LassoSessionStartCall] = []
        var visitedIncludePaths: Set<String> = []
        scan(
            nodes: document.nodes, into: &found,
            includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths
        )
        return found
    }

    private static func scan(
        nodes: [LassoNode], into found: inout [LassoSessionStartCall],
        includeLoader: (any LassoIncludeLoader)?, includePath: String?, visitedIncludePaths: inout Set<String>
    ) {
        for node in nodes {
            switch node {
            case .text:
                break
            case .expression(let expression, _, _, _):
                scan(expression: expression, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
            case .tag(_, let arguments, _, _, _):
                for argument in arguments { scan(expression: argument.value, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths) }
            case .code(let expressions, _, _, _):
                for expression in expressions { scan(expression: expression, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths) }
            case .block(_, let arguments, let body, let alternate, _, _):
                for argument in arguments { scan(expression: argument.value, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths) }
                scan(nodes: body, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
                if let alternate { scan(nodes: alternate, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths) }
            case .typeDefinition(let typeDefinition, _, _):
                for method in typeDefinition.methods { scan(nodes: method.body, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths) }
            }
        }
    }

    private static func scan(
        expression: LassoExpression, into found: inout [LassoSessionStartCall],
        includeLoader: (any LassoIncludeLoader)?, includePath: String?, visitedIncludePaths: inout Set<String>
    ) {
        switch expression {
        case .call(let callee, let arguments):
            if case .identifier(let name) = callee {
                if name.caseInsensitiveCompare("session_start") == .orderedSame,
                   let call = makeCall(from: arguments) {
                    found.append(call)
                }
                if let includeLoader,
                   name.caseInsensitiveCompare("include") == .orderedSame || name.caseInsensitiveCompare("library") == .orderedSame,
                   let path = literalPathArgument(arguments),
                   visitedIncludePaths.contains(path) == false {
                    visitedIncludePaths.insert(path)
                    if let content = try? includeLoader.loadInclude(path: path, from: includePath) {
                        let nestedDocument = LassoParser().parse(content)
                        scan(
                            nodes: nestedDocument.nodes, into: &found,
                            includeLoader: includeLoader, includePath: path, visitedIncludePaths: &visitedIncludePaths
                        )
                    }
                }
            }
            scan(expression: callee, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
            for argument in arguments { scan(expression: argument.value, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths) }
        case .member(let base, _, let arguments):
            scan(expression: base, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
            for argument in arguments ?? [] { scan(expression: argument.value, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths) }
        case .unary(_, let value):
            scan(expression: value, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
        case .binary(let left, _, let right):
            scan(expression: left, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
            scan(expression: right, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
        case .assignment(let target, let value):
            scan(expression: target, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
            scan(expression: value, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
        case .ternary(let condition, let whenTrue, let whenFalse):
            scan(expression: condition, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
            scan(expression: whenTrue, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
            scan(expression: whenFalse, into: &found, includeLoader: includeLoader, includePath: includePath, visitedIncludePaths: &visitedIncludePaths)
        case .string, .integer, .decimal, .boolean, .null, .void, .variable, .identifier, .unknown:
            break
        }
    }

    /// Mirrors `Renderer.renderInclude`/`renderLibrary`'s own path
    /// extraction (`-file=`/`-path=`/first positional), but restricted to
    /// a literal `.string` argument value — this scan works over raw,
    /// unevaluated AST, so a dynamically computed path (a variable, a
    /// concatenation, `action_param(...)`, etc.) can't be resolved here
    /// and is correctly treated as invisible, same as this scan's existing
    /// literal-only limitation for session_start's own arguments.
    private static func literalPathArgument(_ arguments: [LassoArgument]) -> String? {
        func literalString(_ argument: LassoArgument) -> String? {
            if case .string(let value) = argument.value { return value }
            return nil
        }
        if let fileArgument = arguments.first(where: { $0.label?.caseInsensitiveCompare("file") == .orderedSame }) {
            return literalString(fileArgument)
        }
        if let pathArgument = arguments.first(where: { $0.label?.caseInsensitiveCompare("path") == .orderedSame }) {
            return literalString(pathArgument)
        }
        guard let firstPositional = arguments.first(where: { $0.label == nil }) else { return nil }
        return literalString(firstPositional)
    }

    private static func makeCall(from arguments: [LassoArgument]) -> LassoSessionStartCall? {
        // Real corpus overwhelmingly spells the session name as a -Name=
        // keyword argument (session_start(-Name='cart', ...)), not the
        // positional form — see Documentation/outstanding-compatibility-project-plans.md
        // item 7 and SessionArgumentResolution.swift. `stringValue` stays
        // restricted to literal `.string` expressions, preserving this
        // scan's documented "only literal names are visible" limitation
        // (a `-Name=var(x)` still correctly resolves to nil, same as the
        // already-tested positional `session_start(var(x))` case).
        guard let resolved = resolveSessionName(in: arguments, stringValue: { argument in
            if case .string(let value) = argument.value { value } else { nil }
        }) else { return nil }
        let name = resolved.name

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

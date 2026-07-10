import Foundation

/// A single native (Swift-implemented) member method on a `LassoNativeType`.
/// Unlike `LassoMethodDefinition` (a user-defined type's method, whose body
/// is a Lasso AST run by `renderNodes`), a native method's body is ordinary
/// Swift — there's no Lasso source to execute, so it can't go through
/// `LassoMethodDispatcher`. Native members are overwhelmingly name-unique
/// (no real overloading), so a flat name-keyed lookup is sufficient; this
/// intentionally doesn't do the arity/type-constraint scoring
/// `LassoMethodDispatcher` does for user types.
public typealias LassoNativeMethod = @Sendable (
    _ receiver: LassoObjectInstance,
    _ arguments: [EvaluatedArgument],
    _ context: inout LassoContext
) throws -> LassoValue

/// One built-in type's method table — `web_request`, `web_response`,
/// `session`. Mirrors `LassoNativeRegistry`'s register/lookup shape
/// (`Runtime.swift`) deliberately, at the type-method granularity instead
/// of the free-function granularity.
public struct LassoNativeType: Sendable {
    public let name: String
    private var methods: [String: LassoNativeMethod] = [:]

    public init(name: String) {
        self.name = name
    }

    public mutating func register(_ methodName: String, _ method: @escaping LassoNativeMethod) {
        methods[methodName.lowercased()] = method
    }

    func method(named name: String) -> LassoNativeMethod? {
        methods[name.lowercased()]
    }
}

/// Registry of built-in types, populated once at construction (mirroring
/// `LassoNativeRegistry.registerDefaultFunctions`) and read many times
/// during evaluation. A bare identifier that matches a registered name here
/// (and isn't shadowed by a variable or native function) evaluates to a
/// real `.object(LassoObjectInstance(typeName: name))` — see
/// `Evaluator.evaluate(_:)`'s `.identifier` case — so `web_request` etc.
/// are genuine first-class values, not spelling-matched magic strings.
public struct LassoNativeTypeRegistry: Sendable {
    private var types: [String: LassoNativeType] = [:]

    public init(registerDefaults: Bool = true) {
        if registerDefaults { registerDefaultTypes() }
    }

    public mutating func register(_ type: LassoNativeType) {
        types[type.name.lowercased()] = type
    }

    func type(named name: String) -> LassoNativeType? {
        types[name.lowercased()]
    }

    public func containsType(named name: String) -> Bool {
        types[name.lowercased()] != nil
    }

    private mutating func registerDefaultTypes() {
        register(Self.makeWebRequestType())
        register(Self.makeWebResponseType())
        register(Self.makeSessionType())
    }
}

private func firstArgumentString(_ arguments: [EvaluatedArgument]) -> String {
    arguments.first?.value.outputString ?? ""
}

extension LassoNativeTypeRegistry {
    // MARK: - web_request
    //
    // Reference: real Lasso documents ~35 web_request members
    // (Documentation/compatibility-matrix.md). Implemented here: direct
    // header/param/cookie accessors, bulk accessors, request-line/transport
    // metadata backed by `LassoRequestProvider`'s widened surface, and the
    // cheap header-name aliases. `postParam`/`postParams`/`postString`
    // read real application/x-www-form-urlencoded POST data now (see
    // Documentation/post-body-support-plan.md) — Perfect-NIO's own
    // `QueryDecoder` does the parsing, this layer only projects it into
    // Lasso shapes. `param(name, joiner)` uses the ordered `postPairs`/
    // `queryPairs` for real duplicate-name join/array behavior; the plain
    // single-argument form stays dict-based for backward compatibility with
    // every existing conformer. `fileUploads()`/multipart bodies are
    // deferred to session-upload-support-plan.md's upload milestone. The
    // CGI-era fields with no meaning in a standalone Perfect-NIO server
    // (gatewayInterface, scriptFilename, pathTranslated, serverAdmin,
    // serverSignature, serverSoftware) are deliberately not implemented.
    fileprivate static func makeWebRequestType() -> LassoNativeType {
        var type = LassoNativeType(name: "web_request")

        type.register("param") { _, arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ?? firstArgumentString(arguments)
            let joiner = arguments.firstValue(named: "joiner") ?? arguments.dropFirst().first?.value
            guard let joiner else {
                // No joiner requested — plain single-value combined lookup
                // (POST before GET, per real Lasso's documented order).
                // Goes through parameter(named:), a required protocol
                // method every conformer (old dict-based fixtures and new
                // pair-based real providers alike) already implements.
                return context.requestProvider?.parameter(named: name) ?? .void
            }
            // A joiner was explicitly requested — real Lasso's documented
            // duplicate-name behavior needs the ordered, duplicate-
            // preserving pair lists, not the collapsing dictionaries.
            let combined = (context.requestProvider?.postPairs ?? []) + (context.requestProvider?.queryPairs ?? [])
            let matches = combined.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
            guard !matches.isEmpty else { return .void }
            if case .void = joiner { return .array(matches) }
            return .string(matches.map(\.outputString).joined(separator: joiner.outputString))
        }
        type.register("params") { _, _, context in
            .map(context.requestProvider?.parameters ?? [:])
        }
        type.register("header") { _, arguments, context in
            context.requestProvider?.header(named: firstArgumentString(arguments)) ?? .void
        }
        type.register("rawheader") { _, arguments, context in
            context.requestProvider?.header(named: firstArgumentString(arguments)) ?? .void
        }
        type.register("headers") { _, _, context in
            .map(context.requestProvider?.headers ?? [:])
        }
        type.register("cookie") { _, arguments, context in
            context.requestProvider?.cookie(named: firstArgumentString(arguments)) ?? .void
        }
        type.register("cookies") { _, _, context in
            .map(context.requestProvider?.cookies ?? [:])
        }
        type.register("httphost") { _, _, context in
            context.requestProvider?.header(named: "Host") ?? .void
        }

        type.register("queryparam") { _, arguments, context in
            .string((context.requestProvider?.queryParameters ?? [:])[firstArgumentString(arguments).lowercased()]?.outputString ?? "")
        }
        type.register("queryparams") { _, _, context in
            .map(context.requestProvider?.queryParameters ?? [:])
        }
        type.register("querystring") { _, _, context in
            let params = context.requestProvider?.queryParameters ?? [:]
            return .string(params.map { "\($0.key)=\($0.value.outputString)" }.joined(separator: "&"))
        }

        type.register("postparam") { _, arguments, context in
            let name = firstArgumentString(arguments)
            return (context.requestProvider?.postParameters ?? [:])[name.lowercased()] ?? .void
        }
        type.register("postparams") { _, _, context in
            .map(context.requestProvider?.postParameters ?? [:])
        }
        type.register("poststring") { _, _, context in
            .string(context.requestProvider?.rawPostString ?? "")
        }

        type.register("requestmethod") { _, _, context in .string(context.requestProvider?.requestMethod ?? "") }
        type.register("requesturi") { _, _, context in .string(context.requestProvider?.requestURI ?? "") }
        type.register("path") { _, _, context in .string(context.requestProvider?.path ?? "") }
        type.register("ishttps") { _, _, context in .boolean(context.requestProvider?.isHTTPS ?? false) }
        type.register("remoteaddr") { _, _, context in .string(context.requestProvider?.remoteAddress ?? "") }
        type.register("remoteport") { _, _, context in .integer(context.requestProvider?.remotePort ?? 0) }
        type.register("servername") { _, _, context in .string(context.requestProvider?.serverName ?? "") }
        type.register("serverport") { _, _, context in .integer(context.requestProvider?.serverPort ?? 0) }
        type.register("contenttype") { _, _, context in .string(context.requestProvider?.contentType ?? "") }
        type.register("contentlength") { _, _, context in .integer(context.requestProvider?.contentLength ?? 0) }

        // Cheap header-name aliases.
        let headerAliases: [(method: String, header: String)] = [
            ("httpaccept", "Accept"),
            ("httpacceptencoding", "Accept-Encoding"),
            ("httpacceptlanguage", "Accept-Language"),
            ("httpcachecontrol", "Cache-Control"),
            ("httpconnection", "Connection"),
            ("httpreferer", "Referer"),
            ("httpreferrer", "Referer"),
            ("httpuseragent", "User-Agent"),
        ]
        for alias in headerAliases {
            type.register(alias.method) { _, _, context in
                context.requestProvider?.header(named: alias.header) ?? .void
            }
        }

        return type
    }

    // MARK: - web_response
    //
    // Reference: real Lasso documents ~20 web_response members. Implemented
    // here: status, header get/set/bulk, cookie set (full parameter set)/
    // get, and abort. `include*`/`includeBytes`/`includes`/`getInclude`
    // (aliases for the existing include()/library() machinery, which lives
    // in Renderer.swift's renderExpression, not the Evaluator — bridging
    // those is a separate integration), `sendFile`/`sendChunk` (no binary
    // streaming response infrastructure exists), `rawContent`/`rawContent=`
    // (output is one accumulated string built at the very end of
    // rendering — reading/overwriting it mid-render doesn't fit today's
    // architecture), and `addAtEnd`/`define_atBegin`/`define_atEnd`
    // (server-lifecycle hooks, not a per-request concern) are deliberately
    // not implemented.
    fileprivate static func makeWebResponseType() -> LassoNativeType {
        var type = LassoNativeType(name: "web_response")

        type.register("setstatus") { _, arguments, context in
            let status = Int(arguments.first?.value.number ?? 200)
            try context.responseSink?.setStatus(status)
            return .void
        }
        type.register("getstatus") { _, _, context in
            .integer(context.responseSink?.getStatus() ?? 200)
        }

        type.register("header") { _, arguments, context in
            // Response-side header *read* has no dedicated sink accessor —
            // real usage is overwhelmingly write-only (addHeader/
            // replaceHeader/setStatus); return .null rather than fabricate
            // a read path with no backing store.
            _ = arguments
            _ = context
            return .null
        }
        type.register("headers") { _, _, _ in .map([:]) }
        type.register("addheader") { _, arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ?? arguments.first?.value.outputString ?? ""
            let value = arguments.firstValue(named: "value")?.outputString ?? arguments.dropFirst().first?.value.outputString ?? ""
            try context.responseSink?.setHeader(name: name, value: value)
            return .void
        }
        type.register("replaceheader") { _, arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ?? arguments.first?.value.outputString ?? ""
            let value = arguments.firstValue(named: "value")?.outputString ?? arguments.dropFirst().first?.value.outputString ?? ""
            try context.responseSink?.setHeader(name: name, value: value)
            return .void
        }
        type.register("setheaders") { _, arguments, context in
            for argument in arguments {
                guard let label = argument.label else { continue }
                try context.responseSink?.setHeader(name: label, value: argument.value.outputString)
            }
            return .void
        }

        type.register("setcookie") { _, arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ?? arguments.first?.value.outputString ?? ""
            let value = arguments.firstValue(named: "value")?.outputString ?? arguments.dropFirst().first?.value.outputString ?? ""
            try context.responseSink?.setCookie(
                name: name,
                value: value,
                domain: arguments.lastString(named: "domain"),
                expires: arguments.lastString(named: "expires"),
                path: arguments.lastString(named: "path"),
                secure: arguments.hasTruthyFlag("secure"),
                httpOnly: arguments.hasTruthyFlag("httponly")
            )
            return .void
        }
        type.register("cookies") { _, _, _ in .map([:]) }

        type.register("abort") { _, _, context in
            // Rides the existing return-signal short-circuit: every render
            // loop already checks returnSignal after each node and breaks,
            // and LassoRenderer.render already turns an unconsumed signal
            // into page output — no new control-flow mechanism needed.
            context.setReturnSignal(.void)
            return .void
        }

        return type
    }

    // MARK: - session
    //
    // Same two members `nativeMember` already had (`value`/`get`) —
    // relocated here unchanged, not expanded; session's fuller surface is
    // out of scope for this pass.
    fileprivate static func makeSessionType() -> LassoNativeType {
        var type = LassoNativeType(name: "session")
        type.register("value") { _, arguments, context in
            context.sessionProvider?.value(for: firstArgumentString(arguments)) ?? .null
        }
        type.register("get") { _, arguments, context in
            context.sessionProvider?.value(for: firstArgumentString(arguments)) ?? .null
        }
        return type
    }
}

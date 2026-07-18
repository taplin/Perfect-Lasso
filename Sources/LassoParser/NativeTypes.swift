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
) async throws -> LassoValue

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
        register(Self.makeDateType())
        register(Self.makeBytesType())
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
    // every existing conformer. `fileUploads()` reads real multipart
    // uploads now (see Documentation/session-upload-support-plan.md) —
    // Perfect-NIO's own `MimeReader` does the parsing; this layer only
    // projects upload metadata into Lasso 9's documented key names. The
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
        type.register("fileuploads") { _, _, context in
            .array((context.requestProvider?.uploadedFiles ?? []).map { upload in
                .map([
                    "fieldname": .string(upload.fieldName),
                    "contenttype": .string(upload.contentType),
                    "filename": .string(upload.originalFilename),
                    "tmpfilename": .string(upload.temporaryFilename),
                    "filesize": .integer(upload.size),
                ])
            })
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
    // get, abort, include/includeOnce/includeLibrary/includeLibraryOnce/
    // includeBytes/includes (via `LassoContext.includeRenderService` —
    // see `Providers.swift`'s `LassoIncludeRenderService` and
    // `Documentation/web-response-include-plan.md` for the judgment calls
    // involved), and sendFile (string `data` only, per the real documented
    // signature — see the same doc for why path-based serving lives on
    // `file_serve`/`file_stream` instead). `getInclude`, `sendChunk` (no
    // binary streaming response infrastructure exists), `rawContent`/
    // `rawContent=` (output is one accumulated string built at the very
    // end of rendering — reading/overwriting it mid-render doesn't fit
    // today's architecture), and `addAtEnd`/`define_atBegin`/
    // `define_atEnd` (server-lifecycle hooks, not a per-request concern)
    // are deliberately not implemented.
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
            // See CookieHandling.swift — shares the exact fix
            // Runtime.swift's `cookie_set` free-tag registration needed
            // for the same real `'Name'='Value'` labeled-argument syntax.
            guard let (name, value) = LassoCookieArguments.nameAndValue(from: arguments) else {
                return .void
            }
            try context.responseSink?.setCookie(
                name: name,
                value: value,
                domain: arguments.lastString(named: "domain"),
                expires: LassoCookieArguments.httpDateExpires(fromMinutesString: arguments.lastString(named: "expires")),
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

        // Real LP9 convention: one plain positional string, not the
        // legacy -File/-Path keyword form the free `include()`/`library()`
        // tags accept. See LassoIncludeRenderService (Providers.swift) and
        // Documentation/web-response-include-plan.md.
        type.register("include") { _, arguments, context in
            guard let service = context.includeRenderService else {
                throw LassoRuntimeError.includeNotConfigured
            }
            let path = arguments.positionalValue(at: 0)?.outputString ?? ""
            let output = try await service.performInclude(path: path, once: false, context: &context)
            return .string(output ?? "")
        }
        type.register("includeonce") { _, arguments, context in
            guard let service = context.includeRenderService else {
                throw LassoRuntimeError.includeNotConfigured
            }
            let path = arguments.positionalValue(at: 0)?.outputString ?? ""
            guard let output = try await service.performInclude(path: path, once: true, context: &context) else {
                // A repeat call for an already-included path has no
                // confirmed documented return value in either reference
                // source. Defaulting to `.void`, matching
                // includeLibraryOnce's documented "no value" and this
                // codebase's void-on-no-op convention — a judgment call,
                // not a confirmed contract; see the doc above.
                return .void
            }
            return .string(output)
        }
        // includeLibrary re-executes every call (no dedup) — genuinely
        // different from includeLibraryOnce, per the documented contract,
        // and both are distinct from the free-tag `library(...)`'s
        // existing always-deduped ("library_once") behavior.
        type.register("includelibrary") { _, arguments, context in
            guard let service = context.includeRenderService else {
                throw LassoRuntimeError.includeNotConfigured
            }
            let path = arguments.positionalValue(at: 0)?.outputString ?? ""
            try await service.performLibrary(path: path, once: false, context: &context)
            return .void
        }
        type.register("includelibraryonce") { _, arguments, context in
            guard let service = context.includeRenderService else {
                throw LassoRuntimeError.includeNotConfigured
            }
            let path = arguments.positionalValue(at: 0)?.outputString ?? ""
            try await service.performLibrary(path: path, once: true, context: &context)
            return .void
        }
        // LassoGuide 9.3: "a stack of currently executing filenames" — the
        // live nesting stack, needing no new state beyond the existing
        // includeStack. Scope call, flagged: only include/includeOnce push
        // onto includeStack today (library calls never did), so this
        // reflects include-family calls only, not library calls.
        type.register("includes") { _, _, context in
            .array(context.includeStack.map { .string($0) })
        }
        type.register("includebytes") { _, arguments, context in
            guard let loader = context.includeLoader else {
                throw LassoRuntimeError.includeNotConfigured
            }
            let path = arguments.positionalValue(at: 0)?.outputString ?? ""
            let data = try loader.loadIncludeBytes(path: path, from: context.includePath)
            // Lossy UTF-8 decode, never throws — first-pass fallback since
            // no LassoValue case models binary data yet (zero corpus
            // evidence to size one correctly). See
            // Documentation/web-response-include-plan.md.
            return .string(String(decoding: data, as: UTF8.self))
        }

        // `data` is a plain Lasso string value (already-evaluated content,
        // e.g. from includeBytes or a variable) — matches the real
        // documented signature's string-accepting case, not an invented
        // path adaptation; Lasso 8's File_Serve/File_Stream (genuinely
        // path-based) cover real file-serving instead. `-noAbort` is
        // unsupported (always aborts) — this adapter's single-
        // accumulated-response-string architecture has no "serve then
        // keep composing more output" model.
        type.register("sendfile") { _, arguments, context in
            let data = arguments.positionalValue(at: 0)?.outputString ?? ""
            let name = arguments.positionalValue(at: 1)?.outputString ?? arguments.lastString(named: "name")
            let contentType = arguments.lastString(named: "type")
            let disposition = arguments.lastString(named: "disposition") ?? "attachment"
            try context.responseSink?.serveFile(LassoFileServeRequest(
                source: .data(Data(data.utf8)),
                fileName: name,
                contentType: contentType,
                disposition: disposition
            ))
            context.setReturnSignal(.void)
            return .void
        }

        return type
    }

    // MARK: - date
    //
    // See Documentation/date-format-plan.md. A date value is
    // `.object(LassoObjectInstance(typeName: "date"))` storing its six
    // wall-clock components as plain `.integer` fields (see
    // `LassoDateParsing.makeObject`) — `date->format(...)` here calls the
    // exact same `LassoDateFormatting.format` the free-function
    // `Date_Format` native uses, matching the confirmed Lasso 9
    // method-style contract with no separate implementation.
    fileprivate static func makeDateType() -> LassoNativeType {
        var type = LassoNativeType(name: "date")

        type.register("format") { receiver, arguments, _ in
            // A bare `Date` identifier with no call parens (e.g.
            // `Date->format(...)`) resolves to an empty "date" object
            // (nativeTypes.containsType wins before the zero-arg native
            // function call, matching the pre-existing `session` bare-
            // identifier precedent) — falling back to "now" here matches
            // the free-function `date_format` native's identical fallback
            // and Lasso's own bare-`Date` = "now" semantics.
            let components = LassoDateParsing.dateComponents(from: receiver) ?? .now()
            let format = arguments.firstValue(named: "format")?.outputString ?? firstArgumentString(arguments)
            return .string(LassoDateFormatting.format(components, using: format))
        }

        return type
    }

    // MARK: - bytes
    //
    // See BytesType.swift for the storage representation
    // (`LassoBytesValue`, a base64 string stashed in a private-by-
    // convention `_base64` field). Only the three members real corpus
    // actually calls are implemented — decodeBase64/encodeBase64/
    // encodeUrl, always chained straight off a `bytes(value)` constructor
    // call, never off a bare `Bytes` identifier — so unlike `date`, this
    // type has no meaningful "bare identifier" fallback to design for.
    fileprivate static func makeBytesType() -> LassoNativeType {
        var type = LassoNativeType(name: "bytes")

        type.register("decodebase64") { receiver, _, _ in
            // The receiver's own raw bytes ARE the base64 text to decode
            // (interpreted as ASCII/UTF-8) — e.g. `bytes(param)->decodeBase64`
            // treats `param`'s literal characters as a base64 string, not
            // as already-decoded binary.
            let base64Text = LassoBytesValue.string(from: receiver)
            guard let decoded = Data(base64Encoded: base64Text) else {
                return .object(LassoBytesValue.makeObject(rawBytes: []))
            }
            return .object(LassoBytesValue.makeObject(rawBytes: Array(decoded)))
        }
        type.register("encodebase64") { receiver, _, _ in
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let encoded = Data(rawBytes).base64EncodedString()
            return .object(LassoBytesValue.makeObject(rawBytes: Array(encoded.utf8)))
        }
        type.register("encodeurl") { receiver, _, _ in
            let text = LassoBytesValue.string(from: receiver)
            let encoded = LassoEncoding.url(text)
            return .object(LassoBytesValue.makeObject(rawBytes: Array(encoded.utf8)))
        }

        return type
    }

}

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
        register(Self.makeRegExpType())
        register(Self.makeListType())
        register(Self.makeQueueType())
        register(Self.makeStackType())
        register(Self.makeSetType())
        register(Self.makePriorityQueueType())
        register(Self.makeTreeMapType())
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

        // Field accessors (lassoguide.com 9.3 date-duration.html) — the
        // six wall-clock fields were already stored on every `date`
        // object (`LassoDateParsing.makeObject`) but had no way to read
        // any of them back individually; `->format('%Y')`-style string
        // formatting was the only option, forcing every date-comparison/
        // date-math need through string parsing instead of a direct
        // accessor. `->dayOfMonth` is a documented alias for `->day`.
        for (methodName, keyPath) in [
            ("year", \LassoDateComponents.year),
            ("month", \LassoDateComponents.month),
            ("day", \LassoDateComponents.day),
            ("dayofmonth", \LassoDateComponents.day),
            ("hour", \LassoDateComponents.hour),
            ("minute", \LassoDateComponents.minute),
            ("second", \LassoDateComponents.second),
        ] {
            type.register(methodName) { receiver, _, _ in
                .integer((LassoDateParsing.dateComponents(from: receiver) ?? .now())[keyPath: keyPath])
            }
        }
        type.register("dayofweek") { receiver, _, _ in
            // Lasso's own Sunday=1...Saturday=7 numbering — see
            // `LassoDateComponents.weekday`'s own doc comment.
            .integer((LassoDateParsing.dateComponents(from: receiver) ?? .now()).weekday)
        }
        type.register("asinteger") { receiver, _, _ in
            // Epoch seconds — needed for date comparison/sorting/
            // serialization without round-tripping through a string.
            .integer(Int((LassoDateParsing.dateComponents(from: receiver) ?? .now()).asDate.timeIntervalSince1970))
        }

        // `Date->Add`/`Date->Subtract` (Ch. 29 Table 7) — documented as
        // mutating the invocant IN THE CALLING VARIABLE ("do not directly
        // output values, but can be used to change the values of
        // variables that contain date... data types") when called as a
        // bare statement, and joins `Evaluator.selfMutatingMethods` below
        // for exactly that reason.
        //
        // An earlier version of this mutated `receiver`'s own stored
        // fields directly, reasoning that `date` objects are backed by
        // `LassoObjectInstance` (a class — reference semantics) so no
        // write-back mechanism should be needed. That reasoning was
        // wrong and caused a real aliasing bug, caught by testing it
        // directly: `var(d1 = Date(...))` / `var(d2 = $d1)` / `$d1->add(...)`
        // also silently changed `$d2`, because plain assignment in this
        // interpreter copies the `LassoValue.object` ENUM CASE but not
        // the class instance it wraps — both variables end up pointing at
        // the same `LassoObjectInstance`. Real Lasso's own documented
        // model (Language Guide's "References" section) confirms plain
        // assignment is supposed to copy, NOT alias — aliasing is an
        // explicit, opt-in feature (`[Reference]`/`@`), never the default.
        // The fix: never mutate `receiver` at all. Compute a genuinely
        // NEW date object and return it as this method's plain result,
        // exactly like `Array->Insert` already does for `.array` — the
        // mutation-on-bare-statement illusion comes entirely from
        // `Evaluator.evaluateStatement`'s existing write-back mechanism
        // reassigning the CALLING variable to that new object, which
        // never touches whatever other variable(s) still hold the old
        // one. The documented `-Duration=` parameter form isn't supported
        // — this interpreter has no `Duration` type yet (see
        // Documentation/lasso9-lassoguide-gap-analysis-plan.md Section 4)
        // — only the keyword-parameter form (`->Add(-Week=1)`).
        type.register("add") { receiver, arguments, _ in
            let components = LassoDateParsing.dateComponents(from: receiver) ?? .now()
            let delta = LassoDateParsing.dateMathDelta(from: arguments, negate: false)
            return .object(LassoDateParsing.makeObject(components.adding(delta)))
        }
        type.register("subtract") { receiver, arguments, _ in
            let components = LassoDateParsing.dateComponents(from: receiver) ?? .now()
            let delta = LassoDateParsing.dateMathDelta(from: arguments, negate: true)
            return .object(LassoDateParsing.makeObject(components.adding(delta)))
        }

        return type
    }

    // MARK: - bytes
    //
    // See BytesType.swift for the storage representation
    // (`LassoBytesValue`, a base64 string stashed in a private-by-
    // convention `_base64` field). decodeBase64/encodeBase64/encodeUrl
    // were the only three members real corpus actually called at the
    // time `bytes` was first added; this batch adds the next tier of
    // lassoguide.com's documented "Byte Streams" surface (verified
    // directly at http://www.lassoguide.com/operations/byte-streams.html,
    // Lasso 8.5 Language Guide Ch. 27 Table 2 covers the same core
    // inspection/manipulation members under slightly different names —
    // e.g. `->ExportString` where lassoguide.com has both `->ExportString`
    // and the newer `->AsString`) — size/get/getRange/find/contains/
    // beginsWith/endsWith/asString/split/sub (inspection) and
    // append/trim/replace/remove (manipulation, "modify the bytes object
    // without returning a value" per lassoguide.com's own section header
    // — these ride the SAME `Evaluator.selfMutatingMethods` write-back
    // mechanism `Date->Add` already established for `.object` types;
    // "append"/"trim"/"replace"/"remove" are already in that set from
    // String's own additions, so no change needed there) and
    // encodeHex/decodeHex. Still open, deliberately deferred (a long
    // tail with no real-corpus evidence yet, matching how this project
    // has scoped every prior native-type expansion): removeLeading/
    // removeTrailing/padLeading/padTrailing, setSize/setRange,
    // marker/position/setPosition, export*bits/import*bits (binary
    // integer packing), swapBytes, crc, encodeMd5/encodeQP/decodeQP/
    // encodeSql/encodeSql92/decodeUrl, bestCharset/detectCharset, and
    // forEachByte/eachByte (both need Captures — this project's still-
    // unimplemented block/closure primitive).
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
        type.register("size") { receiver, _, _ in
            .integer(LassoBytesValue.rawBytes(from: receiver).count)
        }
        type.register("get") { receiver, arguments, _ in
            // "Returns a single byte from the stream" as an INTEGER, not a
            // string/bytes fragment — confirmed by the doc's own worked
            // example (`bytes('hello world')->get(2) => 101`, the ASCII
            // code for 'e', the 1-based 2nd character). Out-of-range isn't
            // covered by any worked example; degrades to 0 rather than
            // throwing, matching this codebase's established "missing/
            // invalid argument degrades gracefully" convention elsewhere.
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let position = (arguments.positionalValue(at: 0)?.number).map(Int.init) ?? 0
            let index = position - 1
            guard rawBytes.indices.contains(index) else { return .integer(0) }
            return .integer(Int(rawBytes[index]))
        }
        type.register("getrange") { receiver, arguments, _ in
            // Both parameters are required per lassoguide.com's own
            // signature (`getRange(position::integer, num::integer)`,
            // no `=?` on `num`) — unlike `->sub` below, which makes `num`
            // optional.
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let position = (arguments.positionalValue(at: 0)?.number).map(Int.init) ?? 0
            let count = (arguments.positionalValue(at: 1)?.number).map(Int.init) ?? 0
            let startIndex = max(0, position - 1)
            guard startIndex < rawBytes.count, count > 0 else {
                return .object(LassoBytesValue.makeObject(rawBytes: []))
            }
            let endIndex = min(rawBytes.count, startIndex + count)
            return .object(LassoBytesValue.makeObject(rawBytes: Array(rawBytes[startIndex..<endIndex])))
        }
        type.register("find") { receiver, arguments, _ in
            // "Returns the position where the sequence first begins... or
            // '0' if the pattern cannot be found" — 1-based, matching this
            // codebase's established `String->Find` convention. Only the
            // single required `find` parameter is implemented; the four
            // additional optional position/length-limit parameters
            // lassoguide.com documents (searching a sub-range of either
            // the instance or the pattern) have no worked example and are
            // out of scope here, mirroring how `String->Compare`'s
            // substring-offset overload was similarly deferred.
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let needle = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            guard !needle.isEmpty, let range = firstRange(of: needle, in: rawBytes) else { return .integer(0) }
            return .integer(range.lowerBound + 1)
        }
        type.register("contains") { receiver, arguments, _ in
            // Implemented against this method's own written description
            // ("Returns 'true' if the byte stream contains the specified
            // sequence") rather than the page's own worked example under
            // this heading — that example actually calls `->find` (not
            // `->contains`) and expects `false` as output, which doesn't
            // even match `->find`'s own documented integer-or-zero return
            // type. Confirmed copy-paste artifact from the `->find`
            // section directly above it on the same page, the same class
            // of documentation defect this project has repeatedly found
            // and deliberately not followed (Math_Div, String->Compare,
            // String_ReplaceRegExp).
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let needle = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            return .boolean(!needle.isEmpty && firstRange(of: needle, in: rawBytes) != nil)
        }
        type.register("beginswith") { receiver, arguments, _ in
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let needle = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            return .boolean(!needle.isEmpty && rawBytes.starts(with: needle))
        }
        type.register("endswith") { receiver, arguments, _ in
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let needle = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            return .boolean(!needle.isEmpty && rawBytes.count >= needle.count && Array(rawBytes.suffix(needle.count)) == needle)
        }
        type.register("asstring") { receiver, arguments, _ in
            // "Returns the entire byte stream as a string using the
            // specified encoding, defaulting to 'UTF-8'." Only UTF-8 and
            // ISO-8859-1 are mapped — a new, first-instance scope
            // decision (no other encoding-name-mapping precedent exists
            // elsewhere in this codebase); an unrecognized encoding name
            // falls back to UTF-8 rather than throwing.
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let encodingName = arguments.positionalValue(at: 0)?.outputString ?? "UTF-8"
            let encoding: String.Encoding = encodingName.caseInsensitiveCompare("ISO-8859-1") == .orderedSame
                ? .isoLatin1 : .utf8
            return .string(String(data: Data(rawBytes), encoding: encoding) ?? String(decoding: rawBytes, as: UTF8.self))
        }
        type.register("split") { receiver, arguments, _ in
            // "If the delimiter provided is an empty byte stream or
            // string, the byte stream is split on each byte" — matches
            // `String->Split`'s own analogous empty-delimiter handling.
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let delimiter = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            if delimiter.isEmpty {
                return .array(rawBytes.map { .object(LassoBytesValue.makeObject(rawBytes: [$0])) })
            }
            var segments: [LassoValue] = []
            var remaining = rawBytes[...]
            while let range = firstRange(of: delimiter, in: Array(remaining)) {
                let absoluteStart = remaining.startIndex + range.lowerBound
                let absoluteEnd = remaining.startIndex + range.upperBound
                segments.append(.object(LassoBytesValue.makeObject(rawBytes: Array(remaining[remaining.startIndex..<absoluteStart]))))
                remaining = remaining[absoluteEnd...]
            }
            segments.append(.object(LassoBytesValue.makeObject(rawBytes: Array(remaining))))
            return .array(segments)
        }
        type.register("sub") { receiver, arguments, _ in
            // 1-based; `num` optional — "all of the bytes following the
            // index are returned" when omitted, unlike `->getRange` above.
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let position = (arguments.positionalValue(at: 0)?.number).map(Int.init) ?? 0
            let startIndex = max(0, position - 1)
            guard startIndex < rawBytes.count else {
                return .object(LassoBytesValue.makeObject(rawBytes: []))
            }
            let endIndex = arguments.positionalValue(at: 1)?.number.map { min(rawBytes.count, startIndex + Int($0)) } ?? rawBytes.count
            guard endIndex > startIndex else {
                return .object(LassoBytesValue.makeObject(rawBytes: []))
            }
            return .object(LassoBytesValue.makeObject(rawBytes: Array(rawBytes[startIndex..<endIndex])))
        }
        type.register("append") { receiver, arguments, _ in
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let addition = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            return .object(LassoBytesValue.makeObject(rawBytes: rawBytes + addition))
        }
        type.register("trim") { receiver, _, _ in
            // "Removes all whitespace ASCII characters from the beginning
            // and the end" — ASCII whitespace only (space/tab/newline/
            // CR/etc., codes <= 0x20's whitespace set plus 0x7F is NOT
            // whitespace), not a general Unicode-whitespace notion, since
            // this is raw binary data, not text.
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            func isAsciiWhitespace(_ byte: UInt8) -> Bool {
                byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
            }
            var start = 0
            var end = rawBytes.count
            while start < end, isAsciiWhitespace(rawBytes[start]) { start += 1 }
            while end > start, isAsciiWhitespace(rawBytes[end - 1]) { end -= 1 }
            return .object(LassoBytesValue.makeObject(rawBytes: Array(rawBytes[start..<end])))
        }
        type.register("replace") { receiver, arguments, _ in
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let find = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            let replacement = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 1) ?? .string(""))
            guard !find.isEmpty else { return .object(LassoBytesValue.makeObject(rawBytes: rawBytes)) }
            var result: [UInt8] = []
            var remaining = rawBytes[...]
            while let range = firstRange(of: find, in: Array(remaining)) {
                let absoluteStart = remaining.startIndex + range.lowerBound
                let absoluteEnd = remaining.startIndex + range.upperBound
                result.append(contentsOf: remaining[remaining.startIndex..<absoluteStart])
                result.append(contentsOf: replacement)
                remaining = remaining[absoluteEnd...]
            }
            result.append(contentsOf: remaining)
            return .object(LassoBytesValue.makeObject(rawBytes: result))
        }
        type.register("remove") { receiver, arguments, _ in
            // No-arg form: "removes all bytes, setting the object to an
            // empty bytes object." Two-arg form: an offset + count range.
            // A one-arg call is not a documented valid form at all; it
            // falls through the two-arg path with `count` defaulting to
            // 0, so the `count > 0` guard below fails and the original
            // bytes are returned unchanged — graceful degradation
            // consistent with this type's other defaults, not a
            // documented behavior.
            guard let position = arguments.positionalValue(at: 0)?.number.map(Int.init) else {
                return .object(LassoBytesValue.makeObject(rawBytes: []))
            }
            let rawBytes = LassoBytesValue.rawBytes(from: receiver)
            let count = arguments.positionalValue(at: 1)?.number.map(Int.init) ?? 0
            let startIndex = max(0, position - 1)
            guard startIndex < rawBytes.count, count > 0 else {
                return .object(LassoBytesValue.makeObject(rawBytes: rawBytes))
            }
            let endIndex = min(rawBytes.count, startIndex + count)
            var result = rawBytes
            result.removeSubrange(startIndex..<endIndex)
            return .object(LassoBytesValue.makeObject(rawBytes: result))
        }
        type.register("encodehex") { receiver, _, _ in
            let hex = LassoBytesValue.rawBytes(from: receiver).map { String(format: "%02x", $0) }.joined()
            return .object(LassoBytesValue.makeObject(rawBytes: Array(hex.utf8)))
        }
        type.register("decodehex") { receiver, _, _ in
            // "Converting each pair of characters to a single byte" — an
            // odd-length or non-hex input degrades to skipping the
            // unparseable trailing/invalid byte rather than throwing,
            // matching this type's other graceful-degradation defaults.
            let hexText = LassoBytesValue.string(from: receiver)
            var decoded: [UInt8] = []
            var iterator = hexText.makeIterator()
            while let high = iterator.next() {
                guard let low = iterator.next(),
                      let byte = UInt8(String([high, low]), radix: 16) else { break }
                decoded.append(byte)
            }
            return .object(LassoBytesValue.makeObject(rawBytes: decoded))
        }

        return type
    }

    // MARK: - regexp
    //
    // See RegularExpressions.swift for the `NSRegularExpression`-backed
    // implementation. Stored fields ("find"/"replace"/"input"/
    // "ignorecase") mirror `RegExp`'s constructor keywords (Ch. 26 Table 7)
    // exactly. `->FindPattern`/`->ReplacePattern`/`->Input`/`->IgnoreCase`
    // are documented as getter/setter (a parameter sets a new value) —
    // deliberately implemented here as READ-ONLY getters that ignore any
    // argument, not setters. Real Lasso `date` objects taught this
    // codebase a real lesson (see `Date->Add`'s own doc comment above,
    // and the aliasing bug that fix resolved): a setter that mutates
    // `receiver`'s stored fields directly would corrupt any OTHER
    // variable referencing the same shared `LassoObjectInstance` after a
    // plain assignment, since assignment here copies the `LassoValue`
    // enum case but not the class instance it wraps. A correct setter
    // needs the same build-a-new-instance + `selfMutatingMethods` write-
    // back treatment `Date->Add`/`->Subtract` use — deferred to a
    // follow-up along with Table 10's interactive tags, which depend on
    // genuinely mutable per-call state (`->Find` advancing a match
    // position) in a way the convenience tags below don't.
    fileprivate static func makeRegExpType() -> LassoNativeType {
        var type = LassoNativeType(name: "regexp")

        type.register("findpattern") { receiver, _, _ in .string(regexpStringField("find", receiver)) }
        type.register("replacepattern") { receiver, _, _ in .string(regexpStringField("replace", receiver)) }
        type.register("input") { receiver, _, _ in .string(regexpStringField("input", receiver)) }
        type.register("ignorecase") { receiver, _, _ in receiver.value(for: "ignorecase") }
        type.register("groupcount") { receiver, _, _ in
            let regex = LassoRegularExpressions.makeRegex(pattern: regexpStringField("find", receiver), ignoreCase: false)
            return .integer(regex?.numberOfCaptureGroups ?? 0)
        }
        type.register("replaceall") { receiver, arguments, _ in
            let pattern = arguments.lastString(named: "find") ?? regexpStringField("find", receiver)
            let replacement = arguments.lastString(named: "replace") ?? regexpStringField("replace", receiver)
            let input = arguments.lastString(named: "input") ?? regexpStringField("input", receiver)
            let ignoreCase = receiver.value(for: "ignorecase").isTruthy
            return .string(LassoRegularExpressions.replaceAll(
                in: input, pattern: pattern, replacement: replacement, ignoreCase: ignoreCase
            ))
        }
        type.register("replacefirst") { receiver, arguments, _ in
            let pattern = arguments.lastString(named: "find") ?? regexpStringField("find", receiver)
            let replacement = arguments.lastString(named: "replace") ?? regexpStringField("replace", receiver)
            let input = arguments.lastString(named: "input") ?? regexpStringField("input", receiver)
            let ignoreCase = receiver.value(for: "ignorecase").isTruthy
            return .string(LassoRegularExpressions.replaceFirst(
                in: input, pattern: pattern, replacement: replacement, ignoreCase: ignoreCase
            ))
        }
        type.register("split") { receiver, arguments, _ in
            let pattern = arguments.lastString(named: "find") ?? regexpStringField("find", receiver)
            let input = arguments.lastString(named: "input") ?? regexpStringField("input", receiver)
            let ignoreCase = receiver.value(for: "ignorecase").isTruthy
            return .array(LassoRegularExpressions.split(input, pattern: pattern, ignoreCase: ignoreCase))
        }

        return type
    }
}

/// Reads one of a `regexp` object's stored string fields — a top-level
/// function (not a local closure) so it can be captured by the
/// `@Sendable` `type.register(...)` closures above without a
/// Sendable-capture compile error (the same fix already applied to
/// `isEveryCharacter` in Runtime.swift).
private func regexpStringField(_ name: String, _ receiver: LassoObjectInstance) -> String {
    receiver.value(for: name).outputString
}

/// The index range of the first occurrence of `needle` within
/// `haystack`, or `nil` if it doesn't occur — a top-level function (not
/// a local closure) for the same Sendable-capture-avoidance reason as
/// `regexpStringField` above, used by `bytes->find`/`->contains`/
/// `->split`/`->replace`.
private func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    for start in 0...(haystack.count - needle.count) {
        if Array(haystack[start..<(start + needle.count)]) == needle {
            return start..<(start + needle.count)
        }
    }
    return nil
}

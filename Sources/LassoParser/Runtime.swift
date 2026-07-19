import Foundation

public indirect enum LassoValue: Equatable, Sendable {
    case void
    case null
    case boolean(Bool)
    case integer(Int)
    case decimal(Double)
    case string(String)
    case array([LassoValue])
    case map([String: LassoValue])
    case object(LassoObjectInstance)
    /// A real Lasso 9 `Pair` — the value produced by a bare `key = value`
    /// expression appearing somewhere OTHER than an assignment-target
    /// position (an assignment target is a name/`::type`/member-access
    /// shape `assign(_:to:defaultScope:)` recognizes; anything else in
    /// that position, e.g. `field('scrubs_sku') = $temp_array`, is a Pair
    /// literal instead). Real corpus: includes/detail_a_sku.lasso's
    /// `$skuArrayItem->insert(field('scrubs_sku') = $temp_array)`, read
    /// back via `->second` (includes/detail_by_color.lasso).
    case pair(LassoValue, LassoValue)

    public var isTruthy: Bool {
        switch self {
        case .void, .null: false
        case let .boolean(value): value
        case let .integer(value): value != 0
        case let .decimal(value): value != 0
        case let .string(value): !value.isEmpty && value.lowercased() != "false"
        case let .array(value): !value.isEmpty
        case let .map(value): !value.isEmpty
        case .object: true
        case .pair: true
        }
    }

    public var outputString: String {
        switch self {
        case .void, .null: ""
        case let .boolean(value): value ? "true" : "false"
        case let .integer(value): String(value)
        case let .decimal(value): String(value)
        case let .string(value): value
        case let .array(value): value.map(\.outputString).joined()
        case let .map(value): String(describing: value)
        case let .object(value):
            // `bytes` is the one native type whose bare output is
            // meaningful content, not a type-name placeholder (matching
            // real Lasso's auto-stringification of a byte stream) — every
            // other native type (web_request/web_response/date) has no
            // documented bare-output contract, so they keep the existing
            // type-name fallback.
            value.typeName == LassoBytesValue.typeName ? LassoBytesValue.string(from: value) : value.typeName
        case let .pair(key, value): "\(key.outputString) = \(value.outputString)"
        }
    }

    var number: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .decimal(value): value
        case let .string(value): Double(value)
        default: nil
        }
    }

    var typeName: String {
        switch self {
        case .void: "void"
        case .null: "null"
        case .boolean: "boolean"
        case .integer: "integer"
        case .decimal: "decimal"
        case .string: "string"
        case .array: "array"
        case .map: "map"
        case let .object(value): value.typeName
        case .pair: "pair"
        }
    }
}

public struct EvaluatedArgument: Equatable, Sendable {
    public let label: String?
    public let value: LassoValue

    public init(label: String?, value: LassoValue) {
        self.label = label
        self.value = value
    }
}

public typealias LassoNativeFunction = @Sendable (
    _ arguments: [EvaluatedArgument],
    _ context: inout LassoContext
) async throws -> LassoValue

public struct LassoNativeRegistry: Sendable {
    private var functions: [String: LassoNativeFunction] = [:]

    public init(registerDefaults: Bool = true) {
        if registerDefaults { registerDefaultFunctions() }
    }

    public mutating func register(_ name: String, function: @escaping LassoNativeFunction) {
        functions[name.lowercased()] = function
    }

    public func contains(_ name: String) -> Bool {
        functions[name.lowercased()] != nil
    }

    func function(named name: String) -> LassoNativeFunction? {
        functions[name.lowercased()]
    }

    private mutating func registerDefaultFunctions() {
        register("string") { arguments, _ in
            // Real corpus: includes/detail_a_sku.lasso's
            // `var(sku = string($skuArrayItem->first))`, immediately
            // followed by `$sku->second->get:1` — real Lasso's `string()`
            // type-cast passes a `Pair` through unconverted (there's no
            // sensible flattened string form that would keep `->second`
            // meaningful), rather than forcing it through `outputString`.
            if case let .pair(key, value)? = arguments.first?.value {
                return .pair(key, value)
            }
            return .string(arguments.first?.value.outputString ?? "")
        }
        register("integer") { arguments, _ in
            .integer(Int(arguments.first?.value.number ?? 0))
        }
        // `bytes(...)` constructor — see BytesType.swift. Real corpus never
        // uses the integer-size-allocation or PDF-conversion constructor
        // forms lassoguide.com documents, only the string and
        // bytes-object-copy forms, so only those are implemented.
        register("bytes") { arguments, _ in
            guard let first = arguments.first?.value else {
                return .object(LassoBytesValue.makeObject(rawBytes: []))
            }
            if case let .object(existing) = first, existing.typeName == LassoBytesValue.typeName {
                return .object(LassoBytesValue.makeObject(rawBytes: LassoBytesValue.rawBytes(from: existing)))
            }
            return .object(LassoBytesValue.makeObject(rawBytes: Array(first.outputString.utf8)))
        }
        register("decimal") { arguments, _ in
            .decimal(arguments.first?.value.number ?? 0)
        }
        register("var_defined") { arguments, context in
            let name = arguments.first?.value.outputString ?? ""
            switch context.value(for: name) {
            case .void, .null: return .boolean(false)
            default: return .boolean(true)
            }
        }
        register("local_defined") { arguments, context in
            let name = arguments.first?.value.outputString ?? ""
            switch context.value(for: name, scope: .local) {
            case .void, .null: return .boolean(false)
            default: return .boolean(true)
            }
        }
        let tagExists: LassoNativeFunction = { arguments, context in
            let name = arguments.first?.value.outputString ?? ""
            guard name.isEmpty == false else { return .boolean(false) }
            return .boolean(context.natives.contains(name) || context.tagRegistry.containsTag(named: name))
        }
        register("lasso_tagexists", function: tagExists)
        register("tag_exists", function: tagExists)
        register("encode_html") { arguments, _ in
            let value = arguments.first?.value.outputString ?? ""
            return .string(value.htmlEncoded)
        }
        register("encode_smart") { arguments, _ in
            .string(LassoEncoding.smart(arguments.first?.value.outputString ?? ""))
        }
        register("encode_break") { arguments, _ in
            .string(LassoEncoding.breakEncoded(arguments.first?.value.outputString ?? ""))
        }
        register("encode_xml") { arguments, _ in
            .string(LassoEncoding.xml(arguments.first?.value.outputString ?? ""))
        }
        register("encode_url") { arguments, _ in
            .string(LassoEncoding.url(arguments.first?.value.outputString ?? ""))
        }
        register("encode_stricturl") { arguments, _ in
            .string(LassoEncoding.strictURL(arguments.first?.value.outputString ?? ""))
        }
        register("encode_sql") { arguments, _ in
            .string(LassoEncoding.sql(arguments.first?.value.outputString ?? ""))
        }
        register("encode_base64") { arguments, _ in
            .string(LassoEncoding.base64(arguments.first?.value.outputString ?? ""))
        }
        register("decode_base64") { arguments, _ in
            guard let decoded = LassoEncoding.decodeBase64(arguments.first?.value.outputString ?? "") else {
                return .void
            }
            return .string(decoded)
        }
        // Encrypt_HMAC — LassoGuide 9.3 operations/encryption.html. Real
        // corpus usage (password-reset token generation) is always
        // -Digest='sha1' -Base64. -Cram (a distinct CRAM-hex format) has
        // zero corpus evidence and its exact byte layout isn't confirmed
        // against the local Lasso 8.5 reference — deferred, same as this
        // project's other zero-evidence documented siblings (see
        // Date_Format's deferred flags). With none of -Base64/-Hex/-Cram
        // given, the real tag returns raw bytes; this adapter's
        // LassoValue has no bytes case (the same known limitation
        // Decode_Base64 already lives with), so that path lossily decodes
        // as UTF-8 rather than crashing — low-stakes since real usage is
        // always -Base64.
        register("encrypt_hmac") { arguments, _ in
            // -Password/-Token are documented as required PARAMETERS — the
            // real tag must be called with both specified — but real Lasso
            // does NOT require their VALUES to be non-empty: an explicit
            // empty string is a valid, well-defined input (the HMAC of an
            // empty message), and real Lasso Server computes it rather
            // than erroring. Confirmed live 2026-07-18: a real site's
            // login-check include unconditionally calls this with an
            // empty -Token on every unauthenticated non-login request
            // (Encrypt_HMAC(-token = $password, ...) where $password is
            // '' outside a login attempt) and does not error on a real
            // Lasso site. An earlier version of this guard incorrectly
            // conflated "argument omitted" with "argument present but
            // empty," rejecting both — only the former is actually
            // invalid. `lastString(named:)` already draws this exact
            // distinction: nil means the argument wasn't supplied at all,
            // vs. Optional("") for an explicitly-empty value.
            guard let password = arguments.lastString(named: "password") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 3001,
                    message: "Encrypt_HMAC requires -Password.",
                    kind: "encryption"
                ))
            }
            guard let token = arguments.lastString(named: "token") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 3002,
                    message: "Encrypt_HMAC requires -Token.",
                    kind: "encryption"
                ))
            }
            let digest = arguments.lastString(named: "digest") ?? "MD5"
            let raw = LassoHashing.hmac(password: password, token: token, digest: digest)
            if arguments.hasTruthyFlag("base64") {
                return .string(raw.base64EncodedString())
            }
            if arguments.hasTruthyFlag("hex") {
                return .string("0x" + raw.map { String(format: "%02x", $0) }.joined())
            }
            return .string(String(decoding: raw, as: UTF8.self))
        }
        // [Currency]/[Percent] — Lasso 8.5 Chapter 28 "Math Operations",
        // Table 13. Positional (not -flag=) language/country parameters,
        // matching the documented signature exactly. See
        // Documentation/outstanding-compatibility-project-plans.md and
        // NumberFormatting.swift.
        register("currency") { arguments, _ in
            .string(LassoNumberFormatting.format(
                arguments.positionalValue(at: 0)?.number ?? 0,
                style: .currency,
                language: arguments.positionalValue(at: 1)?.outputString ?? "en",
                country: arguments.positionalValue(at: 2)?.outputString ?? "US"
            ))
        }
        register("percent") { arguments, _ in
            .string(LassoNumberFormatting.format(
                arguments.positionalValue(at: 0)?.number ?? 0,
                style: .percent,
                language: arguments.positionalValue(at: 1)?.outputString ?? "en",
                country: arguments.positionalValue(at: 2)?.outputString ?? "US"
            ))
        }
        // Date and time — Lasso 8.5 Language Guide Chapter 29 "Date and
        // Time Operations". See Documentation/date-format-plan.md for the
        // native "date" object representation and the DateFormatter/ICU
        // rendering approach.
        register("date") { arguments, _ in
            // -Year/-Month/-Day/-Hour/-Minute/-Second construction keywords
            // (Chapter 29 Table 1) take priority when present — cheap to
            // support alongside string parsing, same DateComponents
            // plumbing.
            if arguments.lastInt(named: "year") != nil || arguments.lastInt(named: "month") != nil || arguments.lastInt(named: "day") != nil {
                var components = LassoDateComponents.now()
                if let year = arguments.lastInt(named: "year") { components.year = year }
                if let month = arguments.lastInt(named: "month") { components.month = month }
                if let day = arguments.lastInt(named: "day") { components.day = day }
                if let hour = arguments.lastInt(named: "hour") { components.hour = hour }
                if let minute = arguments.lastInt(named: "minute") { components.minute = minute }
                if let second = arguments.lastInt(named: "second") { components.second = second }
                return .object(LassoDateParsing.makeObject(components))
            }
            guard let positional = arguments.positionalValue(at: 0) else {
                return .object(LassoDateParsing.makeObject(.now()))
            }
            let explicitFormat = arguments.lastString(named: "format")
            let parsed = LassoDateParsing.parse(positional, explicitFormat: explicitFormat) ?? .now()
            return .object(LassoDateParsing.makeObject(parsed))
        }
        register("date_format") { arguments, _ in
            let positional = arguments.positionalValue(at: 0) ?? .void
            let format = arguments.lastString(named: "format") ?? ""
            let components = LassoDateParsing.parse(positional) ?? .now()
            return .string(LassoDateFormatting.format(components, using: format))
        }
        register("date_localtogmt") { arguments, _ in
            let positional = arguments.positionalValue(at: 0) ?? .void
            var components = LassoDateParsing.parse(positional) ?? .now()
            let date = components.asDate.addingTimeInterval(-Double(TimeZone.current.secondsFromGMT()))
            components = LassoDateComponents(date: date)
            return .object(LassoDateParsing.makeObject(components))
        }
        register("date_gmttolocal") { arguments, _ in
            let positional = arguments.positionalValue(at: 0) ?? .void
            var components = LassoDateParsing.parse(positional) ?? .now()
            let date = components.asDate.addingTimeInterval(Double(TimeZone.current.secondsFromGMT()))
            components = LassoDateComponents(date: date)
            return .object(LassoDateParsing.makeObject(components))
        }
        register("server_date") { _, _ in
            .object(LassoDateParsing.makeObject(.now()))
        }
        // [Output]/Output(...) — Lasso 8.5 Language Guide Chapter 14
        // "Table 1: Output Tags": applies an encoding to any expression,
        // member tag, or sub-tag result. Default -EncodeHTML, matching
        // Chapter 17 "Encoding Rules" ("Substitution Tags which output a
        // value to the site visitor have a default encoding of
        // -EncodeHTML"), overridable by an explicit -Encode* keyword or by
        // an enclosing [Encode_Set] scope. See
        // Documentation/output-tags-plan.md.
        register("output") { arguments, context in
            let value = arguments.first?.value.outputString ?? ""
            let keyword = LassoEncoding.keyword(in: arguments) ?? context.currentEncodingOverride ?? "html"
            return .string(LassoEncoding.apply(keyword, to: value))
        }
        register("map") { arguments, _ in
            var values: [String: LassoValue] = [:]
            for argument in arguments {
                if let label = argument.label {
                    values[label.lowercased()] = argument.value
                }
            }
            return .map(values)
        }
        register("array") { arguments, _ in
            .array(arguments.map { $0.value })
        }
        // Real Lasso's Pair constructor (LassoGuide, "Collections"):
        // pair() -> both null; pair(anotherPair) -> copies first/second;
        // pair(value, value) -> two positional elements; pair(value=value)
        // -> the key-value/named-assignment form. Real corpus:
        // includes/efs_process.lasso's `Pair('x_Login'=#x_login)` and 20+
        // sibling calls building a gateway POST param array -- previously
        // unregistered entirely, so every one of those calls threw
        // unknownFunction("Pair") immediately, well before the page ever
        // reached its own real (separate, still-unimplemented) gap around
        // include_url.
        register("pair") { arguments, _ in
            guard let first = arguments.first else { return .pair(.null, .null) }
            if let label = first.label {
                return .pair(.string(label), first.value)
            }
            if arguments.count == 1, case let .pair(a, b) = first.value {
                return .pair(a, b)
            }
            let second = arguments.count > 1 ? arguments[1].value : .null
            return .pair(first.value, second)
        }
        // Real Lasso 9's `set` (an ordered, unique-valued collection) —
        // real corpus: includes/detail_a_sku.lasso's
        // `var('skuArrayColor' = set)` followed by
        // `$skuArrayColor->insert(field('color'))`, building "a special
        // 'color' array that contains every color/print found" (per that
        // file's own comment) across a loop of skus, several sharing the
        // same color. Modeled as a plain `.array` for now — real `set`
        // additionally skips inserting a value already present, which
        // this doesn't reproduce (a real gap: the resulting color list
        // can contain duplicates this way), but an unrecognized bare
        // `set` identifier previously evaluated to `.void`, so
        // `->insert` threw outright and the whole page failed to render.
        register("set") { arguments, _ in
            .array(arguments.map { $0.value })
        }
        register("json_serialize") { arguments, _ in
            let value = arguments.first?.value ?? .null
            let object = value.jsonObject
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let string = String(data: data, encoding: .utf8) else {
                return .string("null")
            }
            return .string(string)
        }
        register("valid_email") { arguments, _ in
            let email = arguments.positionalValue(at: 0)?.outputString ?? ""
            let domains: [String]?
            if let domainList = arguments.lastString(named: "domain") {
                domains = domainList.split(separator: ",").map(String.init)
            } else if arguments.hasTruthyFlag("standarddomains") {
                domains = LassoValidation.standardDomains
            } else {
                domains = nil
            }
            return .boolean(LassoValidation.isValidEmail(
                email,
                hostName: arguments.lastString(named: "hostname"),
                domains: domains
            ))
        }
        register("valid_creditcard") { arguments, _ in
            .boolean(LassoValidation.isValidCreditCard(arguments.positionalValue(at: 0)?.outputString ?? ""))
        }
        register("log_critical") { arguments, context in
            if let sink = context.diagnosticLogSink {
                let message = arguments.first?.value.outputString ?? ""
                await sink(message)
            }
            return .void
        }
        register("return") { arguments, context in
            context.setReturnSignal(arguments.first?.value ?? .void)
            return .void
        }
        // Break/continue for the nearest enclosing loop/while/iterate/
        // records/with block — see `LassoContext.loopControlSignal` and
        // each block case in `RendererEngine.renderBlock`. A call outside
        // any loop is simply a no-op: the signal is set, but nothing in
        // the enclosing `render(_:)` chain ever consumes it before the
        // page finishes, so it has no observable effect (matching this
        // codebase's existing "unrecognized/inapplicable construct is a
        // no-op, not fatal" convention elsewhere).
        register("loop_abort") { _, context in
            context.setLoopAbortSignal()
            return .void
        }
        register("loop_continue") { _, context in
            context.setLoopContinueSignal()
            return .void
        }
        register("field") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.currentRow?[name] ??
                context.currentInlineFrame?.rows.first?[name] ??
                .null
        }
        register("column") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.currentRow?[name] ??
                context.currentInlineFrame?.rows.first?[name] ??
                .null
        }
        // KeyField_Value — real Lasso's current-record key value, distinct
        // from field()/column() (which only read named columns): a
        // FileMaker record's key is always the out-of-band internal
        // record ID, never a named field in the result set itself. Real
        // corpus round-trips this directly into a later -KeyValue
        // argument (`-KeyValue=(KeyField_Value)`) for -Update/-Delete —
        // see LassoDataRow.keyValue and Documentation/lasso-perfect-server.md.
        register("keyfield_value") { _, context in
            context.currentRow?.keyValue ??
                context.currentInlineFrame?.rows.first?.keyValue ??
                .null
        }
        register("found_count") { _, context in
            .integer(context.currentInlineFrame?.foundCount ?? 0)
        }
        register("record_count") { _, context in
            .integer(context.currentInlineFrame?.rows.count ?? 0)
        }
        register("affected_count") { _, context in
            .integer(context.currentInlineFrame?.affectedRows ?? 0)
        }
        register("action_statement") { _, context in
            .string(context.currentInlineFrame?.actionStatement ?? "")
        }
        register("error_currenterror") { arguments, context in
            arguments.hasTruthyFlag("errorcode")
                ? .integer(context.currentError.code)
                : .string(context.currentError.message)
        }
        register("action_param") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.requestProvider?.parameter(named: name) ?? .void
        }
        // Real Lasso's action_params(): every submitted name/value pair as
        // an ordered array, POST before GET (same precedence as
        // action_param's own combined lookup) -- unlike the dictionary-
        // shaped parameter(named:) above, this preserves duplicate names
        // and ordering, since real corpus code (e.g.
        // includes/send_debug_email.include.lasso) walks it with
        // ->size/->get(n)->first/->second to log every submitted param.
        register("action_params") { _, context in
            let pairs = (context.requestProvider?.postPairs ?? []) + (context.requestProvider?.queryPairs ?? [])
            return .array(pairs.map { .pair(.string($0.name), $0.value) })
        }
        // Real Lasso 8's bare `server_name` global tag — same underlying
        // value `web_request->serverName` already exposes
        // (NativeTypes.swift), just also reachable without the
        // `web_request->` prefix, matching real corpus usage (e.g.
        // components/koi_setup.inc's `if(server_name >> 'www2' ...)`
        // environment-detection chain). Previously unregistered
        // entirely — a bare `server_name` fell through to
        // `context.value(for: "server_name")`, an ordinary (always
        // empty/undeclared) variable lookup, so every one of that
        // chain's conditions silently compared against "".
        register("server_name") { _, context in
            .string(context.requestProvider?.serverName ?? "")
        }
        // Lasso 8 request tags — see Documentation/post-body-support-plan.md.
        // `form_param` is documented as equivalent to the modern combined
        // `action_param` lookup (POST before GET). The `client_*` tags map
        // directly onto the widened LassoRequestProvider surface.
        register("form_param") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.requestProvider?.parameter(named: name) ?? .void
        }
        register("client_postargs") { _, context in
            .map(context.requestProvider?.postParameters ?? [:])
        }
        register("client_postparams") { _, context in
            .map(context.requestProvider?.postParameters ?? [:])
        }
        register("client_getargs") { _, context in
            .map(context.requestProvider?.queryParameters ?? [:])
        }
        register("client_getparams") { _, context in
            .map(context.requestProvider?.queryParameters ?? [:])
        }
        register("client_contentlength") { _, context in
            .integer(context.requestProvider?.contentLength ?? 0)
        }
        register("client_contenttype") { _, context in
            .string(context.requestProvider?.contentType ?? "")
        }
        register("client_formmethod") { _, context in
            .string(context.requestProvider?.requestMethod ?? "")
        }
        // Lasso 8's [File_Uploads] — see
        // Documentation/session-upload-support-plan.md. Projects the same
        // upload metadata web_request->fileUploads() exposes, but under
        // Lasso 8's own documented key names. OrigPath has no real
        // equivalent (browsers only ever send a bare filename, never a
        // client-side path) — approximated with the filename itself, same
        // as OrigName, rather than fabricating a fake path.
        register("file_uploads") { _, context in
            .array((context.requestProvider?.uploadedFiles ?? []).map { upload in
                let ext = (upload.originalFilename as NSString).pathExtension
                return .map([
                    "path": .string(upload.temporaryFilename),
                    "file": .string(upload.temporaryFilename),
                    "size": .integer(upload.size),
                    "type": .string(upload.contentType),
                    "param": .string(upload.fieldName),
                    "origname": .string(upload.originalFilename),
                    "origpath": .string(upload.originalFilename),
                    "origextension": .string(ext),
                ])
            })
        }
        register("file_processuploads") { arguments, context in
            guard let destination = arguments.lastString(named: "destination"), destination.isEmpty == false else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 2001,
                    message: "File_ProcessUploads requires -Destination.",
                    kind: "file"
                ))
            }
            guard let uploadProcessor = context.uploadProcessor else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 2002,
                    message: "File_ProcessUploads is not configured.",
                    kind: "file"
                ))
            }

            let options = LassoUploadProcessingOptions(
                destination: destination,
                useTempNames: arguments.hasTruthyFlag("usetempnames"),
                allowOverwrite: arguments.hasTruthyFlag("fileoverwrite"),
                maxSize: arguments.lastInt(named: "size"),
                allowedExtensions: lassoUploadExtensions(from: arguments.lastValue(named: "extensions"))
            )
            do {
                _ = try uploadProcessor.processUploads(context.requestProvider?.uploadedFiles ?? [], options: options)
                return .void
            } catch let error as LassoRecoverableError {
                throw error
            } catch {
                throw LassoRecoverableError(LassoErrorState(
                    code: 2003,
                    message: "File_ProcessUploads failed.",
                    kind: "file",
                    detail: String(describing: error)
                ))
            }
        }
        // Lasso 8, genuinely path-based (unlike web_response->sendFile,
        // which takes already-evaluated string data). Implemented as
        // aliases of one identical registration — no confirmed documented
        // behavioral distinction found between File_Serve and File_Stream
        // for this adapter's purposes. Deliberately root-confined, for
        // consistency with every other filesystem-touching feature in this
        // adapter (uploads, includes) — a considered divergence from real
        // Lasso 8's very likely unconfined posture; no escape hatch this
        // pass. The path is handed to the response sink unresolved; actual
        // existence/root-confinement/ETag/Range handling happens at the
        // server boundary via the same fileURL(for:)/FileOutput every
        // other static-asset request already uses (LassoPerfectServer's
        // LassoSiteServer.render) — a missing file surfaces there as a
        // genuine HTTP 404, not a [protect]-catchable recoverable error,
        // since by the time that check runs the page has already aborted
        // via returnSignal and there's no page left for [protect] to catch
        // anything on. See Documentation/web-response-include-plan.md.
        let fileServeHandler: LassoNativeFunction = { arguments, context in
            let path = arguments.lastString(named: "file") ??
                arguments.lastString(named: "path") ??
                arguments.first?.value.outputString ?? ""
            try context.responseSink?.serveFile(LassoFileServeRequest(
                source: .path(path),
                contentType: arguments.lastString(named: "type")
            ))
            context.setReturnSignal(.void)
            return .void
        }
        register("file_serve", function: fileServeHandler)
        register("file_stream", function: fileServeHandler)

        register("cookie") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.requestProvider?.cookie(named: name) ?? .void
        }
        // Real session semantics: sessions are NAMED (session_start(name,
        // ...)), and session_addVar(sessionName, varName) registers an
        // existing thread/local variable for end-of-request persistence —
        // it does not take a value directly. session_start creates/resumes
        // the real session (against PerfectSessionCore, via
        // LassoSessionProvider.start — see LassoPerfectSession) directly,
        // in place, right here — not via a parse-time preflight scan; see
        // LassoSessionProvider's 2026-07-18 doc comment for why. See also
        // Documentation/session-upload-support-plan.md.
        register("session_start") { arguments, context in
            guard let call = makeSessionStartCall(from: arguments) else { return .void }
            if let result = await context.sessionProvider?.start(session: call.name, call: call) {
                context.sessionStartResults[call.name.lowercased()] = result
                // Real Lasso restores every variable ever added to this
                // session the moment session_start runs — session_addVar
                // does not need to be re-called on each page for a name
                // already added on an earlier one. See
                // LassoSessionProvider.restoredVariables's doc comment.
                for (varName, value) in context.sessionProvider?.restoredVariables(session: call.name) ?? [:] {
                    context.set(value, for: varName, scope: .global)
                    if context.trackedSessionVariables.contains(where: { $0.session == call.name && $0.varName == varName }) == false {
                        context.trackedSessionVariables.append((session: call.name, varName: varName))
                    }
                }
            }
            return .void
        }
        register("session_id") { arguments, context in
            guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else { return .void }
            return context.sessionProvider?.id(session: resolved.name).map(LassoValue.string) ?? .void
        }
        register("session_result") { arguments, context in
            guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else { return .void }
            guard let result = context.sessionStartResults[resolved.name.lowercased()] else { return .void }
            return .map([
                "id": .string(result.sessionID),
                "new": .boolean(result.isNew),
            ])
        }
        register("session_addvar") { arguments, context in
            guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else { return .void }
            let name = resolved.name
            let varName = resolved.remainingPositional.first?.value.outputString ?? ""
            guard varName.isEmpty == false else { return .void }
            context.trackedSessionVariables.append((session: name, varName: varName))
            if let restored = context.sessionProvider?.restoredValue(for: varName, session: name) {
                context.set(restored, for: varName, scope: .global)
            }
            return .void
        }
        register("session_removevar") { arguments, context in
            guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else { return .void }
            let name = resolved.name
            let varName = resolved.remainingPositional.first?.value.outputString ?? ""
            context.sessionProvider?.removeVar(varName, session: name)
            context.trackedSessionVariables.removeAll { $0.session == name && $0.varName == varName }
            return .void
        }
        register("session_end") { arguments, context in
            guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else { return .void }
            context.sessionProvider?.end(session: resolved.name)
            context.suppressedSessionSaves.insert(resolved.name)
            return .void
        }
        register("session_abort") { arguments, context in
            guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else { return .void }
            context.sessionProvider?.abort(session: resolved.name)
            context.suppressedSessionSaves.insert(resolved.name)
            return .void
        }
        // Real Lasso 8's [Cache(-Name=..., -Expires=...)] ... [/Cache]
        // wraps a body of markup to memoize for a duration — a
        // performance layer, not a correctness one. This interpreter has
        // no output-caching layer at all (every render is already
        // computed fresh), so treating the opening call as a no-op is
        // exactly equivalent: the wrapped body still renders normally as
        // ordinary template text/nodes, just never cached. The matching
        // `[/Cache]` close needs no handling of its own — it's already
        // covered by the existing generic legacy-closing-tag support.
        register("cache") { _, _ in .void }
        // [Email_Send] (Lasso 8.5 Language Guide, "Process Tags"): a
        // process tag — "does not return a value" per its own doc — that
        // queues/sends a real email via SMTP (-Host/-To/-From/-Subject/
        // -Body etc.). This project has no resurrected SMTP client, so a
        // real send isn't possible; real corpus usage (importscripts/*.lasso,
        // `email_send: -to=..., -from=..., -subject=..., -body=...;`) is
        // itself only reached on already-degraded/error paths (import
        // failure notifications), never on the success path a real user
        // hits. Registered as a no-op, matching the [Cache] precedent
        // above — clears unknownFunction("email_send") and lets the
        // surrounding page finish rendering, without pretending to
        // deliver mail that never actually goes anywhere.
        register("email_send") { _, _ in .void }
        register("redirect_url") { arguments, context in
            let url = arguments.firstValue(named: "url")?.outputString ??
                arguments.first?.value.outputString ?? ""
            try context.responseSink?.redirect(to: url)
            return .void
        }
        register("response_status") { arguments, context in
            let status = Int(arguments.first?.value.number ?? 200)
            try context.responseSink?.setStatus(status)
            return .void
        }
        register("cookie_set") { arguments, context in
            // See CookieHandling.swift — real Lasso's
            // `Cookie_Set('Name'='Value', -Domain=..., ...)` passes name/
            // value as a single labeled argument, not `-Name=`/`-Value=`.
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
    }
}

extension LassoValue {
    public var jsonObject: Any {
        switch self {
        case .void, .null:
            NSNull()
        case let .boolean(value):
            value
        case let .integer(value):
            value
        case let .decimal(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map(\.jsonObject)
        case let .map(values):
            Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value.jsonObject) })
        case let .object(value):
            value.snapshotData().mapValues(\.jsonObject)
        case let .pair(key, value):
            ["first": key.jsonObject, "second": value.jsonObject]
        }
    }

    /// Reverses `jsonObject` — used to restore session variables persisted
    /// as JSON-safe values (see `Documentation/session-upload-support-plan.md`'s
    /// "Variable strategy": string, integer, decimal, boolean, arrays, maps,
    /// null/void). Only used for values this adapter itself wrote; a driver
    /// storing something else is out of scope.
    public static func from(json value: Any) -> LassoValue {
        switch value {
        case is NSNull:
            .null
        case let value as Bool:
            .boolean(value)
        case let value as Int:
            .integer(value)
        case let value as Double:
            .decimal(value)
        case let value as String:
            .string(value)
        case let value as [Any]:
            .array(value.map(LassoValue.from(json:)))
        case let value as [String: Any]:
            .map(value.mapValues(LassoValue.from(json:)))
        default:
            .null
        }
    }
}

extension String {
    var htmlEncoded: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// `Loop_Abort()`/`Loop_Continue()` — Lasso's break/continue. See
/// `LassoContext.loopControlSignal`.
enum LoopControlSignal: Sendable, Equatable {
    case abort
    case continueIteration
}

public struct LassoContext: Sendable {
    private var globals: [String: LassoValue]
    private var locals: [String: LassoValue]
    private var inlineFrames: [ActiveInlineFrame]
    public var natives: LassoNativeRegistry
    public var nativeTypes: LassoNativeTypeRegistry
    public var includeLoader: (any LassoIncludeLoader)?
    public var includePath: String?
    public var includeStack: [String]
    /// Where the first (deepest) render error surfaced — a source-level
    /// complement to `includeStack`, which every enclosing
    /// `performInclude`/`performLibrary` frame's own `defer` pops back to
    /// empty as a genuine error unwinds, leaving nothing for a caller to
    /// read once `LassoRenderer.render` has returned. These two fields
    /// are set once (guarded by `lastErrorLocation == nil`) at the
    /// deepest point an error is caught in `RendererEngine.render(_:)`,
    /// then never touched again — no `defer` clears them, so they survive
    /// intact all the way to the top-level caller via `inout` write-back,
    /// which happens even when the function exits by throwing. See
    /// `Documentation/lasso-perfect-server.md`'s error-page section.
    public var lastErrorLocation: SourceRange?
    public var lastErrorIncludeStack: [String]?
    /// Tag-open-form recognition counts accumulated across this request's
    /// whole render — the top-level document's own fires, plus every
    /// include's/library's, folded in as each is parsed (Phase 3 of
    /// tag-form consolidation). A plain per-request dictionary, not a
    /// store: survives `inout` write-back the same way `lastErrorLocation`
    /// does (including on a mid-render throw), and is merged into the
    /// shared, cross-request `TagOpenFormCounterStore` exactly once, at the
    /// request boundary, only on a successful render.
    public var openFormFires: [TagOpenFormFire: Int]
    /// Wired imperatively by whichever call site constructs both a
    /// `RendererEngine`/`Evaluator` and a `LassoContext` together — same
    /// convention as `Evaluator.renderNodes`, not a public initializer
    /// parameter. Lets `web_response->include`/`includeLibrary` (evaluator-
    /// level native methods, which only see this context, not an
    /// `Evaluator`) trigger a full node render. See
    /// `LassoIncludeRenderService` in `Providers.swift`.
    public var includeRenderService: (any LassoIncludeRenderService)?
    /// Paths already processed by `web_response->includeOnce` this
    /// request's render. Deliberately separate from `loadedLibraries` so
    /// an `include` path and a `library` path sharing a string don't
    /// cross-suppress each other.
    var includedOncePaths: Set<String>
    public var requestProvider: (any LassoRequestProvider)?
    public var uploadProcessor: (any LassoUploadProcessor)?
    public var sessionProvider: (any LassoSessionProvider)?
    public var responseSink: (any LassoResponseSink)?
    public var inlineProvider: (any LassoInlineProvider)?
    /// Called by `log_critical` with its message text — a hook for the
    /// host application to surface these into its own logging.
    /// `LassoParser` has no direct I/O of its own (same convention as
    /// `requestProvider`/`responseSink`); `nil` (the default) makes
    /// `log_critical` a no-op, matching its behavior before this hook
    /// existed, for callers that don't wire anything.
    public var diagnosticLogSink: (@Sendable (String) async -> Void)?
    public var tagRegistry: LassoTagRegistry
    /// Paths already processed by `library()` for THIS request's render —
    /// deliberately per-`LassoContext`, not on the shared `tagRegistry`.
    /// LassoSoft's `library_once` docs scope the "only the first call does
    /// anything" dedup to a single page's own render, not the server
    /// process's lifetime.
    var loadedLibraries: Set<String>
    /// Cycle/depth guard for `performLibrary`, independent of
    /// `includeStack` (which stays include-family-only, matching
    /// `includes()`'s documented scope) and independent of
    /// `loadedLibraries` (which only guards the `once: true` path).
    /// `includeLibrary`'s `once: false` call has no dedup to fall back on,
    /// so without this a self- or mutually-recursive `includeLibrary`
    /// chain would recurse through native Swift calls unboundedly and
    /// crash the process — this bounds it the same way `includeStack`
    /// already bounds `include`.
    var libraryStack: [String]
    var returnSignal: LassoValue?
    /// Set by `Loop_Abort()`/`Loop_Continue()`, consumed by the nearest
    /// enclosing loop/while/iterate/records/with block right after each
    /// iteration's `render(body)` call returns — mirrors `returnSignal`'s
    /// set/short-circuit pattern (checked in `RendererEngine.render(_:)`
    /// alongside `returnSignal` so it also unwinds through any nested
    /// blocks between the call site and the enclosing loop) but is scoped
    /// to just that one loop rather than the whole page, matching
    /// break/continue semantics: a loop nested inside another loop
    /// consumes its own abort/continue signal and never lets it reach the
    /// outer loop. See `loopDepth` and `shouldStopRenderingCurrentBody()`
    /// for how a signal with NO enclosing loop at all is handled.
    var loopControlSignal: LoopControlSignal?
    /// Count of loop-shaped blocks (`loop`/`while`/`iterate`/`records`/
    /// `with`) currently on the render call stack — incremented for the
    /// duration of each one's own body render, decremented after. Lets
    /// `shouldStopRenderingCurrentBody()` distinguish "a `Loop_Abort()`
    /// that some enclosing loop still needs to consume" (`loopDepth > 0`,
    /// so the current node list should stop early and let that unwind
    /// happen) from "a stray call with no loop left to catch it at all"
    /// (`loopDepth == 0`), which is otherwise indistinguishable from the
    /// first case purely by looking at `loopControlSignal` in isolation.
    /// Saved, reset to `0`, and restored around every custom-tag/member-
    /// method call (`Evaluator.invokeCustomTag`/`invokeMemberMethod`) —
    /// a call boundary starts a fresh scope with no loop of its own yet,
    /// exactly like `snapshotLocals()`/`replaceLocals(_:)` already do for
    /// `#locals`, so a stray abort inside a called tag's own body can't
    /// be mistaken for "some enclosing loop out there wants this" just
    /// because the *caller* happened to be inside one.
    var loopDepth: Int
    var tagCallStack: [String]
    var selfStack: [LassoObjectInstance]
    /// Real Lasso's request-local `error_currentError` state — reset to
    /// `.noError` on every fresh context, updated by `setError`/`clearError`.
    /// `lastError` preserves the previous error across a `clearError()` call,
    /// matching how `protect` needs to inspect what failed even after the
    /// catch handler has already reset `currentError` for code that follows.
    public var currentError: LassoErrorState
    public var lastError: LassoErrorState?
    /// `(sessionName, varName)` pairs registered via `session_addVar` this
    /// request — read back by `finalizeSessions()` at the very end of
    /// render so the persisted value reflects whatever the page last set
    /// it to, not just its value at registration time.
    var trackedSessionVariables: [(session: String, varName: String)]
    /// Sessions `session_abort`/`session_end` was called on this request —
    /// `finalizeSessions()` skips persisting tracked variables for these,
    /// matching the documented "prevents saving" behavior.
    var suppressedSessionSaves: Set<String>
    /// The most recent `session_start` result per session name, so
    /// `session_result` can report it without re-consulting the provider.
    var sessionStartResults: [String: LassoSessionStartResult]
    /// `[Encode_Set: -EncodeXxx] ... [/Encode_Set]` pushes here; `Output`
    /// (with no explicit encoding keyword of its own) consults the top of
    /// this stack instead of the -EncodeHTML default. See
    /// `Documentation/output-tags-plan.md`.
    var encodingOverrideStack: [String]

    public init(
        globals: [String: LassoValue] = [:],
        locals: [String: LassoValue] = [:],
        natives: LassoNativeRegistry = LassoNativeRegistry(),
        nativeTypes: LassoNativeTypeRegistry = LassoNativeTypeRegistry(),
        includeLoader: (any LassoIncludeLoader)? = nil,
        includePath: String? = nil,
        requestProvider: (any LassoRequestProvider)? = nil,
        uploadProcessor: (any LassoUploadProcessor)? = nil,
        sessionProvider: (any LassoSessionProvider)? = nil,
        responseSink: (any LassoResponseSink)? = nil,
        inlineProvider: (any LassoInlineProvider)? = nil,
        diagnosticLogSink: (@Sendable (String) async -> Void)? = nil,
        tagRegistry: LassoTagRegistry = LassoTagRegistry()
    ) {
        self.globals = Dictionary(uniqueKeysWithValues: globals.map { ($0.key.lowercased(), $0.value) })
        self.locals = Dictionary(uniqueKeysWithValues: locals.map { ($0.key.lowercased(), $0.value) })
        inlineFrames = []
        self.natives = natives
        self.nativeTypes = nativeTypes
        self.includeLoader = includeLoader
        self.includePath = includePath
        includeStack = []
        lastErrorLocation = nil
        lastErrorIncludeStack = nil
        openFormFires = [:]
        includeRenderService = nil
        includedOncePaths = []
        self.requestProvider = requestProvider
        self.uploadProcessor = uploadProcessor
        self.sessionProvider = sessionProvider
        self.responseSink = responseSink
        self.inlineProvider = inlineProvider
        self.diagnosticLogSink = diagnosticLogSink
        self.tagRegistry = tagRegistry
        loadedLibraries = []
        libraryStack = []
        returnSignal = nil
        loopControlSignal = nil
        loopDepth = 0
        tagCallStack = []
        selfStack = []
        currentError = .noError
        lastError = nil
        trackedSessionVariables = []
        suppressedSessionSaves = []
        sessionStartResults = [:]
        encodingOverrideStack = []
    }

    public mutating func setError(_ error: LassoErrorState) {
        lastError = currentError
        currentError = error
    }

    public mutating func clearError() {
        lastError = currentError
        currentError = .noError
    }

    /// Called once, at the very end of a page's render (`LassoRenderer`),
    /// so tracked session variables persist their final value rather than
    /// whatever they held at `session_addVar` time.
    mutating func finalizeSessions() {
        guard let sessionProvider else {
            trackedSessionVariables = []
            return
        }
        for tracked in trackedSessionVariables where suppressedSessionSaves.contains(tracked.session) == false {
            sessionProvider.persist(value(for: tracked.varName), for: tracked.varName, session: tracked.session)
        }
        trackedSessionVariables = []
    }

    public subscript(_ name: String) -> LassoValue {
        get { locals[name.lowercased()] ?? globals[name.lowercased()] ?? .null }
        set { globals[name.lowercased()] = newValue }
    }

    public mutating func set(_ value: LassoValue, for name: String, scope: VariableScope) {
        switch scope {
        case .local: locals[name.lowercased()] = value
        case .global, .unscoped: globals[name.lowercased()] = value
        }
    }

    public func value(for name: String, scope: VariableScope = .unscoped) -> LassoValue {
        switch scope {
        case .local: locals[name.lowercased()] ?? .null
        case .global: globals[name.lowercased()] ?? .null
        case .unscoped: locals[name.lowercased()] ?? globals[name.lowercased()] ?? .null
        }
    }

    public var currentInlineFrame: LassoInlineFrame? {
        inlineFrames.last?.frame
    }

    var currentEncodingOverride: String? {
        encodingOverrideStack.last
    }

    public var currentRow: LassoDataRow? {
        inlineFrames.last?.currentRow
    }

    mutating func pushInlineFrame(_ frame: LassoInlineFrame) {
        inlineFrames.append(ActiveInlineFrame(frame: frame, currentRow: nil))
        // A successful inline sets currentError back to No Error; a failed
        // database action (once inline executors start constructing frames
        // with real error state) sets it to the action's own error — matching
        // real Lasso's request-local error_currentError, inspectable from
        // inside the inline body per the documented
        // [Error_CurrentError: -ErrorCode]: [Error_CurrentError] pattern.
        setError(frame.error)
    }

    mutating func popInlineFrame() {
        _ = inlineFrames.popLast()
    }

    mutating func setCurrentRow(_ row: LassoDataRow?) {
        guard !inlineFrames.isEmpty else { return }
        inlineFrames[inlineFrames.count - 1].currentRow = row
    }

    mutating func setReturnSignal(_ value: LassoValue) {
        returnSignal = value
    }

    mutating func consumeReturnSignal() -> LassoValue? {
        defer { returnSignal = nil }
        return returnSignal
    }

    mutating func clearReturnSignal() {
        returnSignal = nil
    }

    mutating func setLoopAbortSignal() {
        loopControlSignal = .abort
    }

    mutating func setLoopContinueSignal() {
        loopControlSignal = .continueIteration
    }

    /// Called by the enclosing loop block right after each iteration's
    /// `render(body)` returns. Returns `true` (having cleared the signal)
    /// only for `.abort`, so the caller knows to stop iterating entirely;
    /// a `.continueIteration` signal is cleared here too but reported as
    /// "not abort" since that case just lets the enclosing `for`/`while`
    /// proceed to its next iteration normally.
    mutating func consumeLoopControlSignal() -> Bool {
        defer { loopControlSignal = nil }
        return loopControlSignal == .abort
    }

    /// The single early-exit check `RendererEngine.render(_:)` runs after
    /// every node — `return`/`abort()` always stops (regardless of loop
    /// nesting; that's how `LassoRenderer.render` picks up its value at
    /// the very top). A `Loop_Abort`/`Loop_Continue` signal only stops
    /// the current node list if `loopDepth > 0`, i.e. some enclosing
    /// loop-shaped block is still on the render stack and will consume
    /// it via `consumeLoopControlSignal()`. A signal set with NO
    /// enclosing loop at all (`loopDepth == 0`) is discarded right here
    /// instead of being allowed to persist unconsumed — otherwise a
    /// stray call earlier on the page (or inside a tag body with no loop
    /// of its own) would sit in `loopControlSignal` until some
    /// completely unrelated LATER loop's `consumeLoopControlSignal()`
    /// call mistakenly treated it as an abort request meant for it.
    mutating func shouldStopRenderingCurrentBody() -> Bool {
        if returnSignal != nil { return true }
        guard loopControlSignal != nil else { return false }
        if loopDepth > 0 { return true }
        loopControlSignal = nil
        return false
    }

    func snapshotLocals() -> [String: LassoValue] {
        locals
    }

    mutating func replaceLocals(_ newLocals: [String: LassoValue]) {
        locals = newLocals
    }

    var currentSelf: LassoObjectInstance? {
        selfStack.last
    }

    mutating func pushSelf(_ object: LassoObjectInstance) {
        selfStack.append(object)
    }

    mutating func popSelf() {
        _ = selfStack.popLast()
    }

    // Each level of Lasso-level tag recursion costs several real Swift
    // stack frames (the renderNodes closure, a fresh RendererEngine, the
    // Evaluator call chain), not one — confirmed empirically: 100 levels
    // overflowed the C stack outright in a constrained-stack execution
    // context (an XCTest worker thread) before this guard's own check ever
    // got a chance to fire. Kept low enough to have real margin rather than
    // being maximally permissive.
    private static let maximumTagCallDepth = 20

    mutating func pushTagCall(_ name: String) throws {
        guard tagCallStack.count < Self.maximumTagCallDepth else {
            throw LassoRuntimeError.tagCallDepthExceeded
        }
        tagCallStack.append(name)
    }

    mutating func popTagCall() {
        _ = tagCallStack.popLast()
    }
}

public extension Array where Element == EvaluatedArgument {
    func firstValue(named name: String) -> LassoValue? {
        first { $0.label?.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func lastValue(named name: String) -> LassoValue? {
        last { $0.label?.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func strings(named name: String) -> [String] {
        filter { $0.label?.caseInsensitiveCompare(name) == .orderedSame }
            .map { $0.value.outputString }
    }

    func lastString(named name: String) -> String? {
        lastValue(named: name)?.outputString
    }

    func lastInt(named name: String) -> Int? {
        lastValue(named: name).flatMap { value in
            value.number.map(Int.init)
        }
    }

    func hasTruthyFlag(_ name: String) -> Bool {
        contains { argument in
            argument.label?.caseInsensitiveCompare(name) == .orderedSame && argument.value.isTruthy
        }
    }

    /// The `index`th unlabeled (positional) argument's value, ignoring any
    /// `-flag=value` arguments interspersed among them.
    func positionalValue(at index: Int) -> LassoValue? {
        let unlabeled = filter { $0.label == nil }
        guard unlabeled.indices.contains(index) else { return nil }
        return unlabeled[index].value
    }
}

private func lassoUploadExtensions(from value: LassoValue?) -> Set<String>? {
    guard let value else { return nil }
    let rawValues: [String]
    switch value {
    case .array(let values):
        rawValues = values.map(\.outputString)
    default:
        rawValues = value.outputString.components(separatedBy: ",")
    }
    let extensions = rawValues
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        .filter { $0.isEmpty == false }
        .map { $0.lowercased() }
    return extensions.isEmpty ? nil : Set(extensions)
}

public enum LassoRuntimeError: Error, Equatable {
    case unknownFunction(String)
    case unsupportedExpression(String)
    case invalidAssignment
    case includeNotConfigured
    case includeCycle(String)
    case includeDepthExceeded
    case inlineNotConfigured
    case tagCallDepthExceeded
    case unsafeDynamicFieldName(String)
}

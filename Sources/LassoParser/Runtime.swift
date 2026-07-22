import Foundation

/// Shared by the `String_Is*` free-tag family below — a top-level
/// function (not a local closure) so it can be captured by the
/// `@Sendable` `register(...)` closures without a Sendable-capture error.
private func isEveryCharacter(_ text: String, _ predicate: (Character) -> Bool) -> Bool {
    !text.isEmpty && text.allSatisfy(predicate)
}

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
    /// A Lasso 9 Capture — see `Captures.swift`'s own doc comment for the
    /// full design (real live-reference closure semantics as of Stage 3).
    case capture(LassoCaptureValue)

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
        case .capture: true
        }
    }

    public var outputString: String {
        switch self {
        case .void, .null: ""
        case let .boolean(value): value ? "true" : "false"
        case let .integer(value): String(value)
        // Real Lasso's documented default: "The precision of a decimal
        // value when converted to a string is always displayed as six
        // decimal places" (lassoguide.com Math chapter, "Creating
        // Decimal Objects") -- this governs `string()`, bracket output,
        // and `+` string concatenation, all of which route through this
        // property. Swift's raw `String(Double)` instead prints the
        // shortest round-trippable representation, leaking IEEE-754
        // binary-fraction noise straight through for any value not
        // exactly representable in binary -- almost every two-decimal
        // money amount (`string(0.1 + 0.2)` produced
        // `"0.30000000000000004"`, not the six-place `"0.300000"` real
        // Lasso guarantees). Found live: FileMaker's own CR_web
        // order_grandtotal field, after round-tripping through ordinary
        // Lasso arithmetic (subtotal + tax + shipping - discount),
        // carried exactly this kind of raw-noise value, which then
        // leaked through this exact case into a payment gateway's
        // amount field.
        case let .decimal(value): String(format: "%.6f", value)
        case let .string(value): value
        case let .array(value): value.map(\.outputString).joined()
        case let .map(value): String(describing: value)
        case let .object(value):
            // `bytes` is one native type whose bare output is meaningful
            // content, not a type-name placeholder (matching real
            // Lasso's auto-stringification of a byte stream). List/
            // Queue/Stack/Set are a second such group — Ch. 30's own
            // worked examples show a documented "TypeName: elem1, elem2"
            // auto-stringification (see `LassoCollectionValue
            // .autoStringDescription`'s own doc comment for citations).
            // Every other native type (web_request/web_response/date)
            // has no documented bare-output contract, so they keep the
            // existing type-name fallback.
            if value.typeName == LassoBytesValue.typeName {
                LassoBytesValue.string(from: value)
            } else if LassoCollectionValue.typeNames.contains(value.typeName) {
                LassoCollectionValue.autoStringDescription(for: value)
            } else if value.typeName == LassoTreeMapValue.typeName {
                // Ch. 30 p.418's own worked example: `(TreeMap: (1)=
                // (Sunday), (2)=(Monday), ...)` — a distinct "(key)=
                // (value)" pair format, not the flat comma-joined shape
                // the other collection types use.
                LassoTreeMapValue.autoStringDescription(for: value)
            } else {
                value.typeName
            }
        case let .pair(key, value):
            // Ch. 30 p.404's own worked example (`[Variable: 'Test_Pair']`
            // on `(Pair: 'First_Name'='John')`) → `(Pair: (First_Name)=
            // (John))` — the outer `(...)` wrap is that specific
            // bare-display tag's own formatting (not reproduced here,
            // matching this codebase's established treatment of the
            // same outer-wrap quirk on `TreeMap`'s own worked example —
            // see `LassoTreeMapValue.autoStringDescription`'s doc
            // comment), but the inner `(key)=(value)` shape — no
            // surrounding spaces, each half parenthesized — is Pair's
            // own genuine auto-stringification contract. Previously
            // `"\(key) = \(value)"` (spaces, no parens) with no
            // primary-source citation at all — found and fixed while
            // reading Ch. 30's Pair section for Stage 4's `->First=`/
            // `->Second=` work.
            "(\(key.outputString))=(\(value.outputString))"
        case .capture:
            // No documented bare-output contract found for a capture
            // value (unlike `bytes`/List/Set/etc.'s own worked examples)
            // — falls back to its type name, matching this codebase's
            // existing convention for every other native type with no
            // such contract (date/web_request/web_response, see the
            // `.object` case's own doc comment just above).
            "capture"
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
        case .capture: "capture"
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
        // `null(expr)` / `[Null: expr]` (Ch. 30 pp.422-426's canonical
        // Iterator idiom, e.g. `Null: $myIterator->Forward;`) — evaluates
        // its argument for side effects but suppresses the output. By the
        // time this closure runs, `arguments` is already evaluated (see
        // the `.call` case in Evaluator.evaluate), so simply discarding
        // the result and returning `.void` is sufficient.
        register("null") { _, _ in .void }
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
        // `[Global_Defined]`/`[Global_Remove]`/`[Globals]` (Ch. 15 Table
        // 3) — the read/write `[Global]`/`[Global_Reset]` tags are
        // special-cased alongside `Var`/`Local` in `Evaluator.evaluate`
        // (see `declarationScope(for:)`) since, like them, they need
        // assignment-target-aware argument handling a plain
        // evaluated-arguments free function can't provide.
        register("global_defined") { arguments, context in
            .boolean(context.trueGlobalDefined(arguments.first?.value.outputString ?? ""))
        }
        register("global_remove") { arguments, context in
            context.removeTrueGlobal(arguments.first?.value.outputString ?? "")
            return .void
        }
        register("globals") { _, context in
            .map(context.trueGlobalsSnapshot())
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
        // `Encrypt_MD5`/`Cipher_Digest`/`Cipher_Encrypt`/`Cipher_Decrypt`/
        // `Cipher_List` — lassoguide.com `operations/encryption.html`.
        // See `Hashing.swift`'s own doc comments for exactly which
        // algorithms are supported and why (swift-crypto's real,
        // available surface — not real Lasso's much larger OpenSSL-
        // backed list) and the AES-GCM/SHA-256-key-derivation design
        // decisions `Cipher_Encrypt`/`Cipher_Decrypt` make.
        register("encrypt_md5") { arguments, _ in
            let data = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            return .string(LassoHashing.md5Hex(Data(data)))
        }
        register("cipher_digest") { arguments, _ in
            let data = Data(LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string("")))
            let algorithm = arguments.lastString(named: "digest") ?? ""
            guard let digest = LassoHashing.digest(data, algorithm: algorithm) else {
                throw LassoRecoverableError(LassoErrorState(
                    code: LassoErrorHandling.Code.invalidParameter,
                    message: "Invalid parameter",
                    kind: "encryption"
                ))
            }
            if arguments.hasTruthyFlag("hex") {
                return .string(digest.map { String(format: "%02x", $0) }.joined())
            }
            return .object(LassoBytesValue.makeObject(rawBytes: Array(digest)))
        }
        register("cipher_encrypt") { arguments, _ in
            let data = Data(LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string("")))
            let cipher = arguments.lastString(named: "cipher") ?? ""
            let key = Data((arguments.lastString(named: "key") ?? "").utf8)
            guard let encrypted = LassoHashing.cipherEncrypt(data, cipher: cipher, keyMaterial: key) else {
                throw LassoRecoverableError(LassoErrorState(
                    code: LassoErrorHandling.Code.invalidParameter,
                    message: "Invalid parameter",
                    kind: "encryption"
                ))
            }
            return .object(LassoBytesValue.makeObject(rawBytes: Array(encrypted)))
        }
        register("cipher_decrypt") { arguments, _ in
            let data = LassoBytesValue.rawBytes(from: arguments.positionalValue(at: 0) ?? .string(""))
            let cipher = arguments.lastString(named: "cipher") ?? ""
            let key = Data((arguments.lastString(named: "key") ?? "").utf8)
            guard let decrypted = LassoHashing.cipherDecrypt(Data(data), cipher: cipher, keyMaterial: key) else {
                throw LassoRecoverableError(LassoErrorState(
                    code: LassoErrorHandling.Code.invalidParameter,
                    message: "Invalid parameter",
                    kind: "encryption"
                ))
            }
            return .object(LassoBytesValue.makeObject(rawBytes: Array(decrypted)))
        }
        register("cipher_list") { arguments, _ in
            // Real Lasso returns a `staticarray` (this codebase's
            // `Array` is the closest existing equivalent — `StaticArray`
            // itself is a separate, already-tracked gap). With
            // `-digest`, real Lasso limits the list to digest
            // algorithms specifically — this adapter's own cipher
            // support IS entirely digest algorithms plus AES, so
            // `-digest` here just excludes "AES".
            if arguments.hasTruthyFlag("digest") {
                return .array(LassoHashing.cipherDigestNames.map(LassoValue.string))
            }
            return .array((LassoHashing.cipherDigestNames + ["AES"]).map(LassoValue.string))
        }
        // `Json_Deserialize` — the natural inverse of the pre-existing
        // `Json_Serialize` above, reusing its exact underlying
        // machinery (`JSONSerialization` + `LassoValue.from(json:)`,
        // already used elsewhere to restore JSON-safe session
        // variables). Unlike every other tag added this batch, this
        // one's real-Lasso documentation couldn't be independently
        // re-verified against lassoguide.com's public reference (no
        // `json_deserialize`/`json_serialize` hits found anywhere on
        // the site) — implemented as the obvious, standard inverse of
        // the already-implemented `Json_Serialize` instead, which this
        // exact name/shape was already presumably verified against
        // when it was first added.
        register("json_deserialize") { arguments, _ in
            let jsonString = arguments.first?.value.outputString ?? ""
            guard let data = jsonString.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return .null
            }
            return LassoValue.from(json: object)
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
        // Math_* substitution-tag family (Ch. 28 Tables 10/12) — the
        // arithmetic symbols (+/-/*// /%) already work via
        // `Evaluator.binary`; this is the separate free-tag dialect real
        // corpus commonly uses instead (`Math_Add`, `Math_Round`, ...),
        // plus rounding/random/trig functions with no symbol equivalent
        // at all. See MathOperations.swift for the shared operand-
        // extraction/result-type helpers.
        register("math_abs") { arguments, _ in
            switch arguments.positionalValue(at: 0) {
            case let .integer(value): return .integer(abs(value))
            default: return .decimal(abs(arguments.positionalValue(at: 0)?.number ?? 0))
            }
        }
        register("math_add") { arguments, _ in
            let (values, allInteger) = LassoMathOperations.operands(arguments)
            return LassoMathOperations.result(values.reduce(0, +), allInteger: allInteger)
        }
        register("math_sub") { arguments, _ in
            // "Subtracts each of multiple parameters in order from left
            // to right" (Table 10) — a chained left-fold, not just a
            // two-parameter difference.
            let (values, allInteger) = LassoMathOperations.operands(arguments)
            guard let first = values.first else { return .integer(0) }
            let total = values.dropFirst().reduce(first, -)
            return LassoMathOperations.result(total, allInteger: allInteger)
        }
        register("math_mult") { arguments, _ in
            let (values, allInteger) = LassoMathOperations.operands(arguments)
            return LassoMathOperations.result(values.reduce(1, *), allInteger: allInteger)
        }
        register("math_div") { arguments, _ in
            // Ch. 28 Table 10: "Divides each of multiple parameters in
            // order from left to right." All-integer parameters truncate
            // toward the integer result (confirmed by the Guide's own
            // clean worked example: `Math_Div(1, 8)` -> `0`, "0.125 rounds
            // down to zero when cast to an integer"); a decimal parameter
            // keeps full precision (`Math_Div(1.0, 8)` -> `0.125000`).
            // Note: the Guide's OWN two-parameter examples immediately
            // below that rule (`Math_Div(10, 9)` -> `11`, `Math_Div(10,
            // 8.0)` -> `12.5`) don't correspond to any sensible division
            // of those inputs — almost certainly a real transcription
            // defect in the PDF itself (this project has already
            // confirmed at least one other verbatim doc defect,
            // Valid_CreditCard's "ROT-13" mislabeling), so this follows
            // the clean, internally-consistent rule and first example
            // rather than those two outlier numbers. Division by zero
            // substitutes 1 rather than crashing/producing NaN, borrowing
            // the same zero-substitutes-to-1 idea `Evaluator.binary`'s
            // "%" operator already uses — not full parity: "%" clamps
            // any non-positive divisor (including negatives) to 1, while
            // this only special-cases an exact 0 and preserves negative
            // divisors for real division.
            let (values, allInteger) = LassoMathOperations.operands(arguments)
            guard let first = values.first else { return .integer(0) }
            let total = values.dropFirst().reduce(first) { $0 / ($1 == 0 ? 1 : $1) }
            return LassoMathOperations.result(total, allInteger: allInteger)
        }
        register("math_mod") { arguments, _ in
            let (values, allInteger) = LassoMathOperations.operands(arguments)
            guard values.count >= 2 else { return .integer(0) }
            let divisor = values[1] == 0 ? 1 : values[1]
            return LassoMathOperations.result(values[0].truncatingRemainder(dividingBy: divisor), allInteger: allInteger)
        }
        register("math_max") { arguments, _ in
            let (values, allInteger) = LassoMathOperations.operands(arguments)
            return LassoMathOperations.result(values.max() ?? 0, allInteger: allInteger)
        }
        register("math_min") { arguments, _ in
            let (values, allInteger) = LassoMathOperations.operands(arguments)
            return LassoMathOperations.result(values.min() ?? 0, allInteger: allInteger)
        }
        // ->Ceil/->Floor/->RInt always return an integer regardless of
        // the input's own type (Table 10: "Returns the next higher/lower
        // integer" / "Rounds to nearest integer") — confirmed by the
        // worked examples (`Math_RInt(37.6)` -> `38`, `Math_Floor(37.6)`
        // -> `37`, `Math_Ceil(37.6)` -> `38`).
        register("math_ceil") { arguments, _ in
            .integer(Int((arguments.positionalValue(at: 0)?.number ?? 0).rounded(.up)))
        }
        register("math_floor") { arguments, _ in
            .integer(Int((arguments.positionalValue(at: 0)?.number ?? 0).rounded(.down)))
        }
        register("math_rint") { arguments, _ in
            .integer(Int((arguments.positionalValue(at: 0)?.number ?? 0).rounded()))
        }
        register("math_round") { arguments, _ in
            // Two documented forms sharing one formula (Ch. 28 "Rounding
            // Numbers", confirmed by all four decimal-form worked
            // examples and all three integer-multiple-form ones):
            // decimal precision (e.g. 0.0001) rounds to that many decimal
            // places and stays a decimal; integer precision (e.g. 1000)
            // rounds to the nearest multiple of it and returns an
            // integer. Both are `(value / precision).rounded() * precision`
            // — only the result's TYPE differs, based on the precision
            // argument's own type.
            guard let value = arguments.positionalValue(at: 0)?.number else { return .integer(0) }
            guard let precisionArgument = arguments.positionalValue(at: 1),
                  let precisionValue = precisionArgument.number, precisionValue != 0 else {
                return .integer(Int(value.rounded()))
            }
            let rounded = (value / precisionValue).rounded() * precisionValue
            if case .integer = precisionArgument {
                return .integer(Int(rounded))
            }
            return .decimal(rounded)
        }
        register("math_random") { arguments, _ in
            // Ch. 28 "Random Numbers" / Table 11. Decimal vs. integer
            // result is decided by whether -Min/-Max are decimals; for
            // the integer form, -Max is documented as "one greater than
            // maximum desired value" ("[Math_Random: -Min=1, -Max=100]"
            // returns 1-99), i.e. the real range is [min, max).
            let minArgument = arguments.firstValue(named: "min")
            let maxArgument = arguments.firstValue(named: "max")
            let isDecimalRange: Bool
            if case .decimal = minArgument { isDecimalRange = true }
            else if case .decimal = maxArgument { isDecimalRange = true }
            else { isDecimalRange = false }
            let minValue = minArgument?.number ?? 0
            if isDecimalRange {
                let maxValue = maxArgument?.number ?? 1.0
                let upperBound = max(maxValue, minValue + .ulpOfOne)
                return .decimal(Double.random(in: minValue..<upperBound))
            }
            let low = Int(minValue)
            let high = max(Int(maxArgument?.number ?? 100) - 1, low)
            let result = Int.random(in: low...high)
            if arguments.hasTruthyFlag("hex") {
                // Zero-padded to 2 digits — the Guide's own stated
                // rationale for `-Hex` is HTML color values (`#RRGGBB`),
                // where a caller stitching together `#[Math_Random(...,
                // -Hex)]...` three times needs consistent-width
                // components; an unpadded single digit for a result
                // under 16 would silently shift the color string's
                // length. Flagged in architect review.
                let hex = String(result, radix: 16)
                return .string(hex.count < 2 ? "0" + hex : hex)
            }
            return .integer(result)
        }
        register("math_sqrt") { arguments, _ in
            .decimal(sqrt(arguments.positionalValue(at: 0)?.number ?? 0))
        }
        register("math_pow") { arguments, _ in
            let baseArgument = arguments.positionalValue(at: 0)
            let exponentArgument = arguments.positionalValue(at: 1)
            let result = pow(baseArgument?.number ?? 0, exponentArgument?.number ?? 0)
            // Confirmed worked example: `Math_Pow(3, 3)` -> `27` (an
            // INTEGER result for integer inputs whose result happens to
            // be a whole number), matching the same all-integer-
            // parameters-stay-integer rule as the arithmetic tags above.
            if case .integer = baseArgument, case .integer = exponentArgument, result.rounded() == result {
                return .integer(Int(result))
            }
            return .decimal(result)
        }
        // Date and time — Lasso 8.5 Language Guide Chapter 29 "Date and
        // Time Operations". See Documentation/date-format-plan.md for the
        // native "date" object representation and the DateFormatter/ICU
        // rendering approach.
        // `RegExp(...)` constructor (Ch. 26 Table 7) — `-Find` is
        // documented as required; defaulting to an empty pattern rather
        // than throwing when omitted matches this codebase's general
        // "missing argument degrades gracefully" convention elsewhere
        // (e.g. `->replace`/`->contains` defaulting to `""`).
        register("regexp") { arguments, _ in
            .object(LassoObjectInstance(typeName: "regexp", data: [
                "find": .string(arguments.lastString(named: "find") ?? ""),
                "replace": .string(arguments.lastString(named: "replace") ?? ""),
                "input": .string(arguments.lastString(named: "input") ?? ""),
                "ignorecase": .boolean(arguments.hasTruthyFlag("ignorecase")),
            ]))
        }
        register("string_findregexp") { arguments, _ in
            // Ch. 26 Table 11 — returns a single FLAT array across every
            // match: full match text then each capture group's text, per
            // match, concatenated (see LassoRegularExpressions.findAll's
            // own doc comment for the worked-example evidence).
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let pattern = arguments.lastString(named: "find") ?? ""
            let ignoreCase = arguments.hasTruthyFlag("ignorecase")
            return .array(LassoRegularExpressions.findAll(in: text, pattern: pattern, ignoreCase: ignoreCase))
        }
        register("string_replaceregexp") { arguments, _ in
            // Table 11's own description text says this "Returns an
            // array with each instance... replaced" — almost certainly a
            // copy-paste artifact from the FindRegExp row just above it,
            // since every one of the Guide's own worked examples for
            // this exact tag shows a plain STRING result (e.g.
            // `<font color="blue">Blue</font> lake...`), never an array
            // representation. Implemented against the worked examples.
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let pattern = arguments.lastString(named: "find") ?? ""
            let replacement = arguments.lastString(named: "replace") ?? ""
            let ignoreCase = arguments.hasTruthyFlag("ignorecase")
            if arguments.hasTruthyFlag("replaceonlyone") {
                return .string(LassoRegularExpressions.replaceFirst(
                    in: text, pattern: pattern, replacement: replacement, ignoreCase: ignoreCase
                ))
            }
            return .string(LassoRegularExpressions.replaceAll(
                in: text, pattern: pattern, replacement: replacement, ignoreCase: ignoreCase
            ))
        }
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
        register("date_add") { arguments, _ in
            // Lasso 8.5 Language Guide Ch. 29 Table 6: "First parameter is
            // a Lasso date. Keyword/value parameters define what should
            // be added" — real corpus need (Documentation/
            // outstanding-compatibility-project-plans.md's own Goal
            // section named this explicitly, but it was never actually
            // shipped despite Date_Format/Date_LocalToGMT landing).
            let positional = arguments.positionalValue(at: 0) ?? .void
            let components = LassoDateParsing.parse(positional) ?? .now()
            let delta = LassoDateParsing.dateMathDelta(from: arguments, negate: false)
            return .object(LassoDateParsing.makeObject(components.adding(delta)))
        }
        register("date_subtract") { arguments, _ in
            let positional = arguments.positionalValue(at: 0) ?? .void
            let components = LassoDateParsing.parse(positional) ?? .now()
            let delta = LassoDateParsing.dateMathDelta(from: arguments, negate: true)
            return .object(LassoDateParsing.makeObject(components.adding(delta)))
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
        // Lasso 8.5 Language Guide p.389 "Creating Arrays": "name/value
        // pairs ... are interpreted as pairs to be added to the array" —
        // `[Array: 'Name_One'='Value_One', 'Name_Two'='Value_Two']` builds
        // an array of two Pairs, not two plain string values. p.396's
        // "Pair Arrays" worked example additionally mixes pair and
        // non-string-value forms (`'Alpha'='One', 'Beta'='Two', 'Alpha'=1,
        // 'Beta'=2`). Previously every labeled argument's label was
        // silently discarded here (`register("map")` and `register("pair")`
        // already do the label-aware thing correctly), so
        // `array('Alpha'='One')` produced `.array([.string("One")])`
        // instead of `.array([.pair(.string("Alpha"), .string("One"))])`.
        register("array") { arguments, _ in
            .array(arguments.map { argument in
                if let label = argument.label {
                    return .pair(.string(label), argument.value)
                }
                return argument.value
            })
        }
        // Bare `staticarray` (no parens/args) as a VALUE, not the `(:
        // ...)` literal syntax already handled at parse time — real
        // corpus (zeroloop/ds's ds.lasso): `#rest || staticarray` (~20+
        // call sites, e.g. every `public updaterows(...) =>
        // .updaterow(: #rest || staticarray)` shape) and data-member
        // defaults like `data public inputcolumns::staticarray =
        // staticarray`. This codebase has no distinct StaticArray type
        // (established precedent — see `NativeTypes.swift`'s
        // `eachCharacter` comment and `cipher_list`'s own use of `array`
        // as its stand-in), so this is registered as a plain alias for
        // `array`'s own zero-or-more-argument behavior, reachable via
        // both the bare-identifier dispatch path (`.identifier`, no
        // parens) and an explicit `staticarray(...)` call.
        register("staticarray") { arguments, _ in
            .array(arguments.map { argument in
                if let label = argument.label {
                    return .pair(.string(label), argument.value)
                }
                return argument.value
            })
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
        // `Set`/`List`/`Queue`/`Stack`/`Series` (Ch. 30 Tables 4/12/14/15/17)
        // — see `Collections.swift` for the native-type method tables.
        // A bare `set`/`list`/`queue`/`stack` identifier (no parens —
        // real corpus: includes/detail_a_sku.lasso's `var('skuArrayColor'
        // = set)`, building "a special 'color' array that contains every
        // color/print found" per that file's own comment) already
        // resolves to an empty instance of the right type via the
        // generic bare-identifier-to-native-type path
        // (`Evaluator.evaluate`'s `.identifier` case, `context.nativeTypes.containsType`)
        // with no registration needed here — this is only for the
        // PAREN-CALL form (`(Set)`/`(List: 'a', 'b')`), matching the
        // dual free-function-plus-native-type registration pattern
        // `date`/`bytes`/`regexp` already established. Real Set replaces
        // the previous `.array`-alias placeholder, which admitted (in
        // its own comment, now resolved) that it couldn't dedup —
        // `Collections.swift`'s `->Insert` now does via the same
        // `lassoEquals` this project already uses for `Array->Contains`.
        register("list") { arguments, _ in
            .object(LassoCollectionValue.makeObject(typeName: "list", elements: arguments.map(\.value)))
        }
        // The 8.5 PDF's own Table 12/17 say "Creates an empty queue"/
        // "Creates an empty stack" (Ch. 30 pp.408, 413) with no
        // parameters documented at all — but lassoguide.com's Lasso 9
        // docs explicitly say "Creates a queue/stack object using the
        // parameters passed to it as the elements of the queue/stack",
        // matching List's own documented constructor behavior. Cross-
        // checked directly against lassoguide.com/operations/
        // collections.html, not inferred. Following the newer/more
        // complete source here, same as this project's established
        // practice elsewhere of preferring lassoguide.com over 8.5 PDF
        // gaps. Argument order is preserved as insertion order, so
        // `queue('One', 'Two')`'s `->First` is 'One' (FIFO) and
        // `stack('One', 'Two')`'s `->First` is 'Two' (LIFO) — identical
        // to what sequential `->Insert` calls would produce.
        register("queue") { arguments, _ in
            .object(LassoCollectionValue.makeObject(typeName: "queue", elements: arguments.map(\.value)))
        }
        register("stack") { arguments, _ in
            .object(LassoCollectionValue.makeObject(typeName: "stack", elements: arguments.map(\.value)))
        }
        register("set") { arguments, context in
            // The 8.5 PDF's own Table 15 documents the constructor's
            // one parameter as an optional comparator — but
            // lassoguide.com/operations/collections.html (9.3, the
            // newer/more complete source this project already prefers
            // over 8.5 PDF gaps — see `queue`/`stack`'s own comment
            // above) instead documents `set(key, ...)`: "A set is
            // created with zero or more element parameters. The
            // element values are inserted into the set." No comparator
            // parameter is mentioned there at all. Following that
            // newer source, matching List/Queue/Stack's own
            // constructors, which all likewise insert their positional
            // arguments. Dedup-then-sort mirrors `->Insert`'s own
            // documented behavior (Table 15/16, "duplicate key value is
            // replaced") — folding every argument through the same
            // dedup check `->Insert` uses is equivalent to calling
            // `->Insert` once per argument, since natural-sort is
            // idempotent regardless of insertion order.
            var elements: [LassoValue] = []
            for argument in arguments.map(\.value) {
                if !elements.contains(where: { LassoCollectionValue.equals($0, argument, context: context) }) {
                    elements.append(argument)
                }
            }
            return .object(LassoCollectionValue.makeObject(
                typeName: "set", elements: LassoCollectionValue.naturalSort(elements)
            ))
        }
        register("series") { arguments, _ in
            // "The start value is incremented until it equals the end
            // value" — ascending only; no worked example covers a
            // start > end descending series, deferred/unverified.
            // Per-element whole-number rounding mirrors this codebase's
            // established `.integer`-vs-`.decimal` convention
            // (`numeric(_:_:_:)`), matching the Guide's own worked
            // example (`Series(1,10)` → all integers).
            guard let start = arguments.first?.value.number,
                  let end = arguments.positionalValue(at: 1)?.number,
                  start <= end else {
                return .array([])
            }
            var elements: [LassoValue] = []
            var current = start
            while current <= end {
                elements.append(current.rounded() == current ? .integer(Int(current)) : .decimal(current))
                current += 1
            }
            return .array(elements)
        }
        // Built-in Comparators (Ch. 30 Table 21, p.419) — see
        // `Comparators.swift`'s own top-level doc comment for why these
        // ALSO ship as ordinary free tags (`(Compare_LessThan)` to get a
        // passable value, `(Compare_LessThan: 1, 2)` to evaluate
        // directly), alongside the real `\Compare_LessThan` bareword-
        // reference syntax Stage 6 (`TagReference.swift`) added — both
        // forms are equivalent and kept, not one deprecated in favor of
        // the other.
        for kind in LassoComparatorValue.builtInKinds {
            register("compare_\(kind)") { arguments, context in
                guard arguments.count >= 2 else {
                    return .object(LassoComparatorValue.makeObject(kind: kind))
                }
                let left = arguments[0].value
                let right = arguments.positionalValue(at: 1) ?? .null
                return .integer(LassoComparatorValue.evaluate(kind: kind, left: left, right: right, context: context))
            }
        }
        // `PriorityQueue`/`TreeMap` (Ch. 30 Tables 10/19) — see
        // `Collections.swift`'s own `makePriorityQueueType()`/
        // `makeTreeMapType()` doc comments for the greatest-first-by-
        // default-comparator semantics and any-type-key storage this
        // stage adds.
        register("priorityqueue") { arguments, _ in
            // "Priority queues are always created empty" (p.405) — the
            // ONE optional parameter is a comparator, not initial
            // elements (unlike List/Queue/Stack). Defaults to
            // `\Compare_LessThan` per its own documented default.
            // Re-verified directly against docs while investigating a
            // report that `priorityqueue(2,1)` "silently drops"
            // positional elements the same way `set(...)` did (fixed
            // above): unlike Set, lassoguide.com has no updated
            // PriorityQueue page — its own `[PriorityQueue->Remove]`
            // reference page explicitly defers to "the Lasso 8 Language
            // Guide" (i.e. this same 8.5 PDF) for this type. So this
            // empty-plus-comparator-only behavior IS the documented
            // behavior, not a gap; deliberately left unchanged.
            let comparatorArgument: LassoValue = arguments.first?.value ?? .null
            let kind = LassoComparatorValue.kind(of: comparatorArgument) ?? "lessthan"
            return .object(LassoPriorityQueueValue.makeObject(kind: kind, elements: []))
        }
        register("treemap") { arguments, _ in
            // NOT actually invoked for `treemap(...)` calls anymore —
            // `Evaluator.evaluate`'s `.call` case special-cases the
            // name "treemap" ahead of the generic dispatch that would
            // otherwise reach this closure, specifically to preserve
            // real (non-string-coerced) key types (see that case's own
            // doc comment; found missing by architect review). This
            // registration is kept only so `context.natives
            // .contains("treemap")` still reports true for
            // introspection/`HasMethod`-style checks — its own
            // argument-handling body is now unreachable dead weight
            // for real construction, left here as a best-effort
            // fallback rather than deleted outright in case some other
            // path ever calls `context.natives.function(named:
            // "treemap")` directly.
            var kind = "lessthan"
            var pairs: [EvaluatedArgument] = arguments
            if let first = arguments.first, LassoComparatorValue.kind(of: first.value) != nil {
                kind = LassoComparatorValue.kind(of: first.value) ?? "lessthan"
                pairs = Array(arguments.dropFirst())
            }
            let entries = pairs.compactMap { argument -> LassoValue? in
                if case .pair = argument.value { return argument.value }
                if let label = argument.label { return .pair(.string(label), argument.value) }
                return nil
            }
            return .object(LassoTreeMapValue.makeObject(kind: kind, entries: entries))
        }
        // Matchers (Ch. 30 Table 22) — see `Matchers.swift`'s own doc
        // comment for the full design. All five are ordinary
        // constructors (unlike Comparators, which double as a 0-or-2-arg
        // value/evaluator — Matchers have no analogous documented
        // "call directly with a test value" form).
        register("match_regexp") { arguments, _ in
            .object(LassoMatcherValue.makeObject(kind: "regexp", data: [
                "_pattern": arguments.first?.value ?? .string(""),
            ]))
        }
        register("match_notregexp") { arguments, _ in
            .object(LassoMatcherValue.makeObject(kind: "notregexp", data: [
                "_pattern": arguments.first?.value ?? .string(""),
            ]))
        }
        register("match_range") { arguments, _ in
            .object(LassoMatcherValue.makeObject(kind: "range", data: [
                "_low": arguments.first?.value ?? .null,
                "_high": arguments.positionalValue(at: 1) ?? .null,
            ]))
        }
        register("match_notrange") { arguments, _ in
            .object(LassoMatcherValue.makeObject(kind: "notrange", data: [
                "_low": arguments.first?.value ?? .null,
                "_high": arguments.positionalValue(at: 1) ?? .null,
            ]))
        }
        register("match_comparator") { arguments, _ in
            guard let comparatorValue = arguments.first?.value else { return .null }
            var data: [String: LassoValue] = ["_comparator": comparatorValue]
            if let rhs = arguments.first(where: { $0.label?.caseInsensitiveCompare("rhs") == .orderedSame }) {
                data["_rhs"] = rhs.value
                data["_haslhs"] = .boolean(false)
            } else if let lhs = arguments.first(where: { $0.label?.caseInsensitiveCompare("lhs") == .orderedSame }) {
                data["_lhs"] = lhs.value
                data["_haslhs"] = .boolean(true)
            }
            return .object(LassoMatcherValue.makeObject(kind: "comparator", data: data))
        }
        // `Iterator`/`ReverseIterator` (Ch. 30 Table 23) — "Requires a
        // compound data type as a parameter... A second optional
        // parameter allows a matcher to be specified" — now wired
        // through to `LassoIteratorValue.build(from:reverse:matcher:)`,
        // which pre-filters the snapshot to only matcher-matching
        // elements (verified against the p.426 worked example:
        // `Iterator($myArray, (Match_Range: 'a', 'm'))` on
        // `('One','Two','Three','Four')` yields only "Four").
        register("iterator") { arguments, context in
            guard let source = arguments.first?.value else { return .null }
            let matcher = arguments.positionalValue(at: 1)
            return try await LassoIteratorValue.build(from: source, reverse: false, matcher: matcher, context: context) ?? .null
        }
        register("reverseiterator") { arguments, context in
            guard let source = arguments.first?.value else { return .null }
            let matcher = arguments.positionalValue(at: 1)
            return try await LassoIteratorValue.build(from: source, reverse: true, matcher: matcher, context: context) ?? .null
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
        // String_Is* whole-string validation family (Ch. 25 Table 10) —
        // each returns True only if the string is non-empty AND every
        // character matches the criterion. The Guide doesn't address the
        // empty-string case explicitly, but a vacuous "every character
        // of nothing matches" true (Swift's own `allSatisfy` default on
        // an empty collection) reads as a wrong answer for an "is this
        // string alphabetic" style check — most languages' equivalent
        // predicates (e.g. Python's `str.isalpha()`) special-case empty
        // as False for the same reason, and it's what this file's own
        // pre-existing `->IsLower`/`->IsUpper`-shaped checks already do
        // via their own `.contains { $0.isLetter }` guard.
        register("string_isalpha") { arguments, _ in
            .boolean(isEveryCharacter(arguments.positionalValue(at: 0)?.outputString ?? "") { $0.isLetter })
        }
        register("string_isalphanumeric") { arguments, _ in
            .boolean(isEveryCharacter(arguments.positionalValue(at: 0)?.outputString ?? "") { $0.isLetter || $0.isNumber })
        }
        register("string_isdigit") { arguments, _ in
            .boolean(isEveryCharacter(arguments.positionalValue(at: 0)?.outputString ?? "") { $0.isNumber })
        }
        register("string_ishexdigit") { arguments, _ in
            .boolean(isEveryCharacter(arguments.positionalValue(at: 0)?.outputString ?? "") { $0.isHexDigit })
        }
        register("string_islower") { arguments, _ in
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            return .boolean(isEveryCharacter(text) { $0.isLowercase } && text.contains { $0.isLetter })
        }
        register("string_isupper") { arguments, _ in
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            return .boolean(isEveryCharacter(text) { $0.isUppercase } && text.contains { $0.isLetter })
        }
        register("string_isnumeric") { arguments, _ in
            // Ch. 25 Table 10: "only numerals, hyphens, or periods" —
            // distinct from `->IsDigit`, which is numerals only.
            .boolean(isEveryCharacter(arguments.positionalValue(at: 0)?.outputString ?? "") { $0.isNumber || $0 == "-" || $0 == "." })
        }
        register("string_ispunctuation") { arguments, _ in
            // Ch. 25 Table 10 says only "contains punctuation characters"
            // (no mention of symbols like `$`/`+`/`=`) and gives no
            // worked example that would resolve punctuation-vs-symbol
            // either way — tracking the doc's literal wording rather
            // than also matching `Character.isSymbol`, which an earlier
            // version did with no evidence to justify the broader
            // reading (flagged in architect review).
            .boolean(isEveryCharacter(arguments.positionalValue(at: 0)?.outputString ?? "") { $0.isPunctuation })
        }
        register("string_isspace") { arguments, _ in
            .boolean(isEveryCharacter(arguments.positionalValue(at: 0)?.outputString ?? "") { $0.isWhitespace })
        }
        register("string_length") { arguments, _ in
            // Documented synonym for `->Size` (Ch. 25 Table 10).
            .integer(arguments.positionalValue(at: 0)?.outputString.count ?? 0)
        }
        register("string_endswith") { arguments, _ in
            // Ch. 25 Table 8: `[String_EndsWith]` — a string value plus a
            // `-Find` keyword parameter, case insensitive (matching the
            // member form's own documented case-insensitivity).
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let suffix = arguments.lastString(named: "find") ?? ""
            return .boolean(suffix.isEmpty || text.range(of: suffix, options: [.caseInsensitive, .backwards, .anchored]) != nil)
        }
        register("string_concatenate") { arguments, _ in
            // Ch. 25 Table 4: "Concatenates all of its parameters into a
            // single string."
            .string(arguments.map { $0.value.outputString }.joined())
        }
        register("string_insert") { arguments, _ in
            // Ch. 25 Table 4: string, `-Text`, `-Position` — inserts
            // `-Text` at the (1-based) `-Position` offset, returns the
            // new string. Does not mutate — the free-tag family never
            // does, only its member-tag siblings do. Both `-Text` and
            // `-Position` are documented as required parameters; an
            // OMITTED (not merely empty) one throws, matching this
            // file's `encrypt_hmac`/`file_processuploads` precedent for
            // a documented-required argument the caller simply forgot —
            // found missing by code review.
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let characters = Array(text)
            guard let insertText = arguments.lastString(named: "text") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4001, message: "String_Insert requires -Text.", kind: "string"
                ))
            }
            guard let position = arguments.lastInt(named: "position") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4002, message: "String_Insert requires -Position.", kind: "string"
                ))
            }
            let insertAt = min(max(position - 1, 0), characters.count)
            return .string(String(characters[0..<insertAt]) + insertText + String(characters[insertAt...]))
        }
        register("string_remove") { arguments, _ in
            // Ch. 25 Table 4: string, `-StartPosition`, `-EndPosition` —
            // a DIFFERENT signature from the member `->Remove` (which
            // takes offset+count): removes the substring from
            // `-StartPosition` to `-EndPosition` (inclusive, per the
            // Guide's own worked example: `String_Remove('A Short
            // String', -StartPosition=3, -EndPosition=8)` → 'A String' —
            // removing 6 characters, positions 3 through 8 inclusive)
            // and returns the remainder. Both parameters are documented
            // as required; an OMITTED one throws, matching this file's
            // `encrypt_hmac`/`file_processuploads` precedent (found
            // missing by code review — an earlier version silently
            // returned the input unchanged instead).
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let characters = Array(text)
            guard let start = arguments.lastInt(named: "startposition") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4003, message: "String_Remove requires -StartPosition.", kind: "string"
                ))
            }
            guard let end = arguments.lastInt(named: "endposition") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4004, message: "String_Remove requires -EndPosition.", kind: "string"
                ))
            }
            let startIndex = max(start - 1, 0)
            let endIndex = min(end, characters.count)
            guard startIndex < characters.count, endIndex > startIndex else { return .string(text) }
            return .string(String(characters[0..<startIndex]) + String(characters[endIndex...]))
        }
        register("string_removeleading") { arguments, _ in
            // Ch. 25 Table 4: string, `-Pattern` — "removed from the
            // start", matching the member `->RemoveLeading`'s own
            // documented repeated-removal semantics (worked example:
            // stripping every leading `*` from `'*A Short String*'`).
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let pattern = arguments.lastString(named: "pattern") ?? ""
            guard !pattern.isEmpty else { return .string(text) }
            var remaining = Substring(text)
            while remaining.hasPrefix(pattern) { remaining = remaining.dropFirst(pattern.count) }
            return .string(String(remaining))
        }
        register("string_removetrailing") { arguments, _ in
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let pattern = arguments.lastString(named: "pattern") ?? ""
            guard !pattern.isEmpty else { return .string(text) }
            var remaining = Substring(text)
            while remaining.hasSuffix(pattern) { remaining = remaining.dropLast(pattern.count) }
            return .string(String(remaining))
        }
        register("string_replace") { arguments, _ in
            // Ch. 25 Table 4: string, `-Find`, `-Replace` — "Returns the
            // string with the FIRST INSTANCE of the -Find parameter
            // replaced" — deliberately narrower than the member
            // `->Replace` (which replaces every occurrence); this is the
            // documented free-tag contract, not an oversight. Both
            // `-Find` and `-Replace` are documented required parameters;
            // an OMITTED one throws (found missing by code review),
            // matching this file's `encrypt_hmac` precedent — an
            // explicitly EMPTY `-Find` still just returns the input
            // unchanged (nothing to find), same "omitted vs. present but
            // empty" distinction `encrypt_hmac`'s own comment draws.
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            guard let find = arguments.lastString(named: "find") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4005, message: "String_Replace requires -Find.", kind: "string"
                ))
            }
            guard let replacement = arguments.lastString(named: "replace") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4006, message: "String_Replace requires -Replace.", kind: "string"
                ))
            }
            guard !find.isEmpty, let range = text.range(of: find) else { return .string(text) }
            var result = text
            result.replaceSubrange(range, with: replacement)
            return .string(result)
        }
        register("string_lowercase") { arguments, _ in
            // Ch. 25 Table 6's own prose for BOTH `String_LowerCase` and
            // `String_UpperCase` literally says "in lowercase" — a
            // copy-paste artifact contradicted by the chapter's own worked
            // example (`String_UpperCase: 'A Short String'` → 'A SHORT
            // STRING'); implemented against the worked example, matching
            // this project's established practice of preferring worked
            // examples over inconsistent table prose (e.g. the earlier
            // `Math_Div` documentation-defect precedent).
            .string(arguments.map { $0.value.outputString }.joined().lowercased())
        }
        register("string_uppercase") { arguments, _ in
            .string(arguments.map { $0.value.outputString }.joined().uppercased())
        }
        register("string_extract") { arguments, _ in
            // Ch. 25 Table 10: string, `-StartPosition`, `-EndPosition` —
            // "Returns a substring from -StartPosition to -EndPosition."
            // worked example: `String_Extract('A Short String',
            // -StartPosition=3, -EndPosition=8)` → 'Short' (inclusive
            // range, same 1-based inclusive convention as
            // `string_remove` above). Both parameters are documented
            // required; an OMITTED one throws, matching this file's
            // `encrypt_hmac`/`file_processuploads` precedent (found
            // missing by code review — an earlier version silently
            // returned an empty string instead).
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let characters = Array(text)
            guard let start = arguments.lastInt(named: "startposition") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4007, message: "String_Extract requires -StartPosition.", kind: "string"
                ))
            }
            guard let end = arguments.lastInt(named: "endposition") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4008, message: "String_Extract requires -EndPosition.", kind: "string"
                ))
            }
            let startIndex = max(start - 1, 0)
            let endIndex = min(end, characters.count)
            guard startIndex < characters.count, endIndex > startIndex else { return .string("") }
            return .string(String(characters[startIndex..<endIndex]))
        }
        register("string_findposition") { arguments, _ in
            // Ch. 25 Table 10: string, `-Find` — "Returns the location
            // of the -Find parameter in the string parameter." Same
            // 1-based/0-miss convention as the member `->Find`.
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            let needle = arguments.lastString(named: "find") ?? ""
            guard !needle.isEmpty, let range = text.range(of: needle) else { return .integer(0) }
            return .integer(text.distance(from: text.startIndex, to: range.lowerBound) + 1)
        }
        register("string_findblocks") { arguments, _ in
            // Ch. 25 Table 10: string, `-Begin`, `-End`, optional
            // `-IgnoreComments`/`-CommentChar` (default `#`) — returns an
            // array of substrings found between each `-Begin`/`-End`
            // delimiter pair. No worked example exists anywhere in the
            // Language Guide for this specific tag (confirmed via direct
            // search) — implemented against its own prose description
            // only; `-IgnoreComments` skips any SOURCE LINE that begins
            // with the comment character entirely, before block
            // extraction, matching the documented "ignore comment lines"
            // wording literally. `-Begin`/`-End` are documented required
            // parameters; an OMITTED one throws, matching this file's
            // `encrypt_hmac`/`file_processuploads` precedent (found
            // missing by code review — an earlier version silently
            // returned an empty array instead).
            let text = arguments.positionalValue(at: 0)?.outputString ?? ""
            guard let begin = arguments.lastString(named: "begin") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4009, message: "String_FindBlocks requires -Begin.", kind: "string"
                ))
            }
            guard let end = arguments.lastString(named: "end") else {
                throw LassoRecoverableError(LassoErrorState(
                    code: 4010, message: "String_FindBlocks requires -End.", kind: "string"
                ))
            }
            guard !begin.isEmpty, !end.isEmpty else { return .array([]) }
            let commentChar = arguments.lastString(named: "commentchar") ?? "#"
            let ignoreComments = arguments.hasTruthyFlag("ignorecomments")
            let source: String
            if ignoreComments, !commentChar.isEmpty {
                source = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix(commentChar) }
                    .joined(separator: "\n")
            } else {
                source = text
            }
            var blocks: [LassoValue] = []
            var searchRange = source.startIndex..<source.endIndex
            while let beginRange = source.range(of: begin, range: searchRange),
                  let endRange = source.range(of: end, range: beginRange.upperBound..<source.endIndex) {
                blocks.append(.string(String(source[beginRange.upperBound..<endRange.lowerBound])))
                searchRange = endRange.upperBound..<source.endIndex
            }
            return .array(blocks)
        }
        register("string_getunicodeversion") { _, _ in
            // Ch. 25 Table 12: "Returns the version of the Unicode
            // standard which Lasso supports." Swift's stdlib exposes no
            // runtime-queryable Unicode version constant, so this
            // reports the Unicode Character Database version this
            // toolchain is documented to ship (Swift 6's ICU/UCD data),
            // matching the exact string format real Lasso itself uses
            // for this tag (e.g. "5.1.0").
            .string("15.0.0")
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
        // `stdout`/`stdoutnl` (`lassoguide.com/9.2/operations/command-line-tools.html`,
        // e.g. `stdoutnl($argc)`) -- write directly to the process's real
        // STDOUT stream, not to the page's own rendered output (see
        // `LassoContext.stdoutSink`'s doc comment for why this is a
        // separate hook from `log_critical`'s `diagnosticLogSink`). Real
        // corpus (zeroloop/ds's `_init.lasso`) only ever calls these with
        // a single already-stringifiable expression.
        register("stdout") { arguments, context in
            if let sink = context.stdoutSink {
                await sink(arguments.first?.value.outputString ?? "")
            }
            return .void
        }
        register("stdoutnl") { arguments, context in
            if let sink = context.stdoutSink {
                await sink((arguments.first?.value.outputString ?? "") + "\n")
            }
            return .void
        }
        // Ch. "Web Requests and Responses" > "define_atBegin and
        // define_atEnd": registers `arguments.first` (typically a
        // capture literal, per the docs' own recommendation of a tag
        // reference for efficiency -- real corpus only ever passes a
        // capture) to run once at THIS request's end -- see
        // `LassoContext.atEndRegistrations`/`Evaluator
        // .drainAtEndRegistrations` for storage and invocation. Only
        // `define_atend` is implemented here, not `define_atbegin`/
        // `web_response->addAtEnd` -- no corpus evidence for either yet
        // (zeroloop/ds's `_init.lasso`: `web_request ?
        // define_atend({ds_close_connections})`).
        register("define_atend") { arguments, context in
            guard case let .capture(capture) = arguments.first?.value else { return .void }
            context.atEndRegistrations.append(capture)
            return .void
        }
        register("return") { arguments, context in
            context.setNonLocalReturnSignal(arguments.first?.value ?? .void)
            return .void
        }
        // Ch. "Captures": "Captures can produce values by using `yield`
        // or `return`. Both `yield` and `return` halt the execution of
        // any of the capture's remaining code and produce the specified
        // value." Implemented identically to `return` for now — see
        // `Captures.swift`'s own doc comment for why the documented PC-
        // preserving resume behavior (a subsequent invocation continuing
        // right after the last `yield` instead of restarting) is NOT
        // implemented: it needs genuinely resumable (coroutine-like)
        // execution this tree-walking renderer has no capability for
        // anywhere today, a materially larger, separate piece of work.
        // The documented NON-LOCAL exit-through-home behavior IS real
        // and shared with `return` here (see
        // `LassoValue.setNonLocalReturnSignal`).
        register("yield") { arguments, context in
            context.setNonLocalReturnSignal(arguments.first?.value ?? .void)
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
        // Ch. "Captures", "Capture Methods": "currentCapture() — Returns
        // a reference to the capture that is currently executing." A
        // disclosed partial reading (Stage 7, see `currentCaptureStack`'s
        // own doc comment in this file): only capture LITERALS invoked
        // via `->invoke`/`()` push onto that stack, not the implicit
        // per-method capture the real docs describe every method
        // invocation as running inside (this codebase never materializes
        // one) — so this correctly returns the innermost actively-
        // executing capture LITERAL, and `.void` when called from
        // ordinary method/page code with no capture invocation active.
        register("currentcapture") { _, context in
            context.currentCapture.map { .capture($0) } ?? .void
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
        // Real Lasso's include_url — see NetworkRequests.swift for the
        // full implementation and its documented parameter coverage. Real
        // corpus: includes/efs_process.lasso's Authorize.net gateway call
        // (`include_URL(url, -POSTParams=$HSI_GatewaySend)`), previously
        // unregistered entirely (unknownFunction), which crashed before
        // the page had any chance to reach its own separate Pair(...)
        // gap (fixed earlier the same day).
        register("include_url") { arguments, context in
            try await LassoIncludeURL.perform(arguments, context: &context)
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
        // `Session_AddVar`/`Session_RemoveVar` are Lasso 9's shorthand
        // names; `Session_AddVariable`/`Session_RemoveVariable` are the
        // original Lasso 8.5 longhand this adapter hadn't registered at
        // all (unknownFunction) — real corpus (TS_lasso9, 21/60 files,
        // the single most prevalent gap found live-crawling that site)
        // uses only the longhand. Registered as aliases of one identical
        // implementation, matching the File_Serve/File_Stream precedent
        // above — no documented behavioral distinction between the two
        // names beyond spelling.
        let sessionAddVarHandler: LassoNativeFunction = { arguments, context in
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
        register("session_addvar", function: sessionAddVarHandler)
        register("session_addvariable", function: sessionAddVarHandler)
        let sessionRemoveVarHandler: LassoNativeFunction = { arguments, context in
            guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else { return .void }
            let name = resolved.name
            let varName = resolved.remainingPositional.first?.value.outputString ?? ""
            context.sessionProvider?.removeVar(varName, session: name)
            context.trackedSessionVariables.removeAll { $0.session == name && $0.varName == varName }
            return .void
        }
        register("session_removevar", function: sessionRemoveVarHandler)
        register("session_removevariable", function: sessionRemoveVarHandler)
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
        // -Body etc.). Dispatches through `context.emailProvider`
        // (`Documentation/lasso-perfect-smtp-integration-plan.md` §4.0's
        // dispatch-registration seam), the same "protocol-typed context
        // slot populated per-request from a host application" shape
        // `[inline]`/`context.inlineProvider` already uses in
        // Renderer.swift — `LassoParser` never imports a specific
        // resurrected library (e.g. `LassoPerfectSMTP`), it only knows
        // about the generic `LassoEmailProvider` protocol. When no
        // provider is configured this throws
        // `LassoRuntimeError.emailNotConfigured` rather than silently
        // no-op'ing, mirroring `[inline]`'s own `.inlineNotConfigured`
        // behavior for an unset `inlineProvider` — a deliberate behavior
        // change from this function's original no-op stub (§4.0). Real
        // corpus usage (importscripts/*.lasso, `email_send: -to=...,
        // -from=..., -subject=..., -body=...;`) is itself only reached on
        // already-degraded/error paths (import failure notifications),
        // never on the success path a real user hits.
        register("email_send") { arguments, context in
            guard let emailProvider = context.emailProvider else {
                throw LassoRuntimeError.emailNotConfigured
            }
            // Phase E (§4.0/§4.7b): `send` now returns `LassoEmailSendResult`,
            // not a bare `LassoValue` — this is the one place with `inout
            // LassoContext` access (the provider layer itself only ever sees
            // `context` by value), so it's the only place that CAN stash a
            // job ID into `context.lastEmailJobID` for a later `email_result()`
            // call to read back. A thrown `LassoEmailSendFailure` carries a
            // job ID recorded before a delivery failure occurred (as opposed
            // to a plain `LassoRecoverableError`/other error thrown for a
            // pre-send validation failure, which never recorded a job at all
            // and is left to propagate unchanged, un-caught by the clause
            // below).
            //
            // BLOCKING FIX #3 (Phase E milestone review): reset
            // `context.lastEmailJobID` to `nil` BEFORE attempting this call
            // at all, so that every OTHER thrown error (every pre-send
            // validation failure, which isn't `LassoEmailSendFailure` and so
            // isn't caught below) correctly leaves `lastEmailJobID` `nil`
            // rather than stale from a PREVIOUS, unrelated `email_send` call
            // earlier in the same request. Concrete bug this fixes:
            // `email_send` #1 succeeds (job ID X recorded) -> `email_send`
            // #2 in the same request fails pre-send validation (e.g.
            // missing `-subject`) -> a subsequent `email_result()` call must
            // throw (no job exists for #2), not silently return X.
            context.lastEmailJobID = nil
            do {
                let result = try await emailProvider.send(arguments, context: context)
                context.lastEmailJobID = result.jobID
                return result.value
            } catch let failure as LassoEmailSendFailure {
                context.lastEmailJobID = failure.jobID
                throw failure.underlying
            }
        }
        // `email_compose` (lassoguide.com, "Sending Email" → "Compose an
        // Email Message"; Documentation/lasso-perfect-smtp-integration-plan.md
        // §4.3b) — a genuine native-type CONSTRUCTOR, following the exact
        // `date`/`bytes` two-mechanism split: this free-function
        // registration builds the object (dispatching through
        // `context.emailProvider.compose`, same seam as `email_send`), and
        // `NativeTypes.swift`'s `makeEmailComposeType()` registers the
        // `->data`/`->from`/`->recipients`/etc. methods that read the
        // constructed object's fields back out. Throws
        // `LassoRuntimeError.emailNotConfigured` when unwired, identical to
        // `email_send`.
        register("email_compose") { arguments, context in
            guard let emailProvider = context.emailProvider else {
                throw LassoRuntimeError.emailNotConfigured
            }
            return try await emailProvider.compose(arguments, context: context)
        }
        // `email_mxlookup(domain, -refresh=?, -hostname=?)` (lassoguide.com,
        // §4.4) — a plain free function (no native-type problem here,
        // unlike `email_compose`): looks up (and, per real Lasso's
        // documented caching behavior, caches) the MX records for a
        // domain. Dispatches through the same `context.emailProvider` seam
        // as `email_send`/`email_compose`.
        register("email_mxlookup") { arguments, context in
            guard let emailProvider = context.emailProvider else {
                throw LassoRuntimeError.emailNotConfigured
            }
            return try await emailProvider.mxLookup(arguments, context: context)
        }
        // `email_result()` (Phase E, §4.7/§4.7b) — real Lasso's signature
        // takes NO arguments at all ("Can be called immediately after
        // calling email_send to get a unique ID string for the queued
        // message"); it implicitly refers to whatever `email_send` call
        // most recently completed, via `context.lastEmailJobID` (set by
        // `email_send`'s own registration above). Dispatches through the
        // same `context.emailProvider` seam as every other email-family
        // function.
        register("email_result") { arguments, context in
            guard let emailProvider = context.emailProvider else {
                throw LassoRuntimeError.emailNotConfigured
            }
            return try await emailProvider.result(context: context)
        }
        // `email_status(id)` (Phase E, §4.7/§4.7b) — returns exactly one of
        // "sent"/"queued"/"error" (lowercase) for a job ID previously
        // returned by `email_result()`.
        register("email_status") { arguments, context in
            guard let emailProvider = context.emailProvider else {
                throw LassoRuntimeError.emailNotConfigured
            }
            return try await emailProvider.status(arguments, context: context)
        }
        // `email_smtp` (Lasso 9's low-level raw SMTP connection type —
        // `->open`/`->command`/`->send`/`->close`; §4.8b) — registered as
        // BOTH a native type (`NativeTypes.swift`'s `makeEmailSMTPType()`,
        // for member-method dispatch on a constructed object) AND, here,
        // an ordinary free function for the documented
        // `email_smtp(-host=..., -port=..., ...)` with-args constructor
        // form — the exact same two-mechanism split `date`/`email_compose`
        // already use. Bare `email_smtp` (no parens) never reaches this
        // registration at all: `Evaluator.swift`'s `.identifier` case
        // resolves a name matching a registered native type BEFORE
        // checking native functions (see that case's own comment), so a
        // bare reference always constructs an empty object directly. This
        // free function is reached only via the `.call` path
        // (`email_smtp(...)`, with parens) — and, like `date`'s own
        // registration, is pure/synchronous: real Lasso's own worked
        // example (§4.8b) never dials on construction, only `->open`
        // does. Whatever `-host`/`-port`/`-timeout`/`-username`/
        // `-password`/`-ssl`/`-clientIp` are given here are stashed as
        // `_`-prefixed default fields (matching `email_compose`'s
        // `_data`/`_from`/`_recipients` field-naming convention) for
        // `->open` to fall back on when its own arguments omit them —
        // `->open`'s own arguments always take precedence when both are
        // given (§4.8b).
        register("email_smtp") { arguments, _ in
            var data: [String: LassoValue] = [:]
            let fields: [(label: String, field: String)] = [
                ("host", "_host"), ("port", "_port"), ("timeout", "_timeout"),
                ("username", "_username"), ("password", "_password"),
                ("ssl", "_ssl"), ("clientip", "_clientip"),
            ]
            for (label, field) in fields {
                if let value = arguments.lastValue(named: label) {
                    data[field] = value
                }
            }
            return .object(LassoObjectInstance(typeName: "email_smtp", data: data))
        }
        // `email_token(name::string)` (Phase F, §4.9c) -- real Lasso's
        // mail-merge marker-emitting method ("Can be used within the body
        // of an email to insert Lasso email merge tokens"): emits the
        // literal `#TokenName#` marker text into wherever it's called from
        // inside a rendered `-subject`/`-body`/`-html` value.
        // `LassoSMTPMessageBuilder`'s `-tokens`/`-merge` per-recipient
        // substitution pass (`LassoPerfectSMTP`) later replaces every
        // `#TokenName#` occurrence with that recipient's resolved token
        // value -- by the time `LassoSMTPMessageBuilder.build` ever sees
        // the rendered string, this function has already run and returned
        // its marker text, exactly like any other native function call.
        // Pure, synchronous, zero I/O -- the same `date`/`bytes` native-
        // function shape, matching a single-positional-string-argument
        // idiom already used by `email_mxlookup`'s own `domain` argument
        // access (positional first, falling back to a same-named keyword
        // argument). Does NOT dispatch through `LassoEmailProvider` at all
        // -- no provider/relay/network involvement is needed to emit a
        // literal string.
        register("email_token") { arguments, _ in
            let name = arguments.positionalValue(at: 0)?.outputString ?? arguments.firstValue(named: "name")?.outputString ?? ""
            return .string("#\(name)#")
        }
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
        register("generateSeries") { arguments, _ in
            // Ch. "Query Expressions", "GenerateSeries Type":
            // "generateSeries(from, to, by=1) — Creates an integer
            // series. The first parameter specifies the first number in
            // the series. The second parameter specifies the maximum
            // value of the last number in the series... an optional
            // third parameter can specify the step... Note that the
            // second parameter will not be included in the series if
            // the step value causes it to be skipped" — verified
            // against the docs' own worked example: `generateSeries(2,
            // 11, 2) // => 2, 4, 6, 8, 10` (11 excluded). Only positional
            // calling is verified (the docs' own examples never show a
            // labeled `-from=`/`-to=`/`-by=` form). Eagerly materialized
            // into `_elements`, matching the same disclosed eager-
            // evaluation simplification the rest of Query Expressions
            // already uses (`Evaluator.evaluateQueryExpression`'s own
            // doc comment) — a `by` of 0 produces an empty series rather
            // than looping forever, a defensive choice with no doc
            // guidance either way.
            guard let from = arguments.positionalValue(at: 0)?.number.map(Int.init) else { return .void }
            guard let to = arguments.positionalValue(at: 1)?.number.map(Int.init) else { return .void }
            let by = arguments.positionalValue(at: 2)?.number.map(Int.init) ?? 1
            var elements: [LassoValue] = []
            if by > 0 {
                var current = from
                while current <= to {
                    elements.append(.integer(current))
                    current += by
                }
            } else if by < 0 {
                var current = from
                while current >= to {
                    elements.append(.integer(current))
                    current += by
                }
            }
            return .object(LassoObjectInstance(typeName: "generateseries", data: ["_elements": .array(elements)]))
        }
        LassoFileOperations.registerDefaultFunctions(into: &self)
        LassoErrorHandling.registerDefaultFunctions(into: &self)
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
        case .capture:
            // A capture (stored code + a locals snapshot) has no
            // meaningful JSON representation — this conversion exists for
            // session-variable persistence (see this property's own doc
            // comment), and storing a capture in a session isn't a real,
            // documented use case. Falls back to `NSNull()`, matching the
            // `.void`/`.null` case just above, rather than throwing —
            // this property has no `throws` in its signature and every
            // other case already degrades gracefully rather than
            // crashing.
            NSNull()
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
        // `JSONSerialization` boxes every JSON boolean AND every JSON
        // number as `NSNumber` — a real, previously-undiscovered bug
        // here matched `Bool` FIRST via a plain `as?` cast. Per SE-0170
        // (the Swift proposal governing `NSNumber` bridging, in effect
        // since Swift 4), `NSNumber as? Bool` only succeeds for a value
        // of EXACTLY 0 or 1 — converting to `false`/`true` respectively
        // and failing (`nil`) for any other value — confirmed
        // empirically, not just from the proposal text. So the real,
        // narrower bug: any JSON integer/decimal valued exactly 0 or 1
        // (a very plausible real value — flags, counts, ids) was
        // silently misclassified as `.boolean` instead of `.integer`/
        // `.decimal` by this function the whole time it's existed;
        // other values (42, 3.14, -5, ...) were already routed
        // correctly by the old code, since the `as? Bool` cast failed
        // for them and fell through to the `Int`/`Double` cases below.
        // `CFGetTypeID(_:) == CFBooleanGetTypeID()` is the standard,
        // reliable way to tell a real JSON boolean apart from a real
        // JSON number that merely also bridges to `NSNumber` — both are
        // backed by different underlying CoreFoundation types
        // (`CFBoolean` vs `CFNumber`) despite Swift's `as? Bool`/`as?
        // Int`/`as? Double` casts not respecting that distinction for
        // the 0/1 case. `CFNumberIsFloatType(_:)` is the equally
        // standard way to tell whether a JSON number literal had a
        // decimal point (found by testing this exact function's new
        // `json_deserialize` caller — a Map containing both an integer
        // valued 1 and a boolean `true` together surfaced the
        // corruption immediately).
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                .boolean(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                .decimal(value.doubleValue)
            } else {
                .integer(value.intValue)
            }
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

/// A single mutable local-variable storage cell — Stage 3 (Captures, see
/// `Documentation/captures-subsystem-plan.md` §4.2/§4.2(a)): real Lasso's
/// captures need genuine LIVE-REFERENCE closures (Ch. "Captures" §1.5's own
/// worked example: a capture created in one method mutates a local that
/// method later reads back, after the capture is invoked from a completely
/// different method) — a plain `[String: LassoValue]` dictionary (the
/// pre-Stage-3 storage) can't provide this, since copying/snapshotting the
/// dictionary copies the VALUES, not a live link back to the original slot.
/// Boxing every local's storage cell (not just capture-adjacent ones) gives
/// every local variable a stable, referenceable identity: two dictionaries
/// that both hold the SAME box for a given name see each other's writes to
/// it, because the write mutates the shared box object, not the dictionary
/// entry. `LassoCaptureValue.capturedLocals` (`Captures.swift`) stores a
/// snapshot of `LassoContext.locals` taken at the exact moment a capture
/// literal is evaluated — since that snapshot is just a dictionary COPY
/// (cheap, COW) whose VALUES are box references, it shares boxes with the
/// live creating scope for free, with no additional plumbing needed at the
/// capture-literal-evaluation site itself.
///
/// `@unchecked Sendable` with NO internal locking — unlike
/// `LassoCaptureValue`/`LassoObjectInstance`, which both guard their own
/// mutable state with an `NSLock` — because this type sits in the hot path
/// of every single local-variable read/write in the entire evaluator, and a
/// lock there would tax all of it, not just capture-adjacent code. Safety
/// instead rests on a verified structural invariant, not synchronization:
/// every HTTP request builds a brand-new `LassoContext` (never a copy of
/// another in-flight one), the whole render/evaluate pipeline is a single
/// sequential chain of `await`s with no task groups or unstructured `Task`s
/// touching `LassoContext` anywhere, and a `.capture` value (so also its
/// `capturedLocals` boxes) can never survive a session round-trip — session
/// persistence degrades it to `NSNull` (see `jsonObject` below) before it
/// could ever leak a box reference across requests. If a future change ever
/// introduces real concurrency into the render path (parallel `forEach`,
/// background prefetch, a diagnostic `Task` reading `context` mid-render),
/// this box would race silently with no compiler or runtime signal — revisit
/// this design (an `NSLock`, matching its two siblings, is the natural fix)
/// before that happens, not after.
public final class LassoLocalBox: @unchecked Sendable {
    public var value: LassoValue

    public init(_ value: LassoValue) {
        self.value = value
    }
}

public struct LassoContext: Sendable {
    private var globals: [String: LassoValue]
    private var locals: [String: LassoLocalBox]
    // Genuinely separate namespace from `globals` above — see
    // `VariableScope.trueGlobal`'s own doc comment for why.
    private var trueGlobals: [String: LassoValue] = [:]
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
    /// Same wiring convention as `includeRenderService` immediately
    /// above — lets native-type methods that only see `LassoContext`
    /// (not a full `Evaluator`) invoke an already-resolved custom tag
    /// (e.g. a `\TagName` reference, `TagReference.swift`) with
    /// already-evaluated positional arguments. See
    /// `LassoTagInvocationService` in `Providers.swift` for the full
    /// design and its deliberate scope limits.
    public var tagInvocationService: (any LassoTagInvocationService)?
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
    /// The `email_send` dispatch seam (`Documentation/lasso-perfect-smtp-integration-plan.md`
    /// §4.0) — `nil` (the default) makes `email_send` throw
    /// `LassoRuntimeError.emailNotConfigured` rather than silently
    /// no-op'ing, matching how `[inline]` throws `.inlineNotConfigured`
    /// when `inlineProvider` is unset. Populated per-request from a host
    /// application (e.g. `LassoPerfectSMTP`'s conformer, wired in from
    /// `main.swift`) exactly like `inlineProvider`/`sessionProvider`.
    public var emailProvider: (any LassoEmailProvider)?
    /// The job ID `email_send`'s free-function wrapper (`registerDefaultFunctions()`,
    /// below) most recently recorded — backs `email_result()`'s real,
    /// argument-less signature (Phase E, §4.7b: "Can be called immediately
    /// after calling `email_send` to get a unique ID string for the queued
    /// message," with no parameter of its own). Follows `currentError`'s
    /// exact precedent as a plain, request-scoped, directly-settable field
    /// (no stack/restore machinery — job IDs don't nest the way
    /// `[protect]`/`Error_Push` scopes do). `nil` means either "no
    /// `email_send` has been called yet this request" or "the most recent
    /// `email_send` failed before a job was ever recorded" (a pre-send
    /// validation failure, §4.7b's scoping rule) — `email_result()` throws a
    /// clear, catchable error for either case rather than guessing.
    public var lastEmailJobID: String?
    /// Called by `log_critical` with its message text — a hook for the
    /// host application to surface these into its own logging.
    /// `LassoParser` has no direct I/O of its own (same convention as
    /// `requestProvider`/`responseSink`); `nil` (the default) makes
    /// `log_critical` a no-op, matching its behavior before this hook
    /// existed, for callers that don't wire anything.
    public var diagnosticLogSink: (@Sendable (String) async -> Void)?
    /// Called by `stdout`/`stdoutnl` with their already-`asString`-converted
    /// message text (newline already appended for `stdoutnl`) -- real
    /// Lasso's `stdout`/`stdoutnl` (`lassoguide.com/9.2/operations/command-line-tools.html`)
    /// write directly to the process's actual STDOUT stream, a genuinely
    /// different destination from `log_critical`'s `diagnosticLogSink`
    /// (a log facility, not the raw console stream) -- so this is its own
    /// field rather than a reuse. Same "no direct I/O in `LassoParser`
    /// itself" convention as `diagnosticLogSink`/`requestProvider`/
    /// `responseSink`: `nil` (the default) makes `stdout`/`stdoutnl` a
    /// no-op for callers that don't wire anything; the host application
    /// (`LassoPerfectServer`'s `main.swift`) wires this to the real
    /// process stdout.
    public var stdoutSink: (@Sendable (String) async -> Void)?
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
    var givenBlockStack: [LassoValue] = []
    var captureHomeDepthStack: [Int?] = []
    /// Stage 7: parallel to `captureHomeDepthStack`, but holds the actual
    /// `LassoCaptureValue` reference (not just its `homeDepth`) for
    /// whichever capture is CURRENTLY executing — backs `currentCapture()`
    /// and the member-method form of `->givenBlock()`. Pushed/popped
    /// alongside `captureHomeDepthStack` in `Evaluator.invokeCapture`; a
    /// method-tag invocation (not a capture invocation) never pushes here
    /// at all, so `currentCapture()` correctly returns `.void` when called
    /// from ordinary method code with no capture actively executing — a
    /// disclosed partial reading of the real docs' claim that EVERY method
    /// invocation implicitly runs inside its own capture (this codebase
    /// never materializes a `LassoCaptureValue` for a plain method call).
    var currentCaptureStack: [LassoCaptureValue] = []
    /// Ch. "Error Handling" > "handle and handle_failure" — one frame per
    /// active `Renderer.render(_:)` call (pushed/drained there), matching
    /// the Guide's own "container" wording: "When used within any Lasso
    /// capture block, the code inside the handle methods will be
    /// conditionally executed after the capture block is executed" —
    /// since `render(_:)` is the single choke point every capture/block/
    /// page body in this codebase renders through, one frame per call
    /// naturally gives each nested body (a loop iteration, an invoked
    /// capture, the top-level page) its own independent registration
    /// scope, with no separate "what kind of container is this" logic
    /// needed. See `LassoPendingHandler`'s own doc comment for what gets
    /// stored and `Renderer.render(_:)` for where frames are drained.
    var pendingHandlerFrames: [[LassoPendingHandler]] = []

    mutating func pushHandlerFrame() {
        pendingHandlerFrames.append([])
    }

    mutating func registerHandler(_ handler: LassoPendingHandler) {
        guard !pendingHandlerFrames.isEmpty else { return }
        pendingHandlerFrames[pendingHandlerFrames.count - 1].append(handler)
    }

    @discardableResult
    mutating func popHandlerFrame() -> [LassoPendingHandler] {
        pendingHandlerFrames.popLast() ?? []
    }

    /// Ch. "Web Requests and Responses" > "define_atBegin and
    /// define_atEnd": captures registered via `define_atend`, to be run
    /// once at the very end of the CURRENT request — a flat list, not a
    /// frame stack like `pendingHandlerFrames` above, since this is a
    /// documented whole-request concept, not scoped to each nested body
    /// render. See `Evaluator.drainAtEndRegistrations` for where these
    /// actually run.
    var atEndRegistrations: [LassoCaptureValue] = []
    /// Real Lasso's request-local `error_currentError` state — reset to
    /// `.noError` on every fresh context, updated by `setError`/`clearError`.
    /// `lastError` preserves the previous error across a `clearError()` call,
    /// matching how `protect` needs to inspect what failed even after the
    /// catch handler has already reset `currentError` for code that follows.
    public var currentError: LassoErrorState
    public var lastError: LassoErrorState?
    /// `Error_Push`/`Error_Pop` (Ch. 19 Table 3) — a real stack, distinct
    /// from `lastError` above (which only ever remembers one prior
    /// state). Real corpus pattern: pushing before a `Protect` block so
    /// a preexisting error condition can't bleed into it and mistakenly
    /// trigger its own error handling, then popping to restore the
    /// caller's error state afterward.
    var errorStack: [LassoErrorState] = []
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
        emailProvider: (any LassoEmailProvider)? = nil,
        diagnosticLogSink: (@Sendable (String) async -> Void)? = nil,
        stdoutSink: (@Sendable (String) async -> Void)? = nil,
        tagRegistry: LassoTagRegistry = LassoTagRegistry()
    ) {
        self.globals = Dictionary(uniqueKeysWithValues: globals.map { ($0.key.lowercased(), $0.value) })
        // Public init keeps accepting plain `LassoValue`s (external callers,
        // tests) — each gets its own fresh box on the way in.
        self.locals = Dictionary(uniqueKeysWithValues: locals.map { ($0.key.lowercased(), LassoLocalBox($0.value)) })
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
        self.emailProvider = emailProvider
        lastEmailJobID = nil
        self.diagnosticLogSink = diagnosticLogSink
        self.stdoutSink = stdoutSink
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
        errorStack = []
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

    /// `[Error_Push]`: "Pushes the current error condition onto a stack
    /// and resets the current error code and error message."
    public mutating func pushError() {
        errorStack.append(currentError)
        currentError = .noError
    }

    /// `[Error_Pop]`: "Restores the last error condition stored using
    /// [Error_Push]." A pop with nothing pushed is a documented no-op
    /// rather than an error (the tag has no "stack empty" failure mode
    /// in the Guide) — leaves `currentError` untouched.
    public mutating func popError() {
        guard let restored = errorStack.popLast() else { return }
        currentError = restored
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
        get { locals[name.lowercased()]?.value ?? globals[name.lowercased()] ?? .null }
        set { globals[name.lowercased()] = newValue }
    }

    /// Stage 3 (Captures): a `.local` write MUTATES an existing box in
    /// place when one already exists for `name`, rather than replacing the
    /// dictionary entry outright — this is exactly what makes live-
    /// reference closures work. Any capture (or any other scope) that
    /// captured a reference to THIS box earlier sees the new value
    /// immediately, because it's the same object, not a stale copy. Only
    /// when no box exists yet does this create a fresh one.
    public mutating func set(_ value: LassoValue, for name: String, scope: VariableScope) {
        switch scope {
        case .local:
            let key = name.lowercased()
            if let box = locals[key] {
                box.value = value
            } else {
                locals[key] = LassoLocalBox(value)
            }
        case .global, .unscoped: globals[name.lowercased()] = value
        case .trueGlobal: trueGlobals[name.lowercased()] = value
        }
    }

    /// Ch. "Captures" §1.5's own worked example declares `local(my_local)`
    /// (NO initial value) before creating a capture that closes over it,
    /// then assigns it afterward from a completely different method — for
    /// that later assignment to be visible through the ALREADY-CREATED
    /// capture's own captured reference, `my_local`'s box must exist
    /// (holding `.null`) at DECLARATION time, not be deferred until first
    /// assignment. `Evaluator.declare(_:scope:)`'s bare-name (no `=`)
    /// branch calls this for `.local` scope specifically — a plain read
    /// like `(Local: 'name')` doesn't, and normal `local(x) = value`/
    /// `set(_:for:scope:)` already creates a box as a side effect of
    /// writing. A no-op if a box already exists (preserves whatever value
    /// it currently holds).
    mutating func ensureLocalExists(_ name: String) {
        let key = name.lowercased()
        if locals[key] == nil {
            locals[key] = LassoLocalBox(.null)
        }
    }

    // Ch. 15 p.227: "The $ symbol will return a global variable if no
    // page variable of the same name has been created" — `$name` parses
    // straight to `.variable(name, .global)` (ExpressionParser.swift),
    // not `.unscoped`, so the fallback belongs on `.global` itself: a
    // page variable of the same name still wins (checked first), true-
    // global is the fallback. `[Variable: 'name']`'s own read form maps
    // to this same `.global` scope (see `Evaluator.declarationScope(for:)`),
    // so it gets this fallback too — matching the Guide's parallel
    // wording for both: "use the [Variable] tag to retrieve the value
    // of the global variable" when no page variable overrides it.
    // `.unscoped` deliberately does NOT get this fallback: p.225 scopes
    // `Variable_Defined`/`Var_Defined` to "the current Lasso page", and
    // `var_defined`'s free-function registration (this file, above)
    // reads through the `.unscoped` default — an earlier version of
    // this fallback lived on `.unscoped` too and silently made
    // `Var_Defined('x')` report true whenever an unrelated true Global
    // named "x" existed, even with no page variable ever created
    // (caught by architect review, no test previously exercised this).
    public func value(for name: String, scope: VariableScope = .unscoped) -> LassoValue {
        switch scope {
        case .local: locals[name.lowercased()]?.value ?? .null
        case .global: globals[name.lowercased()] ?? trueGlobals[name.lowercased()] ?? .null
        case .trueGlobal: trueGlobals[name.lowercased()] ?? .null
        case .unscoped: locals[name.lowercased()]?.value ?? globals[name.lowercased()] ?? .null
        }
    }

    /// `[Global_Remove]` (Ch. 15 Table 3): "Removes the specified
    /// variable from the globals."
    public mutating func removeTrueGlobal(_ name: String) {
        trueGlobals.removeValue(forKey: name.lowercased())
    }

    /// `[Global_Defined]` (Ch. 15 Table 3): "Returns True if the global
    /// variable has been defined or False otherwise." Mirrors
    /// `var_defined`/`local_defined`'s existing (Runtime.swift,
    /// `registerDefaultFunctions`) treatment of a variable holding
    /// `.null` as "not defined" — the Guide's prose for the page-
    /// variable sibling `[Variable_Defined]` says a Null-valued
    /// variable should still count as defined, but this codebase's
    /// storage can't currently distinguish "never created" from
    /// "created and set to Null" (both collapse to `.null` in
    /// `value(for:)`), and `var_defined`/`local_defined` already made
    /// this same simplification — kept consistent here rather than
    /// introducing a third, differently-behaved variant.
    public func trueGlobalDefined(_ name: String) -> Bool {
        switch trueGlobals[name.lowercased()] {
        case nil, .void, .null: false
        default: true
        }
    }

    /// `[Globals]` (Ch. 15 Table 3): "Returns a map of all global
    /// variables that are currently defined."
    public func trueGlobalsSnapshot() -> [String: LassoValue] {
        trueGlobals
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

    /// Shared by `register("return")`/`register("yield")` — sets the
    /// ordinary return signal exactly like `setReturnSignal(_:)` above,
    /// but ALSO records the currently-executing capture's own home depth
    /// (if any) as the target this signal must unwind back down to
    /// before being consumed. Reading `currentCaptureHomeDepth` (a
    /// double-optional: outer `nil` = not inside any capture invocation
    /// at all right now, inner `nil` = inside one but it's detached) and
    /// flattening both cases to a plain `nil` is exactly what preserves
    /// ordinary, purely-local `return` behavior for every call site that
    /// ISN'T inside a homed capture — the overwhelming majority of real
    /// Lasso code, completely unaffected by this stage.
    ///
    /// No-ops entirely if a return signal is ALREADY live
    /// (`returnSignal != nil`) — found via a real, reproducible hazard:
    /// `[return(givenBlock->invoke(...))]`, where `givenBlock`'s own body
    /// does an explicit `return`/`yield` targeting some ancestor's home.
    /// Evaluating the argument to the OUTER `return(...)` call fires the
    /// INNER capture's non-local return first, which (correctly) isn't
    /// consumed yet because its target hasn't been reached — so the
    /// still-propagating signal is live by the time the OUTER `return`
    /// call itself runs. Without this guard, the outer call would
    /// silently clobber the inner, still-unresolved signal with its own
    /// (built from the inner's throwaway `.void` propagation value, since
    /// expression evaluation has no mid-expression interruption point in
    /// this tree-walking evaluator) — losing the real value entirely. A
    /// signal only becomes live-and-unconsumed this way while a non-local
    /// return is actively unwinding, so this guard never affects ordinary,
    /// ONE-return-at-a-time code.
    mutating func setNonLocalReturnSignal(_ value: LassoValue) {
        guard returnSignal == nil else { return }
        returnSignal = value
        nonLocalReturnTargetDepth = currentCaptureHomeDepth.flatMap { $0 }
    }

    mutating func consumeReturnSignal() -> LassoValue? {
        defer { returnSignal = nil }
        return returnSignal
    }

    /// Shared by every invocation boundary that can be a capture's home —
    /// `Evaluator.invokeCustomTag`/`invokeMemberMethod`/`invokeCapture`,
    /// `RendererTagInvocationService.invoke`, and the top-level
    /// `LassoRenderer.render(_ document:)` page consume — consumes the
    /// return signal produced by the just-finished render call, UNLESS a
    /// non-local target depth is set (Ch. "Captures": `return`/`yield`
    /// "exiting from the current home as well as itself") and doesn't
    /// match THIS frame's own active depth — i.e. some capture's
    /// `return`/`yield` is still unwinding past this frame toward an
    /// ancestor's home. In that case this frame must NOT consume it:
    /// `returnSignal` stays set and `nonLocalReturnTargetDepth` stays
    /// untouched, so the render loop that called THIS frame sees
    /// `shouldStopRenderingCurrentBody()` still true right after this call
    /// returns and keeps unwinding too — propagation happens simply by
    /// every frame in between declining to consume, reusing the EXISTING
    /// poll-based `returnSignal` mechanism rather than any new exception-
    /// based unwinding. `activeDepth` must be measured BEFORE this
    /// frame's own `defer`-scheduled `popTagCall()` runs (i.e. while
    /// `tagCallStack.count` still reflects this frame's own pushed
    /// depth) — every call site does that naturally, since this is always
    /// the last thing evaluated before the function returns. Originally a
    /// private `Evaluator` helper; found (via the direct/non-nested
    /// `#cap()`-at-top-level test regressions below) that TWO OTHER
    /// consume boundaries outside `Evaluator` — the page-level consume in
    /// `Renderer.swift` and `RendererTagInvocationService.invoke` — also
    /// needed this exact same target-aware check, not the old
    /// unconditional `consumeReturnSignal()`; moved here so both files
    /// can share one implementation.
    mutating func consumeReturnSignalRespectingNonLocalTarget(activeDepth: Int) -> LassoValue? {
        if let target = nonLocalReturnTargetDepth, target != activeDepth {
            return nil
        }
        nonLocalReturnTargetDepth = nil
        return consumeReturnSignal()
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

    /// A shallow dictionary copy — cheap (Swift COW) — whose VALUES are
    /// still the same `LassoLocalBox` object references the live scope
    /// holds. Used for two genuinely different purposes that happen to
    /// need the exact same thing: (1) every invocation boundary's own
    /// save-then-restore-my-caller's-locals-across-this-call bookkeeping
    /// (box identity is irrelevant there — the caller's dictionary gets
    /// restored verbatim either way), and (2) `Evaluator`'s `.captureLiteral`
    /// evaluation, which needs the SHARED box references for Stage 3's
    /// live-reference closure semantics (Ch. "Captures" §1.5) — see
    /// `LassoCaptureValue.capturedLocals`'s own doc comment.
    func snapshotLocals() -> [String: LassoLocalBox] {
        locals
    }

    mutating func replaceLocals(_ newLocals: [String: LassoLocalBox]) {
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

    /// The capture (if any) associated with the CURRENT call via `=>`
    /// (Ch. "Captures": "A method that receives an associated block
    /// accesses it via the `givenBlock` keyword"). Stack-based like
    /// `selfStack` just above — every call pushes its OWN given block
    /// (`.void` if it wasn't invoked with one), so a nested call never
    /// sees its caller's given block by accident, and popping restores
    /// the caller's own on return. See `Evaluator.invokeCustomTag`/
    /// `invokeMemberMethod` for where this is pushed/popped.
    var currentGivenBlock: LassoValue {
        givenBlockStack.last ?? .void
    }

    mutating func pushGivenBlock(_ value: LassoValue) {
        givenBlockStack.append(value)
    }

    mutating func popGivenBlock() {
        _ = givenBlockStack.popLast()
    }

    /// The home depth of whichever capture is CURRENTLY executing (top
    /// of a stack, mirroring `givenBlockStack`'s own per-invocation push/
    /// pop discipline — captures can nest, and a `return`/`yield` always
    /// targets the INNERMOST active capture's own home, not some
    /// enclosing one). `nil` at the top of the stack means "the
    /// currently-executing capture is detached, or this isn't inside any
    /// capture invocation at all" — either way, `return`/`yield` firing
    /// right now is a genuinely ORDINARY, purely-local return, exactly
    /// matching this codebase's pre-Stage-2 behavior. See
    /// `Evaluator.invokeCapture` for where this is pushed/popped, and the
    /// `register("return")`/`register("yield")` free functions
    /// (`Runtime.swift`) for where it's read.
    var currentCaptureHomeDepth: Int?? {
        captureHomeDepthStack.last
    }

    mutating func pushCaptureHomeDepth(_ value: Int?) {
        captureHomeDepthStack.append(value)
    }

    mutating func popCaptureHomeDepth() {
        _ = captureHomeDepthStack.popLast()
    }

    /// Stage 7 (`currentCapture()`): the capture actively executing right
    /// now, or `nil` outside any capture invocation. See
    /// `currentCaptureStack`'s own doc comment above.
    var currentCapture: LassoCaptureValue? {
        currentCaptureStack.last
    }

    mutating func pushCurrentCapture(_ value: LassoCaptureValue) {
        currentCaptureStack.append(value)
    }

    mutating func popCurrentCapture() {
        _ = currentCaptureStack.popLast()
    }

    /// Set by `return`/`yield` (Ch. "Captures": "return and yield will
    /// both behave by exiting from the current home as well as itself")
    /// alongside the pre-existing `returnSignal` whenever firing from
    /// inside a HOMED (non-detached) capture invocation — the call-stack
    /// depth (`tagCallStack.count`) that must be reached before the
    /// return signal is actually consumed, rather than just left set so
    /// the next frame up keeps unwinding. `nil` (the default/no-op case)
    /// preserves this codebase's pre-Stage-2 behavior EXACTLY: an
    /// ordinary `return` inside a plain custom tag/type method (never
    /// touched by this field at all) is still always consumed by the
    /// nearest enclosing call boundary, unaffected by anything below.
    /// See `Evaluator.invokeCustomTag`/`invokeMemberMethod`/
    /// `invokeCapture`'s shared "have I reached the target depth yet?"
    /// check for how this is consulted and cleared.
    var nonLocalReturnTargetDepth: Int?

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
    /// `inline(...)`'s `-Host` array specified a `-DataSource` connector
    /// type this build doesn't implement an ad-hoc-connection path for
    /// (only "mysqlds"/"filemakerds", case-insensitive, are recognized
    /// today). Carries the exact `-DataSource` value supplied, so the
    /// error names what was actually requested rather than silently
    /// guessing a backend and sending the wrong credentials to it.
    case unsupportedInlineHostDataSource(String)
    /// Thrown by `email_send` (and any future email-family native function
    /// dispatching through `LassoContext.emailProvider`) when no
    /// `LassoEmailProvider` is configured — mirrors `.inlineNotConfigured`'s
    /// role for `[inline]`/`inlineProvider`. See
    /// `Documentation/lasso-perfect-smtp-integration-plan.md` §4.0.
    case emailNotConfigured
    /// Thrown by `email_compose`'s mutating builder methods
    /// (`->addAttachment`/`->addHTMLPart`/`->addTextPart`/`->addPart`) --
    /// deliberately not implemented this phase (see plan §4.3b/§6 Phase C);
    /// real corpus code chaining these after construction gets a clear,
    /// catchable error rather than a silent no-op or an incorrect result.
    /// Carries the actual method name called (e.g. `"addAttachment"`) so
    /// the error message names exactly what's unsupported. Real until
    /// Phase D resolves the shared native-type-mutation design (§4.8 point
    /// 2) for `email_compose` and `email_smtp` together.
    case emailComposeMutationNotYetSupported(String)
    case fileSystemNotConfigured
    case tagCallDepthExceeded
    case unsafeDynamicFieldName(String)
    /// A custom tag invoked via `LassoTagInvocationService` (internal
    /// dispatch — custom Comparators/Matchers, `Providers.swift`) was
    /// supplied fewer already-evaluated positional arguments than its
    /// own declared parameter count. This narrower invocation path
    /// doesn't evaluate default-parameter expressions (see
    /// `LassoTagInvocationService`'s own doc comment) — an arity
    /// mismatch here is a real authoring error worth failing loudly on,
    /// not silently defaulting through.
    case tagInvocationArityMismatch(String)
    /// `LassoTagInvocationService` (`Providers.swift`) was needed but
    /// `context.tagInvocationService` was `nil` — matches the
    /// established `includeRenderService`/`includeNotConfigured`
    /// convention (`NativeTypes.swift`'s `web_response->include*`
    /// methods): a missing service throws rather than silently
    /// degrading. Found by architect review — `evaluateCustom`
    /// (`Comparators.swift`) originally returned `-1` ("not a valid
    /// comparison") on a nil service, which is indistinguishable from a
    /// legitimately non-matching comparator and would silently make
    /// every `Match_Comparator` wrapping a custom `\TagName` reference
    /// report "no match" for any `LassoContext` built outside
    /// `LassoRenderer`/`RendererEngine` (the only place that wires this
    /// service up).
    case tagInvocationNotConfigured
    /// Thrown by `Evaluator.assign(_:to:defaultScope:)`'s `.member` case
    /// when a raw field assignment (`$obj->fieldName = value`) targets a
    /// NATIVE (Swift-implemented) type instance — `date`/`bytes`/
    /// `web_request`/`web_response`/`email_compose` today, resolved via
    /// `context.nativeTypes.type(named:)`. Found during the Phase C
    /// milestone review: `object.set(_:for:)` was being called
    /// unconditionally with no check at all, so e.g.
    /// `[$message->_data = 'INJECTED']` on an `email_compose` object could
    /// silently overwrite its composed MIME text, completely bypassing
    /// every validation its mutating methods/constructor enforce
    /// (`HeaderEncoder.rejectHeaderInjection`, `MIMEComposer
    /// .sanitizedFilename`, etc.) through a totally different code path.
    /// A native type's `_`-prefixed (or otherwise-named) storage fields are
    /// Swift-implementation details, never meant to be Lasso-visible/
    /// writable directly — the only legitimate way to affect a native
    /// object's state is through its registered native methods. This is
    /// deliberately a distinct case from `.invalidAssignment`: a developer
    /// hitting this needs to understand it's a deliberate restriction, not
    /// a typo/scoping mistake. Contrast with a USER-DEFINED Lasso type
    /// (resolved via `context.tagRegistry.type(named:)`), where
    /// `self->propname = value` / `#instance->propname = value` remains the
    /// real, load-bearing instance-property-mutation mechanism and must
    /// keep working exactly as before. See
    /// `Documentation/lasso-perfect-smtp-integration-plan.md` §4.8 point 2
    /// (the shared native-type-mutation design this finding is adjacent
    /// to) and the Phase C milestone review's BLOCKING FIX #1.
    case nativeTypeFieldAssignmentNotSupported(typeName: String, field: String)
    /// Thrown by `LassoEmailProvider`'s default `smtpOpen`/`smtpCommand`/
    /// `smtpSend`/`smtpClose` implementations (`Providers.swift`) — a
    /// conformer that predates `email_smtp` (Phase D, §4.8b) and never
    /// overrode these four gets a clear, named failure here rather than a
    /// silent no-op. Carries the method name actually called (e.g.
    /// `"open"`). Distinct from `LassoRecoverableError`: a real conformer
    /// (`LassoPerfectSMTP`'s `LassoEmailProviderImpl`) always overrides all
    /// four, so this is only ever reachable from a provider that
    /// deliberately doesn't support `email_smtp` at all — an
    /// adapter-configuration gap, not an ordinary expected runtime failure.
    case emailSMTPNotSupportedByProvider(String)
    /// Thrown by `LassoEmailProvider`'s default `result` implementation
    /// (`Providers.swift`) — a conformer that predates Phase E and never
    /// overrode it. Same "adapter-configuration gap, not an ordinary
    /// expected runtime failure" rationale as `emailSMTPNotSupportedByProvider`.
    case emailResultNotSupportedByProvider
    /// Thrown by `LassoEmailProvider`'s default `status` implementation
    /// (`Providers.swift`) — same rationale as `emailResultNotSupportedByProvider`.
    case emailStatusNotSupportedByProvider
}

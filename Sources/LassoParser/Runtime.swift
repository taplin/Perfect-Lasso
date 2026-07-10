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
        case let .object(value): value.typeName
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
) throws -> LassoValue

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
            .string(arguments.first?.value.outputString ?? "")
        }
        register("integer") { arguments, _ in
            .integer(Int(arguments.first?.value.number ?? 0))
        }
        register("var_defined") { arguments, context in
            let name = arguments.first?.value.outputString ?? ""
            switch context.value(for: name) {
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
        register("log_critical") { _, _ in
            .void
        }
        register("return") { arguments, context in
            context.setReturnSignal(arguments.first?.value ?? .void)
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
        register("action_param") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.requestProvider?.parameter(named: name) ?? .void
        }
        register("cookie") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.requestProvider?.cookie(named: name) ?? .void
        }
        register("session") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            return context.sessionProvider?.value(for: name) ?? .null
        }
        register("session_addvar") { arguments, context in
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            let value = arguments.firstValue(named: "value") ??
                arguments.dropFirst().first?.value ?? context.value(for: name)
            try context.sessionProvider?.set(value, for: name)
            return .void
        }
        register("session_start") { _, _ in .void }
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
            let name = arguments.firstValue(named: "name")?.outputString ??
                arguments.first?.value.outputString ?? ""
            let value = arguments.firstValue(named: "value")?.outputString ??
                arguments.dropFirst().first?.value.outputString ?? ""
            try context.responseSink?.setCookie(name: name, value: value)
            return .void
        }
    }
}

extension LassoValue {
    var jsonObject: Any {
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

public struct LassoContext: Sendable {
    private var globals: [String: LassoValue]
    private var locals: [String: LassoValue]
    private var inlineFrames: [ActiveInlineFrame]
    public var natives: LassoNativeRegistry
    public var nativeTypes: LassoNativeTypeRegistry
    public var includeLoader: (any LassoIncludeLoader)?
    public var includePath: String?
    public var includeStack: [String]
    public var requestProvider: (any LassoRequestProvider)?
    public var sessionProvider: (any LassoSessionProvider)?
    public var responseSink: (any LassoResponseSink)?
    public var inlineProvider: (any LassoInlineProvider)?
    public var tagRegistry: LassoTagRegistry
    /// Paths already processed by `library()` for THIS request's render —
    /// deliberately per-`LassoContext`, not on the shared `tagRegistry`.
    /// LassoSoft's `library_once` docs scope the "only the first call does
    /// anything" dedup to a single page's own render, not the server
    /// process's lifetime.
    var loadedLibraries: Set<String>
    var returnSignal: LassoValue?
    var tagCallStack: [String]
    var selfStack: [LassoObjectInstance]

    public init(
        globals: [String: LassoValue] = [:],
        locals: [String: LassoValue] = [:],
        natives: LassoNativeRegistry = LassoNativeRegistry(),
        nativeTypes: LassoNativeTypeRegistry = LassoNativeTypeRegistry(),
        includeLoader: (any LassoIncludeLoader)? = nil,
        includePath: String? = nil,
        requestProvider: (any LassoRequestProvider)? = nil,
        sessionProvider: (any LassoSessionProvider)? = nil,
        responseSink: (any LassoResponseSink)? = nil,
        inlineProvider: (any LassoInlineProvider)? = nil,
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
        self.requestProvider = requestProvider
        self.sessionProvider = sessionProvider
        self.responseSink = responseSink
        self.inlineProvider = inlineProvider
        self.tagRegistry = tagRegistry
        loadedLibraries = []
        returnSignal = nil
        tagCallStack = []
        selfStack = []
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

    public var currentRow: LassoDataRow? {
        inlineFrames.last?.currentRow
    }

    mutating func pushInlineFrame(_ frame: LassoInlineFrame) {
        inlineFrames.append(ActiveInlineFrame(frame: frame, currentRow: nil))
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
}

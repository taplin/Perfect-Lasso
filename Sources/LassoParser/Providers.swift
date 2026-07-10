import Foundation

public struct LassoDataRow: Equatable, Sendable {
    private let values: [String: LassoValue]

    public init(_ values: [String: LassoValue]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
    }

    public subscript(_ name: String) -> LassoValue {
        values[name.lowercased()] ?? .null
    }

    public var mapValue: [String: LassoValue] {
        values
    }
}

/// Real Lasso's request-local current-error state, exposed to Lasso code via
/// `error_currentError`. `code: 0`/`kind: "none"` is real Lasso's "No Error"
/// state — the default for every fresh context and every successful inline
/// action. Numeric codes beyond 0 are deliberately not assigned yet (see
/// `Documentation/error-protect-model-plan.md`'s Milestone 1) — real Lasso
/// 8.5's exact Error Control chapter codes still need extracting from the
/// local reference PDF before those are hardcoded here.
public struct LassoErrorState: Equatable, Sendable {
    public var code: Int
    public var message: String
    public var kind: String
    public var detail: String?

    public init(code: Int, message: String, kind: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.kind = kind
        self.detail = detail
    }

    public static let noError = LassoErrorState(code: 0, message: "No Error", kind: "none")
}

/// A recoverable Lasso-level failure — the only error type `protect` catches.
/// Deliberately distinct from ordinary Swift `throw`s used elsewhere in this
/// runtime for fatal adapter/parser bugs (`LassoRuntimeError`) and from the
/// `returnSignal` short-circuit used for `return`/`abort` control flow —
/// `protect` must catch this and only this, per
/// `Documentation/error-protect-model-plan.md`'s three-way error/control-flow/
/// fatal split.
public struct LassoRecoverableError: Error, Equatable, Sendable {
    public var state: LassoErrorState

    public init(_ state: LassoErrorState) {
        self.state = state
    }
}

public struct LassoInlineFrame: Equatable, Sendable {
    public let rows: [LassoDataRow]
    public let foundCount: Int
    public let affectedRows: Int
    public let actionStatement: String?
    public let error: LassoErrorState

    public init(
        rows: [LassoDataRow],
        foundCount: Int? = nil,
        affectedRows: Int = 0,
        actionStatement: String? = nil,
        error: LassoErrorState = .noError
    ) {
        self.rows = rows
        self.foundCount = foundCount ?? rows.count
        self.affectedRows = affectedRows
        self.actionStatement = actionStatement
        self.error = error
    }
}

public enum LassoInlineAction: String, Equatable, Sendable {
    case search
    case find
    case findAll
    case add
    case update
    case delete
    case show
    case prepare
    case nothing
    case rawSQL
    case unknown
}

public struct LassoInlineCriterion: Equatable, Sendable {
    public let field: String
    public let operation: String
    public let value: LassoValue

    public init(field: String, operation: String, value: LassoValue) {
        self.field = field
        self.operation = operation
        self.value = value
    }
}

public struct LassoInlineRequest: Equatable, Sendable {
    public let action: LassoInlineAction
    public let database: String?
    public let table: String?
    public let sql: String?
    public let returnFields: [String]
    public let sortFields: [String]
    public let sortOrders: [String]
    public let maxRecords: Int?
    public let skipRecords: Int?
    public let keyField: String?
    public let keyValue: LassoValue?
    public let criteria: [LassoInlineCriterion]
    public let rawArguments: [EvaluatedArgument]

    public init(arguments: [EvaluatedArgument]) {
        rawArguments = arguments
        database = arguments.lastString(named: "database")
        table = arguments.lastString(named: "table")
        sql = arguments.lastString(named: "sql")
        returnFields = arguments.strings(named: "returnfield")
        sortFields = arguments.strings(named: "sortfield")
        sortOrders = arguments.strings(named: "sortorder")
        maxRecords = arguments.lastInt(named: "maxrecords")
        skipRecords = arguments.lastInt(named: "skiprecords")
        keyField = arguments.lastString(named: "keyfield")
        keyValue = arguments.lastValue(named: "keyvalue")

        if sql != nil {
            action = .rawSQL
        } else if arguments.hasTruthyFlag("search") {
            action = .search
        } else if arguments.hasTruthyFlag("find") {
            action = .find
        } else if arguments.hasTruthyFlag("findall") {
            action = .findAll
        } else if arguments.hasTruthyFlag("add") {
            action = .add
        } else if arguments.hasTruthyFlag("update") {
            action = .update
        } else if arguments.hasTruthyFlag("delete") {
            action = .delete
        } else if arguments.hasTruthyFlag("show") {
            action = .show
        } else if arguments.hasTruthyFlag("prepare") {
            action = .prepare
        } else if arguments.hasTruthyFlag("nothing") {
            action = .nothing
        } else {
            action = .unknown
        }

        let operations = arguments.strings(named: "op")
        let reserved = Self.reservedNames
        let fieldArguments = arguments.filter { argument in
            guard let label = argument.label?.lowercased() else { return false }
            return !reserved.contains(label)
        }
        criteria = fieldArguments.enumerated().map { index, argument in
            LassoInlineCriterion(
                field: argument.label ?? "",
                operation: operations.indices.contains(index) ? operations[index] : "eq",
                value: argument.value
            )
        }
    }

    private static let reservedNames: Set<String> = [
        "search", "find", "findall", "add", "update", "delete", "show", "prepare", "nothing",
        "database", "table", "sql", "returnfield", "sortfield", "sortorder", "maxrecords",
        "skiprecords", "keyfield", "keyvalue", "op", "username", "password",
    ]
}

public protocol LassoIncludeLoader: Sendable {
    func loadInclude(path: String, from includingPath: String?) throws -> String
}

public struct LassoFileSystemIncludeLoader: LassoIncludeLoader {
    public let root: URL
    public let allowedExtensions: Set<String>

    public init(
        root: URL,
        allowedExtensions: Set<String> = ["lasso", "inc", "html", "htm", "txt"]
    ) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LassoFileSystemIncludeError.invalidRoot(resolvedRoot.path)
        }
        self.root = resolvedRoot
        self.allowedExtensions = Set(allowedExtensions.map { $0.lowercased() })
    }

    public func loadInclude(path: String, from includingPath: String?) throws -> String {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var bases: [URL] = [root]
        if !path.hasPrefix("/"), let includingPath {
            // includingPath is stored verbatim from whatever the including
            // file passed to include()/library() — real Lasso source
            // overwhelmingly uses the leading-slash, site-root-relative
            // style (e.g. include('/includes/b2b/siteconfig_cookies.inc')).
            // URL(fileURLWithPath:relativeTo:) treats any string starting
            // with "/" as a literal filesystem absolute path and silently
            // ignores relativeTo, so an un-stripped leading slash here
            // resolved the parent directory against the real filesystem
            // root instead of the site root — every subsequent relative
            // include() from inside that file then failed pathOutsideRoot.
            let normalizedIncludingPath = includingPath.hasPrefix("/")
                ? String(includingPath.dropFirst())
                : includingPath
            let parent = URL(fileURLWithPath: normalizedIncludingPath, relativeTo: root)
                .deletingLastPathComponent()
            bases.insert(parent, at: 0)
        }

        for base in bases {
            let candidate = base.appendingPathComponent(normalizedPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard isWithinRoot(candidate) else {
                throw LassoFileSystemIncludeError.pathOutsideRoot(path)
            }
            let fileExtension = candidate.pathExtension.lowercased()
            guard allowedExtensions.isEmpty || allowedExtensions.contains(fileExtension) else {
                throw LassoFileSystemIncludeError.extensionNotAllowed(fileExtension)
            }
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            do {
                return try String(contentsOf: candidate, encoding: .utf8)
            } catch {
                throw LassoFileSystemIncludeError.unreadableFile(path)
            }
        }
        throw LassoFileSystemIncludeError.fileNotFound(path)
    }

    private func isWithinRoot(_ candidate: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}

public enum LassoFileSystemIncludeError: Error, Equatable, Sendable {
    case invalidRoot(String)
    case pathOutsideRoot(String)
    case extensionNotAllowed(String)
    case fileNotFound(String)
    case unreadableFile(String)
}

/// A single ordered name/value pair from a request's query string or POST
/// body. Real Lasso's `params()`/`postParams()`/`queryParams()` are
/// documented as ordered, duplicate-preserving collections (POST occurring
/// before GET in the combined form) — plain dictionaries lose ordering and
/// silently drop duplicate names. `LassoRequestProvider.postPairs`/
/// `queryPairs` below are the ordered source of truth; the existing
/// dictionary-shaped `parameters`/`queryParameters`/`postParameters`
/// properties stay as convenience projections (first-value-wins per name)
/// for callers that only need simple lookup.
public struct LassoRequestPair: Equatable, Sendable {
    public var name: String
    public var value: LassoValue

    public init(name: String, value: LassoValue) {
        self.name = name
        self.value = value
    }
}

/// Metadata for one `multipart/form-data` file upload — see
/// `Documentation/session-upload-support-plan.md`. Deliberately just
/// metadata, not the file's bytes: real Lasso exposes uploads the same way
/// (`web_request->fileUploads()`/Lasso 8's `[File_Uploads]`), backed by a
/// server-side temporary file Lasso code can then read/move itself. The
/// temporary file's actual lifetime is a server-boundary concern (Perfect-
/// NIO's `MimeReader` deletes its temp files on deinit) — this type only
/// carries where that file currently lives, per `temporaryFilename`.
public struct LassoUploadedFile: Equatable, Sendable {
    public var fieldName: String
    public var contentType: String
    public var originalFilename: String
    public var temporaryFilename: String
    public var size: Int

    public init(
        fieldName: String,
        contentType: String,
        originalFilename: String,
        temporaryFilename: String,
        size: Int
    ) {
        self.fieldName = fieldName
        self.contentType = contentType
        self.originalFilename = originalFilename
        self.temporaryFilename = temporaryFilename
        self.size = size
    }
}

/// Real Lasso's `web_request` exposes ~35 documented members (see
/// `Documentation/compatibility-matrix.md`); this protocol only requires
/// the handful every conformer must supply, with default (empty/zero/false)
/// implementations for the rest via the extension below — so existing
/// conformers (test fixtures, `SmokeRequestProvider`) keep compiling
/// unchanged, and only a real, live-traffic conformer needs to override
/// the defaults with actual data.
public protocol LassoRequestProvider: Sendable {
    func parameter(named name: String) -> LassoValue
    func header(named name: String) -> LassoValue
    func cookie(named name: String) -> LassoValue
    var parameters: [String: LassoValue] { get }
    var headers: [String: LassoValue] { get }
    var cookies: [String: LassoValue] { get }
    var queryParameters: [String: LassoValue] { get }
    var postParameters: [String: LassoValue] { get }
    var queryPairs: [LassoRequestPair] { get }
    var postPairs: [LassoRequestPair] { get }
    var rawPostString: String { get }
    var uploadedFiles: [LassoUploadedFile] { get }
    var requestMethod: String { get }
    var requestURI: String { get }
    var path: String { get }
    var isHTTPS: Bool { get }
    var remoteAddress: String { get }
    var remotePort: Int { get }
    var serverName: String { get }
    var serverPort: Int { get }
    var contentType: String { get }
    var contentLength: Int { get }
}

public extension LassoRequestProvider {
    var headers: [String: LassoValue] { [:] }
    var cookies: [String: LassoValue] { [:] }
    var queryParameters: [String: LassoValue] { parameters }
    var postParameters: [String: LassoValue] { [:] }
    var queryPairs: [LassoRequestPair] { [] }
    var postPairs: [LassoRequestPair] { [] }
    var rawPostString: String { "" }
    var uploadedFiles: [LassoUploadedFile] { [] }
    var requestMethod: String { "" }
    var requestURI: String { "" }
    var path: String { "" }
    var isHTTPS: Bool { false }
    var remoteAddress: String { "" }
    var remotePort: Int { 0 }
    var serverName: String { "" }
    var serverPort: Int { 0 }
    var contentType: String { "" }
    var contentLength: Int { 0 }
}

public protocol LassoSessionProvider: Sendable {
    func value(for name: String) -> LassoValue
    func set(_ value: LassoValue, for name: String) throws
}

/// Real Lasso's `web_response` exposes ~20 documented members; same
/// default-implementation pattern as `LassoRequestProvider` above so
/// existing conformers are unaffected.
public protocol LassoResponseSink: Sendable {
    func setStatus(_ status: Int) throws
    func redirect(to url: String) throws
    func setCookie(name: String, value: String) throws
    func setHeader(name: String, value: String) throws
    func setCookie(
        name: String,
        value: String,
        domain: String?,
        expires: String?,
        path: String?,
        secure: Bool,
        httpOnly: Bool
    ) throws
    func getStatus() -> Int
}

public extension LassoResponseSink {
    func setHeader(name: String, value: String) throws {}
    func setCookie(
        name: String,
        value: String,
        domain: String?,
        expires: String?,
        path: String?,
        secure: Bool,
        httpOnly: Bool
    ) throws {
        try setCookie(name: name, value: value)
    }
    func getStatus() -> Int { 200 }
}

public protocol LassoInlineProvider: Sendable {
    func executeInline(arguments: [EvaluatedArgument], context: LassoContext) throws -> LassoInlineFrame
}

public protocol LassoDynamicQueryExecutor: Sendable {
    func execute(_ request: LassoInlineRequest) throws -> LassoInlineFrame
}

public struct LassoDynamicInlineProvider: LassoInlineProvider {
    public let executor: any LassoDynamicQueryExecutor
    public let datasourceAliases: [String: String]

    public init(
        executor: any LassoDynamicQueryExecutor,
        datasourceAliases: [String: String] = [:]
    ) {
        self.executor = executor
        self.datasourceAliases = Dictionary(
            uniqueKeysWithValues: datasourceAliases.map { ($0.key.lowercased(), $0.value) }
        )
    }

    public func executeInline(
        arguments: [EvaluatedArgument],
        context: LassoContext
    ) throws -> LassoInlineFrame {
        let request = LassoInlineRequest(arguments: arguments)
        let mappedRequest: LassoInlineRequest
        if let database = request.database,
           let mappedDatabase = datasourceAliases[database.lowercased()] {
            mappedRequest = request.replacingDatabase(with: mappedDatabase)
        } else {
            mappedRequest = request
        }
        return try executor.execute(mappedRequest)
    }
}

public struct LassoInMemoryInlineProvider: LassoInlineProvider {
    private let tables: [String: [LassoDataRow]]

    public init(tables: [String: [LassoDataRow]]) {
        self.tables = Dictionary(uniqueKeysWithValues: tables.map { ($0.key.lowercased(), $0.value) })
    }

    public func executeInline(arguments: [EvaluatedArgument], context: LassoContext) throws -> LassoInlineFrame {
        let request = LassoInlineRequest(arguments: arguments)
        guard request.action != .nothing else { return LassoInlineFrame(rows: []) }
        guard let table = request.table?.lowercased(), var rows = tables[table] else {
            return LassoInlineFrame(rows: [])
        }

        rows = rows.filter { row in
            request.criteria.allSatisfy { criterion in
                compare(row[criterion.field], criterion.operation, criterion.value)
            }
        }

        if let sortField = request.sortFields.first {
            let descending = request.sortOrders.first?.lowercased().contains("desc") == true
            rows.sort {
                descending
                    ? $0[sortField].outputString > $1[sortField].outputString
                    : $0[sortField].outputString < $1[sortField].outputString
            }
        }

        if let skip = request.skipRecords, skip > 0 {
            rows = Array(rows.dropFirst(skip))
        }
        if let max = request.maxRecords, max >= 0 {
            rows = Array(rows.prefix(max))
        }

        return LassoInlineFrame(rows: rows)
    }

    private func compare(_ left: LassoValue, _ operation: String, _ right: LassoValue) -> Bool {
        let normalized = operation.lowercased()
        switch normalized {
        case "eq", "equals", "=":
            return left.outputString == right.outputString
        case "neq", "ne", "notequals", "!=":
            return left.outputString != right.outputString
        case "gt", ">":
            return (left.number ?? 0) > (right.number ?? 0)
        case "gte", ">=":
            return (left.number ?? 0) >= (right.number ?? 0)
        case "lt", "<":
            return (left.number ?? 0) < (right.number ?? 0)
        case "lte", "<=":
            return (left.number ?? 0) <= (right.number ?? 0)
        case "bw", "beginswith":
            return left.outputString.hasPrefix(right.outputString)
        case "ew", "endswith":
            return left.outputString.hasSuffix(right.outputString)
        case "cn", "contains":
            return left.outputString.contains(right.outputString)
        default:
            return left.outputString == right.outputString
        }
    }
}

private extension LassoInlineRequest {
    func replacingDatabase(with database: String) -> LassoInlineRequest {
        var arguments = rawArguments
        if let index = arguments.lastIndex(where: {
            $0.label?.caseInsensitiveCompare("database") == .orderedSame
        }) {
            arguments[index] = EvaluatedArgument(label: arguments[index].label, value: .string(database))
        } else {
            arguments.append(EvaluatedArgument(label: "database", value: .string(database)))
        }
        return LassoInlineRequest(arguments: arguments)
    }
}

struct ActiveInlineFrame: Equatable, Sendable {
    let frame: LassoInlineFrame
    var currentRow: LassoDataRow?
}

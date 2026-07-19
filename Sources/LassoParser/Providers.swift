import Foundation

public struct LassoDataRow: Equatable, Sendable {
    private let values: [String: LassoValue]
    /// The row's key/record-id value, for real Lasso's `KeyField_Value`
    /// builtin. Real FileMaker rows always have one (the internal record
    /// ID, never a named field `field()`/`column()` could already read —
    /// see `Documentation/lasso-perfect-server.md`'s FileMaker datasource
    /// section); MySQL rows have no equivalent concept wired up yet
    /// (`nil`, since no corpus evidence any MySQL page relies on it).
    public let keyValue: LassoValue?

    public init(_ values: [String: LassoValue], keyValue: LassoValue? = nil) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
        self.keyValue = keyValue
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
    /// `nil` when the criterion's `-Op` argument was omitted entirely —
    /// distinct from an explicit `-Op='EQ'`. Real Lasso 8.5's default
    /// comparison operator differs by datasource connector (SQL connectors
    /// default to `-EQ`; the FileMaker connector documents `-BW`, Ch. 11
    /// Table 4), so each executor applies its own default rather than one
    /// being baked in here.
    public let operation: String?
    public let value: LassoValue

    public init(field: String, operation: String?, value: LassoValue) {
        self.field = field
        self.operation = operation
        self.value = value
    }
}

/// One `-Not`-delimited group of search criteria. Real Lasso's FileMaker
/// connector documents `-Not` as negating the entire compound query group
/// that follows it (there's no per-criterion `-NEQ`) — confirmed by real
/// corpus usage: `pages/order_history.page.lasso`/`pages/order_reporting.page.lasso`
/// each use exactly one bare `-Not` to split one search into "cust_id = X"
/// (not negated) and "status = 'unchecked'" (negated). `LassoInlineRequest.criteria`
/// stays flat and negation-oblivious for existing MySQL-shaped consumers
/// (`PerfectCRUDLassoExecutor` has no negation concept); this grouped view
/// is for FileMaker-style consumers that do.
public struct LassoInlineCriteriaGroup: Equatable, Sendable {
    public let criteria: [LassoInlineCriterion]
    public let negated: Bool

    public init(criteria: [LassoInlineCriterion], negated: Bool) {
        self.criteria = criteria
        self.negated = negated
    }
}

/// A single column value to write, distinct from `LassoInlineCriterion`
/// (a search predicate) even though both are name/value-argument-shaped in
/// real Lasso source — see `Documentation/inline-write-raw-sql-plan.md`'s
/// "Why split assignments from criteria." In `-Add`/`-Update`, unlabeled
/// name/value arguments are values to write, not predicates to match.
public struct LassoInlineAssignment: Equatable, Sendable {
    public let field: String
    public let value: LassoValue

    public init(field: String, value: LassoValue) {
        self.field = field
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
    /// The same criteria, split into `-Not`-delimited groups. See
    /// `LassoInlineCriteriaGroup`'s doc comment. Populated for every
    /// action (harmless — a request with no `-Not` produces exactly one
    /// non-negated group whose `criteria` matches `criteria` above), but
    /// only meaningfully consumed by search-shaped actions.
    public let criteriaGroups: [LassoInlineCriteriaGroup]
    /// `-StatementOnly` — generate the statement/predicates but don't
    /// execute the action. See `PerfectCRUDLassoExecutor`.
    public let statementOnly: Bool
    /// Populated only for `.add`/`.update` — non-reserved name/value
    /// arguments as values to write, not search criteria. Empty for every
    /// other action, including `.search`/`.find`/`.findAll` (where
    /// `criteria` above is still what those same arguments mean).
    public let fieldAssignments: [LassoInlineAssignment]
    /// The predicate identifying which record(s) `.update`/`.delete`
    /// target — built from `-KeyField`/`-KeyValue` (a single equality
    /// criterion), not from the field/value arguments (those are
    /// `fieldAssignments` for `.update`, ignored entirely for `.delete`).
    /// `-Key` array-based targeting is deliberately not implemented yet —
    /// deferred pending stronger pair/staticarray support in `LassoValue`,
    /// per the plan's own "Recommended first-pass mapping."
    public let writeCriteria: [LassoInlineCriterion]
    public let rawArguments: [EvaluatedArgument]

    public init(arguments: [EvaluatedArgument]) throws {
        rawArguments = arguments
        database = arguments.lastString(named: "database")
        // `-Table`/`-ReturnField`/`-SortField`/`-KeyField` values all
        // eventually become raw SQL identifiers (DynamicQuery/
        // DynamicMutation.table, DynamicQuery.fields, DynamicOrdering.field,
        // DynamicPredicate.field via keyField) in PerfectCRUDLassoExecutor.
        // Validated unconditionally here, regardless of action (including
        // .rawSQL, where these fields are simply unused) — matching how
        // they're already parsed unconditionally today, and how
        // Evaluator.swift's `#var = value` dynamic label already validates
        // unconditionally rather than branching on action.
        table = arguments.lastString(named: "table")
        if let table { try Evaluator.validateDynamicFieldLabel(table) }
        sql = arguments.lastString(named: "sql")
        returnFields = arguments.strings(named: "returnfield")
        try returnFields.forEach { try Evaluator.validateDynamicFieldLabel($0) }
        sortFields = arguments.strings(named: "sortfield")
        try sortFields.forEach { try Evaluator.validateDynamicFieldLabel($0) }
        sortOrders = arguments.strings(named: "sortorder")
        maxRecords = arguments.lastInt(named: "maxrecords")
        skipRecords = arguments.lastInt(named: "skiprecords")
        keyField = arguments.lastString(named: "keyfield")
        if let keyField { try Evaluator.validateDynamicFieldLabel(keyField) }
        keyValue = arguments.lastValue(named: "keyvalue")
        statementOnly = arguments.hasTruthyFlag("statementonly")

        let action: LassoInlineAction
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
        self.action = action

        // `-Op='cn'` and bare `-Cn` are the same real Lasso/FileMaker CWP
        // comparison-operator syntax — the bare form is shorthand for the
        // matching `-Op=` value (`-Eq`/`-Cn`/`-Bw`/`-Ew`/`-Gt`/`-Gte`/`-Lt`/
        // `-Lte`/`-Neq`, matching every alias `PerfectCRUDLassoExecutor`'s
        // `comparison(_:)` recognizes).
        //
        // A real `-Op` (or bare alias) applies to every field argument that
        // follows it, not just the one immediately after — it stays in
        // effect until the next `-Op`/alias overrides it. Found live via
        // pages/thumbs.page.lasso: `-op='cn', 'product_name'=$keyword,
        // 'special'=$show_specials, 'closeout'=$show_closeouts` has no
        // `-op` between `product_name` and `special`/`closeout`, so real
        // Lasso carries `cn` forward to all three. The previous
        // implementation zipped a flat `operations` array positionally
        // against field arguments (index N's field got operations[N]),
        // which silently fell back to the default `Eq` for any field not
        // immediately preceded by its own `-op` — corrupting queries whose
        // trailing fields relied on an earlier operator carrying forward
        // (here, turning `special LIKE '%%'`/`closeout LIKE '%%'`, which
        // real Lasso treats as "no constraint" for a blank filter value,
        // into `special = ''`/`closeout = ''`, which matches nothing and
        // silently zeroed out every product search).
        let reserved = Self.reservedNames
        var currentOperation: String?
        func trackOperation(_ label: String, _ argument: EvaluatedArgument) -> Bool {
            // `-Operator` is real Lasso 8/FileMaker CWP's longhand alias for
            // `-Op` (both accepted, same meaning). Real corpus:
            // pages/category_map.page.lasso's
            // `-Operator='cn', 'store_id'=$search_store` — since
            // "operator" wasn't recognized, it fell into fieldArguments as
            // a literal `LassoInlineCriterion(field: "operator", ...)`,
            // corrupting the generated SQL with a nonexistent `operator`
            // column and silently failing the entire query (the whole
            // Site Map page renders empty behind that one failed inline).
            if label == "op" || label == "operator" {
                currentOperation = argument.value.outputString
                return true
            }
            if Self.comparisonAliases.contains(label) {
                currentOperation = label
                return true
            }
            return false
        }

        var flatCriteria: [LassoInlineCriterion] = []
        var fieldArguments: [EvaluatedArgument] = []
        for argument in arguments {
            guard let label = argument.label?.lowercased() else { continue }
            if trackOperation(label, argument) { continue }
            guard !reserved.contains(label) else { continue }
            fieldArguments.append(argument)
            flatCriteria.append(LassoInlineCriterion(field: argument.label ?? "", operation: currentOperation, value: argument.value))
        }
        criteria = flatCriteria

        // Second pass over the full (unfiltered) argument list — unlike
        // `criteria` above, this needs each field argument's position
        // relative to any `-Not` markers, which filtering to
        // `fieldArguments` first would discard. Operator state is tracked
        // independently here (a `-Not` doesn't reset it) with the same
        // carry-forward semantics as above.
        var groups: [LassoInlineCriteriaGroup] = []
        var currentGroup: [LassoInlineCriterion] = []
        var currentGroupNegated = false
        currentOperation = nil
        for argument in arguments {
            guard let lowercasedLabel = argument.label?.lowercased() else { continue }
            if lowercasedLabel == "not" {
                if !currentGroup.isEmpty {
                    groups.append(LassoInlineCriteriaGroup(criteria: currentGroup, negated: currentGroupNegated))
                }
                currentGroup = []
                currentGroupNegated = true
                continue
            }
            if trackOperation(lowercasedLabel, argument) { continue }
            guard !reserved.contains(lowercasedLabel) else { continue }
            currentGroup.append(LassoInlineCriterion(field: argument.label ?? "", operation: currentOperation, value: argument.value))
        }
        if !currentGroup.isEmpty {
            groups.append(LassoInlineCriteriaGroup(criteria: currentGroup, negated: currentGroupNegated))
        }
        criteriaGroups = groups

        switch action {
        case .add:
            fieldAssignments = fieldArguments.map {
                LassoInlineAssignment(field: $0.label ?? "", value: $0.value)
            }
            writeCriteria = []
        case .update:
            fieldAssignments = fieldArguments.map {
                LassoInlineAssignment(field: $0.label ?? "", value: $0.value)
            }
            if let keyField, let keyValue {
                writeCriteria = [LassoInlineCriterion(field: keyField, operation: "eq", value: keyValue)]
            } else {
                writeCriteria = []
            }
        case .delete:
            fieldAssignments = []
            if let keyField, let keyValue {
                writeCriteria = [LassoInlineCriterion(field: keyField, operation: "eq", value: keyValue)]
            } else {
                writeCriteria = []
            }
        default:
            fieldAssignments = []
            writeCriteria = []
        }
    }

    private static let reservedNames: Set<String> = Set<String>([
        "search", "find", "findall", "add", "update", "delete", "show", "prepare", "nothing",
        "database", "table", "sql", "returnfield", "sortfield", "sortorder", "maxrecords",
        "skiprecords", "keyfield", "keyvalue", "op", "operator", "username", "password", "statementonly",
        // A bare `-Not` flag (real corpus: order_history.page.lasso,
        // order_reporting.page.lasso) negates a query group — it is not
        // itself a field name. Without this, it fell into fieldArguments
        // and produced a bogus `LassoInlineCriterion(field: "not", ...)`,
        // silently corrupting both the criteria list and the -Op
        // positional alignment for every criterion after it.
        "not",
    ]).union(comparisonAliases)

    /// Bare comparison-operator shorthand flags — `-Cn` is real Lasso/
    /// FileMaker CWP syntax for the same thing as `-Op='cn'` (real corpus:
    /// pages/subcats.page.lasso's bare `-cn,`). Matches every alias
    /// `PerfectCRUDLassoExecutor.comparison(_:)` recognizes for the
    /// explicit `-Op=` value form, so both spellings behave identically.
    private static let comparisonAliases: Set<String> = [
        "eq", "equals", "neq", "ne", "notequals", "gt", "gte", "lt", "lte",
        "bw", "beginswith", "ew", "endswith", "cn", "contains",
    ]
}

public protocol LassoIncludeLoader: Sendable {
    func loadInclude(path: String, from includingPath: String?) throws -> String
    /// Raw bytes for `web_response->includeBytes` — a sibling of
    /// `loadInclude` sharing the exact same path-resolution/root-
    /// confinement/extension-allowlist policy, just reading the file as
    /// data instead of decoding it as UTF-8 text. Defaulted so existing
    /// conformers (test/smoke loaders predating `includeBytes`) don't
    /// need to change; only `LassoFileSystemIncludeLoader` implements it
    /// for real. See Documentation/web-response-include-plan.md.
    func loadIncludeBytes(path: String, from includingPath: String?) throws -> Data

    /// The confined filesystem root `File_*` tags (`FileOperations.swift`)
    /// resolve absolute paths against and refuse to escape — deliberately
    /// reusing the SAME root every `include()`/`library()` call is already
    /// confined to, rather than introducing a second, potentially-
    /// inconsistent root concept. Defaulted to `nil` so existing
    /// conformers (test/smoke loaders, and any loader with no real
    /// on-disk root) don't need to change and simply leave `File_*` tags
    /// unconfigured (they throw `fileSystemNotConfigured` — see
    /// `FileOperations.swift`) — matching `loadIncludeBytes`'s own
    /// default-then-override pattern above.
    var fileSystemRoot: URL? { get }
}

public extension LassoIncludeLoader {
    func loadIncludeBytes(path: String, from includingPath: String?) throws -> Data {
        throw LassoRuntimeError.includeNotConfigured
    }

    var fileSystemRoot: URL? { nil }
}

public struct LassoFileSystemIncludeLoader: LassoIncludeLoader {
    public let root: URL
    public var fileSystemRoot: URL? { root }
    public let allowedExtensions: Set<String>

    public init(
        root: URL,
        // Real Lasso's `[Include(...)]`/`[Include_currentpath(...)]` tags
        // have no extension gate at all — they render whatever file the
        // path resolves to (parsing any embedded `[...]` tags, passing the
        // rest through as literal text) regardless of extension. Real
        // corpus: pages/detail.page.lasso's
        // `[include('javascripts/magnify.js')]`, which the previous
        // restrictive default (`lasso, inc, html, htm, txt` only) rejected
        // outright with `extensionNotAllowed("js")` — a real product
        // detail page that renders fine in production failed to render at
        // all locally. `isWithinRoot`'s path-confinement check (still
        // enforced below) is the actual, meaningful security boundary
        // here; an extension allowlist was never real Lasso behavior.
        allowedExtensions: Set<String> = []
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
        let candidate = try resolvedCandidateURL(for: path, from: includingPath)
        do {
            return try String(contentsOf: candidate, encoding: .utf8)
        } catch {
            throw LassoFileSystemIncludeError.unreadableFile(path)
        }
    }

    public func loadIncludeBytes(path: String, from includingPath: String?) throws -> Data {
        let candidate = try resolvedCandidateURL(for: path, from: includingPath)
        do {
            return try Data(contentsOf: candidate)
        } catch {
            throw LassoFileSystemIncludeError.unreadableFile(path)
        }
    }

    /// Path resolution/root-confinement/extension-allowlist policy shared
    /// by `loadInclude` and `loadIncludeBytes` — only the final read call
    /// (text vs. raw data) differs between them.
    private func resolvedCandidateURL(for path: String, from includingPath: String?) throws -> URL {
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
            return candidate
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

/// Lets evaluator-level code (native type methods, which only receive a
/// `LassoContext`, not an `Evaluator`) trigger a full include/library
/// render without rendering arbitrary nodes itself — the exact gap
/// `NativeTypes.swift`'s `makeWebResponseType()` used to flag as the
/// reason `web_response->include*` was deferred. Follows this codebase's
/// established provider-protocol convention (`includeLoader`,
/// `sessionProvider`, `responseSink`, `inlineProvider`, `uploadProcessor`
/// are all `(any SomeProtocol)?` on `LassoContext`, wired imperatively at
/// whichever call site constructs both a renderer and a context) rather
/// than a bare closure. The concrete conformer, `RendererIncludeService`,
/// lives in `Renderer.swift` — only that file can reconstruct a
/// `RendererEngine` to actually render loaded nodes.
///
/// Every call site MUST extract `context.includeRenderService` to a local
/// `let` before calling into it with `&context` — invoking a
/// closure/protocol witness stored on `context` as
/// `context.includeRenderService?.performInclude(..., context: &context)`
/// is overlapping access to the same storage and is rejected by Swift's
/// exclusivity checking.
public protocol LassoIncludeRenderService: Sendable {
    /// Renders `path` and returns its output, or `nil` when `once` is true
    /// and this path was already included earlier in the same render (the
    /// dedup hit itself, distinct from an include that legitimately
    /// produced empty output) — callers map `nil` to whatever "no-op"
    /// value fits their call site (e.g. `web_response->includeOnce`'s
    /// second call returns `.void`). `once`, when true, applies `include`'s
    /// own dedup (backed by `LassoContext.includedOncePaths`, separate
    /// from `loadedLibraries` so an `include` path and a `library` path
    /// sharing a string don't cross-suppress each other).
    func performInclude(path: String, once: Bool, context: inout LassoContext) async throws -> String?
    /// Executes `path` as a library for its side effects only (library
    /// bodies don't contribute to page output). `once`, when true, applies
    /// `loadedLibraries` dedup — the same dedup the bare `library(...)`
    /// free tag already applies unconditionally.
    func performLibrary(path: String, once: Bool, context: inout LassoContext) async throws
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

public struct LassoUploadProcessingOptions: Equatable, Sendable {
    public var destination: String
    public var useTempNames: Bool
    public var allowOverwrite: Bool
    public var maxSize: Int?
    public var allowedExtensions: Set<String>?

    public init(
        destination: String,
        useTempNames: Bool = false,
        allowOverwrite: Bool = false,
        maxSize: Int? = nil,
        allowedExtensions: Set<String>? = nil
    ) {
        self.destination = destination
        self.useTempNames = useTempNames
        self.allowOverwrite = allowOverwrite
        self.maxSize = maxSize
        self.allowedExtensions = allowedExtensions.map { Set($0.map { $0.lowercased() }) }
    }
}

public struct LassoProcessedUpload: Equatable, Sendable {
    public var source: LassoUploadedFile
    public var destinationPath: String

    public init(source: LassoUploadedFile, destinationPath: String) {
        self.source = source
        self.destinationPath = destinationPath
    }
}

public protocol LassoUploadProcessor: Sendable {
    func processUploads(_ uploads: [LassoUploadedFile], options: LassoUploadProcessingOptions) throws -> [LassoProcessedUpload]
}

public enum LassoUploadProcessingError: Error, Equatable, Sendable {
    case missingDestination
    case destinationOutsideRoot(String)
    case destinationUnavailable(String)
    case invalidOriginalFilename(String)
    case sourceMissing(String)
    case destinationExists(String)
    case moveFailed(String)
}

public struct LassoFileSystemUploadProcessor: LassoUploadProcessor {
    public let root: URL

    public init(root: URL) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LassoUploadProcessingError.destinationUnavailable(resolvedRoot.path)
        }
        self.root = resolvedRoot
    }

    public func processUploads(
        _ uploads: [LassoUploadedFile],
        options: LassoUploadProcessingOptions
    ) throws -> [LassoProcessedUpload] {
        guard options.destination.isEmpty == false else {
            throw LassoUploadProcessingError.missingDestination
        }
        let destinationDirectory = try resolveDestination(options.destination)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var processed: [LassoProcessedUpload] = []
        for upload in uploads where shouldProcess(upload, options: options) {
            let filename = try destinationFilename(for: upload, useTempNames: options.useTempNames)
            let destination = destinationDirectory.appendingPathComponent(filename)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard isWithinRoot(destination) else {
                throw LassoUploadProcessingError.destinationOutsideRoot(destination.path)
            }
            guard FileManager.default.fileExists(atPath: upload.temporaryFilename) else {
                throw LassoUploadProcessingError.sourceMissing(upload.temporaryFilename)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard options.allowOverwrite else {
                    throw LassoUploadProcessingError.destinationExists(destination.path)
                }
                try FileManager.default.removeItem(at: destination)
            }
            do {
                try FileManager.default.moveItem(at: URL(fileURLWithPath: upload.temporaryFilename), to: destination)
            } catch {
                do {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: upload.temporaryFilename), to: destination)
                    try? FileManager.default.removeItem(atPath: upload.temporaryFilename)
                } catch {
                    throw LassoUploadProcessingError.moveFailed(destination.path)
                }
            }
            processed.append(LassoProcessedUpload(source: upload, destinationPath: destination.path))
        }
        return processed
    }

    private func resolveDestination(_ destination: String) throws -> URL {
        let normalized = destination.hasPrefix("/") ? String(destination.dropFirst()) : destination
        let candidate = root.appendingPathComponent(normalized)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isWithinRoot(candidate) else {
            throw LassoUploadProcessingError.destinationOutsideRoot(destination)
        }
        return candidate
    }

    private func shouldProcess(_ upload: LassoUploadedFile, options: LassoUploadProcessingOptions) -> Bool {
        if let maxSize = options.maxSize, upload.size > maxSize { return false }
        if let allowedExtensions = options.allowedExtensions {
            let ext = (upload.originalFilename as NSString).pathExtension.lowercased()
            return allowedExtensions.contains(ext)
        }
        return true
    }

    private func destinationFilename(for upload: LassoUploadedFile, useTempNames: Bool) throws -> String {
        let raw = useTempNames
            ? URL(fileURLWithPath: upload.temporaryFilename).lastPathComponent
            : upload.originalFilename
        let sanitized = URL(fileURLWithPath: raw).lastPathComponent
        guard sanitized.isEmpty == false, sanitized != ".", sanitized != ".." else {
            throw LassoUploadProcessingError.invalidOriginalFilename(raw)
        }
        return sanitized
    }

    private func isWithinRoot(_ candidate: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
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

public struct LassoSessionStartResult: Equatable, Sendable {
    public let sessionID: String
    public let isNew: Bool

    public init(sessionID: String, isNew: Bool) {
        self.sessionID = sessionID
        self.isNew = isNew
    }
}

/// A `session_start(name, -flag=value, ...)` call's fully-evaluated
/// arguments — built from real `[EvaluatedArgument]` at the point
/// `session_start` is actually evaluated (see
/// `SessionArgumentResolution.swift`'s `makeSessionStartCall`), not from
/// raw parse-time AST. Dynamic values (a variable, a concatenation,
/// `action_param(...)`, etc.) all resolve correctly here since evaluation
/// has already happened by the time this is built — unlike the retired
/// parse-time preflight scan this replaces, which could only ever see
/// literal arguments.
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

/// Real Lasso sessions are named (`session_start(name, ...)`), each backing
/// a set of persisted thread variables (`session_addVar(name, varName)`) —
/// see `Documentation/session-upload-support-plan.md`'s "Lasso Session
/// Semantics".
///
/// **2026-07-18 architecture correction**: this protocol's `start` method
/// was originally synchronous, forcing a parse-time "preflight scan" of
/// the page for literal `session_start(...)` calls so every session could
/// be created/resumed up front (real session storage,
/// `PerfectSessionCore.SessionDriver`, is async; the evaluator used to be
/// synchronous). That scan was a static approximation of what the page
/// would actually do at render time, and any static approximation of
/// procedural execution is necessarily incomplete — confirmed live: it
/// missed `session_start` calls hidden inside `include(...)`-loaded files
/// (the standard real-world pattern), and by its own documented design it
/// could never see a dynamically-computed session name or flag value
/// either. The evaluator was converted to fully `async throws` end to end
/// on 2026-07-15 (`Documentation/synchronous-render-pipeline.md`) — three
/// days after this session bridge was built on the now-stale "evaluator is
/// sync" premise, and nobody revisited it. `start` is now `async`: real
/// session creation/resumption happens exactly when `session_start` is
/// actually evaluated, in real program order, with the full context
/// (variables, prior session state, whatever `include`/custom-tag nesting
/// got it there) that a parse-time scan could never have. The scan
/// (`LassoSessionPreflight`) has been removed entirely — there is nothing
/// left for it to preload.
public protocol LassoSessionProvider: Sendable {
    /// Starts (creates or resumes) a named session, doing the actual async
    /// `SessionDriver` create/resume work in place. Returns `nil` only when
    /// no session provider is configured at all (see `LassoContext`) —
    /// every real conformer always succeeds (a resume failure falls back to
    /// creating a new session, matching real Lasso's own behavior for an
    /// expired/invalid session id).
    func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult?
    func id(session name: String) -> String?
    /// The value restored from a resumed session for `varName`, or `nil` for
    /// a new session, an ended/aborted one, or a name never persisted before.
    func restoredValue(for varName: String, session name: String) -> LassoValue?
    /// Every variable ever persisted into `name`'s session (from this
    /// resume or any earlier one) — real Lasso restores all of these the
    /// moment `session_start` runs, without requiring `session_addVar` to
    /// be called again for each one on every subsequent page (per
    /// LassoGuide: "The variable does not need to be added to the session
    /// on each request, though it is safe to do so"). `session_start`'s
    /// native registration uses this to auto-populate scope; defaults to
    /// empty so existing conformers that only ever answer one variable at
    /// a time via `restoredValue(for:session:)` don't need updating.
    func restoredVariables(session name: String) -> [String: LassoValue]
    /// Records the current value of `varName` to persist into `name`'s
    /// session data when the request ends (skipped if `abort`/`end` was
    /// called for that session this request).
    func persist(_ value: LassoValue, for varName: String, session name: String)
    func removeVar(_ varName: String, session name: String)
    /// Ends the session: stops future saves and destroys stored state.
    func end(session name: String)
    /// Prevents saving for this session (e.g. after a partial failure) but
    /// does not destroy already-stored state, matching the documented
    /// difference between `session_abort` and `session_end`.
    func abort(session name: String)
}

public extension LassoSessionProvider {
    func restoredVariables(session name: String) -> [String: LassoValue] { [:] }
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
    /// Records a `sendFile`/`file_serve`/`file_stream` request for the
    /// server boundary to act on after render — same "collect now, act
    /// after render" convention as `redirect(to:)`/`setCookie`. Defaulted
    /// to a no-op so existing conformers (test/smoke sinks predating file
    /// serving) don't need to change.
    func serveFile(_ request: LassoFileServeRequest) throws
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
    func serveFile(_ request: LassoFileServeRequest) throws {}
}

/// A file-serve request produced by `web_response->sendFile` (already-
/// evaluated string `data`) or `file_serve`/`file_stream` (a site-relative
/// `path`, resolved by the server boundary via the same root-confining
/// `fileURL(for:)` every other filesystem-touching feature already uses).
/// Exactly one of `data`/`path` is set, matching the two distinct real
/// Lasso constructs this models — see
/// `Documentation/web-response-include-plan.md` for why they're kept
/// separate rather than forced into one path-based mechanism.
public struct LassoFileServeRequest: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case data(Data)
        case path(String)
    }

    public var source: Source
    public var fileName: String?
    public var contentType: String?
    /// `nil` means "don't emit Content-Disposition at all" — the right
    /// default for `file_serve`/`file_stream` (no documented disposition
    /// concept). `sendFile` passes `"attachment"` explicitly, matching its
    /// real documented `-disposition` default.
    public var disposition: String?

    public init(
        source: Source,
        fileName: String? = nil,
        contentType: String? = nil,
        disposition: String? = nil
    ) {
        self.source = source
        self.fileName = fileName
        self.contentType = contentType
        self.disposition = disposition
    }
}

public protocol LassoInlineProvider: Sendable {
    func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame
}

public protocol LassoDynamicQueryExecutor: Sendable {
    func execute(_ request: LassoInlineRequest) async throws -> LassoInlineFrame
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
    ) async throws -> LassoInlineFrame {
        let request = try LassoInlineRequest(arguments: arguments)
        let mappedRequest: LassoInlineRequest
        if let database = request.database,
           let mappedDatabase = datasourceAliases[database.lowercased()] {
            mappedRequest = try request.replacingDatabase(with: mappedDatabase)
        } else {
            mappedRequest = request
        }
        return try await executor.execute(mappedRequest)
    }
}

public struct LassoInMemoryInlineProvider: LassoInlineProvider {
    private let tables: [String: [LassoDataRow]]

    public init(tables: [String: [LassoDataRow]]) {
        self.tables = Dictionary(uniqueKeysWithValues: tables.map { ($0.key.lowercased(), $0.value) })
    }

    public func executeInline(arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoInlineFrame {
        let request = try LassoInlineRequest(arguments: arguments)
        guard request.action != .nothing else { return LassoInlineFrame(rows: []) }
        guard let table = request.table?.lowercased(), var rows = tables[table] else {
            return LassoInlineFrame(rows: [])
        }

        rows = rows.filter { row in
            request.criteria.allSatisfy { criterion in
                compare(row[criterion.field], criterion.operation ?? "eq", criterion.value)
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
    func replacingDatabase(with database: String) throws -> LassoInlineRequest {
        var arguments = rawArguments
        if let index = arguments.lastIndex(where: {
            $0.label?.caseInsensitiveCompare("database") == .orderedSame
        }) {
            arguments[index] = EvaluatedArgument(label: arguments[index].label, value: .string(database))
        } else {
            arguments.append(EvaluatedArgument(label: "database", value: .string(database)))
        }
        return try LassoInlineRequest(arguments: arguments)
    }
}

struct ActiveInlineFrame: Equatable, Sendable {
    let frame: LassoInlineFrame
    var currentRow: LassoDataRow?
}

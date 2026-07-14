import Foundation
import LassoParser
import PerfectFileMaker

/// Mirrors `LassoPerfectCRUD`'s `LassoDatabaseActionFailureKind`/
/// `LassoDatabaseActionError` shape (same adapter-stable-code convention,
/// deliberately not real Lasso 8.5 numeric error codes — see that type's
/// own doc comment) for the FileMaker connector. A separate type, not a
/// reused one, since `LassoPerfectFileMaker` doesn't depend on
/// `LassoPerfectCRUD` and the two connectors' failure kinds genuinely
/// differ (no raw-SQL kind here — real Lasso 8.5 documents `-SQL` as
/// unsupported for FileMaker data sources).
public enum LassoFileMakerActionFailureKind: String, Sendable {
    case search
    case add
    case update
    case delete

    var code: Int {
        switch self {
        case .search: 2001
        case .add: 2002
        case .update: 2003
        case .delete: 2004
        }
    }

    var displayName: String {
        switch self {
        case .search: "Search"
        case .add: "Add"
        case .update: "Update"
        case .delete: "Delete"
        }
    }
}

/// Explicit marker for expected FileMaker datasource/action failures —
/// same role as `LassoPerfectCRUD.LassoDatabaseActionError`: generic Swift
/// throws inside this executor remain fatal to the adapter (structural
/// issues like an unsupported action/operator); only genuine
/// runtime/server failures get wrapped in this type before being turned
/// into a recoverable `LassoInlineFrame`.
public struct LassoFileMakerDatabaseActionError: Error, Sendable {
    public let state: LassoErrorState

    public init(kind: LassoFileMakerActionFailureKind, datasource: String, underlying: Error) {
        self.state = LassoErrorState(
            code: kind.code,
            message: "\(kind.displayName) failed for FileMaker datasource '\(datasource)'.",
            kind: kind.rawValue,
            detail: String(describing: underlying)
        )
    }

    public init(code: Int, message: String, kind: String, detail: String? = nil) {
        self.state = LassoErrorState(code: code, message: message, kind: kind, detail: detail)
    }
}

public enum LassoFileMakerLassoError: Error, Equatable, Sendable {
    case missingDatasource
    case missingTable
    case unsupportedAction(LassoInlineAction)
    case unsupportedComparison(String)
    case missingAssignments(LassoInlineAction)
    /// A missing or non-numeric `-KeyValue` on `-Update`/`-Delete` —
    /// distinct from `missingAssignments` (no field/value arguments at
    /// all), which this previously, confusingly, reused as its `underlying`
    /// error.
    case invalidKeyValue(LassoInlineAction)
}

/// `LassoDynamicQueryExecutor` conformer for real FileMaker Server
/// datasources, speaking XML Custom Web Publishing via the local
/// `Perfect-FileMaker` fork's `FMPQuery`/`FMPResultSet`. Mirrors
/// `LassoPerfectCRUD.PerfectCRUDLassoExecutor`'s overall shape in two
/// ways: (1) one `execute(_:)` entry point dispatching to per-action
/// private methods, structural errors thrown fatally, runtime errors
/// caught and turned into a recoverable `LassoInlineFrame`; (2) — just as
/// important — this executor holds no live backend connection itself.
/// Like `PerfectCRUDLassoExecutor`'s `queryHandler`/`mutationHandler`/
/// `rawSQLHandler`, all FileMaker I/O is delegated to an injected
/// `queryHandler` closure. That keeps this type fully unit-testable with
/// a fake handler (no live server needed) and keeps `FileMakerServer`
/// itself — and the semaphore bridge needed over its genuinely async
/// completion-callback API — out of this file entirely; the production
/// handler is built at the composition root
/// (`Sources/LassoPerfectServer/main.swift`), exactly where
/// `PerfectCRUDLassoExecutor`'s real `Database` wiring lives today. See
/// `Documentation/lasso-perfect-server.md`'s FileMaker Datasource section
/// for the full design rationale, including every deliberately deferred
/// case (`-Duplicate`/`-Random`/`-Show`/`-RX`/portal reads — zero real
/// corpus evidence).
public struct PerfectFileMakerLassoExecutor: LassoDynamicQueryExecutor {
    /// `async throws`, matching `FileMakerServer.query(_:)`'s own native
    /// `async`/`await` shape — the production implementation in `main.swift`
    /// awaits it directly, with no sync/async bridge; unlike
    /// `PerfectCRUDLassoExecutor.QueryHandler` (still deliberately
    /// synchronous, since `PerfectMySQL`'s underlying calls have no async
    /// API to bridge to — see Phase 2 of
    /// `Documentation/synchronous-render-pipeline.md`'s successor plan for
    /// the thread-offload that's meant to address that separately).
    ///
    /// Takes `kind`/`datasource` alongside the query — unlike
    /// `PerfectCRUDLassoExecutor` (which splits `queryHandler`/
    /// `mutationHandler`/`rawSQLHandler` into one closure per action, so
    /// each already knows its own kind), this executor uses a single
    /// handler for all five FileMaker actions, and `FMPQuery`'s
    /// `action`/`database` fields are `internal` to the upstream
    /// `Perfect-FileMaker` module — invisible to whatever builds the real
    /// handler in `main.swift` — so there'd otherwise be no way for it to
    /// classify a failure by kind. The handler is expected to catch any
    /// real backend failure itself and throw `LassoFileMakerDatabaseActionError`
    /// (see `performSync` below) — matching `PerfectCRUDLassoExecutor`'s
    /// convention, where classification happens in the handler, not the
    /// executor.
    public typealias QueryHandler = @Sendable (
        _ query: FMPQuery,
        _ kind: LassoFileMakerActionFailureKind,
        _ datasource: String
    ) async throws -> FMPResultSet

    private let queryHandler: QueryHandler
    /// Matches `LassoPerfectCRUD`'s "reads enabled by default, writes
    /// disabled until a deployment explicitly opts in" policy — real
    /// Lasso 8.5 documents no raw-SQL concept for FileMaker at all, so
    /// there's no `allowsRawSQL` analogue to carry.
    private let allowWrites: Bool
    /// Prefixed onto FileMaker container-field reference paths (already
    /// server-relative in the XML CWP response, not inline binary — see
    /// the executor's `lassoValue(_:)` below) so the resulting
    /// `LassoValue.string` is an immediately usable URL.
    private let baseURL: String

    public init(allowWrites: Bool = false, baseURL: String = "", queryHandler: @escaping QueryHandler) {
        self.queryHandler = queryHandler
        self.allowWrites = allowWrites
        self.baseURL = baseURL
    }

    public func execute(_ request: LassoInlineRequest) async throws -> LassoInlineFrame {
        guard let datasource = request.database, datasource.isEmpty == false else {
            throw LassoFileMakerLassoError.missingDatasource
        }
        guard let table = request.table, table.isEmpty == false else {
            throw LassoFileMakerLassoError.missingTable
        }

        switch request.action {
        case .search, .find:
            return try await executeFind(request, datasource: datasource, table: table)
        case .findAll:
            return try await executeFindAll(request, datasource: datasource, table: table)
        case .add:
            return try await executeAdd(request, datasource: datasource, table: table)
        case .update:
            return try await executeUpdate(request, datasource: datasource, table: table)
        case .delete:
            return try await executeDelete(request, datasource: datasource, table: table)
        default:
            throw LassoFileMakerLassoError.unsupportedAction(request.action)
        }
    }

    // MARK: - Read

    private func executeFind(_ request: LassoInlineRequest, datasource: String, table: String) async throws -> LassoInlineFrame {
        do {
            var query = FMPQuery(database: datasource, layout: table, action: .find)
                .sortFields(sortFields(request))
                .queryFields(try queryFieldGroups(request.criteriaGroups))
            if let maxRecords = request.maxRecords { query = query.maxRecords(maxRecords) }
            if let skipRecords = request.skipRecords { query = query.skipRecords(skipRecords) }
            let result = try await performSync(query, kind: .search, datasource: datasource)
            return LassoInlineFrame(rows: result.records.map(lassoRow), foundCount: result.foundCount, actionStatement: query.queryString)
        } catch let error as LassoFileMakerDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
    }

    private func executeFindAll(_ request: LassoInlineRequest, datasource: String, table: String) async throws -> LassoInlineFrame {
        do {
            var query = FMPQuery(database: datasource, layout: table, action: .findAll)
                .sortFields(sortFields(request))
            if let maxRecords = request.maxRecords { query = query.maxRecords(maxRecords) }
            if let skipRecords = request.skipRecords { query = query.skipRecords(skipRecords) }
            let result = try await performSync(query, kind: .search, datasource: datasource)
            return LassoInlineFrame(rows: result.records.map(lassoRow), foundCount: result.foundCount, actionStatement: query.queryString)
        } catch let error as LassoFileMakerDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
    }

    // MARK: - Write actions

    private func executeAdd(_ request: LassoInlineRequest, datasource: String, table: String) async throws -> LassoInlineFrame {
        guard allowWrites else {
            return recoverableFrame(kind: .add, datasource: datasource, message: "-Add is not enabled for FileMaker datasource '\(datasource)'.")
        }
        guard request.fieldAssignments.isEmpty == false else {
            throw LassoFileMakerLassoError.missingAssignments(.add)
        }
        do {
            let query = FMPQuery(database: datasource, layout: table, action: .new)
                .queryFields(queryFields(request.fieldAssignments))
            let result = try await performSync(query, kind: .add, datasource: datasource)
            return LassoInlineFrame(rows: result.records.map(lassoRow), affectedRows: 1, actionStatement: query.queryString)
        } catch let error as LassoFileMakerDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
    }

    private func executeUpdate(_ request: LassoInlineRequest, datasource: String, table: String) async throws -> LassoInlineFrame {
        guard allowWrites else {
            return recoverableFrame(kind: .update, datasource: datasource, message: "-Update is not enabled for FileMaker datasource '\(datasource)'.")
        }
        guard request.fieldAssignments.isEmpty == false else {
            throw LassoFileMakerLassoError.missingAssignments(.update)
        }
        do {
            let recordID = try recordID(from: request.keyValue, kind: .update, datasource: datasource)
            let query = FMPQuery(database: datasource, layout: table, action: .edit)
                .recordId(recordID)
                .queryFields(queryFields(request.fieldAssignments))
            let result = try await performSync(query, kind: .update, datasource: datasource)
            return LassoInlineFrame(rows: result.records.map(lassoRow), affectedRows: 1, actionStatement: query.queryString)
        } catch let error as LassoFileMakerDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
    }

    private func executeDelete(_ request: LassoInlineRequest, datasource: String, table: String) async throws -> LassoInlineFrame {
        guard allowWrites else {
            return recoverableFrame(kind: .delete, datasource: datasource, message: "-Delete is not enabled for FileMaker datasource '\(datasource)'.")
        }
        do {
            let recordID = try recordID(from: request.keyValue, kind: .delete, datasource: datasource)
            let query = FMPQuery(database: datasource, layout: table, action: .delete)
                .recordId(recordID)
            _ = try await performSync(query, kind: .delete, datasource: datasource)
            // Real Lasso 8.5 documents -Delete as returning an empty found
            // set — matches PerfectCRUDLassoExecutor's identical precedent.
            return LassoInlineFrame(rows: [], affectedRows: 1, actionStatement: query.queryString)
        } catch let error as LassoFileMakerDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
    }

    // MARK: - Query dispatch

    /// A thin pass-through, deliberately NOT a catch-all wrapper — matches
    /// `PerfectCRUDLassoExecutor.executeRead`/etc., which only ever catch
    /// `LassoRecoverableError`/`LassoDatabaseActionError` around their own
    /// `queryHandler` call and let anything else propagate fatally, on the
    /// assumption that the handler itself is responsible for classifying
    /// its own failures before they reach the executor. Each `execute*`
    /// method's own `catch let error as LassoFileMakerDatabaseActionError`
    /// clause is what actually turns a classified failure into a
    /// recoverable frame; an unclassified error from a buggy handler (or a
    /// genuine adapter bug) is deliberately left to propagate fatally
    /// rather than being silently downgraded into a routine "-Search
    /// failed" frame.
    private func performSync(_ query: FMPQuery, kind: LassoFileMakerActionFailureKind, datasource: String) async throws -> FMPResultSet {
        try await queryHandler(query, kind, datasource)
    }

    // MARK: - Shared helpers

    private func recoverableFrame(kind: LassoFileMakerActionFailureKind, datasource: String, message: String) -> LassoInlineFrame {
        LassoInlineFrame(rows: [], error: LassoErrorState(code: kind.code, message: message, kind: kind.rawValue))
    }

    private func sortFields(_ request: LassoInlineRequest) -> [FMPSortField] {
        request.sortFields.enumerated().map { index, field in
            let descending = request.sortOrders.indices.contains(index) &&
                request.sortOrders[index].lowercased().contains("desc")
            return FMPSortField(name: field, order: descending ? .descending : .ascending)
        }
    }

    private func queryFields(_ assignments: [LassoInlineAssignment]) -> [FMPQueryField] {
        assignments.map { FMPQueryField(name: $0.field, value: $0.value.outputString) }
    }

    /// `-Not` group negation → `FMPQueryFieldGroup(op: .not)` — direct,
    /// since `FMPQueryFieldGroup.op: FMPLogicalOp` already models exactly
    /// this. Can throw `LassoFileMakerLassoError.unsupportedComparison`
    /// (a structural/programmer-facing error, matching
    /// `PerfectCRUDLassoExecutor.comparison(_:)`'s identical convention)
    /// — deliberately NOT caught by this executor's `LassoFileMakerDatabaseActionError`
    /// catch clauses, so it propagates fatally rather than becoming a
    /// silently-swallowed recoverable frame.
    private func queryFieldGroups(_ groups: [LassoInlineCriteriaGroup]) throws -> [FMPQueryFieldGroup] {
        try groups.map { group in
            FMPQueryFieldGroup(
                fields: try group.criteria.map {
                    FMPQueryField(name: $0.field, value: $0.value.outputString, op: try fieldOp($0.operation))
                },
                op: group.negated ? .not : .and
            )
        }
    }

    /// Real Lasso 8.5 Ch. 11 "FileMaker Queries", Table 4 "FileMaker
    /// Operators" — lowercased before matching, matching
    /// `PerfectCRUDLassoExecutor.comparison(_:)`'s existing convention
    /// exactly (real corpus supplies mixed case, e.g. `-Op='Eq'`).
    /// `-RX` (raw FileMaker search-symbol expression) has no `FMPFieldOp`
    /// case and zero corpus evidence against `fm_catalog` — unsupported,
    /// same as any other unrecognized operator. A criterion with no `-Op`
    /// at all (`nil`, distinct from an explicit `-Op='EQ'`) defaults to
    /// `.beginsWith` — the FileMaker connector's own documented default,
    /// NOT `PerfectCRUDLassoExecutor`'s `-EQ` default for SQL connectors;
    /// `FMPQueryField`'s own `op:` parameter already defaults to
    /// `.beginsWith` for the same reason.
    private func fieldOp(_ operation: String?) throws -> FMPFieldOp {
        guard let operation else { return .beginsWith }
        switch operation.lowercased() {
        case "eq", "equals", "=": return .equal
        case "cn", "contains": return .contains
        case "bw", "beginswith": return .beginsWith
        case "ew", "endswith": return .endsWith
        case "gt", ">": return .greaterThan
        case "gte", ">=": return .greaterThanEqual
        case "lt", "<": return .lessThan
        case "lte", "<=": return .lessThanEqual
        default: throw LassoFileMakerLassoError.unsupportedComparison(operation)
        }
    }

    /// `-KeyValue` → FileMaker's internal record ID. Real Lasso's
    /// FileMaker connector documents the key field as always being the
    /// internal record ID (`-KeyField` need not name anything — real
    /// corpus confirms every `fm_catalog` `-KeyField` is passed as an
    /// empty string). A malformed/missing `-KeyValue` (e.g. a tampered
    /// HTML form field) is an expected runtime failure, not a
    /// programmer/adapter error — thrown as `LassoFileMakerDatabaseActionError`
    /// so it becomes a recoverable frame, not a Swift-level fatal throw,
    /// matching this feature's plan.
    private func recordID(from value: LassoValue?, kind: LassoFileMakerActionFailureKind, datasource: String) throws -> Int {
        guard let value, let number = Self.numericValue(value), let recordID = Int(exactly: number.rounded()) else {
            throw LassoFileMakerDatabaseActionError(
                kind: kind,
                datasource: datasource,
                underlying: LassoFileMakerLassoError.invalidKeyValue(kind == .update ? .update : .delete)
            )
        }
        return recordID
    }

    /// `LassoValue.number` (Runtime.swift) is `internal` to `LassoParser` —
    /// this reimplements the same integer/decimal/string-coercion cases
    /// locally since this adapter lives in a separate module.
    private static func numericValue(_ value: LassoValue) -> Double? {
        switch value {
        case let .integer(v): Double(v)
        case let .decimal(v): v
        case let .string(v): Double(v)
        default: nil
        }
    }

    private func lassoRow(_ record: FMPRecord) -> LassoDataRow {
        var values: [String: LassoValue] = [:]
        for (name, item) in record.elements {
            // .relatedSet (portal data): zero corpus evidence of any
            // fm_catalog page reading one — silently omitted rather than
            // guessing a shape (array of maps? nested LassoDataRow?)
            // nobody's asked for yet.
            if case .field(_, let fieldValue) = item {
                values[name] = lassoValue(fieldValue)
            }
        }
        return LassoDataRow(values, keyValue: .integer(record.recordId))
    }

    /// Not `private`: `FMPRecord`/`FMPResultSet` have no public initializer
    /// anywhere in the upstream `Perfect-FileMaker` library (their only
    /// inits parse a real XML response), so `lassoRow(_:)` itself can't be
    /// unit-tested from outside this module. This one piece of the mapping
    /// — the part that doesn't need an `FMPRecord`, since `FMPFieldValue`'s
    /// cases are freely constructible — is left `internal` so
    /// `@testable import` can reach it directly.
    func lassoValue(_ value: FMPFieldValue) -> LassoValue {
        switch value {
        case .text(let value): .string(value)
        case .number(let value): .decimal(value)
        // FileMaker-native date/time/timestamp format strings, passed
        // through as-is (not reformatted) -- real corpus/live-verify
        // evidence needed before choosing a specific reformat, matching
        // this codebase's "don't guess a shape nobody's confirmed" posture.
        case .date(let value), .time(let value), .timestamp(let value): .string(value)
        // The XML CWP <data> node for a container field is already a
        // server-relative container-reference *path*, not inline binary
        // (confirmed via FMPRecord/the CWP grammar) -- .string is the
        // actual wire shape here, not a lossy downgrade of something
        // richer. Prefixed with the configured base URL so it's an
        // immediately usable link. Unverified against the real v16
        // server's exact <data> shape until live-tested -- see
        // Documentation/lasso-perfect-server.md.
        case .container(let value): .string(value.hasPrefix("http") ? value : baseURL + value)
        }
    }
}

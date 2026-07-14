import Foundation
import LassoParser
import PerfectCRUD

/// Per-datasource write/raw-SQL policy — see
/// `Documentation/inline-write-raw-sql-plan.md`'s "Capability Policy".
/// Defaults are read-only: a datasource must explicitly opt into
/// insert/update/delete/raw SQL, keeping a legacy Lasso app usable without
/// letting arbitrary pages become uncontrolled database consoles.
public struct LassoDatasourceCapabilities: Sendable {
    public var allowsSelect: Bool
    public var allowsInsert: Bool
    public var allowsUpdate: Bool
    public var allowsDelete: Bool
    public var allowsRawSQL: Bool
    public var allowsMultipleStatements: Bool
    public var allowedTables: Set<String>?
    public var maxRows: Int?

    public init(
        allowsSelect: Bool = true,
        allowsInsert: Bool = false,
        allowsUpdate: Bool = false,
        allowsDelete: Bool = false,
        allowsRawSQL: Bool = false,
        allowsMultipleStatements: Bool = false,
        allowedTables: Set<String>? = nil,
        maxRows: Int? = nil
    ) {
        self.allowsSelect = allowsSelect
        self.allowsInsert = allowsInsert
        self.allowsUpdate = allowsUpdate
        self.allowsDelete = allowsDelete
        self.allowsRawSQL = allowsRawSQL
        self.allowsMultipleStatements = allowsMultipleStatements
        self.allowedTables = allowedTables
        self.maxRows = maxRows
    }

    public static let readOnly = LassoDatasourceCapabilities()

    public static let full = LassoDatasourceCapabilities(
        allowsInsert: true,
        allowsUpdate: true,
        allowsDelete: true,
        allowsRawSQL: true
    )
}

public enum LassoDatabaseActionFailureKind: String, Sendable {
    case search
    case add
    case update
    case delete
    case sql

    var code: LassoErrorState.InlineErrorCode {
        switch self {
        case .search: .selectFailed
        case .add: .addFailed
        case .update: .updateFailed
        case .delete: .deleteFailed
        case .sql: .rawSQLFailed
        }
    }

    var displayName: String {
        switch self {
        case .search: "Search"
        case .add: "Add"
        case .update: "Update"
        case .delete: "Delete"
        case .sql: "SQL"
        }
    }
}

/// Explicit marker for expected datasource/action failures. Generic Swift
/// throws remain fatal to the adapter; connector boundaries should wrap only
/// real database-operation failures in this type before they reach the
/// executor.
public struct LassoDatabaseActionError: Error, Sendable {
    public let state: LassoErrorState

    public init(kind: LassoDatabaseActionFailureKind, datasource: String, underlying: Error) {
        self.state = LassoErrorState(
            code: kind.code.rawValue,
            message: "\(kind.displayName) failed for datasource '\(datasource)'.",
            kind: kind.rawValue,
            detail: String(describing: underlying)
        )
    }

    public init(code: Int, message: String, kind: String, detail: String? = nil) {
        self.state = LassoErrorState(code: code, message: message, kind: kind, detail: detail)
    }
}

public struct PerfectCRUDLassoExecutor: LassoDynamicQueryExecutor {
    public typealias QueryHandler = @Sendable (
        _ datasource: String,
        _ query: DynamicQuery
    ) throws -> DynamicResult
    public typealias MutationHandler = @Sendable (
        _ datasource: String,
        _ mutation: DynamicMutation
    ) throws -> DynamicResult
    public typealias RawSQLHandler = @Sendable (
        _ datasource: String,
        _ sql: DynamicSQL
    ) throws -> DynamicResult
    public typealias CapabilitiesResolver = @Sendable (_ datasource: String) -> LassoDatasourceCapabilities

    private let queryHandler: QueryHandler
    private let mutationHandler: MutationHandler?
    private let rawSQLHandler: RawSQLHandler?
    private let capabilitiesResolver: CapabilitiesResolver

    public init(
        capabilities: @escaping CapabilitiesResolver = { _ in .readOnly },
        queryHandler: @escaping QueryHandler,
        mutationHandler: MutationHandler? = nil,
        rawSQLHandler: RawSQLHandler? = nil
    ) {
        self.queryHandler = queryHandler
        self.mutationHandler = mutationHandler
        self.rawSQLHandler = rawSQLHandler
        capabilitiesResolver = capabilities
    }

    public func execute(_ request: LassoInlineRequest) throws -> LassoInlineFrame {
        guard let datasource = request.database, datasource.isEmpty == false else {
            throw PerfectCRUDLassoError.missingDatasource
        }
        let capabilities = capabilitiesResolver(datasource)

        switch request.action {
        case .search, .find, .findAll:
            return try executeRead(request, datasource: datasource, capabilities: capabilities)
        case .add:
            return try executeInsert(request, datasource: datasource, capabilities: capabilities)
        case .update:
            return try executeUpdate(request, datasource: datasource, capabilities: capabilities)
        case .delete:
            return try executeDelete(request, datasource: datasource, capabilities: capabilities)
        case .rawSQL:
            return try executeRawSQL(request, datasource: datasource, capabilities: capabilities)
        default:
            throw PerfectCRUDLassoError.unsupportedAction(request.action)
        }
    }

    // MARK: - Read (pre-existing behavior, unchanged)

    private func executeRead(
        _ request: LassoInlineRequest,
        datasource: String,
        capabilities: LassoDatasourceCapabilities
    ) throws -> LassoInlineFrame {
        guard capabilities.allowsSelect else {
            return recoverableFrame(code: .permissionDenied, message: "SELECT is not enabled for datasource '\(datasource)'.")
        }
        guard let table = request.table, table.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTable
        }
        guard isTableAllowed(table, capabilities: capabilities) else {
            return recoverableFrame(code: .tableNotAllowed, message: "Table '\(table)' is not in the allowed-table list for datasource '\(datasource)'.")
        }

        let query = DynamicQuery(
            table: table,
            fields: request.returnFields,
            predicates: try request.criteria.map {
                DynamicPredicate(
                    field: $0.field,
                    comparison: try comparison($0.operation ?? "eq"),
                    value: dynamicValue($0.value)
                )
            },
            orderings: request.sortFields.enumerated().map { index, field in
                let descending = request.sortOrders.indices.contains(index) &&
                    request.sortOrders[index].lowercased().contains("desc")
                return DynamicOrdering(field: field, descending: descending)
            },
            limit: cappedLimit(request.maxRecords, capabilities: capabilities),
            offset: request.skipRecords
        )
        let result: DynamicResult
        do {
            result = try queryHandler(datasource, query)
        } catch let error as LassoRecoverableError {
            return LassoInlineFrame(rows: [], error: error.state)
        } catch let error as LassoDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
        return LassoInlineFrame(
            rows: result.rows.map(lassoRow),
            affectedRows: result.affectedRows,
            actionStatement: result.statement
        )
    }

    // MARK: - Write actions

    private func executeInsert(
        _ request: LassoInlineRequest,
        datasource: String,
        capabilities: LassoDatasourceCapabilities
    ) throws -> LassoInlineFrame {
        guard let mutationHandler else { throw PerfectCRUDLassoError.unsupportedAction(.add) }
        guard let table = request.table, table.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTable
        }
        guard capabilities.allowsInsert else {
            return recoverableFrame(code: .addFailed, message: "-Add is not enabled for datasource '\(datasource)'.")
        }
        guard isTableAllowed(table, capabilities: capabilities) else {
            return recoverableFrame(code: .tableNotAllowed, message: "Table '\(table)' is not in the allowed-table list for datasource '\(datasource)'.")
        }
        guard request.fieldAssignments.isEmpty == false else {
            throw PerfectCRUDLassoError.missingAssignments(.add)
        }

        let mutation = DynamicMutation(
            action: .insert,
            table: table,
            values: Dictionary(uniqueKeysWithValues: request.fieldAssignments.map {
                ($0.field, dynamicValue($0.value))
            })
        )
        let result: DynamicResult
        do {
            result = try mutationHandler(datasource, mutation)
        } catch let error as LassoRecoverableError {
            return LassoInlineFrame(rows: [], error: error.state)
        } catch let error as LassoDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }

        // Best-effort, not guaranteed: return the inserted record only when
        // the connector reported an insert id AND a key field is known to
        // select it back by. Real Lasso's own docs only say "return the
        // inserted record when practical" — this is exactly that, not a
        // promise for every table/connector shape.
        var rows: [LassoDataRow] = []
        if let insertedID = result.insertedID, let keyField = request.keyField {
            if let followUp = try? queryHandler(datasource, DynamicQuery(
                table: table,
                predicates: [DynamicPredicate(field: keyField, comparison: .equal, value: .int(insertedID))],
                limit: 1
            )) {
                rows = followUp.rows.map(lassoRow)
            }
        }
        return LassoInlineFrame(rows: rows, affectedRows: result.affectedRows, actionStatement: result.statement)
    }

    private func executeUpdate(
        _ request: LassoInlineRequest,
        datasource: String,
        capabilities: LassoDatasourceCapabilities
    ) throws -> LassoInlineFrame {
        guard let mutationHandler else { throw PerfectCRUDLassoError.unsupportedAction(.update) }
        guard let table = request.table, table.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTable
        }
        guard capabilities.allowsUpdate else {
            return recoverableFrame(code: .updateFailed, message: "-Update is not enabled for datasource '\(datasource)'.")
        }
        guard isTableAllowed(table, capabilities: capabilities) else {
            return recoverableFrame(code: .tableNotAllowed, message: "Table '\(table)' is not in the allowed-table list for datasource '\(datasource)'.")
        }
        guard request.fieldAssignments.isEmpty == false else {
            throw PerfectCRUDLassoError.missingAssignments(.update)
        }
        guard request.writeCriteria.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTarget(.update)
        }

        let mutation = DynamicMutation(
            action: .update,
            table: table,
            values: Dictionary(uniqueKeysWithValues: request.fieldAssignments.map {
                ($0.field, dynamicValue($0.value))
            }),
            predicates: try request.writeCriteria.map {
                DynamicPredicate(field: $0.field, comparison: try comparison($0.operation ?? "eq"), value: dynamicValue($0.value))
            }
        )
        let result: DynamicResult
        do {
            result = try mutationHandler(datasource, mutation)
        } catch let error as LassoRecoverableError {
            return LassoInlineFrame(rows: [], error: error.state)
        } catch let error as LassoDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }

        var rows: [LassoDataRow] = []
        if request.maxRecords != 0 {
            if let followUp = try? queryHandler(datasource, DynamicQuery(table: table, predicates: mutation.predicates)) {
                rows = followUp.rows.map(lassoRow)
            }
        }
        return LassoInlineFrame(rows: rows, affectedRows: result.affectedRows, actionStatement: result.statement)
    }

    private func executeDelete(
        _ request: LassoInlineRequest,
        datasource: String,
        capabilities: LassoDatasourceCapabilities
    ) throws -> LassoInlineFrame {
        guard let mutationHandler else { throw PerfectCRUDLassoError.unsupportedAction(.delete) }
        guard let table = request.table, table.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTable
        }
        guard capabilities.allowsDelete else {
            return recoverableFrame(code: .deleteFailed, message: "-Delete is not enabled for datasource '\(datasource)'.")
        }
        guard isTableAllowed(table, capabilities: capabilities) else {
            return recoverableFrame(code: .tableNotAllowed, message: "Table '\(table)' is not in the allowed-table list for datasource '\(datasource)'.")
        }
        guard request.writeCriteria.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTarget(.delete)
        }

        let mutation = DynamicMutation(
            action: .delete,
            table: table,
            predicates: try request.writeCriteria.map {
                DynamicPredicate(field: $0.field, comparison: try comparison($0.operation ?? "eq"), value: dynamicValue($0.value))
            }
        )
        let result: DynamicResult
        do {
            result = try mutationHandler(datasource, mutation)
        } catch let error as LassoRecoverableError {
            return LassoInlineFrame(rows: [], error: error.state)
        } catch let error as LassoDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
        // Real Lasso 8.5 documents -Delete as returning an empty found set.
        return LassoInlineFrame(rows: [], affectedRows: result.affectedRows, actionStatement: result.statement)
    }

    // MARK: - Raw SQL

    private func executeRawSQL(
        _ request: LassoInlineRequest,
        datasource: String,
        capabilities: LassoDatasourceCapabilities
    ) throws -> LassoInlineFrame {
        guard let rawSQLHandler else { throw PerfectCRUDLassoError.unsupportedAction(.rawSQL) }
        guard let sqlText = request.sql, sqlText.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTable
        }
        guard capabilities.allowsRawSQL else {
            return recoverableFrame(code: .rawSQLNotAllowed, message: "-SQL is not enabled for datasource '\(datasource)'.")
        }

        let dynamicSQL = DynamicSQL(sql: sqlText, allowsMultipleStatements: capabilities.allowsMultipleStatements)
        let result: DynamicResult
        do {
            result = try rawSQLHandler(datasource, dynamicSQL)
        } catch let error as LassoRecoverableError {
            return LassoInlineFrame(rows: [], error: error.state)
        } catch let error as LassoDatabaseActionError {
            return LassoInlineFrame(rows: [], error: error.state)
        }
        return LassoInlineFrame(rows: result.rows.map(lassoRow), affectedRows: result.affectedRows, actionStatement: result.statement)
    }

    // MARK: - Shared helpers

    private func isTableAllowed(_ table: String, capabilities: LassoDatasourceCapabilities) -> Bool {
        guard let allowedTables = capabilities.allowedTables else { return true }
        return allowedTables.contains(table)
    }

    private func cappedLimit(_ requested: Int?, capabilities: LassoDatasourceCapabilities) -> Int? {
        guard let maxRows = capabilities.maxRows else { return requested }
        guard let requested else { return maxRows }
        return min(requested, maxRows)
    }

    private func recoverableFrame(code: LassoErrorState.InlineErrorCode, message: String) -> LassoInlineFrame {
        LassoInlineFrame(rows: [], error: LassoErrorState(code: code.rawValue, message: message, kind: code.kind))
    }

    private func comparison(_ operation: String) throws -> DynamicComparison {
        switch operation.lowercased() {
        case "eq", "equals", "=": .equal
        case "neq", "ne", "notequals", "!=": .notEqual
        case "gt", ">": .greaterThan
        case "gte", ">=": .greaterThanOrEqual
        case "lt", "<": .lessThan
        case "lte", "<=": .lessThanOrEqual
        case "bw", "beginswith": .beginsWith
        case "ew", "endswith": .endsWith
        case "cn", "contains": .contains
        default: throw PerfectCRUDLassoError.unsupportedComparison(operation)
        }
    }

    private func dynamicValue(_ value: LassoValue) -> DynamicValue {
        switch value {
        case .void, .null: .null
        case .boolean(let value): .bool(value)
        case .integer(let value): .int(Int64(value))
        case .decimal(let value): .double(value)
        case .string(let value): .string(value)
        case .array, .map, .object: .string(value.outputString)
        }
    }

    private func lassoRow(_ row: DynamicRow) -> LassoDataRow {
        LassoDataRow(row.values.mapValues(lassoValue))
    }

    private func lassoValue(_ value: DynamicValue) -> LassoValue {
        switch value {
        case .null: .null
        case .bool(let value): .boolean(value)
        case .int(let value):
            Int(exactly: value).map(LassoValue.integer) ?? .string(String(value))
        case .uint(let value):
            Int(exactly: value).map(LassoValue.integer) ?? .string(String(value))
        case .double(let value): .decimal(value)
        case .string(let value): .string(value)
        case .bytes(let value): .string(String(decoding: value, as: UTF8.self))
        case .date(let value): .string(value.ISO8601Format())
        }
    }
}

public enum PerfectCRUDLassoError: Error, Equatable, Sendable {
    case missingDatasource
    case missingTable
    case unsupportedAction(LassoInlineAction)
    case unsupportedComparison(String)
    case missingAssignments(LassoInlineAction)
    case missingTarget(LassoInlineAction)
}

extension LassoErrorState {
    /// Adapter-stable numeric codes for datasource capability/permission
    /// denials — deliberately not real Lasso 8.5 numeric error codes,
    /// which Documentation/error-protect-model-plan.md's Milestone 1 still
    /// needs to extract from the local reference PDF. Isolated behind this
    /// enum so swapping in the real codes later doesn't touch call sites.
    enum InlineErrorCode: Int {
        case addFailed = 1001
        case updateFailed = 1002
        case deleteFailed = 1003
        case rawSQLNotAllowed = 1004
        case permissionDenied = 1005
        case tableNotAllowed = 1006
        case selectFailed = 1007
        case rawSQLFailed = 1008

        var kind: String {
            switch self {
            case .selectFailed: "search"
            case .addFailed: "add"
            case .updateFailed: "update"
            case .deleteFailed: "delete"
            case .rawSQLFailed: "sql"
            case .rawSQLNotAllowed, .permissionDenied, .tableNotAllowed: "permission"
            }
        }
    }
}

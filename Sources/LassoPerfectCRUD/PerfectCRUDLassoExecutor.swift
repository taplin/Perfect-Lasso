import Foundation
import LassoParser
import PerfectCRUD

public struct PerfectCRUDLassoExecutor: LassoDynamicQueryExecutor {
    public typealias QueryHandler = @Sendable (
        _ datasource: String,
        _ query: DynamicQuery
    ) throws -> DynamicResult

    private let queryHandler: QueryHandler

    public init(queryHandler: @escaping QueryHandler) {
        self.queryHandler = queryHandler
    }

    public func execute(_ request: LassoInlineRequest) throws -> LassoInlineFrame {
        guard request.action == .search ||
                request.action == .find ||
                request.action == .findAll else {
            throw PerfectCRUDLassoError.unsupportedAction(request.action)
        }
        guard let datasource = request.database, datasource.isEmpty == false else {
            throw PerfectCRUDLassoError.missingDatasource
        }
        guard let table = request.table, table.isEmpty == false else {
            throw PerfectCRUDLassoError.missingTable
        }

        let query = DynamicQuery(
            table: table,
            fields: request.returnFields,
            predicates: try request.criteria.map {
                DynamicPredicate(
                    field: $0.field,
                    comparison: try comparison($0.operation),
                    value: dynamicValue($0.value)
                )
            },
            orderings: request.sortFields.enumerated().map { index, field in
                let descending = request.sortOrders.indices.contains(index) &&
                    request.sortOrders[index].lowercased().contains("desc")
                return DynamicOrdering(field: field, descending: descending)
            },
            limit: request.maxRecords,
            offset: request.skipRecords
        )
        let result = try queryHandler(datasource, query)
        return LassoInlineFrame(
            rows: result.rows.map(lassoRow),
            affectedRows: result.affectedRows,
            actionStatement: result.statement
        )
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
}

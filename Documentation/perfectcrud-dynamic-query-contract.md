# PerfectCRUD Dynamic Query Contract

Date: 2026-07-09

## Finding

The Lasso adapter now exposes the connector-neutral boundary:

```swift
public protocol LassoDynamicQueryExecutor: Sendable {
    func execute(_ request: LassoInlineRequest) throws -> LassoInlineFrame
}
```

`LassoDynamicInlineProvider` maps Lasso datasource aliases and delegates the
normalized request to this executor. This is covered by the package tests and smoke
suite.

PerfectCRUD's original query model remains based on compile-time `Codable` forms
and key paths. For Lasso compatibility, the local PerfectCRUD checkout now adds a
sibling dynamic-read API for runtime-selected tables, columns, predicates, and
rows without changing the typed API.

## Implemented PerfectCRUD Additions

The first dynamic-read API slice is implemented locally:

```swift
public enum DynamicValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case bytes(Data)
    case date(Date)
}

public struct DynamicRow: Sendable, Equatable {
    public let values: [String: DynamicValue]
}

public struct DynamicPredicate: Sendable, Equatable {
    public let field: String
    public let comparison: DynamicComparison
    public let value: DynamicValue
}

public struct DynamicQuery: Sendable, Equatable {
    public let table: String
    public let fields: [String]
    public let predicates: [DynamicPredicate]
    public let orderings: [DynamicOrdering]
    public let limit: Int?
    public let offset: Int?
}

public protocol DynamicDatabaseProtocol: DatabaseProtocol {
    func select(_ query: DynamicQuery) throws -> DynamicResult
}
```

The implementation reuses each connector's existing identifier quoting, binding,
execution, logging, and transaction machinery. It does not build SQL with
unquoted page strings.

## Structured Inline Mapping

- `-table` becomes `DynamicQuery.table`.
- Repeated `-ReturnField` values become `fields`.
- Each field argument plus its preceding `-op` becomes a predicate.
- `eq` maps to equality.
- `cn` maps to a bound `LIKE` value containing `%...%`.
- Repeated sort field/order pairs become orderings.
- `-MaxRecords` and `-SkipRecords` become limit and offset.
- Connector rows convert to `LassoDataRow`, preserving null and numeric types.

The closeout and featured corpus fixtures are the first acceptance cases. The
featured case also verifies that nested queries restore the outer inline row.

## Security Boundary

- Resolve datasource aliases (e.g. `catalog_mysql`) through server
  configuration, never page credentials.
- Allowlist datasource aliases and, optionally, tables.
- Quote every runtime identifier through the connector.
- Bind every runtime value.
- Keep raw SQL disabled by default or behind a separate capability.
- Apply configurable maximum rows and execution timeout.
- **"Quote every runtime identifier through the connector" is necessary
  but not sufficient.** Perfect-MySQL's `quote(identifier:)`
  (`MySQLCRUD.swift`) wraps an identifier in backticks but does not
  escape embedded backticks — a crafted identifier can break out of the
  quoting. Real Lasso corpus code can set an inline argument's field name
  dynamically (`#fieldNameVar = value`, where `#fieldNameVar`'s runtime
  value becomes the search/sort/return field — see
  `pages/detail.page.lasso`'s `#product_search = #search_by`), so this
  codebase cannot rely on the connector alone to safely handle an
  arbitrary runtime string as an identifier. `Evaluator.swift`'s
  `validateDynamicFieldLabel(_:)` validates any dynamically-resolved
  argument label against `\A[A-Za-z_][A-Za-z0-9_]*\z` before it becomes
  an `EvaluatedArgument.label` — do not remove or bypass this check when
  touching that code path, and note that `-Table`/`-ReturnField`/
  `-SortField`/`-KeyField` argument *values* reach the same unescaped
  quoting sink through a different, still-unvalidated path (tracked as a
  follow-up, not yet fixed).

## Current Implementation

The first dynamic-read slice has now landed locally:

1. PerfectCRUD exposes `DynamicValue`, `DynamicRow`, `DynamicQuery`,
   `DynamicResult`, and `DynamicDatabaseProtocol`.
2. Perfect-MySQL converts connector rows into `DynamicRow` values.
3. The Lasso adapter has a `PerfectCRUDLassoExecutor` target that converts
   structured `inline` requests into dynamic PerfectCRUD selects.
4. Application-specific datasource aliases are configured only by host/demo/test
   code, not inside PerfectCRUD or Perfect-MySQL.

Generic fixture coverage now exists for Perfect-MySQL rather than relying on
private sample data. See `Documentation/mysql-fixture-testing.md`.

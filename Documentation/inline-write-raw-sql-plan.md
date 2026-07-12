# Inline Write And Raw SQL Plan

Last reviewed: July 10, 2026

## Implementation Status (2026-07-10)

All milestones implemented and unit-tested (61/61 tests pass). Real
end-to-end verification against a live MySQL datasource was intentionally
skipped this pass (Tim's call, to avoid needing to pass live credentials
through the session) — this is unit-test-verified only, not live-verified,
matching how MySQL-dependent tests are gated elsewhere in this ecosystem
(`MYSQL_FIXTURE_TESTS=1`, see `Documentation/mysql-fixture-testing.md`).
A real-corpus regression sweep confirmed no parse/render regressions: every
one of 9 failing pages traces to a pre-existing, already-documented gap
(missing includes, missing builtins, or `inlineNotConfigured` — expected
without a live datasource configured for the sweep), not anything new from
this change. Notably two pages previously failing on unrelated bugs
investigated separately in earlier sessions now get further and stop only
at the expected `inlineNotConfigured`.

Key implementation decisions that turned out differently than the plan's own
"Implementation Milestones" section suggested:
- No separate "connector support in Perfect-MySQL" milestone was needed.
  PerfectCRUD's `Database: DynamicDatabaseProtocol` extension already
  generically implements dynamic SQL via `SQLGenDelegate`/`SQLExeDelegate`,
  so widening `Dynamic.swift` once (`DynamicMutation`, `DynamicSQL`,
  `mutate(_:)`, `execute(_:)`) covers every connector, MySQL included, with
  no per-connector code. Only the new `affectedRowCount()`/
  `lastInsertedID()` protocol methods needed a MySQL-specific
  implementation (`MySQLStmtExeDelegate`, backed by `MySQLStmt`'s existing
  `affectedRows()`/`insertId()`).
- `PerfectCRUDLassoExecutor` took three separate handler closures
  (`queryHandler`/`mutationHandler`/`rawSQLHandler`) rather than a single
  "hand back a database" resolver — `DynamicDatabaseProtocol` has an
  associated type via `DatabaseProtocol`, so it isn't existential-safe
  (`any DynamicDatabaseProtocol` doesn't compile).
- Capability denial (write/raw-SQL disabled for a datasource) returns a
  `LassoInlineFrame` with non-default `LassoErrorState` rather than
  throwing — `pushInlineFrame` already surfaces frame error state through
  `error_currentError` unconditionally, so `protect` isn't even required to
  observe a denial.

Deferred, same as the plan's own stated allowances:
- `-StatementOnly`'s true "compile but don't execute" semantic — parsed
  (`LassoInlineRequest.statementOnly`) but not yet acted on; `Dynamic.swift`
  has no compile-without-executing capability yet.
- `-Key` array-based multi-record update/delete targeting (only
  `-KeyField`/`-KeyValue` single-predicate targeting is implemented).
- Real Lasso 8.5 numeric error codes — denial messages use adapter-local
  codes (`LassoErrorState.InlineErrorCode`, 1001-1006), isolated behind an
  enum so swapping in the real codes later (pending PDF extraction, per
  `error-protect-model-plan`'s still-open Milestone 1) won't touch call
  sites.

## DB Error Framing Update (2026-07-12)

Live connector failures now have an explicit recoverable boundary:
`LassoDatabaseActionError`. `PerfectCRUDLassoExecutor` converts only
`LassoDatabaseActionError` and existing `LassoRecoverableError` values into
`LassoInlineFrame.error`; generic Swift errors still throw so adapter bugs,
missing tables in the inline request, missing handlers, unsupported actions,
and other fatal configuration/programmer failures remain visible.

`lasso-perfect-server` wraps failures thrown by the actual PerfectCRUD MySQL
operation calls (`select`, `mutate`, and `execute`) in
`LassoDatabaseActionError` after datasource-configuration guards pass. This
keeps the policy line crisp: validation/configuration failures are fatal to
the request, while real database action failures become inspectable through
`[error_currentError]` inside the inline body, matching the Lasso error model
described in `Documentation/error-protect-model-plan.md`.

Verification commands:

```bash
COPYFILE_DISABLE=1 swift test --filter perfectCRUD
COPYFILE_DISABLE=1 swift test
```

The first command exercises the focused search/add/update/delete/raw-SQL
framing tests plus the guard that unknown handler throws are not framed. The
full suite is still subject to the macOS codesign metadata issue documented in
`Documentation/swift-test-codesign-workaround.md`; run the xattr workaround if
signing fails before the tests launch.

## Goal

Complete the `inline` execution model beyond structured reads:

- raw SQL execution through explicitly enabled datasource capabilities;
- `-Add`, `-Update`, and `-Delete` actions;
- generated/action statement reporting;
- affected-row and returned-record metadata;
- safe mapping to PerfectCRUD and connector-native Swift APIs without adding
  application-specific methods.

This plan extends the existing dynamic read work in
`Documentation/perfectcrud-dynamic-query-contract.md`.

## Sources Reviewed

- `References/Lasso/Lasso 8.5 Language Guide.pdf`
- `References/Lasso/LP9Docs`
- `Documentation/perfectcrud-dynamic-query-contract.md`
- `Sources/LassoParser/Providers.swift`
- `Sources/LassoPerfectCRUD/PerfectCRUDLassoExecutor.swift`
- `/Users/timtaplin/Perfect-Resurrection/Perfect-CRUD/Sources/PerfectCRUD`
- `/Users/timtaplin/Perfect-Resurrection/Perfect-MySQL/Sources/PerfectMySQL`

Relevant Lasso 8.5 pages:

- 90-92: inline overview, `-StatementOnly`, `Action_Statement`, action list.
- 94-95: `Action_Params` inserts submitted form/URL parameters into an inline.
- 141-145: `-Add`, required parameters, returned inserted record behavior.
- 146-149: `-Update`, `-KeyField`/`-KeyValue`, `-Key`, returned record behavior.
- 150-152: `-Delete`, required parameters, empty found set behavior.
- 154-162: SQL datasource behavior, SQL-specific search operators and options.

## Current State

Already present in the adapter:

- `LassoInlineAction` includes `.add`, `.update`, `.delete`, `.prepare`,
  `.nothing`, and `.rawSQL`.
- `LassoInlineRequest` already captures:
  - datasource/database alias;
  - table;
  - raw `-sql`;
  - return fields;
  - sort fields/orders;
  - max/skip records;
  - key field/value;
  - criteria;
  - raw evaluated arguments.
- `LassoInlineFrame` already carries:
  - rows;
  - found count;
  - affected rows;
  - action statement.
- `PerfectCRUDLassoExecutor` supports structured read actions:
  - `-Search`
  - `-Find`
  - `-FindAll`
- PerfectCRUD already has dynamic read structures and `DynamicResult`.

Missing:

- raw SQL action execution;
- dynamic insert/update/delete APIs in PerfectCRUD;
- write support in `PerfectCRUDLassoExecutor`;
- `-StatementOnly` capture in `LassoInlineRequest`;
- field assignment separation from search criteria for write actions;
- `-Key` array support;
- insert-id/key-field returned row behavior;
- explicit raw SQL capability gating;
- transactional policy for multi-statement/batch raw SQL.

## Lasso Behavior Targets

### Shared Inline Behavior

- Each `inline` represents a database action.
- Nested inlines are legal and should restore the outer frame when the inner
  inline exits.
- `Action_Statement` should expose the generated SQL or connector statement.
- `-StatementOnly` should generate the statement and metadata but not execute
  the action.
- `-Log` can be parsed and stored, but actual log-level routing can be deferred.
- Page-supplied `-Username`/`-Password` should remain syntactically accepted but
  should not directly open arbitrary connections. Datasources must resolve
  through host configuration.

### `-Add`

- Required: `-Database`, `-Table`.
- Recommended: `-KeyField`.
- Field name/value arguments become inserted column values.
- If a key field is present and the connector can determine the new key value,
  return the inserted record when practical.
- If no key field is present or `-MaxRecords=0`, return no rows but set error
  and affected-row metadata.

### `-Update`

- Required: `-Database`, `-Table`.
- Required targeting:
  - `-KeyField` plus `-KeyValue`, or
  - `-Key` array search.
- Field name/value arguments become updated column values.
- When possible, return the updated record or records.
- If `-MaxRecords=0`, skip returning rows.
- Multi-record updates are valid but dangerous; capability policy should allow
  host code to require explicit enablement.

### `-Delete`

- Required: `-Database`, `-Table`.
- Required targeting:
  - `-KeyField` plus `-KeyValue`, or
  - `-Key` array search.
- Returns an empty found set.
- Sets affected-row metadata.
- Must be explicitly capability-gated in demos/tests.

### `-SQL`

- Runs raw SQL against SQL-capable datasources.
- May return rows for `SELECT`.
- May return no rows and affected-row metadata for writes.
- Lasso 8.5 says a single inline can perform batch operations when using SQL.
  For first pass, prefer single statement or connector-supported prepared
  execution; batch/multi-statement execution should be opt-in.
- `-SQL` should be disabled by default unless the datasource alias explicitly
  allows it.

### `-Prepare` / `-Exec`

Defer until raw SQL and normal writes are stable. Document parser/runtime shape
now, but do not implement first unless corpus evidence requires it.

## Recommended PerfectCRUD Extensions

Keep typed CRUD intact and add dynamic siblings.

Suggested structures:

```swift
public struct DynamicMutation: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case insert
        case update
        case delete
    }

    public var action: Action
    public var table: String
    public var values: [String: DynamicValue]
    public var predicates: [DynamicPredicate]
    public var returningFields: [String]
    public var limit: Int?
}

public struct DynamicSQL: Sendable, Equatable {
    public var sql: String
    public var bindings: [DynamicValue]
    public var allowsMultipleStatements: Bool
}
```

Extend `DynamicDatabaseProtocol`:

```swift
func mutate(_ mutation: DynamicMutation) throws -> DynamicResult
func execute(_ sql: DynamicSQL) throws -> DynamicResult
func explain(_ request: DynamicInlineStatementRequest) throws -> DynamicResult
```

Implementation expectations:

- quote dynamic identifiers through existing connector delegates;
- bind dynamic values;
- expose generated SQL in `DynamicResult.statement`;
- expose affected rows;
- for inserts, expose insert id when connector supports it;
- reuse existing transaction helpers for multi-step insert/update returning
  behavior.

## Adapter Mapping

Add to `LassoInlineRequest`:

- `statementOnly: Bool`
- `logLevel: String?`
- `inlineName: String?`
- `host: LassoValue?`
- `key: LassoValue?`
- `fieldAssignments: [LassoInlineAssignment]`
- `writeCriteria: [LassoInlineCriterion]`

Why split assignments from criteria:

- In search actions, unlabeled/name-value field arguments are criteria.
- In add/update actions, those same shapes are values to write.
- In update/delete actions, the target records come from `-KeyField`/`-KeyValue`
  or `-Key`, not from the values being assigned.

Recommended first-pass mapping:

- For `-Add`, all non-reserved name/value arguments become assignments.
- For `-Update`, non-reserved name/value arguments become assignments; target
  predicate comes from `-KeyField`/`-KeyValue`.
- For `-Delete`, target predicate comes from `-KeyField`/`-KeyValue`; ignore
  assignments.
- Defer `-Key` array parsing until pair/staticarray support is stronger, unless
  corpus fixtures require it immediately.

## Capability Policy

Datasource aliases should carry capabilities:

```swift
struct LassoDatasourceCapabilities {
    var allowsSelect: Bool
    var allowsInsert: Bool
    var allowsUpdate: Bool
    var allowsDelete: Bool
    var allowsRawSQL: Bool
    var allowsMultipleStatements: Bool
    var allowedTables: Set<String>?
    var maxRows: Int?
}
```

Default recommendation:

- reads enabled for configured aliases;
- insert/update/delete disabled until explicitly enabled;
- raw SQL disabled until explicitly enabled;
- multiple statements disabled unless explicitly enabled;
- table allowlist optional but recommended for demos.

This keeps the adapter useful for legacy apps without letting arbitrary pages
become uncontrolled database consoles.

## Test Plan

Unit tests:

1. `LassoInlineRequest` maps `-Add` assignments separately from criteria.
2. `-Update` maps `-KeyField`/`-KeyValue` to target predicate and field args to
   assignments.
3. `-Delete` maps target predicate and ignores write assignments.
4. `-SQL` maps to `.rawSQL` and preserves SQL string.
5. `-StatementOnly` returns a frame with statement and no mutation.
6. Raw SQL is rejected unless capability allows it.
7. Delete/update are rejected unless capability allows them.

PerfectCRUD tests:

1. Dynamic insert against generic catalog fixture.
2. Dynamic update by primary key against fixture.
3. Dynamic delete by primary key against fixture.
4. Raw `SELECT` returns dynamic rows.
5. Raw `UPDATE` returns affected rows.
6. Statement-only produces SQL without changing fixture data.

Renderer tests:

1. `[Affected_Count]` reflects write result.
2. `[Action_Statement]` reflects generated SQL inside the inline.
3. Nested write inline restores the outer read frame after exit.
4. `-Add` can expose inserted row fields when key-field return is enabled.

## Implementation Milestones

1. Extend `LassoInlineRequest` to represent statement-only, assignments, and
   write targets.
2. Add dynamic mutation and raw SQL contracts to PerfectCRUD.
3. Implement connector support in Perfect-MySQL using prepared statements and
   existing row conversion.
4. Extend `PerfectCRUDLassoExecutor` for `-Add`, `-Update`, `-Delete`, and
   gated `-SQL`.
5. Add generic catalog/cart mutation fixtures.
6. Add renderer tests for affected count/action statement/returned rows.
7. Revisit `-Key` arrays and `-Prepare`/`-Exec`.

## Open Decisions

- Whether `-Add` should perform a follow-up `SELECT` by insert id by default or
  only when return fields/body access require it.
- Whether raw SQL should accept bindings from Lasso arguments or remain raw
  string only at first.
- Whether multi-statement raw SQL should be completely rejected at adapter level
  or passed through only when the connector explicitly supports it.
- How much legacy `-Host` behavior to emulate. Recommendation: accept and
  ignore by default, with diagnostics, because server-managed datasource aliases
  are safer and fit Perfect better.

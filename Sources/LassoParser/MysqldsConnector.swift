import Foundation

/// A real, invocable `mysqlds` datasource connector — Task #178's last
/// remaining blocker: real corpus (zeroloop/ds's `ds.lasso`) does
/// `.'capi' = \#datasource` (default `'mysqlds'`), then
/// `.'capi'->invoke(#dsinfo)` — before this file, `"mysqlds"` existed only
/// as a recognized STRING inside `inline(...)`'s own `-Host` array
/// handling (`LassoMultiBackendInlineProvider.swift`), never as a
/// standalone tag a script could call/escape-reference to get a real
/// connector object back.
///
/// **Scope decision (v1): only `lcapi_datasourcesearch`/
/// `lcapi_datasourcefindall`** — the two READ actions `ds()`'s own
/// `->find`/`->findall`-shaped calls exercise. `add`/`update`/`delete`/
/// `execsql`/`preparesql`/`tickle`/`closeconnection`/`info`/`random` all
/// throw a clear `LassoRuntimeError.datasourceUnsupportedAction` rather
/// than silently no-opping or guessing at a mapping — a genuinely
/// separate, larger piece of work (write-path SQL generation, prepared
/// statements, connection lifecycle) deferred to a later increment, not
/// something this connector's own architecture would need to change to
/// add later.
///
/// **Architecture**: reuses `context.inlineProvider` (the SAME
/// `LassoDynamicInlineProvider`/`LassoMultiBackendInlineProvider` real
/// `[inline(...)]` calls already route through — `LassoContext`'s own
/// field, already correctly wired for every real server request) rather
/// than inventing a new MySQL connection path. `dsinfo`'s fields are
/// translated into an ordinary `[EvaluatedArgument]` array shaped exactly
/// like a hand-written `inline(-host=array(-datasource='mysqlds', ...),
/// -database=..., -table=..., -search, field=value, ...)` call would
/// produce, then handed to `context.inlineProvider!.executeInline(...)` —
/// the exact same entry point `[inline(...)]` itself calls. No new
/// server-side wiring needed at all: a real request's `context
/// .inlineProvider` is already the right one.
///
/// **Why the tag BODY is real Lasso source, not pure Swift**: the raw
/// `__ds_mysql_execute` bridge (below) is an ordinary
/// `LassoNativeFunction` — it only ever sees a bare `LassoContext`, never
/// a full `Evaluator`, so it has NO way to construct a genuine `ds_result`
/// TYPE instance (unlike invoking an already-DEFINED custom TAG, which
/// `LassoTagInvocationService` supports, instantiating a user-defined
/// TYPE from Swift has no equivalent path in this codebase). Rather than
/// hand-assembling a `ds_result`'s internal `LassoObjectInstance` storage
/// from Swift and hoping it exactly matches `ds_result.lasso`'s own
/// private field layout (fragile, silently drifts if that file changes),
/// `mysqlds` itself is registered as a genuine custom TAG (mirroring
/// `DsInfo.swift`'s own embedded-Lasso-source precedent, just for a tag
/// instead of a type) whose tiny body calls the Swift bridge for the raw
/// data, then constructs `ds_result(...)` via ORDINARY Lasso type
/// instantiation — reusing the real Evaluator's own construction path
/// with zero duplication risk. Targets `ds_result.lasso`'s own 8-parameter
/// `oncreate(index, cols, rows, set, found, affected, error, num)`
/// overload directly (confirmed exact parameter order/types by reading
/// the real corpus file) — the simplest of its five overloads, and the
/// only one that needs no raw INLINE_*_POS/`getset`/thread-var machinery
/// (`dsinfo->getset` is deliberately still stubbed to `void`, per
/// `DsInfo.swift`'s own doc comment — this path never calls it).
enum LassoMysqldsConnector {
    private static let bridgeFunctionName = "__ds_mysql_execute"

    private static let tagBodySource = """
    define mysqlds(dsinfo) => {
        local(__r) = \(bridgeFunctionName)(#dsinfo)
        return ds_result(
            #__r->get(1), #__r->get(2), #__r->get(3), #__r->get(4),
            #__r->get(5), #__r->get(6), #__r->get(7), #__r->get(8)
        )
    }
    """

    static func makeDefinition() -> LassoCustomTagDefinition {
        var parser = ExpressionParser(tagBodySource)
        guard case let .definition(_, name, parameters, body) = parser.parseExpression() else {
            preconditionFailure("mysqlds connector body failed to parse — see MysqldsConnector.swift's own tagBodySource")
        }
        return LassoCustomTagDefinition(name: name, parameters: parameters, body: body)
    }

    static func registerDefaultFunctions(into registry: inout LassoNativeRegistry) {
        registry.register(bridgeFunctionName) { arguments, context in
            try await execute(arguments, context: context)
        }
    }

    private static func execute(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
        guard case let .object(dsinfo)? = arguments.first?.value, dsinfo.typeName == "dsinfo" else {
            throw LassoRuntimeError.unknownFunction(bridgeFunctionName)
        }
        guard let inlineProvider = context.inlineProvider else {
            throw LassoRuntimeError.inlineNotConfigured
        }

        let action = Int(dsinfo.value(for: "action").number ?? 0)
        let requestArguments = try makeInlineArguments(from: dsinfo, action: action)
        let frame = try await inlineProvider.executeInline(arguments: requestArguments, context: context)
        return .array(makeResultTuple(from: frame, dsinfo: dsinfo))
    }

    // MARK: - dsinfo -> inline arguments

    private static func makeInlineArguments(from dsinfo: LassoObjectInstance, action: Int) throws -> [EvaluatedArgument] {
        var arguments: [EvaluatedArgument] = []

        let hostname = dsinfo.value(for: "hostname").outputString
        if !hostname.isEmpty {
            var hostPairs: [LassoValue] = [
                .pair(.string("datasource"), .string("mysqlds")),
                .pair(.string("name"), .string(hostname)),
            ]
            hostPairs.append(contentsOf: portPair(dsinfo))
            hostPairs.append(contentsOf: usernamePair(dsinfo))
            hostPairs.append(contentsOf: passwordPair(dsinfo))
            arguments.append(EvaluatedArgument(label: "host", value: .array(hostPairs)))
        }

        let database = dsinfo.value(for: "databasename").outputString
        if !database.isEmpty {
            arguments.append(EvaluatedArgument(label: "database", value: .string(database)))
        }
        let table = dsinfo.value(for: "tablename").outputString
        if !table.isEmpty {
            arguments.append(EvaluatedArgument(label: "table", value: .string(table)))
        }

        if action == LassoLcapiDatasourceConstants.values["lcapi_datasourcesearch"] {
            arguments.append(EvaluatedArgument(label: "search", value: .boolean(true)))
        } else if action == LassoLcapiDatasourceConstants.values["lcapi_datasourcefindall"] {
            arguments.append(EvaluatedArgument(label: "findall", value: .boolean(true)))
        } else {
            throw LassoRuntimeError.datasourceUnsupportedAction(LassoLcapiDatasourceConstants.name(for: action))
        }

        if case let .array(keyTuples) = dsinfo.value(for: "keycolumns") {
            for tuple in keyTuples {
                arguments.append(contentsOf: try criterionArguments(from: tuple))
            }
        }

        if case let .array(returnColumns) = dsinfo.value(for: "returncolumns") {
            for column in returnColumns {
                let name = column.outputString
                guard !name.isEmpty else { continue }
                arguments.append(EvaluatedArgument(label: "returnfield", value: .string(name)))
            }
        }

        if case let .array(sortColumns) = dsinfo.value(for: "sortColumns") {
            for tuple in sortColumns {
                arguments.append(contentsOf: try sortArguments(from: tuple))
            }
        }

        let maxrows = Int(dsinfo.value(for: "maxrows").number ?? 0)
        if maxrows > 0 {
            arguments.append(EvaluatedArgument(label: "maxrecords", value: .integer(maxrows)))
        }
        let skiprows = Int(dsinfo.value(for: "skiprows").number ?? 0)
        if skiprows > 0 {
            arguments.append(EvaluatedArgument(label: "skiprecords", value: .integer(skiprows)))
        }

        return arguments
    }

    /// One `dsinfo->keycolumns` tuple, real corpus's own `(fieldName,
    /// operator, value)` shape (`ds.lasso`'s private `keyvalue(p::pair)`
    /// helper: `(:#p->name, lcapi_datasourceopeq,.filterinput(#p->value))`).
    /// **Deliberately does NOT support the alternate `(value, operator,
    /// null)` shorthand** `ds.lasso`'s own `keyvalue(p::string)`/
    /// `keyvalue(p::tag)` helpers can also produce (`(:#p,
    /// lcapi_datasourceopeq, null)`) — which field that bare value is
    /// meant to match against isn't derivable from the tuple alone (real
    /// Lasso's own connector-author docs for this shorthand weren't
    /// findable), so a tuple whose value slot is `.null` fails loudly via
    /// `.datasourceMalformedKeyColumn` rather than guessing.
    private static func criterionArguments(from tuple: LassoValue) throws -> [EvaluatedArgument] {
        guard case let .array(parts) = tuple, parts.count == 3 else {
            throw LassoRuntimeError.datasourceMalformedKeyColumn
        }
        let field = parts[0].outputString
        guard !field.isEmpty, parts[2] != .null else {
            throw LassoRuntimeError.datasourceMalformedKeyColumn
        }
        let operatorValue = Int(parts[1].number ?? 0)
        let alias = try inlineOperatorAlias(for: operatorValue)
        return [
            EvaluatedArgument(label: "op", value: .string(alias)),
            EvaluatedArgument(label: field, value: parts[2]),
        ]
    }

    /// One `dsinfo->sortColumns` tuple — real corpus builds these as a
    /// bare `key = value` PAIR (`ds.lasso`: `#sortcolumns->insert(#val->
    /// asstring = lcapi_datasourcesortascending)`), not a 3-element array
    /// like `keycolumns`.
    private static func sortArguments(from tuple: LassoValue) throws -> [EvaluatedArgument] {
        guard case let .pair(field, direction) = tuple else {
            throw LassoRuntimeError.datasourceMalformedKeyColumn
        }
        let directionValue = Int(direction.number ?? 0)
        let order = directionValue == LassoLcapiDatasourceConstants.values["lcapi_datasourcesortdescending"]
            ? "descending" : "ascending"
        return [
            EvaluatedArgument(label: "sortfield", value: .string(field.outputString)),
            EvaluatedArgument(label: "sortorder", value: .string(order)),
        ]
    }

    /// `lcapi_datasourceop*` -> the `-Op=` alias string
    /// `PerfectCRUDLassoExecutor`'s `comparison(_:)` recognizes
    /// (`LassoInlineRequest`'s own doc comment lists the full accepted
    /// set). Integer values are literal, duplicated from
    /// `LassoLcapiDatasourceConstants.values` rather than looked up
    /// dynamically — this file's own tests catch any drift immediately,
    /// and it avoids a force-unwrap chain on a dictionary this file
    /// doesn't own. `opft`/`oprx`/`opnrx` (full-text/regex matching) have
    /// no equivalent in the underlying SQL executor at all — real,
    /// disclosed gaps, not oversights.
    private static let operatorAliases: [Int: String] = [
        20: "eq", 21: "bw", 22: "ew", 23: "cn",
        25: "gt", 26: "gte", 27: "lt", 28: "lte", 32: "neq",
    ]

    private static func inlineOperatorAlias(for value: Int) throws -> String {
        guard let alias = operatorAliases[value] else {
            throw LassoRuntimeError.datasourceUnsupportedOperator(LassoLcapiDatasourceConstants.name(for: value))
        }
        return alias
    }

    private static func portPair(_ dsinfo: LassoObjectInstance) -> [LassoValue] {
        let port = dsinfo.value(for: "hostport").outputString
        guard !port.isEmpty, let portNumber = Int(port) else { return [] }
        return [.pair(.string("port"), .integer(portNumber))]
    }

    private static func usernamePair(_ dsinfo: LassoObjectInstance) -> [LassoValue] {
        let username = dsinfo.value(for: "hostusername").outputString
        guard !username.isEmpty else { return [] }
        return [.pair(.string("username"), .string(username))]
    }

    private static func passwordPair(_ dsinfo: LassoObjectInstance) -> [LassoValue] {
        let password = dsinfo.value(for: "hostpassword").outputString
        guard !password.isEmpty else { return [] }
        return [.pair(.string("password"), .string(password))]
    }

    // MARK: - LassoInlineFrame -> ds_result's 8-parameter oncreate

    /// Builds the 8-element positional array `ds_result(index, cols,
    /// rows, set, found, affected, error, num)` expects, matching that
    /// overload's exact parameter order (confirmed against the real
    /// `ds_result.lasso` source). `set` is always an empty array — this
    /// direct-construction path bypasses the raw INLINE_*_POS/`getset`
    /// protocol entirely, so there's no genuine "raw result set" to pass.
    private static func makeResultTuple(from frame: LassoInlineFrame, dsinfo: LassoObjectInstance) -> [LassoValue] {
        let explicitColumns = arrayStrings(dsinfo.value(for: "returncolumns"))
        let columns = explicitColumns.isEmpty ? deriveColumns(from: frame.rows) : explicitColumns

        var index: [String: LassoValue] = [:]
        for (position, column) in columns.enumerated() {
            index[column] = .integer(position + 1)
        }

        let rows: [LassoValue] = frame.rows.map { row in
            .array(columns.map { row[$0] })
        }

        let error: LassoValue = .array([
            .integer(frame.error.code),
            .string(frame.error.message),
            .string(frame.error.detail ?? ""),
        ])

        return [
            .map(index),
            .array(columns.map { .string($0) }),
            .array(rows),
            .array([]),
            .integer(frame.foundCount),
            .integer(frame.affectedRows),
            error,
            .integer(1),
        ]
    }

    /// `LassoDataRow` is dictionary-backed (see `Providers.swift`'s own
    /// type) — real MySQL column ORDER isn't preserved without an
    /// explicit `dsinfo->returncolumns` list, matching a pre-existing
    /// limitation of that type elsewhere in this codebase, not something
    /// new here. Falls back to the first row's own keys, alphabetized for
    /// determinism, when no explicit return-column list was supplied.
    private static func deriveColumns(from rows: [LassoDataRow]) -> [String] {
        guard let first = rows.first else { return [] }
        return first.mapValue.keys.sorted()
    }

    private static func arrayStrings(_ value: LassoValue) -> [String] {
        guard case let .array(elements) = value else { return [] }
        return elements.map(\.outputString).filter { !$0.isEmpty }
    }
}

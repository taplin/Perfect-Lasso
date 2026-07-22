import Foundation

/// Real Lasso 9's LCAPI datasource-connector constants
/// (lassoguide.com/api/lcapi-reference.html's `datasource_action_t`/
/// operator/sort/type enums) — the values a connector-author reads from
/// `dsinfo->action` and a `dsinfo->keycolumns`/`sortColumns` tuple's
/// operator/direction slot. **Not documented anywhere on the Lasso-facing
/// side** (same situation `DsInfo.swift`'s own doc comment describes for
/// `dsinfo` itself) — this exact 32-name list is reverse-engineered from
/// every real usage site across zeroloop/ds's full source (`grep -ohR
/// 'lcapi_[a-zA-Z_]*' *.lasso | sort -u -f`, Task #178), not guessed at
/// beyond that.
///
/// Registered as ordinary zero-argument native functions returning a
/// fixed, arbitrary-but-stable `.integer` — real corpus only ever
/// compares these for EQUALITY (`#dsinfo->action == lcapi_datasourcesearch`,
/// `case(::add) #dsinfo->action = lcapi_datasourceadd`, tuple membership
/// checks), never bitwise-combines or orders them, so the exact numeric
/// values carry no meaning beyond distinctness — confirmed by grep across
/// the whole `ds` package finding zero `&`/`|`/bitAnd/bitOr usage on any
/// of them.
enum LassoLcapiDatasourceConstants {
    /// Every constant name mapped to its registered integer value —
    /// shared by `registerDefaultFunctions` (below) and
    /// `MysqldsConnector.swift`'s reverse lookup (turning an unsupported
    /// `dsinfo->action`/operator integer back into its real name for a
    /// clear `LassoRuntimeError.datasourceUnsupportedAction`/
    /// `.datasourceUnsupportedOperator` message).
    static let values: [String: Int] = [
        // Actions
        "lcapi_datasourcesearch": 1,
        "lcapi_datasourcefindall": 2,
        "lcapi_datasourceadd": 3,
        "lcapi_datasourceupdate": 4,
        "lcapi_datasourcedelete": 5,
        "lcapi_datasourceExecSQL": 6,
        "lcapi_datasourcepreparesql": 7,
        "lcapi_datasourcetickle": 8,
        "lcapi_datasourceCloseConnection": 9,
        "lcapi_datasourceinfo": 10,
        "lcapi_datasourcerandom": 11,
        // Operators
        "lcapi_datasourceopeq": 20,
        "lcapi_datasourceopbw": 21,
        "lcapi_datasourceopew": 22,
        "lcapi_datasourceopct": 23,
        "lcapi_datasourceopnct": 24,
        "lcapi_datasourceopgt": 25,
        "lcapi_datasourceopgteq": 26,
        "lcapi_datasourceoplt": 27,
        "lcapi_datasourceoplteq": 28,
        "lcapi_datasourceopft": 29,
        "lcapi_datasourceoprx": 30,
        "lcapi_datasourceopnrx": 31,
        "lcapi_datasourceopnot": 32,
        // Sort
        "lcapi_datasourcesortascending": 40,
        "lcapi_datasourcesortdescending": 41,
        "lcapi_datasourcesortcustom": 42,
        // Field types
        "lcapi_datasourcetypestring": 50,
        "lcapi_datasourcetypeinteger": 51,
        "lcapi_datasourcetypeboolean": 52,
        "lcapi_datasourcetypeblob": 53,
        "lcapi_datasourcetypedecimal": 54,
        "lcapi_datasourcetypedate": 55,
    ]

    /// Reverse lookup, for error messages only — see `values`' own doc
    /// comment.
    static func name(for value: Int) -> String {
        values.first { $0.value == value }?.key ?? "<unknown lcapi constant \(value)>"
    }

    static func registerDefaultFunctions(into registry: inout LassoNativeRegistry) {
        for (name, value) in values {
            registry.register(name) { _, _ in .integer(value) }
        }
    }
}

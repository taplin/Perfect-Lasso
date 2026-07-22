import Foundation
import LassoParser
import LassoPerfectCRUD
import PerfectCRUD
import PerfectMySQL

let environment = ProcessInfo.processInfo.environment
guard environment["LASSO_MYSQL_TESTS"] == "1" else {
    print("Skipped live Lasso MySQL smoke test; set LASSO_MYSQL_TESTS=1 to enable it.")
    exit(0)
}

let host = environment["LASSO_MYSQL_HOST"] ?? "127.0.0.1"
let port = environment["LASSO_MYSQL_PORT"].flatMap(Int.init)
let databaseName = environment["LASSO_MYSQL_DATABASE"] ?? "catalog"
let username = environment["LASSO_MYSQL_USER"]
let password = environment["LASSO_MYSQL_PASSWORD"]

let executor = PerfectCRUDLassoExecutor { datasource, query, _ in
    guard datasource == "catalog_mysql" else {
        throw LiveMySQLSmokeError.unknownDatasource(datasource)
    }
    let configuration = try MySQLDatabaseConfiguration(
        database: databaseName,
        host: host,
        port: port,
        username: username,
        password: password
    )
    return try Database(configuration: configuration).select(query)
}

// `nonisolated(unsafe)`: top-level `var` bindings in an executable's
// main.swift are implicitly main-actor-isolated in Swift 6, which blocks
// passing them `inout` across the suspension inside `LassoRenderer.render`'s
// now-`async` signature. This is a one-shot, single-threaded script with no
// concurrent access to `context`, so opting out of isolation here is safe —
// the same reasoning (and precedent) as `AsyncBridge.swift`'s own use of
// `nonisolated(unsafe)` before this phase's conversion.
nonisolated(unsafe) var context = LassoContext(
    globals: ["product_subset": .string(environment["LASSO_DEMO_PRODUCT_SUBSET"] ?? "")],
    inlineProvider: LassoDynamicInlineProvider(executor: executor)
)
let source = """
[inline(-database='catalog_mysql',-table='skus',-op='cn','store_id'=$product_subset,
    -op='cn','featured'='seasonal_sale',-ReturnField='mfr_style_no',-ReturnField='color',
    -MaxRecords=10,-search)]
[records][field('mfr_style_no')]:[field('color')];[/records][/inline]
"""
let output = try await LassoRenderer().render(source, context: &context)
print(output)

enum LiveMySQLSmokeError: Error {
    case unknownDatasource(String)
}

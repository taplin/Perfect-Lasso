import Foundation
import LassoParser
import LassoPerfectFileMaker
import PerfectFileMaker

let environment = ProcessInfo.processInfo.environment
guard environment["LASSO_FILEMAKER_TESTS"] == "1" else {
    print("Skipped live Lasso FileMaker smoke test; set LASSO_FILEMAKER_TESTS=1 to enable it.")
    exit(0)
}

let host = environment["LASSO_FILEMAKER_HOST"] ?? "127.0.0.1"
let port = environment["LASSO_FILEMAKER_PORT"].flatMap(Int.init) ?? 80
let user = environment["LASSO_FILEMAKER_USER"] ?? ""
let password = environment["LASSO_FILEMAKER_PASSWORD"] ?? ""
let datasourceAlias = environment["LASSO_FILEMAKER_DATASOURCE"] ?? "fm_catalog"
let table = environment["LASSO_FILEMAKER_TABLE"] ?? "records"
let useTLS = port == 443
let scheme = useTLS ? "https" : "http"

let executor = PerfectFileMakerLassoExecutor(
    allowWrites: false,
    baseURL: "\(scheme)://\(host):\(port)"
) { query, kind, datasource, _ in
    let server = FileMakerServer(host: host, port: port, userName: user, password: password, useTLS: useTLS)
    do {
        return try await server.query(query)
    } catch let error as LassoFileMakerDatabaseActionError {
        throw error
    } catch {
        throw LassoFileMakerDatabaseActionError(kind: kind, datasource: datasource, underlying: error)
    }
}

// See LassoMySQLSmoke/main.swift's identical comment: a top-level `var` in
// an executable's main.swift is implicitly main-actor-isolated in Swift 6,
// which blocks passing it `inout` across the suspension inside
// `LassoRenderer.render`'s now-`async` signature. Safe here — single-shot,
// single-threaded script, no concurrent access.
nonisolated(unsafe) var context = LassoContext(
    inlineProvider: LassoDynamicInlineProvider(executor: executor)
)
let source = """
[inline(-database='\(datasourceAlias)',-table='\(table)',-maxrecords=3,-findall)]
found_count: [found_count]
[records]record [keyfield_value]:[error_currenterror]
[/records]
[/inline]
"""
let output = try await LassoRenderer().render(source, context: &context)
print(output)

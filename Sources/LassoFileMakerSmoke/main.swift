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

/// Duplicated from `Sources/LassoPerfectServer/AsyncBridge.swift`'s
/// `runAsyncAndWait` -- executable targets can't import one another in
/// SwiftPM, only library targets. `runBlockingOffCooperativePool`'s
/// cooperative-pool isolation isn't needed here: this is a one-shot
/// script with a single serial query, not a server handling concurrent
/// requests on Swift's shared cooperative pool, so there's no thread
/// pool to exhaust.
@Sendable func runAsyncAndWait<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let outcome: Result<T, Error> = DispatchQueue.global(qos: .userInitiated).sync {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var innerOutcome: Result<T, Error>!
        Task {
            do {
                innerOutcome = .success(try await operation())
            } catch {
                innerOutcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return innerOutcome!
    }
    return try outcome.get()
}

let executor = PerfectFileMakerLassoExecutor(
    allowWrites: false,
    baseURL: "\(scheme)://\(host):\(port)"
) { query, kind, datasource in
    let server = FileMakerServer(host: host, port: port, userName: user, password: password, useTLS: useTLS)
    do {
        return try runAsyncAndWait { try await server.query(query) }
    } catch let error as LassoFileMakerDatabaseActionError {
        throw error
    } catch {
        throw LassoFileMakerDatabaseActionError(kind: kind, datasource: datasource, underlying: error)
    }
}

var context = LassoContext(
    inlineProvider: LassoDynamicInlineProvider(executor: executor)
)
let source = """
[inline(-database='\(datasourceAlias)',-table='\(table)',-maxrecords=3,-findall)]
found_count: [found_count]
[records]record [keyfield_value]:[error_currenterror]
[/records]
[/inline]
"""
let output = try LassoRenderer().render(source, context: &context)
print(output)

import Foundation
import LassoParser
import LassoPerfectSession
import PerfectSessionCore
import PerfectSessionMySQL

// Live check that session storage lives in its own dedicated MySQL schema
// (not the site's own application database) and actually persists there --
// the same driver + provider pair `main.swift` wires up for
// LASSO_SESSION_DRIVER=mysql, exercised against a real MySQL server with the
// real config-file field names (mysql.sessionDatabase / mysql.sessionTable),
// not mocked. Mirrors
// `perfectBackedSessionProviderPersistsVariablesAcrossTwoRequestsViaMemoryDriver`
// in Tests/LassoParserTests/LassoParserTests.swift, but resumes a session
// across two real MySQL connections instead of one in-memory driver
// instance, which is the part a mocked test can't verify.

let environment = ProcessInfo.processInfo.environment
guard environment["LASSO_SESSION_MYSQL_TESTS"] == "1" else {
    print("Skipped live Lasso session MySQL smoke test; set LASSO_SESSION_MYSQL_TESTS=1 to enable it.")
    exit(0)
}

MySQLSessionConnector.host = environment["LASSO_MYSQL_HOST"] ?? "127.0.0.1"
if let port = environment["LASSO_MYSQL_PORT"].flatMap(Int.init) {
    MySQLSessionConnector.port = port
}
// Defaults to the dedicated `lasso_sessions` schema, NOT the site's own
// application database -- that separation is the whole point of this check.
MySQLSessionConnector.database = environment["LASSO_MYSQL_DATABASE"] ?? "lasso_sessions"
MySQLSessionConnector.username = environment["LASSO_MYSQL_USER"] ?? ""
MySQLSessionConnector.password = environment["LASSO_MYSQL_PASSWORD"] ?? ""
MySQLSessionConnector.table = environment["LASSO_MYSQL_SESSION_TABLE"] ?? "sessions"

let driver = MySQLSessionDriver()
await driver.setup()

// Request 1: new session, register+set a variable, finalize (saves it).
let firstBridge = PerfectBackedLassoSessionProvider(driver: driver, cookies: [:], remoteAddress: "", userAgent: "")
// `nonisolated(unsafe)`: top-level `var` bindings in an executable's
// main.swift are implicitly main-actor-isolated in Swift 6, which blocks
// passing them `inout` across the suspension inside `LassoRenderer.render`'s
// async signature -- same reasoning as `LassoMySQLSmoke/main.swift`'s own use
// of this, since this is likewise a one-shot, single-threaded script.
nonisolated(unsafe) var firstContext = LassoContext(sessionProvider: firstBridge)
let firstOutput = try await LassoRenderer().render(
    "[session_start('cart')][var(total = 3)][session_addvar('cart','total')][total]",
    context: &firstContext
)
guard firstOutput == "3" else {
    print("FAIL: first request rendered \(firstOutput), expected 3")
    exit(1)
}
let firstActions = await firstBridge.finalize()
guard let token = firstActions.first(where: { $0.call.name == "cart" })?.token else {
    print("FAIL: expected a tracker token from finalize")
    exit(1)
}

// Request 2: a brand-new driver instance and provider, resuming purely via
// the real MySQL row the first request wrote -- this is the part that was
// broken by the "sessions" table collision (the driver's resume() threw
// against the wrong columns and was silently swallowed, so this second
// request always looked like a fresh session).
let secondDriver = MySQLSessionDriver()
let secondBridge = PerfectBackedLassoSessionProvider(
    driver: secondDriver,
    cookies: ["_LassoSessionTracker_cart": token],
    remoteAddress: "", userAgent: ""
)
nonisolated(unsafe) var secondContext = LassoContext(sessionProvider: secondBridge)
let secondOutput = try await LassoRenderer().render(
    "[session_start('cart')][session_addvar('cart','total')][total]",
    context: &secondContext
)
guard secondOutput == "3" else {
    print("FAIL: second request rendered \(secondOutput), expected 3 -- session data did not persist across requests")
    exit(1)
}

print("PASS: session variable persisted across two real MySQL-backed requests via table `\(MySQLSessionConnector.table)`")

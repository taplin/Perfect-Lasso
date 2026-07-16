import Foundation
import LassoParser
import PerfectAdminConsole
import PerfectCRUD
import PerfectFileMaker
import PerfectMySQL

/// `AdminConsoleDelegate` conformer supplying this server's Lasso-specific
/// state to `PerfectAdminConsole` (status sections, datasource list, and
/// on-demand connectivity tests). See `Documentation/lasso-perfect-server.md`'s
/// Admin Console section for the operator-facing setup (`LASSO_ADMIN_*`
/// env vars).
///
/// A plain class, not an actor: `AdminConsoleDelegate` declares
/// `serverPort`/`serverStartTime`/`registeredRoutes` as synchronous (non-
/// `async`) requirements — `AdminConsole`'s own route handlers read them
/// without `await` — and every stored property here is an immutable `let`,
/// so there's no isolation to manage and an actor would only add
/// `nonisolated` ceremony for no benefit.
final class LassoAdminDelegate: AdminConsoleDelegate {
    private let config: ServerConfig
    private let startTime: Date

    init(config: ServerConfig, startTime: Date) {
        self.config = config
        self.startTime = startTime
    }

    // MARK: - Phase 1: status display

    var serverPort: Int { config.port }
    var serverStartTime: Date { startTime }

    /// Matches the actual routes registered in `LassoSiteServer.routes()`
    /// — kept as a literal list rather than introspected from `Routes<...>`
    /// (Perfect-NIO's route tree isn't designed to be enumerated after the
    /// fact); update this alongside any change there.
    var registeredRoutes: [RouteInfo] {
        [
            RouteInfo(uri: "GET /__lasso_health"),
            RouteInfo(uri: "GET /"),
            RouteInfo(uri: "GET /**"),
            RouteInfo(uri: "POST /"),
            RouteInfo(uri: "POST /**"),
        ]
    }

    func additionalStatusSections() async -> [AdminStatusSection] {
        var items: [(key: String, value: String)] = [
            ("Site root", config.siteRoot.path),
            ("Startup folder", config.startupPath?.path ?? "none"),
            ("Render extensions", config.lassoExtensions.sorted().joined(separator: ", ")),
            ("Session driver", config.sessionDriver),
        ]
        if let prefix = config.imageProxyPrefix, let target = config.imageProxyTarget {
            items.append(("Image proxy", "\(prefix) -> \(target)"))
        }
        return [AdminStatusSection(title: "Lasso Site", items: items)]
    }

    // MARK: - Phase 3: datasource management

    /// Sanitized (no credentials) view of every configured datasource,
    /// across both backends. `name` is the Lasso-side alias, lowercased —
    /// already guaranteed unique across both backends by the case-
    /// insensitive collision check in `ServerConfig.load()`.
    func registeredDatasources() async -> [DatasourceInfo] {
        var sources: [DatasourceInfo] = []
        for (alias, schema) in config.datasourceMap {
            sources.append(DatasourceInfo(name: alias.lowercased(), alias: alias, schema: schema, driver: "MySQL"))
        }
        for alias in config.filemakerDatasourceAliases {
            // Real Lasso's FileMaker connector model: database = whole
            // FileMaker file, so the alias itself IS the schema/file name.
            sources.append(DatasourceInfo(name: alias.lowercased(), alias: alias, schema: alias, driver: "FileMaker"))
        }
        return sources.sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    }

    /// `@concurrent`: both branches below perform real, blocking-or-network
    /// connection work (`Database(configuration:)`'s `mysql_real_connect`
    /// call is genuinely synchronous; `FileMakerServer.databaseNames()` is
    /// real network I/O) — matches `PerfectCRUDLassoExecutor.execute(_:)`'s
    /// own `@concurrent` usage (SE-0461) for the identical reason: keep
    /// this off whatever actor/executor called in, not the caller's problem.
    @concurrent
    func testDatasource(name: String) async throws -> DatasourceTestResult {
        let target = name.lowercased()
        if let schema = config.datasourceMap.first(where: { $0.key.lowercased() == target })?.value {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                _ = try Database(configuration: MySQLDatabaseConfiguration(
                    database: schema,
                    host: config.mysqlHost,
                    port: config.mysqlPort,
                    username: config.mysqlUser,
                    password: config.mysqlPassword
                ))
                return .ok(latencyMs: Self.milliseconds(since: start, clock: clock), message: "Connected to MySQL schema '\(schema)'")
            } catch {
                return .failed("MySQL connect failed: \(error)")
            }
        }
        if config.filemakerDatasourceAliases.contains(where: { $0.lowercased() == target }) {
            guard let host = config.filemakerHost else {
                return .failed("No FileMaker host configured")
            }
            let port = config.filemakerPort ?? 80
            let server = FileMakerServer(
                host: host, port: port,
                userName: config.filemakerUser ?? "", password: config.filemakerPassword ?? "",
                useTLS: port == 443
            )
            let clock = ContinuousClock()
            let start = clock.now
            do {
                _ = try await server.databaseNames()
                return .ok(latencyMs: Self.milliseconds(since: start, clock: clock), message: "Connected to FileMaker Server at \(host):\(port)")
            } catch {
                return .failed("FileMaker connect failed: \(error)")
            }
        }
        return .failed("No datasource named '\(name)' is registered")
    }

    /// `Duration.components` is `(seconds, attoseconds)` where `attoseconds`
    /// is only the **sub-second remainder** (0..<1e18), not the total
    /// duration — dropping the `seconds` component here would silently
    /// truncate any test that took a full second or more.
    private static func milliseconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let components = (clock.now - start).components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

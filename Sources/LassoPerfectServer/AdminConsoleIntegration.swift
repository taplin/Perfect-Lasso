import Foundation
import LassoCrawlReport
import LassoParser
import PerfectAdminConsole
import PerfectCRUD
import PerfectFileMaker
import PerfectMySQL

/// `AdminConsoleDelegate` conformer supplying this server's Lasso-specific
/// state to `PerfectAdminConsole` (status sections, datasource list,
/// on-demand connectivity tests, live datasource switching, and a
/// crawl-report action). See `Documentation/lasso-perfect-server.md`'s
/// Admin Console section for the operator-facing setup (`LASSO_ADMIN_*`
/// env vars).
///
/// A plain class, not an actor: `AdminConsoleDelegate` declares
/// `serverPort`/`serverStartTime`/`registeredRoutes` as synchronous (non-
/// `async`) requirements — `AdminConsole`'s own route handlers read them
/// without `await` — and every stored property here is an immutable `let`
/// (the *mutable* live state lives inside `fileMakerRegistry`/`logCapture`,
/// both actors reached through these immutable references), so there's no
/// isolation to manage on this type itself and an actor would only add
/// `nonisolated` ceremony for no benefit.
final class LassoAdminDelegate: AdminConsoleDelegate {
    private let config: ServerConfig
    private let startTime: Date
    private let fileMakerRegistry: FileMakerConnectionRegistry?
    private let logCapture: LogCapture?
    /// This server's own base URL (`http://localhost:<port>`) — needed to
    /// actually run a crawl-report action against real HTTP, matching how
    /// `main.swift`'s `LASSO_CRAWL_REPORT=1` CLI mode calls `CrawlReport.run`.
    private let baseURL: String

    init(
        config: ServerConfig,
        startTime: Date,
        fileMakerRegistry: FileMakerConnectionRegistry?,
        logCapture: LogCapture?,
        baseURL: String
    ) {
        self.config = config
        self.startTime = startTime
        self.fileMakerRegistry = fileMakerRegistry
        self.logCapture = logCapture
        self.baseURL = baseURL
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

    // MARK: - Phase 2: actions

    /// A single custom action for now: trigger a crawl report on demand,
    /// instead of restarting the process with `LASSO_CRAWL_REPORT=1`.
    /// See `Documentation/crawl-report-filtering-plan.md` for the crawler's
    /// own design/history; the one thing that mattered for wiring this in
    /// safely is that `CrawlReport.run(...)` itself never exits the
    /// process — only `main.swift`'s own CLI-mode block (`LASSO_CRAWL_REPORT=1`
    /// at startup) calls `exit(0)` after printing results, and this action
    /// deliberately does not reuse that code path.
    func availableActions() async -> [AdminAction] {
        [
            AdminAction(
                name: "crawl-report",
                label: "Run Crawl Report",
                description: "Request every discovered site page over real HTTP and log a pass/fail summary. Runs in the background; can take several minutes on a large site.",
                category: "data",
                isDestructive: false
            ),
        ]
    }

    func executeAction(_ name: String) async throws -> AdminActionResult {
        guard name == "crawl-report" else {
            return .failed("Unknown action: \(name)")
        }
        let config = self.config
        let baseURL = self.baseURL
        let logCapture = self.logCapture
        // Fire-and-forget, matching main.swift's own CLI-mode crawl Task —
        // a full crawl (~2,000 real pages, sequential requests) can take
        // minutes; blocking this action's HTTP response for that long
        // would make the admin console itself unresponsive for the
        // duration, and there's no exit(0) to wait for here since this
        // server keeps running afterward.
        Task {
            await logCapture?.capture("[crawl-report] started (admin-triggered)")
            let (results, excludedCount) = await CrawlReport.run(
                baseURL: baseURL,
                siteRoot: config.siteRoot,
                extensions: config.lassoExtensions,
                excludePaths: config.crawlExcludePaths
            )
            let cleanCount = results.count { $0.isClean }
            let failingCount = results.count - cleanCount
            await logCapture?.capture(
                "[crawl-report] finished: \(results.count) page(s) crawled, \(cleanCount) clean, \(failingCount) failing, \(excludedCount) excluded"
            )
            // Same JSON-output convention as CLI mode, when configured —
            // an admin-triggered run is exactly the kind of run someone
            // would want to diff against a previous baseline afterward.
            CrawlReport.printAndWrite(results, outputPath: config.crawlReportOutputPath, excludedCount: excludedCount)
        }
        return .ok("Crawl report started in the background — watch the Logs tab for progress and a completion summary.")
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
            guard let (host, port) = await fileMakerRegistry?.resolve(alias: target) else {
                return .failed("No FileMaker host configured")
            }
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

    // MARK: - Phase 5: live datasource config switching

    /// Every known FileMaker connection profile (the shared block plus any
    /// per-alias `host` overrides configured anywhere in the datasources
    /// file — see `FileMakerConnectionRegistry`'s doc comment), with
    /// `isActive` marking whichever one `datasource` currently resolves
    /// to. Empty for a MySQL alias (this project's MySQL connector has no
    /// equivalent per-alias override concept to switch between) or an
    /// unrecognized name — both match the protocol's documented "return
    /// empty to suppress the switcher" contract.
    func availableConfigs(for datasource: String) async -> [DatasourceConfigInfo] {
        guard let fileMakerRegistry else { return [] }
        let profiles = await fileMakerRegistry.availableProfiles(for: datasource.lowercased())
        return profiles.map {
            DatasourceConfigInfo(id: $0.id, label: $0.label, description: "FileMaker Server connection", isActive: $0.isActive)
        }
    }

    /// Re-points `name` at a different, already-known FileMaker connection
    /// profile, live — e.g. switching the primary alias to a dev/backup
    /// server's profile without editing the config file or restarting.
    /// Confirms the switch actually reaches something by running the same
    /// connectivity probe `testDatasource` uses, so a bad switch reports
    /// failure immediately rather than silently pointing at an unreachable
    /// host until the next real page request notices.
    func switchDatasource(name: String, to configID: String) async throws -> DatasourceTestResult {
        guard let fileMakerRegistry else {
            return .failed("No FileMaker connection registry configured")
        }
        guard let profile = await fileMakerRegistry.switchAlias(name, to: configID) else {
            return .failed("Unknown datasource or config id: \(name) -> \(configID)")
        }
        await logCapture?.capture("[admin] datasource-switch \(name) -> \(profile.id) (\(profile.host):\(profile.port))")
        let clock = ContinuousClock()
        let start = clock.now
        let server = FileMakerServer(
            host: profile.host, port: profile.port,
            userName: config.filemakerUser ?? "", password: config.filemakerPassword ?? "",
            useTLS: profile.port == 443
        )
        do {
            _ = try await server.databaseNames()
            return .ok(
                latencyMs: Self.milliseconds(since: start, clock: clock),
                message: "\(name) now using '\(profile.id)' (\(profile.host):\(profile.port))"
            )
        } catch {
            return .failed("Switched to '\(profile.id)', but connectivity check failed: \(error)")
        }
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

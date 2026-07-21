import Foundation
import LassoCrawlReport
import LassoParser
import PerfectAdminConsole
import PerfectCRUD
import PerfectFileMaker
import PerfectFileMakerAdminAPI
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
    /// Live/last-run state for the crawl-report action — see
    /// `CrawlRunTracker`'s doc comment. Defaulted so existing call sites
    /// (including tests) don't need to pass one; tests that want to drive
    /// or inspect tracker state construct their own and pass it in.
    private let crawlTracker: CrawlRunTracker
    /// Handle to the site server's own run loop (`main.swift`'s
    /// `siteServerTask`) — the "restart-server" action cancels this,
    /// gracefully draining in-flight connections, once a freshly spawned
    /// replacement process has proven itself healthy. `Task<Void, Error>`
    /// is unconditionally `Sendable`, so this is safe to store and call
    /// `.cancel()`/`.value` on from any isolation context.
    private let siteServerTask: Task<Void, Error>
    /// Guards against two near-simultaneous restart clicks racing into two
    /// concurrent process spawns. See `RestartCoordinator`.
    private let restartCoordinator: RestartCoordinator
    /// Must be the *same* instance `LassoSiteServer` records real datasource
    /// failures into (`main.swift` passes `siteServer.datasourceFailureTracker`
    /// here) — a separate instance would always read zero, defeating the
    /// whole point. See `DatasourceFailureTracker`'s own doc comment.
    private let datasourceFailureTracker: DatasourceFailureTracker
    /// Live/last-run state for the CWP session janitor — see
    /// `CWPSessionJanitorTracker`'s doc comment (in `Perfect-FileMaker-AdminAPI`,
    /// generic to any consumer of that package, not Lasso-specific).
    private let janitorTracker: CWPSessionJanitorTracker
    /// The same `FMAdminClient` instance `main.swift`'s background poll loop
    /// uses, shared here so the manual "run now" action hits the same
    /// cached Admin API session/token rather than authenticating a second
    /// time. `nil` when `config.cwpJanitorEnabled` is false.
    private let cwpAdminAPIClient: FMAdminClient?
    /// Handle to `main.swift`'s background janitor poll `Task`, cancelled
    /// alongside `siteServerTask` on a successful restart handoff so an
    /// in-flight Admin API call doesn't linger past it. `nil` when the
    /// janitor is disabled.
    private let cwpJanitorTask: Task<Void, Never>?

    init(
        config: ServerConfig,
        startTime: Date,
        fileMakerRegistry: FileMakerConnectionRegistry?,
        logCapture: LogCapture?,
        baseURL: String,
        siteServerTask: Task<Void, Error>,
        crawlTracker: CrawlRunTracker = CrawlRunTracker(),
        restartCoordinator: RestartCoordinator = RestartCoordinator(),
        datasourceFailureTracker: DatasourceFailureTracker = DatasourceFailureTracker(),
        janitorTracker: CWPSessionJanitorTracker = CWPSessionJanitorTracker(),
        cwpAdminAPIClient: FMAdminClient? = nil,
        cwpJanitorTask: Task<Void, Never>? = nil
    ) {
        self.config = config
        self.startTime = startTime
        self.fileMakerRegistry = fileMakerRegistry
        self.logCapture = logCapture
        self.baseURL = baseURL
        self.siteServerTask = siteServerTask
        self.crawlTracker = crawlTracker
        self.restartCoordinator = restartCoordinator
        self.datasourceFailureTracker = datasourceFailureTracker
        self.janitorTracker = janitorTracker
        self.cwpAdminAPIClient = cwpAdminAPIClient
        self.cwpJanitorTask = cwpJanitorTask
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
        if config.crawlSitemapEnabled {
            items.append(("Sitemap discovery", "enabled (\(config.crawlSitemapPath) -> \(config.crawlSitemapOrigin ?? "unconfigured"))"))
        } else {
            items.append(("Sitemap discovery", "disabled"))
        }
        return [
            AdminStatusSection(title: "Lasso Site", items: items),
            AdminStatusSection(title: "CWP Session Janitor", items: await cwpJanitorStatusItems()),
        ]
    }

    private func cwpJanitorStatusItems() async -> [(key: String, value: String)] {
        var items: [(key: String, value: String)] = [
            ("Enabled", config.cwpJanitorEnabled ? "yes" : "no"),
        ]
        guard config.cwpJanitorEnabled else { return items }
        items.append(("Mode", config.cwpJanitorDryRun ? "dry-run (no real disconnects)" : "ARMED (real disconnects)"))
        items.append(("Poll interval", "\(config.cwpJanitorPollIntervalSeconds)s"))
        items.append(("Duration threshold", config.cwpJanitorDurationThresholdSeconds.map { "\($0)s" } ?? "disabled"))
        items.append(("Count threshold", config.cwpJanitorMaxSessions.map { "\($0)" } ?? "disabled"))
        items.append(("Min floor", "\(config.cwpJanitorMinFloor)"))
        items.append(("Max disconnects/sweep", config.cwpJanitorMaxDisconnectsPerSweep.map { "\($0)" } ?? "unlimited"))
        let snapshot = await janitorTracker.snapshot()
        if let lastSweepAt = snapshot.lastSweepAt {
            let when = DateFormatter.localizedString(from: lastSweepAt, dateStyle: .none, timeStyle: .short)
            items.append(("Last sweep", "\(when): \(snapshot.considered) considered, \(snapshot.disconnected) disconnected"))
            if let error = snapshot.error {
                items.append(("Last error", error))
            }
        } else {
            items.append(("Last sweep", "none yet"))
        }
        return items
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
    ///
    /// The action's `description` is built fresh on every call from
    /// `crawlTracker`, so a currently-running crawl shows live "N/M pages"
    /// progress on its chip, and an idle one shows the last run's summary
    /// instead of a static blurb — `AdminWebUI`'s dashboard re-fetches
    /// `/api/actions` on every periodic refresh, so this updates live.
    func availableActions() async -> [AdminAction] {
        let description = await crawlTracker.statusDescription(
            fallback: "Request every discovered site page over real HTTP and log a pass/fail summary. Runs in the background, paced between requests to avoid overloading datasource backends (LASSO_CRAWL_REQUEST_DELAY_MS), and aborts early if the backend starts failing repeatedly (LASSO_CRAWL_CIRCUIT_BREAKER_THRESHOLD) — can take several minutes on a large site."
        )
        var restartDescription = "Spawn a fresh instance, confirm it's healthy, then hand off — the running site keeps serving throughout, no dropped connections. Also how an edited datasource config file gets picked up without a rebuild."
        if config.sessionDriver == "memory" {
            restartDescription += " Uses the in-memory session driver: every logged-in visitor's session is lost on handoff."
        }
        var actions = [
            AdminAction(
                name: "crawl-report",
                label: "Run Crawl Report",
                description: description,
                category: "data",
                isDestructive: false
            ),
            AdminAction(
                name: "restart-server",
                label: "Restart Server",
                description: restartDescription,
                category: "maintenance",
                isDestructive: true
            ),
        ]
        if config.cwpJanitorEnabled {
            // Not `isDestructive` — this runs through the exact same
            // dry-run/threshold-gated sweep as the automatic poll loop
            // (see `executeCWPJanitorRunNow`), never a separate,
            // more-dangerous manual-only path. It's a "run it now instead
            // of waiting for the next poll" convenience, not its own
            // distinct destructive action.
            let janitorDescription = await janitorTracker.statusDescription(
                fallback: "Force an immediate CWP session sweep instead of waiting for the next scheduled poll (every \(config.cwpJanitorPollIntervalSeconds)s). Runs in \(config.cwpJanitorDryRun ? "DRY-RUN" : "ARMED") mode, same as the automatic loop."
            )
            actions.append(AdminAction(
                name: "cwp-janitor-run-now",
                label: "Run CWP Janitor Now",
                description: janitorDescription,
                category: "maintenance",
                isDestructive: false
            ))
        }
        return actions
    }

    func executeAction(_ name: String) async throws -> AdminActionResult {
        if name == "restart-server" {
            return await executeRestartServer()
        }
        if name == "cwp-janitor-run-now" {
            return await executeCWPJanitorRunNow()
        }
        guard name == "crawl-report" else {
            return .failed("Unknown action: \(name)")
        }
        guard await crawlTracker.tryBegin() else {
            let status = await crawlTracker.statusDescription(fallback: "")
            return .failed("A crawl report is already running. \(status)")
        }
        let config = self.config
        let baseURL = self.baseURL
        let logCapture = self.logCapture
        let crawlTracker = self.crawlTracker
        let datasourceFailureTracker = self.datasourceFailureTracker
        // Fire-and-forget, matching main.swift's own CLI-mode crawl Task —
        // a full crawl (~2,000 real pages, sequential requests) can take
        // minutes; blocking this action's HTTP response for that long
        // would make the admin console itself unresponsive for the
        // duration, and there's no exit(0) to wait for here since this
        // server keeps running afterward.
        Task {
            await logCapture?.capture("[crawl-report] started (admin-triggered)")
            await datasourceFailureTracker.reset()
            let (results, excludedCount, abortedByCircuitBreaker, sitemapSummary) = await CrawlReport.run(
                baseURL: baseURL,
                siteRoot: config.siteRoot,
                extensions: config.lassoExtensions,
                excludePaths: config.crawlExcludePaths,
                requestDelayMS: config.crawlRequestDelayMS,
                circuitBreakerThreshold: config.crawlCircuitBreakerThreshold,
                datasourceFailureThreshold: config.crawlDatasourceFailureThreshold,
                currentDatasourceFailureCount: { await datasourceFailureTracker.currentCount() },
                onProgress: { completed, total in
                    Task { await crawlTracker.progress(completed, total) }
                },
                sitemapEnabled: config.crawlSitemapEnabled,
                sitemapEntryPath: config.crawlSitemapPath,
                sitemapAllowedOrigin: config.crawlSitemapOrigin,
                sitemapMaxSubSitemaps: config.crawlSitemapMaxSubSitemaps,
                sitemapMaxURLs: config.crawlSitemapMaxURLs,
                sitemapMaxResponseBytes: config.crawlSitemapMaxResponseBytes
            )
            let cleanCount = results.count { $0.isClean }
            let failingCount = results.count - cleanCount
            let finishedAt = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            let abortNote = abortedByCircuitBreaker ? " ABORTED EARLY — circuit breaker tripped on repeated backend failures." : ""
            let summary = "Last run: \(results.count) page(s), \(cleanCount) clean, \(failingCount) failing, \(excludedCount) excluded (finished \(finishedAt)).\(abortNote)"
            await crawlTracker.finish(summary: summary)
            await logCapture?.capture(
                "[crawl-report] finished: \(results.count) page(s) crawled, \(cleanCount) clean, \(failingCount) failing, \(excludedCount) excluded\(abortedByCircuitBreaker ? " (ABORTED by circuit breaker)" : "")"
            )
            // Same JSON-output convention as CLI mode, when configured —
            // an admin-triggered run is exactly the kind of run someone
            // would want to diff against a previous baseline afterward.
            CrawlReport.printAndWrite(
                results,
                outputPath: config.crawlReportOutputPath,
                excludedCount: excludedCount,
                abortedByCircuitBreaker: abortedByCircuitBreaker,
                sitemapSummary: sitemapSummary
            )
        }
        return .ok("Crawl report started in the background — watch the Logs tab for progress and a completion summary.")
    }

    /// Spawns a fresh copy of this process (inheriting the current environment, so
    /// it re-reads any edited config files) and hands off to it — but only once it's
    /// proven itself genuinely bound and serving via `RestartReadiness`. If it never
    /// does, this instance is left completely untouched: no window with zero
    /// processes serving, ever. See `RestartReadiness.swift`'s doc comment for why a
    /// port health-check probe can't be used here instead (once `Server.alwaysReusePort`
    /// is in play, an ordinary HTTP request to the shared port could land on either
    /// process during the handoff window).
    private func executeRestartServer() async -> AdminActionResult {
        guard await restartCoordinator.tryBegin() else {
            return .failed("A restart is already in progress.")
        }
        guard let executablePath = RestartReadiness.resolveOwnExecutablePath(
            argv0: CommandLine.arguments[0],
            currentDirectoryPath: FileManager.default.currentDirectoryPath,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"]
        ) else {
            await restartCoordinator.reset()
            return .failed("Could not resolve this server's own executable path from '\(CommandLine.arguments[0])' — refusing to restart.")
        }

        let outcome = await RestartReadiness.spawnAndAwaitHealthy(
            executablePath: executablePath,
            environment: ProcessInfo.processInfo.environment,
            markerPrefix: "Listening: http://localhost:"
        )

        switch outcome {
        case .failed(let reason):
            await restartCoordinator.reset()
            await logCapture?.capture("[admin] restart-server failed: \(reason)")
            return .failed("\(reason) This instance was left running, unchanged.")

        case .healthy(let pid):
            await logCapture?.capture("[admin] restart-server: new instance (pid \(pid)) confirmed healthy — handing off")
            let siteServerTask = self.siteServerTask
            let cwpJanitorTask = self.cwpJanitorTask
            let logCapture = self.logCapture
            // Fire-and-forget with a brief delay, matching the crawl-report action's
            // own pattern — this action's HTTP response (below) needs to actually
            // reach the caller before anything disruptive happens.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                // Stop the janitor's poll loop too, so it can't leave an
                // in-flight Admin API call running past this process's exit.
                cwpJanitorTask?.cancel()
                siteServerTask.cancel()
                // Bounded: an actively-executing request or a WebSocket connection has
                // no drain deadline of its own (see main.swift's siteServerTask doc
                // comment) — if draining hasn't finished naturally within this window,
                // force the process down anyway rather than let a stuck restart hang
                // forever. This is graceful restart degrading to an ungraceful one, so
                // it's logged distinctly rather than silently folded into a clean exit.
                let drained = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try? await siteServerTask.value
                        return true
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(10))
                        return false
                    }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }
                if !drained {
                    await logCapture?.capture("[admin] restart-server: old instance did not drain within 10s — forcing exit")
                }
                exit(0)
            }
            var message = "New instance confirmed healthy on port \(config.port) (pid \(pid)). This instance will shut down shortly — reconnect with the new token once it does."
            if config.sessionDriver == "memory" {
                message += " Logged-in sessions were reset."
            }
            return .ok(message)
        }
    }

    /// Forces an immediate CWP session sweep instead of waiting for the
    /// next scheduled poll. Runs through the exact same
    /// `CWPSessionJanitor.sweep(...)` call as `main.swift`'s background
    /// poll loop, respecting whatever `config.cwpJanitorDryRun` is
    /// currently set to — this is never a separate, more-dangerous manual
    /// path. `CWPSessionJanitor.sweep` itself calls `janitorTracker.tryBegin()`,
    /// so this method just checks `isRunning` first to give a clean,
    /// immediate rejection rather than silently doing nothing.
    private func executeCWPJanitorRunNow() async -> AdminActionResult {
        guard let cwpAdminAPIClient else {
            return .failed("CWP session janitor is not enabled or missing Admin API config.")
        }
        if await janitorTracker.isRunning {
            return .failed("A sweep is already running. \(await janitorTracker.statusDescription(fallback: ""))")
        }
        let config = self.config
        let janitorTracker = self.janitorTracker
        let logCapture = self.logCapture
        Task {
            await CWPSessionJanitor.sweep(
                client: cwpAdminAPIClient,
                durationThresholdSeconds: config.cwpJanitorDurationThresholdSeconds,
                maxSessions: config.cwpJanitorMaxSessions,
                minFloor: config.cwpJanitorMinFloor,
                maxDisconnectsPerSweep: config.cwpJanitorMaxDisconnectsPerSweep,
                dryRun: config.cwpJanitorDryRun,
                tracker: janitorTracker,
                log: { line in await logCapture?.capture(line) }
            )
        }
        return .ok("CWP session sweep started in the background (\(config.cwpJanitorDryRun ? "dry-run" : "ARMED")) — watch the Logs tab or status section.")
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

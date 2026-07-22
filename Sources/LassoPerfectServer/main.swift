import Foundation
import LassoCrawlReport
import LassoParser
import LassoPerfectCRUD
import LassoPerfectFileMaker
import LassoPerfectSession
import LassoPerfectSMTP
import PerfectAdminConsole
import PerfectCRUD
import PerfectFileMaker
import PerfectFileMakerAdminAPI
import PerfectMySQL
import PerfectNIO
import PerfectSMTP
import NIOCore
import NIOHTTP1
import NIOPosix
import PerfectSessionCore
import PerfectSessionMySQL

/// A per-alias FileMaker host/port override — see `ServerConfig.filemakerHostOverrides`.
struct FileMakerHostOverride: Sendable {
    let host: String
    let port: Int?
}

struct ServerConfig: Sendable {
    let siteRoot: URL
    let port: Int
    let lassoExtensions: Set<String>
    /// `LASSO_RENDER_EXCLUDE_PATHS` — case-insensitive substrings checked
    /// against a request's site-root-relative path; a match means "serve
    /// this file as plain static content, never attempt to Lasso-render
    /// it," regardless of extension. Same matching semantics as
    /// `crawlExcludePaths` below (`CrawlReport.pathMatchesExclude`) —
    /// deliberately a separate list, not reused automatically, since what
    /// you don't want *crawled* (noisy but harmless) isn't necessarily
    /// what you don't want *served as Lasso* (e.g. vendored JS/HTML that
    /// happens to match a render extension and gets misparsed as Lasso
    /// source on a real, non-crawler request too).
    let renderExcludePaths: [String]
    let startupPath: URL?
    /// `LASSO_APPS_PATH` — the "LassoApps" directory conventionally
    /// holding one subdirectory per installed LassoApp; see
    /// `loadLassoApps`'s doc comment for exactly what subset of real
    /// Lasso 9's LassoApp system this loads (library-style `_init*.lasso`
    /// auto-load only, no HTTP-servable node tree).
    let appsPath: URL?
    /// Lasso-side datasource alias (e.g. `-database='catalog_mysql'`) ->
    /// real MySQL schema name, one entry per configured datasource.
    /// Empty means no live MySQL datasource is configured (inline()
    /// throws inlineNotConfigured). All aliases share one MySQL
    /// connection (mysqlHost/Port/User/Password below) — real corpus
    /// datasources are separate schemas on the same server, not separate
    /// servers; see `Documentation/lasso-perfect-server.md`. Populated
    /// either from `LASSO_DATASOURCE_CONFIG_PATH` (a JSON file, supports
    /// multiple aliases) or the legacy single-alias
    /// `LASSO_DATASOURCE_ALIAS`/`LASSO_MYSQL_DATABASE` env var pair.
    let datasourceMap: [String: String]
    let mysqlHost: String
    let mysqlPort: Int?
    let mysqlDatabase: String
    let mysqlUser: String?
    let mysqlPassword: String?
    /// `LASSO_SESSION_DRIVER=mysql`'s session table name — see
    /// `MySQLConnectionFileConfig.sessionTable`'s doc comment for why this
    /// needs to be overridable (the default "sessions" can collide with an
    /// unrelated table already in `mysqlDatabase`). Default "sessions",
    /// matching `MySQLSessionConnector.table`'s own default.
    let mysqlSessionTable: String
    /// Both default false — see Documentation/inline-write-raw-sql-plan.md's
    /// "Capability Policy": reads enabled by default, writes and raw SQL
    /// disabled until a deployment explicitly opts in.
    let mysqlAllowWrites: Bool
    let mysqlAllowRawSQL: Bool
    /// Lasso-side aliases configured with `type: "filemaker"` in the
    /// datasource config file. Unlike `datasourceMap`, this doesn't map to
    /// a different real name — the alias itself IS the FileMaker
    /// database-file name (real Lasso's documented FileMaker connector
    /// model: database = whole FileMaker file, table = layout). Empty
    /// means no FileMaker datasource is configured.
    let filemakerDatasourceAliases: Set<String>
    let filemakerHost: String?
    let filemakerPort: Int?
    let filemakerUser: String?
    let filemakerPassword: String?
    /// Per-alias FileMaker host/port overrides, keyed by lowercased alias
    /// — e.g. a dev/backup FileMaker Server tested under a second alias
    /// while still using the shared `filemakerUser`/`filemakerPassword`
    /// above. An alias with no entry here uses `filemakerHost`/`filemakerPort`.
    let filemakerHostOverrides: [String: FileMakerHostOverride]
    /// Same default-false, explicit-opt-in policy as `mysqlAllowWrites` —
    /// real Lasso documents no raw-SQL concept for FileMaker at all, so
    /// there's no FileMaker analogue of `mysqlAllowRawSQL`.
    let filemakerAllowWrites: Bool
    /// "memory" (default) or "mysql" — see Documentation/
    /// session-upload-support-plan.md's Milestone 3. PostgreSQL/Redis/
    /// SQLite session backends already exist in Perfect-Session but aren't
    /// wired here yet (deferred: this adapter's only actually-configured
    /// external datasource today is MySQL, via the same LASSO_MYSQL_* vars
    /// reused below — adding the other three is the same mechanical
    /// pattern, not a design gap, once a deployment needs one).
    let sessionDriver: String
    /// `LASSO_CRAWL_REPORT=1` — after the server starts listening, request
    /// every discovered site page over real HTTP (matching a browser's
    /// plain GET), group results by first unsupported construct, print a
    /// report, and exit. Replaces the manual `curl`-in-a-loop sweep used
    /// throughout this project's development sessions. See
    /// `Documentation/lasso-perfect-server.md`'s "Next Compatibility Work".
    let crawlReportMode: Bool
    /// Optional path to also write the full per-page JSON results to,
    /// for diffing between runs. `LASSO_CRAWL_REPORT_PATH`.
    let crawlReportOutputPath: String?
    /// Comma-separated, case-insensitive path substrings to skip during
    /// discovery — `LASSO_CRAWL_EXCLUDE_PATHS` (e.g. "vendor"). Default
    /// empty: no behavior change unless a deployment opts in. See
    /// `Documentation/crawl-report-filtering-plan.md`.
    let crawlExcludePaths: [String]
    /// `LASSO_CRAWL_PATH_LIST` — a file of newline-delimited site-root-
    /// relative paths to crawl instead of the filesystem walk.
    let crawlPathListPath: String?
    /// `LASSO_CRAWL_BASELINE` — a previous run's own JSON output, used with
    /// `crawlOnlyFailure` to re-crawl just one failure bucket.
    let crawlBaselinePath: String?
    /// `LASSO_CRAWL_ONLY_FAILURE` — a substring matched against
    /// `crawlBaselinePath`'s `errorDescription` values.
    let crawlOnlyFailure: String?
    /// `LASSO_CRAWL_REQUEST_DELAY_MS` — a deliberate pause between every
    /// crawled request (default 200ms). This project has repeatedly broken
    /// real FileMaker Server Web Publishing Engine instances by running a
    /// short, purely sequential crawl against them, for reasons not fully
    /// understood from outside the HTTP layer (see
    /// `Documentation/lasso-perfect-server.md`'s FileMaker connectivity
    /// section) — pacing every request, not just FileMaker-touching ones
    /// (the crawler can't know in advance which pages hit a datasource),
    /// is cheap insurance. `0` disables pacing entirely.
    let crawlRequestDelayMS: Int
    /// `LASSO_CRAWL_CIRCUIT_BREAKER_THRESHOLD` — abort the crawl after this
    /// many *consecutive* genuine request-level failures (`statusCode ==
    /// 0`: timeout, connection refused/reset). Deliberately not any `5xx`
    /// — this server's own render-error page returns 500 uniformly for
    /// every kind of Lasso error, ordinary already-cataloged interpreter
    /// gaps included, so status code alone can't tell a real backend
    /// failure apart from completely normal crawl output (confirmed live,
    /// see `CrawlReport.isBackendDistressSignal`'s doc comment). Default
    /// 3. `nil`/unset-to-0 disables the breaker entirely.
    let crawlCircuitBreakerThreshold: Int?
    /// `LASSO_CRAWL_DATASOURCE_FAILURE_THRESHOLD` — a second, independent
    /// circuit breaker: abort the crawl once `datasourceFailureTracker`
    /// (a real-time count of "Datasource action failed" events — see that
    /// type's doc comment) reaches this many failures *since the crawl
    /// started*. Exists because a FileMaker/MySQL connectivity failure
    /// gets caught and converted into a recoverable Lasso error frame the
    /// page inspects via `error_currenterror`, so the page still returns
    /// a normal `200` — invisible to `crawlCircuitBreakerThreshold` above
    /// entirely. Confirmed live (2026-07-17): FileMaker Server's own
    /// admin console showed a climbing session count and a majority of
    /// datasource actions failing while every crawled page's HTTP status
    /// looked completely normal. Default 5. `nil`/unset-to-0 disables it.
    let crawlDatasourceFailureThreshold: Int?
    /// `LASSO_CRAWL_SITEMAP_ENABLED=1` — adds `Sitemap.discoverPaths` as an
    /// ADDITIONAL, merged-in source of crawl candidate paths, alongside
    /// (never instead of) the existing filesystem walk — sees dynamic,
    /// query-parameterized pages (`product.lasso?id=42`) the filesystem
    /// walk can never discover on its own. Off by default: an extra fetch
    /// of site-controlled content shouldn't activate silently for existing
    /// users. See `Sitemap.swift`'s own doc comment for the full
    /// same-origin/SSRF design.
    let crawlSitemapEnabled: Bool
    /// `LASSO_CRAWL_SITEMAP_PATH`, default `"sitemap.xml"` — fetched
    /// relative to `baseURL` (the local server), exactly like every other
    /// crawled page. Never a new arbitrary host.
    let crawlSitemapPath: String
    /// `LASSO_CRAWL_SITEMAP_ORIGIN` — the real, public origin (e.g.
    /// `https://www.realclientsite.com`) the sitemap's `<loc>` entries are
    /// declared to describe. Required (validated http(s)+host) when
    /// `crawlSitemapEnabled` is true — `ServerConfig.load()` throws
    /// `ServerConfigError.missingCrawlSitemapOrigin` otherwise, matching the
    /// existing `missingCWPJanitorAdminAPIConfig` fail-fast-at-startup
    /// convention. Deliberately NEVER inferred from `baseURL` or the
    /// sitemap document itself — see `Sitemap.swift`'s doc comment.
    let crawlSitemapOrigin: String?
    /// `LASSO_CRAWL_SITEMAP_MAX_SUB_SITEMAPS`, default 50. Unlike
    /// `crawlCircuitBreakerThreshold` above, `0`/negative does NOT disable
    /// this — it falls back to the default. These three caps are
    /// security-relevant bounds on content fetched from a site-controlled
    /// source, not a legitimate "turn it off" knob.
    let crawlSitemapMaxSubSitemaps: Int
    /// `LASSO_CRAWL_SITEMAP_MAX_URLS`, default 20,000. See
    /// `crawlSitemapMaxSubSitemaps`'s doc comment re: non-disableable.
    let crawlSitemapMaxURLs: Int
    /// `LASSO_CRAWL_SITEMAP_MAX_RESPONSE_BYTES`, default 10,000,000. See
    /// `crawlSitemapMaxSubSitemaps`'s doc comment re: non-disableable.
    let crawlSitemapMaxResponseBytes: Int
    /// `LASSO_IMAGE_PROXY_PREFIX`/`LASSO_IMAGE_PROXY_TARGET` — a temporary
    /// escape hatch for a local site-root copy that's missing a real image
    /// tree: any request whose resolved path starts with `imageProxyPrefix`
    /// (e.g. "product_images") gets redirected (302) to
    /// `imageProxyTarget` + the remainder of the path instead of being
    /// resolved against the local filesystem — e.g.
    /// "product_images/koi/247.jpg" -> "https://api.iscrubs.com/
    /// product_images/koi/247.jpg". Both unset (the default) disables
    /// this entirely. See Documentation/lasso-perfect-server.md.
    let imageProxyPrefix: String?
    let imageProxyTarget: String?
    /// `LASSO_TAG_FORM_COUNTERS=1` — Phase 3 of tag-form consolidation.
    /// Enables a process-lifetime, cross-request fire-count of which real
    /// tag-open-form (`TagOpenForm`) actually gets recognized during
    /// rendering, exposed at `__lasso_tag_form_counters`. Default false:
    /// zero overhead (a `NoOpTagOpenFormCounterStore`) unless explicitly
    /// enabled for a real-corpus verification sweep. See
    /// `Documentation/` for the design writeup once it lands.
    let tagFormCountersEnabled: Bool
    /// `LASSO_ADMIN_CONSOLE=1` — start `PerfectAdminConsole` (bound to
    /// 127.0.0.1 only, separate from the main site port) alongside the
    /// main server. Off by default: this is an operator tool, not
    /// something a deployment should run unless it's asked for.
    let adminConsoleEnabled: Bool
    /// `LASSO_ADMIN_PORT`, default 8990 — matches `AdminConsole`'s own default.
    let adminConsolePort: Int
    /// `LASSO_ADMIN_TOKEN_PATH` — where the generated bearer token is
    /// written (chmod 600 by `AdminConsole` itself). Defaults under
    /// `NSTemporaryDirectory()`, matching the pattern
    /// `PerfectAdminConsole`'s own README documents.
    let adminConsoleTokenPath: String
    /// `LASSO_ADMIN_TOKEN_ROTATE=1` — force a fresh bearer token on this
    /// launch, overwriting whatever's at `adminConsoleTokenPath`. Default
    /// `false`: the token persists across restarts (reused from the
    /// existing file if present and well-formed) so the dashboard doesn't
    /// need re-pasting after every restart — see `AdminTokenStore`'s doc
    /// comment for why that's safe (the file is already chmod 600).
    let adminConsoleTokenRotate: Bool
    /// `LASSO_CWP_JANITOR_ENABLED=1` — start a background task that polls
    /// FileMaker Server's Admin API and disconnects stale/excess Custom
    /// Web Publishing sessions (see `PerfectFileMakerAdminAPI`'s
    /// `CWPSessionJanitor`). Off by default: an automated, unattended,
    /// timer-triggered cleanup action is a deployment-level opt-in, not a
    /// default. See `Documentation/lasso-perfect-server.md`'s FileMaker
    /// connectivity section for why this exists — WPE (built on Apache
    /// Tomcat internally) can leave orphaned CWP sessions that don't clear
    /// via its own undocumented ~30-minute internal reaper, saturating
    /// real backend capacity in the meantime.
    ///
    /// Confirmed live 2026-07-17 against a real FileMaker Server instance
    /// (and its own published OpenAPI spec) that `GET /clients` does return
    /// CWP connections with `appType == "CWP"` — an earlier same-day
    /// verification pass concluded otherwise because it checked
    /// immediately after firing a test request; there's a short server-side
    /// propagation delay (observed: absent immediately, present ~30s
    /// later) before a new connection appears. Not an issue for this
    /// feature's actual duration-threshold logic (it only ever targets
    /// connections older than a threshold), only for anyone re-verifying
    /// with an immediate post-request check.
    let cwpJanitorEnabled: Bool
    /// `LASSO_CWP_JANITOR_DRY_RUN`, default `true` — when true, the janitor
    /// only logs what it WOULD disconnect and performs zero real
    /// disconnects. Set to `0`/`false`/`no` to arm real disconnects. This
    /// is an unattended timer action with no per-run human confirmation,
    /// so it gets an extra safety gate beyond what a manually-confirmed
    /// action (like "Restart Server", `isDestructive: true`) already has.
    let cwpJanitorDryRun: Bool
    /// `LASSO_CWP_JANITOR_POLL_INTERVAL_SECONDS`, default 60.
    let cwpJanitorPollIntervalSeconds: Int
    /// `LASSO_CWP_JANITOR_DURATION_THRESHOLD_SECONDS` — of the sessions over
    /// `cwpJanitorMaxSessions`, only the ones ALSO open longer than this are
    /// actual disconnect candidates (`nil`/unset-to-0 disables this filter,
    /// so every over-the-limit session is a candidate regardless of age).
    /// A session's age alone, while under the count limit, is never
    /// sufficient reason to disconnect it — see `cwpJanitorMaxSessions`.
    let cwpJanitorDurationThresholdSeconds: Int?
    /// `LASSO_CWP_JANITOR_MAX_SESSIONS` — the ONLY trigger for considering a
    /// disconnect at all. `nil`/unset-to-0 disables the janitor entirely (it
    /// never disconnects anything based on duration alone). When total
    /// active CWP session count exceeds this, the oldest sessions beyond the
    /// limit become candidates — further narrowed by
    /// `cwpJanitorDurationThresholdSeconds` and never taken below
    /// `cwpJanitorMinFloor`.
    let cwpJanitorMaxSessions: Int?
    /// `LASSO_CWP_JANITOR_MIN_FLOOR`, default 5 — never disconnect a CWP
    /// session if doing so would leave fewer than this many CWP sessions
    /// standing. Safety net against a misconfigured threshold zeroing out
    /// real production traffic.
    let cwpJanitorMinFloor: Int
    /// `LASSO_CWP_JANITOR_MAX_DISCONNECTS_PER_SWEEP` — caps how many
    /// sessions a single sweep disconnects, oldest-first. A big backlog
    /// (e.g. after a burst of load) drains gradually over several sweeps
    /// instead of all at once, so a large batch of real, still-in-use
    /// sessions can't all get disconnected in the same instant.
    /// `nil`/unset-to-0 disables the cap (a sweep can disconnect everything
    /// it selects in one pass).
    let cwpJanitorMaxDisconnectsPerSweep: Int?
    /// Admin API host — `datasourceFile?.adminAPI?.host` or
    /// `LASSO_FM_ADMIN_HOST`. Required (throws
    /// `ServerConfigError.missingCWPJanitorAdminAPIConfig` at startup) if
    /// `cwpJanitorEnabled` is true and this is unset. A SEPARATE FileMaker
    /// Server admin account from `filemakerUser`/`filemakerPassword` — the
    /// Admin API (port 16000) is a different interface from classic XML
    /// CWP and needs its own credentials.
    let fmAdminAPIHost: String?
    /// `LASSO_FM_ADMIN_PORT`, default 16000.
    let fmAdminAPIPort: Int
    /// `LASSO_FM_ADMIN_USER`.
    let fmAdminAPIUser: String?
    /// `LASSO_FM_ADMIN_PASSWORD`.
    let fmAdminAPIPassword: String?
    /// `LASSO_FM_ADMIN_TRUST_SELF_SIGNED_TLS`, default `false` — when
    /// `true`, the Admin API client accepts ANY server certificate
    /// unconditionally (see `FMAdminClient.insecureURLSession()`), for a
    /// known dev/test FileMaker Server using its default self-signed
    /// "Claris Self Signed Certificate". Off by default: enabling this
    /// against a server reachable over an untrusted network defeats TLS's
    /// whole purpose.
    let fmAdminAPITrustSelfSignedTLS: Bool
    /// Named SMTP relays — `Documentation/lasso-perfect-smtp-integration-plan.md`
    /// §4.6. Empty means no SMTP relay is configured at all: `LassoSiteServer`
    /// leaves `LassoContext.emailProvider` unset, matching every other
    /// optional backend's degrade-gracefully-when-unconfigured convention
    /// (`email_send` then throws `LassoRuntimeError.emailNotConfigured`).
    /// Populated from `datasourceFile?.smtp` (JSON, supports multiple named
    /// relays) or, when that block is entirely absent, the legacy
    /// single-relay `LASSO_SMTP_*` env-var pair (implicitly named `"primary"`)
    /// — see `SMTPFileConfig`'s doc comment.
    let smtpRelays: [String: SMTPRelaySettings]
    /// `nil` only when `smtpRelays` is empty. Always validated (at `load()`
    /// time) to name a key actually present in `smtpRelays` —
    /// `ServerConfigError.smtpInvalidDefaultRelay` otherwise.
    let smtpDefaultRelay: String?
    /// `LASSO_SMTP_ALLOW_EMAIL_SMTP` / `smtp.allowEmailSMTP` — off-by-default
    /// gate for `email_smtp->open` (Phase D milestone review, BLOCKING #2),
    /// mirroring `mysqlAllowRawSQL`'s exact "dangerous, low-level, opt-in-
    /// only" precedent. Unlike `email_send`/`email_compose` (named-relay
    /// only, no literal `-host`), `email_smtp->open` dials ANY literal
    /// caller-given `-host`/`-port` with zero address-routability filtering
    /// — matching real Lasso's own documented behavior, but a real SSRF
    /// vector against a server that renders arbitrary Lasso source from a
    /// site's own codebase. Default `false`: an operator must explicitly
    /// opt in before any template can use `email_smtp` at all. See
    /// `LassoEmailSMTPType.swift`'s `smtpOpen` for the actual gate check.
    let smtpAllowEmailSMTP: Bool
    /// Resolved, validated, permission-checked DKIM signing config (Phase
    /// F, §4.9a) — `nil` when `smtp.dkim` wasn't configured at all. See
    /// `ServerConfig.resolveSMTPDKIM(_:)` for the validation this applies
    /// and `SMTPDKIMSettings`'s own doc comment for why this type stays
    /// free of any `PerfectSMTP` import.
    let smtpDKIM: SMTPDKIMSettings?
    /// `LASSO_SMTP_ALLOW_DIRECT_MX` / `smtp.allowDirectMX` (Phase F,
    /// §4.9b) — off-by-default opt-in for direct-MX delivery, mirroring
    /// `smtpAllowEmailSMTP`'s exact "new network-reaching capability is
    /// off-by-default" posture. When `true`, `LassoSiteServer.init`'s
    /// `smtp` wiring block registers one additional mailer under the
    /// reserved relay name `"direct-mx"` (§4.9b) — selectable via
    /// `-host='direct-mx'`, no new Lasso-facing dash-param at all.
    let smtpAllowDirectMX: Bool
    /// `LASSO_SMTP_MTA_STS_ENFORCE` / `smtp.mtaSTSEnforce` (Phase F,
    /// §4.9b) — off-by-default; `ServerConfig.load()` throws
    /// `.mtaSTSEnforceRequiresDirectMX` if this is `true` while
    /// `smtpAllowDirectMX` is not also `true` (MTA-STS enforcement has no
    /// meaning without direct-MX delivery — see that error case's own doc
    /// comment).
    let smtpMTASTSEnforce: Bool

    static func load() throws -> ServerConfig {
        let env = ProcessInfo.processInfo.environment
        let rootPath = env["LASSO_SITE_ROOT"] ?? FileManager.default.currentDirectoryPath
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ServerConfigError.invalidSiteRoot(root.path)
        }
        let extensions = (env["LASSO_RENDER_EXTENSIONS"] ?? "lasso,inc,html,htm")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.isEmpty == false }
        // Same extension preferences as page-serving (LASSO_RENDER_EXTENSIONS)
        // apply to the startup folder — a real Lasso instance's file-extension
        // setting governs both, and some deployments register additional
        // custom extensions there too.
        let startupPathValue = env["LASSO_STARTUP_PATH"].map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
        }
        let appsPathValue = env["LASSO_APPS_PATH"].map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
        }

        // LASSO_DATASOURCE_CONFIG_PATH takes priority when set — a JSON
        // file so real credentials never land on a command line or in
        // shell history (matches this project's established "chmod-600
        // credentials file, not a raw password on the command line"
        // practice). Falls back to the legacy single-alias env-var pair
        // for the existing one-datasource smoke-test flow.
        let datasourceFile = try env["LASSO_DATASOURCE_CONFIG_PATH"].map { try DatasourceFileConfig.load(path: $0) }
        let datasourceEntries = datasourceFile?.datasources ?? [:]
        // A config file with no `datasources` entries at all falls back to
        // the legacy single-alias env-var pair — MySQL-only, since it
        // predates FileMaker support.
        let datasourceMap: [String: String] = datasourceEntries.isEmpty
            ? (env["LASSO_DATASOURCE_ALIAS"].map { [$0: env["LASSO_MYSQL_DATABASE"] ?? ""] } ?? [:])
            : datasourceEntries.reduce(into: [:]) { result, entry in
                guard entry.value.type == .mysql else { return }
                result[entry.key] = entry.value.schema ?? entry.key
            }
        let filemakerDatasourceAliases = Set(
            datasourceEntries.filter { $0.value.type == .filemaker }.keys
        )
        let filemakerHostOverrides: [String: FileMakerHostOverride] = datasourceEntries.reduce(into: [:]) { result, entry in
            guard entry.value.type == .filemaker, let host = entry.value.host else { return }
            result[entry.key.lowercased()] = FileMakerHostOverride(host: host, port: entry.value.port)
        }
        // LassoDynamicInlineProvider/LassoMultiBackendInlineProvider both
        // lowercase alias keys themselves (case-insensitive Lasso
        // -database= matching), which traps on a duplicate key — only
        // reachable now that a config file can define more than one
        // alias, across either backend. Catch a case-only collision here
        // instead, where ServerConfig.load() can already throw a clear,
        // actionable config error rather than crashing the whole process
        // at startup.
        let allAliasKeys = Array(datasourceMap.keys) + Array(filemakerDatasourceAliases)
        let lowercasedAliasCount = Dictionary(grouping: allAliasKeys, by: { $0.lowercased() })
        if let collision = lowercasedAliasCount.first(where: { $0.value.count > 1 }) {
            throw ServerConfigError.duplicateDatasourceAlias(collision.value.sorted())
        }
        let filemakerHost = datasourceFile?.filemaker?.host ?? env["LASSO_FILEMAKER_HOST"]
        if filemakerDatasourceAliases.isEmpty == false, filemakerHost == nil {
            throw ServerConfigError.missingFileMakerHost
        }

        let cwpJanitorEnabled = Self.isTruthyEnv(env["LASSO_CWP_JANITOR_ENABLED"])
        let fmAdminAPIHost = datasourceFile?.adminAPI?.host ?? env["LASSO_FM_ADMIN_HOST"]
        let fmAdminAPIPort = datasourceFile?.adminAPI?.port ?? env["LASSO_FM_ADMIN_PORT"].flatMap(Int.init) ?? 16000
        let fmAdminAPIUser = datasourceFile?.adminAPI?.user ?? env["LASSO_FM_ADMIN_USER"]
        let fmAdminAPIPassword = datasourceFile?.adminAPI?.password ?? env["LASSO_FM_ADMIN_PASSWORD"]
        if cwpJanitorEnabled, fmAdminAPIHost == nil || fmAdminAPIUser == nil || fmAdminAPIPassword == nil {
            throw ServerConfigError.missingCWPJanitorAdminAPIConfig
        }

        let renderExcludePaths = (env["LASSO_RENDER_EXCLUDE_PATHS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        // `smtp` block resolution (§4.6) — the JSON block, when present at
        // all, is authoritative and the LASSO_SMTP_* env vars are never
        // consulted (matching this file's stated convention for the
        // `filemaker`/`mysql` blocks). Only a wholly absent `smtp` key
        // falls back to the single-relay env-var smoke-test path.
        var smtpRelays: [String: SMTPRelaySettings] = [:]
        var smtpDefaultRelay: String?
        if let smtpFile = datasourceFile?.smtp {
            for (name, relay) in smtpFile.relays {
                guard let host = relay.host, host.isEmpty == false else {
                    throw ServerConfigError.smtpRelayMissingHost(name)
                }
                let port = relay.port ?? 587
                smtpRelays[name] = SMTPRelaySettings(
                    host: host,
                    port: port,
                    user: relay.user,
                    password: relay.password,
                    tls: relay.tls ?? (port == 465 ? "implicit" : "startTLS")
                )
            }
            if smtpRelays.isEmpty == false {
                let resolved = smtpFile.defaultRelay ?? (smtpRelays.count == 1 ? smtpRelays.keys.first : nil)
                guard let resolved, smtpRelays[resolved] != nil else {
                    throw ServerConfigError.smtpInvalidDefaultRelay(smtpFile.defaultRelay ?? "")
                }
                smtpDefaultRelay = resolved
            }
        } else if let envHost = env["LASSO_SMTP_HOST"] {
            let port = env["LASSO_SMTP_PORT"].flatMap(Int.init) ?? 587
            smtpRelays["primary"] = SMTPRelaySettings(
                host: envHost,
                port: port,
                user: env["LASSO_SMTP_USER"],
                password: env["LASSO_SMTP_PASSWORD"],
                tls: port == 465 ? "implicit" : "startTLS"
            )
            smtpDefaultRelay = "primary"
        }
        // Read independently of whether relays came from the JSON block or
        // the legacy env-var pair — same "always check the JSON block
        // first, fall back to its own dedicated env var" shape
        // `mysqlAllowRawSQL` uses just below, not tied to the relay-source
        // branching above.
        let smtpAllowEmailSMTP = datasourceFile?.smtp?.allowEmailSMTP ?? Self.isTruthyEnv(env["LASSO_SMTP_ALLOW_EMAIL_SMTP"])

        // DKIM (Phase F, §4.9a) — JSON-only (no `LASSO_SMTP_DKIM_*` env-var
        // fallback: unlike the single-boolean flags below, DKIM needs four
        // related fields at once, which doesn't fit this file's flat
        // env-var-per-setting convention — a deliberate scope decision,
        // not an oversight).
        let smtpDKIM = try Self.resolveSMTPDKIM(datasourceFile?.smtp?.dkim)

        // Direct-MX opt-in + MTA-STS enforcement toggle (Phase F, §4.9b) —
        // same "JSON block first, dedicated env var fallback" shape as
        // `smtpAllowEmailSMTP` just above.
        let smtpAllowDirectMX = datasourceFile?.smtp?.allowDirectMX ?? Self.isTruthyEnv(env["LASSO_SMTP_ALLOW_DIRECT_MX"])
        let smtpMTASTSEnforce = datasourceFile?.smtp?.mtaSTSEnforce ?? Self.isTruthyEnv(env["LASSO_SMTP_MTA_STS_ENFORCE"])
        try Self.validateDirectMXConfig(
            allowDirectMX: smtpAllowDirectMX,
            mtaSTSEnforce: smtpMTASTSEnforce,
            relayNames: Set(smtpRelays.keys)
        )

        let crawlSitemapEnabled = Self.isTruthyEnv(env["LASSO_CRAWL_SITEMAP_ENABLED"])
        let crawlSitemapOrigin = env["LASSO_CRAWL_SITEMAP_ORIGIN"]
        if crawlSitemapEnabled {
            guard let origin = crawlSitemapOrigin,
                  let originURL = URL(string: origin),
                  let originScheme = originURL.scheme?.lowercased(),
                  originScheme == "http" || originScheme == "https",
                  originURL.host != nil else {
                throw ServerConfigError.missingCrawlSitemapOrigin
            }
        }

        return ServerConfig(
            siteRoot: root,
            port: env["LASSO_SERVER_PORT"].flatMap(Int.init) ?? 8181,
            lassoExtensions: Set(extensions),
            renderExcludePaths: renderExcludePaths,
            startupPath: startupPathValue,
            appsPath: appsPathValue,
            datasourceMap: datasourceMap,
            mysqlHost: datasourceFile?.mysql?.host ?? env["LASSO_MYSQL_HOST"] ?? "localhost",
            mysqlPort: datasourceFile?.mysql?.port ?? env["LASSO_MYSQL_PORT"].flatMap(Int.init),
            mysqlDatabase: datasourceFile?.mysql?.sessionDatabase ?? env["LASSO_MYSQL_DATABASE"] ?? "",
            mysqlUser: datasourceFile?.mysql?.user ?? env["LASSO_MYSQL_USER"],
            mysqlPassword: datasourceFile?.mysql?.password ?? env["LASSO_MYSQL_PASSWORD"],
            mysqlSessionTable: datasourceFile?.mysql?.sessionTable ?? env["LASSO_MYSQL_SESSION_TABLE"] ?? "sessions",
            mysqlAllowWrites: datasourceFile?.mysql?.allowWrites ?? Self.isTruthyEnv(env["LASSO_MYSQL_ALLOW_WRITES"]),
            mysqlAllowRawSQL: datasourceFile?.mysql?.allowRawSQL ?? Self.isTruthyEnv(env["LASSO_MYSQL_ALLOW_RAW_SQL"]),
            filemakerDatasourceAliases: filemakerDatasourceAliases,
            filemakerHost: filemakerHost,
            filemakerPort: datasourceFile?.filemaker?.port ?? env["LASSO_FILEMAKER_PORT"].flatMap(Int.init),
            filemakerUser: datasourceFile?.filemaker?.user ?? env["LASSO_FILEMAKER_USER"],
            filemakerPassword: datasourceFile?.filemaker?.password ?? env["LASSO_FILEMAKER_PASSWORD"],
            filemakerHostOverrides: filemakerHostOverrides,
            filemakerAllowWrites: datasourceFile?.filemaker?.allowWrites ?? Self.isTruthyEnv(env["LASSO_FILEMAKER_ALLOW_WRITES"]),
            sessionDriver: (env["LASSO_SESSION_DRIVER"] ?? "memory").lowercased(),
            crawlReportMode: Self.isTruthyEnv(env["LASSO_CRAWL_REPORT"]),
            crawlReportOutputPath: env["LASSO_CRAWL_REPORT_PATH"],
            crawlExcludePaths: (env["LASSO_CRAWL_EXCLUDE_PATHS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false },
            crawlPathListPath: env["LASSO_CRAWL_PATH_LIST"],
            crawlBaselinePath: env["LASSO_CRAWL_BASELINE"],
            crawlOnlyFailure: env["LASSO_CRAWL_ONLY_FAILURE"],
            crawlRequestDelayMS: env["LASSO_CRAWL_REQUEST_DELAY_MS"].flatMap(Int.init) ?? 200,
            // `0` (explicit or default-absent-but-parsed-as-0) disables the
            // breaker — `Int?` isn't reachable as `nil` through env vars
            // otherwise, since an unset var already falls back to the `3`
            // default rather than to `nil`.
            crawlCircuitBreakerThreshold: {
                let configured = env["LASSO_CRAWL_CIRCUIT_BREAKER_THRESHOLD"].flatMap(Int.init) ?? 3
                return configured > 0 ? configured : nil
            }(),
            crawlDatasourceFailureThreshold: {
                let configured = env["LASSO_CRAWL_DATASOURCE_FAILURE_THRESHOLD"].flatMap(Int.init) ?? 5
                return configured > 0 ? configured : nil
            }(),
            crawlSitemapEnabled: crawlSitemapEnabled,
            crawlSitemapPath: env["LASSO_CRAWL_SITEMAP_PATH"] ?? "sitemap.xml",
            crawlSitemapOrigin: crawlSitemapOrigin,
            // These three are security-relevant bounds on content fetched
            // from a site-controlled source, not a legitimate "turn it
            // off" knob — unlike the circuit-breaker thresholds above,
            // 0/negative falls back to the default rather than disabling.
            crawlSitemapMaxSubSitemaps: {
                let configured = env["LASSO_CRAWL_SITEMAP_MAX_SUB_SITEMAPS"].flatMap(Int.init) ?? 50
                return configured > 0 ? configured : 50
            }(),
            crawlSitemapMaxURLs: {
                let configured = env["LASSO_CRAWL_SITEMAP_MAX_URLS"].flatMap(Int.init) ?? 20_000
                return configured > 0 ? configured : 20_000
            }(),
            crawlSitemapMaxResponseBytes: {
                let configured = env["LASSO_CRAWL_SITEMAP_MAX_RESPONSE_BYTES"].flatMap(Int.init) ?? 10_000_000
                return configured > 0 ? configured : 10_000_000
            }(),
            imageProxyPrefix: env["LASSO_IMAGE_PROXY_PREFIX"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            imageProxyTarget: env["LASSO_IMAGE_PROXY_TARGET"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            tagFormCountersEnabled: Self.isTruthyEnv(env["LASSO_TAG_FORM_COUNTERS"]),
            adminConsoleEnabled: Self.isTruthyEnv(env["LASSO_ADMIN_CONSOLE"]),
            adminConsolePort: env["LASSO_ADMIN_PORT"].flatMap(Int.init) ?? 8990,
            adminConsoleTokenPath: env["LASSO_ADMIN_TOKEN_PATH"]
                ?? (NSTemporaryDirectory() + "lasso-perfect-server-admin.token"),
            adminConsoleTokenRotate: Self.isTruthyEnv(env["LASSO_ADMIN_TOKEN_ROTATE"]),
            cwpJanitorEnabled: cwpJanitorEnabled,
            cwpJanitorDryRun: Self.isFalsyEnv(env["LASSO_CWP_JANITOR_DRY_RUN"]) == false,
            cwpJanitorPollIntervalSeconds: env["LASSO_CWP_JANITOR_POLL_INTERVAL_SECONDS"].flatMap(Int.init) ?? 60,
            cwpJanitorDurationThresholdSeconds: {
                let configured = env["LASSO_CWP_JANITOR_DURATION_THRESHOLD_SECONDS"].flatMap(Int.init) ?? 150
                return configured > 0 ? configured : nil
            }(),
            cwpJanitorMaxSessions: {
                let configured = env["LASSO_CWP_JANITOR_MAX_SESSIONS"].flatMap(Int.init) ?? 0
                return configured > 0 ? configured : nil
            }(),
            cwpJanitorMinFloor: env["LASSO_CWP_JANITOR_MIN_FLOOR"].flatMap(Int.init) ?? 5,
            cwpJanitorMaxDisconnectsPerSweep: {
                let configured = env["LASSO_CWP_JANITOR_MAX_DISCONNECTS_PER_SWEEP"].flatMap(Int.init) ?? 0
                return configured > 0 ? configured : nil
            }(),
            fmAdminAPIHost: fmAdminAPIHost,
            fmAdminAPIPort: fmAdminAPIPort,
            fmAdminAPIUser: fmAdminAPIUser,
            fmAdminAPIPassword: fmAdminAPIPassword,
            fmAdminAPITrustSelfSignedTLS: Self.isTruthyEnv(env["LASSO_FM_ADMIN_TRUST_SELF_SIGNED_TLS"]),
            smtpRelays: smtpRelays,
            smtpDefaultRelay: smtpDefaultRelay,
            smtpAllowEmailSMTP: smtpAllowEmailSMTP,
            smtpDKIM: smtpDKIM,
            smtpAllowDirectMX: smtpAllowDirectMX,
            smtpMTASTSEnforce: smtpMTASTSEnforce
        )
    }

    private static func isTruthyEnv(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    /// Like `isTruthyEnv`, but for flags that default to `true` when unset
    /// (e.g. `LASSO_CWP_JANITOR_DRY_RUN`, which must default to dry-run-on
    /// — a `nil` env var means "stay safe," not "stay off"). Only an
    /// explicit `0`/`false`/`no` value flips it to `false`.
    private static func isFalsyEnv(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["0", "false", "no"].contains(value.lowercased())
    }
}

/// `LASSO_DATASOURCE_CONFIG_PATH` — a JSON file with real datasource
/// connection details and a `datasources` map (Lasso-side alias -> which
/// backend it lives on). Real credentials belong in this file, not on the
/// command line or in an env var (shell history, `ps`, and process
/// environment inspection all leak env vars far more easily than a file
/// permissioned `chmod 600`, which this file should be). Every MySQL
/// alias shares one MySQL connection, and every FileMaker alias shares
/// one FileMaker Server connection — real corpus datasources are separate
/// schemas/files on the same server, not separate servers. See
/// `Documentation/lasso-perfect-server.md`.
///
/// Current shape:
/// ```json
/// {
///   "mysql": {"host": "...", "port": 3306, "user": "...", "password": "...",
///             "sessionDatabase": "...", "sessionTable": "...",
///             "allowWrites": false, "allowRawSQL": false},
///   "filemaker": {"host": "...", "port": 80, "user": "...", "password": "...",
///                 "allowWrites": false},
///   "adminAPI": {"host": "...", "port": 16000, "user": "...", "password": "..."},
///   "datasources": {
///     "some_mysql_alias": {"type": "mysql", "schema": "some_schema"},
///     "some_filemaker_alias": {"type": "filemaker"}
///   }
/// }
/// ```
/// Back-compat: a config file written before FileMaker support — flat
/// top-level `host`/`port`/`user`/`password`/`sessionDatabase`/
/// `sessionTable`/`allowWrites`/`allowRawSQL` fields (read as the `mysql` block when no
/// nested `mysql` key is present) and a `datasources` map of bare
/// `"alias": "schemaName"` strings (read as `{type: "mysql", schema:
/// "schemaName"}`) — still decodes and behaves identically.
struct DatasourceFileConfig: Decodable {
    var mysql: MySQLConnectionFileConfig?
    var filemaker: FileMakerConnectionFileConfig?
    var adminAPI: FileMakerAdminAPIFileConfig?
    var smtp: SMTPFileConfig?
    var datasources: [String: DatasourceEntry]

    private enum CodingKeys: String, CodingKey {
        case mysql, filemaker, adminAPI, smtp, datasources
        case host, port, user, password, sessionDatabase, sessionTable, allowWrites, allowRawSQL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        datasources = try container.decodeIfPresent([String: DatasourceEntry].self, forKey: .datasources) ?? [:]
        filemaker = try container.decodeIfPresent(FileMakerConnectionFileConfig.self, forKey: .filemaker)
        adminAPI = try container.decodeIfPresent(FileMakerAdminAPIFileConfig.self, forKey: .adminAPI)
        smtp = try container.decodeIfPresent(SMTPFileConfig.self, forKey: .smtp)
        if let nestedMySQL = try container.decodeIfPresent(MySQLConnectionFileConfig.self, forKey: .mysql) {
            mysql = nestedMySQL
        } else {
            let flatHost = try container.decodeIfPresent(String.self, forKey: .host)
            let flatPort = try container.decodeIfPresent(Int.self, forKey: .port)
            let flatUser = try container.decodeIfPresent(String.self, forKey: .user)
            let flatPassword = try container.decodeIfPresent(String.self, forKey: .password)
            let flatSessionDatabase = try container.decodeIfPresent(String.self, forKey: .sessionDatabase)
            let flatSessionTable = try container.decodeIfPresent(String.self, forKey: .sessionTable)
            let flatAllowWrites = try container.decodeIfPresent(Bool.self, forKey: .allowWrites)
            let flatAllowRawSQL = try container.decodeIfPresent(Bool.self, forKey: .allowRawSQL)
            let anyFlatFieldPresent = flatHost != nil || flatPort != nil || flatUser != nil ||
                flatPassword != nil || flatSessionDatabase != nil || flatSessionTable != nil ||
                flatAllowWrites != nil || flatAllowRawSQL != nil
            mysql = anyFlatFieldPresent ? MySQLConnectionFileConfig(
                host: flatHost,
                port: flatPort,
                user: flatUser,
                password: flatPassword,
                sessionDatabase: flatSessionDatabase,
                sessionTable: flatSessionTable,
                allowWrites: flatAllowWrites,
                allowRawSQL: flatAllowRawSQL
            ) : nil
        }
    }

    static func load(path: String) throws -> DatasourceFileConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DatasourceFileConfig.self, from: data)
    }
}

struct MySQLConnectionFileConfig: Decodable {
    var host: String?
    var port: Int?
    var user: String?
    var password: String?
    /// Schema `LASSO_SESSION_DRIVER=mysql` stores session data in — a
    /// separate concern from `datasources` (which maps Lasso-side inline
    /// datasource aliases to their own schemas), since session storage
    /// isn't itself an inline-queryable Lasso datasource. Falls back to
    /// `LASSO_MYSQL_DATABASE` when omitted.
    var sessionDatabase: String?
    /// Table `LASSO_SESSION_DRIVER=mysql` stores session rows in, within
    /// `sessionDatabase`. Defaults to "sessions" (matching
    /// `MySQLSessionConnector.table`'s own default) when omitted — override
    /// this if `sessionDatabase` already has an unrelated "sessions" table
    /// (e.g. another application's own session/user table in the same
    /// schema), since Perfect-Lasso's MySQL session driver otherwise throws
    /// against the wrong columns on every read/write and silently falls
    /// back to creating a fresh session each time.
    var sessionTable: String?
    var allowWrites: Bool?
    var allowRawSQL: Bool?
}

struct FileMakerConnectionFileConfig: Decodable {
    var host: String?
    var port: Int?
    var user: String?
    var password: String?
    var allowWrites: Bool?
}

/// `LASSO_FM_ADMIN_*` config-file block — a SEPARATE FileMaker Server admin
/// account from `filemaker`'s CWP credentials, used only by the CWP session
/// janitor to call the Admin API (port 16000, not the CWP port). Credentials
/// belong here (chmod-600 JSON file), matching this project's established
/// practice, not on the command line/raw env var.
struct FileMakerAdminAPIFileConfig: Decodable {
    var host: String?
    var port: Int?
    var user: String?
    var password: String?
}

/// `smtp` config-file block — `Documentation/lasso-perfect-smtp-integration-plan.md`
/// §4.6. Named relays, never a single bare host — `email_send`'s `-host`
/// dash-param selects one of these *names*, it never dials an arbitrary
/// caller-supplied literal host (§5's SSRF-safe design). Shape:
/// ```json
/// {
///   "smtp": {
///     "relays": {
///       "primary": {"host": "...", "port": 587, "user": "...", "password": "...", "tls": "startTLS"},
///       "marketing": {"host": "...", "port": 587, "user": "...", "password": "..."}
///     },
///     "defaultRelay": "primary",
///     "allowEmailSMTP": false
///   }
/// }
/// ```
/// `defaultRelay` may be omitted only when exactly one relay is configured
/// (it's then implied); two or more relays with no `defaultRelay` is a
/// startup error (`ServerConfigError.smtpInvalidDefaultRelay`), same as a
/// `defaultRelay` naming a relay absent from `relays`.
///
/// `allowEmailSMTP` (Phase D milestone review, BLOCKING #2) gates
/// `email_smtp->open` specifically — see `ServerConfig.smtpAllowEmailSMTP`'s
/// doc comment for the full rationale. Default `false`, same
/// off-by-default policy as `mysql.allowRawSQL`/`mysql.allowWrites`.
///
/// Deliberately does NOT include `allowDirectMX`/`dkimKeyPath`/
/// `dkimSelector`/`dkimDomain` yet — Phase A's scope is relay config only;
/// those are Phase D/F per the plan's phasing (§6), and adding them now
/// would scope-creep this config block ahead of the DKIM-key-permission
/// hardening (§4.6) that phase also requires.
struct SMTPFileConfig: Decodable {
    var relays: [String: SMTPRelayFileConfig]
    var defaultRelay: String?
    var allowEmailSMTP: Bool?
    /// `dkim` (Phase F, §4.9a) — `domain`/`selector`/`keyPath` required
    /// together (`ServerConfig.resolveSMTPDKIM(_:)` throws
    /// `.smtpIncompleteDKIMConfig` if only one or two are set); `keyType`
    /// optional, defaults `"rsa"`.
    var dkim: SMTPDKIMFileConfig?
    /// `allowDirectMX` (Phase F, §4.9b) — off by default, matching
    /// `allowEmailSMTP`'s exact "new network-reaching capability is
    /// off-by-default" posture.
    var allowDirectMX: Bool?
    /// `mtaSTSEnforce` (Phase F, §4.9b) — off by default; meaningless (and
    /// rejected at startup) unless `allowDirectMX` is also `true` — see
    /// `ServerConfigError.mtaSTSEnforceRequiresDirectMX`.
    var mtaSTSEnforce: Bool?

    init(
        relays: [String: SMTPRelayFileConfig] = [:],
        defaultRelay: String? = nil,
        allowEmailSMTP: Bool? = nil,
        dkim: SMTPDKIMFileConfig? = nil,
        allowDirectMX: Bool? = nil,
        mtaSTSEnforce: Bool? = nil
    ) {
        self.relays = relays
        self.defaultRelay = defaultRelay
        self.allowEmailSMTP = allowEmailSMTP
        self.dkim = dkim
        self.allowDirectMX = allowDirectMX
        self.mtaSTSEnforce = mtaSTSEnforce
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relays = try container.decodeIfPresent([String: SMTPRelayFileConfig].self, forKey: .relays) ?? [:]
        defaultRelay = try container.decodeIfPresent(String.self, forKey: .defaultRelay)
        allowEmailSMTP = try container.decodeIfPresent(Bool.self, forKey: .allowEmailSMTP)
        dkim = try container.decodeIfPresent(SMTPDKIMFileConfig.self, forKey: .dkim)
        allowDirectMX = try container.decodeIfPresent(Bool.self, forKey: .allowDirectMX)
        mtaSTSEnforce = try container.decodeIfPresent(Bool.self, forKey: .mtaSTSEnforce)
    }

    private enum CodingKeys: String, CodingKey { case relays, defaultRelay, allowEmailSMTP, dkim, allowDirectMX, mtaSTSEnforce }
}

/// `smtp.dkim` config-file sub-block (Phase F, §4.9a) — see
/// `SMTPFileConfig.dkim`'s doc comment for the required-together rule and
/// `ServerConfig.resolveSMTPDKIM(_:)` for the actual validation/loading
/// this decodes into.
struct SMTPDKIMFileConfig: Decodable {
    var domain: String?
    var selector: String?
    var keyPath: String?
    var keyType: String?
}

/// One named relay's connection settings. `host` is optional here (not
/// required by the JSON grammar itself) so a relay entry with a missing
/// host fails with a clear `ServerConfigError.smtpRelayMissingHost` at
/// `ServerConfig.load()` time — matching `FileMakerConnectionFileConfig`'s
/// identical "optional in the Decodable shape, required by a startup
/// check" convention — rather than an opaque `DecodingError` from
/// `JSONDecoder` itself.
///
/// `tls`: `"none"` | `"startTLS"` | `"implicit"` (case-insensitive).
/// Unset defaults to `"implicit"` when `port == 465`, `"startTLS"`
/// otherwise — the same port-465-implies-implicit-TLS convention `-ssl`
/// itself would use if this design honored it as a per-call override
/// (see `LassoSMTPMessageBuilder`'s doc comment for why it deliberately
/// does not).
struct SMTPRelayFileConfig: Decodable {
    var host: String?
    var port: Int?
    var user: String?
    var password: String?
    var tls: String?
}

/// Resolved (JSON- or env-var-sourced, defaults applied) settings for one
/// named SMTP relay — `ServerConfig.smtpRelays`' value type.
/// `LassoPerfectSMTP.LassoSMTPMailerRegistry` is what actually turns these
/// into a live `RelayConfig`/`SMTPMailer`; this type stays free of any
/// `PerfectSMTP` import so `ServerConfig`'s own compilation doesn't need
/// one (`tls` is carried as the same raw string `SMTPRelayFileConfig` uses,
/// parsed into a real `TLSMode` only where `PerfectSMTP` is already
/// imported).
struct SMTPRelaySettings: Sendable {
    let host: String
    let port: Int
    let user: String?
    let password: String?
    let tls: String
}

/// Resolved (validated, permission-checked, file-contents-read-once) DKIM
/// signing config for the whole process (Phase F, §4.9a) —
/// `ServerConfig.smtpDKIM`'s value type, produced by
/// `ServerConfig.resolveSMTPDKIM(_:)`. Deliberately free of any
/// `PerfectSMTP` import, matching `SMTPRelaySettings`'s identical
/// reasoning above — `LassoSiteServer.init`'s `smtp` wiring block (where
/// `PerfectSMTP` is already imported) is what actually turns
/// `keyMaterial` into a real `SigningKey`/`DKIMSigner`.
struct SMTPDKIMSettings: Sendable {
    let domain: String
    let selector: String
    /// `"rsa"` or `"ed25519"` — already validated by `resolveSMTPDKIM(_:)`;
    /// no other value can reach this point.
    let keyType: String
    /// `keyPath`'s raw file bytes, read exactly once here at config-
    /// resolution time (§4.6's "read it once at startup... never
    /// per-call" instruction) — UTF-8 PEM text for `"rsa"`, UTF-8 base64
    /// text for `"ed25519"` (this implementation's own documented file
    /// format for that key type — see `resolveSMTPDKIM(_:)`'s doc comment
    /// for why: neither real Lasso doc source mentions DKIM at all, so
    /// there's no corpus convention to match). The actual UTF-8-decode/
    /// base64-decode/`SigningKey` construction happens in
    /// `LassoSiteServer.init`'s `smtp` wiring block.
    let keyMaterial: Data
}

/// One `datasources` entry. Decodes either the current shape
/// (`{"type": "mysql"|"filemaker", "schema": "..."}`) or, for back-compat,
/// a bare schema-name string (`"schemaName"`, implicitly `{type: "mysql",
/// schema: "schemaName"}` — the only shape this key ever had before
/// FileMaker support).
struct DatasourceEntry: Decodable {
    enum Backend: String, Decodable {
        case mysql
        case filemaker
    }

    var type: Backend
    /// The real MySQL schema name — meaningful only for `.mysql` entries.
    /// A `.filemaker` entry needs none: the alias itself IS the FileMaker
    /// database-file name (real Lasso's documented FileMaker connector
    /// model). `ServerConfig.load()` falls back to the alias itself when
    /// this is omitted on a `.mysql` entry too.
    var schema: String?
    /// Per-alias FileMaker host/port override — meaningful only for
    /// `.filemaker` entries. Every FileMaker alias shares one `filemaker`
    /// connection block's user/password by default (matching MySQL's
    /// "every alias shares one connection" model); `host`/`port` here let
    /// a specific alias point at a *different* FileMaker Server (e.g. a
    /// dev/backup instance) while still reusing the shared block's
    /// credentials — there's no per-alias user/password override, since
    /// the point is testing against the same account, not a different one.
    /// `nil` (the default) means "use the shared `filemaker` block."
    var host: String?
    var port: Int?

    private enum CodingKeys: String, CodingKey { case type, schema, host, port }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let flatSchema = try? single.decode(String.self) {
            type = .mysql
            schema = flatSchema
            host = nil
            port = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(Backend.self, forKey: .type)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
    }
}

enum ServerConfigError: Error, Equatable, CustomStringConvertible {
    case invalidSiteRoot(String)
    case duplicateDatasourceAlias([String])
    /// A `datasources` entry has `type: "filemaker"` but no `filemaker`
    /// connection block (or `LASSO_FILEMAKER_HOST`) supplies a host —
    /// caught here, at startup, rather than deferred to a confusing
    /// failure the first time a page actually queries that alias.
    case missingFileMakerHost
    /// The CWP session janitor is enabled but no Admin API host/credentials
    /// were supplied — caught here at startup rather than deferred to a
    /// confusing failure on the first poll.
    case missingCWPJanitorAdminAPIConfig
    /// A `smtp.relays` entry has no `host` at all — caught here, at
    /// startup, rather than deferred to a confusing failure the first time
    /// `email_send` actually tries to use that relay.
    case smtpRelayMissingHost(String)
    /// `smtp.defaultRelay` names a relay absent from `smtp.relays`, or was
    /// left unset while `smtp.relays` has more than one entry (ambiguous —
    /// there's no single relay to imply as the default).
    case smtpInvalidDefaultRelay(String)
    /// `smtp.dkim` had exactly one or two (not all three) of `domain`/
    /// `selector`/`keyPath` set (Phase F, §4.9a) — required together,
    /// caught here rather than silently signing with a half-configured
    /// signer or silently not signing at all.
    case smtpIncompleteDKIMConfig
    /// `smtp.dkim.keyType` was set to something other than `"rsa"`/
    /// `"ed25519"` (case-insensitive) — the only two recognized values.
    case smtpInvalidDKIMKeyType(String)
    /// `smtp.dkim.keyPath` names a file that's group- or world-readable
    /// (`posixPermissions & 0o077 != 0`) — an ENFORCED hard startup
    /// failure, not a warning (§4.6: a leaked DKIM private key is not
    /// equivalently rotatable to a leaked password, unlike
    /// `DatasourceFileConfig`'s chmod-600-is-documentation-only
    /// precedent).
    case dkimKeyFilePermissionsTooPermissive(path: String)
    /// `smtp.mtaSTSEnforce: true` was set while `smtp.allowDirectMX` is not
    /// also `true` (§4.9b) — MTA-STS enforcement has no effect and no
    /// meaning unless direct-MX delivery is also enabled (the relay
    /// operator, not this codebase, would be the one resolving a
    /// recipient's MX and needing MTA-STS on a named-relay-only path).
    case mtaSTSEnforceRequiresDirectMX
    /// `smtp.allowDirectMX: true` was set while `smtp.relays` also happens
    /// to use the literal, reserved relay name this feature registers
    /// direct-MX delivery under (`"direct-mx"`) — caught here at
    /// config-load time rather than silently shadowed by whichever entry
    /// wins the dictionary-construction race.
    case smtpReservedRelayName(String)
    /// `LASSO_CRAWL_SITEMAP_ENABLED=1` requires `LASSO_CRAWL_SITEMAP_ORIGIN`
    /// (a valid http(s) origin) — caught here at startup rather than
    /// deferred to sitemap discovery silently no-op'ing on every crawl.
    case missingCrawlSitemapOrigin

    var description: String {
        switch self {
        case .invalidSiteRoot(let path): "Invalid LASSO_SITE_ROOT: \(path)"
        case .duplicateDatasourceAlias(let aliases):
            "Datasource aliases differ only by case, which is ambiguous (Lasso datasource names are case-insensitive): \(aliases.joined(separator: ", "))"
        case .missingFileMakerHost:
            "A FileMaker datasource is configured but no FileMaker host was supplied (set \"filemaker\": {\"host\": ...} in the datasource config file, or LASSO_FILEMAKER_HOST)."
        case .missingCWPJanitorAdminAPIConfig:
            "LASSO_CWP_JANITOR_ENABLED=1 requires Admin API credentials — set \"adminAPI\": {\"host\": ..., \"user\": ..., \"password\": ...} in the datasource config file, or LASSO_FM_ADMIN_HOST/LASSO_FM_ADMIN_USER/LASSO_FM_ADMIN_PASSWORD."
        case .smtpRelayMissingHost(let name):
            "SMTP relay '\(name)' has no host (set \"smtp\": {\"relays\": {\"\(name)\": {\"host\": ...}}} in the datasource config file)."
        case .smtpInvalidDefaultRelay(let name):
            name.isEmpty
                ? "smtp.relays has more than one entry but smtp.defaultRelay was not set — name which relay email_send should use by default."
                : "smtp.defaultRelay ('\(name)') does not name any relay configured in smtp.relays."
        case .smtpIncompleteDKIMConfig:
            "smtp.dkim requires domain, selector, and keyPath together (set all three, or omit dkim entirely to disable DKIM signing)."
        case .smtpInvalidDKIMKeyType(let keyType):
            "smtp.dkim.keyType must be \"rsa\" or \"ed25519\", got '\(keyType)'."
        case .dkimKeyFilePermissionsTooPermissive(let path):
            "smtp.dkim.keyPath ('\(path)') is group- or world-readable — chmod it to 600 (owner read/write only) before starting this server. A leaked DKIM private key can't be rotated as easily as a password."
        case .mtaSTSEnforceRequiresDirectMX:
            "smtp.mtaSTSEnforce requires smtp.allowDirectMX to also be true — MTA-STS enforcement has no effect on the named-relay-only delivery path."
        case .smtpReservedRelayName(let name):
            "smtp.relays must not define a relay named '\(name)' while smtp.allowDirectMX is true — that name is reserved for direct-MX delivery."
        case .missingCrawlSitemapOrigin:
            "LASSO_CRAWL_SITEMAP_ENABLED=1 requires LASSO_CRAWL_SITEMAP_ORIGIN — the real public origin (e.g. https://www.realclientsite.com) the sitemap's <loc> entries describe."
        }
    }
}

extension ServerConfig {
    /// Pure, directly-testable resolution of the `smtp.dkim` sub-block
    /// (Phase F, §4.9a) — separated from `load()`'s env-var/file plumbing
    /// so tests can exercise the incomplete-config/key-type/permission
    /// validation paths directly (including against a real temp key file)
    /// without needing a full `LASSO_DATASOURCE_CONFIG_PATH`-driven
    /// `ServerConfig.load()` round trip — this codebase has no existing
    /// precedent for testing `load()` end to end via live env vars; every
    /// other config-shape test in this file exercises a `Decodable`
    /// conformance or a small, pure resolver function directly instead,
    /// matching that established style.
    ///
    /// Returns `nil` when `dkim` is `nil`, or present but with all three
    /// of `domain`/`selector`/`keyPath` absent/empty (DKIM simply isn't
    /// configured at all — not an error). Throws
    /// `.smtpIncompleteDKIMConfig` when exactly one or two of the three
    /// are set, `.smtpInvalidDKIMKeyType` for an unrecognized `keyType`,
    /// and `.dkimKeyFilePermissionsTooPermissive` when `keyPath`'s file is
    /// group-/world-readable. Any other failure reading `keyPath` (missing
    /// file, permission denied at the OS level, etc.) propagates as
    /// whatever `FileManager`/`Data(contentsOf:)` itself throws — this
    /// mirrors every other "read a config-referenced file, fail fast"
    /// check in this file (e.g. `DatasourceFileConfig.load(path:)`
    /// itself), rather than wrapping every possible I/O failure in a
    /// bespoke case.
    static func resolveSMTPDKIM(_ dkim: SMTPDKIMFileConfig?) throws -> SMTPDKIMSettings? {
        guard let dkim else { return nil }
        let domain = dkim.domain?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selector = dkim.selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPath = dkim.keyPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let presentCount = [domain, selector, keyPath].filter { ($0?.isEmpty ?? true) == false }.count
        guard presentCount > 0 else { return nil }
        guard presentCount == 3, let domain, let selector, let keyPath else {
            throw ServerConfigError.smtpIncompleteDKIMConfig
        }

        let keyType: String
        if let rawKeyType = dkim.keyType?.trimmingCharacters(in: .whitespacesAndNewlines), rawKeyType.isEmpty == false {
            keyType = rawKeyType.lowercased()
        } else {
            keyType = "rsa"
        }
        guard keyType == "rsa" || keyType == "ed25519" else {
            throw ServerConfigError.smtpInvalidDKIMKeyType(keyType)
        }

        // Permission check (§4.6/§4.9a) — an ENFORCED hard startup
        // failure, not a warning, unlike `DatasourceFileConfig`'s
        // chmod-600-is-documentation-only precedent. Checked BEFORE the
        // file's contents are ever read.
        let attributes = try FileManager.default.attributesOfItem(atPath: keyPath)
        let posixPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard posixPermissions & 0o077 == 0 else {
            throw ServerConfigError.dkimKeyFilePermissionsTooPermissive(path: keyPath)
        }

        let keyMaterial = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        return SMTPDKIMSettings(domain: domain, selector: selector, keyType: keyType, keyMaterial: keyMaterial)
    }

    /// Pure, directly-testable validation of the direct-MX/MTA-STS/
    /// reserved-relay-name rules (Phase F, §4.9b) — same "separated from
    /// `load()`'s plumbing" rationale as `resolveSMTPDKIM(_:)` above.
    static func validateDirectMXConfig(allowDirectMX: Bool, mtaSTSEnforce: Bool, relayNames: Set<String>) throws {
        guard mtaSTSEnforce == false || allowDirectMX else {
            throw ServerConfigError.mtaSTSEnforceRequiresDirectMX
        }
        guard allowDirectMX == false || relayNames.contains("direct-mx") == false else {
            throw ServerConfigError.smtpReservedRelayName("direct-mx")
        }
    }
}

/// Thrown by `LassoSiteServer.init`'s `smtp` wiring block when
/// `config.smtpDKIM.keyType == "ed25519"` but the key file's contents
/// aren't valid base64. `ServerConfig.resolveSMTPDKIM(_:)` already
/// validates the file's *permissions* and that `keyType` itself is a
/// recognized value at config-load time — decoding the actual bytes as
/// base64 can only be checked once they're being turned into a
/// `SigningKey`, which needs `PerfectSMTP` (see `SMTPDKIMSettings`'s own
/// doc comment for why that translation is deferred to here rather than
/// done inside `ServerConfig.resolveSMTPDKIM(_:)` itself).
struct SMTPDKIMKeyMaterialError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct LassoSiteServer: Sendable {
    let config: ServerConfig
    let includeLoader: LassoFileSystemIncludeLoader
    let uploadProcessor: LassoFileSystemUploadProcessor
    let inlineProvider: (any LassoInlineProvider)?
    /// One registry for the life of this server process. Every request
    /// gets a `LassoContext` wired with this same instance, so `library()`
    /// caching and `define`d custom tags are shared across every request
    /// and every site path this instance serves — not re-parsed or
    /// re-registered per request.
    let tagRegistry = LassoTagRegistry()
    /// Also one instance for the process lifetime — `SessionDriver`
    /// conformers (`MemorySessionDriver`, MySQL) are themselves the shared
    /// storage, matching how a real Lasso instance's session store outlives
    /// any single request.
    let sessionDriver: any SessionDriver
    /// One instance for the process lifetime, like `tagRegistry` — but
    /// unlike `tagRegistry`, which config can't be given inline (its shape
    /// depends on `config.tagFormCountersEnabled`), so it's set in `init`
    /// below instead of as a stored-property default (Phase 3 of tag-form
    /// consolidation).
    let tagFormCounters: any TagOpenFormCounterStore
    /// `nil` unless the admin console is enabled (`LASSO_ADMIN_CONSOLE=1`)
    /// — no ring buffer to feed when nothing will ever read it.
    let logCapture: LogCapture?
    /// Same nil-when-unused policy as `logCapture`.
    let metrics: AdminMetrics?
    /// Always present (unlike `logCapture`/`metrics`, both nil-when-unused)
    /// — cheap to keep running regardless of whether the admin console is
    /// enabled, and the crawl-report action/CLI mode need it either way.
    /// See `DatasourceFailureTracker`'s own doc comment for why this
    /// exists.
    let datasourceFailureTracker: DatasourceFailureTracker
    /// `nil` when no FileMaker datasource is configured. Owns the *live*,
    /// runtime-mutable host/port each FileMaker alias currently resolves
    /// to — see `FileMakerConnectionRegistry`'s own doc comment. Exposed
    /// here (not just captured locally in the FileMaker queryHandler
    /// closure below) so `LassoAdminDelegate`, constructed separately in
    /// `main.swift`'s top-level code, can share the exact same instance —
    /// real query traffic and the admin console's "switch datasource"
    /// action must always agree on which host an alias currently means.
    let fileMakerRegistry: FileMakerConnectionRegistry?
    /// The `email_send` dispatch seam's conformer
    /// (`Documentation/lasso-perfect-smtp-integration-plan.md` §4.0 point 2)
    /// — `nil` when `config.smtpRelays` is empty (no `smtp` block/
    /// `LASSO_SMTP_*` env vars configured at all), matching every other
    /// optional backend's degrade-gracefully-when-unconfigured convention.
    /// Wired into each request's `LassoContext.emailProvider` exactly like
    /// `inlineProvider` is today.
    let emailProvider: (any LassoEmailProvider)?
    /// `email_smtp`'s idle-connection reaper (Phase D, §4.8b) — `nil`
    /// exactly when `emailProvider` is `nil` (no `smtp` block configured at
    /// all, so `email_smtp` has no live connections to ever leak). Follows
    /// the CWP session janitor's own established convention just below in
    /// this file (a cancellable `Task<Void, Never>` owned by whoever wires
    /// the resource, not by the resource type itself — see
    /// `LassoSMTPConnectionRegistry`'s own doc comment for why): the actor
    /// just exposes `sweepIdleConnections(idleTimeout:)`, and this Task is
    /// the periodic caller. `LassoSiteServer` is a `struct` (no `deinit`
    /// available, matching the CWP janitor's own identical lifecycle) and is
    /// constructed exactly once for the life of the process
    /// (`main.swift`'s top-level `let siteServer = try LassoSiteServer(...)`).
    /// Milestone review correction (BLOCKING #3): an earlier revision of
    /// this comment claimed `cwpJanitorTask` "below has no formal shutdown
    /// hook either" — false even then (`AdminConsoleIntegration.swift:325`
    /// already cancels it on a "Restart Server" admin action), and this
    /// comment's own claim that this Task's lifetime is "reaped only by
    /// process exit" was the actual gap: `main.swift` passes this Task to
    /// `LassoAdminDelegate` exactly like `cwpJanitorTask`, and the restart
    /// action now cancels it alongside `cwpJanitorTask`/`siteServerTask` —
    /// it IS genuinely cancelled on restart, not merely exposed for some
    /// hypothetical future path.
    let smtpConnectionReaperTask: Task<Void, Never>?
    /// `LassoEmailJobTracker`'s periodic eviction-sweep Task (Phase E,
    /// §4.7/§4.7b) — `nil` under the exact same condition
    /// `smtpConnectionReaperTask` is (no `smtp` block configured at all, so
    /// there's no job tracker any request could ever populate). Follows
    /// `smtpConnectionReaperTask`'s own established convention identically:
    /// a cancellable `Task<Void, Never>` owned by whoever wires the
    /// resource, wired into `LassoAdminDelegate`'s restart action alongside
    /// `cwpJanitorTask`/`smtpConnectionReaperTask` so it's genuinely
    /// cancelled on "Restart Server," not merely exposed for some
    /// hypothetical future path (see that property's own doc comment for
    /// the identical reasoning, and `LassoEmailJobTracker.swift`'s doc
    /// comment for why THIS is the one Task Phase E tracks this way, while
    /// individual per-send deferred-send Tasks deliberately are not).
    let emailJobSweepTask: Task<Void, Never>?

    init(
        config: ServerConfig,
        logCapture: LogCapture? = nil,
        metrics: AdminMetrics? = nil,
        datasourceFailureTracker: DatasourceFailureTracker = DatasourceFailureTracker()
    ) throws {
        self.config = config
        tagFormCounters = config.tagFormCountersEnabled
            ? CountingTagOpenFormCounterStore()
            : NoOpTagOpenFormCounterStore()
        self.logCapture = logCapture
        self.metrics = metrics
        self.datasourceFailureTracker = datasourceFailureTracker
        includeLoader = try LassoFileSystemIncludeLoader(root: config.siteRoot)
        uploadProcessor = try LassoFileSystemUploadProcessor(root: config.siteRoot)

        switch config.sessionDriver {
        case "mysql":
            // MySQLSessionDriver reads connection info from these process-
            // global statics (matching PerfectSessionCore's own SessionConfig
            // pattern) rather than taking them in its initializer.
            MySQLSessionConnector.host = config.mysqlHost
            if let port = config.mysqlPort { MySQLSessionConnector.port = port }
            MySQLSessionConnector.database = config.mysqlDatabase
            MySQLSessionConnector.username = config.mysqlUser ?? ""
            MySQLSessionConnector.password = config.mysqlPassword ?? ""
            MySQLSessionConnector.table = config.mysqlSessionTable
            sessionDriver = MySQLSessionDriver()
        default:
            sessionDriver = MemorySessionDriver()
        }

        let mysqlProvider: LassoDynamicInlineProvider?
        do {
            // The set of real MySQL schema names this deployment is
            // configured for — LassoDynamicInlineProvider remaps a
            // recognized Lasso-side alias to one of these before this
            // executor ever sees it; an unrecognized alias passes through
            // unmapped and is rejected here rather than allowing queries
            // against arbitrary named schemas that happen to already
            // exist on the server. This gate is bypassed entirely when a
            // request carries its own `-Host` override — real Lasso's own
            // documented behavior ("If an inline host is specified with a
            // -Host array then step 2 [the Lasso security check] is
            // skipped") — an ad-hoc connection is never something a
            // deployment pre-approves by datasource name, it's approved by
            // the site's own code supplying real credentials at the call
            // site. This provider is now always constructed (previously
            // only when `config.datasourceMap` was non-empty) so ad-hoc
            // `-Host` MySQL connections work even on a deployment with zero
            // pre-configured MySQL datasources — real corpus: TS_lasso9
            // has no server-side datasource config at all, every inline
            // supplies `-Host=$host_array` itself.
            let knownDatabases = Set(config.datasourceMap.values)
            @Sendable func makeDatabase(_ database: String, hostOverride: LassoInlineHostOverride?) throws -> Database<MySQLDatabaseConfiguration> {
                guard let hostOverride else {
                    return try Database(configuration: MySQLDatabaseConfiguration(
                        database: database,
                        host: config.mysqlHost,
                        port: config.mysqlPort,
                        username: config.mysqlUser,
                        password: config.mysqlPassword
                    ))
                }
                // An ad-hoc -Host connection reaches whatever address the
                // site's own code supplies at the call site, never vetted
                // at deployment time the way a pre-configured datasource
                // is -- bound how long one unreachable/misconfigured
                // ad-hoc host can stall a request, rather than the
                // library's unbounded OS-default connect timeout.
                let connection = MySQL()
                _ = connection.setOption(.MYSQL_OPT_CONNECT_TIMEOUT, 5)
                guard connection.connect(
                    host: hostOverride.name,
                    user: hostOverride.username,
                    password: hostOverride.password,
                    db: database,
                    port: UInt32(hostOverride.port ?? 0),
                    socket: nil,
                    flag: 0
                ) else {
                    throw MySQLCRUDError("Could not connect. \(connection.errorMessage())")
                }
                return Database(configuration: MySQLDatabaseConfiguration(connection: connection))
            }
            let executor = PerfectCRUDLassoExecutor(
                capabilities: { datasource, hostOverride in
                    guard hostOverride != nil || knownDatabases.contains(datasource) else { return .readOnly }
                    return LassoDatasourceCapabilities(
                        allowsInsert: config.mysqlAllowWrites,
                        allowsUpdate: config.mysqlAllowWrites,
                        allowsDelete: config.mysqlAllowWrites,
                        allowsRawSQL: config.mysqlAllowRawSQL
                    )
                },
                queryHandler: { datasource, query, hostOverride in
                    guard hostOverride != nil || knownDatabases.contains(datasource) else {
                        throw LassoSiteServerError.unknownDatasource(datasource)
                    }
                    do {
                        return try makeDatabase(datasource, hostOverride: hostOverride).select(query)
                    } catch let error as LassoDatabaseActionError {
                        throw error
                    } catch {
                        logDatasourceActionFailure(kind: "search", datasource: datasource, error: error, logCapture: logCapture, datasourceFailureTracker: datasourceFailureTracker)
                        throw LassoDatabaseActionError(kind: .search, datasource: datasource, underlying: error)
                    }
                },
                mutationHandler: { datasource, mutation, hostOverride in
                    guard hostOverride != nil || knownDatabases.contains(datasource) else {
                        throw LassoSiteServerError.unknownDatasource(datasource)
                    }
                    do {
                        return try makeDatabase(datasource, hostOverride: hostOverride).mutate(mutation)
                    } catch let error as LassoDatabaseActionError {
                        throw error
                    } catch {
                        let kind: LassoDatabaseActionFailureKind = switch mutation.action {
                        case .insert: .add
                        case .update: .update
                        case .delete: .delete
                        }
                        logDatasourceActionFailure(kind: kind.rawValue, datasource: datasource, error: error, logCapture: logCapture, datasourceFailureTracker: datasourceFailureTracker)
                        throw LassoDatabaseActionError(kind: kind, datasource: datasource, underlying: error)
                    }
                },
                rawSQLHandler: { datasource, sql, hostOverride in
                    guard hostOverride != nil || knownDatabases.contains(datasource) else {
                        throw LassoSiteServerError.unknownDatasource(datasource)
                    }
                    do {
                        return try makeDatabase(datasource, hostOverride: hostOverride).execute(sql)
                    } catch let error as LassoDatabaseActionError {
                        throw error
                    } catch {
                        logDatasourceActionFailure(kind: "sql", datasource: datasource, error: error, logCapture: logCapture, datasourceFailureTracker: datasourceFailureTracker)
                        throw LassoDatabaseActionError(kind: .sql, datasource: datasource, underlying: error)
                    }
                }
            )
            mysqlProvider = LassoDynamicInlineProvider(
                executor: executor,
                datasourceAliases: config.datasourceMap
            )
        }

        let fileMakerProvider: LassoDynamicInlineProvider?
        do {
            // ServerConfig.load() already validates filemakerHost is set
            // whenever any FileMaker alias is configured
            // (ServerConfigError.missingFileMakerHost) — "localhost" here
            // is just a defensive fallback for a ServerConfig built by
            // hand (e.g. in tests) rather than through .load(), and for a
            // deployment relying entirely on ad-hoc `-Host` FileMaker
            // connections with no aliases configured at all.
            let filemakerHost = config.filemakerHost ?? "localhost"
            let filemakerPort = config.filemakerPort ?? 80
            let filemakerUser = config.filemakerUser ?? ""
            let filemakerPassword = config.filemakerPassword ?? ""
            let filemakerUseTLS = filemakerPort == 443
            let filemakerScheme = filemakerUseTLS ? "https" : "http"
            // Always constructed (previously only when
            // `config.filemakerDatasourceAliases` was non-empty) — an
            // empty `FileMakerConnectionRegistry` just means every
            // `resolve(alias:)` call falls through to the shared
            // connection below, exactly as it already did for any
            // unrecognized alias.
            let registry = FileMakerConnectionRegistry(config: config)
            fileMakerRegistry = registry
            // Container-field URLs (FMPFieldValue.container) are prefixed
            // with this single baseURL regardless of which alias's records
            // they came from — known, accepted gap for an alias whose live
            // resolution (below) currently points somewhere other than the
            // shared block: its container-field links would point at the
            // wrong host. Not a concern for the connectivity-testing/dev-
            // server use case this exists for; would need a per-alias
            // baseURL (not just per-alias FileMakerServer) to fix properly.
            let executor = PerfectFileMakerLassoExecutor(
                allowWrites: config.filemakerAllowWrites,
                baseURL: "\(filemakerScheme)://\(filemakerHost):\(filemakerPort)"
            ) { query, kind, datasource, hostOverride in
                // An ad-hoc `-Host` override supplies its own full
                // connection (real Lasso's own documented behavior — see
                // `LassoInlineHostOverride`'s doc comment); everything else
                // still goes through the registry's live alias resolution,
                // which is what makes the admin console's "switch
                // datasource" action take effect on the very next query.
                let host: String
                let port: Int
                let user: String
                let password: String
                if let hostOverride {
                    host = hostOverride.name
                    port = hostOverride.port ?? 80
                    user = hostOverride.username ?? ""
                    password = hostOverride.password ?? ""
                } else {
                    (host, port) = await registry.resolve(alias: datasource) ?? (filemakerHost, filemakerPort)
                    user = filemakerUser
                    password = filemakerPassword
                }
                let useTLS = port == 443
                // A fresh FileMakerServer per call (matching makeDatabase's
                // own per-call construction above), even though the
                // resurrected FileMakerServer is now natively Sendable and
                // could safely be built once and captured — keeps this
                // closure's shape consistent with makeDatabase's and with
                // how it looked before the resurrection, when
                // FileMakerServer wasn't Sendable at all.
                let server = FileMakerServer(
                    host: host, port: port,
                    userName: user, password: password,
                    useTLS: useTLS
                )
                // FileMakerServer.query(_:) is genuine async/await (the
                // resurrected library replaced its blocking PerfectCURL/
                // libcurl transport with URLSession); the render pipeline
                // is now natively async throughout, so this queryHandler
                // can await it directly with no bridge.
                do {
                    return try await server.query(query)
                } catch let error as LassoFileMakerDatabaseActionError {
                    throw error
                } catch {
                    logDatasourceActionFailure(kind: "\(kind)", datasource: datasource, error: error, logCapture: logCapture, datasourceFailureTracker: datasourceFailureTracker)
                    throw LassoFileMakerDatabaseActionError(kind: kind, datasource: datasource, underlying: error)
                }
            }
            // No alias remapping needed — the alias itself IS the
            // FileMaker database-file name.
            fileMakerProvider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: [:])
        }

        if mysqlProvider == nil, fileMakerProvider == nil {
            inlineProvider = nil
        } else {
            inlineProvider = LassoMultiBackendInlineProvider(
                mysqlProvider: mysqlProvider,
                fileMakerProvider: fileMakerProvider,
                fileMakerAliases: config.filemakerDatasourceAliases
            )
        }

        // `smtp` wiring (§4.0 point 2/§4.6) — `config.smtpRelays` empty
        // means no `smtp` block/`LASSO_SMTP_*` env vars were configured at
        // all; `emailProvider` stays `nil` and `email_send` throws
        // `LassoRuntimeError.emailNotConfigured`, matching every other
        // optional backend here. `MultiThreadedEventLoopGroup.singleton`
        // (not a group this type owns/shuts down) — every other NIO-backed
        // piece of this server (`PerfectNIO`/`PerfectAdminConsole`) already
        // runs on the process-wide singleton group; reusing it here avoids
        // spinning up a second, separately-lifecycled thread pool just for
        // SMTP.
        //
        // `email_mxlookup`/`email_compose` (Phase C) share this exact same
        // on/off gate, even though neither strictly needs a configured
        // relay -- `email_mxlookup` is a pure DNS lookup with no
        // relay/credential dependency at all, and `email_compose` never
        // dials a relay either (§4.3b: composes but does not send). A
        // deliberate, flagged judgment call: splitting `emailProvider` into
        // "parts that need relay config" vs. "parts that don't" would add
        // real complexity (two optional context slots, or a provider type
        // that's itself partially-configured) for a scenario a real
        // deployment is unlikely to hit in practice -- an operator who
        // wants `email_compose`/`email_mxlookup` almost certainly also
        // wants `email_send`, since all three are part of the same `smtp`
        // config block conceptually. Keeping one on/off switch is the
        // pragmatic, defensible choice; a future phase can split it if a
        // real "MX lookups only, no relay configured" deployment ever
        // surfaces.
        if config.smtpRelays.isEmpty == false, let defaultRelay = config.smtpDefaultRelay {
            let descriptors = config.smtpRelays.mapValues { settings in
                LassoSMTPRelayDescriptor(
                    host: settings.host,
                    port: settings.port,
                    user: settings.user,
                    password: settings.password,
                    tls: Self.tlsMode(settings.tls, port: settings.port)
                )
            }
            // Built here, ahead of `registry`/`directMXMailer` below, so
            // both can reuse the exact same instance -- `email_mxlookup`
            // (Phase C), direct-MX delivery (Phase F, §4.9b), and MTA-STS
            // policy lookups (also §4.9b) all share one `DNSResolver`
            // rather than each spinning up its own.
            let mxResolver = DNSResolver(group: MultiThreadedEventLoopGroup.singleton)

            // DKIM signer (Phase F, §4.9a) -- one signer per process,
            // shared across every relay's `SMTPMailer` this block builds
            // below, named relays AND the direct-mx entry alike (§4.9a's
            // "one signer, not per-relay" design). `nil` when
            // `config.smtpDKIM` wasn't configured at all -- every
            // `SMTPMailer` below then sends unsigned, exactly like every
            // phase before this one.
            let dkimSigner: (any MessageSigner)? = try config.smtpDKIM.map { try Self.makeDKIMSigner($0) }

            // Direct-MX opt-in (Phase F, §4.9b) -- reuses `mxResolver`
            // above (never a second, redundant `DNSResolver`).
            // `DirectMXConfig()`'s library defaults are used verbatim --
            // `allowPrivateAddresses` is deliberately NEVER exposed as
            // operator config here, staying hardcoded at its safe default
            // (`false`): this is the exact SSRF-relevant knob §5's whole
            // `-host` redesign exists to keep away from any
            // caller-reachable surface, and no real deployment need for
            // internal-address direct-MX delivery has been identified.
            let directMXMailer: SMTPMailer?
            if config.smtpAllowDirectMX {
                let mtaSTSPolicyProvider: (any MTASTSPolicyProviding)? = config.smtpMTASTSEnforce
                    ? MTASTSPolicyManager(dnsResolver: mxResolver, addressResolver: mxResolver)
                    : nil
                let directMXTransport = DirectMXTransport(
                    resolver: mxResolver,
                    group: MultiThreadedEventLoopGroup.singleton,
                    mtaSTSPolicyProvider: mtaSTSPolicyProvider
                )
                directMXMailer = SMTPMailer(transport: directMXTransport, signer: dkimSigner)
            } else {
                directMXMailer = nil
            }

            let registry = try LassoSMTPMailerRegistry(
                relays: descriptors,
                defaultRelay: defaultRelay,
                group: MultiThreadedEventLoopGroup.singleton,
                signer: dkimSigner,
                directMX: directMXMailer
            )
            // `email_smtp`'s live-connection registry (Phase D, §4.8b) —
            // built once here so the reaper Task below and every request's
            // `LassoEmailProviderImpl` (via `emailProvider`) share the
            // exact same instance; two separately-constructed registries
            // would mean the reaper sweeps a registry no request ever
            // populates.
            let connectionRegistry = LassoSMTPConnectionRegistry()
            // `email_result`/`email_status`'s job tracking layer (Phase E,
            // §4.7/§4.7b) — built once here for the exact same reason
            // `connectionRegistry` is: shared across every request's
            // `LassoEmailProviderImpl` AND the periodic eviction-sweep Task
            // below, so a job one request records is actually readable by a
            // later request's `email_result`/`email_status` call.
            let jobTracker = LassoEmailJobTracker()
            emailProvider = LassoEmailProviderImpl(
                registry: registry,
                siteRoot: config.siteRoot,
                mxResolver: mxResolver,
                mxLookupCache: LassoMXLookupCache(),
                connectionRegistry: connectionRegistry,
                group: MultiThreadedEventLoopGroup.singleton,
                allowEmailSMTP: config.smtpAllowEmailSMTP,
                jobTracker: jobTracker
            )
            // Idle-timeout reaper: a page that errors out mid `->open`/
            // `->command`/`->send` sequence, or simply forgets `->close`,
            // would otherwise leak a live SMTP connection (and a registry
            // entry) for the rest of the process's life. Matches the CWP
            // session janitor's own established
            // `while !Task.isCancelled { ...; try? await Task.sleep(...) }`
            // shape just below in this file — 60s poll interval, 300s
            // (5-minute) idle threshold, matching `SMTPConnection`'s own
            // default `replyTimeout` (§4.8b's suggested, documented
            // starting point — always-on, not behind a separate opt-in
            // flag, since this is a leak-prevention safety net, not an
            // optional feature).
            smtpConnectionReaperTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    _ = await connectionRegistry.sweepIdleConnections(idleTimeout: 300)
                }
            }
            // `LassoEmailJobTracker`'s own periodic eviction sweep (Phase E,
            // §4.7b's answer to open question #1/#2) — matches
            // `smtpConnectionReaperTask`'s identical shape immediately
            // above (60s poll interval; the tracker's own TTL/hard-cap
            // defaults, 24h/10,000 entries, applied every sweep). This is
            // the ONE background Task Phase E tracks for restart
            // cancellation (`LassoEmailJobTracker.swift`'s own doc comment
            // explains why per-send deferred-send Tasks deliberately are
            // NOT also tracked this way).
            emailJobSweepTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    _ = await jobTracker.sweepExpiredJobs()
                }
            }
        } else {
            emailProvider = nil
            smtpConnectionReaperTask = nil
            emailJobSweepTask = nil
        }
    }

    /// `SMTPRelaySettings.tls`'s raw string -> `PerfectSMTP.TLSMode` —
    /// `ServerConfig.load()` already resolves the default ("implicit" at
    /// port 465, "startTLS" otherwise) and only ever writes one of the
    /// three recognized strings, so an unrecognized value here (a hand-
    /// edited config file with a typo) falls back to `.startTLS` — the
    /// safer of the two "assume some TLS" choices when the string can't be
    /// interpreted, rather than silently downgrading to `.none`.
    private static func tlsMode(_ raw: String, port: Int) -> TLSMode {
        switch raw.lowercased() {
        case "none": .none
        case "implicit": .implicit
        case "starttls": .startTLS
        default: .startTLS
        }
    }

    /// `SMTPDKIMSettings` -> a real `DKIMSigner` (Phase F, §4.9a) —
    /// separated from the `smtp` wiring block above purely so tests can
    /// exercise both the `"rsa"` and `"ed25519"` key-loading paths (and
    /// the ed25519-invalid-base64 failure path) directly, without needing
    /// a full `LassoSiteServer` construction. `settings.keyType` is
    /// already validated to be `"rsa"` or `"ed25519"` by `ServerConfig
    /// .resolveSMTPDKIM(_:)` — no other value ever reaches this function.
    static func makeDKIMSigner(_ settings: SMTPDKIMSettings) throws -> any MessageSigner {
        let key: SigningKey
        switch settings.keyType {
        case "ed25519":
            // This implementation's own documented file format for an
            // ed25519 DKIM key — base64-encoded raw 32-byte seed — since
            // neither real Lasso doc source mentions DKIM at all (§4.9a),
            // there's no corpus convention this needs to match.
            let base64Text = String(decoding: settings.keyMaterial, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawKey = Data(base64Encoded: base64Text) else {
                throw SMTPDKIMKeyMaterialError(
                    message: "smtp.dkim.keyPath's contents are not valid base64 (required for keyType=\"ed25519\")."
                )
            }
            key = try SigningKey.ed25519(rawRepresentation: rawKey)
        default:
            // "rsa" -- the only other value `ServerConfig
            // .resolveSMTPDKIM(_:)` ever lets through.
            let pem = String(decoding: settings.keyMaterial, as: UTF8.self)
            key = try SigningKey.rsa(pem: pem)
        }
        // `signedHeaders: []` -- `DKIMSigner.alwaysOversignedHeaders`
        // already covers every header a message built WITHOUT
        // `-extraMIMEHeaders` ever has (§4.9a). `canon` left at
        // `DKIMSigner`'s own default (`(.relaxed, .relaxed)`, §4.6).
        //
        // Milestone review finding (protocol pass), now resolved: a
        // caller-supplied `-extraMIMEHeaders` name is NOT in
        // `alwaysOversignedHeaders` and is a per-MESSAGE concern (different
        // `email_send` calls may add different custom header names) --
        // this one signer, built once here at server startup, has no way
        // to know any particular message's extra header names in advance.
        // Fixed on the Perfect-SMTP side instead of here:
        // `SMTPMailer.composeAndSign` (`Sources/PerfectSMTP/SMTPMailer.swift`)
        // now widens whichever signer is configured -- when it's a
        // `DKIMSigner` -- with that specific message's own
        // `EmailMessage.extraHeaders` names (`DKIMSigner
        // .signingAdditionalHeaders(_:)`) immediately before calling
        // `sign(_:)`, every single send. That happens transparently for
        // every mailer this registry builds (every relay, and the
        // reserved `"direct-mx"` entry, §4.9b), so this one signer,
        // constructed once with `signedHeaders: []`, is still the correct
        // and sufficient construction here -- no per-relay or per-call
        // signer construction is needed on this side after all.
        return try DKIMSigner(domain: settings.domain, selector: settings.selector, signedHeaders: [], keys: [key])
    }

    func routes() throws -> Routes<HTTPRequest, HTTPOutput> {
        let health = root().GET.path("__lasso_health").map { _ -> HTTPOutput in
            TextOutput("ok")
        }
        // Phase 3 of tag-form consolidation: a plaintext dump of which real
        // tag-open-forms have actually fired during this process's
        // lifetime, sorted by descending count. Empty (and says so) when
        // LASSO_TAG_FORM_COUNTERS isn't enabled — mirrors __lasso_health's
        // pattern, an unauthenticated admin route intended only for local
        // real-corpus verification sweeps, never a public deployment.
        let tagFormCountersRoute = root().GET.path("__lasso_tag_form_counters").map { _ -> HTTPOutput in
            TextOutput(self.renderTagFormCountersReport())
        }
        let rootFile = root().GET.map { request -> HTTPOutput in
            try await handle(request: request, trailingPath: "")
        }
        let files = root().GET.trailing { request, path -> HTTPOutput in
            try await handle(request: request, trailingPath: path)
        }
        // POST routes mirror the GET ones — real Lasso pages are typically
        // requested at the same URL for both the form's initial GET and its
        // POST submission. See Documentation/post-body-support-plan.md;
        // `handle` already reads/parses the body for either verb via
        // readPostBody, so no separate handler logic is needed here.
        let rootFilePost = root().POST.map { request -> HTTPOutput in
            try await handle(request: request, trailingPath: "")
        }
        let filesPost = root().POST.trailing { request, path -> HTTPOutput in
            try await handle(request: request, trailingPath: path)
        }
        return try root().dir(health, tagFormCountersRoute, rootFile, files, rootFilePost, filesPost)
    }

    /// `tag\tform\tcount`, one line per fire, descending by count — plain
    /// and greppable rather than JSON, matching this admin surface's
    /// throwaway, developer-facing purpose.
    private func renderTagFormCountersReport() -> String {
        let snapshot = tagFormCounters.snapshot()
        guard !snapshot.isEmpty else {
            return "(no tag-open-form fires recorded; set LASSO_TAG_FORM_COUNTERS=1 to enable)\n"
        }
        var lines = ["tag\tform\tcount"]
        for (fire, count) in snapshot.sorted(by: { $0.value > $1.value }) {
            lines.append("\(fire.tagName)\t\(fire.form.displayName)\t\(count)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func handle(request: any HTTPRequest, trailingPath: String) async throws -> HTTPOutput {
        // Route key matches AdminMetrics' own documented convention
        // ("METHOD:///path", e.g. "GET:///api/posts") so /api/metrics
        // shows something directly comparable to that example.
        await metrics?.recordRequest(route: "\(request.method.rawValue):///\(trailingPath)")
        var resolvedPath = trailingPath
        var resolvedFileURL: URL?
        do {
            let path = try resolveRequestPath(trailingPath)
            resolvedPath = path
            if let redirect = imageProxyRedirect(for: path) {
                return redirect
            }
            if Self.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
               localFileExists(path) == false {
                return Self.missingImagePlaceholderOutput()
            }
            let fileURL = try fileURL(for: path)
            resolvedFileURL = fileURL
            // path is empty (or directory-shaped) exactly when directory-
            // index resolution picked the actual file -- recover its real
            // relative path so shouldRender's exclude-match and render's
            // includePath reflect what was actually served, not the empty
            // string that located it.
            let effectivePath = (path.isEmpty || path.hasSuffix("/")) ? relativePath(of: fileURL) : path
            resolvedPath = effectivePath
            if shouldRender(fileURL, path: effectivePath) {
                let postBody = try await readPostBody(request: request)
                return try await render(fileURL: fileURL, request: request, includePath: effectivePath, postBody: postBody)
            }
            return try FileOutput(localPath: fileURL.path)
        } catch let error as ErrorOutput {
            await metrics?.recordError()
            throw error
        } catch {
            await metrics?.recordError()
            return developerErrorOutput(
                error,
                request: request,
                routePath: trailingPath,
                resolvedPath: resolvedPath,
                fileURL: resolvedFileURL
            )
        }
    }

    /// `LASSO_IMAGE_PROXY_PREFIX`/`LASSO_IMAGE_PROXY_TARGET` — see
    /// `ServerConfig`'s doc comment. Checked before any local filesystem
    /// resolution, so a configured prefix (e.g. "product_images") never
    /// falls through to the missing-image placeholder below; it always
    /// redirects to the real source instead.
    private func imageProxyRedirect(for path: String) -> HTTPOutput? {
        guard let prefix = config.imageProxyPrefix, let target = config.imageProxyTarget,
              prefix.isEmpty == false, target.isEmpty == false else { return nil }
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        let remainder = path.dropFirst(prefix.count)
        return RedirectOutput(to: target + remainder, status: .found)
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "ico", "svg"]

    /// A same-size-agnostic placeholder so a real product/template image
    /// missing from a local site-root copy shows a visible, deliberate
    /// "image not available" box instead of a broken-image icon (whose
    /// intrinsic size is usually 0x0 or browser-chrome-dependent) —
    /// keeping the surrounding page layout intact rather than mangled.
    /// SVG scales to whatever width/height the `<img>` tag or its CSS
    /// specifies, unlike a fixed-dimension raster placeholder.
    private static func missingImagePlaceholderOutput() -> HTTPOutput {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300" preserveAspectRatio="xMidYMid meet">
        <rect width="400" height="300" fill="#eeeeee"/>
        <rect x="0.5" y="0.5" width="399" height="299" fill="none" stroke="#cccccc"/>
        <g stroke="#bbbbbb" stroke-width="2">
        <line x1="40" y1="40" x2="360" y2="260"/>
        <line x1="360" y1="40" x2="40" y2="260"/>
        </g>
        <text x="200" y="280" font-family="sans-serif" font-size="14" fill="#999999" text-anchor="middle">Image not available</text>
        </svg>
        """
        return BytesOutput(
            head: HTTPHead(status: .ok, headers: HTTPHeaders([
                ("Content-Type", "image/svg+xml"),
                ("Cache-Control", "no-store"),
            ])),
            body: Array(svg.utf8)
        )
    }

    /// Reads and parses the request body asynchronously, before the
    /// synchronous LassoRenderer/Evaluator ever runs — see
    /// Documentation/post-body-support-plan.md. Phase 1 handles
    /// application/x-www-form-urlencoded via Perfect-NIO's own QueryDecoder
    /// and captures any other content type as a raw string; multipart/file
    /// uploads are deferred to session-upload-support-plan.md's upload
    /// milestone (Perfect-NIO's MimeReader needs careful temp-file-lifetime
    /// handling that doesn't belong bolted onto this pass).
    private func readPostBody(request: any HTTPRequest) async throws -> ParsedPostBody {
        guard request.contentLength > 0 else { return .empty }
        switch try await request.readContent() {
        case .urlForm(let decoder):
            let pairs = decoder.map { LassoRequestPair(name: $0.0, value: .string($0.1)) }
            let rawString = pairs.map { "\($0.name)=\($0.value.outputString)" }.joined(separator: "&")
            return ParsedPostBody(pairs: pairs, rawString: rawString)
        case .other(let bytes):
            return ParsedPostBody(pairs: [], rawString: String(decoding: bytes, as: UTF8.self))
        case .multiPartForm(let reader):
            var pairs: [LassoRequestPair] = []
            var uploads: [LassoUploadedFile] = []
            for spec in reader.bodySpecs {
                if spec.file != nil {
                    uploads.append(LassoUploadedFile(
                        fieldName: spec.fieldName,
                        contentType: spec.contentType,
                        originalFilename: spec.fileName,
                        temporaryFilename: spec.tmpFileName,
                        size: spec.fileSize
                    ))
                } else if spec.fileName.isEmpty, spec.contentType == "application/octet-stream" {
                    // Matches Perfect-NIO's own RequestDecoder.decode(_:content:)
                    // filter — an empty placeholder BodySpec MimeReader emits
                    // for a file field the client submitted with no file
                    // selected, not a real form value.
                    continue
                } else {
                    pairs.append(LassoRequestPair(name: spec.fieldName, value: .string(spec.fieldValue)))
                }
            }
            // Retaining `reader` here (not just letting it fall out of
            // scope) matters: MimeReader deletes its temp upload files on
            // deinit, and Lasso code needs to be able to read an upload's
            // tmpFileName for as long as this request's render lasts.
            return ParsedPostBody(pairs: pairs, rawString: "", uploads: uploads, retainedMimeReader: RetainedMimeReader(reader))
        case .none:
            return .empty
        }
    }

    func resolveRequestPath(_ trailingPath: String) throws -> String {
        // Deliberately does NOT hardcode "index.lasso" for an empty/root
        // path -- that used to short-circuit fileURL(for:)'s own directory-
        // index fallback (directoryIndexURL(for:), which already tries
        // index.html/index.htm/etc.) by handing it a literal "index.lasso"
        // relative path that doesn't exist, throwing notFound before the
        // fallback list was ever consulted. Real corpus: a site with only
        // index.html (no .lasso files at all) got "File not found:
        // index.lasso" for every request to "/", even though the exact
        // same fallback search already succeeds for any OTHER directory
        // request (e.g. "/sub/") because those correctly pass an empty
        // relativePath into fileURL(for:) today. Returning the normalized
        // (possibly empty) path here, unconditionally, makes the root case
        // go through the identical, already-correct directory-index path.
        let decoded = trailingPath.removingPercentEncoding ?? trailingPath
        return decoded.split(separator: "/").reduce(into: [String]()) { parts, component in
            switch component {
            case "", ".": break
            case "..": _ = parts.popLast()
            default: parts.append(String(component))
            }
        }.joined(separator: "/")
    }

    /// The site-root-relative path of an already-resolved file URL, in the
    /// same slash-joined, no-leading-slash shape `resolveRequestPath`
    /// produces (matches `CrawlReport.discoverPaths`' `relativePath` shape,
    /// per `shouldRender`'s own doc comment below). Used to recover a real,
    /// reportable path after directory-index resolution has picked an
    /// actual file for an originally empty/directory request -- so
    /// `render`'s `includePath` and error reporting still show the file
    /// that was actually served, not the empty string that located it.
    func relativePath(of url: URL) -> String {
        let rootPath = config.siteRoot.path.hasSuffix("/") ? config.siteRoot.path : config.siteRoot.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.path }
        return String(url.path.dropFirst(rootPath.count))
    }

    /// A non-throwing existence check mirroring `fileURL(for:)`'s own
    /// candidate resolution, used ahead of it so the missing-image
    /// placeholder path never has to catch-and-inspect a thrown
    /// `ErrorOutput` (which doesn't expose its status code publicly).
    private func localFileExists(_ relativePath: String) -> Bool {
        let candidate = config.siteRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isWithinRoot(candidate) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue == false
    }

    func fileURL(for relativePath: String) throws -> URL {
        let candidate = config.siteRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isWithinRoot(candidate) else {
            throw ErrorOutput(status: .forbidden, description: "Path is outside the site root.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return try directoryIndexURL(for: candidate)
            }
            return candidate
        }
        if relativePath.isEmpty || relativePath.hasSuffix("/") {
            return try directoryIndexURL(for: candidate)
        }
        throw ErrorOutput(status: .notFound, description: "File not found: \(relativePath)")
    }

    func directoryIndexURL(for directory: URL) throws -> URL {
        for name in ["index.lasso", "index.html", "index.htm", "default.lasso", "default.html", "default.htm"] {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ErrorOutput(status: .notFound, description: "No index file found.")
    }

    private func isWithinRoot(_ candidate: URL) -> Bool {
        let rootPath = config.siteRoot.path.hasSuffix("/") ? config.siteRoot.path : config.siteRoot.path + "/"
        return candidate.path == config.siteRoot.path || candidate.path.hasPrefix(rootPath)
    }

    /// `path` is the site-root-relative request path (matches
    /// `CrawlReport.discoverPaths`' `relativePath` shape) — checked against
    /// `config.renderExcludePaths` with the same case-insensitive substring
    /// semantics the crawler uses for its own exclude list.
    private func shouldRender(_ url: URL, path: String) -> Bool {
        guard config.lassoExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return CrawlReport.pathMatchesExclude(path, excludePaths: config.renderExcludePaths) == false
    }

    private func render(
        fileURL: URL,
        request: any HTTPRequest,
        includePath: String,
        postBody: ParsedPostBody
    ) async throws -> HTTPOutput {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let document = LassoParser().parse(source)
        // Kept as a local so its collected status/redirect/headers/cookies
        // can be read back after rendering — context.responseSink alone
        // wouldn't let us do that once context goes out of scope, and
        // previously nothing did, which is why redirect_url/response_status/
        // cookie_set never actually affected the HTTP response despite
        // correctly mutating this same (reference-type) sink instance.
        let sink = ServerResponseSink()

        // Session bridge: cheap to construct unconditionally (no I/O until
        // a session_start(...) is actually evaluated) — see
        // Sources/LassoPerfectSession/PerfectBackedLassoSessionProvider.swift
        // and LassoSessionProvider's 2026-07-18 doc comment for why there's
        // no more parse-time preflight scan here.
        let sessionBridge = PerfectBackedLassoSessionProvider(
            driver: sessionDriver,
            cookies: request.cookies,
            remoteAddress: request.remoteAddress?.ipAddress ?? "",
            userAgent: request.headers["user-agent"].first ?? ""
        )

        let context = LassoContext(
            globals: baseGlobals(for: request),
            includeLoader: includeLoader,
            includePath: includePath,
            requestProvider: ServerRequestProvider(request: request, postBody: postBody),
            uploadProcessor: uploadProcessor,
            sessionProvider: sessionBridge,
            responseSink: sink,
            inlineProvider: inlineProvider,
            emailProvider: emailProvider,
            diagnosticLogSink: { [logCapture] (message: String) async -> Void in
                guard let logCapture else { return }
                await logCapture.capture("[log_critical] " + message)
            },
            stdoutSink: { (message: String) async -> Void in
                FileHandle.standardOutput.write(Data(message.utf8))
            },
            tagRegistry: tagRegistry
        )
        // The render pipeline (`LassoRenderer`, `LassoInlineProvider`,
        // `LassoDynamicQueryExecutor`) is natively `async throws` now, so
        // it can be awaited directly here — no bridge/off-pool wrapper
        // needed (see Documentation/synchronous-render-pipeline.md for the
        // pre-conversion history this superseded). `context`/`document`
        // are both `Sendable` value types; the mutated copy never needs to
        // leave this scope since nothing downstream reads `context` again
        // (only `sink`, a separately-captured reference type, does).
        var localContext = context
        let html: String
        do {
            html = try await LassoRenderer().render(document, context: &localContext)
        } catch {
            throw LassoSiteRenderError(
                underlying: error,
                // `includeStack` itself is always empty here — every
                // enclosing `performInclude`/`performLibrary` frame's own
                // `defer` already popped it back to empty as the error
                // unwound. `lastErrorIncludeStack`/`lastErrorLocation`
                // are the frozen snapshot `RendererEngine.render(_:)`
                // recorded at the moment this first threw, before any of
                // that unwinding happened.
                includeStack: localContext.lastErrorIncludeStack ?? [],
                parserDiagnostics: document.diagnostics.map(\.message),
                location: localContext.lastErrorLocation
            )
        }

        // Merge this request's fire counts into the shared store (Phase 3
        // of tag-form consolidation) — placed here, immediately after the
        // render's own do/catch, so it runs on every successful render
        // (including the redirect/file-serve/session-finalize paths below)
        // but never on a throw, which rethrows above before reaching this
        // line. A no-op when counters aren't enabled (`NoOpTagOpenFormCounterStore`).
        tagFormCounters.merge(localContext.openFormFires)

        let sessionActions = await sessionBridge.finalize()
        for action in sessionActions {
            let cookieName = "_LassoSessionTracker_\(action.call.name)"
            if action.shouldClearCookie {
                try? sink.setCookie(
                    name: cookieName, value: "",
                    domain: action.call.domain, expires: "Thu, 01 Jan 1970 00:00:00 GMT",
                    path: action.call.path ?? "/", secure: action.call.secure, httpOnly: action.call.httpOnly
                )
            } else if let token = action.token {
                try? sink.setCookie(
                    name: cookieName, value: token,
                    domain: action.call.domain, expires: action.call.cookieExpires,
                    path: action.call.path ?? "/", secure: action.call.secure, httpOnly: action.call.httpOnly
                )
            }
        }

        // web_response->sendFile / file_serve / file_stream supersede
        // normal page output — checked before the redirect check, matching
        // the same "whichever short-circuit fired wins" precedent redirect
        // already established. All three set returnSignal to abort the
        // page script, so `html` at this point is whatever the page
        // produced before the abort, which is intentionally discarded.
        if let fileServeRequest = sink.fileServeRequest {
            return try fileServeOutput(for: fileServeRequest)
        }
        if let redirectURL = sink.redirectURL {
            return RedirectOutput(to: redirectURL, status: .found)
        }
        var headers = HTTPHeaders([
            ("Content-Type", "text/html; charset=utf-8"),
        ])
        headers.add(contentsOf: sink.headerPairs)
        for cookieValue in sink.cookieHeaderValues {
            headers.add(name: "Set-Cookie", value: cookieValue)
        }
        return BytesOutput(
            head: HTTPHead(status: HTTPResponseStatus(statusCode: sink.status), headers: headers),
            body: Array(html.utf8)
        )
    }

    /// Builds the HTTP response for a `sendFile`/`file_serve`/`file_stream`
    /// request. A `.path` source is resolved through the same
    /// root-confining `fileURL(for:)` every other filesystem-touching
    /// route already uses — a missing/escaping path throws `ErrorOutput`
    /// here exactly like a normal static-asset 404/403 would, not a
    /// `[protect]`-catchable recoverable error (the page has already
    /// aborted via `returnSignal` by the time this runs). No header
    /// override requested → real `FileOutput(localPath:)`, full ETag/Range
    /// support for free. An override (`-Type`, or `sendFile`'s `name`/
    /// `-disposition`) → `Perfect-NIO`'s `FileOutput` can't be subclassed
    /// to inject extra headers (confirmed `public`, not `open`), so this
    /// branch reads the file directly and hand-assembles headers —
    /// deliberately no Range/ETag support here, a narrow documented
    /// trade-off. See Documentation/web-response-include-plan.md.
    private func fileServeOutput(for request: LassoFileServeRequest) throws -> HTTPOutput {
        switch request.source {
        case .path(let path):
            let resolved = try fileURL(for: path)
            guard request.contentType != nil || request.disposition != nil || request.fileName != nil else {
                return try FileOutput(localPath: resolved.path)
            }
            let data = try Data(contentsOf: resolved)
            return bytesFileOutput(data: data, request: request)
        case .data(let data):
            return bytesFileOutput(data: data, request: request)
        }
    }

    private func developerErrorOutput(
        _ error: Error,
        request: any HTTPRequest,
        routePath: String,
        resolvedPath: String,
        fileURL: URL?
    ) -> HTTPOutput {
        let details = RenderFailureDetails(
            error: error,
            requestURI: request.uri,
            routePath: routePath,
            resolvedPath: resolvedPath,
            filePath: fileURL?.path
        )
        fputs(details.logLine + "\n", stderr)
        if let logCapture {
            Task { await logCapture.capture("[render-error] " + details.logLine) }
        }

        // The crawl/report mode (LASSO_CRAWL_REPORT=1, see CrawlReport.swift)
        // requests every page with Accept: application/json so it can read
        // the first unsupported construct structurally instead of scraping
        // the HTML error page meant for a developer's browser.
        if request.headers["accept"].contains(where: { $0.contains("application/json") }) {
            let payload: [String: String] = [
                "errorType": details.errorType,
                "errorDescription": details.errorDescription,
            ]
            let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return BytesOutput(
                head: HTTPHead(status: .internalServerError, headers: HTTPHeaders([
                    ("Content-Type", "application/json; charset=utf-8"),
                ])),
                body: Array(body)
            )
        }

        let html = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Lasso Render Error</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 32px; line-height: 1.45; }
                code, pre { background: #f4f4f4; border-radius: 4px; padding: 2px 4px; }
                pre { padding: 12px; overflow: auto; }
            </style>
        </head>
        <body>
            <h1>Lasso Render Error</h1>
            <p><strong>Request:</strong> <code>\(details.requestURI.htmlEscaped)</code></p>
            <p><strong>Route path:</strong> <code>\(details.routePath.htmlEscaped)</code></p>
            <p><strong>Resolved site path:</strong> <code>\(details.resolvedPath.htmlEscaped)</code></p>
            <p><strong>Filesystem path:</strong> <code>\((details.filePath ?? "(unresolved)").htmlEscaped)</code></p>
            <p><strong>Error type:</strong> <code>\(details.errorType.htmlEscaped)</code></p>
            <pre>\(details.errorDescription.htmlEscaped)</pre>
            <p><strong>Failed at:</strong> <code>\(details.locationText.htmlEscaped)</code></p>
            <h2>Include Stack</h2>
            <pre>\(details.includeStackText.htmlEscaped)</pre>
            <h2>Parser Diagnostics</h2>
            <pre>\(details.parserDiagnosticsText.htmlEscaped)</pre>
        </body>
        </html>
        """
        return BytesOutput(
            head: HTTPHead(status: .internalServerError, headers: HTTPHeaders([
                ("Content-Type", "text/html; charset=utf-8"),
            ])),
            body: Array(html.utf8)
        )
    }

    private func baseGlobals(for request: any HTTPRequest) -> [String: LassoValue] {
        [
            "response_filepath": .string(request.path),
            "url_prefix": .string(""),
        ]
    }
}

/// Every datasource action failure (a genuine connector-level error — bad
/// credentials, connection refused, an unexpected schema mismatch, etc.)
/// gets logged here, even though it's also caught and converted into a
/// recoverable Lasso error frame (`LassoDatabaseActionError`/
/// `LassoFileMakerDatabaseActionError`) the page can inspect via
/// `error_currenterror`. Without this, a real backend outage — e.g. MySQL
/// access denied — is otherwise invisible outside the adapter entirely:
/// `error_currenterror` only exposes a generic "Search failed for
/// datasource 'X'." message (the real underlying error only lives in
/// `LassoErrorState.detail`, which no native tag currently exposes to
/// Lasso script), and nothing else surfaces it anywhere. A query that
/// legitimately finds zero rows and one that silently can't reach the
/// database at all look identical from inside the page — this stderr
/// line is what actually distinguishes them operationally.
/// `logCapture` is optional and this function stays synchronous (not
/// `async`) deliberately — `PerfectCRUDLassoExecutor`'s `queryHandler`/
/// `mutationHandler`/`rawSQLHandler` closure types are plain synchronous
/// throwing closures (matching PerfectCRUD's own synchronous connector
/// API), so an `async` signature here would force those call sites into
/// an unwanted bridge. A fire-and-forget `Task` for the actor-isolated
/// `LogCapture` write is safe here — this is best-effort operator
/// visibility, not something any caller waits on — matching this file's
/// existing fire-and-forget `Task { }` precedent (crawl-report mode, the
/// admin console's own startup).
func logDatasourceActionFailure(
    kind: String,
    datasource: String,
    error: Error,
    logCapture: LogCapture? = nil,
    datasourceFailureTracker: DatasourceFailureTracker? = nil
) {
    let line = "Datasource action failed kind=\(kind) datasource=\(datasource) error=\(error)"
    fputs(line + "\n", stderr)
    if let logCapture {
        Task { await logCapture.capture("[datasource] " + line) }
    }
    if let datasourceFailureTracker {
        Task { await datasourceFailureTracker.recordFailure() }
    }
}

struct LassoSiteRenderError: Error, CustomStringConvertible {
    let underlying: Error
    let includeStack: [String]
    let parserDiagnostics: [String]
    /// Where in the source this first surfaced — see
    /// `LassoContext.lastErrorLocation`'s doc comment for how this
    /// avoids the same defer-unwinding problem `includeStack` used to
    /// have (fixed alongside this: see that field's comment).
    let location: SourceRange?

    var description: String {
        String(describing: underlying)
    }
}

struct RenderFailureDetails {
    let error: Error
    let requestURI: String
    let routePath: String
    let resolvedPath: String
    let filePath: String?

    var renderError: LassoSiteRenderError? {
        error as? LassoSiteRenderError
    }

    var displayError: Error {
        renderError?.underlying ?? error
    }

    var errorType: String {
        String(reflecting: type(of: displayError))
    }

    var errorDescription: String {
        String(describing: displayError)
    }

    var includeStackText: String {
        guard let includeStack = renderError?.includeStack, includeStack.isEmpty == false else {
            return "(empty)"
        }
        return includeStack.joined(separator: "\n")
    }

    var parserDiagnosticsText: String {
        guard let diagnostics = renderError?.parserDiagnostics, diagnostics.isEmpty == false else {
            return "(none)"
        }
        return diagnostics.joined(separator: "\n")
    }

    /// The file the error actually happened in — the deepest active
    /// include (`includeStack`'s last-pushed entry) if any include was
    /// active, otherwise the top-level page itself.
    var failureFile: String {
        renderError?.includeStack.last ?? resolvedPath
    }

    var locationText: String {
        guard let location = renderError?.location else {
            return "(unknown)"
        }
        return "\(failureFile):\(location.start.line):\(location.start.column)"
    }

    var logLine: String {
        let file = filePath ?? "(unresolved)"
        return "Lasso render error request=\(requestURI) route=\(routePath) resolved=\(resolvedPath) file=\(file) type=\(errorType) error=\(errorDescription) at=\(locationText)"
    }
}

enum LassoSiteServerError: Error, CustomStringConvertible {
    case unknownDatasource(String)

    var description: String {
        switch self {
        case .unknownDatasource(let datasource): "No configured datasource for \(datasource)"
        }
    }
}

/// Wraps Perfect-NIO's `MimeReader` so it can be stored inside `Sendable`
/// value types (`ParsedPostBody`/`ServerRequestProvider`). `@unchecked` is
/// safe here specifically because one request's `MimeReader` is only ever
/// touched by the single task handling that request — read during
/// `readPostBody`, then only read again (never mutated) by Lasso code
/// during that same request's synchronous render — never shared across
/// concurrent tasks the way a long-lived service object would be.
final class RetainedMimeReader: @unchecked Sendable {
    let reader: MimeReader
    init(_ reader: MimeReader) { self.reader = reader }
}

/// A request's POST body, already read and parsed asynchronously at the
/// Perfect route-handler boundary (see `LassoSiteServer.readPostBody`)
/// before the synchronous `LassoRenderer`/`Evaluator` ever runs — keeps
/// async I/O out of the renderer entirely, per
/// `Documentation/post-body-support-plan.md`'s recommended architecture.
struct ParsedPostBody: Sendable {
    let pairs: [LassoRequestPair]
    let rawString: String
    let uploads: [LassoUploadedFile]
    /// Retains Perfect-NIO's `MimeReader` (and therefore its `BodySpec`s'
    /// temp-file handles) for as long as this value — and anything holding
    /// a reference to it, like `ServerRequestProvider` below — stays alive.
    /// `MimeReader` deletes its temp files on deinit; letting it deallocate
    /// before render (and any Lasso code reading an upload's tmpFileName)
    /// finishes would delete the file out from under it.
    let retainedMimeReader: RetainedMimeReader?

    init(
        pairs: [LassoRequestPair],
        rawString: String,
        uploads: [LassoUploadedFile] = [],
        retainedMimeReader: RetainedMimeReader? = nil
    ) {
        self.pairs = pairs
        self.rawString = rawString
        self.uploads = uploads
        self.retainedMimeReader = retainedMimeReader
    }

    static let empty = ParsedPostBody(pairs: [], rawString: "")
}

struct ServerRequestProvider: LassoRequestProvider {
    /// POST-then-GET combined, first-value-per-name-wins — backs the plain
    /// single-argument `parameter(named:)`/`action_param`/`web_request->
    /// param(name)` lookup, matching real Lasso's documented combined order.
    private let parameterValues: [String: LassoValue]
    private let queryParameterValues: [String: LassoValue]
    private let postParameterValues: [String: LassoValue]
    let queryPairs: [LassoRequestPair]
    let postPairs: [LassoRequestPair]
    let rawPostString: String
    let uploadedFiles: [LassoUploadedFile]
    /// See `ParsedPostBody.retainedMimeReader` — held here too so it
    /// survives for this provider's full lifetime (stored in
    /// `LassoContext`, alive for the whole synchronous render call), not
    /// just the originating `ParsedPostBody` value's own scope.
    private let retainedMimeReader: RetainedMimeReader?
    private let headerValues: [String: LassoValue]
    private let cookieValues: [String: LassoValue]
    let requestMethod: String
    let requestURI: String
    let path: String
    let isHTTPS: Bool
    let remoteAddress: String
    let remotePort: Int
    let serverName: String
    let serverPort: Int
    let contentType: String
    let contentLength: Int

    init(request: any HTTPRequest, postBody: ParsedPostBody = .empty) {
        // request.searchArgs is Perfect-NIO's own QueryDecoder, already
        // parsed from the URI's query string when the request was built —
        // switching from URLComponents fixes a real pre-existing bug for
        // free: URLComponents doesn't treat "+" as space in query strings
        // the way application/x-www-form-urlencoded requires; QueryDecoder
        // does.
        let queryPairs = (request.searchArgs?.map { LassoRequestPair(name: $0.0, value: .string($0.1)) }) ?? []
        let postPairs = postBody.pairs

        func firstValuePerName(_ pairs: [LassoRequestPair]) -> [String: LassoValue] {
            var result: [String: LassoValue] = [:]
            for pair in pairs where result[pair.name.lowercased()] == nil {
                result[pair.name.lowercased()] = pair.value
            }
            return result
        }

        self.queryPairs = queryPairs
        self.postPairs = postPairs
        rawPostString = postBody.rawString
        uploadedFiles = postBody.uploads
        retainedMimeReader = postBody.retainedMimeReader
        queryParameterValues = firstValuePerName(queryPairs)
        postParameterValues = firstValuePerName(postPairs)
        // POST first, matching real Lasso 9's documented combined params()
        // order — firstValuePerName keeps the first pair it sees per name,
        // so POST pairs win over GET pairs with the same name.
        parameterValues = firstValuePerName(postPairs + queryPairs)
        headerValues = Dictionary(uniqueKeysWithValues: request.headers.map {
            ($0.name.lowercased(), LassoValue.string($0.value))
        })
        cookieValues = Dictionary(uniqueKeysWithValues: request.cookies.map {
            ($0.key.lowercased(), LassoValue.string($0.value))
        })
        requestMethod = request.method.rawValue
        requestURI = request.uri
        path = request.path
        // Pragmatic heuristic: trust a reverse proxy's X-Forwarded-Proto
        // header over deep NIO channel/TLS pipeline introspection.
        isHTTPS = request.headers["x-forwarded-proto"].first?.lowercased() == "https"
        remoteAddress = request.remoteAddress?.ipAddress ?? ""
        remotePort = request.remoteAddress?.port ?? 0
        // reference.lassosoft.com: "[Server_Name] returns the domain name
        // of the current server. If the name ... cannot be determined
        // then the IP address ... is returned instead" — i.e. the virtual
        // host from the request (the Host header nginx already forwards
        // via `proxy_set_header Host $host;`), not this process's own
        // bind address. The previous `request.localAddress?.ipAddress`
        // always returned "127.0.0.1" for every request regardless of
        // the actual browsed domain, since that's this dev server's fixed
        // loopback bind address — silently breaking every site
        // environment-detection branch keyed on `server_name` (confirmed
        // live 2026-07-18: koi.lasso's own
        // `if(server_name >> 'scrubs.local' || ... || server_name >>
        // '127.0.0.1' ...)` always took the 127.0.0.1 branch no matter
        // what domain koi.scrubs.test was actually served from).
        serverName = Self.hostName(fromHostHeader: request.headers["host"].first) ?? request.localAddress?.ipAddress ?? ""
        serverPort = request.localAddress?.port ?? 0
        contentType = request.contentType ?? ""
        contentLength = request.contentLength
    }

    /// Strips a trailing `:port` from a raw `Host` header value — real
    /// Lasso's documented `Server_Name` is the domain name alone (e.g.
    /// `koi.scrubs.test`, not `koi.scrubs.test:8443`). Internal (not
    /// private) so `LassoPerfectServerTests` can exercise it directly via
    /// `@testable import` without needing a full NIO `HTTPRequest` mock.
    static func hostName(fromHostHeader header: String?) -> String? {
        guard let header, header.isEmpty == false else { return nil }
        guard let colonIndex = header.firstIndex(of: ":") else { return header }
        return String(header[..<colonIndex])
    }

    func parameter(named name: String) -> LassoValue {
        parameterValues[name.lowercased()] ?? .void
    }

    func header(named name: String) -> LassoValue {
        headerValues[name.lowercased()] ?? .void
    }

    func cookie(named name: String) -> LassoValue {
        cookieValues[name.lowercased()] ?? .void
    }

    var parameters: [String: LassoValue] {
        parameterValues
    }

    var queryParameters: [String: LassoValue] {
        queryParameterValues
    }

    var postParameters: [String: LassoValue] {
        postParameterValues
    }

    var headers: [String: LassoValue] {
        headerValues
    }

    var cookies: [String: LassoValue] {
        cookieValues
    }
}

/// Builds the header-carrying HTTP response for a `sendFile`/`file_serve`/
/// `file_stream` request whose source is already in memory (a `sendFile`
/// string payload, or a `.path` source that needed a header override and
/// so was read into memory by `LassoSiteServer.fileServeOutput` instead of
/// streamed via `FileOutput`). A free function (not a `LassoSiteServer`
/// method) so it's independently unit-testable — it touches no server
/// state, only the request's own fields.
func bytesFileOutput(data: Data, request: LassoFileServeRequest) -> HTTPOutput {
    var headers = HTTPHeaders([
        ("Content-Type", headerSafe(request.contentType ?? "application/octet-stream")),
    ])
    if let disposition = request.disposition {
        if let fileName = request.fileName {
            headers.add(name: "Content-Disposition", value: "\(headerSafe(disposition)); filename=\"\(quotedStringSafe(fileName))\"")
        } else {
            headers.add(name: "Content-Disposition", value: headerSafe(disposition))
        }
    }
    return BytesOutput(
        head: HTTPHead(status: .ok, headers: headers),
        body: Array(data)
    )
}

/// Strips CR/LF from Lasso-script-controlled values before they land in a
/// raw header — `-Type`/`-Disposition`/`name` all originate from evaluated
/// Lasso expressions, and an unsanitized newline there would be HTTP
/// header/response-splitting.
func headerSafe(_ value: String) -> String {
    value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
}

/// Escapes a value for use inside an RFC 6266 `quoted-string` (the
/// `filename="..."` part of `Content-Disposition`) — `headerSafe` alone
/// strips CR/LF (preventing response-splitting) but doesn't escape `"`/
/// `\`, so a script-controlled filename containing a quote could otherwise
/// terminate the quoted string early and inject trailing header
/// parameters.
func quotedStringSafe(_ value: String) -> String {
    headerSafe(value)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

final class ServerResponseSink: LassoResponseSink, @unchecked Sendable {
    private(set) var status: Int = 200
    private(set) var redirectURL: String?
    private(set) var headerPairs: [(name: String, value: String)] = []
    private(set) var cookieHeaderValues: [String] = []
    private(set) var fileServeRequest: LassoFileServeRequest?

    func setStatus(_ status: Int) throws {
        self.status = status
    }

    func getStatus() -> Int {
        status
    }

    func redirect(to url: String) throws {
        // `url` is Lasso-script-controlled (real corpus: TS_lasso9's
        // graphics/headeradmincourt.lasso has a redirect_url target with
        // an accidentally-embedded raw newline in its own source) and was
        // previously stored completely unsanitized, later handed straight
        // into RedirectOutput's Location header -- unlike headerSafe's
        // existing use for -Type/-Disposition/filename, matching how
        // Cookie_Set's own name/value already got the same CRLF-stripping
        // treatment. Live-verified: an unsanitized embedded newline here
        // corrupted the HTTP response badly enough that the client saw
        // the connection drop entirely rather than a clean redirect or
        // error.
        redirectURL = headerSafe(url)
    }

    func setHeader(name: String, value: String) throws {
        // Same CRLF/header-injection class as redirect(to:) above -- a
        // Lasso-script-controlled header name or value reaches raw HTTP
        // output here with no sanitization otherwise.
        headerPairs.append((headerSafe(name), headerSafe(value)))
    }

    func setCookie(name: String, value: String) throws {
        try setCookie(name: name, value: value, domain: nil, expires: nil, path: nil, secure: false, httpOnly: false)
    }

    func setCookie(
        name: String,
        value: String,
        domain: String?,
        expires: String?,
        path: String?,
        secure: Bool,
        httpOnly: Bool
    ) throws {
        var parts = ["\(name)=\(value)"]
        if let domain { parts.append("Domain=\(domain)") }
        if let expires { parts.append("Expires=\(expires)") }
        if let path { parts.append("Path=\(path)") }
        if secure { parts.append("Secure") }
        if httpOnly { parts.append("HttpOnly") }
        cookieHeaderValues.append(parts.joined(separator: "; "))
    }

    func serveFile(_ request: LassoFileServeRequest) throws {
        fileServeRequest = request
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// Offline diff mode (LASSO_CRAWL_DIFF_BASELINE + LASSO_CRAWL_DIFF_CURRENT)
// needs neither a site root nor a running server — check for it before
// ServerConfig.load() so it stays a lightweight, standalone operation
// rather than printing site/server setup output for what's really just
// comparing two JSON files.
if let baselinePath = ProcessInfo.processInfo.environment["LASSO_CRAWL_DIFF_BASELINE"],
   let currentPath = ProcessInfo.processInfo.environment["LASSO_CRAWL_DIFF_CURRENT"] {
    guard let baseline = CrawlReport.loadBaseline(baselinePath) else {
        fputs("Could not read LASSO_CRAWL_DIFF_BASELINE: \(baselinePath)\n", stderr)
        exit(1)
    }
    guard let current = CrawlReport.loadBaseline(currentPath) else {
        fputs("Could not read LASSO_CRAWL_DIFF_CURRENT: \(currentPath)\n", stderr)
        exit(1)
    }
    CrawlReport.printDiff(CrawlReport.diff(baseline: baseline, current: current))
    exit(0)
}

let config = try ServerConfig.load()
// Constructed here (not inside the `config.adminConsoleEnabled` block
// below) so `LassoSiteServer.init` can wire real request/error traffic
// into them from the start — no ring buffer to feed or counters to
// increment when the admin console is disabled, though, so both stay
// `nil` in that case rather than paying for an actor nothing will ever read.
let logCapture = config.adminConsoleEnabled ? LogCapture() : nil
let metrics = config.adminConsoleEnabled ? AdminMetrics() : nil
// Always default-constructed (cheap — an idle actor) so `LassoAdminDelegate.init`
// always has one to pass, matching `crawlTracker`'s own convention; only actually
// used when `config.cwpJanitorEnabled` starts the poll loop below.
let janitorTracker = CWPSessionJanitorTracker()
let siteServer = try LassoSiteServer(config: config, logCapture: logCapture, metrics: metrics)
// Started below (after the "Listening" print moves inside its ready callback) as a
// cancellable, awaitable Task rather than a bare blocking call — the admin console's
// "restart-server" action needs a handle it can `.cancel()` to gracefully hand off to a
// freshly spawned replacement process before this one exits. See RestartReadiness.swift.
let siteServerTask = Task.detached {
    // .detached, not a plain Task { } — top-level code in main.swift is implicitly
    // MainActor-isolated in Swift 6, and Server.withServer's closure runs from
    // inside its own internal (non-MainActor) task group; a MainActor-isolated
    // closure can't safely cross that boundary. Nothing in this closure touches
    // MainActor-isolated state, so detaching is correct, not just a workaround.
    try await Server(routes: try siteServer.routes(), port: config.port, alwaysReusePort: true)
        .withServer { boundPort in
            print("Listening: http://localhost:\(boundPort)")
            // stdout becomes block-buffered once redirected to a pipe (not a TTY) — a
            // restart's spawned-child readiness watcher reads this process's stdout when
            // *it's* the child, and without an explicit flush this line could sit in libc's
            // buffer indefinitely instead of ever reaching the parent.
            fflush(stdout)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
}
print("Lasso Perfect test server")
print("Site root: \(config.siteRoot.path)")
if let startupPath = config.startupPath {
    let result = await loadLassoStartupDirectory(
        at: startupPath,
        allowedExtensions: config.lassoExtensions,
        tagRegistry: siteServer.tagRegistry
    )
    print("Startup folder: \(startupPath.path) (\(result.loadedFiles.count) loaded, \(result.failedFiles.count) failed)")
    for failure in result.failedFiles {
        fputs("Startup load failed: \(failure.file): \(failure.error)\n", stderr)
    }
} else {
    print("Startup folder: none")
}
if let appsPath = config.appsPath {
    let result = await loadLassoApps(at: appsPath, tagRegistry: siteServer.tagRegistry)
    print("LassoApps: \(appsPath.path) (\(result.loadedFiles.count) loaded, \(result.failedFiles.count) failed)")
    for failure in result.failedFiles {
        fputs("LassoApp load failed: \(failure.file): \(failure.error)\n", stderr)
    }
} else {
    print("LassoApps: none")
}
// "Listening: ..." now prints from inside siteServerTask's withServer callback (above),
// only once the server has genuinely bound and started accepting — not unconditionally
// here, ahead of the actual bind.
if config.datasourceMap.isEmpty {
    print("Datasource aliases: none")
} else {
    let mapped = config.datasourceMap.sorted { $0.key < $1.key }
        .map { "\($0.key) -> \($0.value)" }
        .joined(separator: ", ")
    print("Datasource aliases: \(mapped)@\(config.mysqlHost)")
}
print("Session driver: \(config.sessionDriver)")
await siteServer.sessionDriver.setup()

if config.crawlReportMode {
    print("Crawl report mode: requesting every discovered page once listening...")
    Task {
        // Give the NIO server a moment to actually bind before hitting it —
        // there's no separate "ready" signal to await here.
        try? await Task.sleep(for: .seconds(1))

        // Focused rerun: an explicit path list wins outright; otherwise a
        // baseline + failure substring derives one. Neither set -> the
        // usual full filesystem walk (CrawlReport.run's default).
        var pathList: [String]?
        if let pathListPath = config.crawlPathListPath {
            guard let loaded = CrawlReport.loadPathList(pathListPath) else {
                fputs("Could not read LASSO_CRAWL_PATH_LIST: \(pathListPath)\n", stderr)
                exit(1)
            }
            pathList = loaded
        } else if let baselinePath = config.crawlBaselinePath, let onlyFailure = config.crawlOnlyFailure {
            guard let baseline = CrawlReport.loadBaseline(baselinePath) else {
                fputs("Could not read LASSO_CRAWL_BASELINE: \(baselinePath)\n", stderr)
                exit(1)
            }
            pathList = CrawlReport.pathsMatchingFailure(baseline, substring: onlyFailure)
            print("Focused rerun: \(pathList?.count ?? 0) page(s) previously matching '\(onlyFailure)'.")
        }

        await siteServer.datasourceFailureTracker.reset()
        let (results, excludedCount, abortedByCircuitBreaker, sitemapSummary) = await CrawlReport.run(
            baseURL: "http://localhost:\(config.port)",
            siteRoot: config.siteRoot,
            extensions: config.lassoExtensions,
            excludePaths: config.crawlExcludePaths,
            pathList: pathList,
            requestDelayMS: config.crawlRequestDelayMS,
            circuitBreakerThreshold: config.crawlCircuitBreakerThreshold,
            datasourceFailureThreshold: config.crawlDatasourceFailureThreshold,
            currentDatasourceFailureCount: { await siteServer.datasourceFailureTracker.currentCount() },
            sitemapEnabled: config.crawlSitemapEnabled,
            sitemapEntryPath: config.crawlSitemapPath,
            sitemapAllowedOrigin: config.crawlSitemapOrigin,
            sitemapMaxSubSitemaps: config.crawlSitemapMaxSubSitemaps,
            sitemapMaxURLs: config.crawlSitemapMaxURLs,
            sitemapMaxResponseBytes: config.crawlSitemapMaxResponseBytes
        )
        CrawlReport.printAndWrite(
            results,
            outputPath: config.crawlReportOutputPath,
            excludedCount: excludedCount,
            abortedByCircuitBreaker: abortedByCircuitBreaker,
            sitemapSummary: sitemapSummary
        )
        exit(0)
    }
}

// CWP session janitor: an opt-in background poller that lists FileMaker
// Server Admin API clients and disconnects stale/excess Custom Web
// Publishing sessions. Off by default — see `ServerConfig.cwpJanitorEnabled`'s
// doc comment for why this exists. All the actual selection/sweep logic
// lives in `PerfectFileMakerAdminAPI` (`CWPSessionJanitor`/`CWPSessionSelector`)
// — this is generic to any Admin API consumer, not Lasso-specific, so
// `lasso-perfect-server` just supplies its own config values and logging
// sink and calls into the package. `cwpAdminAPIClient`/`cwpJanitorTask` stay
// `nil` when disabled, so the admin delegate can cleanly no-op the manual
// trigger action and skip restart cancellation.
var cwpAdminAPIClient: FMAdminClient?
var cwpJanitorTask: Task<Void, Never>?
if config.cwpJanitorEnabled {
    print("CWP session janitor: enabled (dry-run: \(config.cwpJanitorDryRun), poll every \(config.cwpJanitorPollIntervalSeconds)s)")
    let adminAPIClient = FMAdminClient(
        host: config.fmAdminAPIHost!, // validated non-nil in ServerConfig.load()
        port: config.fmAdminAPIPort,
        username: config.fmAdminAPIUser!,
        password: config.fmAdminAPIPassword!,
        urlSession: config.fmAdminAPITrustSelfSignedTLS ? FMAdminClient.insecureURLSession() : .shared
    )
    cwpAdminAPIClient = adminAPIClient
    cwpJanitorTask = Task {
        while !Task.isCancelled {
            await CWPSessionJanitor.sweep(
                client: adminAPIClient,
                durationThresholdSeconds: config.cwpJanitorDurationThresholdSeconds,
                maxSessions: config.cwpJanitorMaxSessions,
                minFloor: config.cwpJanitorMinFloor,
                maxDisconnectsPerSweep: config.cwpJanitorMaxDisconnectsPerSweep,
                dryRun: config.cwpJanitorDryRun,
                tracker: janitorTracker,
                log: { line in await logCapture?.capture(line) }
            )
            try? await Task.sleep(for: .seconds(config.cwpJanitorPollIntervalSeconds))
        }
    }
} else {
    print("CWP session janitor: disabled (set LASSO_CWP_JANITOR_ENABLED=1 to enable)")
}

if config.adminConsoleEnabled {
    print("Admin console: enabled on http://127.0.0.1:\(config.adminConsolePort) — token: \(config.adminConsoleTokenPath)")
    let adminDelegate = LassoAdminDelegate(
        config: config,
        startTime: Date(),
        fileMakerRegistry: siteServer.fileMakerRegistry,
        logCapture: logCapture,
        baseURL: "http://localhost:\(config.port)",
        siteServerTask: siteServerTask,
        datasourceFailureTracker: siteServer.datasourceFailureTracker,
        janitorTracker: janitorTracker,
        cwpAdminAPIClient: cwpAdminAPIClient,
        cwpJanitorTask: cwpJanitorTask,
        smtpConnectionReaperTask: siteServer.smtpConnectionReaperTask,
        emailJobSweepTask: siteServer.emailJobSweepTask
    )
    let admin = try AdminConsole(
        port: config.adminConsolePort,
        tokenFilePath: config.adminConsoleTokenPath,
        forceNewToken: config.adminConsoleTokenRotate,
        logCapture: logCapture,
        metrics: metrics,
        delegate: adminDelegate
    )
    // Runs concurrently with the main server's own blocking .run() below —
    // matches the existing crawl-report-mode Task above, this project's
    // established pattern for "start something alongside the main serve
    // loop without blocking it."
    //
    // Retries on bind failure, unlike a bare one-shot attempt: the admin
    // port deliberately does NOT use `alwaysReusePort` (see
    // FileMakerConnectionRegistry.swift's sibling doc comment on
    // AdminConsoleIntegration.swift's restart action for why), so when a
    // "restart-server" handoff spawns this process, the *previous*
    // process's admin console can still be bound to the same port for a
    // little while after this one starts — its own shutdown isn't
    // synchronized with the site server's readiness handoff, only
    // triggered by it, with a drain step that can itself take a few
    // seconds. Found live: without a retry, the very first restart in this
    // feature's own testing left the new process with no admin console at
    // all until the *next* restart. 20 attempts, 500ms apart (10s total) —
    // matches the restart action's own bounded drain fallback, so this
    // process gives the old one at least as long to actually let go of
    // the port as that action is willing to wait for a graceful exit.
    Task {
        var lastError: Error?
        for attempt in 1...20 {
            do {
                try await admin.run()
                return // run() only returns after a clean, intentional shutdown
            } catch {
                lastError = error
                if attempt < 20 {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        fputs("[AdminConsole] failed to start after repeated attempts: \(lastError.map { "\($0)" } ?? "unknown error")\n", stderr)
    }
} else {
    print("Admin console: disabled (set LASSO_ADMIN_CONSOLE=1 to enable)")
}

do {
    try await siteServerTask.value
} catch is CancellationError {
    // Expected: the "restart-server" admin action cancelled this deliberately
    // once a replacement process proved itself healthy.
} catch {
    fputs("Site server failed: \(error)\n", stderr)
    exit(1)
}

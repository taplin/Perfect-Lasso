import Foundation
import LassoCrawlReport
import LassoParser
import LassoPerfectCRUD
import LassoPerfectFileMaker
import LassoPerfectSession
import PerfectCRUD
import PerfectFileMaker
import PerfectMySQL
import PerfectNIO
import NIOHTTP1
import PerfectSessionCore
import PerfectSessionMySQL

struct ServerConfig: Sendable {
    let siteRoot: URL
    let port: Int
    let lassoExtensions: Set<String>
    let startupPath: URL?
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

        return ServerConfig(
            siteRoot: root,
            port: env["LASSO_SERVER_PORT"].flatMap(Int.init) ?? 8181,
            lassoExtensions: Set(extensions),
            startupPath: startupPathValue,
            datasourceMap: datasourceMap,
            mysqlHost: datasourceFile?.mysql?.host ?? env["LASSO_MYSQL_HOST"] ?? "localhost",
            mysqlPort: datasourceFile?.mysql?.port ?? env["LASSO_MYSQL_PORT"].flatMap(Int.init),
            mysqlDatabase: datasourceFile?.mysql?.sessionDatabase ?? env["LASSO_MYSQL_DATABASE"] ?? "",
            mysqlUser: datasourceFile?.mysql?.user ?? env["LASSO_MYSQL_USER"],
            mysqlPassword: datasourceFile?.mysql?.password ?? env["LASSO_MYSQL_PASSWORD"],
            mysqlAllowWrites: datasourceFile?.mysql?.allowWrites ?? Self.isTruthyEnv(env["LASSO_MYSQL_ALLOW_WRITES"]),
            mysqlAllowRawSQL: datasourceFile?.mysql?.allowRawSQL ?? Self.isTruthyEnv(env["LASSO_MYSQL_ALLOW_RAW_SQL"]),
            filemakerDatasourceAliases: filemakerDatasourceAliases,
            filemakerHost: filemakerHost,
            filemakerPort: datasourceFile?.filemaker?.port ?? env["LASSO_FILEMAKER_PORT"].flatMap(Int.init),
            filemakerUser: datasourceFile?.filemaker?.user ?? env["LASSO_FILEMAKER_USER"],
            filemakerPassword: datasourceFile?.filemaker?.password ?? env["LASSO_FILEMAKER_PASSWORD"],
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
            crawlOnlyFailure: env["LASSO_CRAWL_ONLY_FAILURE"]
        )
    }

    private static func isTruthyEnv(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
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
///             "sessionDatabase": "...", "allowWrites": false, "allowRawSQL": false},
///   "filemaker": {"host": "...", "port": 80, "user": "...", "password": "...",
///                 "allowWrites": false},
///   "datasources": {
///     "some_mysql_alias": {"type": "mysql", "schema": "some_schema"},
///     "some_filemaker_alias": {"type": "filemaker"}
///   }
/// }
/// ```
/// Back-compat: a config file written before FileMaker support — flat
/// top-level `host`/`port`/`user`/`password`/`sessionDatabase`/
/// `allowWrites`/`allowRawSQL` fields (read as the `mysql` block when no
/// nested `mysql` key is present) and a `datasources` map of bare
/// `"alias": "schemaName"` strings (read as `{type: "mysql", schema:
/// "schemaName"}`) — still decodes and behaves identically.
struct DatasourceFileConfig: Decodable {
    var mysql: MySQLConnectionFileConfig?
    var filemaker: FileMakerConnectionFileConfig?
    var datasources: [String: DatasourceEntry]

    private enum CodingKeys: String, CodingKey {
        case mysql, filemaker, datasources
        case host, port, user, password, sessionDatabase, allowWrites, allowRawSQL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        datasources = try container.decodeIfPresent([String: DatasourceEntry].self, forKey: .datasources) ?? [:]
        filemaker = try container.decodeIfPresent(FileMakerConnectionFileConfig.self, forKey: .filemaker)
        if let nestedMySQL = try container.decodeIfPresent(MySQLConnectionFileConfig.self, forKey: .mysql) {
            mysql = nestedMySQL
        } else {
            let flatHost = try container.decodeIfPresent(String.self, forKey: .host)
            let flatPort = try container.decodeIfPresent(Int.self, forKey: .port)
            let flatUser = try container.decodeIfPresent(String.self, forKey: .user)
            let flatPassword = try container.decodeIfPresent(String.self, forKey: .password)
            let flatSessionDatabase = try container.decodeIfPresent(String.self, forKey: .sessionDatabase)
            let flatAllowWrites = try container.decodeIfPresent(Bool.self, forKey: .allowWrites)
            let flatAllowRawSQL = try container.decodeIfPresent(Bool.self, forKey: .allowRawSQL)
            let anyFlatFieldPresent = flatHost != nil || flatPort != nil || flatUser != nil ||
                flatPassword != nil || flatSessionDatabase != nil || flatAllowWrites != nil || flatAllowRawSQL != nil
            mysql = anyFlatFieldPresent ? MySQLConnectionFileConfig(
                host: flatHost,
                port: flatPort,
                user: flatUser,
                password: flatPassword,
                sessionDatabase: flatSessionDatabase,
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

    private enum CodingKeys: String, CodingKey { case type, schema }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let flatSchema = try? single.decode(String.self) {
            type = .mysql
            schema = flatSchema
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(Backend.self, forKey: .type)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
    }
}

enum ServerConfigError: Error, CustomStringConvertible {
    case invalidSiteRoot(String)
    case duplicateDatasourceAlias([String])
    /// A `datasources` entry has `type: "filemaker"` but no `filemaker`
    /// connection block (or `LASSO_FILEMAKER_HOST`) supplies a host —
    /// caught here, at startup, rather than deferred to a confusing
    /// failure the first time a page actually queries that alias.
    case missingFileMakerHost

    var description: String {
        switch self {
        case .invalidSiteRoot(let path): "Invalid LASSO_SITE_ROOT: \(path)"
        case .duplicateDatasourceAlias(let aliases):
            "Datasource aliases differ only by case, which is ambiguous (Lasso datasource names are case-insensitive): \(aliases.joined(separator: ", "))"
        case .missingFileMakerHost:
            "A FileMaker datasource is configured but no FileMaker host was supplied (set \"filemaker\": {\"host\": ...} in the datasource config file, or LASSO_FILEMAKER_HOST)."
        }
    }
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

    init(config: ServerConfig) throws {
        self.config = config
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
            sessionDriver = MySQLSessionDriver()
        default:
            sessionDriver = MemorySessionDriver()
        }

        let mysqlProvider: LassoDynamicInlineProvider?
        if config.datasourceMap.isEmpty == false {
            // The set of real MySQL schema names this deployment is
            // configured for — LassoDynamicInlineProvider remaps a
            // recognized Lasso-side alias to one of these before this
            // executor ever sees it; an unrecognized alias passes through
            // unmapped and is rejected here rather than allowing queries
            // against arbitrary named schemas that happen to already
            // exist on the server.
            let knownDatabases = Set(config.datasourceMap.values)
            @Sendable func makeDatabase(_ database: String) throws -> Database<MySQLDatabaseConfiguration> {
                try Database(configuration: MySQLDatabaseConfiguration(
                    database: database,
                    host: config.mysqlHost,
                    port: config.mysqlPort,
                    username: config.mysqlUser,
                    password: config.mysqlPassword
                ))
            }
            let executor = PerfectCRUDLassoExecutor(
                capabilities: { datasource in
                    guard knownDatabases.contains(datasource) else { return .readOnly }
                    return LassoDatasourceCapabilities(
                        allowsInsert: config.mysqlAllowWrites,
                        allowsUpdate: config.mysqlAllowWrites,
                        allowsDelete: config.mysqlAllowWrites,
                        allowsRawSQL: config.mysqlAllowRawSQL
                    )
                },
                queryHandler: { datasource, query in
                    guard knownDatabases.contains(datasource) else {
                        throw LassoSiteServerError.unknownDatasource(datasource)
                    }
                    do {
                        return try makeDatabase(datasource).select(query)
                    } catch let error as LassoDatabaseActionError {
                        throw error
                    } catch {
                        throw LassoDatabaseActionError(kind: .search, datasource: datasource, underlying: error)
                    }
                },
                mutationHandler: { datasource, mutation in
                    guard knownDatabases.contains(datasource) else {
                        throw LassoSiteServerError.unknownDatasource(datasource)
                    }
                    do {
                        return try makeDatabase(datasource).mutate(mutation)
                    } catch let error as LassoDatabaseActionError {
                        throw error
                    } catch {
                        let kind: LassoDatabaseActionFailureKind = switch mutation.action {
                        case .insert: .add
                        case .update: .update
                        case .delete: .delete
                        }
                        throw LassoDatabaseActionError(kind: kind, datasource: datasource, underlying: error)
                    }
                },
                rawSQLHandler: { datasource, sql in
                    guard knownDatabases.contains(datasource) else {
                        throw LassoSiteServerError.unknownDatasource(datasource)
                    }
                    do {
                        return try makeDatabase(datasource).execute(sql)
                    } catch let error as LassoDatabaseActionError {
                        throw error
                    } catch {
                        throw LassoDatabaseActionError(kind: .sql, datasource: datasource, underlying: error)
                    }
                }
            )
            mysqlProvider = LassoDynamicInlineProvider(
                executor: executor,
                datasourceAliases: config.datasourceMap
            )
        } else {
            mysqlProvider = nil
        }

        let fileMakerProvider: LassoDynamicInlineProvider?
        if config.filemakerDatasourceAliases.isEmpty == false {
            // ServerConfig.load() already validates filemakerHost is set
            // whenever any FileMaker alias is configured
            // (ServerConfigError.missingFileMakerHost) — "localhost" here
            // is just a defensive fallback for a ServerConfig built by
            // hand (e.g. in tests) rather than through .load().
            let filemakerHost = config.filemakerHost ?? "localhost"
            let filemakerPort = config.filemakerPort ?? 80
            let filemakerUser = config.filemakerUser ?? ""
            let filemakerPassword = config.filemakerPassword ?? ""
            let filemakerUseTLS = filemakerPort == 443
            let filemakerScheme = filemakerUseTLS ? "https" : "http"
            let executor = PerfectFileMakerLassoExecutor(
                allowWrites: config.filemakerAllowWrites,
                baseURL: "\(filemakerScheme)://\(filemakerHost):\(filemakerPort)"
            ) { query, kind, datasource in
                // A fresh FileMakerServer per call (matching makeDatabase's
                // own per-call construction above), even though the
                // resurrected FileMakerServer is now natively Sendable and
                // could safely be built once and captured — keeps this
                // closure's shape consistent with makeDatabase's and with
                // how it looked before the resurrection, when
                // FileMakerServer wasn't Sendable at all.
                let server = FileMakerServer(
                    host: filemakerHost, port: filemakerPort,
                    userName: filemakerUser, password: filemakerPassword,
                    useTLS: filemakerUseTLS
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
                    throw LassoFileMakerDatabaseActionError(kind: kind, datasource: datasource, underlying: error)
                }
            }
            // No alias remapping needed — the alias itself IS the
            // FileMaker database-file name.
            fileMakerProvider = LassoDynamicInlineProvider(executor: executor, datasourceAliases: [:])
        } else {
            fileMakerProvider = nil
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
    }

    func routes() throws -> Routes<HTTPRequest, HTTPOutput> {
        let health = root().GET.path("__lasso_health").map { _ -> HTTPOutput in
            TextOutput("ok")
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
        return try root().dir(health, rootFile, files, rootFilePost, filesPost)
    }

    private func handle(request: any HTTPRequest, trailingPath: String) async throws -> HTTPOutput {
        var resolvedPath = trailingPath
        var resolvedFileURL: URL?
        do {
            let path = try resolveRequestPath(trailingPath)
            resolvedPath = path
            let fileURL = try fileURL(for: path)
            resolvedFileURL = fileURL
            if shouldRender(fileURL) {
                let postBody = try await readPostBody(request: request)
                return try await render(fileURL: fileURL, request: request, includePath: path, postBody: postBody)
            }
            return try FileOutput(localPath: fileURL.path)
        } catch let error as ErrorOutput {
            throw error
        } catch {
            return developerErrorOutput(
                error,
                request: request,
                routePath: trailingPath,
                resolvedPath: resolvedPath,
                fileURL: resolvedFileURL
            )
        }
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

    private func resolveRequestPath(_ trailingPath: String) throws -> String {
        let raw = trailingPath.isEmpty ? "index.lasso" : trailingPath
        let decoded = raw.removingPercentEncoding ?? raw
        let normalized = decoded.split(separator: "/").reduce(into: [String]()) { parts, component in
            switch component {
            case "", ".": break
            case "..": _ = parts.popLast()
            default: parts.append(String(component))
            }
        }.joined(separator: "/")
        return normalized.isEmpty ? "index.lasso" : normalized
    }

    private func fileURL(for relativePath: String) throws -> URL {
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

    private func directoryIndexURL(for directory: URL) throws -> URL {
        for name in ["index.lasso", "index.html", "default.lasso", "default.html"] {
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

    private func shouldRender(_ url: URL) -> Bool {
        config.lassoExtensions.contains(url.pathExtension.lowercased())
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

        // Session preflight: real create/resume against SessionDriver is
        // async, the renderer/evaluator is not — scan for literal
        // session_start(...) calls and load them now, before the sync
        // render runs. See Documentation/session-upload-support-plan.md
        // and Sources/LassoPerfectSession/PerfectBackedLassoSessionProvider.swift.
        let sessionCalls = LassoSessionPreflight.scan(document)
        let sessionBridge: PerfectBackedLassoSessionProvider? = sessionCalls.isEmpty ? nil : PerfectBackedLassoSessionProvider()
        if let sessionBridge {
            await sessionBridge.prepare(
                calls: sessionCalls,
                driver: sessionDriver,
                cookies: request.cookies,
                remoteAddress: request.remoteAddress?.ipAddress ?? "",
                userAgent: request.headers["user-agent"].first ?? ""
            )
        }

        let context = LassoContext(
            globals: baseGlobals(for: request),
            includeLoader: includeLoader,
            includePath: includePath,
            requestProvider: ServerRequestProvider(request: request, postBody: postBody),
            uploadProcessor: uploadProcessor,
            sessionProvider: sessionBridge,
            responseSink: sink,
            inlineProvider: inlineProvider,
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
                includeStack: localContext.includeStack,
                parserDiagnostics: document.diagnostics.map(\.message)
            )
        }

        if let sessionBridge {
            let actions = await sessionBridge.finalize(driver: sessionDriver)
            for action in actions {
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

struct LassoSiteRenderError: Error, CustomStringConvertible {
    let underlying: Error
    let includeStack: [String]
    let parserDiagnostics: [String]

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

    var logLine: String {
        let file = filePath ?? "(unresolved)"
        return "Lasso render error request=\(requestURI) route=\(routePath) resolved=\(resolvedPath) file=\(file) type=\(errorType) error=\(errorDescription)"
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
        serverName = request.localAddress?.ipAddress ?? ""
        serverPort = request.localAddress?.port ?? 0
        contentType = request.contentType ?? ""
        contentLength = request.contentLength
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
        redirectURL = url
    }

    func setHeader(name: String, value: String) throws {
        headerPairs.append((name, value))
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
let siteServer = try LassoSiteServer(config: config)
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
print("Listening: http://localhost:\(config.port)")
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

        let (results, excludedCount) = await CrawlReport.run(
            baseURL: "http://localhost:\(config.port)",
            siteRoot: config.siteRoot,
            extensions: config.lassoExtensions,
            excludePaths: config.crawlExcludePaths,
            pathList: pathList
        )
        CrawlReport.printAndWrite(results, outputPath: config.crawlReportOutputPath, excludedCount: excludedCount)
        exit(0)
    }
}

try await Server(routes: try siteServer.routes(), port: config.port).run()

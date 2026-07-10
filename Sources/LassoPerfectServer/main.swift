import Foundation
import LassoParser
import LassoPerfectCRUD
import PerfectCRUD
import PerfectMySQL
import PerfectNIO
import NIOHTTP1

struct ServerConfig: Sendable {
    let siteRoot: URL
    let port: Int
    let lassoExtensions: Set<String>
    let startupPath: URL?
    let datasourceAlias: String?
    let mysqlHost: String
    let mysqlPort: Int?
    let mysqlDatabase: String
    let mysqlUser: String?
    let mysqlPassword: String?

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

        return ServerConfig(
            siteRoot: root,
            port: env["LASSO_SERVER_PORT"].flatMap(Int.init) ?? 8181,
            lassoExtensions: Set(extensions),
            startupPath: startupPathValue,
            datasourceAlias: env["LASSO_DATASOURCE_ALIAS"],
            mysqlHost: env["LASSO_MYSQL_HOST"] ?? "localhost",
            mysqlPort: env["LASSO_MYSQL_PORT"].flatMap(Int.init),
            mysqlDatabase: env["LASSO_MYSQL_DATABASE"] ?? "",
            mysqlUser: env["LASSO_MYSQL_USER"],
            mysqlPassword: env["LASSO_MYSQL_PASSWORD"]
        )
    }
}

enum ServerConfigError: Error, CustomStringConvertible {
    case invalidSiteRoot(String)

    var description: String {
        switch self {
        case .invalidSiteRoot(let path): "Invalid LASSO_SITE_ROOT: \(path)"
        }
    }
}

struct LassoSiteServer: Sendable {
    let config: ServerConfig
    let includeLoader: LassoFileSystemIncludeLoader
    let inlineProvider: LassoDynamicInlineProvider?
    /// One registry for the life of this server process. Every request
    /// gets a `LassoContext` wired with this same instance, so `library()`
    /// caching and `define`d custom tags are shared across every request
    /// and every site path this instance serves — not re-parsed or
    /// re-registered per request.
    let tagRegistry = LassoTagRegistry()

    init(config: ServerConfig) throws {
        self.config = config
        includeLoader = try LassoFileSystemIncludeLoader(root: config.siteRoot)

        if let alias = config.datasourceAlias, config.mysqlDatabase.isEmpty == false {
            let executor = PerfectCRUDLassoExecutor { datasource, query in
                guard datasource == config.mysqlDatabase else {
                    throw LassoSiteServerError.unknownDatasource(datasource)
                }
                let database = try Database(configuration: MySQLDatabaseConfiguration(
                    database: config.mysqlDatabase,
                    host: config.mysqlHost,
                    port: config.mysqlPort,
                    username: config.mysqlUser,
                    password: config.mysqlPassword
                ))
                return try database.select(query)
            }
            inlineProvider = LassoDynamicInlineProvider(
                executor: executor,
                datasourceAliases: [alias: config.mysqlDatabase]
            )
        } else {
            inlineProvider = nil
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
                return try render(fileURL: fileURL, request: request, includePath: path, postBody: postBody)
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
        case .multiPartForm, .none:
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
    ) throws -> HTTPOutput {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let document = LassoParser().parse(source)
        // Kept as a local so its collected status/redirect/headers/cookies
        // can be read back after rendering — context.responseSink alone
        // wouldn't let us do that once context goes out of scope, and
        // previously nothing did, which is why redirect_url/response_status/
        // cookie_set never actually affected the HTTP response despite
        // correctly mutating this same (reference-type) sink instance.
        let sink = ServerResponseSink()
        var context = LassoContext(
            globals: baseGlobals(for: request),
            includeLoader: includeLoader,
            includePath: includePath,
            requestProvider: ServerRequestProvider(request: request, postBody: postBody),
            responseSink: sink,
            inlineProvider: inlineProvider,
            tagRegistry: tagRegistry
        )
        let html: String
        do {
            html = try LassoRenderer().render(document, context: &context)
        } catch {
            throw LassoSiteRenderError(
                underlying: error,
                includeStack: context.includeStack,
                parserDiagnostics: document.diagnostics.map(\.message)
            )
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

/// A request's POST body, already read and parsed asynchronously at the
/// Perfect route-handler boundary (see `LassoSiteServer.readPostBody`)
/// before the synchronous `LassoRenderer`/`Evaluator` ever runs — keeps
/// async I/O out of the renderer entirely, per
/// `Documentation/post-body-support-plan.md`'s recommended architecture.
struct ParsedPostBody {
    let pairs: [LassoRequestPair]
    let rawString: String

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

final class ServerResponseSink: LassoResponseSink, @unchecked Sendable {
    private(set) var status: Int = 200
    private(set) var redirectURL: String?
    private(set) var headerPairs: [(name: String, value: String)] = []
    private(set) var cookieHeaderValues: [String] = []

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

let config = try ServerConfig.load()
let siteServer = try LassoSiteServer(config: config)
print("Lasso Perfect test server")
print("Site root: \(config.siteRoot.path)")
if let startupPath = config.startupPath {
    let result = loadLassoStartupDirectory(
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
if let alias = config.datasourceAlias {
    print("Datasource alias: \(alias) -> \(config.mysqlDatabase)@\(config.mysqlHost)")
} else {
    print("Datasource alias: none")
}
try await Server(routes: try siteServer.routes(), port: config.port).run()

import Foundation

/// One page's crawl result. `errorType`/`errorDescription` come from the
/// server's own JSON error format (`developerErrorOutput`'s
/// `Accept: application/json` branch) — read structurally, not scraped
/// from the HTML error page meant for a developer's browser.
struct CrawlPageResult: Sendable {
    let path: String
    let statusCode: Int
    let errorType: String?
    let errorDescription: String?

    // A redirect is a real, intentional Lasso outcome (e.g. the bot-exclusion
    // flow) — not a bug needing engineering attention — so it counts as
    // clean alongside a normal 2xx render. Only 4xx/5xx/request-failure
    // count as an unsupported-construct failure.
    var isClean: Bool { (200 ..< 400).contains(statusCode) }
}

/// Requests every discovered site page over real HTTP and groups results by
/// first unsupported construct — replaces the manual `curl`-in-a-loop sweep
/// used throughout this project's development sessions with a repeatable,
/// built-in tool. See `Documentation/lasso-perfect-server.md`'s "Next
/// Compatibility Work".
enum CrawlReport {
    /// Real pages are always requested by an ordinary GET, matching how a
    /// browser would first load them — this crawler never submits forms
    /// or otherwise triggers writes.
    static func run(baseURL: String, siteRoot: URL, extensions: Set<String>) async -> [CrawlPageResult] {
        let paths = discoverPaths(siteRoot: siteRoot, extensions: extensions)
        var results: [CrawlPageResult] = []
        for path in paths.sorted() {
            results.append(await requestPage(baseURL: baseURL, path: path))
        }
        return results
    }

    /// Recursively walks `siteRoot` for renderable pages, skipping
    /// underscore-prefixed files — the site's own "include-only, never
    /// request directly" convention (matching every real corpus sweep run
    /// manually this project's development sessions) — and any path
    /// component starting with `.` (hidden files/directories).
    private static func discoverPaths(siteRoot: URL, extensions: Set<String>) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: siteRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard url.lastPathComponent.hasPrefix("_") == false else { continue }
            let relativePath = String(url.path.dropFirst(siteRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            paths.append(relativePath)
        }
        return paths
    }

    private static func requestPage(baseURL: String, path: String) async -> CrawlPageResult {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/\(encodedPath)") else {
            return CrawlPageResult(path: path, statusCode: 0, errorType: "invalidPath", errorDescription: nil)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            // Don't follow redirects — a page that legitimately redirects
            // (e.g. the bot-exclusion flow) should be recorded as exactly
            // that, not chased into a different page's result or a loop
            // ("too many HTTP redirects" for any page that ever redirects
            // back toward itself, since the crawler isn't a real browser
            // carrying cookies/session state between hops).
            let (data, response) = try await noRedirectSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode >= 400 else {
                return CrawlPageResult(path: path, statusCode: statusCode, errorType: nil, errorDescription: nil)
            }
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            return CrawlPageResult(
                path: path,
                statusCode: statusCode,
                errorType: payload?["errorType"] ?? "unknown",
                errorDescription: payload?["errorDescription"]
            )
        } catch {
            return CrawlPageResult(path: path, statusCode: 0, errorType: "requestFailed", errorDescription: "\(error)")
        }
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let noRedirectSession = URLSession(
        configuration: .ephemeral,
        delegate: NoRedirectDelegate(),
        delegateQueue: nil
    )

    /// Groups failures by `errorType` (matching `LassoSubsetCrawler`'s
    /// existing counted-and-grouped report style), prints a summary to
    /// stdout, and — if `outputPath` is set — writes the full per-page
    /// results as JSON for diffing between runs.
    static func printAndWrite(_ results: [CrawlPageResult], outputPath: String?) {
        let clean = results.filter(\.isClean)
        let failing = results.filter { $0.isClean == false }

        print("")
        print("=== Crawl Report ===")
        print("\(clean.count) of \(results.count) pages render cleanly.")

        if failing.isEmpty == false {
            // Group by the actual construct (`errorDescription`, e.g.
            // `unknownFunction("Output")`), not `errorType` — the latter is
            // just the broad Swift error enum name (`LassoRuntimeError`
            // covers unknownFunction/unsupportedExpression/etc. alike) and
            // would lump dozens of genuinely distinct gaps into one bucket.
            var byConstruct: [String: [CrawlPageResult]] = [:]
            for result in failing {
                let key = result.errorDescription?.isEmpty == false ? result.errorDescription! : (result.errorType ?? "unknown")
                byConstruct[key, default: []].append(result)
            }
            print("")
            print("Failures by first unsupported construct:")
            for (construct, group) in byConstruct.sorted(by: { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }) {
                print("  \(construct.prefix(160)) — \(group.count) page\(group.count == 1 ? "" : "s")")
                for page in group.prefix(5) {
                    print("    \(page.path)")
                }
                if group.count > 5 {
                    print("    ... and \(group.count - 5) more")
                }
            }
        }
        print("")

        guard let outputPath else { return }
        let records = results.map { result in
            [
                "path": result.path,
                "statusCode": String(result.statusCode),
                "errorType": result.errorType ?? "",
                "errorDescription": result.errorDescription ?? "",
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
            print("Full per-page results written to \(outputPath)")
        }
    }
}

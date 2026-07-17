import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One page's crawl result. `errorType`/`errorDescription` come from the
/// server's own JSON error format (`developerErrorOutput`'s
/// `Accept: application/json` branch) — read structurally, not scraped
/// from the HTML error page meant for a developer's browser.
///
/// Lives in its own library target (not inside `LassoPerfectServer`, which
/// is a genuine top-level-executing `main.swift`, not `@main`-based) so a
/// test target can `import LassoCrawlReport` without any risk of executing
/// server-startup code as a side effect of the import.
public struct CrawlPageResult: Sendable, Equatable {
    public let path: String
    public let statusCode: Int
    public let errorType: String?
    public let errorDescription: String?
    public let elapsedMS: Int

    public init(path: String, statusCode: Int, errorType: String?, errorDescription: String?, elapsedMS: Int) {
        self.path = path
        self.statusCode = statusCode
        self.errorType = errorType
        self.errorDescription = errorDescription
        self.elapsedMS = elapsedMS
    }

    // A redirect is a real, intentional Lasso outcome (e.g. the bot-exclusion
    // flow) — not a bug needing engineering attention — so it counts as
    // clean alongside a normal 2xx render. Only 4xx/5xx/request-failure
    // count as an unsupported-construct failure.
    public var isClean: Bool { (200 ..< 400).contains(statusCode) }
}

public struct CrawlDiffSummary: Sendable, Equatable {
    public let newlyClean: [String]
    public let newlyFailing: [String]
    public let changedBucket: [ChangedBucketEntry]
    public let onlyInBaseline: [String]
    public let onlyInCurrent: [String]

    public struct ChangedBucketEntry: Sendable, Equatable {
        public let path: String
        public let from: String
        public let to: String
    }
}

/// Requests every discovered site page over real HTTP and groups results by
/// first unsupported construct — replaces the manual `curl`-in-a-loop sweep
/// used throughout this project's development sessions with a repeatable,
/// built-in tool. See `Documentation/lasso-perfect-server.md`'s "Next
/// Compatibility Work" and `Documentation/crawl-report-filtering-plan.md`.
public enum CrawlReport {
    /// Marker list ported verbatim from `LassoSubsetCrawler.Scanner.isLassoSource`
    /// (`Sources/LassoSubsetCrawler/LassoSubsetCrawler.swift`) — that tool
    /// already solved "does this .htm/.html file actually contain Lasso" for
    /// its own static-analysis purposes; reusing the exact same signals here
    /// keeps both tools' definition of "real Lasso content" consistent
    /// instead of maintaining two independently-drifting marker lists.
    public static let lassoContentMarkers = [
        "<?lasso", "[inline", "[records", "[rows", "[if", "[var", "[local",
        "[include", "[define", "[protect", "[iterate", "[loop", "[while",
        "[no_square_brackets",
    ]

    /// Only meaningful for `.htm`/`.html` — `.lasso`/`.inc` files are always
    /// treated as real Lasso content regardless of this check (matching the
    /// crawl-filtering plan's stated risk: don't weaken behavior for the
    /// site's own primary extensions, only reduce noise from vendored
    /// static/demo HTML).
    public static func looksLikeLassoSource(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lassoContentMarkers.contains { lower.contains($0) }
    }

    /// Real pages are always requested by an ordinary GET, matching how a
    /// browser would first load them — this crawler never submits forms
    /// or otherwise triggers writes. `excludePaths` are case-insensitive
    /// substrings checked against each page's site-root-relative path
    /// (`LASSO_CRAWL_EXCLUDE_PATHS`, e.g. "vendor" — real corpus evidence
    /// showed 53% of all discovered pages and 32% of currently-failing
    /// pages live under a `*/vendor/*` path serving third-party JS/CSS demo
    /// content, not real Lasso). `pathList`, when provided, is used instead
    /// of the filesystem walk entirely (`LASSO_CRAWL_PATH_LIST`/focused
    /// reruns) — `excludePaths`/content-sniffing don't apply to an
    /// explicitly supplied list, since the caller already chose exactly
    /// what to crawl.
    /// `onProgress`, when supplied, is called synchronously after each page
    /// finishes (`completed`, `total`) — the admin console's crawl-report
    /// action uses this to show live "N/M pages" status on its action chip
    /// while a crawl runs (see `LassoPerfectServer`'s `CrawlRunTracker`).
    /// `nil` by default so every other caller (CLI mode, tests) is unaffected.
    public static func run(
        baseURL: String,
        siteRoot: URL,
        extensions: Set<String>,
        excludePaths: [String] = [],
        pathList: [String]? = nil,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> (results: [CrawlPageResult], excludedCount: Int) {
        let paths: [String]
        let excludedCount: Int
        if let pathList {
            paths = pathList
            excludedCount = 0
        } else {
            let discovered = discoverPaths(siteRoot: siteRoot, extensions: extensions, excludePaths: excludePaths)
            paths = discovered.paths
            excludedCount = discovered.excludedCount
        }

        let sortedPaths = paths.sorted()
        var results: [CrawlPageResult] = []
        results.reserveCapacity(sortedPaths.count)
        for path in sortedPaths {
            results.append(await requestPage(baseURL: baseURL, path: path))
            onProgress?(results.count, sortedPaths.count)
        }
        return (results, excludedCount)
    }

    /// Case-insensitive substring match of `path` against any entry in
    /// `excludePaths` (e.g. `"vendor"` matches `assetsnew/vendor/gmaps/...`).
    /// Shared by `discoverPaths` (crawl-report discovery) and
    /// `LassoSiteServer.shouldRender` (live request serving) so both use
    /// exactly the same exclusion semantics — `LASSO_CRAWL_EXCLUDE_PATHS`
    /// and `LASSO_RENDER_EXCLUDE_PATHS` behave identically, just at
    /// different points (which pages get crawled vs. which get served as
    /// Lasso at all).
    public static func pathMatchesExclude(_ path: String, excludePaths: [String]) -> Bool {
        guard excludePaths.isEmpty == false else { return false }
        let lowercasedPath = path.lowercased()
        return excludePaths.contains { lowercasedPath.contains($0.lowercased()) }
    }

    /// Recursively walks `siteRoot` for renderable pages, skipping
    /// underscore-prefixed files — the site's own "include-only, never
    /// request directly" convention (matching every real corpus sweep run
    /// manually this project's development sessions) — any path component
    /// starting with `.` (hidden files/directories), any path matching
    /// `excludePaths`, and any `.htm`/`.html` file with no real Lasso
    /// content signal (`looksLikeLassoSource`). `public` (not `private`)
    /// specifically so tests can exercise real filesystem discovery against
    /// a temp directory without needing a live HTTP server.
    public static func discoverPaths(
        siteRoot: URL,
        extensions: Set<String>,
        excludePaths: [String]
    ) -> (paths: [String], excludedCount: Int) {
        // The path-relative `enumerator(atPath:)` overload (not
        // `enumerator(at: URL, ...)`) returns paths already relative to
        // `siteRoot` — deliberately avoiding absolute-path arithmetic
        // entirely. The URL-based enumerator resolves symlinks in the
        // paths it hands back (notably macOS's /var -> /private/var
        // firmlink, which `resolvingSymlinksInPath()` doesn't reliably
        // normalize either), which silently mis-sized a manual
        // `dropFirst(siteRoot.path.count)` prefix strip — found writing a
        // temp-directory unit test for this function, where
        // `FileManager.default.temporaryDirectory` returns an un-resolved
        // `/var/...` path but the enumerator's URLs came back as
        // `/private/var/...`.
        guard let enumerator = FileManager.default.enumerator(atPath: siteRoot.path) else {
            return ([], 0)
        }

        var paths: [String] = []
        var excludedCount = 0
        for case let relativePath as String in enumerator {
            // enumerator(atPath:) has no `.skipsHiddenFiles` option (that's
            // only on the URL-based overload) — filter manually.
            guard relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) == false else { continue }
            let url = siteRoot.appendingPathComponent(relativePath)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let fileExtension = url.pathExtension.lowercased()
            guard extensions.contains(fileExtension) else { continue }
            guard url.lastPathComponent.hasPrefix("_") == false else { continue }

            if pathMatchesExclude(relativePath, excludePaths: excludePaths) {
                excludedCount += 1
                continue
            }
            if fileExtension == "htm" || fileExtension == "html" {
                guard let text = try? String(contentsOf: url, encoding: .utf8), looksLikeLassoSource(text) else {
                    excludedCount += 1
                    continue
                }
            }
            paths.append(relativePath)
        }
        return (paths, excludedCount)
    }

    /// Loads a newline-delimited list of site-root-relative paths —
    /// `LASSO_CRAWL_PATH_LIST`. Blank lines and `#`-prefixed comment lines
    /// are skipped so a hand-edited list stays readable.
    public static func loadPathList(_ filePath: String) -> [String]? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.hasPrefix("#") == false }
        return lines
    }

    /// Loads a previous run's own JSON output (the exact shape
    /// `printAndWrite` writes) as a baseline — reused both for
    /// `LASSO_CRAWL_ONLY_FAILURE` focused reruns and the diff mode below,
    /// rather than inventing a second file format for either.
    public static func loadBaseline(_ filePath: String) -> [CrawlPageResult]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return nil
        }
        return records.compactMap { record in
            guard let path = record["path"], let statusCode = Int(record["statusCode"] ?? "") else { return nil }
            return CrawlPageResult(
                path: path,
                statusCode: statusCode,
                errorType: record["errorType"].flatMap { $0.isEmpty ? nil : $0 },
                errorDescription: record["errorDescription"].flatMap { $0.isEmpty ? nil : $0 },
                elapsedMS: Int(record["elapsedMS"] ?? "") ?? 0
            )
        }
    }

    /// The site-root-relative paths of every currently-failing page in
    /// `baseline` whose `errorDescription` contains `substring` (case-
    /// insensitive) — `LASSO_CRAWL_ONLY_FAILURE`, used together with
    /// `LASSO_CRAWL_BASELINE` to re-crawl just one failure bucket instead
    /// of the full site.
    public static func pathsMatchingFailure(_ baseline: [CrawlPageResult], substring: String) -> [String] {
        let needle = substring.lowercased()
        return baseline
            .filter { $0.isClean == false && ($0.errorDescription ?? "").lowercased().contains(needle) }
            .map(\.path)
    }

    /// Compares two crawl results (typically a before/after pair around a
    /// fix) and summarizes what changed — replaces the ad hoc
    /// `python3 -c "..."` JSON diffing this project's own development
    /// sessions have repeated after every fix pass. Only pages present in
    /// both are compared for clean/failing/bucket changes; pages unique to
    /// either side are reported separately (a path-list/exclude change
    /// between runs, not a render-outcome change).
    public static func diff(baseline: [CrawlPageResult], current: [CrawlPageResult]) -> CrawlDiffSummary {
        let baselineByPath = Dictionary(baseline.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let currentByPath = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var newlyClean: [String] = []
        var newlyFailing: [String] = []
        var changedBucket: [CrawlDiffSummary.ChangedBucketEntry] = []

        for path in Set(baselineByPath.keys).intersection(currentByPath.keys) {
            guard let before = baselineByPath[path], let after = currentByPath[path] else { continue }
            if before.isClean == false, after.isClean {
                newlyClean.append(path)
            } else if before.isClean, after.isClean == false {
                newlyFailing.append(path)
            } else if before.isClean == false, after.isClean == false,
                      before.errorDescription != after.errorDescription {
                changedBucket.append(.init(path: path, from: before.errorDescription ?? "unknown", to: after.errorDescription ?? "unknown"))
            }
        }

        return CrawlDiffSummary(
            newlyClean: newlyClean.sorted(),
            newlyFailing: newlyFailing.sorted(),
            changedBucket: changedBucket.sorted { $0.path < $1.path },
            onlyInBaseline: Set(baselineByPath.keys).subtracting(currentByPath.keys).sorted(),
            onlyInCurrent: Set(currentByPath.keys).subtracting(baselineByPath.keys).sorted()
        )
    }

    public static func printDiff(_ summary: CrawlDiffSummary) {
        print("")
        print("=== Crawl Diff ===")
        print("Newly clean: \(summary.newlyClean.count)")
        for path in summary.newlyClean.prefix(20) { print("  \(path)") }
        print("Newly failing: \(summary.newlyFailing.count)")
        for path in summary.newlyFailing.prefix(20) { print("  \(path)") }
        print("Changed failure bucket: \(summary.changedBucket.count)")
        for change in summary.changedBucket.prefix(20) {
            print("  \(change.path): \(change.from) -> \(change.to)")
        }
        if summary.onlyInBaseline.isEmpty == false {
            print("Only in baseline (not re-crawled): \(summary.onlyInBaseline.count)")
        }
        if summary.onlyInCurrent.isEmpty == false {
            print("Only in current (new since baseline): \(summary.onlyInCurrent.count)")
        }
        print("")
    }

    private static func requestPage(baseURL: String, path: String) async -> CrawlPageResult {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/\(encodedPath)") else {
            return CrawlPageResult(path: path, statusCode: 0, errorType: "invalidPath", errorDescription: nil, elapsedMS: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let start = Date()
        func elapsedMS() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

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
                return CrawlPageResult(path: path, statusCode: statusCode, errorType: nil, errorDescription: nil, elapsedMS: elapsedMS())
            }
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            return CrawlPageResult(
                path: path,
                statusCode: statusCode,
                errorType: payload?["errorType"] ?? "unknown",
                errorDescription: payload?["errorDescription"],
                elapsedMS: elapsedMS()
            )
        } catch {
            return CrawlPageResult(path: path, statusCode: 0, errorType: "requestFailed", errorDescription: "\(error)", elapsedMS: elapsedMS())
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
    public static func printAndWrite(_ results: [CrawlPageResult], outputPath: String?, excludedCount: Int = 0) {
        let clean = results.filter(\.isClean)
        let failing = results.filter { $0.isClean == false }

        print("")
        print("=== Crawl Report ===")
        print("\(clean.count) of \(results.count) pages render cleanly.")
        if excludedCount > 0 {
            print("\(excludedCount) additional pages excluded (path exclude or no Lasso content signal) — not counted above.")
        }

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
                "elapsedMS": String(result.elapsedMS),
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
            print("Full per-page results written to \(outputPath)")
        }
    }
}

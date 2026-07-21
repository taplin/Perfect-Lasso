import Foundation
import Testing
@testable import LassoCrawlReport

private func makeTempSiteRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ text: String, to root: URL, relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Test func looksLikeLassoSourceRecognizesEveryPortedMarker() throws {
    #expect(CrawlReport.looksLikeLassoSource("<html><?lasso 'x' ?></html>"))
    #expect(CrawlReport.looksLikeLassoSource("[inline(-search)]"))
    #expect(CrawlReport.looksLikeLassoSource("[Records][/Records]"))
    #expect(CrawlReport.looksLikeLassoSource("<html><body>Static page, no Lasso here.</body></html>") == false)
}

@Test func discoverPathsSkipsUnderscorePrefixedAndHiddenFiles() throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("hello", to: root, relativePath: "page.lasso")
    try write("include-only", to: root, relativePath: "_header.lasso")
    try write("hidden", to: root, relativePath: ".hidden/page.lasso")

    let (paths, excludedCount) = CrawlReport.discoverPaths(
        siteRoot: root,
        extensions: ["lasso"],
        excludePaths: []
    )
    #expect(paths == ["page.lasso"])
    #expect(excludedCount == 0)
}

@Test func discoverPathsAppliesCaseInsensitivePathExcludes() throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("real page", to: root, relativePath: "pages/home.lasso")
    try write("vendor demo", to: root, relativePath: "assets/Vendor/gmaps/demo.lasso")

    let (paths, excludedCount) = CrawlReport.discoverPaths(
        siteRoot: root,
        extensions: ["lasso"],
        excludePaths: ["vendor"]
    )
    #expect(paths == ["pages/home.lasso"])
    #expect(excludedCount == 1)
}

// MARK: - pathMatchesExclude (shared by discoverPaths and LassoSiteServer.shouldRender)

@Test func pathMatchesExcludeIsCaseInsensitive() {
    #expect(CrawlReport.pathMatchesExclude("assets/Vendor/gmaps/demo.html", excludePaths: ["vendor"]))
    #expect(CrawlReport.pathMatchesExclude("assets/VENDOR/gmaps/demo.html", excludePaths: ["Vendor"]))
}

@Test func pathMatchesExcludeMatchesAnySubstringInTheList() {
    #expect(CrawlReport.pathMatchesExclude("pages/legacy/old.lasso", excludePaths: ["vendor", "legacy"]))
    #expect(CrawlReport.pathMatchesExclude("pages/home.lasso", excludePaths: ["vendor", "legacy"]) == false)
}

@Test func pathMatchesExcludeReturnsFalseWithNoExcludesConfigured() {
    #expect(CrawlReport.pathMatchesExclude("assets/vendor/gmaps/demo.html", excludePaths: []) == false)
}

// MARK: - candidateIsEligible (shared by discoverPaths and Sitemap-derived
// paths — see CrawlReport.swift's own doc comment on why this was
// extracted rather than reimplemented a second time for sitemap discovery)

@Test func candidateIsEligibleAcceptsAMatchingExtensionWithNoExcludes() {
    #expect(CrawlReport.candidateIsEligible(relativePath: "pages/home.lasso", extensions: ["lasso"], excludePaths: []))
}

@Test func candidateIsEligibleRejectsNonMatchingExtension() {
    #expect(CrawlReport.candidateIsEligible(relativePath: "image.jpg", extensions: ["lasso"], excludePaths: []) == false)
}

@Test func candidateIsEligibleRejectsUnderscorePrefixedFiles() {
    #expect(CrawlReport.candidateIsEligible(relativePath: "_header.lasso", extensions: ["lasso"], excludePaths: []) == false)
}

@Test func candidateIsEligibleRejectsHiddenSegments() {
    #expect(CrawlReport.candidateIsEligible(relativePath: ".hidden/page.lasso", extensions: ["lasso"], excludePaths: []) == false)
}

@Test func candidateIsEligibleRejectsExcludedPaths() {
    #expect(CrawlReport.candidateIsEligible(relativePath: "assets/vendor/demo.lasso", extensions: ["lasso"], excludePaths: ["vendor"]) == false)
}

@Test func candidateIsEligibleAppliesEveryCheckToThePathPortionOnlyIgnoringAnyQueryString() {
    // Sitemap-derived paths are exactly the query-parameterized case this
    // feature exists for — every check must look at the path portion only.
    #expect(CrawlReport.candidateIsEligible(relativePath: "product.lasso?id=42", extensions: ["lasso"], excludePaths: []))
    #expect(CrawlReport.candidateIsEligible(relativePath: "_header.lasso?x=1", extensions: ["lasso"], excludePaths: []) == false)
    #expect(CrawlReport.candidateIsEligible(relativePath: "assets/vendor/demo.lasso?x=1", extensions: ["lasso"], excludePaths: ["vendor"]) == false)
    #expect(CrawlReport.candidateIsEligible(relativePath: "page.html?x=1", extensions: ["lasso"], excludePaths: []) == false)
}

// MARK: - encodedRequestPath (the requestPage query-encoding fix)

@Test func encodedRequestPathWithNoQueryMatchesThePriorWholeStringEncodingExactly() {
    // Regression: every caller before this feature never had a query
    // string — this must produce byte-for-byte the same result as the
    // single `.urlPathAllowed`-encoding call this replaced.
    for raw in ["pages/home.lasso", "Caf\u{E9} menu/index.lasso", "a/b/c.inc"] {
        #expect(CrawlReport.encodedRequestPath(raw) == raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
    }
}

@Test func encodedRequestPathSplitsPathAndQueryWithTheCorrectAllowedCharacterSets() throws {
    let raw = "product.lasso?id=42&name=A B"
    let encoded = try #require(CrawlReport.encodedRequestPath(raw))
    let url = try #require(URL(string: "http://example.com/\(encoded)"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/product.lasso")
    #expect(components.percentEncodedQuery?.removingPercentEncoding == "id=42&name=A B")
}

@Test func discoverPathsSkipsStaticHTMLButKeepsLassoBearingHTML() throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("<html><?lasso 'x' ?></html>", to: root, relativePath: "layout.html")
    try write("<html><body>Static demo page</body></html>", to: root, relativePath: "vendor-ish/demo.html")
    try write("[inline(-search)][/inline]", to: root, relativePath: "search.htm")

    let (paths, excludedCount) = CrawlReport.discoverPaths(
        siteRoot: root,
        extensions: ["html", "htm"],
        excludePaths: []
    )
    #expect(Set(paths) == ["layout.html", "search.htm"])
    #expect(excludedCount == 1)
}

@Test func discoverPathsNeverContentSniffsLassoOrIncExtensions() throws {
    // .lasso/.inc must behave exactly as before this pass regardless of
    // content — the content heuristic only applies to .htm/.html.
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("plain text, no Lasso markers at all", to: root, relativePath: "odd.lasso")

    let (paths, excludedCount) = CrawlReport.discoverPaths(
        siteRoot: root,
        extensions: ["lasso"],
        excludePaths: []
    )
    #expect(paths == ["odd.lasso"])
    #expect(excludedCount == 0)
}

@Test func loadPathListSkipsBlankLinesAndComments() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try """
    pages/a.lasso

    # a comment
    pages/b.lasso
    """.write(to: file, atomically: true, encoding: .utf8)

    let list = CrawlReport.loadPathList(file.path)
    #expect(list == ["pages/a.lasso", "pages/b.lasso"])
}

@Test func loadPathListReturnsNilForMissingFile() throws {
    #expect(CrawlReport.loadPathList("/nonexistent/\(UUID().uuidString)") == nil)
}

private func writeBaseline(_ records: [[String: String]]) throws -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    let data = try JSONSerialization.data(withJSONObject: records)
    try data.write(to: file)
    return file
}

@Test func loadBaselineRoundTripsPrintAndWritesOwnFormat() throws {
    let file = try writeBaseline([
        ["path": "a.lasso", "statusCode": "200", "errorType": "", "errorDescription": "", "elapsedMS": "12"],
        ["path": "b.lasso", "statusCode": "500", "errorType": "LassoRuntimeError", "errorDescription": "unknownFunction(\"X\")", "elapsedMS": "5"],
    ])
    defer { try? FileManager.default.removeItem(at: file) }

    let loaded = try #require(CrawlReport.loadBaseline(file.path))
    #expect(loaded.count == 2)
    // Neither record has a `"source"` key (an old-format baseline, written
    // before this feature existed) — both must still load, defaulting to
    // `.filesystem`. `CrawlPageResult`'s `Equatable` conformance covers
    // `source` too, so this literal (built with its default `.filesystem`)
    // only matches if the old-format fallback actually fired.
    #expect(loaded[0] == CrawlPageResult(path: "a.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 12))
    #expect(loaded[0].source == .filesystem)
    #expect(loaded[1].errorDescription == "unknownFunction(\"X\")")
    #expect(loaded[1].isClean == false)
}

@Test func loadBaselineParsesAnExplicitSourceFieldFromANewFormatBaseline() throws {
    let file = try writeBaseline([
        ["path": "b.lasso", "statusCode": "200", "errorType": "", "errorDescription": "", "elapsedMS": "3", "source": "sitemapOnly"],
        ["path": "a.lasso", "statusCode": "200", "errorType": "", "errorDescription": "", "elapsedMS": "3", "source": "filesystem"],
    ])
    defer { try? FileManager.default.removeItem(at: file) }

    let loaded = try #require(CrawlReport.loadBaseline(file.path))
    #expect(loaded.first { $0.path == "b.lasso" }?.source == .sitemapOnly)
    #expect(loaded.first { $0.path == "a.lasso" }?.source == .filesystem)
}

@Test func pathsMatchingFailureFiltersCaseInsensitivelyAndOnlyFailingPages() throws {
    let baseline = [
        CrawlPageResult(path: "a.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0),
        CrawlPageResult(path: "b.lasso", statusCode: 500, errorType: "x", errorDescription: "unknownFunction(\"Date_Format\")", elapsedMS: 0),
        CrawlPageResult(path: "c.lasso", statusCode: 500, errorType: "x", errorDescription: "unknownFunction(\"Select\")", elapsedMS: 0),
    ]
    #expect(CrawlReport.pathsMatchingFailure(baseline, substring: "date_format") == ["b.lasso"])
    #expect(CrawlReport.pathsMatchingFailure(baseline, substring: "nope").isEmpty)
}

@Test func diffReportsNewlyCleanNewlyFailingAndChangedBucketsOnly() throws {
    let baseline = [
        CrawlPageResult(path: "fixed.lasso", statusCode: 500, errorType: "x", errorDescription: "unknownFunction(\"inline\")", elapsedMS: 0),
        CrawlPageResult(path: "broke.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0),
        CrawlPageResult(path: "movedBucket.lasso", statusCode: 500, errorType: "x", errorDescription: "unknownFunction(\"inline\")", elapsedMS: 0),
        CrawlPageResult(path: "unchanged.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0),
        CrawlPageResult(path: "removedPage.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0),
    ]
    let current = [
        CrawlPageResult(path: "fixed.lasso", statusCode: 500, errorType: "x", errorDescription: "inlineNotConfigured", elapsedMS: 0),
        CrawlPageResult(path: "broke.lasso", statusCode: 500, errorType: "x", errorDescription: "unknownFunction(\"newGap\")", elapsedMS: 0),
        CrawlPageResult(path: "movedBucket.lasso", statusCode: 500, errorType: "x", errorDescription: "inlineNotConfigured", elapsedMS: 0),
        CrawlPageResult(path: "unchanged.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0),
        CrawlPageResult(path: "newPage.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0),
    ]

    let summary = CrawlReport.diff(baseline: baseline, current: current)
    #expect(summary.newlyFailing == ["broke.lasso"])
    #expect(summary.newlyClean.isEmpty)
    #expect(summary.changedBucket.map(\.path) == ["fixed.lasso", "movedBucket.lasso"])
    #expect(summary.changedBucket.first { $0.path == "fixed.lasso" }?.from == "unknownFunction(\"inline\")")
    #expect(summary.changedBucket.first { $0.path == "fixed.lasso" }?.to == "inlineNotConfigured")
    #expect(summary.onlyInBaseline == ["removedPage.lasso"])
    #expect(summary.onlyInCurrent == ["newPage.lasso"])
}

// MARK: - isBackendDistressSignal (circuit breaker's core predicate)

@Test func isBackendDistressSignalTreatsOnlyRequestFailuresAsDistress() {
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 0, errorType: "requestFailed", errorDescription: nil, elapsedMS: 0)
    ))
}

@Test func isBackendDistressSignalDoesNotTreatAnyHTTPStatusAsDistress() {
    // Not just 4xx (an unsupported construct on one page, the normal,
    // expected output of a crawl) — also 5xx. lasso-perfect-server's own
    // render-error page returns 500 uniformly for *every* kind of Lasso
    // error, ordinary already-cataloged interpreter gaps included, so a
    // 500 here is completely indistinguishable from a real backend
    // failure at the status-code level alone — treating it as distress
    // tripped the breaker on ordinary crawl output in practice
    // (live-confirmed 2026-07-17).
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 404, errorType: "x", errorDescription: nil, elapsedMS: 0)
    ) == false)
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 500, errorType: "x", errorDescription: "unknownFunction(\"inline\")", elapsedMS: 0)
    ) == false)
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 502, errorType: "x", errorDescription: nil, elapsedMS: 0)
    ) == false)
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0)
    ) == false)
}

// MARK: - run(...) pacing + circuit breaker (URLProtocol-mocked, no live server)

private final class CrawlMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCodesByPath: [String: Int] = [:]
    // Paths that simulate a genuine request-level failure (timeout,
    // connection lost) rather than any HTTP response at all — the only
    // real distress signal `isBackendDistressSignal` recognizes.
    nonisolated(unsafe) static var failingPaths: Set<String> = []
    nonisolated(unsafe) static var requestedPaths: [String] = []
    // Per-path response bodies — defaults to the existing hardcoded `"{}"`
    // (an ordinary crawled page's JSON error payload shape) when unset, so
    // every pre-existing test using this mock is unaffected. Sitemap-merge
    // tests below set this to real sitemap XML for `"sitemap.xml"`, since
    // `Sitemap.discoverPaths` needs actual XML bytes, not `"{}"`.
    nonisolated(unsafe) static var bodiesByPath: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        Self.requestedPaths.append(path)
        if Self.failingPaths.contains(path) {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let statusCode = Self.statusCodesByPath[path] ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bodiesByPath[path] ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CrawlMockURLProtocol.self]
    return URLSession(configuration: config)
}

// `CrawlMockURLProtocol`'s status-code table and requested-path log are
// shared mutable static state — `.serialized` avoids the exact cross-test
// race Perfect-FileMaker's own MockURLProtocol-based suite guards against
// the same way (parallel tests stomping each other's mock configuration
// mid-run, e.g. one test's "d.lasso" status code bleeding into another's).
@Suite(.serialized)
struct CrawlReportRunTests {

@Test func runAbortsEarlyWhenConsecutiveRequestFailuresReachTheThreshold() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c", "d", "e", "f"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 200, "b.lasso": 200, "f.lasso": 200]
    // Three consecutive genuine request-level failures starting at "c" —
    // matching the actual observed live signal (timeouts), not just any
    // 5xx status (see isBackendDistressSignal's own doc comment for why
    // that distinction matters).
    CrawlMockURLProtocol.failingPaths = ["c.lasso", "d.lasso", "e.lasso"]
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    let (results, _, abortedByCircuitBreaker, _) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        circuitBreakerThreshold: 3,
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker)
    // Stops right after the 3rd consecutive failure (c, d, e) — "f" is
    // never reached.
    #expect(results.map(\.path) == ["a.lasso", "b.lasso", "c.lasso", "d.lasso", "e.lasso"])
    #expect(CrawlMockURLProtocol.requestedPaths.contains("f.lasso") == false)
}

@Test func runDoesNotAbortWhenRequestFailuresAreNotConsecutive() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c", "d"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    // An isolated request failure between two clean pages resets the
    // consecutive-failure count — a one-off hiccup shouldn't trip the
    // breaker the same way a sustained run of failures does.
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 200, "c.lasso": 200]
    CrawlMockURLProtocol.failingPaths = ["b.lasso", "d.lasso"]
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    let (results, _, abortedByCircuitBreaker, _) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        circuitBreakerThreshold: 2,
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker == false)
    #expect(results.count == 4)
}

@Test func runOrdinaryPageErrorsIncludingServerErrorsNeverTripTheCircuitBreaker() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c", "d"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    // A mix of 404s and 500s — ordinary Lasso render errors, exactly the
    // kind a crawl exists to find — should never trip the breaker no
    // matter how many appear consecutively, since this server's own
    // render-error page returns 500 uniformly for every kind of error
    // (ordinary interpreter gaps included), making status code alone
    // useless as a backend-health signal here.
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 404, "b.lasso": 500, "c.lasso": 500, "d.lasso": 404]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    let (results, _, abortedByCircuitBreaker, _) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        circuitBreakerThreshold: 2,
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker == false)
    #expect(results.count == 4)
}

@Test func runWithNoCircuitBreakerThresholdNeverAborts() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.failingPaths = ["a.lasso", "b.lasso", "c.lasso"]
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    let (results, _, abortedByCircuitBreaker, _) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        circuitBreakerThreshold: nil,
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker == false)
    #expect(results.count == 3)
}

@Test func runPacesRequestsByTheConfiguredDelay() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 200, "b.lasso": 200, "c.lasso": 200]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    let start = Date()
    _ = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        requestDelayMS: 100,
        urlSession: mockSession()
    )
    let elapsed = Date().timeIntervalSince(start)

    // 3 requests -> 2 gaps of >= 100ms each; generous lower bound (150ms)
    // to absorb scheduling jitter without the test being flaky, while
    // still clearly distinguishing "paced" from "no delay at all".
    #expect(elapsed >= 0.15)
}

@Test func runWithNoDelayConfiguredDoesNotPace() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 200, "b.lasso": 200, "c.lasso": 200]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    let start = Date()
    _ = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        requestDelayMS: 0,
        urlSession: mockSession()
    )
    let elapsed = Date().timeIntervalSince(start)

    #expect(elapsed < 0.15)
}

@Test func runAbortsWhenTheDatasourceFailureCounterCrossesItsThreshold() async throws {
    // Real corpus symptom (2026-07-17): a FileMaker Server connectivity
    // failure gets caught and converted into a recoverable Lasso error
    // frame, so the page still returns a normal 200 — every one of these
    // mocked pages is a clean 200, exactly matching what the crawler
    // actually saw live while FileMaker Server was demonstrably failing
    // most of its requests. This signal has to come from somewhere other
    // than the page's own HTTP response.
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c", "d", "e"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.statusCodesByPath = [
        "a.lasso": 200, "b.lasso": 200, "c.lasso": 200, "d.lasso": 200, "e.lasso": 200,
    ]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    final class CounterBox: @unchecked Sendable {
        var count = 0
    }
    let box = CounterBox()

    let (results, _, abortedByCircuitBreaker, _) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        datasourceFailureThreshold: 3,
        currentDatasourceFailureCount: {
            // Simulates one real datasource failure per crawled page —
            // by the 3rd page the count has reached the threshold.
            box.count += 1
            return box.count
        },
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker)
    #expect(results.map(\.path) == ["a.lasso", "b.lasso", "c.lasso"])
    #expect(results.filter(\.isClean).count == results.count)
}

@Test func runWithNoDatasourceFailureThresholdIgnoresTheCounterEntirely() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 200, "b.lasso": 200]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    let (results, _, abortedByCircuitBreaker, _) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        // No datasourceFailureThreshold — the closure is still supplied,
        // but must never be consulted since the threshold is nil.
        currentDatasourceFailureCount: { 999 },
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker == false)
    #expect(results.count == 2)
}

// MARK: - run(...) sitemap-discovery merge (Sitemap.swift)

@Test func runMergesSitemapOnlyPathsWithFilesystemResultsAndTagsSourceCorrectly() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("page", to: root, relativePath: "a.lasso")

    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 200, "b.lasso": 200]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [
        "sitemap.xml": Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://origin.example/a.lasso</loc></url>
          <url><loc>https://origin.example/b.lasso?id=1</loc></url>
        </urlset>
        """.utf8),
    ]

    let (results, _, _, sitemapSummary) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        urlSession: mockSession(),
        sitemapEnabled: true,
        sitemapEntryPath: "sitemap.xml",
        sitemapAllowedOrigin: "https://origin.example"
    )

    #expect(results.map(\.path).sorted() == ["a.lasso", "b.lasso?id=1"])
    // Found by BOTH sources -> stays `.filesystem` (the pre-existing,
    // better-understood source).
    #expect(results.first { $0.path == "a.lasso" }?.source == .filesystem)
    // Found ONLY via the sitemap -> `.sitemapOnly`.
    #expect(results.first { $0.path == "b.lasso?id=1" }?.source == .sitemapOnly)
    #expect(sitemapSummary != nil)
    #expect(sitemapSummary?.sitemapURLsFetched == 2)
}

@Test func runWithSitemapDisabledNeverRequestsSitemapAndReturnsNilSummary() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("page", to: root, relativePath: "a.lasso")

    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 200]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    // sitemapEnabled defaults to false — every existing caller's behavior,
    // before this feature existed, must be completely unaffected.
    let (results, _, _, sitemapSummary) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        urlSession: mockSession()
    )

    #expect(results.map(\.path) == ["a.lasso"])
    #expect(sitemapSummary == nil)
    #expect(CrawlMockURLProtocol.requestedPaths.contains("sitemap.xml") == false)
}

@Test func runSkipsSitemapDiscoveryWhenPathListIsSupplied() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    CrawlMockURLProtocol.statusCodesByPath = ["only.lasso": 200]
    CrawlMockURLProtocol.failingPaths = []
    CrawlMockURLProtocol.requestedPaths = []
    CrawlMockURLProtocol.bodiesByPath = [:]

    // Even with sitemapEnabled true, an explicit pathList means "the
    // caller already chose exactly what to crawl" — matching pathList's
    // pre-existing contract with the filesystem walk.
    let (results, _, _, sitemapSummary) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        pathList: ["only.lasso"],
        urlSession: mockSession(),
        sitemapEnabled: true,
        sitemapAllowedOrigin: "https://origin.example"
    )

    #expect(results.map(\.path) == ["only.lasso"])
    #expect(sitemapSummary == nil)
    #expect(CrawlMockURLProtocol.requestedPaths.contains("sitemap.xml") == false)
}

}

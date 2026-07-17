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
    #expect(loaded[0] == CrawlPageResult(path: "a.lasso", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 12))
    #expect(loaded[1].errorDescription == "unknownFunction(\"X\")")
    #expect(loaded[1].isClean == false)
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

@Test func isBackendDistressSignalTreatsRequestFailuresAndServerErrorsAsDistress() {
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 0, errorType: "requestFailed", errorDescription: nil, elapsedMS: 0)
    ))
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 500, errorType: "x", errorDescription: nil, elapsedMS: 0)
    ))
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 502, errorType: "x", errorDescription: nil, elapsedMS: 0)
    ))
}

@Test func isBackendDistressSignalDoesNotTreatOrdinaryPageErrorsAsDistress() {
    // 4xx (an unsupported construct on one specific page) is the normal,
    // expected output of a crawl — it says nothing about backend health,
    // unlike a run of timeouts/5xx.
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 404, errorType: "x", errorDescription: nil, elapsedMS: 0)
    ) == false)
    #expect(CrawlReport.isBackendDistressSignal(
        CrawlPageResult(path: "a", statusCode: 200, errorType: nil, errorDescription: nil, elapsedMS: 0)
    ) == false)
}

// MARK: - run(...) pacing + circuit breaker (URLProtocol-mocked, no live server)

private final class CrawlMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCodesByPath: [String: Int] = [:]
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        Self.requestedPaths.append(path)
        let statusCode = Self.statusCodesByPath[path] ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
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

@Test func runAbortsEarlyWhenConsecutiveBackendFailuresReachTheThreshold() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c", "d", "e", "f"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.statusCodesByPath = [
        "a.lasso": 200, "b.lasso": 200,
        // Three consecutive backend-distress results starting at "c" —
        // matching the observed live symptom (timeouts/502s in a row).
        "c.lasso": 502, "d.lasso": 0, "e.lasso": 500,
        "f.lasso": 200,
    ]
    CrawlMockURLProtocol.requestedPaths = []

    let (results, _, abortedByCircuitBreaker) = await CrawlReport.run(
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

@Test func runDoesNotAbortWhenFailuresAreNotConsecutive() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c", "d"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    // A 5xx between two clean pages resets the consecutive-failure count —
    // an isolated backend hiccup shouldn't trip the breaker the same way
    // a sustained run of failures does.
    CrawlMockURLProtocol.statusCodesByPath = [
        "a.lasso": 200, "b.lasso": 500, "c.lasso": 200, "d.lasso": 500,
    ]
    CrawlMockURLProtocol.requestedPaths = []

    let (results, _, abortedByCircuitBreaker) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        circuitBreakerThreshold: 2,
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker == false)
    #expect(results.count == 4)
}

@Test func runOrdinaryPageErrorsNeverTripTheCircuitBreaker() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    // Three consecutive 404s — an unsupported-construct-style page error,
    // not backend distress — should crawl through cleanly even with an
    // aggressive threshold.
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 404, "b.lasso": 404, "c.lasso": 404]
    CrawlMockURLProtocol.requestedPaths = []

    let (results, _, abortedByCircuitBreaker) = await CrawlReport.run(
        baseURL: "http://mock.example",
        siteRoot: root,
        extensions: ["lasso"],
        circuitBreakerThreshold: 2,
        urlSession: mockSession()
    )

    #expect(abortedByCircuitBreaker == false)
    #expect(results.count == 3)
}

@Test func runWithNoCircuitBreakerThresholdNeverAborts() async throws {
    let root = try makeTempSiteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c"] {
        try write("page", to: root, relativePath: "\(name).lasso")
    }
    CrawlMockURLProtocol.statusCodesByPath = ["a.lasso": 500, "b.lasso": 500, "c.lasso": 500]
    CrawlMockURLProtocol.requestedPaths = []

    let (results, _, abortedByCircuitBreaker) = await CrawlReport.run(
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
    CrawlMockURLProtocol.requestedPaths = []

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
    CrawlMockURLProtocol.requestedPaths = []

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

}

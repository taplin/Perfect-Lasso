import Foundation
import Testing
@testable import LassoCrawlReport

// MARK: - Pure-logic tests (no networking, no mocking)

@Test func isSameOriginTreatsDefaultPortsAsEquivalent() {
    let allowed = URL(string: "https://example.com")!
    #expect(Sitemap.isSameOrigin(URL(string: "https://example.com:443/a.lasso")!, as: allowed))
    #expect(Sitemap.isSameOrigin(URL(string: "https://example.com/a.lasso")!, as: allowed))
}

@Test func isSameOriginIsCaseInsensitiveOnHost() {
    let allowed = URL(string: "https://Example.COM")!
    #expect(Sitemap.isSameOrigin(URL(string: "https://example.com/a.lasso")!, as: allowed))
    #expect(Sitemap.isSameOrigin(URL(string: "https://EXAMPLE.COM/a.lasso")!, as: allowed))
}

@Test func isSameOriginRejectsSchemeMismatch() {
    let allowed = URL(string: "https://example.com")!
    #expect(Sitemap.isSameOrigin(URL(string: "http://example.com/a.lasso")!, as: allowed) == false)
}

@Test func isSameOriginRejectsPortMismatch() {
    let allowed = URL(string: "https://example.com")!
    #expect(Sitemap.isSameOrigin(URL(string: "https://example.com:8443/a.lasso")!, as: allowed) == false)
}

@Test func isSameOriginRejectsHostMismatch() {
    let allowed = URL(string: "https://example.com")!
    #expect(Sitemap.isSameOrigin(URL(string: "https://evil.example/a.lasso")!, as: allowed) == false)
}

@Test func isSameOriginRejectsNonHTTPSchemesEvenWithMatchingHost() {
    // Not reachable through a real `<loc>` matching a real `allowedOrigin`
    // (which is itself always validated http(s) by the caller), but
    // `isSameOrigin` itself should never treat e.g. `ftp://` as acceptable
    // regardless of what's passed in.
    let allowed = URL(string: "ftp://example.com")!
    #expect(Sitemap.isSameOrigin(URL(string: "ftp://example.com/a")!, as: allowed) == false)
}

@Test func relativePathPercentDecodesPathAndQueryRoundTrip() {
    let url = URL(string: "https://example.com/products/Caf%C3%A9.lasso?name=Caf%C3%A9")!
    #expect(Sitemap.relativePath(of: url, extensions: ["lasso"]) == "products/Café.lasso?name=Café")
}

@Test func relativePathRejectsHiddenSegments() {
    let url = URL(string: "https://example.com/_internal/.hidden/page.lasso")!
    #expect(Sitemap.relativePath(of: url, extensions: ["lasso"]) == nil)
}

@Test func relativePathRejectsNonMatchingExtension() {
    let url = URL(string: "https://example.com/image.jpg")!
    #expect(Sitemap.relativePath(of: url, extensions: ["lasso", "html"]) == nil)
}

@Test func relativePathRejectsNonHTTPScheme() {
    let url = URL(string: "ftp://example.com/a.lasso")!
    #expect(Sitemap.relativePath(of: url, extensions: ["lasso"]) == nil)
}

@Test func relativePathReturnsNilForRootWithNoPath() {
    let url = URL(string: "https://example.com")!
    #expect(Sitemap.relativePath(of: url, extensions: ["lasso"]) == nil)
}

@Test func relativePathReEscapesAPathInternalPercentEncodedQuestionMark() {
    // Reproduces a real review finding: a `<loc>` whose PATH contains a
    // percent-encoded, literal `?` (`%3F`) — one path segment, no real
    // query string at all. Percent-decoding it naively (the pre-fix
    // behavior) would produce the ambiguous flat string
    // "foo.lasso?bar.lasso", indistinguishable from a real
    // path+query split by every downstream consumer. The fix re-escapes
    // that literal `?` back to `%3F` before returning, so the one true
    // separator convention downstream depends on ("the first unescaped `?`
    // is the query separator") stays true.
    let url = URL(string: "https://example.com/foo.lasso%3Fbar.lasso")!
    #expect(Sitemap.relativePath(of: url, extensions: ["lasso"]) == "foo.lasso%3Fbar.lasso")
}

@Test func relativePathDistinguishesAPathInternalPercentEncodedQuestionMarkFromARealTrailingQuery() {
    // Companion case: a percent-encoded `?` INSIDE the path AND a genuine
    // trailing real query string. The two must remain distinguishable
    // after the fix — exactly one literal (real) `?` should appear in the
    // result, separating the (re-escaped) path from the real query.
    let url = URL(string: "https://example.com/foo.lasso%3Fbar.lasso?real=1")!
    #expect(Sitemap.relativePath(of: url, extensions: ["lasso"]) == "foo.lasso%3Fbar.lasso?real=1")
}

// MARK: - discoverPaths (URLProtocol-mocked, keyed by full URL so
// cross-origin hosts are genuinely distinguishable — the whole point of
// several tests below is proving a cross-origin host is NEVER actually
// requested, which a lastPathComponent-keyed mock couldn't demonstrate).

private final class SitemapMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responsesByURL: [String: (statusCode: Int, body: Data)] = [:]
    nonisolated(unsafe) static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(urlString)
        guard let entry = Self.responsesByURL[urlString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: entry.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: entry.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func sitemapMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SitemapMockURLProtocol.self]
    return URLSession(configuration: config)
}

// `SitemapMockURLProtocol`'s response table and request log are shared
// mutable static state, same reasoning as `CrawlReportTests.swift`'s own
// `.serialized` `CrawlMockURLProtocol`-based suite.
@Suite(.serialized)
struct SitemapDiscoverPathsTests {

private static let defaultOrigin = "https://www.realclientsite.com"
private static let baseURL = "http://mock.example"

private func setUp() {
    SitemapMockURLProtocol.responsesByURL = [:]
    SitemapMockURLProtocol.requestedURLs = []
}

@Test func urlsetHappyPath() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://www.realclientsite.com/product.lasso?id=42</loc></url>
          <url><loc>https://www.realclientsite.com/about.lasso</loc></url>
        </urlset>
        """.utf8)),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(Set(paths) == ["product.lasso?id=42", "about.lasso"])
    #expect(summary.sitemapURLsFetched == 2)
    #expect(summary.crossOriginSkippedCount == 0)
    #expect(summary.malformedLocCount == 0)
    #expect(summary.subSitemapsFollowed == 0)
    #expect(summary.truncated == false)
}

@Test func sitemapindexRecursesIntoSubSitemaps() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://www.realclientsite.com/sitemap-products.xml</loc></sitemap>
          <sitemap><loc>https://www.realclientsite.com/sitemap-pages.xml</loc></sitemap>
        </sitemapindex>
        """.utf8)),
        "\(Self.baseURL)/sitemap-products.xml": (200, Data("""
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://www.realclientsite.com/product.lasso?id=1</loc></url>
        </urlset>
        """.utf8)),
        "\(Self.baseURL)/sitemap-pages.xml": (200, Data("""
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://www.realclientsite.com/about.lasso</loc></url>
        </urlset>
        """.utf8)),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(Set(paths) == ["product.lasso?id=1", "about.lasso"])
    #expect(summary.subSitemapsFollowed == 2)
    #expect(summary.sitemapURLsFetched == 2)
    #expect(summary.truncated == false)
}

@Test func crossOriginSubSitemapEntriesAreSkippedAndNeverRequested() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>
        """.utf8)),
    ]
    // Not registering "sitemap-evil.xml" at all — if this feature ever
    // actually requested it (through baseURL or, worse, some other host),
    // the request would show up in `requestedURLs` and/or fail loudly; the
    // real assertion is that it's simply never attempted.
    SitemapMockURLProtocol.responsesByURL["\(Self.baseURL)/sitemap.xml"] = (200, Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <sitemap><loc>https://www.realclientsite.com/sitemap-good.xml</loc></sitemap>
      <sitemap><loc>https://evil.example/sitemap-evil.xml</loc></sitemap>
    </sitemapindex>
    """.utf8))
    SitemapMockURLProtocol.responsesByURL["\(Self.baseURL)/sitemap-good.xml"] = (200, Data("""
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <url><loc>https://www.realclientsite.com/about.lasso</loc></url>
    </urlset>
    """.utf8))

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(paths == ["about.lasso"])
    #expect(summary.crossOriginSkippedCount == 1)
    #expect(summary.subSitemapsFollowed == 1)
    // The whole point: no request was ever made for the evil sub-sitemap,
    // under any host — neither the real cross-origin host nor even
    // `baseURL` with the evil path.
    #expect(SitemapMockURLProtocol.requestedURLs.contains { $0.contains("evil") } == false)
    #expect(SitemapMockURLProtocol.requestedURLs == ["\(Self.baseURL)/sitemap.xml", "\(Self.baseURL)/sitemap-good.xml"])
}

@Test func nonHTTPSchemeLocEntriesAreRejected() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>javascript:alert(1)</loc></url>
          <url><loc>ftp://www.realclientsite.com/a.lasso</loc></url>
          <url><loc>https://www.realclientsite.com/real.lasso</loc></url>
        </urlset>
        """.utf8)),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(paths == ["real.lasso"])
    // Non-http(s) schemes fail `isSameOrigin`'s own scheme check, so they're
    // counted alongside genuinely cross-origin entries, never as a separate
    // "picked a new destination" outcome — no non-http(s) scheme was ever
    // converted into a network request either way.
    #expect(summary.crossOriginSkippedCount == 2)
}

@Test func malformedOrTruncatedXMLIsHandledWithoutCrashingAndUsesPartialResults() async throws {
    setUp()
    // Truncated mid-second-<url> — a real parse error on every platform,
    // but the first, fully-closed <url><loc> must still be recovered (see
    // `LocCollectorDelegate`'s doc comment on why this doesn't rely on
    // `XMLParser.parse()`'s own, cross-platform-inconsistent return value).
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://www.realclientsite.com/a.lasso</loc></url>
          <url><loc>https://www.realclientsite.com/b
        """.utf8)),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(paths == ["a.lasso"])
    #expect(summary.fetchErrors.isEmpty == false)
}

@Test func emptyDocumentIsHandledWithoutCrashing() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data()),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(paths.isEmpty)
    #expect(summary.sitemapURLsFetched == 0)
}

@Test func doctypeAndEntityDocumentsAreRejectedBeforeParsing() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <?xml version="1.0"?>
        <!DOCTYPE lolz [
         <!ENTITY lol "lol">
         <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        ]>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://www.realclientsite.com/real.lasso</loc></url>
        </urlset>
        """.utf8)),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    // The real, valid <loc> in the same document is also rejected — the
    // WHOLE document is refused pre-parse, not selectively sanitized.
    #expect(paths.isEmpty)
    #expect(summary.fetchErrors.contains { $0.lowercased().contains("doctype") || $0.lowercased().contains("entity") })
}

@Test func utf16EncodedDoctypeAndEntityDocumentBypassesTheSubstringScanButIsStillSafe() async throws {
    setUp()
    // Reproduces a real review finding: a legal, UTF-16-encoded XML
    // document (BOM + `encoding="UTF-16"` declaration) carrying a
    // `<!DOCTYPE ...>` + external `<!ENTITY ...>` declaration. Confirmed
    // empirically (outside this test) that `containsDoctypeOrEntity`'s
    // `String(decoding:as: UTF8.self)` scan NEVER reproduces the literal
    // ASCII "<!doctype"/"<!entity" markers against interleaved-null UTF-16
    // bytes, so this document sails past that pre-check — unlike the
    // ASCII-encoded `doctypeAndEntityDocumentsAreRejectedBeforeParsing`
    // case above, which the scan does catch and rejects wholesale. The
    // real, encoding-independent defense is `shouldResolveExternalEntities
    // = false` at the `XMLParser` construction site, not this scan — this
    // test must pass regardless of the scan's own (encoding-dependent)
    // success or failure.
    let xml = """
    <?xml version="1.0" encoding="UTF-16"?>
    <!DOCTYPE urlset [
    <!ENTITY xxe SYSTEM "file:///etc/hostname">
    ]>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <url><loc>https://www.realclientsite.com/real.lasso</loc></url>
      <url><loc>https://www.realclientsite.com/page.lasso?x=&xxe;</loc></url>
    </urlset>
    """
    let utf16Data = try #require(xml.data(using: .utf16))
    // Sanity check this really is UTF-16-with-BOM, not accidentally
    // re-encoded as UTF-8 by the test itself — a `0xFF 0xFE` lead byte
    // pair is the UTF-16LE byte-order mark.
    #expect(utf16Data.prefix(2) == Data([0xFF, 0xFE]))

    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, utf16Data),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    // The document was NOT rejected pre-parse (unlike the ASCII DOCTYPE
    // test) — proving the substring scan really was bypassed by the
    // encoding, exactly as the review found. It still parses safely and
    // yields the real, declared `<loc>` entries.
    #expect(Set(paths).isSuperset(of: ["real.lasso"]))
    #expect(summary.sitemapURLsFetched == 2)
    #expect(summary.malformedLocCount == 0)
    // The whole point: with `shouldResolveExternalEntities = false` now
    // explicit, the external entity was never fetched/expanded — the
    // second `<loc>`'s `&xxe;` reference contributes no substituted text,
    // so nothing beyond the literal `x=` prefix ever appears. If the
    // external entity HAD been resolved, this would instead contain the
    // contents of `/etc/hostname` appended after `x=`.
    if let pageEntry = paths.first(where: { $0.hasPrefix("page.lasso") }) {
        #expect(pageEntry == "page.lasso?x=")
    }
}

@Test func maxURLsCapTruncatesCleanlyWithoutCrashing() async throws {
    setUp()
    let locs = (1 ... 5).map { "<url><loc>https://www.realclientsite.com/page\($0).lasso</loc></url>" }.joined()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\(locs)</urlset>
        """.utf8)),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 2,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(paths.count == 2)
    #expect(summary.sitemapURLsFetched == 2)
    #expect(summary.truncated)
}

@Test func maxSubSitemapsCapTruncatesCleanlyWithoutCrashing() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://www.realclientsite.com/sub1.xml</loc></sitemap>
          <sitemap><loc>https://www.realclientsite.com/sub2.xml</loc></sitemap>
          <sitemap><loc>https://www.realclientsite.com/sub3.xml</loc></sitemap>
        </sitemapindex>
        """.utf8)),
        "\(Self.baseURL)/sub1.xml": (200, Data("""
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://www.realclientsite.com/a.lasso</loc></url>
        </urlset>
        """.utf8)),
    ]
    // sub2.xml/sub3.xml deliberately unregistered — never fetched once the
    // cap is hit.

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 1,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(paths == ["a.lasso"])
    #expect(summary.subSitemapsFollowed == 1)
    #expect(summary.truncated)
    #expect(SitemapMockURLProtocol.requestedURLs.contains("\(Self.baseURL)/sub2.xml") == false)
    #expect(SitemapMockURLProtocol.requestedURLs.contains("\(Self.baseURL)/sub3.xml") == false)
}

@Test func maxResponseBytesCapDiscardsOversizedDocumentsCleanly() async throws {
    setUp()
    let oversized = String(repeating: "x", count: 100)
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data(oversized.utf8)),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10,
        urlSession: sitemapMockSession()
    )

    #expect(paths.isEmpty)
    #expect(summary.truncated)
    #expect(summary.fetchErrors.contains { $0.contains("exceeded") })
}

@Test func unreachableEntrySitemapIsHandledGracefully() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (404, Data()),
    ]

    let (paths, summary) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    #expect(paths.isEmpty)
    #expect(summary.fetchErrors.contains { $0.contains("404") })
}

@Test func extensionFilteringMatchesDiscoverPathsOwnBehavior() async throws {
    setUp()
    SitemapMockURLProtocol.responsesByURL = [
        "\(Self.baseURL)/sitemap.xml": (200, Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://www.realclientsite.com/page.lasso</loc></url>
          <url><loc>https://www.realclientsite.com/PAGE2.LASSO</loc></url>
          <url><loc>https://www.realclientsite.com/image.jpg</loc></url>
          <url><loc>https://www.realclientsite.com/script.js</loc></url>
        </urlset>
        """.utf8)),
    ]

    let (paths, _) = await Sitemap.discoverPaths(
        baseURL: Self.baseURL,
        entryPath: "sitemap.xml",
        allowedOrigin: Self.defaultOrigin,
        extensions: ["lasso"],
        maxSubSitemaps: 50,
        maxURLs: 20_000,
        maxResponseBytes: 10_000_000,
        urlSession: sitemapMockSession()
    )

    // Case-insensitive extension match, same as `discoverPaths`' own
    // `url.pathExtension.lowercased()` check.
    #expect(Set(paths) == ["page.lasso", "PAGE2.LASSO"])
}

}

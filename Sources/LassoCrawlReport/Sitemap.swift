import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// LINUX PARITY CORRECTION (found via a real spike, not in the original
// approved plan): on `swift-corelibs-foundation`, `XMLParser`/
// `XMLParserDelegate` live in a SEPARATE `FoundationXML` module — exactly
// the same split `FoundationNetworking` already makes for `URLSession`
// above. Confirmed empirically: compiling this file against
// `swift:6.3.2-noble` (the same Linux CI image `Documentation/
// linux-compatibility-review.md` used for this adapter's earlier
// `FoundationNetworking` fix) fails with "'XMLParser' is unavailable: This
// type has moved to the FoundationXML module" until this import is added.
// Without this guard, `LassoCrawlReport` — and therefore the entire
// `LassoPerfectServer` binary, which unconditionally imports it — would
// fail to compile on Linux the moment this file was added, exactly the
// class of hard blocker the earlier `FoundationNetworking` gap already was.
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Sitemap.xml-based URL discovery — an ADDITIONAL source of candidate
/// crawl paths alongside `CrawlReport.discoverPaths`' filesystem walk, not a
/// replacement for it (real sitemaps are often stale/incomplete, so the
/// filesystem walk stays the safety net). Exists because a filesystem walk
/// can never see dynamic, query-parameterized pages (`product.lasso?id=42`)
/// that only exist as URLs a site's own `sitemap.xml` lists.
///
/// Uses Foundation's `XMLParser` (SAX-style), not this workspace's
/// Perfect-XML library — sitemap XML is a simple, well-known shape, and
/// this avoids adding a new system-library (libxml2) build dependency to
/// `LassoPerfectServer` for the first time.
///
/// SECURITY / SSRF POSTURE — read before changing anything here:
///
/// Both real call sites of `CrawlReport.run` pass `baseURL:
/// "http://localhost:<port>"` — a local loopback dev port — while a real
/// `sitemap.xml` lists absolute URLs on the site's real public domain. If
/// same-origin filtering compared `<loc>` entries against `baseURL`,
/// essentially zero real entries would ever match (the feature would
/// silently no-op everywhere it's actually used). So:
///
/// 1. The sitemap document itself — and every sub-sitemap reached via
///    `<sitemapindex>` recursion — is fetched EXCLUSIVELY through
///    `baseURL`, exactly like every other crawled page (same `URLSession`,
///    same client). The path used for each such fetch is always either the
///    caller-supplied `entryPath` (a literal config value) or a path+query
///    string EXTRACTED from an already same-origin-verified `<loc>` — never
///    a new arbitrary host. Zero new outbound-fetch capability is
///    introduced by this feature.
/// 2. Same-origin enforcement compares each `<loc>` against a SEPARATE,
///    always explicitly operator-configured `allowedOrigin` (e.g.
///    `https://www.realclientsite.com` — the origin the sitemap is
///    declared to describe) — never inferred from `baseURL` or from the
///    document itself. This matches this project's established
///    "never accept a literal caller-supplied host, only a pre-configured
///    value" posture (the `email_send -host` SSRF fix).
/// 3. A `<loc>` value, after the origin check, only ever contributes a
///    path+query *string* appended onto the already-trusted `baseURL` — it
///    never picks a network destination. Cross-origin and non-http(s)
///    `<loc>` entries are counted and dropped; they are NEVER converted to
///    a path and NEVER fetched.
public enum Sitemap {
    /// Best-effort discovery statistics — this feature never fails the
    /// overall crawl; every problem (an unreachable sub-sitemap, a
    /// malformed document, a cap being hit) is recorded here instead.
    public struct FetchSummary: Sendable, Equatable {
        /// Total valid (http/https, same-origin) `<loc>` URL entries found
        /// across every `<urlset>` document reached — BEFORE extension
        /// filtering (the `paths` `discoverPaths` returns are already
        /// extension-filtered; this is the raw "how big is this sitemap"
        /// figure, for operator-facing reporting).
        public let sitemapURLsFetched: Int
        public let crossOriginSkippedCount: Int
        public let malformedLocCount: Int
        public let subSitemapsFollowed: Int
        public let truncated: Bool
        public let fetchErrors: [String]

        public init(
            sitemapURLsFetched: Int,
            crossOriginSkippedCount: Int,
            malformedLocCount: Int,
            subSitemapsFollowed: Int,
            truncated: Bool,
            fetchErrors: [String]
        ) {
            self.sitemapURLsFetched = sitemapURLsFetched
            self.crossOriginSkippedCount = crossOriginSkippedCount
            self.malformedLocCount = malformedLocCount
            self.subSitemapsFollowed = subSitemapsFollowed
            self.truncated = truncated
            self.fetchErrors = fetchErrors
        }
    }

    /// `sitemap.xml` never legitimately needs a DOCTYPE or a custom ENTITY
    /// declaration — checked case-insensitively against the raw response
    /// BEFORE it's ever handed to `XMLParser`, since Foundation's
    /// `XMLParser` has no libxml2-style flag to hard-disable entity
    /// expansion (a "billion laughs" defense). This is defense in depth
    /// beyond what was strictly needed to survive contact with real input:
    /// the Linux-parity spike for this feature found that a small,
    /// non-exponential entity payload didn't hang or crash `XMLParser` on
    /// either Darwin or `swift-corelibs-foundation` — but that's not a
    /// guarantee about a genuinely exponential payload, so this check stays
    /// unconditional rather than being scoped down after the fact.
    private static func containsDoctypeOrEntity(_ data: Data) -> Bool {
        // Lossy UTF-8 decode is fine here — this is a substring scan for a
        // literal ASCII marker, not a correctness-sensitive parse, and the
        // caller has already bounded `data` to `maxResponseBytes`.
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("<!doctype") || text.contains("<!entity")
    }

    /// Scheme+host+port match, case-insensitive host, default-port-aware
    /// (`https://Example.com` == `https://example.com:443`). Both `http`
    /// and `https` are accepted schemes (matched against each other, never
    /// mixed) — any other scheme is always a mismatch.
    static func isSameOrigin(_ candidate: URL, as allowedOrigin: URL) -> Bool {
        guard let candidateScheme = candidate.scheme?.lowercased(),
              let allowedScheme = allowedOrigin.scheme?.lowercased(),
              candidateScheme == allowedScheme,
              candidateScheme == "http" || candidateScheme == "https" else {
            return false
        }
        guard let candidateHost = candidate.host?.lowercased(),
              let allowedHost = allowedOrigin.host?.lowercased(),
              candidateHost == allowedHost else {
            return false
        }
        func effectivePort(_ url: URL, scheme: String) -> Int {
            url.port ?? (scheme == "https" ? 443 : 80)
        }
        return effectivePort(candidate, scheme: candidateScheme) == effectivePort(allowedOrigin, scheme: allowedScheme)
    }

    /// Converts an absolute `<loc>` URL (already confirmed same-origin by
    /// the caller) into a raw, percent-DECODED site-root-relative path (no
    /// leading slash), with its query string (also decoded) reattached
    /// after a literal `?` — preserving `discoverPaths`' existing "path
    /// strings are raw until `requestPage`/`encodedRequestPath` encodes
    /// them" contract. Uses `URLComponents`'s `percentEncodedPath`/
    /// `percentEncodedQuery` plus an explicit `removingPercentEncoding`
    /// call, rather than `URL.path`/`URL.query`'s own auto-decoding
    /// shortcut — those two properties' exact decode behavior has drifted
    /// across Foundation versions/platforms historically, and this feature
    /// needs a single, unambiguous, cross-platform-predictable meaning.
    ///
    /// Returns `nil` for a non-http(s) scheme, an empty path, any path with
    /// a hidden segment (a component starting with `.` — the same
    /// filesystem-hidden-file convention `discoverPaths` already refuses to
    /// crawl), or an extension not in `extensions`.
    static func relativePath(of url: URL, extensions: Set<String>) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let decodedPath = components.percentEncodedPath.removingPercentEncoding, decodedPath.isEmpty == false else { return nil }
        let trimmedPath = decodedPath.hasPrefix("/") ? String(decodedPath.dropFirst()) : decodedPath
        guard trimmedPath.isEmpty == false else { return nil }
        guard trimmedPath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) == false else { return nil }
        let fileExtension = (trimmedPath as NSString).pathExtension.lowercased()
        guard extensions.contains(fileExtension) else { return nil }

        var result = trimmedPath
        if let encodedQuery = components.percentEncodedQuery,
           let decodedQuery = encodedQuery.removingPercentEncoding,
           decodedQuery.isEmpty == false {
            result += "?\(decodedQuery)"
        }
        return result
    }

    /// Fetches `pathAndQuery` through `baseURL` (never any other host —
    /// see this type's own doc comment) and returns its body, or `nil` if
    /// anything went wrong — every failure is recorded into `fetchErrors`
    /// and is never fatal to the overall discovery call (sitemap discovery
    /// is fully best-effort). Also enforces `maxResponseBytes`, setting
    /// `truncated` true (via `inout`) if a response is discarded for being
    /// oversized.
    private static func fetchDocument(
        baseURL: String,
        pathAndQuery: String,
        maxResponseBytes: Int,
        urlSession: URLSession,
        fetchErrors: inout [String],
        truncated: inout Bool
    ) async -> Data? {
        guard let encodedPath = CrawlReport.encodedRequestPath(pathAndQuery),
              let url = URL(string: "\(baseURL)/\(encodedPath)") else {
            fetchErrors.append("sitemap: could not build a request URL for path '\(pathAndQuery)'")
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await urlSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(statusCode) else {
                fetchErrors.append("sitemap: fetching '\(pathAndQuery)' returned HTTP \(statusCode)")
                return nil
            }
            guard data.count <= maxResponseBytes else {
                fetchErrors.append("sitemap: '\(pathAndQuery)' response (\(data.count) bytes) exceeded the \(maxResponseBytes)-byte cap — discarded unparsed")
                truncated = true
                return nil
            }
            return data
        } catch {
            fetchErrors.append("sitemap: fetching '\(pathAndQuery)' failed: \(error)")
            return nil
        }
    }

    /// SAX-style collector: records every `<loc>` element's text content in
    /// document order, and the document's root element name (`urlset` or
    /// `sitemapindex`) — without depending on `XMLParser.parse()`'s own
    /// boolean return value, which the Linux-parity spike for this feature
    /// found is NOT consistent across platforms for a malformed/truncated
    /// document (Darwin returns `false`; `swift-corelibs-foundation`
    /// returned `true` for the identical input, despite also invoking
    /// `parser(_:parseErrorOccurred:)`). `discoverPaths` below treats
    /// `hadParseError` — not `parser.parse()`'s return value — as the
    /// signal that a document was malformed/truncated, and still uses
    /// whatever `<loc>` entries were fully closed before the error, on
    /// both platforms.
    private final class LocCollectorDelegate: NSObject, XMLParserDelegate {
        private(set) var rootElementName: String?
        private(set) var locs: [String] = []
        private(set) var hadParseError = false
        private var currentElementName: String?
        private var currentText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if rootElementName == nil {
                rootElementName = elementName
            }
            currentElementName = elementName
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentElementName == "loc" else { return }
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "loc" {
                locs.append(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            currentText = ""
            currentElementName = nil
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            hadParseError = true
        }
    }

    /// Fetches `entryPath` (relative to `baseURL`) and, depending on its
    /// root element, either collects `<urlset>/<url>/<loc>` entries
    /// directly or recurses into `<sitemapindex>/<sitemap>/<loc>` children
    /// (up to `maxSubSitemaps`) — every recursion step re-applies the exact
    /// same same-origin check, DOCTYPE/ENTITY pre-parse rejection, and size
    /// cap as the entry document. Iterative (a work queue), not recursive
    /// `async` calls, so there's no unbounded call-stack growth even for a
    /// maliciously deep `<sitemapindex>` chain, and cancellation of the
    /// enclosing `Task` (e.g. the crawl being aborted) is checked between
    /// documents rather than only being possible to interrupt at a single
    /// deeply-nested call frame.
    public static func discoverPaths(
        baseURL: String,
        entryPath: String,
        allowedOrigin: String,
        extensions: Set<String>,
        maxSubSitemaps: Int,
        maxURLs: Int,
        maxResponseBytes: Int,
        urlSession: URLSession
    ) async -> (paths: [String], summary: FetchSummary) {
        guard let allowedOriginURL = URL(string: allowedOrigin),
              let scheme = allowedOriginURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              allowedOriginURL.host != nil else {
            return (
                [],
                FetchSummary(
                    sitemapURLsFetched: 0,
                    crossOriginSkippedCount: 0,
                    malformedLocCount: 0,
                    subSitemapsFollowed: 0,
                    truncated: false,
                    fetchErrors: ["sitemap: allowedOrigin '\(allowedOrigin)' is not a valid http(s) origin — sitemap discovery skipped"]
                )
            )
        }

        var collectedPaths: Set<String> = []
        var sitemapURLsFetched = 0
        var crossOriginSkipped = 0
        var malformedLoc = 0
        var subSitemapsFollowed = 0
        var truncated = false
        var fetchErrors: [String] = []

        var pendingSitemapPaths: [String] = [entryPath]
        var isFirstDocument = true
        var reachedURLCap = false

        while Task.isCancelled == false, reachedURLCap == false, pendingSitemapPaths.isEmpty == false {
            let path = pendingSitemapPaths.removeFirst()

            guard let data = await fetchDocument(
                baseURL: baseURL,
                pathAndQuery: path,
                maxResponseBytes: maxResponseBytes,
                urlSession: urlSession,
                fetchErrors: &fetchErrors,
                truncated: &truncated
            ) else {
                continue
            }

            guard containsDoctypeOrEntity(data) == false else {
                fetchErrors.append("sitemap: '\(path)' contains a DOCTYPE/ENTITY declaration, which sitemap.xml never legitimately needs — rejected before parsing")
                continue
            }

            if isFirstDocument == false {
                subSitemapsFollowed += 1
            }
            isFirstDocument = false

            let delegate = LocCollectorDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            // Deliberately ignore `parser.parse()`'s own return value — see
            // `LocCollectorDelegate`'s doc comment for why it isn't a
            // reliable cross-platform signal. Whatever `<loc>` entries the
            // delegate collected before any error are still used; a
            // captured parse error is only ever a note in `fetchErrors`.
            _ = parser.parse()
            if delegate.hadParseError {
                fetchErrors.append("sitemap: '\(path)' was malformed or truncated — used \(delegate.locs.count) <loc> entr\(delegate.locs.count == 1 ? "y" : "ies") parsed before the error")
            }

            guard let rootElementName = delegate.rootElementName else {
                fetchErrors.append("sitemap: '\(path)' had no recognizable root element (empty or completely unparseable) — skipped")
                continue
            }

            switch rootElementName {
            case "urlset":
                for rawLoc in delegate.locs {
                    if sitemapURLsFetched >= maxURLs {
                        truncated = true
                        reachedURLCap = true
                        break
                    }
                    guard rawLoc.isEmpty == false, let locURL = URL(string: rawLoc) else {
                        malformedLoc += 1
                        continue
                    }
                    guard isSameOrigin(locURL, as: allowedOriginURL) else {
                        crossOriginSkipped += 1
                        continue
                    }
                    sitemapURLsFetched += 1
                    if let relative = relativePath(of: locURL, extensions: extensions) {
                        collectedPaths.insert(relative)
                    }
                }

            case "sitemapindex":
                for rawLoc in delegate.locs {
                    guard rawLoc.isEmpty == false, let locURL = URL(string: rawLoc) else {
                        malformedLoc += 1
                        continue
                    }
                    guard isSameOrigin(locURL, as: allowedOriginURL) else {
                        crossOriginSkipped += 1
                        continue
                    }
                    // No extension filter for a sub-sitemap reference
                    // itself (it's an XML document, not a crawl candidate)
                    // — just the same hidden-segment/percent-decode
                    // handling `relativePath` already provides, via an
                    // extension set that matches whatever this sub-sitemap
                    // document's own path extension is.
                    guard let subSitemapPath = relativePath(
                        of: locURL,
                        extensions: [(locURL.path as NSString).pathExtension.lowercased()]
                    ) else {
                        malformedLoc += 1
                        continue
                    }
                    // `subSitemapsFollowed` counts documents actually
                    // fetched (incremented above, once dequeued) — this is
                    // the queueing side of that same cap, counting what's
                    // already enqueued-or-fetched so a wide sitemapindex
                    // can't queue unboundedly past the cap before any of it
                    // is ever fetched.
                    guard subSitemapsFollowed + pendingSitemapPaths.count < maxSubSitemaps else {
                        truncated = true
                        continue
                    }
                    pendingSitemapPaths.append(subSitemapPath)
                }

            default:
                fetchErrors.append("sitemap: '\(path)' had an unrecognized root element <\(rootElementName)> (expected <urlset> or <sitemapindex>) — skipped")
            }
        }

        return (
            collectedPaths.sorted(),
            FetchSummary(
                sitemapURLsFetched: sitemapURLsFetched,
                crossOriginSkippedCount: crossOriginSkipped,
                malformedLocCount: malformedLoc,
                subSitemapsFollowed: subSitemapsFollowed,
                truncated: truncated,
                fetchErrors: fetchErrors
            )
        )
    }
}

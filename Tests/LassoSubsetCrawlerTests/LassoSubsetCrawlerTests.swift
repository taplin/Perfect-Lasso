import Foundation
import Testing
@testable import LassoSubsetCrawler

@Test func scansLassoEmbeddedInHTMLFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "[inline(-search), records][/records][/inline]"
        .write(to: root.appendingPathComponent("search.htm"), atomically: true, encoding: .utf8)
    try "<?lasso include('header.inc') ?>"
        .write(to: root.appendingPathComponent("layout.html"), atomically: true, encoding: .utf8)
    try "<html><body>Static page</body></html>"
        .write(to: root.appendingPathComponent("static.html"), atomically: true, encoding: .utf8)
    try "[inline: -search][records][field:'name'][/records][/inline]"
        .write(to: root.appendingPathComponent("legacy.htm"), atomically: true, encoding: .utf8)

    let result = try Scanner(root: root, rootPath: root.path, excludes: []).run()

    #expect(result.files == 3)
    #expect(result.extensions["htm"] == 2)
    #expect(result.extensions["html"] == 1)
    #expect(result.constructs.counts["inline"] == 2)
    #expect(result.constructs.counts["include"] == 1)
}

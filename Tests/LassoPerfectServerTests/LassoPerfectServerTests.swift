import Foundation
import Testing
@testable import LassoPerfectServer
import LassoParser
import PerfectNIO

// See Documentation/web-response-include-plan.md. Covers the pure
// header-building helpers behind sendFile/file_serve/file_stream's
// response construction — specifically the CRLF-stripping and
// quoted-string-escaping fix that a code review pass flagged as having no
// automated coverage (LassoParserTests can't reach LassoPerfectServer's
// executable target, hence this separate test target).

@Test func headerSafeStripsCarriageReturnsAndNewlines() {
    #expect(headerSafe("text/plain\r\nX-Injected: evil") == "text/plainX-Injected: evil")
    #expect(headerSafe("no newlines here") == "no newlines here")
}

@Test func quotedStringSafeEscapesBackslashAndDoubleQuoteAndStripsCRLF() {
    // Backslash must be escaped first — escaping the quote before the
    // backslash would double-escape the backslash it just inserted.
    #expect(quotedStringSafe(#"evil".pdf"#) == #"evil\".pdf"#)
    #expect(quotedStringSafe(#"a\b"#) == #"a\\b"#)
    #expect(quotedStringSafe("line1\r\nline2") == "line1line2")
    #expect(quotedStringSafe("plain.pdf") == "plain.pdf")
}

@Test func bytesFileOutputSetsContentTypeAndOmitsDispositionWhenNil() throws {
    let request = LassoFileServeRequest(source: .data(Data("hello".utf8)), contentType: "text/plain")
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Type") == "text/plain")
    #expect(head.headers.first(name: "Content-Disposition") == nil)
}

@Test func bytesFileOutputBuildsDispositionWithEscapedFilenameWhenNameGiven() throws {
    let request = LassoFileServeRequest(
        source: .data(Data("hello".utf8)),
        fileName: #"report".pdf"#,
        contentType: "application/pdf",
        disposition: "attachment"
    )
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Type") == "application/pdf")
    #expect(head.headers.first(name: "Content-Disposition") == #"attachment; filename="report\".pdf""#)
}

@Test func bytesFileOutputOmitsFilenameAttributeWhenNoNameGiven() throws {
    // file_serve/file_stream's shape: a disposition-free override branch
    // (contentType set, name/disposition both nil) must not emit a
    // Content-Disposition header at all.
    let request = LassoFileServeRequest(source: .path("downloads/report.pdf"), contentType: "application/pdf")
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Disposition") == nil)
}

@Test func bytesFileOutputDefaultsContentTypeToOctetStreamWhenNil() throws {
    let request = LassoFileServeRequest(source: .data(Data("hello".utf8)))
    let output = bytesFileOutput(data: Data("hello".utf8), request: request)

    let head = try #require(output.head(request: sampleRequestInfo()))
    #expect(head.headers.first(name: "Content-Type") == "application/octet-stream")
}

private func sampleRequestInfo() -> HTTPRequestInfo {
    HTTPRequestInfo(
        head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/"),
        options: []
    )
}

// MARK: - DatasourceFileConfig / DatasourceEntry decoding
//
// See Documentation/lasso-perfect-server.md's FileMaker Datasource
// section. `datasources` used to be a flat `[String: String]` (Lasso
// alias -> MySQL schema name); it's now `[String: DatasourceEntry]` so a
// config file can mix MySQL and FileMaker aliases, but every config file
// written before FileMaker support must keep decoding identically.

@Test func datasourceEntryDecodesLegacyBareStringAsMySQLWithSchema() throws {
    let entry = try JSONDecoder().decode(DatasourceEntry.self, from: Data(#""catalog""#.utf8))
    #expect(entry.type == .mysql)
    #expect(entry.schema == "catalog")
}

@Test func datasourceEntryDecodesExplicitMySQLObjectShape() throws {
    let entry = try JSONDecoder().decode(
        DatasourceEntry.self,
        from: Data(#"{"type": "mysql", "schema": "catalog"}"#.utf8)
    )
    #expect(entry.type == .mysql)
    #expect(entry.schema == "catalog")
}

@Test func datasourceEntryDecodesFileMakerObjectShapeWithNoSchema() throws {
    let entry = try JSONDecoder().decode(DatasourceEntry.self, from: Data(#"{"type": "filemaker"}"#.utf8))
    #expect(entry.type == .filemaker)
    #expect(entry.schema == nil)
}

@Test func datasourceFileConfigDecodesLegacyFlatShapeAsMySQLBlock() throws {
    let json = """
    {
        "host": "localhost",
        "port": 3306,
        "user": "lassouser",
        "password": "secret",
        "sessionDatabase": "sessions",
        "allowWrites": true,
        "allowRawSQL": false,
        "datasources": {"catalog_mysql": "catalog"}
    }
    """
    let config = try JSONDecoder().decode(DatasourceFileConfig.self, from: Data(json.utf8))
    #expect(config.mysql?.host == "localhost")
    #expect(config.mysql?.port == 3306)
    #expect(config.mysql?.user == "lassouser")
    #expect(config.mysql?.password == "secret")
    #expect(config.mysql?.sessionDatabase == "sessions")
    #expect(config.mysql?.allowWrites == true)
    #expect(config.mysql?.allowRawSQL == false)
    #expect(config.filemaker == nil)
    #expect(config.datasources["catalog_mysql"]?.type == .mysql)
    #expect(config.datasources["catalog_mysql"]?.schema == "catalog")
}

@Test func datasourceFileConfigDecodesNestedMySQLAndFileMakerBlocks() throws {
    let json = """
    {
        "mysql": {"host": "db.internal", "port": 3306, "user": "u", "password": "p"},
        "filemaker": {"host": "192.0.2.1", "port": 80, "user": "fmuser", "password": "fmpass", "allowWrites": true},
        "datasources": {
            "primary_mysql": {"type": "mysql", "schema": "primary"},
            "some_filemaker_alias": {"type": "filemaker"}
        }
    }
    """
    let config = try JSONDecoder().decode(DatasourceFileConfig.self, from: Data(json.utf8))
    #expect(config.mysql?.host == "db.internal")
    #expect(config.filemaker?.host == "192.0.2.1")
    #expect(config.filemaker?.port == 80)
    #expect(config.filemaker?.allowWrites == true)
    #expect(config.datasources["primary_mysql"]?.type == .mysql)
    #expect(config.datasources["primary_mysql"]?.schema == "primary")
    #expect(config.datasources["some_filemaker_alias"]?.type == .filemaker)
    #expect(config.datasources["some_filemaker_alias"]?.schema == nil)
}

@Test func datasourceFileConfigWithOnlyFileMakerFieldsLeavesMySQLNil() throws {
    // No nested "mysql" key AND none of the legacy flat MySQL fields --
    // must not synthesize a spurious empty MySQL block.
    let json = """
    {
        "filemaker": {"host": "192.0.2.1"},
        "datasources": {"some_filemaker_alias": {"type": "filemaker"}}
    }
    """
    let config = try JSONDecoder().decode(DatasourceFileConfig.self, from: Data(json.utf8))
    #expect(config.mysql == nil)
    #expect(config.filemaker?.host == "192.0.2.1")
}

// MARK: - LassoMultiBackendInlineProvider routing

private final class InlineProviderCallRecorder: @unchecked Sendable {
    var calls: [String] = []
}

private struct RecordingExecutor: LassoDynamicQueryExecutor {
    let label: String
    let recorder: InlineProviderCallRecorder

    func execute(_ request: LassoInlineRequest) async throws -> LassoInlineFrame {
        recorder.calls.append(label)
        return LassoInlineFrame(rows: [])
    }
}

@Test func multiBackendInlineProviderRoutesByAliasToTheCorrectBackend() async throws {
    let recorder = InlineProviderCallRecorder()
    let mysqlProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "mysql", recorder: recorder))
    let fileMakerProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "filemaker", recorder: recorder))
    let provider = LassoMultiBackendInlineProvider(
        mysqlProvider: mysqlProvider,
        fileMakerProvider: fileMakerProvider,
        fileMakerAliases: ["fm_catalog"]
    )
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='fm_catalog',-table='storefront',-findall)][/inline]",
        context: &context
    )
    _ = try await LassoRenderer().render(
        "[inline(-database='catalog_mysql',-table='skus',-findall)][/inline]",
        context: &context
    )

    #expect(recorder.calls == ["filemaker", "mysql"])
}

@Test func multiBackendInlineProviderMatchesFileMakerAliasesCaseInsensitively() async throws {
    let recorder = InlineProviderCallRecorder()
    let fileMakerProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "filemaker", recorder: recorder))
    let provider = LassoMultiBackendInlineProvider(
        mysqlProvider: nil,
        fileMakerProvider: fileMakerProvider,
        fileMakerAliases: ["Fm_Catalog"]
    )
    var context = LassoContext(inlineProvider: provider)

    _ = try await LassoRenderer().render(
        "[inline(-database='fm_catalog',-table='storefront',-findall)][/inline]",
        context: &context
    )

    #expect(recorder.calls == ["filemaker"])
}

@Test func multiBackendInlineProviderThrowsInlineNotConfiguredForUnroutableAliasWithNoMySQLProvider() async throws {
    let recorder = InlineProviderCallRecorder()
    let fileMakerProvider = LassoDynamicInlineProvider(executor: RecordingExecutor(label: "filemaker", recorder: recorder))
    let provider = LassoMultiBackendInlineProvider(
        mysqlProvider: nil,
        fileMakerProvider: fileMakerProvider,
        fileMakerAliases: ["fm_catalog"]
    )
    var context = LassoContext(inlineProvider: provider)

    await #expect(throws: LassoRuntimeError.inlineNotConfigured) {
        try await LassoRenderer().render(
            "[inline(-database='some_unconfigured_alias',-table='x',-findall)][/inline]",
            context: &context
        )
    }
    #expect(recorder.calls == [])
}

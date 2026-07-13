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

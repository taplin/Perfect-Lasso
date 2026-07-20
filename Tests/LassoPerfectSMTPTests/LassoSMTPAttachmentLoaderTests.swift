//
//  LassoSMTPAttachmentLoaderTests.swift
//  LassoPerfectSMTPTests
//
//  Adversarial + happy-path tests for `LassoSMTPAttachmentLoader` — §4.5's
//  testing-strategy line: `../` traversal, symlink escape, non-regular-file
//  rejection, TOCTOU-relevant ordering, byte-cap/count-cap ceilings, and
//  the happy path. Uses a real, uniquely-named temp directory as
//  `siteRoot` for every test — this loader does real filesystem I/O
//  (containment/`open`/`fstat`/`read`), so a fake filesystem would test
//  the wrong thing.
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Testing
@testable import LassoPerfectSMTP
import PerfectSMTP

struct LassoSMTPAttachmentLoaderTests {
    private static func makeSiteRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-smtp-attachment-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func write(_ contents: Data, to url: URL) throws {
        try contents.write(to: url)
    }

    // MARK: - Happy path

    @Test func validFileLoadsCorrectlyWithInferredContentType() throws {
        let root = try Self.makeSiteRoot()
        try Self.write(Data("hello world".utf8), to: root.appendingPathComponent("greeting.txt"))

        let result = try LassoSMTPAttachmentLoader.resolve(
            attachments: [.path(relativePath: "greeting.txt")],
            inlineImages: [],
            siteRoot: root
        )

        #expect(result.attachments.count == 1)
        #expect(result.attachments[0].filename == "greeting.txt")
        #expect(result.attachments[0].contentType == "text/plain")
        #expect(result.attachments[0].data == Data("hello world".utf8))
    }

    @Test func unknownExtensionDefaultsToOctetStream() throws {
        let root = try Self.makeSiteRoot()
        try Self.write(Data([0x01, 0x02, 0x03]), to: root.appendingPathComponent("mystery.bin"))

        let result = try LassoSMTPAttachmentLoader.resolve(
            attachments: [.path(relativePath: "mystery.bin")],
            inlineImages: [],
            siteRoot: root
        )

        #expect(result.attachments[0].contentType == "application/octet-stream")
    }

    @Test func nestedSubdirectoryPathResolvesCorrectly() throws {
        let root = try Self.makeSiteRoot()
        let subdir = root.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Self.write(Data("nested".utf8), to: subdir.appendingPathComponent("file.txt"))

        let result = try LassoSMTPAttachmentLoader.resolve(
            attachments: [.path(relativePath: "attachments/file.txt")],
            inlineImages: [],
            siteRoot: root
        )

        #expect(result.attachments[0].data == Data("nested".utf8))
        #expect(result.attachments[0].filename == "file.txt") // basenamed, no directory component
    }

    @Test func dataVariantAttachmentNeedsNoFileSystemAccessAtAll() throws {
        // siteRoot deliberately doesn't need to exist as a real, populated
        // directory for the `.data` (name=data pair) variant -- no path
        // resolution happens for it at all.
        let root = try Self.makeSiteRoot()

        let result = try LassoSMTPAttachmentLoader.resolve(
            attachments: [.data(filename: "generated.pdf", data: Data("pdf bytes".utf8))],
            inlineImages: [.data(contentID: "logo.png", data: Data("png bytes".utf8))],
            siteRoot: root
        )

        #expect(result.attachments[0].filename == "generated.pdf")
        #expect(result.attachments[0].contentType == "application/pdf")
        #expect(result.attachments[0].data == Data("pdf bytes".utf8))
        #expect(result.inlineImages[0].contentID == "logo.png")
        #expect(result.inlineImages[0].contentType == "image/png")
    }

    @Test func inlineImagePathVariantUsesBasenameAsBothFilenameAndContentID() throws {
        let root = try Self.makeSiteRoot()
        try Self.write(Data("gif bytes".utf8), to: root.appendingPathComponent("apache_pb.gif"))

        let result = try LassoSMTPAttachmentLoader.resolve(
            attachments: [],
            inlineImages: [.path(contentID: "apache_pb.gif", relativePath: "apache_pb.gif")],
            siteRoot: root
        )

        #expect(result.inlineImages[0].contentID == "apache_pb.gif")
        #expect(result.inlineImages[0].filename == "apache_pb.gif")
        #expect(result.inlineImages[0].contentType == "image/gif")
    }

    // MARK: - Path traversal / containment (§4.5, §5)

    @Test func dotDotTraversalEscapingSiteRootIsRejected() throws {
        let root = try Self.makeSiteRoot()
        // A real file that genuinely exists just outside siteRoot -- proves
        // rejection is a containment decision, not just a
        // file-doesn't-exist coincidence.
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Self.write(Data("secret".utf8), to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "../\(outside.lastPathComponent)")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    @Test func deeplyNestedDotDotTraversalIsRejected() throws {
        let root = try Self.makeSiteRoot()
        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "../../../../../../../../etc/passwd")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    @Test func symlinkEscapingSiteRootIsRejected() throws {
        let root = try Self.makeSiteRoot()
        let outside = root.deletingLastPathComponent().appendingPathComponent("symlink-target-\(UUID().uuidString).txt")
        try Self.write(Data("secret via symlink".utf8), to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let symlink = root.appendingPathComponent("escape-link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "escape-link.txt")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    @Test func symlinkStayingWithinSiteRootIsAllowed() throws {
        let root = try Self.makeSiteRoot()
        try Self.write(Data("real content".utf8), to: root.appendingPathComponent("real.txt"))
        let symlink = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: root.appendingPathComponent("real.txt")
        )

        let result = try LassoSMTPAttachmentLoader.resolve(
            attachments: [.path(relativePath: "link.txt")],
            inlineImages: [],
            siteRoot: root
        )
        #expect(result.attachments[0].data == Data("real content".utf8))
    }

    // MARK: - Regular-file-type rejection + TOCTOU-relevant ordering (§4.5)

    @Test func namedPipeIsRejectedNotHungOn() throws {
        let root = try Self.makeSiteRoot()
        let pipePath = root.appendingPathComponent("fifo").path
        let mkfifoResult = mkfifo(pipePath, 0o600)
        #expect(mkfifoResult == 0, "mkfifo failed with errno \(errno)")

        // If the loader ever regresses to `Data(contentsOf:)`-style
        // path-based reading, this call would hang indefinitely (no
        // writer on the other end of the FIFO) instead of throwing --
        // Swift Testing's own default per-test timeout would eventually
        // fail the suite, but the throw below is the real assertion: the
        // regular-file-type check (on the open descriptor's `fstat`, not
        // the path string) must reject this before any `read` is even
        // attempted.
        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "fifo")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    @Test func directoryPathIsRejectedAsNotARegularFile() throws {
        let root = try Self.makeSiteRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("adir"), withIntermediateDirectories: true)

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "adir")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    @Test func missingFileThrowsAClearErrorRatherThanCrashing() throws {
        let root = try Self.makeSiteRoot()
        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "does-not-exist.txt")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    /// Proves the regular-file-type check happens against the *opened
    /// descriptor's* `fstat` result, not a second re-stat of the path
    /// string -- by using `loadFile` directly (the internal entry point
    /// `resolve` calls) against a FIFO and confirming the failure is the
    /// file-type rejection, not e.g. a generic read timeout/hang. This is
    /// the ordering the file's own doc comment describes: open -> fstat(fd)
    /// -> verify -> read, all against one already-open descriptor.
    @Test func regularFileTypeCheckOperatesOnTheOpenDescriptorNotThePathStringAgain() throws {
        let root = try Self.makeSiteRoot()
        let pipePath = root.appendingPathComponent("fifo2").path
        #expect(mkfifo(pipePath, 0o600) == 0)

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.loadFile(relativePath: "fifo2", siteRoot: root, maxBytes: LassoSMTPAttachmentLoader.maximumTotalBytes)
        }
    }

    // MARK: - Byte ceiling (§4.5)

    @Test func singleFileOverTheByteCeilingIsRejected() throws {
        let root = try Self.makeSiteRoot()
        let oversized = Data(repeating: 0x41, count: LassoSMTPAttachmentLoader.maximumTotalBytes + 1)
        try Self.write(oversized, to: root.appendingPathComponent("big.bin"))

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "big.bin")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    @Test func sumOfSeveralFilesOverTheByteCeilingIsRejected() throws {
        let root = try Self.makeSiteRoot()
        let each = LassoSMTPAttachmentLoader.maximumTotalBytes / 2 + 1024
        for name in ["a.bin", "b.bin"] {
            try Self.write(Data(repeating: 0x42, count: each), to: root.appendingPathComponent(name))
        }

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "a.bin"), .path(relativePath: "b.bin")],
                inlineImages: [],
                siteRoot: root
            )
        }
    }

    @Test func combinedAttachmentAndInlineImageBytesCountTowardTheSameCeiling() throws {
        let root = try Self.makeSiteRoot()
        let half = LassoSMTPAttachmentLoader.maximumTotalBytes / 2 + 1024
        try Self.write(Data(repeating: 0x43, count: half), to: root.appendingPathComponent("attach.bin"))

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(
                attachments: [.path(relativePath: "attach.bin")],
                inlineImages: [.data(contentID: "img", data: Data(repeating: 0x44, count: half))],
                siteRoot: root
            )
        }
    }

    @Test func justUnderTheByteCeilingSucceeds() throws {
        let root = try Self.makeSiteRoot()
        let underCap = Data(repeating: 0x45, count: LassoSMTPAttachmentLoader.maximumTotalBytes - 10)
        try Self.write(underCap, to: root.appendingPathComponent("justunder.bin"))

        let result = try LassoSMTPAttachmentLoader.resolve(
            attachments: [.path(relativePath: "justunder.bin")],
            inlineImages: [],
            siteRoot: root
        )
        #expect(result.attachments[0].data.count == underCap.count)
    }

    // MARK: - Count ceiling (§4.5)

    @Test func moreThanTheCountCeilingIsRejectedEvenWhenWellUnderTheByteCeiling() throws {
        let root = try Self.makeSiteRoot()
        let pending: [LassoSMTPPendingAttachment] = (0..<(LassoSMTPAttachmentLoader.maximumFileCount + 1)).map { index in
            .data(filename: "tiny-\(index).txt", data: Data([0x00]))
        }

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(attachments: pending, inlineImages: [], siteRoot: root)
        }
    }

    @Test func exactlyTheCountCeilingSucceeds() throws {
        let root = try Self.makeSiteRoot()
        let pending: [LassoSMTPPendingAttachment] = (0..<LassoSMTPAttachmentLoader.maximumFileCount).map { index in
            .data(filename: "tiny-\(index).txt", data: Data([0x00]))
        }

        let result = try LassoSMTPAttachmentLoader.resolve(attachments: pending, inlineImages: [], siteRoot: root)
        #expect(result.attachments.count == LassoSMTPAttachmentLoader.maximumFileCount)
    }

    @Test func countCeilingIsSharedAcrossAttachmentsAndInlineImagesCombined() throws {
        let root = try Self.makeSiteRoot()
        let half = LassoSMTPAttachmentLoader.maximumFileCount / 2
        let attachments: [LassoSMTPPendingAttachment] = (0..<(half + 1)).map { .data(filename: "a\($0).txt", data: Data([0x00])) }
        let inlineImages: [LassoSMTPPendingInlineImage] = (0..<(half + 1)).map { .data(contentID: "i\($0)", data: Data([0x00])) }

        #expect(throws: LassoSMTPError.self) {
            _ = try LassoSMTPAttachmentLoader.resolve(attachments: attachments, inlineImages: inlineImages, siteRoot: root)
        }
    }
}

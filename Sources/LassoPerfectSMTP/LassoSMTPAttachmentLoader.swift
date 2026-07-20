//
//  LassoSMTPAttachmentLoader.swift
//  LassoPerfectSMTP
//
//  Resolves `LassoSMTPMessageBuilder`'s I/O-free `LassoSMTPPendingAttachment`/
//  `LassoSMTPPendingInlineImage` intermediate values into real
//  `Attachment`/`InlineResource`s — see
//  Documentation/lasso-perfect-smtp-integration-plan.md §4.5. This is the
//  ONLY place in `LassoPerfectSMTP` that touches the filesystem for
//  `-attachments`/`-htmlImages`; `LassoSMTPMessageBuilder.build` stays pure
//  mapping logic per its own doc comment. Called from
//  `LassoEmailProviderImpl.send`, after `build()` returns and before
//  `EmailMessage` construction/dispatch to the mailer.
//
//  ## Path-containment — reimplemented here, not shared, and why
//
//  `main.swift`'s `LassoSiteServer.isWithinRoot`/`fileURL(for:)`
//  (`Sources/LassoPerfectServer/main.swift`, ~line 1295/1326) already do
//  exactly this containment check, but `LassoPerfectSMTP` cannot call them
//  — `LassoPerfectServer` (the executable) depends on `LassoPerfectSMTP`
//  (this library), not the other way around; reaching "up" into the
//  executable target would be a circular/backwards dependency. This type
//  reimplements the identical logic instead (same
//  `standardizedFileURL`/`resolvingSymlinksInPath()`/prefix-check shape),
//  matching `main.swift`'s own precedent rather than inventing a new
//  policy.
//
//  ## Regular-file-type check + TOCTOU-safe read order
//
//  `Data(contentsOf:)` against a named pipe or a device file can hang
//  (FIFO with no writer) or exhaust memory (an endless character device).
//  The safe fix isn't just "check the path string is a regular file, then
//  read the path" — an attacker can swap what a path component resolves to
//  between the check and the read (classic TOCTOU). This loader instead:
//  1. containment-checks + resolves the path to `candidate: URL` (symlinks
//     already fully resolved by `resolvingSymlinksInPath()`);
//  2. opens `candidate.path` with POSIX `open(_:O_RDONLY)`, getting a file
//     descriptor;
//  3. `fstat`s THAT DESCRIPTOR (not the path string again) to verify
//     `S_IFREG` (regular file) and read its authoritative size;
//  4. reads exactly that many bytes from the same descriptor, then closes
//     it.
//  Steps 2-4 all operate on one already-open descriptor — nothing between
//  the type check and the read can swap what "the file" refers to, closing
//  the race a path-string-based re-check would leave open. (The earlier,
//  separate race — a symlink being swapped between step 1's containment
//  check and step 2's `open` — is a real, harder problem `main.swift`'s own
//  `isWithinRoot`/`fileURL(for:)` has the identical exposure to; not solved
//  here either, since fixing it needs `openat`-style component-by-component
//  walking with `O_NOFOLLOW`, out of scope for matching an existing,
//  already-accepted precedent.)
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import PerfectSMTP

/// `-attachments`, parsed by `LassoSMTPMessageBuilder.build` but not yet
/// resolved to bytes — no I/O has happened at this point.
public enum LassoSMTPPendingAttachment: Sendable, Equatable {
    /// The `name = data` pair variant — already-evaluated `Data`, nothing
    /// left to resolve.
    case data(filename: String, data: Data)
    /// The file-path variant — resolved against `siteRoot` by
    /// `LassoSMTPAttachmentLoader`.
    case path(relativePath: String)
}

/// `-htmlImages`, parsed but not yet resolved — same two-shape contract as
/// `LassoSMTPPendingAttachment`, plus the `Content-ID` every inline image
/// needs (computed at parse time in `LassoSMTPMessageBuilder`, since
/// deriving it is pure string logic, not I/O).
public enum LassoSMTPPendingInlineImage: Sendable, Equatable {
    case data(contentID: String, data: Data)
    case path(contentID: String, relativePath: String)
}

/// Thrown by every `LassoSMTPAttachmentLoader` failure mode — always
/// caught at the `LassoEmailProviderImpl.send` boundary and re-thrown as
/// `LassoRecoverableError`, same discipline as every other error this
/// adapter produces (see `LassoSMTPError.swift`'s doc comment). Never lets
/// a raw `Data(contentsOf:)`/POSIX error, or a silent drop, reach the
/// caller.
public enum LassoSMTPAttachmentLoader {
    /// 8MB, matching lassoguide.com's/the Lasso 8.5 Language Guide's own
    /// documented ceiling for `email_send` specifically. lassoguide.com:
    /// "The maximum size of an email message including all attachments
    /// must be less than 8 MB when using the email_send method." The local
    /// Lasso 8.5 Language Guide (Ch. 47) states the identical 8MB ceiling
    /// with slightly different wording ("...using the [Email_Send] tag") —
    /// same substance, not a byte-for-byte quote match across both sources.
    /// Enforced here as a running sum across `-attachments` AND
    /// `-htmlImages` combined, matching how they actually share one
    /// message's total size.
    public static let maximumTotalBytes = 8 * 1024 * 1024

    /// A separate, explicit cap on the total number of combined
    /// `-attachments`/`-htmlImages` entries in one message, independent of
    /// the byte ceiling above — the byte ceiling alone bounds memory but
    /// not syscall/fd volume against many-small-files (opening, `fstat`ing,
    /// and reading 10,000 one-byte files would pass the byte cap easily).
    /// No confirmed real-corpus number exists to size this against (stated
    /// explicitly, not implied) — 20 is a conservative, reasonable-looking
    /// number for a real marketing/transactional email (a handful of
    /// attachments plus a few inline images), well above anything the
    /// worked examples in either doc source show (one or two), and well
    /// below anything that would turn a single `email_send` call into a
    /// meaningful syscall-amplification vector.
    public static let maximumFileCount = 20

    /// Resolves every pending attachment/inline image against `siteRoot`,
    /// enforcing containment, regular-file-type, and the combined byte/count
    /// ceilings — throws `LassoSMTPError(kind: .attachmentFailed)` (or
    /// `.invalidParameter` for a malformed pending value) on any failure,
    /// never partially returns a truncated result.
    ///
    /// - Parameters:
    ///   - siteRoot: The site's document root — same value `main.swift`
    ///     passes to `LassoFileSystemIncludeLoader`/
    ///     `LassoFileSystemUploadProcessor` (`config.siteRoot`).
    public static func resolve(
        attachments: [LassoSMTPPendingAttachment],
        inlineImages: [LassoSMTPPendingInlineImage],
        siteRoot: URL
    ) throws -> (attachments: [Attachment], inlineImages: [InlineResource]) {
        let resolvedRoot = siteRoot.standardizedFileURL.resolvingSymlinksInPath()
        var totalBytes = 0
        var totalCount = 0

        func checkCount() throws {
            totalCount += 1
            guard totalCount <= maximumFileCount else {
                throw LassoSMTPError(
                    kind: .attachmentFailed,
                    message: "email_send: more than \(maximumFileCount) combined -attachments/-htmlImages entries in one message is not supported."
                )
            }
        }

        func checkBytes(_ added: Int) throws {
            totalBytes += added
            guard totalBytes <= maximumTotalBytes else {
                throw LassoSMTPError(
                    kind: .attachmentFailed,
                    message: "email_send: combined -attachments/-htmlImages size exceeds the \(maximumTotalBytes)-byte (8MB) ceiling."
                )
            }
        }

        var resolvedAttachments: [Attachment] = []
        resolvedAttachments.reserveCapacity(attachments.count)
        for pending in attachments {
            try checkCount()
            let filename: String
            let data: Data
            switch pending {
            case .data(let fn, let d):
                filename = fn
                data = d
            case .path(let relativePath):
                filename = basename(relativePath)
                data = try loadFile(relativePath: relativePath, siteRoot: resolvedRoot, maxBytes: maximumTotalBytes - totalBytes)
            }
            try checkBytes(data.count)
            resolvedAttachments.append(Attachment(filename: filename, contentType: contentType(forFilename: filename), data: data))
        }

        var resolvedInline: [InlineResource] = []
        resolvedInline.reserveCapacity(inlineImages.count)
        for pending in inlineImages {
            try checkCount()
            let contentID: String
            let filename: String
            let data: Data
            switch pending {
            case .data(let cid, let d):
                contentID = cid
                filename = cid
                data = d
            case .path(let cid, let relativePath):
                contentID = cid
                filename = basename(relativePath)
                data = try loadFile(relativePath: relativePath, siteRoot: resolvedRoot, maxBytes: maximumTotalBytes - totalBytes)
            }
            try checkBytes(data.count)
            resolvedInline.append(InlineResource(contentID: contentID, filename: filename, contentType: contentType(forFilename: filename), data: data))
        }

        return (resolvedAttachments, resolvedInline)
    }

    // MARK: - Path resolution / containment

    /// Reimplementation of `main.swift`'s `isWithinRoot`/`fileURL(for:)`
    /// candidate-resolution shape — see the file doc comment for why this
    /// can't just call that code directly.
    static func resolveContained(relativePath: String, siteRoot: URL) throws -> URL {
        // Defense in depth, not a closed exploit: `withCString` (in
        // `loadFile` below) truncates at the first NUL byte, which could
        // in principle let a NUL-containing relativePath diverge from what
        // this Swift-level containment check just validated. No known path
        // gets a NUL byte into this string today, but rejecting it
        // outright is free and removes the question entirely.
        guard relativePath.contains("\0") == false else {
            throw LassoSMTPError(
                kind: .attachmentFailed,
                message: "email_send: attachment path contains an invalid character."
            )
        }
        let candidate = siteRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = siteRoot.path.hasSuffix("/") ? siteRoot.path : siteRoot.path + "/"
        guard candidate.path == siteRoot.path || candidate.path.hasPrefix(rootPath) else {
            throw LassoSMTPError(
                kind: .attachmentFailed,
                message: "email_send: attachment path '\(relativePath)' resolves outside the site root."
            )
        }
        return candidate
    }

    // MARK: - TOCTOU-safe regular-file read

    /// Opens, `fstat`s (on the open descriptor, not the path string again),
    /// verifies regular-file-type and the per-call remaining byte budget,
    /// then reads — see the file doc comment for the full TOCTOU rationale.
    static func loadFile(relativePath: String, siteRoot: URL, maxBytes: Int) throws -> Data {
        let resolved = try resolveContained(relativePath: relativePath, siteRoot: siteRoot)
        // O_NONBLOCK here is load-bearing, not an optimization: opening a
        // FIFO for reading WITHOUT it blocks the calling thread until some
        // other process opens the same FIFO for writing -- i.e. `open`
        // itself hangs, before this function ever reaches the fstat check
        // below that's supposed to reject named pipes. With O_NONBLOCK, a
        // read-only FIFO open returns immediately regardless of whether a
        // writer exists (POSIX), so `fstat` gets a chance to see S_IFIFO
        // and reject it through the normal error path instead of hanging
        // the whole call. Has no effect on regular-file reads (the only
        // case that reaches the `read` loop below), so it's safe to set
        // unconditionally rather than only for the FIFO case.
        let fd = resolved.path.withCString { open($0, O_RDONLY | O_NONBLOCK) }
        guard fd >= 0 else {
            throw LassoSMTPError(
                kind: .attachmentFailed,
                message: "email_send: attachment file not found or unreadable: '\(relativePath)'."
            )
        }
        defer { close(fd) }

        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0 else {
            throw LassoSMTPError(
                kind: .attachmentFailed,
                message: "email_send: could not stat attachment file '\(relativePath)'."
            )
        }
        guard (statInfo.st_mode & S_IFMT) == S_IFREG else {
            throw LassoSMTPError(
                kind: .attachmentFailed,
                message: "email_send: attachment path '\(relativePath)' is not a regular file (named pipes/devices/directories are rejected)."
            )
        }
        let size = Int(statInfo.st_size)
        guard size >= 0, size <= max(0, maxBytes) else {
            // Deliberately doesn't include the file's exact byte size here
            // (unlike an earlier draft) -- `-attachments`/`-htmlImages`
            // let a caller name any file under siteRoot, and echoing back
            // its precise size once the running budget is tight enough to
            // trip on it is a narrow but real information-disclosure
            // oracle main.swift's equivalent (`fileURL(for:)`) doesn't have
            // for the analogous case.
            throw LassoSMTPError(
                kind: .attachmentFailed,
                message: "email_send: attachment '\(relativePath)' exceeds the remaining combined 8MB attachment/inline-image budget."
            )
        }

        guard size > 0 else { return Data() }

        var buffer = [UInt8](repeating: 0, count: size)
        var totalRead = 0
        var readFailed = false
        buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while totalRead < size {
                let n = read(fd, base.advanced(by: totalRead), size - totalRead)
                if n < 0 {
                    readFailed = true
                    break
                }
                if n == 0 { break } // EOF earlier than fstat's reported size (file shrank concurrently) -- treated as a short read below, not looped forever.
                totalRead += n
            }
        }
        guard readFailed == false else {
            throw LassoSMTPError(
                kind: .attachmentFailed,
                message: "email_send: failed reading attachment file '\(relativePath)'."
            )
        }
        return Data(buffer[0..<totalRead])
    }

    // MARK: - Filename / content-type helpers (pure, no I/O)

    /// Last path component, no directories — matches lassoguide.com's own
    /// documented `-htmlImages` Content-ID derivation ("automatically uses
    /// the image file name as the Content-ID without any path
    /// information") and doubles as the attachment display filename for
    /// the path variant. `public` so `LassoSMTPMessageBuilder` (pure string
    /// logic, no I/O — permitted there) can reuse it for the
    /// `-htmlImages` path-variant Content-ID instead of duplicating this
    /// exact logic.
    public static func basename(_ path: String) -> String {
        guard let lastSeparator = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else {
            return path
        }
        return String(path[path.index(after: lastSeparator)...])
    }

    /// Neither `email_send`'s `-attachments` nor `-htmlImages` accept a
    /// per-entry MIME-type override (confirmed against both doc sources —
    /// only the unrelated `email_compose->addAttachment(-type=?)` companion
    /// method does), so this loader infers `Content-Type` from the
    /// filename's extension. A small, deliberately non-exhaustive table
    /// covering the file types most plausible for real attachments/inline
    /// images (documents, archives, common image formats, structured
    /// text); anything else falls back to `application/octet-stream` — the
    /// standard "type genuinely unknown" MIME default (RFC 2046 §4.5.1),
    /// not a guess specific to this adapter.
    private static let extensionContentTypes: [String: String] = [
        "txt": "text/plain",
        "html": "text/html",
        "htm": "text/html",
        "csv": "text/csv",
        "json": "application/json",
        "xml": "application/xml",
        "pdf": "application/pdf",
        "zip": "application/zip",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "svg": "image/svg+xml",
    ]

    static func contentType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard ext.isEmpty == false else { return "application/octet-stream" }
        return extensionContentTypes[ext] ?? "application/octet-stream"
    }
}

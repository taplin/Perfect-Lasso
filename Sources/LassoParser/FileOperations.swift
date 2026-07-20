import Foundation

/// `File_*` free tags (Lasso 8.5 Language Guide Ch. 31 "Files", Table 1
/// "File Tags") — read/write/inspect files on the same machine as Lasso
/// Service. Real Lasso gates every file operation behind a four-tier Site
/// Administration permission model (tag enablement, per-tag permission,
/// per-action permission, an "Allow Path" root, and a file-suffix
/// allowlist — Ch. 31 "Security"); this codebase has no user/permission/
/// Site-Administration concept at all, so the only security boundary
/// implemented here is path confinement to the SAME root
/// `include()`/`library()` are already confined to
/// (`LassoIncludeLoader.fileSystemRoot`, `Providers.swift`) — deliberately
/// reusing that one root rather than inventing a second, independently-
/// configured one. No file-suffix allowlist is enforced by default,
/// mirroring `LassoFileSystemIncludeLoader`'s own established precedent
/// (its own doc comment: "an extension allowlist was never real Lasso
/// behavior" for `include()`; there's no real-corpus evidence here to
/// justify hardcoding Ch. 31's specific default suffix list either, and a
/// wrong hardcoded list would silently reject legitimate file operations
/// with no way to configure around it).
///
/// Deliberately scoped to the 13 tags below plus `File_CurrentError`;
/// explicitly NOT implemented this stage (disclosed, not silently
/// dropped): `File_ReadLine`/`File_GetLineCount`/`File_ProbeEOL` (line-
/// oriented reading — needs end-of-line-character detection this batch
/// doesn't build), `File_SetSize`/`File_Chmod`/`File_StreamCopy`
/// (lower-value/more niche per the gap-analysis doc's own prioritization),
/// and the entire object-oriented `[File]`/`[Directory]` native-type
/// wrapper Ch. 31 documents as an alternative to this free-tag family —
/// the Guide's own words, "the same things... using an object-oriented
/// methodology" — a distinct, separately-scoped follow-up.
///
/// Fully-qualified paths that escape the confined root entirely (Mac OS
/// X's `///`-prefixed absolute-filesystem paths, Windows' `C://`-prefixed
/// drive paths) are Ch. 31's own documented way to reach files OUTSIDE
/// the Web serving root — i.e. they're explicitly an escape hatch from
/// the exact confinement this implementation relies on as its only
/// security boundary. Not supported: a bare `/`-prefixed path is always
/// resolved root-relative, matching the "Absolute Paths" behavior only.
enum LassoFileOperations {
    /// Real Lasso's File Errors (Appendix A "Error Codes", Table 1,
    /// p.824) — verified against the PDF directly (`pdftotext -layout`,
    /// since the raw text extraction interleaves the code/message
    /// columns unreadably). Named for exactly the failure mode each
    /// registration below actually needs to report; the remaining
    /// documented File Error codes (-9970 through -9982, -9986, -9988)
    /// have no call site here yet since nothing implemented this stage
    /// exercises them (e.g. no open-file-handle concept exists to need
    /// "-9972 File is closed"). `File_ProcessUploads` (`Runtime.swift`,
    /// registered separately, predates this file) also sets
    /// `kind: "file"` errors, but with ad hoc placeholder codes
    /// (2001-2003) rather than real Appendix A numbers — the two ranges
    /// don't currently collide, but any future code branching on
    /// `kind == "file"` and assuming an Appendix A code should be aware
    /// those placeholders exist.
    enum ErrorCode {
        static let couldNotRead = -9968
        static let couldNotWrite = -9969
        static let invalidPathname = -9977
        static let fileAlreadyExists = -9983
        static let unauthorizedOrNotFound = -9984
        static let couldNotDelete = -9985
        static let couldNotCreate = -9987
        static let generic = -9990
    }

    static func fail(_ context: inout LassoContext, code: Int, message: String) {
        context.setError(LassoErrorState(code: code, message: message, kind: "file"))
    }

    static func succeed(_ context: inout LassoContext) {
        context.clearError()
    }

    /// Path resolution/root-confinement shared by every registration
    /// below — reimplements (can't directly call, since that method is
    /// `private` to `LassoFileSystemIncludeLoader`)
    /// `LassoFileSystemIncludeLoader.resolvedCandidateURL`'s policy: try
    /// relative-to-the-current-page first, then relative-to-root,
    /// matching Ch. 31's own "Relative Paths"/"Absolute Paths"
    /// distinction. Differs from that method in three ways: no
    /// extension allowlist (see this file's own top-level doc comment
    /// for why); a base that fails confinement is skipped in favor of
    /// trying the next base rather than throwing immediately (each
    /// candidate is still independently confinement-checked before
    /// acceptance, so this isn't a security difference, just a
    /// resolution-order one); and it doesn't require the target to
    /// already exist (`File_Create`/`File_Write` need to resolve a path
    /// for something that doesn't exist yet — see
    /// `resolvedExistingAncestor` below for how that path stays
    /// confined despite the target itself not existing).
    static func resolvedURL(for path: String, context: LassoContext) throws -> URL {
        guard let root = context.includeLoader?.fileSystemRoot else {
            throw LassoRuntimeError.fileSystemNotConfigured
        }
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var bases: [URL] = [root]
        if !path.hasPrefix("/"), let includingPath = context.includePath {
            let normalizedIncludingPath = includingPath.hasPrefix("/")
                ? String(includingPath.dropFirst())
                : includingPath
            let parent = URL(fileURLWithPath: normalizedIncludingPath, relativeTo: root)
                .deletingLastPathComponent()
            bases.insert(parent, at: 0)
        }
        for base in bases {
            let candidate = base.appendingPathComponent(normalizedPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard isWithinRoot(candidate, root: root) else { continue }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Nothing existing matched — return the root-relative candidate
        // anyway (for `File_Create`/`File_Write`'s benefit), still
        // confinement-checked via `resolvedExistingAncestor` below —
        // NOT plain `.resolvingSymlinksInPath()`, which (confirmed
        // empirically, this isn't documented anywhere clearly enough to
        // trust blind) does NOT resolve a real, already-existing
        // intermediate directory symlink when the final path component
        // doesn't exist yet. Without walking up to an existing ancestor
        // first, a symlink planted inside root pointing outside it (e.g.
        // `root/evil -> /etc`) would pass confinement on the UNRESOLVED
        // lexical path (`<root>/evil/passwd` textually starts with
        // root's own path) while `File_Write` actually wrote through the
        // symlink to the real, unconfined target — the OS follows
        // intermediate-directory symlinks regardless of the final
        // component's existence.
        let candidate = try resolvedExistingAncestor(of: root.appendingPathComponent(normalizedPath))
        guard isWithinRoot(candidate, root: root) else {
            throw LassoRuntimeError.unsafeDynamicFieldName(path)
        }
        return candidate
    }

    /// Walks up from `url` until it finds an ancestor directory that
    /// actually exists (worst case, `root` itself, which always does),
    /// resolves symlinks on THAT ancestor (safe: `resolvingSymlinksInPath()`
    /// correctly follows symlinks for path components that exist), then
    /// re-appends the non-existent trailing components verbatim. This is
    /// what actually closes the intermediate-symlink confinement gap
    /// `resolvedURL`'s own doc comment above describes.
    private static func resolvedExistingAncestor(of url: URL) throws -> URL {
        var trailingComponents: [String] = []
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent != current else {
                throw LassoRuntimeError.unsafeDynamicFieldName(url.path)
            }
            trailingComponents.append(current.lastPathComponent)
            current = parent
        }
        let resolvedAncestor = current.resolvingSymlinksInPath()
        return trailingComponents.reversed().reduce(resolvedAncestor) { $0.appendingPathComponent($1) }
    }

    private static func isWithinRoot(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    /// True when `url` resolves to the confined root itself — an empty,
    /// `"."`, or `"/"` path all resolve here via `resolvedURL`'s own
    /// logic (a directory always exists, so it satisfies both the
    /// existing-file loop and `isWithinRoot`'s own `candidate.path ==
    /// root.path` case trivially). Reading/listing the root is
    /// legitimate and documented (`File_ListDirectory: '/'`, Ch. 31
    /// p.432's own worked example) — this helper exists specifically so
    /// the destructive registrations below (`file_delete`, and
    /// `file_move`/`file_rename`'s SOURCE) can reject operating on the
    /// root itself as their own targeted guard, not something
    /// `resolvedURL` should refuse universally.
    private static func isRoot(_ url: URL, root: URL) -> Bool {
        url.standardizedFileURL.path == root.path
    }

    /// Confines `newName` (`File_Rename`'s destination, documented as a
    /// bare name rather than a path — but untrusted input regardless)
    /// to `root`, resolved against `parent` and walked up to an existing
    /// ancestor exactly like `resolvedURL`'s own not-yet-existing-target
    /// branch, so a `newName` containing `../` traversal — or an
    /// intermediate symlink — can't escape the confined root either.
    private static func confinedDestination(name: String, in parent: URL, root: URL) throws -> URL {
        let candidate = parent.appendingPathComponent(name).standardizedFileURL
        let resolved = try resolvedExistingAncestor(of: candidate)
        guard isWithinRoot(resolved, root: root), !isRoot(resolved, root: root) else {
            throw LassoRuntimeError.unsafeDynamicFieldName(name)
        }
        return resolved
    }

    static func registerDefaultFunctions(into registry: inout LassoNativeRegistry) {
        registry.register("file_exists") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            do {
                let url = try resolvedURL(for: path, context: context)
                succeed(&context)
                return .boolean(FileManager.default.fileExists(atPath: url.path))
            } catch {
                fail(&context, code: ErrorCode.unauthorizedOrNotFound, message: "Unauthorized file suffix or file not found.")
                return .boolean(false)
            }
        }
        registry.register("file_isdirectory") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            do {
                let url = try resolvedURL(for: path, context: context)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    succeed(&context)
                    return .boolean(false)
                }
                succeed(&context)
                return .boolean(isDirectory.boolValue)
            } catch {
                fail(&context, code: ErrorCode.unauthorizedOrNotFound, message: "Unauthorized file suffix or file not found.")
                return .boolean(false)
            }
        }
        registry.register("file_getsize") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            guard let url = try? resolvedURL(for: path, context: context),
                  let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
                fail(&context, code: ErrorCode.unauthorizedOrNotFound, message: "Unauthorized file suffix or file not found.")
                return .integer(0)
            }
            succeed(&context)
            return .integer(size)
        }
        registry.register("file_creationdate") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            guard let url = try? resolvedURL(for: path, context: context),
                  let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date else {
                fail(&context, code: ErrorCode.unauthorizedOrNotFound, message: "Unauthorized file suffix or file not found.")
                return .null
            }
            succeed(&context)
            return .object(LassoDateParsing.makeObject(LassoDateComponents(date: date)))
        }
        registry.register("file_moddate") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            guard let url = try? resolvedURL(for: path, context: context),
                  let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
                fail(&context, code: ErrorCode.unauthorizedOrNotFound, message: "Unauthorized file suffix or file not found.")
                return .null
            }
            succeed(&context)
            return .object(LassoDateParsing.makeObject(LassoDateComponents(date: date)))
        }
        registry.register("file_read") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            do {
                let url = try resolvedURL(for: path, context: context)
                let contents = try String(contentsOf: url, encoding: .utf8)
                succeed(&context)
                // `-FileStartPos`/`-FileEndPos` (Table 1) define an
                // optional character-range read; both are 0-based offsets
                // per the Guide's own phrasing ("the range of characters").
                guard let start = arguments.lastInt(named: "filestartpos") else { return .string(contents) }
                let characters = Array(contents)
                let clampedStart = max(0, min(start, characters.count))
                let end = arguments.lastInt(named: "fileendpos").map { min($0, characters.count) } ?? characters.count
                guard clampedStart < end else { return .string("") }
                return .string(String(characters[clampedStart..<end]))
            } catch {
                fail(&context, code: ErrorCode.couldNotRead, message: "Could not read from file.")
                return .void
            }
        }
        registry.register("file_write") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            let data = arguments.positionalValue(at: 1)?.outputString ?? ""
            do {
                let url = try resolvedURL(for: path, context: context)
                if arguments.hasTruthyFlag("fileoverwrite") || !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    // `FileHandle.write(_:)` (the non-throwing overload)
                    // raises an uncatchable Objective-C exception on
                    // failure (disk full, quota exceeded, EPIPE) rather
                    // than a Swift error the surrounding `catch` below
                    // can see — `write(contentsOf:)` is the throwing
                    // equivalent, required so a real write failure
                    // degrades to `File_CurrentError` like every other
                    // failure mode here instead of crashing the process.
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    try handle.write(contentsOf: Data(data.utf8))
                }
                succeed(&context)
                return .void
            } catch {
                fail(&context, code: ErrorCode.couldNotWrite, message: "Could not write to file.")
                return .void
            }
        }
        registry.register("file_create") { arguments, context in
            // "If the file name ends in a / then a directory is created."
            let path = arguments.first?.value.outputString ?? ""
            let isDirectory = path.hasSuffix("/")
            do {
                let url = try resolvedURL(for: path, context: context)
                if isDirectory {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    let overwrite = arguments.hasTruthyFlag("fileoverwrite")
                    guard overwrite || !FileManager.default.fileExists(atPath: url.path) else {
                        fail(&context, code: ErrorCode.fileAlreadyExists, message: "File already exists.")
                        return .void
                    }
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        fail(&context, code: ErrorCode.couldNotCreate, message: "Could not create or open file.")
                        return .void
                    }
                }
                succeed(&context)
                return .void
            } catch {
                fail(&context, code: ErrorCode.couldNotCreate, message: "Could not create or open file.")
                return .void
            }
        }
        registry.register("file_delete") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            do {
                guard let root = context.includeLoader?.fileSystemRoot else {
                    throw LassoRuntimeError.fileSystemNotConfigured
                }
                let url = try resolvedURL(for: path, context: context)
                // An empty/"."/"/" path resolves to the confined root
                // itself via `resolvedURL`'s own logic (a directory
                // always exists) — `removeItem` on a directory recurses,
                // so without this guard a blank/unset `File_Delete`
                // argument (e.g. `File_Delete($_POST('filename'))` with
                // no field submitted) would recursively delete the
                // entire confined site root in one call.
                guard !isRoot(url, root: root) else {
                    fail(&context, code: ErrorCode.invalidPathname, message: "Invalid pathname.")
                    return .void
                }
                try FileManager.default.removeItem(at: url)
                succeed(&context)
                return .void
            } catch {
                fail(&context, code: ErrorCode.couldNotDelete, message: "Could not delete file.")
                return .void
            }
        }
        registry.register("file_listdirectory") { arguments, context in
            let path = arguments.first?.value.outputString ?? ""
            guard let url = try? resolvedURL(for: path, context: context) else {
                fail(&context, code: ErrorCode.unauthorizedOrNotFound, message: "Unauthorized file suffix or file not found.")
                return .array([])
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                fail(&context, code: ErrorCode.unauthorizedOrNotFound, message: "Unauthorized file suffix or file not found.")
                return .array([])
            }
            succeed(&context)
            // Directory entries get a trailing "/" — confirmed by the
            // Guide's own worked example ("Images/", "Lasso/").
            let entries = names.sorted().map { name -> LassoValue in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
                return .string(isDirectory.boolValue ? name + "/" : name)
            }
            return .array(entries)
        }
        registry.register("file_copy") { arguments, context in
            let source = arguments.positionalValue(at: 0)?.outputString ?? ""
            let destination = arguments.positionalValue(at: 1)?.outputString ?? ""
            do {
                guard let root = context.includeLoader?.fileSystemRoot else {
                    throw LassoRuntimeError.fileSystemNotConfigured
                }
                let sourceURL = try resolvedURL(for: source, context: context)
                let destinationURL = try resolvedURL(for: destination, context: context)
                // A blank/"."/"/" `destination` resolves to the confined
                // root itself (it always exists) — without this guard,
                // an ordinary `-FileOverwrite` on that destination would
                // recursively delete the entire confined root via
                // `removeItem` below before the copy even runs (found by
                // a second review pass, same bug class already fixed for
                // `file_delete`/`file_move`'s source/`file_rename`).
                guard !isRoot(destinationURL, root: root) else {
                    fail(&context, code: ErrorCode.invalidPathname, message: "Invalid pathname.")
                    return .void
                }
                let overwrite = arguments.hasTruthyFlag("fileoverwrite")
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    guard overwrite else {
                        fail(&context, code: ErrorCode.fileAlreadyExists, message: "File already exists.")
                        return .void
                    }
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                succeed(&context)
                return .void
            } catch {
                fail(&context, code: ErrorCode.generic, message: "File error.")
                return .void
            }
        }
        registry.register("file_move") { arguments, context in
            let source = arguments.positionalValue(at: 0)?.outputString ?? ""
            let destination = arguments.positionalValue(at: 1)?.outputString ?? ""
            do {
                guard let root = context.includeLoader?.fileSystemRoot else {
                    throw LassoRuntimeError.fileSystemNotConfigured
                }
                let sourceURL = try resolvedURL(for: source, context: context)
                guard !isRoot(sourceURL, root: root) else {
                    fail(&context, code: ErrorCode.invalidPathname, message: "Invalid pathname.")
                    return .void
                }
                let destinationURL = try resolvedURL(for: destination, context: context)
                // Same root-destination guard as `file_copy` above — see
                // its own comment for why this matters with
                // `-FileOverwrite`.
                guard !isRoot(destinationURL, root: root) else {
                    fail(&context, code: ErrorCode.invalidPathname, message: "Invalid pathname.")
                    return .void
                }
                let overwrite = arguments.hasTruthyFlag("fileoverwrite")
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    guard overwrite else {
                        fail(&context, code: ErrorCode.fileAlreadyExists, message: "File already exists.")
                        return .void
                    }
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                succeed(&context)
                return .void
            } catch {
                fail(&context, code: ErrorCode.generic, message: "File error.")
                return .void
            }
        }
        registry.register("file_rename") { arguments, context in
            // "Renames a file or directory. Accepts two parameters, the
            // location... and the new name" — the second parameter is
            // documented as just a NAME, not a full path, so it's
            // resolved against the source's own parent directory rather
            // than root/current-page like `->Move`'s destination — but
            // it's still untrusted input, and `confinedDestination`
            // still confinement-checks it (a `newName` containing `../`
            // traversal, or an intermediate symlink, could otherwise
            // escape the confined root entirely with no special
            // conditions needed).
            let source = arguments.positionalValue(at: 0)?.outputString ?? ""
            let newName = arguments.positionalValue(at: 1)?.outputString ?? ""
            do {
                guard let root = context.includeLoader?.fileSystemRoot else {
                    throw LassoRuntimeError.fileSystemNotConfigured
                }
                let sourceURL = try resolvedURL(for: source, context: context)
                guard !isRoot(sourceURL, root: root) else {
                    fail(&context, code: ErrorCode.invalidPathname, message: "Invalid pathname.")
                    return .void
                }
                let destinationURL = try confinedDestination(
                    name: newName,
                    in: sourceURL.deletingLastPathComponent(),
                    root: root
                )
                let overwrite = arguments.hasTruthyFlag("fileoverwrite")
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    guard overwrite else {
                        fail(&context, code: ErrorCode.fileAlreadyExists, message: "File already exists.")
                        return .void
                    }
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                succeed(&context)
                return .void
            } catch {
                fail(&context, code: ErrorCode.generic, message: "File error.")
                return .void
            }
        }
        registry.register("file_currenterror") { arguments, context in
            arguments.hasTruthyFlag("errorcode")
                ? .integer(context.currentError.code)
                : .string(context.currentError.message)
        }
    }
}

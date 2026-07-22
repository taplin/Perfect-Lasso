import Foundation

public struct LassoStartupLoadFailure: Sendable, Equatable {
    public let file: String
    public let error: String

    public init(file: String, error: String) {
        self.file = file
        self.error = error
    }
}

public struct LassoStartupLoadResult: Sendable, Equatable {
    public let loadedFiles: [String]
    public let failedFiles: [LassoStartupLoadFailure]

    public init(loadedFiles: [String], failedFiles: [LassoStartupLoadFailure]) {
        self.loadedFiles = loadedFiles
        self.failedFiles = failedFiles
    }
}

/// Loads every matching-extension file in a directory once, in the same
/// spirit as a real Lasso instance auto-loading its `LassoStartup` folder
/// at launch: each file is parsed and rendered (its text output discarded —
/// startup files aren't meant to produce visible content, only register
/// `define`d tags/types), sharing one `LassoTagRegistry` so everything
/// registered here stays available to every request the server later
/// serves. Unlike `library()`, this isn't lazy or per-path-cached — it's
/// meant to run exactly once, synchronously, before a server starts
/// accepting connections.
///
/// A file that fails to parse or render is recorded in the result rather
/// than thrown — real startup folders can contain a mix of syntax this
/// interpreter doesn't support yet (legacy `define_tag`, for example), and
/// one such file shouldn't prevent every other file in the folder from
/// loading.
public func loadLassoStartupDirectory(
    at directory: URL,
    allowedExtensions: Set<String>,
    tagRegistry: LassoTagRegistry
) async -> LassoStartupLoadResult {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        return LassoStartupLoadResult(
            loadedFiles: [],
            failedFiles: [LassoStartupLoadFailure(
                file: directory.path,
                error: "not a directory or does not exist"
            )]
        )
    }

    let normalizedExtensions = Set(allowedExtensions.map { $0.lowercased() })
    guard let loader = try? LassoFileSystemIncludeLoader(root: directory, allowedExtensions: normalizedExtensions) else {
        return LassoStartupLoadResult(
            loadedFiles: [],
            failedFiles: [LassoStartupLoadFailure(
                file: directory.path,
                error: "could not construct an include loader for this directory"
            )]
        )
    }

    let entries = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []

    let files = entries
        .filter { !$0.hasDirectoryPath }
        .filter { normalizedExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    return await renderEachOnce(files, loader: loader, tagRegistry: tagRegistry, namePrefix: "")
}

/// Renders each file once (output discarded, failures recorded rather than
/// thrown) sharing one `tagRegistry` — the loop `loadLassoStartupDirectory`/
/// `loadLassoApps` both need, factored out so the per-app case below can
/// reuse it exactly instead of duplicating the do/catch bookkeeping.
/// `namePrefix` lets a caller qualify each reported file name (e.g. with its
/// app's own name) without needing a second result shape.
private func renderEachOnce(
    _ files: [URL],
    loader: LassoIncludeLoader,
    tagRegistry: LassoTagRegistry,
    namePrefix: String
) async -> LassoStartupLoadResult {
    var loaded: [String] = []
    var failed: [LassoStartupLoadFailure] = []

    for file in files {
        let reportedName = namePrefix + file.lastPathComponent
        do {
            let source = try String(contentsOf: file, encoding: .utf8)
            var context = LassoContext(
                includeLoader: loader,
                includePath: file.lastPathComponent,
                tagRegistry: tagRegistry
            )
            _ = try await LassoRenderer().render(source, context: &context)
            loaded.append(reportedName)
        } catch {
            failed.append(LassoStartupLoadFailure(file: reportedName, error: String(describing: error)))
        }
    }

    return LassoStartupLoadResult(loadedFiles: loaded, failedFiles: failed)
}

/// Loads every installed LassoApp's `_init*.lasso` files once, in the same
/// spirit as `loadLassoStartupDirectory` but scoped to the narrower
/// "library" use of LassoApps this adapter supports — no node/resource
/// tree, no `/lasso9/AppName/...` HTTP routing, no content-representation
/// objects (LassoGuide's "Operations > LassoApps" chapter; that full
/// system has no evidenced need across any corpus this project has seen).
/// What real LassoApps use for exactly this purpose ("LassoApp Concepts" >
/// "Customizing Initialization"): "LassoApps can contain a special set of
/// files that are executed every time the LassoApp is loaded... named
/// beginning with '_init.' ... Only initialization files at the root of
/// the LassoApp are executed" — real corpus: zeroloop/ds (a commonly-used
/// third-party datasource-abstraction LassoApp seen live in TS_lasso9 and,
/// separately, in the "scrubs" corpus) ships exactly one `_init.lasso`
/// that loops over its own sibling files via `lassoapp_include`.
///
/// `at` is the directory conventionally named "LassoApps" — each of ITS
/// immediate subdirectories is one installed app, keyed by folder name
/// (hidden/dot-prefixed entries skipped). Every `_init*.lasso` file
/// directly inside an app's own folder (non-recursive, matching real
/// Lasso's "only initialization files at the root" rule) is rendered
/// once, in `localizedStandardCompare` order, with `lassoapp_include`
/// (aliased to `include`'s existing mechanism in `Renderer.swift`)
/// resolving relative to that SAME app's own folder — never another
/// app's, and never the site's own root — via a dedicated
/// `LassoFileSystemIncludeLoader` built fresh per app. One `tagRegistry`
/// is shared across every app (and the site's own `LassoStartup` folder,
/// if both are loaded), matching how real Lasso 9 exposes every loaded
/// app's `define`d types/tags process-wide, not sandboxed per app.
public func loadLassoApps(
    at directory: URL,
    tagRegistry: LassoTagRegistry
) async -> LassoStartupLoadResult {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        return LassoStartupLoadResult(
            loadedFiles: [],
            failedFiles: [LassoStartupLoadFailure(
                file: directory.path,
                error: "not a directory or does not exist"
            )]
        )
    }

    let entries = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []

    // `URL.hasDirectoryPath` doesn't reliably resolve symlinks (a symlink
    // TO a directory can report `false`) — a real deployment commonly
    // symlinks an app's folder in from elsewhere, so this needs the same
    // `fileExists(atPath:isDirectory:)` filesystem check (follows
    // symlinks) `LassoFileSystemIncludeLoader.init` already uses, not the
    // lexical URL property.
    let appDirectories = entries
        .filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        .filter { !$0.lastPathComponent.hasPrefix(".") }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    var loaded: [String] = []
    var failed: [LassoStartupLoadFailure] = []

    for appDirectory in appDirectories {
        let appName = appDirectory.lastPathComponent
        guard let loader = try? LassoFileSystemIncludeLoader(root: appDirectory) else {
            failed.append(LassoStartupLoadFailure(
                file: appName,
                error: "could not construct an include loader for this app's directory"
            ))
            continue
        }

        let appEntries = (try? FileManager.default.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let initFiles = appEntries
            .filter { !$0.hasDirectoryPath }
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasPrefix("_init") && name.hasSuffix(".lasso")
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let result = await renderEachOnce(initFiles, loader: loader, tagRegistry: tagRegistry, namePrefix: "\(appName)/")
        loaded.append(contentsOf: result.loadedFiles)
        failed.append(contentsOf: result.failedFiles)
    }

    return LassoStartupLoadResult(loadedFiles: loaded, failedFiles: failed)
}

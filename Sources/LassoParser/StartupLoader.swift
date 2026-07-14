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

    var loaded: [String] = []
    var failed: [LassoStartupLoadFailure] = []

    for file in files {
        do {
            let source = try String(contentsOf: file, encoding: .utf8)
            var context = LassoContext(
                includeLoader: loader,
                includePath: file.lastPathComponent,
                tagRegistry: tagRegistry
            )
            _ = try await LassoRenderer().render(source, context: &context)
            loaded.append(file.lastPathComponent)
        } catch {
            failed.append(LassoStartupLoadFailure(file: file.lastPathComponent, error: String(describing: error)))
        }
    }

    return LassoStartupLoadResult(loadedFiles: loaded, failedFiles: failed)
}

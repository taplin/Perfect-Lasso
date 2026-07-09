import Foundation

public struct LassoCustomTagDefinition: Sendable {
    public let name: String
    public let parameters: [LassoArgument]
    public let body: [LassoNode]

    public init(name: String, parameters: [LassoArgument], body: [LassoNode]) {
        self.name = name
        self.parameters = parameters
        self.body = body
    }
}

private struct LassoCachedInclude {
    let source: String
    let document: LassoDocument
}

/// Shared, thread-safe store for compiled custom tags, the set of libraries
/// already loaded, and parsed include documents. A single instance can be
/// handed to every `LassoContext` a server process constructs so tags
/// compile once and stay callable for the lifetime of the process, not just
/// one request.
public final class LassoTagRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [String: LassoCustomTagDefinition] = [:]
    private var loadedLibraries: Set<String> = []
    private var includeCache: [String: LassoCachedInclude] = [:]

    public init() {}

    public func registerTag(_ definition: LassoCustomTagDefinition) {
        lock.lock()
        defer { lock.unlock() }
        tags[definition.name.lowercased()] = definition
    }

    public func tag(named name: String) -> LassoCustomTagDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return tags[name.lowercased()]
    }

    public func containsTag(named name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tags[name.lowercased()] != nil
    }

    /// Returns `true` the first time a given path is seen, meaning the
    /// caller should load and process it. Returns `false` on every
    /// subsequent call for the same path — already cached, nothing to do.
    @discardableResult
    public func markLibraryLoaded(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedLibraries.insert(path).inserted
    }

    /// Unlike a library, an include can produce output on every use, so it
    /// can't simply be marked "processed" once. Instead the caller always
    /// reads the source (the only way to detect a change, since
    /// `LassoIncludeLoader` exposes no separate staleness signal) and hands
    /// it here — a matching `source` to what's cached means the file hasn't
    /// changed since last use, so the caller can skip re-parsing and reuse
    /// the cached document, re-rendering it fresh for this call site.
    public func cachedInclude(forKey key: String, matchingSource source: String) -> LassoDocument? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = includeCache[key], cached.source == source else { return nil }
        return cached.document
    }

    public func cacheInclude(forKey key: String, source: String, document: LassoDocument) {
        lock.lock()
        defer { lock.unlock() }
        includeCache[key] = LassoCachedInclude(source: source, document: document)
    }
}

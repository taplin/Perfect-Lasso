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

/// Shared, thread-safe store for compiled custom tags and parsed include
/// documents. A single instance can be handed to every `LassoContext` a
/// server process constructs so tags compile once and stay callable for the
/// lifetime of the process, not just one request.
///
/// Deliberately does NOT track which `library()` paths have been loaded —
/// per LassoSoft's own `library_once`/`[Library_Once]` documentation, that
/// dedup is scoped to a single page's own render ("if used multiple times
/// referencing the same Lasso page then only the first will actually
/// perform the include"), not to the server process's lifetime. That
/// per-request set lives on `LassoContext` instead (see `loadedLibraries`
/// there) — keeping it here made a file's top-level executable code (e.g.
/// a bot-exclusion check at the top of `_begin.lasso`) run only once, ever,
/// for the whole server process, silently no-opping on every later request.
public final class LassoTagRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [String: LassoCustomTagDefinition] = [:]
    private var types: [String: LassoTypeDefinition] = [:]
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

    public func registerType(_ definition: LassoTypeDefinition) {
        lock.lock()
        defer { lock.unlock() }
        types[definition.name.lowercased()] = definition
    }

    public func type(named name: String) -> LassoTypeDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return types[name.lowercased()]
    }

    public func containsType(named name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return types[name.lowercased()] != nil
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

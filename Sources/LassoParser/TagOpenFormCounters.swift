import Foundation

/// Identity of one recognized open-form event: which tag, opened which way.
/// Per-tag, not per-form-globally — the real question fire-counts answer is
/// "is THIS tag's colon-call still used," not "are colon-calls used
/// anywhere," so the two must stay distinguishable in the aggregate.
public struct TagOpenFormFire: Hashable, Sendable {
    public let tagName: String
    public let form: TagOpenForm

    public init(tagName: String, form: TagOpenForm) {
        self.tagName = tagName
        self.form = form
    }
}

/// A cross-request, process-lifetime sink for tag-open-form recognition
/// counts (Phase 3 of tag-form consolidation). Pluggable and optional
/// exactly like `LassoContext`'s other dependencies (`includeLoader`,
/// `sessionProvider`, `responseSink`, `tagRegistry`).
///
/// Deliberately exposes only a batch `merge(_:)`, not a per-match
/// `record(tag:form:)`, as its write API: incrementing a shared, locked
/// table on every single tag match would serialize otherwise-independent
/// concurrent requests at the exact point real corpus rendering hits most
/// often. Recognition sites accumulate into a local, unsynchronized
/// per-parse dictionary instead (see `ScriptBodyParser.openFormFires`),
/// which folds up through nested parses/includes/libraries into one
/// per-request total; only that per-request total is ever merged into this
/// shared store, once, at the end of a successful render.
public protocol TagOpenFormCounterStore: AnyObject, Sendable {
    func merge(_ counts: [TagOpenFormFire: Int])
    func snapshot() -> [TagOpenFormFire: Int]
}

/// Zero-cost default: every method is inert. This is what runs whenever
/// fire-count instrumentation isn't explicitly enabled, so the feature costs
/// nothing in the common case.
public final class NoOpTagOpenFormCounterStore: TagOpenFormCounterStore, Sendable {
    public init() {}
    public func merge(_ counts: [TagOpenFormFire: Int]) {}
    public func snapshot() -> [TagOpenFormFire: Int] { [:] }
}

/// Real counting store. Concurrency model copied from `LassoTagRegistry`
/// (`TagRegistry.swift`) — this codebase's established cross-request
/// shared-mutable precedent — not from `ServerResponseSink`, whose
/// `@unchecked Sendable` safety argument is scoped to one request at a time
/// and does not transfer to a table every concurrent request writes into.
public final class CountingTagOpenFormCounterStore: TagOpenFormCounterStore, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [TagOpenFormFire: Int] = [:]

    public init() {}

    public func merge(_ counts: [TagOpenFormFire: Int]) {
        guard !counts.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (fire, count) in counts {
            table[fire, default: 0] += count
        }
    }

    public func snapshot() -> [TagOpenFormFire: Int] {
        lock.lock()
        defer { lock.unlock() }
        return table
    }
}

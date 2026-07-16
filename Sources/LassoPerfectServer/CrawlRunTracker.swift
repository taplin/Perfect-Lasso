import Foundation

/// Tracks the in-progress/last-completed state of the admin console's
/// crawl-report action, so `LassoAdminDelegate.availableActions()` can show
/// live status ("Running now — 340/1,989 pages, started 2m ago" or
/// "Last run: 1,943 clean, 46 failing (finished 11:04 AM)") on the action's
/// chip instead of a static description, and so `executeAction` can reject
/// a second crawl while one is already running.
///
/// `tryBegin()` is the only way `isRunning` flips to `true` — actor
/// serialization makes the check-and-set atomic, so two near-simultaneous
/// `POST /api/actions` calls can't both start a crawl.
actor CrawlRunTracker {
    private(set) var isRunning = false
    private var startedAt: Date?
    private var completed = 0
    private var total = 0
    private var lastSummary: String?

    /// Returns `true` and marks a crawl as started if none is currently
    /// running; returns `false` (leaving state untouched) if one already is.
    @discardableResult
    func tryBegin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        startedAt = Date()
        completed = 0
        total = 0
        return true
    }

    /// Called from `CrawlReport.run`'s `onProgress` callback as pages finish.
    func progress(_ completed: Int, _ total: Int) {
        self.completed = completed
        self.total = total
    }

    func finish(summary: String) {
        isRunning = false
        lastSummary = summary
    }

    /// A human-readable status line for the crawl-report action's
    /// description — `fallback` is the static, no-crawl-yet description.
    func statusDescription(fallback: String) -> String {
        if isRunning {
            let elapsed = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let progressText = total > 0 ? "\(completed)/\(total) pages" : "starting…"
            return "Running now — \(progressText), started \(elapsed)s ago."
        }
        if let lastSummary {
            return lastSummary
        }
        return fallback
    }
}

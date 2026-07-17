import Foundation

/// Guards the admin console's "restart-server" action against two
/// near-simultaneous triggers racing each other into two concurrent
/// process spawns. Mirrors `CrawlRunTracker`'s `tryBegin()`/reset shape —
/// actor serialization makes the check-and-set atomic.
actor RestartCoordinator {
    private(set) var isRestarting = false

    @discardableResult
    func tryBegin() -> Bool {
        guard !isRestarting else { return false }
        isRestarting = true
        return true
    }

    /// Called on any failure path so a bad attempt doesn't permanently
    /// wedge the action — the next click should be able to try again.
    func reset() {
        isRestarting = false
    }
}

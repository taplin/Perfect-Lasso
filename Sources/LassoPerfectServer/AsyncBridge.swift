import Dispatch

/// Bridges an `async` call to a synchronous caller. See
/// `Documentation/synchronous-render-pipeline.md` for the full context —
/// this project's render pipeline (`LassoRenderer`, `LassoInlineProvider`,
/// `LassoDynamicQueryExecutor`) is entirely synchronous by design, but a
/// datasource's real API can be `async` (the resurrected `Perfect-FileMaker`
/// replaced its blocking transport with `URLSession`'s `async`/`await`).
///
/// **This function alone is NOT safe to call from a thread that belongs
/// to Swift's cooperative executor pool** — see `runBlockingOffCooperativePool`,
/// which every caller of this function must already be running inside
/// of. `DispatchQueue.sync` (used internally below) blocks the CALLING
/// thread for the operation's full duration; it does not free that
/// thread while its closure runs elsewhere. If the caller is itself a
/// cooperative-pool thread, that block is exactly as costly to the pool
/// as calling `Task { } + semaphore.wait()` directly would be, and this
/// project confirmed by reproducing it (a 50-way concurrent
/// `withThrowingTaskGroup` test around a naive, unwrapped use of this
/// function alone hung outright) that enough concurrent callers still
/// exhausts the pool and deadlocks the whole process, not just the
/// datasource that triggered it — every route handler shares the same
/// pool. `runBlockingOffCooperativePool` is what actually keeps this
/// function's internal blocking off the cooperative pool, by ensuring
/// its caller isn't running on one to begin with.
///
/// `nonisolated(unsafe)` on the captured result is safe, not a
/// suppression: every path (`.success`/`.failure`) assigns it strictly
/// before `semaphore.signal()`, and `semaphore.wait()` establishes a
/// real happens-before edge before it's read — real synchronization the
/// compiler's region-isolation checker just can't see through
/// `DispatchSemaphore`.
func runAsyncAndWait<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let outcome: Result<T, Error> = DispatchQueue.global(qos: .userInitiated).sync {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var innerOutcome: Result<T, Error>!
        Task {
            do {
                innerOutcome = .success(try await operation())
            } catch {
                innerOutcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return innerOutcome!
    }
    return try outcome.get()
}

/// The other, necessary half of the fix `runAsyncAndWait` alone doesn't
/// provide — see that function's doc comment and
/// `Documentation/synchronous-render-pipeline.md` for the full story.
///
/// The actual fix has to happen above the leaf datasource call: the
/// synchronous render itself (`LassoRenderer().render(...)`, called from
/// `LassoSiteServer.render`) — not just a FileMaker/MySQL leaf call
/// inside it — must never run directly on a cooperative-pool thread.
/// This function moves `work` onto a `libdispatch` global concurrent
/// queue (a separate, elastic pool, same as `runAsyncAndWait`'s), but
/// critically, the calling `Task` `await`s a checked continuation
/// rather than blocking — a genuine suspension point that hands the
/// cooperative-pool thread back to the scheduler for other work while
/// `work` runs. Once `work` completes and resumes the continuation, the
/// caller's `Task` is rescheduled onto a cooperative-pool thread again
/// to continue — but critically, no cooperative-pool thread sits
/// idle-and-blocked for the render's duration, so the pool can never be
/// exhausted by concurrent requests the way a directly-blocking bridge
/// would exhaust it.
///
/// With this wrapping the whole render, `runAsyncAndWait`'s own internal
/// blocking — which still happens, unchanged, inside `work` — now
/// happens on a `libdispatch` worker thread (itself dispatched from
/// `work`'s own `libdispatch` thread, not a cooperative-pool one), so it
/// can no longer contribute to cooperative-pool exhaustion either.
func runBlockingOffCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

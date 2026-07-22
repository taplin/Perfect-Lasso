// Regression coverage for `@concurrent` on
// `PerfectCRUDLassoExecutor.execute(_:)` (Phase 2 of the MySQL-offload work
// tracked alongside `Documentation/synchronous-render-pipeline.md`'s
// successor plan).
//
// `queryHandler`/`mutationHandler`/`rawSQLHandler` wrap `PerfectCRUD`/
// `PerfectMySQL` calls, which are genuinely blocking — there's no async API
// to bridge to. Without offloading, a slow query would block whichever
// actor's executor called `execute(_:)` (e.g. a MainActor request handler),
// stalling every other unit of work on that actor for the query's duration.
// `@concurrent` fixes this by moving `execute(_:)` itself onto the
// concurrent thread pool, off the caller's executor, regardless of what
// actor the caller is isolated to.
//
// This is worth pinning down with a real test rather than trusting the
// annotation:
//
// `@concurrent` on a protocol-conformance method is easy to get wrong
// silently — the method still type-checks and satisfies
// `LassoDynamicQueryExecutor` whether or not the offload actually happens at
// runtime, since the protocol requirement itself is plain `nonisolated
// async throws`. Per SE-0461, `@concurrent` forces the offload
// unconditionally, independent of whether the target enables the
// `ApproachableConcurrency` upcoming feature (which changes a plain
// `nonisolated async` function's *default* to stay on the caller's actor
// instead of hopping off). This test target (`LassoParserTests`) already
// enables `ApproachableConcurrency` (see `Package.swift`) — so
// `concurrentAttributeOffloadsBlockingWork` passing here is itself proof
// that `@concurrent` holds regardless of that flag, not evidence that it
// depends on the flag being off elsewhere.
//
// Two tests cover this:
//  - `concurrentAttributeOffloadsBlockingWork`: one blocking call doesn't
//    stall a single MainActor caller (heartbeat-starvation check).
//  - `manyConcurrentExecuteCallsRunInParallel`: many simultaneous slow
//    calls complete in roughly the time of one, not N times that — i.e.
//    they genuinely run in parallel on the offload pool rather than
//    serializing there.

import Foundation
import Testing
import LassoParser
import LassoPerfectCRUD
import PerfectCRUD

/// `Thread.current` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — it can't be
/// referenced directly inside an `async` function body. Wrapping the read in
/// an ordinary synchronous function sidesteps that (the property access
/// itself happens in a non-async frame); callers just invoke this from
/// async code as a plain synchronous call.
private func currentThreadSync() -> Thread {
    Thread.current
}

@MainActor
private final class HeartbeatMonitor {
    private(set) var ticks = 0
    private(set) var running = true

    func stop() { running = false }

    func startHeartbeat() {
        Task { @MainActor in
            while self.running {
                self.ticks += 1
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
            }
        }
    }
}

@Test @MainActor func concurrentAttributeOffloadsBlockingWork() async throws {
    let monitor = HeartbeatMonitor()
    monitor.startHeartbeat()

    // Give the heartbeat a moment to start ticking before we block.
    try await Task.sleep(nanoseconds: 20_000_000) // 20ms

    let recordedThreads = ThreadRecorder()

    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, _, _ in
            recordedThreads.record(callingThread: Thread.current)
            // Simulate a blocking PerfectMySQL call.
            Thread.sleep(forTimeInterval: 0.3)
            return DynamicResult(rows: [], statement: "SELECT 1 /* offload check */")
        }
    )

    let request = try LassoInlineRequest(arguments: [
        EvaluatedArgument(label: "database", value: .string("offload-check")),
        EvaluatedArgument(label: "table", value: .string("t")),
        EvaluatedArgument(label: "search", value: .boolean(true)),
    ])

    let callingThreadBeforeAwait = currentThreadSync()

    // This is the call under test. `execute` is annotated `@concurrent`.
    _ = try await executor.execute(request)

    monitor.stop()
    // Let the heartbeat loop observe `running = false` and exit.
    try await Task.sleep(nanoseconds: 10_000_000)

    let ticksDuringBlockingCall = monitor.ticks
    print("[ConcurrentOffloadTests] MainActor heartbeat ticks during ~300ms blocking execute(): \(ticksDuringBlockingCall)")
    print("[ConcurrentOffloadTests] Calling thread before await: \(callingThreadBeforeAwait)")
    print("[ConcurrentOffloadTests] Thread executing queryHandler (inside execute body): \(recordedThreads.thread!)")
    print("[ConcurrentOffloadTests] Same thread as caller? \(recordedThreads.thread === callingThreadBeforeAwait)")

    // If @concurrent genuinely offloaded the blocking work, MainActor's
    // serial executor was never occupied by it, so the heartbeat should
    // have accumulated roughly 300ms / 5ms ≈ 60 ticks (allow generous
    // slack for scheduling jitter). If the blocking work had instead run
    // on MainActor's executor, the heartbeat would be starved near 0-1.
    #expect(ticksDuringBlockingCall > 20, "Heartbeat starved — blocking work appears to have run on MainActor's executor, not offloaded.")
}

/// Proves the "many simultaneous slow-query requests no longer stall
/// unrelated request handling" requirement, not just the single-call case
/// above: fires several concurrent `execute(_:)` calls, each with its own
/// ~200ms synthetic blocking `queryHandler`, and checks they complete in
/// roughly the time of ONE call rather than N times that. If `@concurrent`
/// only moved work off the *caller's* executor but every call still
/// serialized on some shared resource, this would take ~N × 200ms instead.
@Test func manyConcurrentExecuteCallsRunInParallel() async throws {
    let singleCallDuration: TimeInterval = 0.2 // 200ms
    let concurrentCallCount = 10

    let executor = PerfectCRUDLassoExecutor(
        capabilities: { _, _ in .readOnly },
        queryHandler: { _, _, _ in
            // Simulate a blocking PerfectMySQL call.
            Thread.sleep(forTimeInterval: singleCallDuration)
            return DynamicResult(rows: [], statement: "SELECT 1 /* concurrent-load check */")
        }
    )

    func makeRequest() throws -> LassoInlineRequest {
        try LassoInlineRequest(arguments: [
            EvaluatedArgument(label: "database", value: .string("concurrent-load-check")),
            EvaluatedArgument(label: "table", value: .string("t")),
            EvaluatedArgument(label: "search", value: .boolean(true)),
        ])
    }

    let start = Date()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<concurrentCallCount {
            group.addTask {
                _ = try await executor.execute(try makeRequest())
            }
        }
        try await group.waitForAll()
    }
    let elapsed = Date().timeIntervalSince(start)

    print("[ConcurrentOffloadTests] \(concurrentCallCount) concurrent ~\(Int(singleCallDuration * 1000))ms execute() calls completed in \(String(format: "%.3f", elapsed))s")

    // Generous tolerance (not N×) to absorb scheduling jitter and machines
    // with fewer cores than `concurrentCallCount` — the point is ruling out
    // gross serialization, not asserting perfect parallelism. `Thread.sleep`
    // in `queryHandler` blocks a pool thread without yielding, so the real
    // completion time is roughly `ceil(concurrentCallCount / coreCount) ×
    // singleCallDuration` — on a 4-core machine that's already ~3×, leaving
    // no margin at a strict 3× tolerance; 4× keeps a real margin down to
    // ~3-4 cores while still failing loudly on genuine serialization (which
    // would be ~10×).
    let serializedDuration = singleCallDuration * Double(concurrentCallCount)
    let tolerance = singleCallDuration * 4
    #expect(
        elapsed < tolerance,
        "Expected \(concurrentCallCount) concurrent execute() calls to complete in roughly one call's duration (~\(singleCallDuration)s, allowing up to \(tolerance)s), but took \(elapsed)s — close to the fully-serialized \(serializedDuration)s, suggesting calls are serializing instead of running in parallel."
    )
}

private final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _thread: Thread?

    var thread: Thread? {
        lock.lock()
        defer { lock.unlock() }
        return _thread
    }

    func record(callingThread: Thread) {
        lock.lock()
        _thread = callingThread
        lock.unlock()
    }
}

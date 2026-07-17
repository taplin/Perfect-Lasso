import Foundation

/// Supports the admin console's "restart-server" action: resolving this process's
/// own executable, spawning a fresh copy of it, and confirming — from the *new*
/// process's own stdout, not an external port probe — that it genuinely bound and
/// started serving before anything touches the old process.
///
/// A port probe can't do this reliably once `Server.alwaysReusePort` is in play:
/// during the brief window both processes are bound, an ordinary HTTP request to
/// the shared port could be routed by the kernel to either one, so "something
/// answered" doesn't prove the *new* process specifically came up. Watching for the
/// literal `"Listening: http://localhost:"` line `main.swift` prints only from
/// inside `Server.withServer`'s post-bind callback sidesteps that ambiguity
/// entirely — that line can only exist if the new process really bound.
enum RestartReadiness {

    /// Detects a complete line starting with a given prefix across a stream of
    /// arbitrarily-sized chunks (`Pipe`/`FileHandle` deliver bytes, not lines, so a
    /// marker can legitimately split across two reads). A pure, deterministic type
    /// with no process/IO involved — this is the unit-tested surface of this file.
    struct MarkerScanner {
        private var buffer = ""

        /// Feeds a freshly-read chunk in; returns `true` the first time a complete
        /// (newline-terminated) line starting with `markerPrefix` has been seen.
        /// A prefix match on the still-buffered, not-yet-terminated tail doesn't
        /// count — only a confirmed complete line does.
        mutating func feed(_ chunk: String, markerPrefix: String) -> Bool {
            buffer += chunk
            let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.dropLast() where line.hasPrefix(markerPrefix) {
                return true
            }
            buffer = String(lines.last ?? "")
            return false
        }
    }

    enum Outcome: Sendable {
        case healthy(pid: Int32)
        case failed(String)
    }

    /// Resolves this process's own executable to an absolute path, so a restart can
    /// re-launch the exact same binary regardless of how it was originally invoked:
    /// an already-absolute argv[0], a path relative to the launch directory (how
    /// every server in this project has been started this session, e.g.
    /// `.build/out/Products/Debug/lasso-perfect-server`), or a bare command name
    /// resolved via `$PATH` (a systemd-style `ExecStart=lasso-perfect-server` unit).
    /// Returns `nil` rather than guessing if none of these resolve to something
    /// executable.
    static func resolveOwnExecutablePath(
        argv0: String,
        currentDirectoryPath: String,
        pathEnvironment: String?,
        fileManager: FileManager = .default
    ) -> String? {
        func isExecutable(_ path: String) -> Bool {
            fileManager.isExecutableFile(atPath: path)
        }
        if argv0.hasPrefix("/") {
            return isExecutable(argv0) ? argv0 : nil
        }
        if argv0.contains("/") {
            let joined = (currentDirectoryPath as NSString).appendingPathComponent(argv0)
            return isExecutable(joined) ? joined : nil
        }
        guard let pathEnvironment else { return nil }
        for dir in pathEnvironment.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(argv0)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Spawns a fresh copy of `executablePath` with `environment` (so it re-reads
    /// every config file fresh, including any edits made since the current process
    /// started), then races: the new process's stdout producing the readiness
    /// marker, vs. it terminating early, vs. a bounded timeout. Whichever resolves
    /// first wins; the stdout drain itself keeps running for the process's entire
    /// remaining lifetime regardless (not just until the marker appears) — an
    /// unread pipe eventually fills its buffer and blocks any later, unrelated
    /// `print()` in the child, silently wedging it.
    static func spawnAndAwaitHealthy(
        executablePath: String,
        environment: [String: String],
        markerPrefix: String,
        timeout: Duration = .seconds(10)
    ) async -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.environment = environment
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // standardError left unset (inherits the parent's) so the new process's own
        // startup errors stay visible wherever the parent's stderr already goes.

        do {
            try process.run()
        } catch {
            return .failed("Could not launch new instance: \(error)")
        }

        let box = OutcomeBox()

        Task.detached {
            var scanner = MarkerScanner()
            let handle = outPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break } // EOF: the process exited, stdout closed.
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                if scanner.feed(chunk, markerPrefix: markerPrefix) {
                    await box.resolve(.healthy(pid: process.processIdentifier))
                }
            }
        }

        process.terminationHandler = { exited in
            Task {
                await box.resolve(.failed(
                    "New instance exited before becoming healthy (status \(exited.terminationStatus))."
                ))
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            await box.resolve(.failed("New instance did not become healthy within \(timeout)."))
        }

        let outcome = await box.wait()
        timeoutTask.cancel()
        if case .failed = outcome {
            // Closes the pipe as a side effect, letting the still-running drain
            // task above hit EOF and finish on its own.
            await terminate(process)
        }
        return outcome
    }

    /// `SIGTERM` first, escalating to `SIGKILL` after a short grace period, and
    /// only returns once the process has actually exited. This matters more than a
    /// fire-and-forget `terminate()` would: since `Server.alwaysReusePort` lets a
    /// second process share the port, an undead child left running after a *failed*
    /// handoff would keep a live slot in the kernel's reuseport group and silently
    /// swallow a share of new connections against a process that never responds —
    /// exactly the inconsistent-serving state graceful restart exists to prevent,
    /// now caused by a failed handoff instead of a successful one.
    private static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 { // ~2s grace period, checked every 100ms
            if !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// A single-resolution event box: the first `resolve(_:)` call wins, every caller
/// of `wait()` — whether before or after resolution — sees that same outcome.
/// Deliberately not a `withThrowingTaskGroup` race over the stdout-draining task
/// directly: `FileHandle.availableData` is a blocking call with no cancellation
/// awareness, so cancelling that task wouldn't actually stop it until the pipe
/// next produces data or closes — which, in the failure path, only happens once
/// the process is terminated. Routing termination through this box's outcome
/// (resolved by whichever signal — marker, early exit, or timeout — comes first)
/// avoids that structural deadlock entirely.
private actor OutcomeBox {
    private var outcome: RestartReadiness.Outcome?
    private var waiters: [CheckedContinuation<RestartReadiness.Outcome, Never>] = []

    func resolve(_ new: RestartReadiness.Outcome) {
        guard outcome == nil else { return }
        outcome = new
        for waiter in waiters { waiter.resume(returning: new) }
        waiters.removeAll()
    }

    func wait() async -> RestartReadiness.Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

import LassoParser
import PerfectSessionCore

/// Describes what the server boundary should do with one named session's
/// tracker cookie after a request finishes rendering — a plain data result
/// from `PerfectBackedLassoSessionProvider.finalize()` so the actual
/// `LassoResponseSink.setCookie` call stays in `LassoPerfectServer`, which
/// already owns the HTTP response.
public struct LassoSessionFinalizeAction: Sendable {
    public let call: LassoSessionStartCall
    /// The token to write into `_LassoSessionTracker_<name>` — nil means
    /// "don't set a cookie" (either `useCookie` is false, or the session
    /// was ended and should be cleared instead).
    public let token: String?
    public let shouldClearCookie: Bool

    public init(call: LassoSessionStartCall, token: String?, shouldClearCookie: Bool) {
        self.call = call
        self.token = token
        self.shouldClearCookie = shouldClearCookie
    }
}

/// Bridges Lasso's now-fully-async evaluator onto `PerfectSessionCore.
/// SessionDriver` (also async) — `start(session:call:)` does the real
/// create/resume work directly, in place, exactly when `session_start` is
/// evaluated. See `LassoSessionProvider`'s 2026-07-18 doc comment for why
/// this replaced an earlier parse-time-preflight-then-sync-render design:
/// that design predated the evaluator's async conversion by three days and
/// nobody revisited it once the "evaluator is sync" premise it was built on
/// went away.
///
/// One instance is constructed fresh per request (matching how
/// `ServerResponseSink`/`ServerRequestProvider` are also per-request) — it
/// is not a long-lived shared object. `finalize()` is still called once
/// after render completes (this server buffers the entire response body
/// before building headers, so cookies decided mid-render are never "too
/// late") to save/destroy every session actually touched and report what
/// each one's tracker cookie should become.
public final class PerfectBackedLassoSessionProvider: LassoSessionProvider, @unchecked Sendable {
    private let driver: any SessionDriver
    private let cookies: [String: String]
    private let remoteAddress: String
    private let userAgent: String

    private var loadedSessions: [String: PerfectSession] = [:]
    private var loadedCalls: [String: LassoSessionStartCall] = [:]
    private var isNewFlags: [String: Bool] = [:]
    private var restoredValues: [String: [String: LassoValue]] = [:]
    private var pendingSaveValues: [String: [String: LassoValue]] = [:]
    private var removedVarNames: [String: Set<String>] = [:]
    private var endedNames: Set<String> = []
    private var abortedNames: Set<String> = []

    public init(driver: any SessionDriver, cookies: [String: String], remoteAddress: String, userAgent: String) {
        self.driver = driver
        self.cookies = cookies
        self.remoteAddress = remoteAddress
        self.userAgent = userAgent
    }

    // MARK: - LassoSessionProvider

    /// Creates or resumes `name`'s session on first call for this request;
    /// a repeat `session_start` for the same name within the same request
    /// (real Lasso allows this) just returns the already-loaded session
    /// rather than re-fetching or re-creating it. ID lookup order: explicit
    /// `-id`, then the `_LassoSessionTracker_<name>` cookie (unless
    /// `-UseCookie` was disabled or `-UseNone` was set) — the GET/POST
    /// `-lassosession` fallback is not implemented yet (see
    /// Documentation/session-upload-support-plan.md's Milestone 4).
    public func start(session name: String, call: LassoSessionStartCall) async -> LassoSessionStartResult? {
        if let existing = loadedSessions[name] {
            return LassoSessionStartResult(sessionID: existing.token, isNew: isNewFlags[name] ?? false)
        }

        let cookieName = "_LassoSessionTracker_\(name)"
        let candidateToken = call.id ?? (call.useCookie ? cookies[cookieName] : nil)

        var session: PerfectSession
        var isNew: Bool
        if let candidateToken, call.useNone == false,
           let resumed = try? await driver.resume(token: candidateToken) {
            session = resumed
            isNew = false
        } else {
            session = await driver.create(ipaddress: remoteAddress, useragent: userAgent)
            isNew = true
        }

        loadedSessions[name] = session
        loadedCalls[name] = call
        isNewFlags[name] = isNew
        restoredValues[name] = session.data.mapValues(LassoValue.from(json:))

        return LassoSessionStartResult(sessionID: session.token, isNew: isNew)
    }

    public func id(session name: String) -> String? {
        loadedSessions[name]?.token
    }

    public func restoredValue(for varName: String, session name: String) -> LassoValue? {
        restoredValues[name]?[varName]
    }

    public func persist(_ value: LassoValue, for varName: String, session name: String) {
        pendingSaveValues[name, default: [:]][varName] = value
        removedVarNames[name]?.remove(varName)
    }

    public func removeVar(_ varName: String, session name: String) {
        pendingSaveValues[name]?[varName] = nil
        removedVarNames[name, default: []].insert(varName)
    }

    public func end(session name: String) {
        endedNames.insert(name)
    }

    public func abort(session name: String) {
        abortedNames.insert(name)
    }

    // MARK: - Async finalize (call after render)

    /// Saves/destroys every session actually started this request and
    /// reports what each one's tracker cookie should become. Ended
    /// sessions are destroyed and their cookie cleared; aborted sessions
    /// are left exactly as loaded (no save) per the documented difference
    /// between `session_end` and `session_abort` ("abort prevents saving,"
    /// it does not destroy).
    public func finalize() async -> [LassoSessionFinalizeAction] {
        var actions: [LassoSessionFinalizeAction] = []
        for (name, session) in loadedSessions {
            guard let call = loadedCalls[name] else { continue }

            if endedNames.contains(name) {
                await driver.destroy(token: session.token)
                actions.append(LassoSessionFinalizeAction(call: call, token: nil, shouldClearCookie: call.useCookie))
                continue
            }
            if abortedNames.contains(name) {
                if call.useCookie, isNewFlags[name] == true {
                    actions.append(LassoSessionFinalizeAction(call: call, token: session.token, shouldClearCookie: false))
                }
                continue
            }

            var updated = session
            for varName in removedVarNames[name] ?? [] {
                updated.data.removeValue(forKey: varName)
            }
            for (varName, value) in pendingSaveValues[name] ?? [:] {
                updated.data[varName] = value.jsonObject
            }
            updated.touch()
            await driver.save(updated)

            if call.useCookie {
                actions.append(LassoSessionFinalizeAction(call: call, token: updated.token, shouldClearCookie: false))
            }
        }
        return actions
    }
}

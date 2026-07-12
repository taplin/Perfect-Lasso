import LassoParser
import PerfectSessionCore

/// Describes what the server boundary should do with one named session's
/// tracker cookie after a request finishes rendering — a plain data result
/// from `PerfectBackedLassoSessionProvider.finalize(driver:)` so the actual
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

/// Bridges Lasso's synchronous, named-session evaluator model
/// (`LassoSessionProvider`) onto `PerfectSessionCore.SessionDriver`, which
/// is async. Real create/resume/save/destroy work happens in
/// `prepare(calls:driver:...)` (before render) and `finalize(driver:)`
/// (after render) — both async, called from `LassoPerfectServer`'s route
/// handler. Everything `LassoSessionProvider` itself exposes is synchronous
/// lookups over state `prepare` already loaded, so the (synchronous)
/// `LassoRenderer`/`Evaluator` never touches async code directly. See
/// `Documentation/session-upload-support-plan.md`'s "Session Recommendation".
///
/// One instance is constructed fresh per request (matching how
/// `ServerResponseSink`/`ServerRequestProvider` are also per-request) — it
/// is not a long-lived shared object.
public final class PerfectBackedLassoSessionProvider: LassoSessionProvider, @unchecked Sendable {
    private var loadedSessions: [String: PerfectSession] = [:]
    private var loadedCalls: [String: LassoSessionStartCall] = [:]
    private var isNewFlags: [String: Bool] = [:]
    private var restoredValues: [String: [String: LassoValue]] = [:]
    private var pendingSaveValues: [String: [String: LassoValue]] = [:]
    private var removedVarNames: [String: Set<String>] = [:]
    private var endedNames: Set<String> = []
    private var abortedNames: Set<String> = []

    public init() {}

    // MARK: - Async preflight (call before render)

    /// Creates or resumes every named session a preflight scan
    /// (`LassoSessionPreflight.scan`) found a literal `session_start` call
    /// for. `cookies` should be the incoming request's cookie map so
    /// `_LassoSessionTracker_<name>` can be used to resume, unless the call
    /// specified `-id` explicitly (which takes priority, matching the
    /// documented ID lookup order: explicit `-id`, then cookie, then
    /// GET/POST `-lassosession` — the GET/POST fallback is not implemented
    /// yet, see Documentation/session-upload-support-plan.md's Milestone 4).
    public func prepare(
        calls: [LassoSessionStartCall],
        driver: any SessionDriver,
        cookies: [String: String],
        remoteAddress: String,
        userAgent: String
    ) async {
        for call in calls {
            let cookieName = "_LassoSessionTracker_\(call.name)"
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

            loadedSessions[call.name] = session
            loadedCalls[call.name] = call
            isNewFlags[call.name] = isNew
            restoredValues[call.name] = session.data.mapValues(LassoValue.from(json:))
        }
    }

    // MARK: - LassoSessionProvider (sync, evaluator-facing)

    public func start(session name: String) -> LassoSessionStartResult? {
        guard let session = loadedSessions[name] else { return nil }
        return LassoSessionStartResult(sessionID: session.token, isNew: isNewFlags[name] ?? false)
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

    /// Saves/destroys every session `prepare` loaded and reports what each
    /// one's tracker cookie should become. Ended sessions are destroyed and
    /// their cookie cleared; aborted sessions are left exactly as loaded
    /// (no save) per the documented difference between `session_end` and
    /// `session_abort` ("abort prevents saving," it does not destroy).
    public func finalize(driver: any SessionDriver) async -> [LassoSessionFinalizeAction] {
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

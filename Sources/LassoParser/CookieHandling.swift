import Foundation

/// Shared argument-parsing and -Expires conversion for `Cookie_Set` (the
/// classic free-tag form, `Runtime.swift`'s `cookie_set` registration) and
/// `web_response->setCookie` (`NativeTypes.swift`) -- both accept the same
/// real Lasso syntax and had the identical bug before this file existed.
enum LassoCookieArguments {
    /// Real Lasso's `[Cookie_Set('Name'='Value', -Domain=..., -Path=...)]`
    /// (reference.lassosoft.com: required parameter is literally
    /// `'Cookie Name'='Cookie Value'`) passes the cookie's name and value
    /// as a SINGLE call argument whose LABEL is the name and VALUE is the
    /// value -- `Evaluator.swift`'s generic argument-evaluation already
    /// turns a bare `'literal' = value` call argument into exactly this
    /// labeled shape (its own comment even uses this exact
    /// `'active' = 'active'` corpus line as the illustrating example).
    ///
    /// Confirmed live 2026-07-18 against koi.scrubs.test: the previous
    /// implementation (checking only `-Name=`/`-Value=` labeled arguments,
    /// which real corpus never uses) instead fell through to
    /// `arguments.first?.value` for the name and `arguments.dropFirst()
    /// .first?.value` for the value -- for
    /// `Cookie_Set('verify_cookies_active'='active', -Domain='iscrubs.com')`
    /// that silently produced `Set-Cookie: active=iscrubs.com`: the
    /// cookie's real name ("verify_cookies_active") was discarded
    /// entirely, its value became the pair's OWN value ("active"), and
    /// its value was overwritten by the next argument's ("-Domain") value
    /// ("iscrubs.com") -- three real corpus files (siteconfig_cookies.inc
    /// x3, log_out.page.lasso, not_me.page.lasso, process.page.lasso(.backup))
    /// all rely on this exact pattern and were all silently broken by it.
    static func nameAndValue(from arguments: [EvaluatedArgument]) -> (name: String, value: String)? {
        // Explicit -Name=/-Value= labeled form checked FIRST since it's
        // unambiguous when present — not used anywhere in this project's
        // real corpus (which always uses the 'Name'='Value' pair-argument
        // idiom below), but pre-existing test coverage for this adapter's
        // own web_response->setCookie relies on it, and it's a
        // reasonable, explicit alternative to support regardless.
        if let name = arguments.firstValue(named: "name")?.outputString {
            let value = arguments.firstValue(named: "value")?.outputString ?? ""
            return (name, value)
        }
        let reservedFlagLabels: Set<String> = ["domain", "expires", "path", "secure", "httponly"]
        if let pair = arguments.first(where: { argument in
            guard let label = argument.label else { return false }
            return reservedFlagLabels.contains(label.lowercased()) == false
        }) {
            return (pair.label ?? "", pair.value.outputString)
        }
        // Two bare positional arguments — not used anywhere in real
        // corpus either, but a reasonable last-resort fallback rather
        // than silently no-op-ing.
        guard let name = arguments.positionalValue(at: 0)?.outputString else { return nil }
        let value = arguments.positionalValue(at: 1)?.outputString ?? ""
        return (name, value)
    }

    /// `-Expires` is documented (reference.lassosoft.com) as "the
    /// expiration time of the cookie in minutes" from now, with a
    /// negative value meaning "expire immediately" (i.e. delete the
    /// cookie) -- real corpus (log_out.page.lasso, not_me.page.lasso,
    /// process.page.lasso(.backup)) always passes `-Expires='-1'` for
    /// exactly that deletion case. `LassoResponseSink.setCookie`'s
    /// `expires` parameter is a raw string written verbatim into the
    /// `Set-Cookie` header's `Expires=` attribute (see
    /// `ServerResponseSink.setCookie` in `main.swift`), which must be an
    /// HTTP-date, not a bare number -- so this converts the documented
    /// minutes value into the same RFC 1123 date format the existing
    /// session-tracker cookie-clearing code already uses
    /// ("Thu, 01 Jan 1970 00:00:00 GMT" for the immediate-expiry case).
    /// Returns `nil` (no `Expires` attribute at all -- a real session
    /// cookie) when `-Expires` wasn't given or isn't a parseable integer,
    /// matching `siteconfig_cookies.inc`'s no-`-Expires` call, which is
    /// intentionally a session cookie.
    static func httpDateExpires(fromMinutesString minutesString: String?) -> String? {
        guard let minutesString, let minutes = Int(minutesString) else { return nil }
        let date = minutes <= 0 ? Date(timeIntervalSince1970: 0) : Date().addingTimeInterval(TimeInterval(minutes) * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

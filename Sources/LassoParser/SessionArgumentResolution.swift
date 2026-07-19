/// Shared by `SessionPreflight.swift` (parse-time, `[LassoArgument]`) and
/// `Runtime.swift`'s session natives (render-time, `[EvaluatedArgument]`) —
/// real corpus session calls overwhelmingly spell the session name as a
/// `-Name=` keyword argument (`session_start(-Name='cart', ...)`,
/// `Session_Addvar(-Name='cart', 'sort_by')`), not the positional form
/// (`session_start('cart', ...)`) both layers previously assumed
/// exclusively. One shared resolver for both argument types — matching
/// this codebase's established "one shared implementation, multiple
/// calling conventions" pattern (`LassoEncoding`, `LassoDateFormatting`) —
/// keeps the keyword-vs-positional precedence rule from drifting between
/// the two call sites. See `Documentation/outstanding-compatibility-project-plans.md`
/// item 7.
protocol LassoNamedArgument {
    var label: String? { get }
}

extension LassoArgument: LassoNamedArgument {}
extension EvaluatedArgument: LassoNamedArgument {}

/// Resolves a session-bearing native's session name from either `-Name=`
/// (the dominant real corpus shape) or the first positional argument (the
/// legacy/already-tested shape). `-Name=` wins when both are present —
/// untested by real evidence (no corpus call mixes them), but the
/// conservative choice: an explicit keyword shouldn't be silently
/// shadowed by position.
///
/// `remainingPositional` is what lets callers like `session_addvar` find
/// the *next* argument (the var name) correctly in both shapes: when the
/// name came from `-Name=`, no positional argument was consumed, so
/// `remainingPositional.first` is the var name directly
/// (`-Name='cart', 'sort_by'` → `["sort_by"]`); when the name came from
/// position 0, it's popped off first (`'cart', 'a'` → `["a"]`), matching
/// the already-tested positional behavior exactly.
func resolveSessionName<Argument: LassoNamedArgument>(
    in arguments: [Argument],
    stringValue: (Argument) -> String?
) -> (name: String, remainingPositional: [Argument])? {
    let unlabeled = arguments.filter { $0.label == nil }
    if let keywordArgument = arguments.first(where: { $0.label?.caseInsensitiveCompare("name") == .orderedSame }),
       let name = stringValue(keywordArgument), name.isEmpty == false {
        return (name, unlabeled)
    }
    guard let first = unlabeled.first, let name = stringValue(first), name.isEmpty == false else {
        return nil
    }
    return (name, Array(unlabeled.dropFirst()))
}

/// Builds a full `LassoSessionStartCall` from `session_start`'s real,
/// fully-evaluated call-site arguments — used directly by `Runtime.swift`'s
/// `session_start` registration now that session creation/resumption
/// happens in place at evaluation time, not via a parse-time preflight
/// scan (see `LassoSessionProvider`'s 2026-07-18 doc comment). Every flag
/// value here can be arbitrarily dynamic (a variable, a concatenation,
/// etc.) since `arguments` has already been evaluated by the time this
/// runs — unlike the retired scan, which could only see literal AST.
func makeSessionStartCall(from arguments: [EvaluatedArgument]) -> LassoSessionStartCall? {
    guard let resolved = resolveSessionName(in: arguments, stringValue: { $0.value.outputString }) else {
        return nil
    }
    let name = resolved.name

    func flagString(_ label: String) -> String? {
        arguments.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame })?.value.outputString
    }
    func flagInt(_ label: String) -> Int? {
        arguments.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame })?.value.number.map(Int.init)
    }
    func flagBool(_ label: String, default defaultValue: Bool) -> Bool {
        guard let argument = arguments.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame }) else {
            return defaultValue
        }
        return argument.value.isTruthy
    }

    return LassoSessionStartCall(
        name: name,
        expiresSeconds: flagInt("expires"),
        id: flagString("id"),
        useCookie: flagBool("usecookie", default: true),
        useLink: flagBool("uselink", default: false),
        useAuto: flagBool("useauto", default: false),
        useNone: flagBool("usenone", default: false),
        cookieExpires: flagString("cookieexpires"),
        domain: flagString("domain"),
        path: flagString("path"),
        secure: flagBool("secure", default: false),
        httpOnly: flagBool("httponly", default: false),
        rotate: flagBool("rotate", default: false)
    )
}

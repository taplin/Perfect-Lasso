import Foundation

/// A Lasso 9 Capture value (`https://lassoguide.com/language/captures.html`)
/// — a stored block of Lasso code that can be invoked later. See
/// `Documentation/captures-subsystem-plan.md` for the full scoping pass this
/// implements Stages 1-2 of.
///
/// **Snapshot closure semantics only** (Stage 1, unchanged) — a capture's
/// body executes against the local variables as they existed at the MOMENT
/// the capture literal was evaluated, not a live reference back to its
/// creation scope. Real Lasso's own documented semantics are live-reference
/// (the Guide's own worked example: a capture created in one method mutates
/// a local that method later reads back, after the capture is invoked from
/// a completely different method) — this codebase's `LassoContext.locals`
/// has no per-variable storage indirection anywhere (the identical
/// structural wall the `@`/`[Reference]` aliasing gap hit), so providing
/// real live-reference closures is a separate, materially larger piece of
/// work, deliberately deferred to a later stage (see the plan doc's own
/// architecture section, §4.2).
///
/// **Stage 2 adds**: non-local `return`/`yield` through a capture's home
/// (see `Evaluator.invokeCapture`/`invokeCustomTag`/`invokeMemberMethod` for
/// the propagation mechanism, and `LassoContext.nonLocalReturnTargetDepth`/
/// `currentCaptureHomeDepthStack`) and `->detach()`. **`yield` is
/// implemented identically to `return`** for this stage — real Lasso's own
/// documented PC-preserving resume behavior (a capture that reached a
/// `yield` continues executing from the point AFTER that yield on its NEXT
/// invocation, cycling through a sequence: `1, 2, 3, 4, 1, 2, 3, 4, ...`) is
/// NOT implemented — every invocation of a capture (yielded-from or not)
/// re-executes its body from the top. This would need genuine resumable
/// (coroutine-like) execution of a tree-walking render pipeline that has no
/// such capability anywhere today — a materially larger, separate piece of
/// work than the non-local-propagation mechanism this stage does implement,
/// deliberately deferred (see the plan doc's own Stage 2 status note).
/// `->home()`/`->restart()`/`->continuation()`/`->callSite_*`/
/// `->callStack()`/`currentCapture()` introspection are also deferred —
/// low corpus value, and several of them (a real home CAPTURE reference,
/// not just a depth marker) don't fit this stage's simpler `homeDepth: Int`
/// model without deeper rework.
///
/// A dedicated `LassoValue` case rather than the usual
/// `.object(LassoObjectInstance)` wrapper every other native type in this
/// codebase uses, because a capture's payload (`[LassoNode]`, a
/// captured-locals snapshot) doesn't fit `LassoObjectInstance`'s
/// `[String: LassoValue]`-only data bag — the same reason `.pair` is also
/// its own top-level `LassoValue` case instead of an `.object`. Lock-
/// protected (`@unchecked Sendable`, mirroring `LassoObjectInstance`'s own
/// pattern) since Stage 2 introduces genuine post-construction mutation
/// (`->detach()`), unlike Stage 1's fully-immutable design.
public final class LassoCaptureValue: @unchecked Sendable, Equatable {
    private let lock = NSLock()

    /// The capture's already-parsed body — produced via the same
    /// ScriptBodyParser + BlockBuilder two-pass pipeline the rest of this
    /// parser uses for every other nested block body (`define X => {...}`'s
    /// own body, if/while/loop bodies, etc.) — see
    /// `ExpressionParser.parseCaptureBody(source:autoCollect:)`.
    public let body: [LassoNode]
    /// `{^...^}` (true) vs. plain `{...}` (false) — an auto-collect
    /// capture "concatenates the result of calling the `asString` method
    /// on every value produced inside the capture... and produces that
    /// value" when invoked, instead of the plain `.void` a regular
    /// capture produces when it falls off the end without an explicit
    /// `return`.
    public let autoCollect: Bool
    /// A snapshot of the enclosing scope's local variables at the exact
    /// moment this capture literal was evaluated — Stage 1's
    /// intentionally narrower substitute for real Lasso's live-reference
    /// closure semantics (see this type's own top-level doc comment).
    public let capturedLocals: [String: LassoValue]
    /// The call-stack depth (`LassoContext.tagCallStack.count`) active
    /// WHILE the capture's creating frame was rendering its own body, at
    /// the exact moment this capture literal was evaluated — i.e. "the
    /// depth a `return`/`yield` inside this capture should unwind back
    /// down to, no matter how many frames deep this capture is later
    /// invoked from." `nil` after `->detach()` (or if a capture is ever
    /// constructed with no home at all) — a homeless/detached capture's
    /// `return`/`yield` is purely local to its own invocation, matching
    /// Ch. "Captures": "A capture can be detached from its home in order
    /// to escape from this [non-local] behavior."
    private var _homeDepth: Int?

    public init(body: [LassoNode], autoCollect: Bool, capturedLocals: [String: LassoValue], homeDepth: Int?) {
        self.body = body
        self.autoCollect = autoCollect
        self.capturedLocals = capturedLocals
        self._homeDepth = homeDepth
    }

    public var homeDepth: Int? {
        lock.lock()
        defer { lock.unlock() }
        return _homeDepth
    }

    /// "Detaches the capture so that it no longer has a home capture...
    /// After this, calling `capture->home` will return `void`." Returns
    /// self, matching the documented "detaches... and then returns
    /// itself" contract.
    @discardableResult
    public func detach() -> LassoCaptureValue {
        lock.lock()
        _homeDepth = nil
        lock.unlock()
        return self
    }

    public static func == (lhs: LassoCaptureValue, rhs: LassoCaptureValue) -> Bool {
        lhs === rhs
    }
}

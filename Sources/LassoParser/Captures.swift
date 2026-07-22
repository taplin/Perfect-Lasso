import Foundation

/// A Lasso 9 Capture value (`https://lassoguide.com/language/captures.html`)
/// — a stored block of Lasso code that can be invoked later. See
/// `Documentation/captures-subsystem-plan.md` for the full scoping pass this
/// implements Stages 1-3 of.
///
/// **Live-reference closure semantics** (Stage 3, see the plan doc's §4.2(a)
/// design decision) — a capture's body executes against the SAME storage
/// cells (`LassoLocalBox`, `Runtime.swift`) the enclosing scope's local
/// variables live in, not a value-type snapshot. Matches the Guide's own
/// canonical worked example (§1.5): a capture created in one method mutates
/// a local that method later reads back, after the capture is invoked from
/// a completely different method — this only works because
/// `capturedLocals` below holds REFERENCES to the same boxes the creating
/// scope's own `LassoContext.locals` holds, not copies of their values.
/// Stage 1's original cut used a plain value-type snapshot instead
/// (disclosed then as a deliberately narrower substitute); see
/// `LassoLocalBox`'s own doc comment for why boxing every local (not just
/// capture-adjacent ones) was the chosen fix over a scope-chain redesign
/// (§4.2(b)) — smaller blast radius, no change to this codebase's existing
/// flat-dictionary-per-call-frame scoping model.
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
/// **Stage 7 adds**: `currentCapture()`, the member-method form of
/// `->givenBlock()` (distinct from the pre-existing bare `givenBlock`
/// keyword, which reads the same underlying per-invocation state via
/// `context.currentGivenBlock`), `->restart()`, and the auto-collect
/// buffer family (`->autoCollectBuffer()`/`->autoCollectBuffer=`/
/// `->invokeAutoCollect()`). See `Evaluator.invokeCapture`/
/// `LassoContext.currentCaptureStack` for `currentCapture()`'s tracking
/// mechanism, and this type's own `_autoCollectBuffer` below.
///
/// `->home()`/`->continuation()`/`->callSite_*`/`->callStack()`/
/// `->methodName()`/`->calledName()` remain deferred — a real home
/// CAPTURE reference (not just this type's own `homeDepth: Int` marker),
/// source-location tracking on AST nodes, and an implicit per-method-
/// invocation capture object (this codebase executes method bodies
/// directly via the tree-walking evaluator, never materializing a
/// `LassoCaptureValue` for them) are all deeper architectural rework this
/// stage's own research found zero corpus evidence justifying.
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
    /// A dictionary COPY of the enclosing scope's `LassoContext.locals` at
    /// the exact moment this capture literal was evaluated — but since the
    /// dictionary's VALUES are `LassoLocalBox` object references (not
    /// plain `LassoValue`s), this shares the same live storage cells the
    /// creating scope's own locals use, giving real live-reference closure
    /// semantics "for free" from a plain dictionary copy (see this type's
    /// own top-level doc comment, and `LassoLocalBox`'s in `Runtime.swift`).
    public let capturedLocals: [String: LassoLocalBox]
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
    /// Ch. "Captures": "When you invoke an auto-collect capture, the
    /// auto-collected value will be returned and can be accessed using
    /// `capture->autoCollectBuffer`" — the worked example invokes a
    /// distance-calculating auto-collect capture, then separately reads
    /// `#distance->autoCollectBuffer` afterward and gets the SAME value
    /// back, meaning it must be retained on the capture itself after
    /// `->invoke()` returns, not just handed back as the call's own
    /// result and discarded. `.void` for a non-auto-collect capture, or
    /// before an auto-collect capture has ever been invoked (Stage 7).
    private var _autoCollectBuffer: LassoValue = .void

    public init(body: [LassoNode], autoCollect: Bool, capturedLocals: [String: LassoLocalBox], homeDepth: Int?) {
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

    public func autoCollectBuffer() -> LassoValue {
        lock.lock()
        defer { lock.unlock() }
        return _autoCollectBuffer
    }

    /// `capture->autoCollectBuffer = value` (Ch. "Captures": "can be used
    /// as the left parameter of an assignment operator" is not literally
    /// documented for this member, but the plain getter/setter pairing —
    /// `autoCollectBuffer=(value)` — is listed as its own distinct method
    /// right below the getter, so a direct write is real, documented API,
    /// not an inferred convenience).
    public func setAutoCollectBuffer(_ value: LassoValue) {
        lock.lock()
        _autoCollectBuffer = value
        lock.unlock()
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

/// Ch. "Error Handling" > "handle and handle_failure": a `handle => {...}`/
/// `handle_failure => {...}` call registers one of these against the
/// currently-active `Renderer.render(_:)` frame (see
/// `LassoContext.pendingHandlerFrames`'s own doc comment) rather than
/// invoking its capture immediately — it runs once that frame's body
/// finishes, in registration order, whether the body completed normally
/// or a thrown error unwound through it. `condition` is evaluated eagerly
/// at registration time (not lazily at drain time) — real corpus
/// (zeroloop/ds's own `_init.lasso`) never supplies one at all, so this
/// is a disclosed simplification rather than a corpus-driven choice: the
/// Guide's wording ("can take a single parameter that is a conditional
/// expression") doesn't specify eager-vs-lazy evaluation either way, and
/// eager evaluation avoids needing to snapshot/re-evaluate a raw
/// expression against a possibly-already-torn-down local scope at drain
/// time. `failureOnly` distinguishes `handle_failure` (only runs when
/// the frame actually failed) from plain `handle` (runs regardless,
/// subject only to `condition`) — otherwise identical.
struct LassoPendingHandler: Sendable {
    let condition: LassoValue
    let capture: LassoCaptureValue
    let failureOnly: Bool
}

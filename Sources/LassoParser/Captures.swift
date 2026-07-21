import Foundation

/// A Lasso 9 Capture value (`https://lassoguide.com/language/captures.html`)
/// — a stored block of Lasso code that can be invoked later. See
/// `Documentation/captures-subsystem-plan.md` for the full scoping pass this
/// implements Stage 1 of.
///
/// **Stage 1 scope, explicitly disclosed**: SNAPSHOT closure semantics only
/// — a capture's body executes against the local variables as they existed
/// at the MOMENT the capture literal was evaluated, not a live reference
/// back to its creation scope. Real Lasso's own documented semantics are
/// live-reference (the Guide's own worked example: a capture created in one
/// method mutates a local that method later reads back, after the capture
/// is invoked from a completely different method) — this codebase's
/// `LassoContext.locals` has no per-variable storage indirection anywhere
/// (the identical structural wall the `@`/`[Reference]` aliasing gap hit),
/// so providing real live-reference closures is a separate, materially
/// larger piece of work, deliberately deferred to a later stage (see the
/// plan doc's own architecture section, §4.2).
///
/// `yield`/`detach`/`restart`/non-local-return-through-nested-homes are
/// also not yet implemented — a plain `return` inside a capture's body
/// exits just that capture's own invocation, reusing the exact same
/// per-call return-signal mechanism `Evaluator.invokeCustomTag` already
/// established for custom tag bodies (see `Evaluator.invokeCapture`).
///
/// Immutable and safely `Sendable` without a lock, unlike
/// `LassoObjectInstance` (which needs one because ITS value is genuinely
/// mutated after construction, e.g. `Date->Add`'s own write-back path) —
/// a Stage 1 capture carries no mutable per-invocation state (no PC/yield
/// position) once created. A dedicated `LassoValue` case rather than the
/// usual `.object(LassoObjectInstance)` wrapper every other native type in
/// this codebase uses, because a capture's payload (`[LassoNode]`, a
/// captured-locals snapshot) doesn't fit `LassoObjectInstance`'s
/// `[String: LassoValue]`-only data bag — the same reason `.pair` is also
/// its own top-level `LassoValue` case instead of an `.object`.
public final class LassoCaptureValue: Sendable, Equatable {
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

    public init(body: [LassoNode], autoCollect: Bool, capturedLocals: [String: LassoValue]) {
        self.body = body
        self.autoCollect = autoCollect
        self.capturedLocals = capturedLocals
    }

    public static func == (lhs: LassoCaptureValue, rhs: LassoCaptureValue) -> Bool {
        lhs === rhs
    }
}

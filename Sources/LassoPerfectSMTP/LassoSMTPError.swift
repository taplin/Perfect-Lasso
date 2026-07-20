//
//  LassoSMTPError.swift
//  LassoPerfectSMTP
//
//  Error model for the `LassoEmailProvider` conformer — see
//  Documentation/lasso-perfect-smtp-integration-plan.md §2/§7. Unlike
//  `LassoPerfectFileMaker`/`LassoPerfectCRUD`, this adapter has no
//  `[inline]`-style frame to auto-populate `context.currentError` through:
//  `email_send` is a plain native function, so the ONLY way a delivery (or
//  validation) failure can be caught by Lasso code at all is
//  `LassoRecoverableError`, which `[protect]` catches (`Renderer.swift`).
//  Every expected failure mode this adapter can produce — malformed
//  dash-params, an unknown named relay, a real SMTP-level rejection —
//  is therefore modeled here and always surfaces as a thrown
//  `LassoRecoverableError`, never a silently-swallowed no-op and never an
//  uncaught raw Swift error (which would otherwise fall through to a
//  developer-error page for what might be perfectly ordinary, expected
//  failure, e.g. an invalid recipient address).
//
//  Same tone/structure as `LassoFileMakerDatabaseActionError`/
//  `LassoFileMakerActionFailureKind` (adapter-stable numeric codes, not
//  real Lasso 8.5 Error Control chapter codes — those still need
//  extracting from the local reference PDF, see `LassoErrorState`'s own
//  doc comment) even though the *mechanism* differs: FileMaker's executor
//  returns a recoverable `LassoInlineFrame`; this adapter throws
//  `LassoRecoverableError` directly, since there is no frame to return.
//

import Foundation
import LassoParser

/// Adapter-stable failure classification — NOT real Lasso 8.5 numeric
/// error codes (unresearched, see `LassoErrorState`'s doc comment). Codes
/// are chosen in the 3000s block, distinct from `LassoFileMakerActionFailureKind`'s
/// 2000s and `LassoDatabaseActionFailureKind`'s own block, so a caller
/// inspecting `error_currentError`'s numeric code can at least tell which
/// adapter a failure came from.
public enum LassoSMTPFailureKind: String, Sendable {
    /// A dash-param failed to parse (e.g. `-to`/-cc`/`-bcc` via
    /// `LassoSMTPAddressList`, or a missing required field like `-from`/
    /// `-subject`/at-least-one-body).
    case invalidParameter
    /// `-host` named a relay not present in the configured `smtp.relays`
    /// map. Never falls back to the default relay and never attempts to
    /// dial the literal string as a host — see `LassoSMTPMessageBuilder`'s
    /// doc comment for the SSRF-safe design this enforces.
    case unknownRelay
    /// A dash-param names functionality Phase A deliberately doesn't
    /// implement yet (`-date`, `-immediate=false`) — thrown rather than
    /// silently sending synchronously anyway or silently dropping the
    /// message.
    case notYetSupported
    /// `MIMEComposer`/`HeaderEncoder` rejected the message at composition
    /// time (e.g. `ComposerError.missingBody`, a header-injection
    /// rejection, a forbidden extra header) — a real, expected failure
    /// mode for malformed caller input, not an adapter bug.
    case composeFailed
    /// The message composed successfully but the transport/relay rejected
    /// or failed to deliver it — a thrown transport-level error (e.g. a
    /// `MAIL FROM` rejection, a connection failure) or a per-recipient
    /// `DeliveryResult.Outcome` that isn't `.delivered`/`.queuedForRetry`.
    case deliveryFailed
    /// `-attachments`/`-htmlImages` resolution failed (`LassoSMTPAttachmentLoader`,
    /// §4.5) — a path escaped `siteRoot`, wasn't a regular file, was
    /// missing/unreadable, or the combined byte/count ceiling was
    /// exceeded. Distinct from `.invalidParameter` because these are
    /// resolve-time (after `LassoSMTPMessageBuilder.build` already
    /// validated dash-param shape) file/security failures, not dash-param
    /// parsing failures.
    case attachmentFailed
    /// `email_mxlookup` (Phase C, §4.4) failed — every
    /// `DNSResolver.ResolveError` case (`.nullMX`/`.noRecordsFound`/
    /// `.timeout`/`.malformedResponse`/`.serverFailure`/`.cnameLoop`/
    /// `.noNameserversConfigured`) converts to this one adapter-stable
    /// kind, with a distinct, per-case message (see
    /// `LassoEmailProviderImpl.mxLookup`'s error-mapping switch) — one kind
    /// rather than seven, matching this file's existing convention of
    /// broad kinds carrying a specific message (`.deliveryFailed` already
    /// covers several distinct SMTP-level outcomes the same way).
    case mxLookupFailed
    /// `email_result()` (Phase E, §4.7/§4.7b) was called with no prior
    /// `email_send` recorded in this context — either it's genuinely the
    /// first call this request, or the most recent `email_send` failed
    /// before a job was ever recorded (a pre-send validation failure,
    /// §4.7b's job-ID scoping rule). Neither doc source describes this
    /// case, so this project's "explicit error over silent guess"
    /// discipline applies rather than returning an ambiguous `.void`.
    case noJobRecorded
    /// A deferred (`-immediate=false`/`-date`) send was rejected because
    /// too many deferred sends are already in flight (Phase E milestone
    /// review, BLOCKING FIX #1) — a pre-send validation failure, no job
    /// recorded, thrown before a background `Task` is ever spawned. See
    /// `LassoEmailProviderImpl.maxConcurrentDeferredSends`'s own doc
    /// comment for the chosen cap and reasoning.
    case tooManyDeferredSendsInFlight
    /// `-date` named a due time further in the future than this adapter
    /// allows (Phase E milestone review, BLOCKING FIX #2) — a pre-send
    /// validation failure, no job recorded. See
    /// `LassoEmailProviderImpl.maximumFutureScheduleWindow`'s own doc
    /// comment for the chosen window and reasoning.
    case dateTooFarInFuture

    var code: Int {
        switch self {
        case .invalidParameter: 3001
        case .unknownRelay: 3002
        case .notYetSupported: 3003
        case .composeFailed: 3004
        case .deliveryFailed: 3005
        case .attachmentFailed: 3006
        case .mxLookupFailed: 3007
        case .noJobRecorded: 3008
        case .tooManyDeferredSendsInFlight: 3010
        case .dateTooFarInFuture: 3011
        }
    }
}

/// Thrown internally by `LassoSMTPMessageBuilder`/`LassoSMTPMailerRegistry`/
/// `LassoEmailProviderImpl` — always caught at the `LassoEmailProviderImpl.send`
/// boundary and re-thrown as `LassoRecoverableError(state)`, never let to
/// escape as a raw Swift error to the render pipeline.
public struct LassoSMTPError: Error, Sendable {
    public let state: LassoErrorState

    public init(kind: LassoSMTPFailureKind, message: String, detail: String? = nil) {
        state = LassoErrorState(code: kind.code, message: message, kind: kind.rawValue, detail: detail)
    }
}

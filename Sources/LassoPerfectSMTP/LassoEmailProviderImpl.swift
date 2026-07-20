//
//  LassoEmailProviderImpl.swift
//  LassoPerfectSMTP
//
//  The concrete `LassoEmailProvider` conformer (§4.0 point 2) — wires
//  `LassoSMTPMessageBuilder` + `LassoSMTPMailerRegistry` together and is
//  the one place in this target that decides `email_send`'s evaluated
//  return value and how failures surface to Lasso code.
//
//  ## Return value on success
//
//  Real Lasso 8.5's `[Email_Send]` documentation states it "does not
//  return a value" (a process tag) — `.void` is the correct evaluated
//  value for a synchronous, successful send, matching the pre-existing
//  no-op stub's own return type.
//
//  ## Error propagation — this target's first real exercise of §2's
//  `LassoRecoverableError`/`[protect]` mechanism
//
//  `email_send` is a plain native function with no `[inline]`-style frame
//  to auto-populate `context.currentError` through (`LassoDynamicQueryExecutor`
//  conformers get that for free; this doesn't). The ONLY way a Lasso page
//  can catch an `email_send` failure at all is `[protect]`, which catches
//  `LassoRecoverableError` and only that (`Renderer.swift`). Concretely,
//  that means every expected failure mode below is caught here and
//  re-thrown as `LassoRecoverableError`, never left to propagate as a raw
//  Swift error (which `Renderer.swift` treats as a fatal, uncaught
//  developer-error-page condition — wrong for what might be a perfectly
//  ordinary, expected failure like an invalid recipient address) and never
//  silently swallowed into a success-shaped `.void` (which would lie about
//  whether the message actually sent):
//  - `LassoSMTPMessageBuilder.build` validation failures (malformed
//    dash-params, an unsupported param, `-immediate=false`/`-date`).
//  - `LassoSMTPAttachmentLoader.resolve(attachments:inlineImages:siteRoot:)`
//    failures (§4.5) — a path escaping `siteRoot`, a non-regular file, a
//    missing file, or the combined byte/count ceiling exceeded.
//  - `LassoSMTPMailerRegistry.mailer(named:)` throwing
//    `LassoSMTPRelayError.unknownRelay` (`-host` named a relay that isn't
//    configured).
//  - `SMTPMailer.send` itself throwing (compose-time `MIMEComposer.ComposerError`/
//    `HeaderEncoder.HeaderInjectionError`, or a transport-level failure —
//    e.g. a `MAIL FROM` rejection, a connection/pool failure).
//  - `SMTPMailer.send` returning normally but with one or more
//    per-recipient `DeliveryResult.Outcome`s that aren't
//    `.delivered`/`.queuedForRetry` (`.permanentlyFailed`/`.expired`/
//    `.ambiguous`/`.failed`) — these are real, "the message wasn't
//    actually accepted for delivery" outcomes Perfect-SMTP reports as data
//    rather than a thrown error (RCPT/DATA-phase rejections never throw —
//    see `RelayTransport.send`'s own doc comment), so this provider is
//    what turns that data into a catchable failure.
//

import Foundation
import LassoParser
import PerfectSMTP

public struct LassoEmailProviderImpl: LassoEmailProvider {
    private let registry: LassoSMTPMailerRegistry
    /// Passed straight through to `LassoSMTPAttachmentLoader.resolve` — the
    /// same value `main.swift` passes to `LassoFileSystemIncludeLoader`/
    /// `LassoFileSystemUploadProcessor` (`config.siteRoot`).
    private let siteRoot: URL

    public init(registry: LassoSMTPMailerRegistry, siteRoot: URL) {
        self.registry = registry
        self.siteRoot = siteRoot
    }

    public func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
        let built: LassoSMTPMessageBuilder.BuildResult
        do {
            built = try LassoSMTPMessageBuilder.build(arguments)
        } catch let error as LassoSMTPError {
            throw LassoRecoverableError(error.state)
        }

        var message = built.message
        do {
            let files = try LassoSMTPAttachmentLoader.resolve(
                attachments: built.pendingAttachments,
                inlineImages: built.pendingInlineImages,
                siteRoot: siteRoot
            )
            message.attachments = files.attachments
            message.inlineImages = files.inlineImages
        } catch let error as LassoSMTPError {
            throw LassoRecoverableError(error.state)
        }

        let resolved: (name: String, mailer: SMTPMailer)
        do {
            resolved = try await registry.mailer(named: built.relayName)
        } catch let error as LassoSMTPRelayError {
            throw LassoRecoverableError(relayErrorState(error))
        }

        let results: [DeliveryResult]
        do {
            results = try await resolved.mailer.send(message, bcc: built.bcc, envelopeFrom: built.envelopeFrom)
        } catch let error as MIMEComposer.ComposerError {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .composeFailed,
                message: "email_send: message composition failed (\(error)).",
                detail: String(describing: error)
            ).state)
        } catch let error as HeaderEncoder.HeaderInjectionError {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .composeFailed,
                message: "email_send: rejected header/address content (\(error)).",
                detail: String(describing: error)
            ).state)
        } catch {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .deliveryFailed,
                message: "email_send: sending through relay '\(resolved.name)' failed (\(error)).",
                detail: String(describing: error)
            ).state)
        }

        if let failure = results.first(where: { isFailureOutcome($0.outcome) }) {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .deliveryFailed,
                message: "email_send: delivery failed for \(failure.recipient) via relay '\(resolved.name)' (\(describeOutcome(failure.outcome))).",
                detail: describeOutcome(failure.outcome)
            ).state)
        }

        return .void
    }

    private func relayErrorState(_ error: LassoSMTPRelayError) -> LassoErrorState {
        switch error {
        case .unknownRelay(let name):
            LassoSMTPError(
                kind: .unknownRelay,
                message: "email_send: -host='\(name)' does not name a configured SMTP relay.",
                detail: name
            ).state
        case .unknownDefaultRelay(let name):
            LassoSMTPError(
                kind: .unknownRelay,
                message: "email_send: no default SMTP relay is configured (looked for '\(name)').",
                detail: name
            ).state
        }
    }

    /// `.delivered`/`.queuedForRetry` are both "accepted" outcomes for
    /// Phase A's purposes — real Lasso callers expect `email_send` to
    /// succeed once the message has been handed off for delivery, not to
    /// block on final recipient-side confirmation (which SMTP itself
    /// doesn't provide synchronously anyway). Every other case represents
    /// a real, non-transient (or at least not silently-retryable by this
    /// adapter, which has no retry queue) failure.
    private func isFailureOutcome(_ outcome: DeliveryResult.Outcome) -> Bool {
        switch outcome {
        case .delivered, .queuedForRetry: false
        case .permanentlyFailed, .expired, .ambiguous, .failed: true
        }
    }

    private func describeOutcome(_ outcome: DeliveryResult.Outcome) -> String {
        switch outcome {
        case .delivered(let reply): "delivered: \(reply.code)"
        case .queuedForRetry(let nextAttempt, let attempt, let last): "queuedForRetry(attempt: \(attempt), next: \(nextAttempt), last: \(last.code))"
        case .permanentlyFailed(let reply): "permanentlyFailed: \(reply.code) \(reply.lines.joined(separator: " "))"
        case .expired(let attempts, let last): "expired(attempts: \(attempts), last: \(last.code))"
        case .ambiguous(let reply): "ambiguous: \(reply.map { "\($0.code)" } ?? "no reply")"
        case .failed(let error): "failed: \(error)"
        }
    }
}

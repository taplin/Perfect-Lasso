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
import NIOCore
import NIOPosix
import PerfectSMTP

public struct LassoEmailProviderImpl: LassoEmailProvider {
    private let registry: LassoSMTPMailerRegistry
    /// Passed straight through to `LassoSMTPAttachmentLoader.resolve` — the
    /// same value `main.swift` passes to `LassoFileSystemIncludeLoader`/
    /// `LassoFileSystemUploadProcessor` (`config.siteRoot`).
    private let siteRoot: URL
    /// Backs `email_mxlookup` (Phase C, §4.4) — `nil` only in contexts that
    /// never call `mxLookup` (there is no real "email configured but MX
    /// lookup unavailable" split; `main.swift` always supplies both when it
    /// supplies this conformer at all, see that file's own doc comment for
    /// why `email_mxlookup`/`email_compose` share `email_send`'s single
    /// on/off gate). Typed as `any MXResolving`, not concretely
    /// `DNSResolver`, so tests can inject a fake — see
    /// `LassoMXLookupCache.swift`'s doc comment.
    private let mxResolver: (any MXResolving)?
    /// Backs `email_mxlookup`'s documented per-domain caching (§4.4) — one
    /// cache shared across every `email_mxlookup` call in this process's
    /// lifetime, matching `LassoSMTPMailerRegistry`'s own "built once,
    /// shared across calls" shape.
    private let mxLookupCache: LassoMXLookupCache?
    /// Backs `email_smtp` (Phase D, §4.8b) — the live-connection store
    /// keyed by object identity. Always constructible with zero external
    /// resources (unlike `mxResolver`), so this defaults to a fresh,
    /// private registry rather than being optional — every conformer gets
    /// working `email_smtp` support unless a caller has some reason to
    /// share one explicitly (`main.swift` does, so its idle-reaper `Task`
    /// sweeps the exact same registry every request's context dispatches
    /// through).
    let connectionRegistry: LassoSMTPConnectionRegistry
    /// Off-by-default operator gate for `email_smtp->open` (Phase D
    /// milestone review, BLOCKING #2) — real Lasso's own documented
    /// `email_smtp` behavior lets `->open` dial ANY literal caller-given
    /// `-host`/`-port` with zero address-routability filtering, unlike
    /// `email_send`/`email_compose`'s SSRF-safe named-relay-only design.
    /// Since this server renders arbitrary Lasso source from a site's own
    /// codebase, a compromised/malicious template author (or any template
    /// with an injection bug elsewhere) could otherwise reach internal-
    /// network addresses (e.g. `-host='169.254.169.254'`) with zero
    /// operator-facing safety gate. Mirrors this codebase's exact existing
    /// precedent for gating dangerous, low-level, opt-in-only access —
    /// `ServerConfig.mysqlAllowRawSQL` (`main.swift`) — rather than
    /// inventing a new pattern: default `false`, threaded through from
    /// `ServerConfig.smtpAllowEmailSMTP` / `LASSO_SMTP_ALLOW_EMAIL_SMTP`.
    /// See `LassoEmailSMTPType.swift`'s `smtpOpen` for the actual gate
    /// check (the one place real network dialing happens).
    let allowEmailSMTP: Bool
    /// `email_smtp->open` dials directly via `SMTPBootstrap.connect`,
    /// bypassing `LassoSMTPMailerRegistry`'s pooled, named-relay
    /// `SMTPMailer`s entirely (§4.8b: real Lasso's `email_smtp` is a raw,
    /// low-level connection type with its own caller-given host, not a
    /// selector into the operator's configured relay map) — it needs its
    /// own `EventLoopGroup` to dial on. Defaults to the same process-wide
    /// singleton `main.swift` already uses for `LassoSMTPMailerRegistry`/
    /// `DNSResolver`, so a real deployment shares one thread pool across
    /// every NIO-backed piece of this server rather than spinning up a
    /// second one just for `email_smtp`.
    let group: any EventLoopGroup

    public init(
        registry: LassoSMTPMailerRegistry,
        siteRoot: URL,
        mxResolver: (any MXResolving)? = nil,
        mxLookupCache: LassoMXLookupCache? = nil,
        connectionRegistry: LassoSMTPConnectionRegistry = LassoSMTPConnectionRegistry(),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        allowEmailSMTP: Bool = false
    ) {
        self.registry = registry
        self.siteRoot = siteRoot
        self.mxResolver = mxResolver
        self.mxLookupCache = mxLookupCache
        self.connectionRegistry = connectionRegistry
        self.group = group
        self.allowEmailSMTP = allowEmailSMTP
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

    /// Backs `email_compose` (Phase C, §4.3b) — full-message construction
    /// only (this phase's approved scoped subset), composed via
    /// `MIMEComposer(message).compose()` directly rather than
    /// `SMTPMailer.composeAndSign`. Deliberate: `email_compose` has no
    /// `-host` param and thus no way to select which configured relay's
    /// DKIM identity should sign the message — signing with an
    /// arbitrary/default relay's key for a call that names no relay at all
    /// would be a surprising, wrong choice of whose signature to attach.
    /// This is a flagged judgment call, not an oversight: `email_compose`
    /// simply never signs.
    ///
    /// Reuses `LassoSMTPMessageBuilder.build`/`LassoSMTPAttachmentLoader.resolve`
    /// unchanged — `email_compose`'s documented dash-param surface
    /// (`-to/-from/-cc/-bcc/-subject/-sender/-replyTo/-body/-html/
    /// -contentType/-characterSet/-transferEncoding/-contentDisposition/
    /// -extraMIMEHeaders/-attachments/-htmlImages`) is a strict subset of
    /// `email_send`'s (no `-host/-port/-username/-password/-immediate/
    /// -tokens/-merge`, none of which `build` requires), so the same
    /// validated pipeline applies unmodified. `build`'s own validation
    /// order (`-from` required, then `-subject` required, then at least
    /// one of `-to`/`-cc`/`-bcc` required) already throws a clear error
    /// for every part-mode-requested case (any of `-to`/`-from`/`-subject`
    /// absent) — no separate mode-detection code needed; passing
    /// `functionName: "email_compose"` only changes those three messages'
    /// wording to name the function actually called.
    public func compose(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
        let built: LassoSMTPMessageBuilder.BuildResult
        do {
            built = try LassoSMTPMessageBuilder.build(arguments, functionName: "email_compose")
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

        let composed: RFC5322Message
        do {
            composed = try MIMEComposer(message).compose()
        } catch let error as MIMEComposer.ComposerError {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .composeFailed,
                message: "email_compose: message composition failed (\(error)).",
                detail: String(describing: error)
            ).state)
        } catch let error as HeaderEncoder.HeaderInjectionError {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .composeFailed,
                message: "email_compose: rejected header/address content (\(error)).",
                detail: String(describing: error)
            ).state)
        } catch {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .composeFailed,
                message: "email_compose: message composition failed (\(error)).",
                detail: String(describing: error)
            ).state)
        }

        // Lossy-tolerant decode (never throws) -- the composed bytes are
        // MIME text (headers + a base64/quoted-printable/plain body per
        // whatever encoding was chosen), not guaranteed-clean UTF-8 in
        // every byte position (e.g. a raw base64 attachment blob is
        // ASCII-safe in practice, but there is no hard guarantee worth a
        // throwing decode here) -- matches this file's own established
        // "lossy decode for already-produced MIME/text content" precedent.
        let composedText = String(decoding: composed.serialized(), as: UTF8.self)

        // Matches `send(_:context:)`'s own recipient-assembly shape
        // (`built.bcc` is already `[String]`, per `BuildResult`'s doc
        // comment on the Bcc type-mismatch fix) -- To+Cc+Bcc combined,
        // matching the reference doc's own `email_queue(-recipients=
        // #message->recipients)` worked example, which is clearly meant to
        // be the full addressee list for the queued send, not just `-to`.
        let recipients = message.to.map(\.address) + message.cc.map(\.address) + built.bcc

        return .object(LassoObjectInstance(typeName: "email_compose", data: [
            "_data": .string(composedText),
            "_from": .string(message.from.address),
            "_recipients": .array(recipients.map { .string($0) }),
        ]))
    }

    /// Backs `email_mxlookup(domain, -refresh=?, -hostname=?)` (Phase C,
    /// §4.4). `-hostname`'s meaning is now CONFIRMED, not unconfirmed —
    /// found during the Phase C milestone review's protocol/SMTP pass:
    /// reference.lassosoft.com's `[Email_MXLookup]` page (live-fetched
    /// during review) states plainly: "Specifies which DNS host to use to
    /// look up the MX record. Defaults to the standard host for the
    /// machine." The local Lasso 8.5 Language Guide's `[Email_MXLookup]`
    /// table entry (Ch. 47/54, `References/Lasso/Lasso 8.5 Language
    /// Guide.pdf`) documents no parameters at all beyond the plain domain,
    /// and its own worked example's returned map shape (`domain`/
    /// `password`/`host`/`ssl`/`cache`/`username`/`timeout`/`route`) is the
    /// Lasso 8.5 dialect's shape (see the return-shape comment below) —
    /// `-hostname` is a Lasso-9-only addition with no 8.5 precedent, which
    /// is exactly why the 8.5 guide doesn't mention it, not evidence its
    /// meaning is unclear. What's still deferred here is purely a scope
    /// decision, not an unknown: implementing it for real would mean
    /// constructing a one-off `DNSResolver` pointed at the caller-given
    /// host and deciding how that interacts with this cache's per-domain
    /// (not per-domain-per-resolver-host) cache key — reasonable to defer
    /// past this phase, just not because the semantics are unconfirmed.
    /// `-hostname` throws `LassoSMTPFailureKind.notYetSupported` rather
    /// than being silently ignored or implemented against a half-decided
    /// cache-key design.
    public func mxLookup(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
        if arguments.firstValue(named: "hostname") != nil {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .notYetSupported,
                message: "email_mxlookup: -hostname is not yet supported (its meaning is confirmed -- which DNS host to query -- but implementing it is deferred as a scope decision for this phase); see Documentation/lasso-perfect-smtp-integration-plan.md §4.4."
            ).state)
        }
        guard let mxResolver, let mxLookupCache else {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .mxLookupFailed,
                message: "email_mxlookup: MX lookup is not available (no DNS resolver was wired for this server)."
            ).state)
        }

        let domain = arguments.positionalValue(at: 0)?.outputString ?? arguments.firstValue(named: "domain")?.outputString ?? ""
        guard domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .invalidParameter,
                message: "email_mxlookup requires a domain."
            ).state)
        }
        let refresh = arguments.hasTruthyFlag("refresh")

        let records: [DNSResolver.MXRecord]
        do {
            records = try await mxLookupCache.lookup(domain: domain, refresh: refresh, resolver: mxResolver)
        } catch let error as DNSResolver.ResolveError {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .mxLookupFailed,
                message: "email_mxlookup: \(mxLookupErrorMessage(error, domain: domain))",
                detail: String(describing: error)
            ).state)
        } catch {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .mxLookupFailed,
                message: "email_mxlookup: lookup for '\(domain)' failed (\(error)).",
                detail: String(describing: error)
            ).state)
        }

        // `resolveMX`'s own contract (`DNSResolver.swift`) guarantees
        // ascending-preference sort with equal-preference entries already
        // randomized -- taking the first element is "the most-preferred
        // record," matching this method's documented `host`/`priority`
        // shape without re-sorting.
        guard let preferred = records.first else {
            // `resolveMX` never returns an empty array without throwing
            // first (`.nullMX`/`.noRecordsFound`) -- defensive, not a
            // reachable real-world path.
            throw LassoRecoverableError(LassoSMTPError(
                kind: .mxLookupFailed,
                message: "email_mxlookup: no MX records found for '\(domain)'."
            ).state)
        }

        // Three keys (`domain`/`host`/`priority`), matching lassoguide.com's
        // own worked-example OUTPUT (`map(domain = gmail.com, host =
        // gmail-smtp-in.l.google.com, priority = 5)`) rather than that same
        // page's PROSE description ("includes the 'domain', 'host',
        // 'username', 'password', 'timeout', and 'SSL' preference").
        //
        // The Phase C milestone review's protocol/SMTP pass resolved this
        // as a version-disambiguation, not just a discrepancy to note:
        // reference.lassosoft.com's `[Email_MXLookup]` page (Lasso 8.5,
        // classic bracket-tag dialect) documents an 8-key shape
        // (`domain`/`password`/`host`/`ssl`/`cache`/`username`/`timeout`/
        // `route`) matching the local Lasso 8.5 Language Guide PDF's own
        // worked example byte-for-byte -- two independent Lasso-8.5-tagged
        // sources agree on 8 keys. lassoguide.com's 3-key worked example,
        // by contrast, is written in Lasso 9 method-call syntax
        // (`email_mxlookup(...)`, matching this codebase's implemented
        // dialect) rather than the Lasso 8.5 bracket-tag form
        // (`[Email_MXLookup: ...]`). Conclusion: 8-key = Lasso 8.5, 3-key =
        // Lasso 9, and this implementation correctly targets the 3-key
        // Lasso 9 shape it's actually implementing method-call syntax
        // for -- `username`/`password`/`timeout`/`ssl` are Lasso-8.5-only
        // keys with no meaningful value to report here anyway, for a plain
        // DNS-only lookup with no relay/credential involved at all.
        return .map([
            "domain": .string(domain),
            "host": .string(preferred.exchange),
            "priority": .integer(preferred.preference),
        ])
    }

    private func mxLookupErrorMessage(_ error: DNSResolver.ResolveError, domain: String) -> String {
        switch error {
        case .nullMX:
            "'\(domain)' publishes a null MX record (RFC 7505) -- it does not accept email."
        case .noRecordsFound:
            "no MX records found for '\(domain)'."
        case .timeout:
            "MX lookup for '\(domain)' timed out."
        case .malformedResponse:
            "the nameserver returned a malformed response for '\(domain)'."
        case .serverFailure(let rcode):
            "the nameserver returned an error response (rcode \(rcode)) for '\(domain)'."
        case .cnameLoop:
            "resolving '\(domain)' followed a CNAME chain that couldn't be safely completed."
        case .noNameserversConfigured:
            "no nameservers are configured for MX lookup."
        }
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
    /// Not `private`: reused by `LassoEmailSMTPType.swift`'s `smtpSend`
    /// (Phase D, §4.8b) — same "delivery succeeded enough to report
    /// `email_send`/`email_smtp`'s own call as successful" judgment,
    /// intentionally not duplicated.
    func isFailureOutcome(_ outcome: DeliveryResult.Outcome) -> Bool {
        switch outcome {
        case .delivered, .queuedForRetry: false
        case .permanentlyFailed, .expired, .ambiguous, .failed: true
        }
    }

    /// Not `private` — see `isFailureOutcome`'s doc comment above.
    func describeOutcome(_ outcome: DeliveryResult.Outcome) -> String {
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

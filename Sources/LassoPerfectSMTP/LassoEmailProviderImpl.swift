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
//  ## Phase E addendum (§4.7/§4.7b): job tracking, `-immediate=false`/
//  `-date`, `email_result`/`email_status`
//
//  `-immediate=false`/`-date` moved OFF the failure list above -- they're
//  real, implemented deferred-send paths now (see `send(_:context:)`'s own
//  inline comments for the full three-case design). Every failure that
//  occurs AFTER a job has been recorded (i.e. after build/attachment-
//  resolution/relay-resolution have all succeeded) is now wrapped in
//  `LassoEmailSendFailure` rather than thrown as a bare
//  `LassoRecoverableError` directly -- see that type's own doc comment
//  (`Providers.swift`) for why a job ID needs to ride along on the thrown
//  error itself for `email_result()` to remain able to retrieve it after a
//  `[protect]`-caught delivery failure. Failures that occur BEFORE a job is
//  recorded (every failure listed above this addendum) are unaffected --
//  still a bare, unwrapped `LassoRecoverableError`, matching every phase
//  before this one, since there is no job ID to carry.
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
    /// Backs `email_result`/`email_status`/`-immediate=false`/`-date`
    /// (Phase E, §4.7/§4.7b) — the job tracking layer, shared across every
    /// request this conformer serves so a job recorded by one `email_send`
    /// call is later readable by any subsequent `email_result`/
    /// `email_status` call in the same process. Always constructible with
    /// zero external resources (matching `connectionRegistry`'s own
    /// "default to a fresh, private instance" convention above) — every
    /// conformer gets working job tracking unless a caller has some reason
    /// to share one explicitly (`main.swift` does, so its periodic
    /// eviction-sweep `Task` sweeps the exact same tracker every request's
    /// context dispatches through).
    let jobTracker: LassoEmailJobTracker
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

    /// Hard cap on concurrently in-flight deferred (`-immediate=false`/
    /// `-date`) sends (Phase E milestone review, BLOCKING FIX #1) —
    /// enforced only in `send(_:context:)`'s deferred branch, via
    /// `LassoEmailJobTracker.recordQueuedIfUnderCap`, BEFORE a job is
    /// recorded and BEFORE its background `Task` is spawned. The
    /// synchronous path is never subject to this cap (it never lingers
    /// `.queued` long enough to meaningfully count — see
    /// `LassoEmailJobTracker.recordQueuedIfUnderCap`'s own doc comment).
    ///
    /// This project's own explicit judgment call — no doc source specifies
    /// a number, matching the discipline already used for
    /// `LassoEmailJobTracker`'s own TTL/hard-cap numbers. Each in-flight
    /// deferred send retains its full captured `EmailMessage` (including
    /// resolved attachment `Data`, up to `LassoSMTPAttachmentLoader.maximumTotalBytes`,
    /// 8MB) for its entire lifetime, so 1,000 concurrent in-flight caps
    /// worst-case transient memory at roughly 1,000 × 8MB ≈ 8GB — a real,
    /// enforced ceiling (versus the previous fully-unbounded exposure,
    /// which could reach hundreds of GB under an adversarial burst) while
    /// still generous enough not to reject any plausible legitimate burst
    /// of scheduled/deferred sends from ordinary corpus usage.
    ///
    /// This is the DEFAULT for `maxConcurrentDeferredSends` (the actual,
    /// per-instance cap `send(_:context:)` enforces) — a real deployment
    /// always gets this number; `init`'s own parameter exists purely so
    /// tests can inject a small cap and exercise the rejection path
    /// deterministically without spawning 1,000 real deferred sends.
    public static let defaultMaxConcurrentDeferredSends = 1_000

    /// Hard cap on how far into the future `-date` may schedule a send
    /// (Phase E milestone review, BLOCKING FIX #2) — enforced in
    /// `send(_:context:)` immediately after `-date` is parsed, before
    /// `recordQueued()`/`recordQueuedIfUnderCap()` or any Task is created.
    ///
    /// 30 days — this project's own explicitly-flagged judgment call, no
    /// real Lasso doc source specifies a queue-retention window for a
    /// scheduled send. Bounding this compounds `maxConcurrentDeferredSends`
    /// above: without it, a single scheduled `Task` could pin its captured
    /// message in memory for an arbitrarily long duration, worsening the
    /// same resource-exhaustion concern Fix #1 addresses.
    static let maximumFutureScheduleWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Per-instance cap `send(_:context:)`'s deferred branch actually
    /// enforces — defaults to `defaultMaxConcurrentDeferredSends` (the real
    /// chosen number, see that constant's own doc comment) for every real
    /// deployment; overridable only so tests can exercise the rejection
    /// path with a small cap instead of spawning 1,000 real deferred sends.
    let maxConcurrentDeferredSends: Int

    public init(
        registry: LassoSMTPMailerRegistry,
        siteRoot: URL,
        mxResolver: (any MXResolving)? = nil,
        mxLookupCache: LassoMXLookupCache? = nil,
        connectionRegistry: LassoSMTPConnectionRegistry = LassoSMTPConnectionRegistry(),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        allowEmailSMTP: Bool = false,
        maxConcurrentDeferredSends: Int = LassoEmailProviderImpl.defaultMaxConcurrentDeferredSends,
        jobTracker: LassoEmailJobTracker = LassoEmailJobTracker()
    ) {
        self.registry = registry
        self.siteRoot = siteRoot
        self.mxResolver = mxResolver
        self.mxLookupCache = mxLookupCache
        self.connectionRegistry = connectionRegistry
        self.group = group
        self.allowEmailSMTP = allowEmailSMTP
        self.maxConcurrentDeferredSends = maxConcurrentDeferredSends
        self.jobTracker = jobTracker
    }

    public func send(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoEmailSendResult {
        let built: LassoSMTPMessageBuilder.BuildResult
        do {
            built = try LassoSMTPMessageBuilder.build(arguments)
        } catch let error as LassoSMTPError {
            // Pre-send validation failure (§4.7b's job-ID scoping rule) --
            // no job is ever recorded for this, so this throws the plain
            // `LassoRecoverableError` unchanged, exactly as every phase
            // before this one did. `Runtime.swift`'s `email_send` wrapper
            // only special-cases `LassoEmailSendFailure`; anything else
            // (like this) propagates untouched, leaving
            // `context.lastEmailJobID` at whatever it was before this call.
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
            // Also pre-send (a path/size/count failure) -- no job recorded.
            throw LassoRecoverableError(error.state)
        }

        let resolved: (name: String, mailer: SMTPMailer)
        do {
            resolved = try await registry.mailer(named: built.relayName)
        } catch let error as LassoSMTPRelayError {
            // Also pre-send (an unknown relay name) -- no job recorded.
            throw LassoRecoverableError(relayErrorState(error))
        }

        // -date (Phase E, §4.3/§4.7b): parsed here, not in
        // `LassoSMTPMessageBuilder` (pure mapping logic, no
        // `LassoDateParsing` dependency -- see `BuildResult.dateValue`'s own
        // doc comment). A parse failure is a pre-send validation error --
        // no job recorded, matching every other failure above.
        //
        // `LassoDateParsing.parse` is reused as-is here rather than
        // reimplemented for `-date` specifically -- a deliberate SUPERSET of
        // what any doc source actually documents for `-date` (real Lasso's
        // own worked example only ever shows a `[Date]` object), not a
        // guarantee every format it accepts is independently confirmed for
        // this parameter. That's safe (permissive, not lossy) and matches
        // this codebase's existing "reuse the general date parser" instruction
        // (§4.7b/plan prompt: "parse -date via the existing LassoDateParsing/
        // date native-type machinery already in this codebase -- reuse it,
        // don't reinvent date parsing"), just stated explicitly here per the
        // Phase E milestone review's protocol pass (cheap non-blocking finding D).
        let dueDate: Date?
        if let dateValue = built.dateValue {
            guard let components = LassoDateParsing.parse(dateValue) else {
                throw LassoRecoverableError(LassoSMTPError(
                    kind: .invalidParameter,
                    message: "email_send: -date could not be parsed: '\(dateValue.outputString)'."
                ).state)
            }
            let candidateDueDate = components.asDate
            // BLOCKING FIX #2 (Phase E milestone review, concurrency pass):
            // reject a `-date` scheduled further than `maximumFutureScheduleWindow`
            // into the future -- a pre-send validation error, no job
            // recorded, thrown before `recordQueued()`/`recordQueuedIfUnderCap()`
            // or the background Task are ever reached. See that constant's
            // own doc comment for the chosen window and reasoning.
            guard candidateDueDate.timeIntervalSinceNow <= Self.maximumFutureScheduleWindow else {
                let maxDays = Int(Self.maximumFutureScheduleWindow / 86_400)
                throw LassoRecoverableError(LassoSMTPError(
                    kind: .dateTooFarInFuture,
                    message: "email_send: -date is too far in the future (maximum \(maxDays) days from now)."
                ).state)
            }
            dueDate = candidateDueDate
        } else {
            dueDate = nil
        }
        // `-date`'s presence implies deferred sending regardless of
        // `-immediate`'s own value (a future date inherently means "not
        // now"); `-immediate=false` alone (no `-date`) means "send as soon
        // as possible, but don't block the request" (§4.7b).
        let deferred = dueDate != nil || built.immediateExplicitlyFalse

        // Phase F (§4.9c): `-tokens`/`-merge` branch into a per-recipient
        // personalized BATCH send instead of the single-message path --
        // real Lasso's own documented "Email Merge" semantics (confirmed
        // against lassoguide.com), not a single-message content edit. This
        // composes with BOTH the synchronous and deferred branches below
        // unchanged: whichever branch would have called
        // `mailer.send(message, bcc:, envelopeFrom:)` calls
        // `mailer.send(personalizedMessages, envelopeFrom:)` instead when
        // `mergeMode` is true. The non-merge path (`built.tokens == nil &&
        // built.merge == nil`) is completely unaffected -- this is a
        // strictly additive branch.
        let mergeMode = built.tokens != nil || built.merge != nil

        // Everything above this line can fail with NO job ever recorded.
        // From here on, build/attachment-resolution/relay-resolution have
        // ALL succeeded -- a real send is genuinely about to be attempted
        // (synchronously below, or via a background Task for the deferred
        // cases), so this is exactly the point §4.7b's job-ID scoping rule
        // draws the line at: a job now exists to track.
        //
        // BLOCKING FIX #1 (Phase E milestone review, concurrency pass): the
        // concurrency cap applies ONLY to the deferred branch -- a
        // synchronous send resolves to `.sent`/`.error` before this
        // function even returns, so it never lingers `.queued` and would
        // never legitimately be blocked by this cap (see
        // `maxConcurrentDeferredSends`'s own doc comment). `recordQueuedIfUnderCap`
        // atomically checks-and-inserts within one actor-isolated call, so
        // there's no separate check-then-insert race across concurrent
        // deferred `email_send` calls.
        let jobID: String
        if deferred {
            guard let deferredJobID = await jobTracker.recordQueuedIfUnderCap(maxConcurrentDeferredSends) else {
                throw LassoRecoverableError(LassoSMTPError(
                    kind: .tooManyDeferredSendsInFlight,
                    message: "email_send: too many deferred (-immediate=false/-date) sends already in flight; try again shortly."
                ).state)
            }
            jobID = deferredJobID
        } else {
            jobID = await jobTracker.recordQueued()
        }

        if deferred {
            // Cases 2 (`-immediate=false`) and 3 (`-date`), §4.7b: record
            // `.queued` (already done above) and return immediately WITHOUT
            // waiting for the real send -- a background `Task` performs it
            // and updates the job to `.sent`/`.error(...)` once it
            // completes. This `Task {}` is deliberately a plain,
            // unstructured task, NOT a child task of this `async` function
            // (no `TaskGroup`/`async let` involved) -- it is not scoped to
            // this call's own async context and is not cancelled when
            // `send` returns, which is exactly the "genuinely detached,
            // server-lifetime-scoped" requirement §4.7b's third open
            // question asks for (verified directly by
            // `LassoEmailJobTrackerDeferredSendTests`'s
            // `backgroundTaskSurvivesPastTheTriggeringRequestsOwnCompletion`
            // test). See `LassoEmailJobTracker.swift`'s own doc comment for
            // why this Task is deliberately NOT tracked for restart
            // cancellation the way `smtpConnectionReaperTask`/the tracker's
            // own periodic sweep Task are.
            let mailer = resolved.mailer
            let relayName = resolved.name
            let bcc = built.bcc
            let envelopeFrom = built.envelopeFrom
            let tracker = jobTracker
            let capturedMessage = message
            let tokens = built.tokens
            let merge = built.merge
            // `self` (this conformer) is a plain `Sendable` struct (the
            // protocol itself requires `Sendable`) -- capturing it directly
            // to reuse `isFailureOutcome`/`describeOutcome`/
            // `personalizedMessages` is exactly as safe as capturing any
            // other `Sendable` value here.
            let provider = self
            Task {
                if let dueDate {
                    let interval = dueDate.timeIntervalSinceNow
                    if interval > 0 {
                        let millis = Int((interval * 1000).rounded(.up))
                        try? await Task.sleep(for: .milliseconds(millis))
                    }
                }
                if mergeMode {
                    // `SMTPMailer.send(_ messages:envelopeFrom:)` never
                    // throws (every per-message failure already becomes a
                    // `.failed(error)` `DeliveryResult`) -- no `do`/`catch`
                    // needed here, unlike the single-message overload below.
                    let messages = provider.personalizedMessages(from: capturedMessage, tokens: tokens, merge: merge)
                    let results = await mailer.send(messages, envelopeFrom: envelopeFrom)
                    if let failure = results.first(where: { provider.isFailureOutcome($0.outcome) }) {
                        await tracker.update(jobID, to: .error(
                            "delivery failed for \(failure.recipient) via relay '\(relayName)' (\(provider.describeOutcome(failure.outcome)))."
                        ))
                    } else {
                        await tracker.update(jobID, to: .sent)
                    }
                } else {
                    do {
                        let results = try await mailer.send(capturedMessage, bcc: bcc, envelopeFrom: envelopeFrom)
                        if let failure = results.first(where: { provider.isFailureOutcome($0.outcome) }) {
                            await tracker.update(jobID, to: .error(
                                "delivery failed for \(failure.recipient) via relay '\(relayName)' (\(provider.describeOutcome(failure.outcome)))."
                            ))
                        } else {
                            await tracker.update(jobID, to: .sent)
                        }
                    } catch {
                        await tracker.update(jobID, to: .error(
                            "sending through relay '\(relayName)' failed (\(error))."
                        ))
                    }
                }
            }
            return LassoEmailSendResult(value: .void, jobID: jobID)
        }

        // Case 1 (default, §4.7b): behavior UNCHANGED from every phase
        // before this one, except for the one addition -- recording the job
        // (`.queued` then immediately `.sent`/`.error(...)`, since it all
        // happens before this function returns either way) and threading
        // that job ID back via `LassoEmailSendResult`. Any failure from
        // here on has ALREADY recorded a job, so it's wrapped in
        // `LassoEmailSendFailure` rather than thrown as a bare
        // `LassoRecoverableError` -- `Runtime.swift`'s wrapper unwraps this
        // to stash the job ID into `context.lastEmailJobID` before
        // re-throwing the underlying, `[protect]`-catchable error.
        let results: [DeliveryResult]
        if mergeMode {
            // Phase F (§4.9c): one batch call across every personalized
            // clone, never N sequential single-message `send` calls --
            // preserves the connection-pooling benefit
            // `SMTPMailer.send(_:envelopeFrom:)`'s batch overload exists
            // for. Never throws (every per-message failure already
            // becomes a `.failed(error)` `DeliveryResult`), so no
            // `do`/`catch` is needed here, unlike the non-merge path
            // below.
            let messages = personalizedMessages(from: message, tokens: built.tokens, merge: built.merge)
            results = await resolved.mailer.send(messages, envelopeFrom: built.envelopeFrom)
        } else {
            do {
                results = try await resolved.mailer.send(message, bcc: built.bcc, envelopeFrom: built.envelopeFrom)
            } catch let error as MIMEComposer.ComposerError {
                let state = LassoSMTPError(
                    kind: .composeFailed,
                    message: "email_send: message composition failed (\(error)).",
                    detail: String(describing: error)
                ).state
                await jobTracker.update(jobID, to: .error(state.message))
                throw LassoEmailSendFailure(jobID: jobID, underlying: LassoRecoverableError(state))
            } catch let error as HeaderEncoder.HeaderInjectionError {
                let state = LassoSMTPError(
                    kind: .composeFailed,
                    message: "email_send: rejected header/address content (\(error)).",
                    detail: String(describing: error)
                ).state
                await jobTracker.update(jobID, to: .error(state.message))
                throw LassoEmailSendFailure(jobID: jobID, underlying: LassoRecoverableError(state))
            } catch {
                let state = LassoSMTPError(
                    kind: .deliveryFailed,
                    message: "email_send: sending through relay '\(resolved.name)' failed (\(error)).",
                    detail: String(describing: error)
                ).state
                await jobTracker.update(jobID, to: .error(state.message))
                throw LassoEmailSendFailure(jobID: jobID, underlying: LassoRecoverableError(state))
            }
        }

        if let failure = results.first(where: { isFailureOutcome($0.outcome) }) {
            let state = LassoSMTPError(
                kind: .deliveryFailed,
                message: "email_send: delivery failed for \(failure.recipient) via relay '\(resolved.name)' (\(describeOutcome(failure.outcome))).",
                detail: describeOutcome(failure.outcome)
            ).state
            await jobTracker.update(jobID, to: .error(state.message))
            throw LassoEmailSendFailure(jobID: jobID, underlying: LassoRecoverableError(state))
        }

        await jobTracker.update(jobID, to: .sent)
        return LassoEmailSendResult(value: .void, jobID: jobID)
    }

    /// Backs `email_result()` (Phase E, §4.7/§4.7b) -- real Lasso's
    /// signature takes NO arguments; it implicitly refers to whatever
    /// `email_send` call most recently completed in this context.
    /// `context.lastEmailJobID` is set by `Runtime.swift`'s `email_send`
    /// wrapper (the only place with `inout LassoContext` access -- see
    /// `LassoEmailSendResult`/`LassoEmailSendFailure`'s own doc comments),
    /// so this method only ever reads it back, never mutates anything.
    /// Throws a clear, catchable error when no job is on record at all --
    /// either genuinely the first call this request, or the most recent
    /// `email_send` failed before a job was ever recorded (a pre-send
    /// validation failure).
    public func result(context: LassoContext) async throws -> LassoValue {
        guard let jobID = context.lastEmailJobID else {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .noJobRecorded,
                message: "email_result: no email_send job is on record for this request (either none has been sent yet, or the most recent attempt failed before a job could be queued)."
            ).state)
        }
        return .string(jobID)
    }

    /// Backs `email_status(id)` (Phase E) -- looks up `id` (the first
    /// positional argument, matching `email_status(id)`'s documented bare
    /// signature) against `jobTracker`, returning exactly one of
    /// `"sent"`/`"queued"`/`"error"` (lowercase, per lassoguide.com's own
    /// "Email Sending Status" section) -- `.error`'s own human-readable
    /// description is deliberately NOT surfaced here (see
    /// `LassoEmailJobState`'s own doc comment): real Lasso documents only
    /// the bare three-string return shape, nothing richer.
    ///
    /// **An unrecognized/evicted job ID returns `"sent"`, not a thrown
    /// error (Phase E milestone review, BLOCKING FIX #4).** Confirmed via
    /// three independent sources (lassoguide.com, an archived
    /// lassosoft.com reference mirror, and the local Lasso 8.5 Language
    /// Guide PDF): real Lasso documents "Messages which have been sent (or
    /// are not found in the queue) will have a status of 'sent'." This
    /// matters concretely for this codebase's own design: `jobTracker`'s
    /// 24-hour TTL eviction (`LassoEmailJobTracker.defaultTTL`) means
    /// legitimate corpus code following the doc's own recommended pattern
    /// ("store the ID, check sometime later") would poll an evicted ID and
    /// -- under the previous implementation -- get a thrown, unexpected
    /// error instead of the documented, benign `"sent"`. A genuinely
    /// bogus/typo'd ID also reads as `"sent"` under this same path -- that
    /// IS the documented real-Lasso behavior, not something to
    /// special-case further.
    public func status(_ arguments: [EvaluatedArgument], context: LassoContext) async throws -> LassoValue {
        let jobID = arguments.positionalValue(at: 0)?.outputString ?? arguments.firstValue(named: "id")?.outputString ?? ""
        guard let state = await jobTracker.status(of: jobID) else {
            return .string("sent")
        }
        switch state {
        case .queued: return .string("queued")
        case .sent: return .string("sent")
        case .error: return .string("error")
        }
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
        case .reservedRelayNameCollision(let name):
            // Unreachable via `email_send`'s own runtime path -- this
            // registry-construction-time invariant is enforced at server
            // startup (`ServerConfigError.smtpReservedRelayName`), long
            // before any request could ever call `mailer(named:)` -- kept
            // exhaustive here only because `LassoSMTPRelayError` is a
            // single enum shared by both failure classes.
            LassoSMTPError(
                kind: .unknownRelay,
                message: "email_send: internal configuration error -- relay name '\(name)' is reserved.",
                detail: name
            ).state
        }
    }

    /// Phase F (§4.9c): builds one personalized `EmailMessage` clone per
    /// address in `base.to` — the per-recipient fan-out `-tokens`/`-merge`
    /// requires. Each clone's `.to` is narrowed to that ONE recipient
    /// (never the full original recipient list — `SMTPMailer.send(_
    /// messages:envelopeFrom:)`'s own doc comment describes each array
    /// element as "already fully composed as its own `EmailMessage`" for
    /// "many independent recipients," which only makes sense if each
    /// element addresses exactly one of them); `-cc`/`-bcc` are already
    /// guaranteed absent by `LassoSMTPMessageBuilder.build`'s mutual-
    /// exclusion check whenever `tokens`/`merge` is non-nil, so `base.cc`
    /// is empty here regardless. Every other field (attachments, extra
    /// headers, etc.) is copied from `base` unchanged.
    ///
    /// Token resolution per recipient: `tokens` (the `-tokens` default map)
    /// overlaid by that recipient's own `merge[address]` entry, if any —
    /// `merge` values win on key collision, matching real Lasso's
    /// documented "Email Merge" override rule (lassoguide.com, fetched
    /// 2026-07-20).
    func personalizedMessages(
        from base: EmailMessage,
        tokens: [String: String]?,
        merge: [String: [String: String]]?
    ) -> [EmailMessage] {
        let baseTokens = tokens ?? [:]
        return base.to.map { recipient in
            var resolved = baseTokens
            // `.lowercased()` here for the same root-cause reason
            // `substitute(_:tokens:)`'s own doc comment explains for token
            // NAMES: `-merge`'s outer map (address -> token map) is also
            // built via Lasso `map(...)`, whose `register("map")`
            // registration lowercases every key it stores — so `merge`'s
            // keys are always already lowercase, regardless of the case a
            // caller wrote in `-merge=map('SomeAddress@Example.com'=...)`.
            // Matching that against `recipient.address` (which preserves
            // whatever case `-to` was written in) needs the same
            // normalization on this side of the lookup.
            if let overrides = merge?[recipient.address.lowercased()] {
                for (name, value) in overrides {
                    resolved[name] = value
                }
            }
            var clone = base
            clone.to = [recipient]
            clone.subject = substitute(base.subject, tokens: resolved)
            clone.textBody = base.textBody.map { substitute($0, tokens: resolved) }
            clone.htmlBody = base.htmlBody.map { substitute($0, tokens: resolved) }
            return clone
        }
    }

    /// Literal substring replacement of every `"#\(name)#"` marker
    /// occurrence — NOT a regex pass (§4.9c: real Lasso's own
    /// `email_token`/`#TOKEN#` marker convention is a plain literal
    /// string, and this codebase's `email_token` registration
    /// (`Runtime.swift`) emits exactly that literal shape). A marker with
    /// no resolved value in `tokens` is left verbatim, unsubstituted — a
    /// deliberate, conservative judgment call (§4.9c: neither doc source
    /// describes missing-token behavior; leaving it as literal text is the
    /// least surprising of the unconfirmed options and easy to spot in a
    /// rendered message if it happens).
    ///
    /// **Case-insensitive marker matching — a correction discovered during
    /// implementation, not in the original plan text.** `tokens`'/`merge`'s
    /// values originate from Lasso `map(...)` literals (`-tokens=map(
    /// 'FirstName'='...')`), and `Runtime.swift`'s `register("map")`
    /// lowercases every key it stores (`values[label.lowercased()] =
    /// argument.value`) — a real, pre-existing, generic `map()` behavior,
    /// not something specific to this feature. That means the resolved
    /// token dictionary this method receives always has lowercase keys
    /// (e.g. `"firstname"`), while `#TokenName#` marker text in a rendered
    /// `-subject`/`-body`/`-html` value keeps whatever case the caller
    /// actually wrote (`email_token('FirstName')` emits `"#FirstName#"`
    /// verbatim, case preserved — it does not lowercase its argument).
    /// Without case-insensitive matching here, every mixed-case token name
    /// in the plan's own worked example (`'FirstName'`) would silently
    /// fail to substitute. `.caseInsensitive` keeps this a literal
    /// substring match (Foundation's case-insensitive string search, not a
    /// regex engine) — still satisfying "simple literal substring replace,
    /// not regex."
    ///
    /// **Single-pass resolution against the ORIGINAL text — milestone
    /// review fix (protocol pass).** The original implementation mutated
    /// one running `result` string in a sequential loop over `tokens`,
    /// applying each token's replacement on top of whatever the *prior*
    /// iterations had already produced. If a resolved token's own VALUE
    /// happened to contain another token's literal marker text (e.g.
    /// token `A`'s value is literally `"#B#"`), whether that got further
    /// (incorrectly) substituted depended on Swift `Dictionary`'s
    /// unspecified iteration order — genuinely nondeterministic across
    /// runs for the same input. Fixed by scanning `text` once for
    /// `#...#`-shaped spans and resolving each one against `tokens`,
    /// building the output from copied substrings of the *original* text
    /// plus resolved values — a resolved value's own content is never
    /// re-scanned for further markers, so substitution is idempotent
    /// regardless of dictionary iteration order. Still a literal/substring
    /// match, not a regex engine: `#` is only ever treated as a marker
    /// delimiter, and the span between a pair of `#`s is looked up
    /// case-insensitively as a plain string key, not a pattern.
    private func substitute(_ text: String, tokens: [String: String]) -> String {
        guard tokens.isEmpty == false else { return text }
        // Case-insensitive lookup table, built once per call.
        var lowercasedTokens: [String: String] = [:]
        for (name, value) in tokens {
            lowercasedTokens[name.lowercased()] = value
        }

        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let markerStart = text[cursor...].firstIndex(of: "#") else {
                output += text[cursor...]
                break
            }
            let afterMarkerStart = text.index(after: markerStart)
            guard afterMarkerStart < text.endIndex,
                  let markerEnd = text[afterMarkerStart...].firstIndex(of: "#") else {
                // No closing `#` -- the rest of the text can't contain a
                // complete marker, so copy it verbatim and stop.
                output += text[cursor...]
                break
            }
            let name = text[afterMarkerStart..<markerEnd]
            if let value = lowercasedTokens[name.lowercased()] {
                output += text[cursor..<markerStart]
                output += value
                cursor = text.index(after: markerEnd)
            } else {
                // No resolved value for this marker -- left verbatim,
                // unsubstituted (this method's established, documented
                // behavior). Copy up through this `#` and resume scanning
                // right after it, so a `#` that's genuinely just a literal
                // character (not part of any resolvable marker) doesn't
                // get treated as the start of an ever-larger unresolved
                // span.
                output += text[cursor...markerStart]
                cursor = afterMarkerStart
            }
        }
        return output
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

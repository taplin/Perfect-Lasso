//
//  LassoEmailSMTPType.swift
//  LassoPerfectSMTP
//
//  `LassoEmailProviderImpl`'s conformance to the `LassoEmailProvider`
//  protocol's `email_smtp` members (§4.0 problem 3, §4.8b) — the
//  `->open`/`->command`/`->send`/`->close` implementations `NativeTypes.swift`'s
//  `makeEmailSMTPType()` dispatches to. Kept in its own file (mirroring the
//  plan's own suggested layout) rather than folded into
//  `LassoEmailProviderImpl.swift`, since this is a genuinely separate
//  concern from `send`/`compose`/`mxLookup` — it drives a live,
//  cross-call network connection instead of a single request/response.
//
//  ## Deliberate scope decision: `email_smtp` bypasses the SSRF-safe
//  named-relay design entirely — flagged, not an oversight
//
//  `email_send`/`email_compose` (§5) deliberately never accept a literal
//  `-host` — `-host` there selects a *name* out of the operator's
//  configured `smtp.relays` map, specifically because `RelayTransport` has
//  no address-routability filtering at all (that machinery lives
//  exclusively on `DirectMXTransport`). `email_smtp` cannot follow that
//  same design: its entire documented purpose is a low-level, raw
//  connection to a caller-given host (the worked example passes a literal
//  `-host='smtp.example.com'` straight to `->open`), and there is no
//  "named relay" concept for it in real Lasso at all. This means an
//  unauthenticated Lasso page (or template) with `email_smtp` available to
//  it CAN dial an arbitrary host/port, including internal/private
//  addresses — the exact class of primitive §5 designed `email_send` to
//  never expose. This is a deliberate, flagged scope decision, not a gap
//  quietly reintroduced: it matches real Lasso's own documented
//  `email_smtp` behavior byte for byte (this is, after all, "the point" of
//  a low-level SMTP connection type), and the plan's own §4.8b never asked
//  for `DirectMXTransport`-style filtering here.
//
//  RESOLVED (milestone review, BLOCKING #2): real Lasso operators had an
//  actual enforced mitigation for this — a per-tag/per-group permission
//  system ("Setup > Global > Tags and Security > Groups > Tags" per the
//  Lasso 8.5 Language Guide) — that this codebase had no equivalent of.
//  `smtpOpen` below now gates ALL dialing behind `LassoEmailProviderImpl.
//  allowEmailSMTP`, an off-by-default config flag (`ServerConfig.
//  smtpAllowEmailSMTP` / `LASSO_SMTP_ALLOW_EMAIL_SMTP`) mirroring this
//  codebase's exact `mysqlAllowRawSQL` precedent. An operator who wants
//  `email_smtp` off entirely simply leaves the flag unset (the default);
//  one who needs it enables it explicitly and accepts the SSRF exposure
//  described above as the documented cost of real Lasso's own `email_smtp`
//  design. See Documentation/lasso-perfect-smtp-integration-plan.md §4.8b.
//

import Foundation
import LassoParser
import NIOCore
import PerfectSMTP

extension LassoEmailProviderImpl {
    public func smtpOpen(
        _ receiver: LassoObjectInstance,
        _ arguments: [EvaluatedArgument],
        context: LassoContext
    ) async throws -> LassoValue {
        // Off-by-default operator gate (milestone review, BLOCKING #2) —
        // see `LassoEmailProviderImpl.allowEmailSMTP`'s doc comment for the
        // full SSRF rationale. Checked before any network dialing happens;
        // `->command`/`->send`/`->close` don't need their own gate since
        // they already fail cleanly (a clear "no open connection" error)
        // against a connection that was never opened.
        guard allowEmailSMTP else {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .invalidParameter,
                message: "email_smtp is not enabled on this server (set smtp.allowEmailSMTP / LASSO_SMTP_ALLOW_EMAIL_SMTP to enable — see Documentation/lasso-perfect-smtp-integration-plan.md §4.8b's SSRF discussion)."
            ).state)
        }
        guard let host = Self.resolvedString(arguments, "host", receiver, "_host"), host.isEmpty == false else {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .invalidParameter,
                message: "email_smtp->open: Requires a -host."
            ).state)
        }
        let port = Self.resolvedInt(arguments, "port", receiver, "_port") ?? 25
        let ssl = Self.resolvedBool(arguments, "ssl", receiver, "_ssl")
        let tls = Self.tlsMode(ssl: ssl, port: port)
        let ehloHostname = Self.resolvedString(arguments, "clientip", receiver, "_clientip") ?? "localhost"
        let timeoutSeconds = Self.resolvedInt(arguments, "timeout", receiver, "_timeout")
        let connectTimeout: TimeAmount = timeoutSeconds.map { TimeAmount.seconds(Int64($0)) } ?? .seconds(30)
        let username = Self.resolvedString(arguments, "username", receiver, "_username")
        let password = Self.resolvedString(arguments, "password", receiver, "_password")

        let connection: SMTPConnection
        do {
            let asyncChannel = try await SMTPBootstrap.connect(
                host: host, port: port, tls: tls, connectTimeout: connectTimeout, group: group
            )
            connection = SMTPConnection(asyncChannel: asyncChannel, ehloHostname: ehloHostname)
            try await connection.negotiateCapabilities()
            // Real behavior per the worked example: authenticate whenever
            // BOTH `-username`/`-password` were given, immediately after
            // EHLO, as part of what `->open` means (see this method's own
            // doc comment on `Providers.swift`'s protocol declaration) —
            // never a separate, caller-issued raw `->command` for AUTH.
            // `SASLPlain` — the same mechanism `LassoSMTPRelayDescriptor.auth`
            // already chooses for `email_send`'s `-username`/`-password`
            // (`LassoSMTPMailerRegistry.swift`) — is reused here rather
            // than introducing a second convention for the identical
            // "plain username+password" shape. Milestone review correction:
            // reference.lassosoft.com's `[Email_SMTP]` page actually says
            // real Lasso "opens a connection... using the best available
            // authentication method" and references `[Email_DigestChallenge]`/
            // `[Email_DigestResponse]` (DIGEST-MD5 helper tags) — real Lasso
            // appears to prefer DIGEST-MD5 when available, not an
            // unspecified mechanism as an earlier revision of this comment
            // claimed. Perfect-SMTP has no DIGEST-MD5/CRAM-MD5 mechanism
            // implemented at all (`SASLMechanism.swift`'s own doc comment
            // confirms this is deliberately deferred), so `SASLPlain` is the
            // pragmatic fallback given what's actually available here, not
            // an arbitrary guess.
            if let username, let password, username.isEmpty == false {
                try await connection.authenticate(SASLPlain(username: username, password: password))
            }
        } catch let error as LassoRecoverableError {
            throw error
        } catch {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .deliveryFailed,
                message: "email_smtp->open: connecting to '\(host):\(port)' failed (\(error)).",
                detail: String(describing: error)
            ).state)
        }

        await connectionRegistry.insert(connection, for: receiver)
        // Neither doc source documents a meaningful return value for
        // `->open` (it isn't in either method-list table with a described
        // return shape) — `.void` matches this project's established
        // convention for an undocumented-return, process-tag-like method
        // (e.g. `email_send` itself), absent contrary evidence.
        return .void
    }

    public func smtpCommand(
        _ receiver: LassoObjectInstance,
        _ arguments: [EvaluatedArgument],
        context: LassoContext
    ) async throws -> LassoValue {
        guard let connection = await connectionRegistry.connection(for: receiver) else {
            throw LassoRecoverableError(Self.noOpenConnectionError("command"))
        }

        // `-send` is genuinely raw, unsanitized wire content by design —
        // see this file's header doc comment and `Providers.swift`'s
        // protocol doc comment. No `HeaderEncoder.rejectHeaderInjection`-
        // style filtering here, deliberately: unlike `-extraMIMEHeaders`
        // (a caller-controlled VALUE inserted into a higher-level
        // abstraction this library controls the rest of), `->command`
        // *is* the abstraction boundary — there is nothing underneath it
        // to protect from the caller's own literal protocol line. A
        // future reader should not "fix" this as an oversight.
        if let sendLine = arguments.lastString(named: "send") {
            do {
                try await connection.writeLine(sendLine)
            } catch {
                throw LassoRecoverableError(LassoSMTPError(
                    kind: .deliveryFailed,
                    message: "email_smtp->command: writing '\(sendLine)' failed (\(error)).",
                    detail: String(describing: error)
                ).state)
            }
        }

        let reply: SMTPReply
        do {
            reply = try await connection.nextReply()
        } catch {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .deliveryFailed,
                message: "email_smtp->command: reading the server's reply failed (\(error)).",
                detail: String(describing: error)
            ).state)
        }

        // `-multi`'s real meaning, confirmed against `SMTPResponseDecoder.swift`
        // (Perfect-SMTP): the decoder already assembles every continuation
        // line (`250-...`) into one `SMTPReply` — `reply.lines` — before
        // `nextReply()` ever returns it. There is nothing left for `-multi`
        // to toggle from this implementation's perspective; it's accepted
        // (so an extra keyword argument never throws an unknown-arg
        // surprise) but is a documented no-op, not silently ignored by
        // omission.
        _ = arguments.hasTruthyFlag("multi")

        // `-timeout` is likewise accepted but currently a documented no-op,
        // not silently unaddressed (milestone review, cheap fix A):
        // `SMTPConnection.replyTimeout` is fixed at construction time
        // (inside `->open`, before any `->command` call could ever supply
        // its own) and isn't adjustable per-command without deeper changes
        // to `SMTPConnection` itself — out of scope for this pass. An
        // extra `-timeout` keyword argument here never throws an unknown-
        // arg surprise; it simply has no effect yet.
        _ = arguments.lastInt(named: "timeout")

        let wantsText = arguments.hasTruthyFlag("read")
        let expected = arguments.lastInt(named: "expect")

        // Exact real-Lasso return shape when BOTH `-expect` and `-read`
        // are given together is unconfirmed by either doc source (§4.8b
        // flags this explicitly) — this implementation's judgment call:
        // `-read` wins (returns the reply text) whenever it's truthy,
        // regardless of whether `-expect` was also given; `-expect`'s
        // comparison still has nowhere else to go in that case (there is
        // no side channel to report it through), so it's simply not
        // surfaced when `-read` also applies. Flagged here rather than
        // silently guessed.
        if wantsText {
            return .string(reply.lines.joined(separator: "\n"))
        }
        if let expected {
            return .boolean(reply.code == expected)
        }
        // Neither `-expect` nor `-read` given: nothing documented to
        // return — `.void`, matching `->open`/`->close`'s own convention
        // for a call with no confirmed return contract.
        return .void
    }

    public func smtpSend(
        _ receiver: LassoObjectInstance,
        _ arguments: [EvaluatedArgument],
        context: LassoContext
    ) async throws -> LassoValue {
        guard let connection = await connectionRegistry.connection(for: receiver) else {
            throw LassoRecoverableError(Self.noOpenConnectionError("send"))
        }

        let from = arguments.lastString(named: "from") ?? ""
        guard from.isEmpty == false else {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .invalidParameter,
                message: "email_smtp->send: Requires -from."
            ).state)
        }
        let recipients = Self.stringArray(from: arguments.lastValue(named: "recipients"))
        guard recipients.isEmpty == false else {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .invalidParameter,
                message: "email_smtp->send: Requires -recipients."
            ).state)
        }
        // The worked example's `#message->data + '\r\n'` is the CALLER's
        // own responsibility to get right (§4.8b) — no trailing-CRLF logic
        // is added on top of whatever `-message` literally contains.
        let messageText = arguments.lastString(named: "message") ?? ""

        let envelope: SMTPEnvelope
        do {
            envelope = try SMTPEnvelope(mailFrom: .address(from), recipients: recipients)
        } catch {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .composeFailed,
                message: "email_smtp->send: rejected -from/-recipients content (\(error)).",
                detail: String(describing: error)
            ).state)
        }
        let signed = SignedMessage(rfc5322: Array(messageText.utf8))

        let results: [DeliveryResult]
        do {
            results = try await connection.sendMessage(envelope, signed)
        } catch {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .deliveryFailed,
                message: "email_smtp->send: sending failed (\(error)).",
                detail: String(describing: error)
            ).state)
        }

        // Reuses `LassoEmailProviderImpl.send(_:context:)`'s exact same
        // "which outcomes count as failure" judgment (`isFailureOutcome`/
        // `describeOutcome`, made non-`private` for exactly this reuse) —
        // not duplicated.
        if let failure = results.first(where: { isFailureOutcome($0.outcome) }) {
            throw LassoRecoverableError(LassoSMTPError(
                kind: .deliveryFailed,
                message: "email_smtp->send: delivery failed for \(failure.recipient) (\(describeOutcome(failure.outcome))).",
                detail: describeOutcome(failure.outcome)
            ).state)
        }

        return .void
    }

    public func smtpClose(
        _ receiver: LassoObjectInstance,
        _ arguments: [EvaluatedArgument],
        context: LassoContext
    ) async throws -> LassoValue {
        // Safe to call twice / on a never-`->open`ed instance, per §4.8b's
        // explicit requirement — `remove(for:)` returns `nil` for either
        // case, and that's simply a no-op here, never an error.
        guard let connection = await connectionRegistry.remove(for: receiver) else {
            return .void
        }
        // `try?`: a close failing (already-closed peer, etc.) is not a
        // meaningful `->close` failure to surface to Lasso code — the
        // connection is gone from the registry either way, which is the
        // actual, observable postcondition `->close` promises.
        try? await connection.channel.close()
        return .void
    }

    // MARK: - Shared argument-resolution helpers

    /// `->open`'s own arguments always take precedence over the
    /// constructor's stored `_`-prefixed defaults when both are given
    /// (§4.8b) — applied uniformly to every `email_smtp` parameter, not
    /// just `-host` (the plan calls this out explicitly only for `-host`,
    /// but the same precedence is the only reading that makes
    /// `email_smtp(-host=..., ...)` immediately followed by a bare
    /// `->open()` behave sensibly, and the only one that lets `->open`'s
    /// own arguments genuinely "override" anything).
    private static func resolvedString(
        _ arguments: [EvaluatedArgument], _ label: String, _ receiver: LassoObjectInstance, _ field: String
    ) -> String? {
        if let value = arguments.lastString(named: label), value.isEmpty == false { return value }
        // `LassoObjectInstance.value(for:)` returns `.null` (not `.void`)
        // for an absent field, and both stringify to `""` — so this one
        // check correctly handles "never stored," "stored as `.null`," and
        // "stored as an empty string" alike.
        let text = receiver.value(for: field).outputString
        return text.isEmpty ? nil : text
    }

    private static func resolvedInt(
        _ arguments: [EvaluatedArgument], _ label: String, _ receiver: LassoObjectInstance, _ field: String
    ) -> Int? {
        if let value = arguments.lastInt(named: label) { return value }
        // `LassoValue.number` (used by `arguments.lastInt(named:)`) is an
        // `internal` computed property, not visible outside `LassoParser` —
        // this switches on the (public) enum cases directly instead of
        // reaching for it.
        switch receiver.value(for: field) {
        case .integer(let value): return value
        case .decimal(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    private static func resolvedBool(
        _ arguments: [EvaluatedArgument], _ label: String, _ receiver: LassoObjectInstance, _ field: String
    ) -> Bool {
        if let value = arguments.lastValue(named: label) { return value.isTruthy }
        return receiver.value(for: field).isTruthy
    }

    /// `-ssl=true` implies `.implicit` specifically at port 465, else
    /// `.startTLS` — the exact same judgment
    /// `LassoSMTPMessageBuilder`'s own `-ssl` doc comment documents for
    /// `email_send`'s relay config (reused here per §4.8b's own
    /// instruction, not reinvented). Absent/`false` maps to `.none`: unlike
    /// `email_send`, there is no configured relay here to fall back to —
    /// this is `email_smtp`'s own explicit judgment call, since real
    /// Lasso's own docs don't describe a default TLS posture for
    /// `email_smtp` at all.
    private static func tlsMode(ssl: Bool, port: Int) -> TLSMode {
        guard ssl else { return .none }
        return port == 465 ? .implicit : .startTLS
    }

    /// `-recipients` arrives as a single array-valued argument (the
    /// worked example's `-recipients=#message->recipients`, itself a
    /// `.array` of `.string`) — this flattens either an actual `.array`
    /// or, defensively, a single scalar value into `[String]`.
    private static func stringArray(from value: LassoValue?) -> [String] {
        guard let value else { return [] }
        if case let .array(values) = value {
            return values.map(\.outputString).filter { $0.isEmpty == false }
        }
        let single = value.outputString
        return single.isEmpty ? [] : [single]
    }

    private static func noOpenConnectionError(_ methodName: String) -> LassoErrorState {
        LassoSMTPError(
            kind: .invalidParameter,
            message: "email_smtp->\(methodName): no open connection (call ->open first, or it was already ->closed)."
        ).state
    }
}

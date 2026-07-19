//
//  LassoSMTPMessageBuilder.swift
//  LassoPerfectSMTP
//
//  Dash-params -> `EmailMessage`/`ReversePath` — implements
//  Documentation/lasso-perfect-smtp-integration-plan.md §4.3's finalized
//  parameter-mapping table for Phase A's scope. Pure mapping logic: no I/O,
//  no relay dialing, no `SMTPMailer` — `LassoEmailProviderImpl` is what
//  actually resolves `BuildResult.relayName` against the configured relay
//  map and sends.
//
//  ## Deliberate scope decisions (read before touching this file)
//
//  **`-host` selects a *relay name*, never a literal hostname/IP** — the
//  SSRF-safe design §5 exists specifically to prevent: `RelayConfig`/
//  `RelayTransport` has NO address-routability filtering at all (that
//  machinery lives exclusively on `DirectMXTransport`), so a per-call
//  "-host=<arbitrary string>, dial it" design would hand a caller the
//  exact internal-network-connect primitive `DirectMXConfig.allowPrivateAddresses`
//  exists to prevent. `BuildResult.relayName` is therefore just the raw
//  `-host` string, unresolved — `LassoEmailProviderImpl`/
//  `LassoSMTPMailerRegistry` are what actually enforce "must name a
//  configured relay or throw," since only they know what's configured.
//
//  **`-port`/`-username`/`-password`/`-ssl`/`-timeout` are silently
//  ignored, not honored as per-call overrides of the selected relay.**
//  Once `-host` means "select a name" rather than "dial this," these four
//  params have no safe, coherent per-call meaning left:
//  - `-port` no longer has a peer literal host to pair with — overriding
//    just the port of a *named, pre-configured* relay is a narrower,
//    defensible middle ground (connect to relay X's host, but on a
//    caller-chosen port), but it's still a live network-behavior change
//    driven by unauthenticated-by-default caller input, for a feature with
//    zero confirmed real-corpus usage. Given `LassoSMTPMailerRegistry`
//    holds one long-lived, pre-built `SMTPMailer`/`RelayTransport`/
//    `SMTPConnectionPool` per relay name (§4.6 — the entire point of the
//    shared-mailer design is realizing that pool's benefit across many
//    calls), honoring a per-call port override would mean either (a)
//    spinning up a fresh, unpooled transport per call whenever `-port` is
//    given — defeating the pooling design silently on a per-call basis in
//    a way that's easy to miss in review, or (b) baking multiple
//    port-keyed pools per relay name, which the config shape (§4.6) was
//    never designed to express. Neither is worth it for an unconfirmed
//    legacy param — scoped out.
//  - `-username`/`-password` overriding a shared, pooled, already-
//    authenticated connection's credentials per-call has no coherent
//    meaning at all (the pool authenticates once per dialed connection,
//    not per send — see `RelayTransport.send`'s doc comment) without
//    tearing down and rebuilding that connection's auth state on every
//    call, which is both expensive and a real security-review surface
//    (an unauthenticated caller now decides which stored credential a
//    shared connection authenticates as).
//  - `-ssl` is scoped out for the same consistency reason as `-port`: it
//    only had a coherent meaning in real Lasso as a *pair* with `-port`
//    (`-ssl=true` implies implicit TLS specifically when `-port=465`) —
//    honoring one half of that pair and not the other would be a more
//    confusing partial design than honoring neither. The selected relay's
//    own configured `tls` mode (§4.6's `smtp.relays.<name>.tls`) is what
//    governs TLS, full stop.
//  - `-timeout` isn't reachable per-call at all given the shared-mailer
//    architecture: `RelayConfig.pool.connectTimeout` is fixed at
//    registry-construction time (server startup), and
//    `SMTPConnectionPool.withConnection` (what `RelayTransport.send`
//    actually calls) takes no per-call timeout parameter to override it
//    with — a documented limitation, not a design choice to silently work
//    around.
//
//  All four are recognized (present in `arguments`) and silently ignored —
//  not thrown as `notYetSupported` — because ignoring them changes nothing
//  about *what* gets sent or *where* (the message still sends correctly
//  through the selected/default relay); they only ever would have changed
//  *how* the connection to an already-safe, already-configured relay is
//  made, which the relay's own config now governs unconditionally.
//
//  **`-tokens`/`-merge` (mail-merge templating) and
//  `-contentType`/`-transferEncoding`/`-characterSet` throw
//  `LassoSMTPFailureKind.notYetSupported`, not silently ignored.** Unlike
//  the connection-only params above, these change what content is
//  actually sent: silently ignoring `-tokens`/`-merge` would mail
//  unsubstituted `{{token}}`-style placeholder text straight to real
//  recipients, and `-contentType`/`-transferEncoding` don't even have a
//  landing spot in `EmailMessage` today (§4.3: `MIMEComposer.forbiddenExtraHeaderNames`
//  explicitly denies both as `extraHeaders`) — this plan's own §4.3 table
//  recommends the explicit-error posture for the initial release. A
//  caller passing any of these five gets a clear, catchable
//  `[protect]`-able error instead of a message that silently doesn't do
//  what was asked.
//
//  **`-attachments`/`-htmlImages` also throw `notYetSupported`, for the
//  same reason and arguably more urgently** — path-or-inline attachment
//  resolution is scoped to Phase B (§4.5/§6), not yet implemented in this
//  builder at all, and a dropped attachment is a correctness failure a
//  recipient has no way to detect (unlike an unsupported header param,
//  which at worst fails to change behavior the recipient can observe).
//

import Foundation
import LassoParser
import PerfectSMTP

public enum LassoSMTPMessageBuilder {
    public struct BuildResult: Sendable {
        public let message: EmailMessage
        /// Envelope Bcc addresses — `SMTPMailer.send(_:bcc:envelopeFrom:)`'s
        /// `bcc` parameter is `[String]`, never part of `EmailMessage`
        /// itself (Perfect-SMTP's structural Bcc-leak fix; §4.3's table
        /// calls this type mismatch out explicitly).
        public let bcc: [String]
        public let envelopeFrom: ReversePath
        /// Raw `-host` value, if given at all — a relay *name* to resolve
        /// against the configured `smtp.relays` map, never a literal host.
        /// `nil` means "use the configured default relay."
        public let relayName: String?
    }

    /// Dash-params this Phase A builder deliberately does not implement at
    /// all — throws `LassoSMTPFailureKind.notYetSupported` if any is
    /// present, regardless of its value. See the file doc comment for why
    /// each is in this list (as opposed to the silently-ignored
    /// connection-only params, `-port`/`-username`/`-password`/`-ssl`/
    /// `-timeout`, handled separately below).
    private static let unsupportedParameterNames: [String] = [
        "date", "tokens", "merge", "contentType", "transferEncoding", "characterSet",
        "attachments", "htmlImages",
    ]

    public static func build(_ arguments: [EvaluatedArgument]) throws -> BuildResult {
        for name in unsupportedParameterNames where isPresent(name, in: arguments) {
            throw LassoSMTPError(
                kind: .notYetSupported,
                message: "-\(name) is not yet supported by email_send in this phase; see Documentation/lasso-perfect-smtp-integration-plan.md §4.3/§6."
            )
        }
        if let immediateValue = lastValueIfPresent("immediate", in: arguments), immediateValue.isTruthy == false {
            throw LassoSMTPError(
                kind: .notYetSupported,
                message: "-immediate=false is not yet supported by email_send — the job tracker it needs (LassoEmailJobTracker) lands in Phase E; see §4.3/§7."
            )
        }

        guard let fromRaw = arguments.lastString(named: "from"), fromRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LassoSMTPError(kind: .invalidParameter, message: "email_send requires -from.")
        }
        let fromAddresses = try addressList(fromRaw, field: "-from")
        guard fromAddresses.count == 1, let from = fromAddresses.first else {
            throw LassoSMTPError(kind: .invalidParameter, message: "-from must resolve to exactly one address, got \(fromAddresses.count) in '\(fromRaw)'.")
        }

        guard isPresent("subject", in: arguments) else {
            throw LassoSMTPError(kind: .invalidParameter, message: "email_send requires -subject.")
        }
        let subject = arguments.lastString(named: "subject") ?? ""

        let to = try joinedAddressList("to", in: arguments)
        let cc = try joinedAddressList("cc", in: arguments)
        let bccAddresses = try joinedAddressList("bcc", in: arguments)
        let bcc = bccAddresses.map(\.address)

        guard to.isEmpty == false || cc.isEmpty == false || bcc.isEmpty == false else {
            throw LassoSMTPError(kind: .invalidParameter, message: "email_send requires at least one of -to/-cc/-bcc.")
        }

        var message = EmailMessage(from: from)
        message.to = to
        message.cc = cc
        message.subject = subject
        // -body/-html: both legitimately nil is `-simpleform` (Lasso 9) --
        // NOT special-cased/faked here (see LassoEmailProviderImpl's doc
        // comment for the real, flagged Perfect-SMTP gap this reaches:
        // `MIMEComposer.compose()` currently throws `ComposerError.missingBody`
        // for a message with neither body set).
        message.textBody = arguments.lastString(named: "body")
        message.htmlBody = arguments.lastString(named: "html")

        if let replyToRaw = arguments.lastString(named: "replyTo"), replyToRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            message.replyTo = try addressList(replyToRaw, field: "-replyTo")
        }
        if let senderRaw = arguments.lastString(named: "sender"), senderRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let senderAddresses = try addressList(senderRaw, field: "-sender")
            guard senderAddresses.count == 1, let sender = senderAddresses.first else {
                throw LassoSMTPError(kind: .invalidParameter, message: "-sender must resolve to exactly one address, got \(senderAddresses.count) in '\(senderRaw)'.")
            }
            message.sender = sender
        }
        message.priority = priority(from: arguments.lastString(named: "priority"))
        if let dispositionRaw = arguments.lastString(named: "ContentDisposition") {
            message.defaultDisposition = try contentDisposition(dispositionRaw)
        }
        message.extraHeaders = extraMIMEHeaders(arguments)

        let relayName: String? = {
            guard let raw = arguments.lastString(named: "host")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.isEmpty == false else { return nil }
            return raw
        }()

        return BuildResult(
            message: message,
            bcc: bcc,
            envelopeFrom: .address(from.address),
            relayName: relayName
        )
    }

    // MARK: - Helpers

    private static func isPresent(_ name: String, in arguments: [EvaluatedArgument]) -> Bool {
        arguments.contains { $0.label?.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func lastValueIfPresent(_ name: String, in arguments: [EvaluatedArgument]) -> LassoValue? {
        arguments.lastValue(named: name)
    }

    private static func addressList(_ raw: String, field: String) throws -> [EmailAddress] {
        do {
            return try LassoSMTPAddressList.parse(raw)
        } catch {
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "\(field) could not be parsed as an address list: '\(raw)'.",
                detail: String(describing: error)
            )
        }
    }

    /// Joins every occurrence of a repeated dash-param (real corpus usage
    /// always supplies each of `-to`/`-cc`/`-bcc` at most once, but nothing
    /// stops a caller from passing more than one, and doing so is at least
    /// as reasonable to merge as to silently drop) into one address list,
    /// rather than only reading the last (`Array.lastString(named:)`'s
    /// otherwise-standard "later wins" convention, which is right for
    /// single-value fields like `-from`/`-subject` but would silently
    /// discard recipients for these three).
    private static func joinedAddressList(_ name: String, in arguments: [EvaluatedArgument]) throws -> [EmailAddress] {
        let raws = arguments.strings(named: name)
        guard raws.isEmpty == false else { return [] }
        return try raws.flatMap { try addressList($0, field: "-\(name)") }
    }

    private static func priority(from raw: String?) -> Priority {
        switch raw?.lowercased() {
        case "high": .high
        case "low": .low
        default: .normal
        }
    }

    private static func contentDisposition(_ raw: String) throws -> ContentDisposition {
        switch raw.lowercased() {
        case "inline": return .inline
        case "attachment": return .attachment
        default:
            throw LassoSMTPError(kind: .invalidParameter, message: "-ContentDisposition must be 'attachment' or 'inline', got '\(raw)'.")
        }
    }

    /// `-extraMIMEHeaders`: real Lasso 8.5/9's exact accepted shape isn't
    /// confirmed against real corpus usage (zero observed callers so far —
    /// same "not independently re-verified" caveat the plan's §4.4 flags
    /// for `email_mxlookup`'s `-hostname`). Accepts the most permissive,
    /// low-risk-to-guess-wrong shape: one `-extraMIMEHeaders` argument per
    /// header, OR a single string value containing `Name: Value` pairs
    /// separated by CR/LF — either maps cleanly onto
    /// `EmailMessage.extraHeaders`. No injection/denylist checking happens
    /// here deliberately: `MIMEComposer.compose()` is the single place
    /// that enforces `HeaderEncoder.rejectHeaderInjection`/
    /// `forbiddenExtraHeaderNames` against every entry in `extraHeaders`
    /// (§4.3's table calls this out explicitly) — duplicating that check
    /// here would just be a second, easier-to-drift copy of the same rule.
    private static func extraMIMEHeaders(_ arguments: [EvaluatedArgument]) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        for raw in arguments.strings(named: "extraMIMEHeaders") {
            for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                guard let colonIndex = line.firstIndex(of: ":") else { continue }
                let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                guard name.isEmpty == false else { continue }
                headers.append((name: name, value: value))
            }
        }
        return headers
    }
}

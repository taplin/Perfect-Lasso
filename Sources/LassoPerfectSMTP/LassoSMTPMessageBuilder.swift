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
//  **Phase F: `-tokens`/`-merge`/`-characterSet` now implemented** (plan
//  §4.9c). `-characterSet` is trivial — `EmailMessage.charset` verbatim,
//  same one-line mapping §4.3's table always specified. `-tokens`/`-merge`
//  turned out to be a genuinely different mechanism than a simple string-
//  substitution pass on one message: confirmed against lassoguide.com's
//  "Email Merge" section to be a per-recipient personalized BATCH send —
//  one composed message per address named in `-merge`, each with that
//  recipient's own token values substituted into the shared `-subject`/
//  `-body`/`-html` templates (`-tokens` supplies the default token map;
//  `-merge`'s per-address map overrides it for that recipient only). This
//  file only PARSES the two maps (`tokens`/`merge` on `BuildResult`) — the
//  actual per-recipient cloning/substitution/batch-send happens in
//  `LassoEmailProviderImpl.send`, which is what has access to
//  `SMTPMailer.send(_ messages:envelopeFrom:)`'s batch overload. `-cc`/
//  `-bcc` given together with `-tokens`/`-merge` is explicitly rejected
//  here (a pre-send validation error) rather than guessed at — neither
//  lassoguide.com nor the local Language Guide PDF documents what a static
//  cc/bcc list would mean against a per-recipient personalized batch.
//
//  **Phase B: `-contentType`/`-transferEncoding` now implemented** —
//  Perfect-SMTP's `EmailMessage.bodyContentTypeOverride`/
//  `.bodyTransferEncodingOverride` (merged to Perfect-SMTP `main` at
//  `33ac532`, §4.3/§7 item 5) give these two params a real landing spot.
//  `-contentType` is passed through to `bodyContentTypeOverride` verbatim
//  (unvalidated here — `MIMEComposer` is the single enforcement point for
//  CRLF-injection/charset checks, matching this file's existing
//  `-extraMIMEHeaders` precedent: one enforcement point, not two).
//  `-transferEncoding`'s accepted token values are not spelled out with a
//  literal list anywhere in lassoguide.com's "Sending Email" page
//  (`https://lassoguide.com/operations/sending-email.html`, fetched
//  2026-07-19 — "The value for the Transfer-Encoding header of the
//  message") or the local Lasso 8.5 Language Guide (`References/Lasso/
//  Lasso 8.5 Language Guide.pdf`, Table 7, Ch. 47 "Sending Email" —
//  identical wording); both simply describe it as the literal header
//  value, implying it's passed through close to verbatim. Rather than
//  invent a Lasso-specific token set, `transferEncodingOverride(from:)`
//  below maps the standard RFC 2045 §6.1 Content-Transfer-Encoding
//  mechanism-name tokens `7bit`/`quoted-printable`/`base64`
//  (case-insensitive) onto the three cases `ContentTransferEncodingOverride`
//  actually offers — real MTAs/mail clients already expect exactly these
//  values in that header regardless of which language generated it.
//  `8bit`/`binary` are real RFC 2045 tokens too but are deliberately NOT
//  offered by `ContentTransferEncodingOverride` at all (see its own doc
//  comment for why) — passed here, they throw the same clear, catchable
//  `.invalidParameter` error as any other unrecognized token, never a
//  silent default to one of the three supported cases.
//
//  **Phase B: `-attachments`/`-htmlImages` now implemented, in two
//  stages.** This file (`LassoSMTPMessageBuilder.build`, no I/O) parses
//  each dash-param's entries into `LassoSMTPPendingAttachment`/
//  `LassoSMTPPendingInlineImage` — a not-yet-resolved intermediate
//  representation, carried on `BuildResult`. Path-based entries need real
//  file I/O to resolve (reading the file, containment-checking it against
//  `siteRoot`) — that happens in `LassoSMTPAttachmentLoader`, called from
//  `LassoEmailProviderImpl.send` *after* this function returns, never from
//  here (see `LassoSMTPAttachmentLoader.swift`'s own doc comment for the
//  full design and lassoguide.com/Lasso-8.5-Language-Guide citations for
//  the exact accepted shape: an array of file-path strings, OR an array of
//  `name = data` pairs — confirmed directly against both sources, not
//  guessed; no `type=`/`name=`/`path=` map-keyed shape exists for
//  `email_send`'s `-attachments`/`-htmlImages` themselves, unlike the
//  unrelated `email_compose->addAttachment(-data=?, -name=?, -path=?,
//  -type=?)` companion method. A THIRD shape does exist per lassoguide.com
//  (an `email_compose` MIME-part object fed into `-attachments`/
//  `-htmlImages`), but no `LassoValue` can represent it until Phase C
//  implements `email_compose` — `pendingAttachment(from:)`/
//  `pendingInlineImage(from:)`'s `default:` case will need a third arm
//  added at that point, not before).
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
        /// `-attachments`, parsed but not yet resolved (no I/O has
        /// happened) — `LassoSMTPAttachmentLoader.resolve(attachments:inlineImages:)`
        /// turns these into real `Attachment`s. See §4.5/this file's doc
        /// comment.
        public let pendingAttachments: [LassoSMTPPendingAttachment]
        /// `-htmlImages`, parsed but not yet resolved — same deal as
        /// `pendingAttachments`.
        public let pendingInlineImages: [LassoSMTPPendingInlineImage]
        /// `-date`'s raw, unparsed value (Phase E, §4.3/§4.7b) — `nil` when
        /// `-date` wasn't given at all. Left unparsed here deliberately:
        /// `LassoSMTPMessageBuilder` is pure mapping logic with no
        /// dependency on `LassoDateParsing`'s own concept of "now" (parsing
        /// failure is a real, catchable pre-send validation error, but
        /// deciding *when* "now" is, for a genuinely relative parse, belongs
        /// with the caller that's about to act on the result) —
        /// `LassoEmailProviderImpl.send` parses this via
        /// `LassoDateParsing.parse(_:)`, matching this file's existing
        /// "no I/O, no interpretation beyond dash-param shape" scope.
        public let dateValue: LassoValue?
        /// `true` only when `-immediate=false` was explicitly given (Phase
        /// E) — `-immediate` absent, or any other truthy value, keeps the
        /// default synchronous-send behavior. `-date`'s presence implies
        /// deferred sending regardless of this flag's value (a future date
        /// inherently means "not now") — `LassoEmailProviderImpl.send` is
        /// what combines the two into the actual sync-vs-deferred decision,
        /// not this builder.
        public let immediateExplicitlyFalse: Bool
        /// `-tokens` (Phase F, §4.9c) -- a map of token name -> default
        /// value, applied to every recipient unless overridden by that
        /// recipient's own `-merge` entry. `nil` when `-tokens` wasn't
        /// given at all (as opposed to an empty map, which is `Optional(
        /// [:])`) -- `LassoEmailProviderImpl.send` treats either `tokens`
        /// or `merge` being non-nil as "enter per-recipient batch-send
        /// mode" (see that method's own doc comment).
        public let tokens: [String: String]?
        /// `-merge` (Phase F, §4.9c) -- a map of recipient address ->
        /// (token name -> value), one entry per personalized recipient.
        /// Values here override `tokens`' defaults for that specific
        /// recipient only (real Lasso's own documented "Email Merge"
        /// semantics — lassoguide.com, fetched 2026-07-20). `nil` when
        /// `-merge` wasn't given at all.
        public let merge: [String: [String: String]]?
    }

    /// Dash-params this builder deliberately does not implement at all —
    /// throws `LassoSMTPFailureKind.notYetSupported` if any is present,
    /// regardless of its value. See the file doc comment for why each is
    /// in this list (as opposed to the silently-ignored connection-only
    /// params, `-port`/`-username`/`-password`/`-ssl`/`-timeout`, handled
    /// separately below). `-contentType`/`-transferEncoding`/
    /// `-attachments`/`-htmlImages` moved OFF this list in Phase B — see
    /// the file doc comment for their real handling.
    ///
    /// `-attachment` (singular)/`-parts`/`-headerType` added per the Phase C
    /// milestone review (BLOCKING FIX #3/#4): all three are confirmed real,
    /// part of `email_compose`'s documented signature (lassoguide.com:
    /// `email_compose(..., -attachments=?, -attachment=?, ..., -parts=?,
    /// ..., -headerType=?, ...)`), and were previously silently dropped
    /// with zero error/signal — the same "silent content loss" bug class
    /// already found and fixed once in this project (commit `474b48f`,
    /// address-parser/attachment-drop fix). Explicitly listed here rather
    /// than guessed at (`-attachment` singular isn't confirmed to be a
    /// simple alias for `-attachments`'s array/pair shapes; `-parts` isn't
    /// confirmed to be `-attachments`-shaped at all — it's plausibly a
    /// pre-built array of `email_compose` MIME-part objects, a shape this
    /// builder can't represent yet either way) — per §4.3b's own stated
    /// rule, "if the shape can't be confirmed with reasonable confidence,
    /// treat as notYetSupported... rather than guess."
    /// `-date` moved OFF this list in Phase E (§4.3/§4.7b) — now given a
    /// real landing spot (`BuildResult.dateValue`) now that
    /// `LassoEmailJobTracker` exists to back real deferred sending. See the
    /// file doc comment's Phase E section.
    /// `-tokens`/`-merge`/`-characterSet` moved OFF this list in Phase F
    /// (§4.9c) — see the file doc comment's Phase F section below for
    /// their real handling.
    private static let unsupportedParameterNames: [String] = [
        "attachment", "parts", "headerType",
    ]

    /// Milestone review finding (Phase F review, security pass): unlike
    /// the uncapped `-to`/`-cc`/`-bcc` address lists — which share ONE
    /// MIME compose + (if DKIM configured) ONE signature across every
    /// recipient — `-tokens`/`-merge` mode builds one full `EmailMessage`
    /// clone PER address in `-to` (`LassoEmailProviderImpl
    /// .personalizedMessages(from:tokens:merge:)`), each costing its own
    /// full compose + (if configured) its own RSA signature + a real SMTP
    /// transaction. That's categorically heavier per-recipient, so it
    /// gets its own explicit cap, matching this project's established
    /// precedent for this exact class of gap
    /// (`LassoSMTPAttachmentLoader.maximumFileCount`,
    /// `LassoEmailProviderImpl.maxConcurrentDeferredSends` — both named,
    /// documented constants with a stated "why this number" rather than a
    /// silent, undocumented limit).
    ///
    /// No confirmed real-corpus number exists to size this against
    /// (stated explicitly, not implied — same posture as
    /// `maximumFileCount`'s own doc comment). 100 is a reasonable
    /// starting point for a personalized-batch mail-merge use case: well
    /// above anything either doc source's worked examples show (two
    /// recipients), generous enough for a genuine small-batch
    /// mail-merge send (e.g. a department roster or a small customer
    /// segment), while still bounding the per-call RSA-signature/SMTP-
    /// transaction amplification a caller-controlled `-to` list could
    /// otherwise trigger to an unbounded degree. Not meant to be a
    /// generic bulk-mail/list-server ceiling — a real large-scale
    /// mail-merge deployment should be batching `email_send` calls (or
    /// this project should grow a dedicated bulk API) rather than raising
    /// this number arbitrarily.
    public static let maximumMergeRecipientCount = 100

    /// - Parameter functionName: Interpolated into the three
    ///   "requires -from"/"requires -subject"/"requires at least one of
    ///   -to/-cc/-bcc" validation messages only — defaults to `"email_send"`
    ///   so every existing call site/test is unaffected. `email_compose`
    ///   (Phase C, §4.3b) passes `"email_compose"` instead, since those
    ///   error messages are what the real caller actually invoked. Every
    ///   OTHER error message in this file still says "email_send:" verbatim
    ///   — a deliberate, explicitly scoped-out minor cosmetic
    ///   inconsistency (see plan prompt), not worth a larger parameterization
    ///   pass for this phase.
    public static func build(_ arguments: [EvaluatedArgument], functionName: String = "email_send") throws -> BuildResult {
        for name in unsupportedParameterNames where isPresent(name, in: arguments) {
            throw LassoSMTPError(
                kind: .notYetSupported,
                message: "-\(name) is not yet supported by email_send in this phase; see Documentation/lasso-perfect-smtp-integration-plan.md §4.3/§6."
            )
        }
        // Phase E (§4.3/§4.7b): `-immediate=false` now has a real landing
        // spot (`LassoEmailJobTracker`-backed deferred sending in
        // `LassoEmailProviderImpl.send`) — no longer thrown here as
        // `notYetSupported`. Only an EXPLICIT `false` defers; absent, or any
        // other truthy value, keeps today's synchronous default.
        let immediateExplicitlyFalse = lastValueIfPresent("immediate", in: arguments)?.isTruthy == false

        guard let fromRaw = arguments.lastString(named: "from"), fromRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LassoSMTPError(kind: .invalidParameter, message: "\(functionName) requires -from.")
        }
        let fromAddresses = try addressList(fromRaw, field: "-from")
        guard fromAddresses.count == 1, let from = fromAddresses.first else {
            throw LassoSMTPError(kind: .invalidParameter, message: "-from must resolve to exactly one address, got \(fromAddresses.count) in '\(fromRaw)'.")
        }

        guard isPresent("subject", in: arguments) else {
            throw LassoSMTPError(kind: .invalidParameter, message: "\(functionName) requires -subject.")
        }
        let subject = arguments.lastString(named: "subject") ?? ""

        let to = try joinedAddressList("to", in: arguments)
        let cc = try joinedAddressList("cc", in: arguments)
        let bccAddresses = try joinedAddressList("bcc", in: arguments)
        let bcc = bccAddresses.map(\.address)

        guard to.isEmpty == false || cc.isEmpty == false || bcc.isEmpty == false else {
            throw LassoSMTPError(kind: .invalidParameter, message: "\(functionName) requires at least one of -to/-cc/-bcc.")
        }

        // -tokens/-merge (Phase F, §4.9c) -- parsed here (pure mapping,
        // no I/O), applied by `LassoEmailProviderImpl.send` as a
        // per-recipient personalized batch send. See this file's doc
        // comment for the real, confirmed semantics.
        let tokens = try tokensMap(arguments)
        let merge = try mergeMap(arguments)
        if (tokens != nil || merge != nil), isPresent("cc", in: arguments) || isPresent("bcc", in: arguments) {
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "-cc/-bcc are not supported together with -tokens/-merge in this phase."
            )
        }
        // Milestone review finding (security pass, §-tokens/-merge):
        // pre-send validation, matching `maximumMergeRecipientCount`'s own
        // doc comment for the full "why this number, why here" reasoning
        // — a pre-send failure (no job recorded), same precedent as the
        // -cc/-bcc rejection immediately above.
        if tokens != nil || merge != nil, to.count > maximumMergeRecipientCount {
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "email_send: -tokens/-merge personalized batch sends are limited to \(maximumMergeRecipientCount) -to recipients, got \(to.count)."
            )
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
        // -contentType: passed through verbatim, unvalidated here --
        // MIMEComposer is the single enforcement point (CRLF-injection,
        // charset=utf-8-only), matching the file doc comment's
        // "-extraMIMEHeaders" precedent.
        message.bodyContentTypeOverride = arguments.lastString(named: "contentType")
        message.bodyTransferEncodingOverride = try transferEncodingOverride(from: arguments.lastString(named: "transferEncoding"))
        // -characterSet (Phase F, §4.9c/§4.3 table, §7 item 6): trivial,
        // zero-ambiguity mapping onto `EmailMessage.charset` -- was simply
        // never wired through when -contentType/-transferEncoding landed
        // in Phase B. Absent -characterSet leaves `EmailMessage`'s own
        // "utf-8" default untouched.
        if let characterSet = arguments.lastString(named: "characterSet") {
            message.charset = characterSet
        }

        let relayName: String? = {
            guard let raw = arguments.lastString(named: "host")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.isEmpty == false else { return nil }
            return raw
        }()

        let pendingAttachments = try collectEntries(arguments, name: "attachments").map(pendingAttachment(from:))
        let pendingInlineImages = try collectEntries(arguments, name: "htmlImages").map(pendingInlineImage(from:))

        // -date: raw value only, unparsed -- see BuildResult.dateValue's own
        // doc comment for why interpretation is deferred to the caller.
        let dateValue = arguments.lastValue(named: "date")

        return BuildResult(
            message: message,
            bcc: bcc,
            envelopeFrom: .address(from.address),
            relayName: relayName,
            pendingAttachments: pendingAttachments,
            pendingInlineImages: pendingInlineImages,
            dateValue: dateValue,
            immediateExplicitlyFalse: immediateExplicitlyFalse,
            tokens: tokens,
            merge: merge
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

    /// See the file doc comment's "Phase B" section for the citations
    /// backing the accepted token set. Case-insensitive; `nil`/empty input
    /// (no `-transferEncoding` given) yields `nil` (no override, matching
    /// `bodyContentTypeOverride`'s own "absent means don't override"
    /// contract).
    private static func transferEncodingOverride(from raw: String?) throws -> ContentTransferEncodingOverride? {
        guard let raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        switch raw.lowercased() {
        case "7bit": return .sevenBit
        case "quoted-printable", "quotedprintable", "quoted_printable": return .quotedPrintable
        case "base64": return .base64
        default:
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "-transferEncoding must be one of '7bit'/'quoted-printable'/'base64' (RFC 2045 §6.1), got '\(raw)'."
            )
        }
    }

    /// Collects every element across all occurrences of a dash-param whose
    /// value is meant to be an array (`-attachments`/`-htmlImages`) —
    /// lassoguide.com's own wording ("This parameter can be specified with
    /// either a single file name or an array of file names") confirms a
    /// bare, non-array value is also legal, so a non-`.array` value is
    /// treated as a single one-element list rather than rejected. Multiple
    /// occurrences of the same dash-param (unconfirmed against real corpus
    /// usage, same judgment call as `joinedAddressList`) are concatenated
    /// rather than "last wins," for the same "at least as reasonable to
    /// merge as to silently drop content" reasoning.
    private static func collectEntries(_ arguments: [EvaluatedArgument], name: String) -> [LassoValue] {
        var entries: [LassoValue] = []
        for argument in arguments where argument.label?.caseInsensitiveCompare(name) == .orderedSame {
            switch argument.value {
            case .array(let items): entries.append(contentsOf: items)
            default: entries.append(argument.value)
            }
        }
        return entries
    }

    /// One `-attachments` array element -> `LassoSMTPPendingAttachment`.
    /// Confirmed shape (lassoguide.com "Sending Email", fetched 2026-07-19,
    /// and the local Lasso 8.5 Language Guide Table 4/Ch. 47, byte-for-byte
    /// consistent): a bare file-path string (`'MyAttachment.txt'`), or a
    /// `name = data` pair (`'MyPDF.pdf' = string(#my_file)`) where `data`
    /// is already-evaluated content, not a third path/type-keyed shape.
    private static func pendingAttachment(from value: LassoValue) throws -> LassoSMTPPendingAttachment {
        switch value {
        case .string(let path):
            return .path(relativePath: path)
        case .pair(let key, let dataValue):
            let filename = key.outputString
            guard filename.isEmpty == false else {
                throw LassoSMTPError(kind: .invalidParameter, message: "-attachments pair entry has an empty filename.")
            }
            return .data(filename: filename, data: dataBytes(from: dataValue))
        default:
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "-attachments entries must be a file path or a name=data pair, got a \(describeShape(value))."
            )
        }
    }

    /// One `-htmlImages` array element -> `LassoSMTPPendingInlineImage`.
    /// Same two-shape contract as `pendingAttachment(from:)` (identical
    /// citations), plus the documented `Content-ID` derivation: "Lasso
    /// automatically uses the image file name as the Content-ID without
    /// any path information" for the path variant (so `cid` is the raw
    /// path's basename, computed here — pure string logic, no I/O); for
    /// the pair variant, "the name that is specified in the first part of
    /// the pair should be used within the HTML body," i.e. the pair's own
    /// name IS the Content-ID, verbatim, not basenamed further.
    private static func pendingInlineImage(from value: LassoValue) throws -> LassoSMTPPendingInlineImage {
        switch value {
        case .string(let path):
            return .path(contentID: LassoSMTPAttachmentLoader.basename(path), relativePath: path)
        case .pair(let key, let dataValue):
            let contentID = key.outputString
            guard contentID.isEmpty == false else {
                throw LassoSMTPError(kind: .invalidParameter, message: "-htmlImages pair entry has an empty name.")
            }
            return .data(contentID: contentID, data: dataBytes(from: dataValue))
        default:
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "-htmlImages entries must be a file path or a name=data pair, got a \(describeShape(value))."
            )
        }
    }

    /// Extracts raw bytes from an already-evaluated `-attachments`/
    /// `-htmlImages` pair's data half. Mirrors `sendfile`'s existing
    /// `-data` handling (`NativeTypes.swift`) for the plain-string case —
    /// this interpreter's real corpus usage overwhelmingly produces
    /// binary-ish content as a lossy-UTF8-decoded `.string` (e.g.
    /// `include_raw`/`string(...)`), so `Data(string.utf8)` is the
    /// correct, precedented re-encoding, not a guess. A `bytes` native
    /// object (`.object` with `typeName == "bytes"`) is decoded from its
    /// lossless `_base64` field instead, when the caller happens to
    /// construct one directly — the exact-bytes path when it's available,
    /// falling back to the lossy string path otherwise. Any other
    /// `LassoValue` case (e.g. `.integer`) falls back to its
    /// `outputString`'s UTF-8 bytes, matching `LassoValue.outputString`'s
    /// own general auto-stringification contract.
    private static func dataBytes(from value: LassoValue) -> Data {
        switch value {
        case .string(let string):
            return Data(string.utf8)
        case .object(let instance) where instance.typeName == "bytes":
            guard case let .string(base64) = instance.value(for: "_base64"), let decoded = Data(base64Encoded: base64) else {
                return Data()
            }
            return decoded
        default:
            return Data(value.outputString.utf8)
        }
    }

    /// `-tokens` (Phase F, §4.9c) -- a Lasso map of token name -> default
    /// value, applied to every recipient. `nil` when `-tokens` wasn't
    /// given at all. Every value is coerced via `outputString`, matching
    /// this file's own established string-coercion convention elsewhere
    /// (e.g. `dataBytes(from:)`'s fallback case, `extraMIMEHeaders`'s
    /// value handling) rather than requiring every value already be a
    /// `.string`.
    private static func tokensMap(_ arguments: [EvaluatedArgument]) throws -> [String: String]? {
        guard let value = arguments.lastValue(named: "tokens") else { return nil }
        guard case let .map(raw) = value else {
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "-tokens must be a map of token name to value, got a \(describeShape(value))."
            )
        }
        var result: [String: String] = [:]
        for (name, tokenValue) in raw {
            result[name] = tokenValue.outputString
        }
        return result
    }

    /// `-merge` (Phase F, §4.9c) -- a Lasso map of recipient address ->
    /// (token name -> value), one entry per personalized recipient — real
    /// Lasso's own documented "Email Merge" shape (lassoguide.com, fetched
    /// 2026-07-20): `-merge=map('a@example.com'=map('FirstName'='...'),
    /// ...)`. `nil` when `-merge` wasn't given at all. Same
    /// `outputString`-based value coercion as `tokensMap(_:)` for each
    /// inner map's values.
    private static func mergeMap(_ arguments: [EvaluatedArgument]) throws -> [String: [String: String]]? {
        guard let value = arguments.lastValue(named: "merge") else { return nil }
        guard case let .map(raw) = value else {
            throw LassoSMTPError(
                kind: .invalidParameter,
                message: "-merge must be a map of recipient address to a map of token name to value, got a \(describeShape(value))."
            )
        }
        var result: [String: [String: String]] = [:]
        for (address, perRecipientValue) in raw {
            guard case let .map(innerRaw) = perRecipientValue else {
                throw LassoSMTPError(
                    kind: .invalidParameter,
                    message: "-merge entries must each be a map of token name to value, got a \(describeShape(perRecipientValue)) for '\(address)'."
                )
            }
            var inner: [String: String] = [:]
            for (name, tokenValue) in innerRaw {
                inner[name] = tokenValue.outputString
            }
            result[address] = inner
        }
        return result
    }

    /// A short, human-readable shape description for error messages —
    /// `LassoValue.typeName` itself is `internal` to `LassoParser`, not
    /// reachable from this target, so this is a small, deliberately
    /// approximate stand-in (exact wording doesn't matter; it only ever
    /// appears inside a caught, catchable error message).
    private static func describeShape(_ value: LassoValue) -> String {
        switch value {
        case .void: "void"
        case .null: "null"
        case .boolean: "boolean"
        case .integer: "integer"
        case .decimal: "decimal"
        case .string: "string"
        case .array: "array"
        case .map: "map"
        case .object: "object"
        case .pair: "pair"
        case .capture: "capture"
        }
    }
}

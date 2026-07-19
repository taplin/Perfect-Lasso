# LassoPerfectSMTP — Integration Plan

Date: 2026-07-19
Status: **Planned, not yet reviewed, not yet implemented.** This document is the output of a research pass against both `/Users/timtaplin/Perfect-Lasso` and `/Users/timtaplin/Perfect-Resurrection/Perfect-SMTP`, followed by an architecture draft. It has not yet been through the parallel expert review this project's other plans go through before implementation starts — see §8 for the review record, filled in once that happens.

## 1. Why this exists, and what it is not

Perfect-SMTP (`/Users/timtaplin/Perfect-Resurrection/Perfect-SMTP`) is a complete, from-scratch Swift 6.2/SwiftNIO SMTP client — implemented across six phases, each independently milestone-reviewed (architecture, concurrency, protocol, security), fully merged to `main`. It was explicitly built to have **zero knowledge of Lasso**: no Lasso-shaped types, no dash-param API, no target inside its own repo for a Lasso adapter. Its own plan document (§4.1, §6) reserved that work for a future, separate task living entirely inside the Perfect-Lasso repository — the same pattern already established by `LassoPerfectFileMaker` and `LassoPerfectCRUD`, which wrap `Perfect-FileMaker`/`Perfect-CRUD` from the outside, as plain consumers of those libraries' public APIs, with zero Lasso-awareness leaking back into the wrapped library.

This document is that future task. It plans a new `LassoPerfectSMTP` target inside Perfect-Lasso that gives `lasso-perfect-server` real, working `email_send`/`email_smtp`/`email_compose`/`email_mxlookup`/`email_result`/`email_status` support, replacing the current no-op stub.

**Scope boundary, restated because it matters:** nothing in this plan modifies Perfect-SMTP. Every requirement below is satisfiable through Perfect-SMTP's existing public API as shipped on its own `main` branch. If a requirement turns out not to be satisfiable that way, that is itself a finding for this plan's review to surface explicitly (see §4.4's `email_smtp` discussion), not a license to reach into Perfect-SMTP and add Lasso-shaped surface to it.

## 2. Current state, verified directly against both codebases

**Perfect-Lasso's existing adapter precedent.** `LassoPerfectFileMaker` and `LassoPerfectCRUD` are both single-file SPM library targets under `Sources/`, each depending on exactly `LassoParser` plus the one resurrected library product they wrap (`Package.swift:32-59`). Each implements `LassoDynamicQueryExecutor` (`Providers.swift:993-995`), a two-method protocol that plugs into the **hardcoded** `"inline"` case in `RendererEngine.render` (`Renderer.swift:252-263`) via a `(any LassoInlineProvider)?` slot on `LassoContext` (`Runtime.swift:1079`). Neither adapter "registers a new tag" — they both reuse the one existing `[inline]` slot. `LassoPerfectSMTP` cannot use this same mechanism, because SMTP sending has no `[inline]`-shaped rows-and-columns result to return — it needs its own dispatch surface (§3).

**Tag/method dispatch is not one registry — it's three separate mechanisms:**
- **(a) Free-function tags**, via `LassoNativeRegistry` (`Runtime.swift:98-116`) — `register(name, function:)` where `function` is `@Sendable (arguments: [EvaluatedArgument], context: inout LassoContext) async throws -> LassoValue`. This is where the existing `email_send` stub already lives.
- **(b) Native-type-with-methods**, via `LassoNativeTypeRegistry`/`LassoNativeType` (`NativeTypes.swift:1-70`) — a type name resolves to `.object(LassoObjectInstance(typeName:))`, and `->method(...)` calls dispatch through `LassoNativeMethod` closures registered on that type. Exactly four built-in types exist today: `web_request`, `web_response`, `date`, `bytes`.
- **(c) Hardcoded block-tag `switch` in `Renderer.swift`** — a fixed, closed set of block-tag names (`inline`, `records`/`rows`, `iterate`, `protect`, `define`, etc.), not extensible without editing the renderer itself. Not relevant to this plan.

**The `email_send` stub, verbatim** (`LassoParser/Runtime.swift:918-930`):
```swift
// [Email_Send] (Lasso 8.5 Language Guide, "Process Tags"): a
// process tag -- "does not return a value" per its own doc -- that
// queues/sends a real email via SMTP (-Host/-To/-From/-Subject/
// -Body etc.). This project has no resurrected SMTP client, so a
// real send isn't possible; ...
register("email_send") { _, _ in .void }
```
The accompanying comment is now stale (Perfect-SMTP exists). A matching regression test, `emailSendIsARegisteredNoOpNotAnUnknownFunction` (`LassoParserTests.swift:5622-5634`), documents the real corpus call shape: `email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b'` — Lasso 8's bare colon-call form, sourced from `importscripts/*.lasso`. `LassoSubsetCrawler.swift:68` also lists `"email_send"` in a recognized-tag-names set for corpus classification.

**No sync/async bridge is needed.** The entire render pipeline — `Evaluator`, `Renderer`, every `LassoNativeFunction`/`LassoNativeMethod` — is `async throws` end to end (confirmed live, and via `Documentation/synchronous-render-pipeline.md`, marked superseded 2026-07-15). `PerfectFileMakerLassoExecutor.execute` awaits `FileMakerServer.query` directly with "no sync/async bridge" per its own doc comment, and `main.swift:1180-1183` awaits the whole render with the same note. `SMTPMailer.send` is itself `async throws` (`PerfectSMTP/SMTPMailer.swift:78-82`), so native closures here `await` straight into it exactly the same way.

**Error propagation — two live mechanisms, and `email_smtp`/`email_send` need the second one.** `LassoDynamicQueryExecutor` conformers (FileMaker/CRUD) catch their own failures and build `LassoInlineFrame(rows: [], error: LassoErrorState(...))`; `LassoContext.pushInlineFrame` (`Runtime.swift:1267-1276`) auto-populates `context.currentError`, readable via `error_currentError`. This mechanism is specific to the `[inline]` frame machinery and **is not available** to a plain native function or native-type method. The other mechanism, `LassoRecoverableError` (`Providers.swift:57-63`), is caught only by `[protect]` (`Renderer.swift:191-212`); anything not caught there propagates as an ordinary thrown Swift error to `main.swift`'s top-level handler and becomes a developer error page. **`email_send`/`email_smtp` will use `LassoRecoverableError`**, since they have no `[inline]` frame to populate.

**Dash-param parsing** — no new infrastructure needed. `Array<EvaluatedArgument>` already exposes `firstValue(named:)`, `lastValue(named:)`, `strings(named:)`, `lastString(named:)`, `lastInt(named:)`, `hasTruthyFlag(_:)`, `positionalValue(at:)` (`Runtime.swift:1381-1418`), used throughout the codebase. `LassoInlineRequest`'s much richer bespoke parser (`Providers.swift:190-377`) is specific to `[inline]`'s comparison-operator vocabulary and isn't a fit here.

**Credential/config source precedent** — `DatasourceFileConfig` (`LassoPerfectServer/main.swift:472-520`), loaded from a `chmod 600` JSON file at `LASSO_DATASOURCE_CONFIG_PATH`, with one top-level block per backend (`filemaker`, `mysql`, `adminAPI`), each with an env-var fallback for the single-datasource smoke-test path. The doc comment's stated rationale — "real credentials belong in this file, not on the command line or in an env var... far more easily leaked" — applies identically to SMTP relay credentials.

**Perfect-SMTP's actual public surface, verified `public` where this plan depends on it:** `SMTPMailer` (`send` single/array/streaming, `composeAndSign`), `EmailMessage`/`EmailAddress`/`Attachment`/`InlineResource` (all `Data`-based, no file-loading), `RelayTransport`/`LocalMTATransport`/`DirectMXTransport` and their `Config` types, `DirectMXConfig.allowPrivateAddresses` (defaults `false`, SSRF filter), `DNSResolver` (`resolveMX`/`resolveAddresses`, `public struct`), `MTASTSPolicy`/`MTASTSPolicyManager` (`public actor`), `DKIMSigner`/`SigningKey` (`public`, in `PerfectSMTPCore`).

**Address-list parsing — genuinely absent everywhere.** Both Lasso versions document `-to`/`-cc`/`-bcc` as always a single comma-delimited string, never a native array, never repeated params (8.5 Language Guide p. 590: "Multiple -To, -CC, or -BCC parameters are not allowed"). A quoted display name can legally contain a comma (`"Smith, John" <j@x.com>, other@y.com`). Neither repo has an RFC-5322-aware, quote-comma-aware splitter — `string->split` (`Evaluator.swift:507-514`) and `valid_email`'s `-Domain` list-split (`Runtime.swift:589`) are both naive `.split(separator: ",")`, and `Perfect-SMTP`'s `EmailAddress` expects callers to already have an array. This has to be written from scratch (§4.2).

## 3. Lasso 8.5/9 email API surface (from Perfect-SMTP plan §6, restated here as the authoritative source for this plan)

Both Lasso versions ship a first-class, near-identically-named built-in email API — `[Email_Send]` (8.5, Language Guide Ch. 47) and `email_send` (9, now a method, lassoguide.com) — not an external binding, and Lasso 9 kept essentially every 8.5 parameter name verbatim (lowercased). There is no `Send_Mail` tag in 8.5; the pre-8.0 `-Email.*` dash-command syntax explicitly does not operate in Lasso 8.

**Full shared parameter surface** (identical semantics both versions): `-to`/`-from`/`-subject` (from+subject always required, one of to/cc/bcc required), `-body`/`-html` (one required, both → multipart/alternative), `-cc`/`-bcc`, `-htmlImages` (array of paths OR array of `name=data` pairs, `cid:`/`src`-matched), `-attachments` (array of paths OR `name=data` pairs, base64-encoded, **both versions document an 8MB total-size ceiling for this send path**), `-tokens`/`-merge` (mail merge), `-priority` (`High`/`Low`, default `Medium`), `-replyTo`, `-sender`, `-contentType`/`-transferEncoding`/`-characterSet` (raw overrides, neither version documents a default), `-extraMIMEHeaders`, `-immediate`, `-host`/`-port` (default 25)/`-username`/`-password`/`-timeout`.

**Lasso-9-only additions:** `-ssl` (boolean, undifferentiated implicit-vs-STARTTLS), `-date` (schedule a future send), `-simpleform` (send with no body), and on `email_smtp`: `-clientIp` (HELO/EHLO identity), `-multi`.

**The one 8.5→9 incompatibility:** 8.5's `-ContentDisposition` (default `'attachment'`) lives directly on `[Email_Send]`; Lasso 9 moved it to `email_compose` only, dropped from `email_send`'s own params.

**Companion surface:** `email_compose` (build-then-send, two-phase), `email_smtp` (low-level connection type — `->open`/`->command(-send,-expect,-multi,-read)`/`->send`/`->close`), `email_mxlookup(domain, -refresh, -hostname)` (MX resolution with a `priority` field), `email_result`/`email_status` (async job ID + polling — Lasso's email model has always been queue-based, never fire-and-forget-synchronous).

## 4. Target architecture

### 4.1 Package/target layout

```
Perfect-Lasso/
  Package.swift                          — add Perfect-SMTP to dependencies[], add
                                            .library(name: "LassoPerfectSMTP", ...) product
  Sources/LassoPerfectSMTP/
    LassoSMTPAddressList.swift           — RFC 5322-aware -to/-cc/-bcc tokenizer (§4.2)
    LassoSMTPMessageBuilder.swift        — dash-params -> EmailMessage/ReversePath
    LassoSMTPAttachmentLoader.swift      — path-or-inline attachment/htmlImage resolution (§4.5)
    LassoSMTPMailerRegistry.swift        — server-lifetime shared SMTPMailer(s) (§4.6)
    LassoEmailSendFunction.swift         — email_send, email_compose (native functions)
    LassoEmailSMTPType.swift             — email_smtp (native type)
    LassoEmailMXLookupFunction.swift     — email_mxlookup (native function)
    LassoEmailJobTracker.swift           — email_result/email_status backing store (§4.7)
    LassoSMTPError.swift                 — LassoRecoverableError-producing error model
  Tests/LassoPerfectSMTPTests/
```

One target, following the `LassoPerfectFileMaker`/`LassoPerfectCRUD` naming and dependency convention exactly (`LassoParser` + `.product(name: "PerfectSMTP", package: "Perfect-SMTP")`), split into multiple files unlike the single-file precedent, because this adapter's surface (three dispatch mechanisms, address parsing, attachment loading, job tracking) is meaningfully larger than either existing adapter's.

### 4.2 Address-list parsing (new, standalone, testable independent of everything else)

`LassoSMTPAddressList.parse(_ raw: String) -> [EmailAddress]` (or `throws` on genuinely malformed input — decide during implementation whether a malformed entry should drop silently or hard-fail the whole send; lean toward hard-fail, matching this adapter's general fail-loud posture per §4.3). Must handle: bare `addr@example.com`, `Display Name <addr@example.com>`, `"Quoted, Name" <addr@example.com>` (comma inside quotes must not split), multiple entries comma-separated, and reasonable whitespace tolerance. This is pure string parsing, no I/O, no Lasso runtime dependency beyond the input string — write and test it standalone before wiring it into anything else.

### 4.3 `email_send` / `email_compose` (Phase A/C — the core, and the natural first landing point)

Replace `Runtime.swift:918-930`'s no-op registration with a real implementation. Update the stale comment and `emailSendIsARegisteredNoOpNotAnUnknownFunction`'s expectation (it currently asserts `.void`/no-op — decide whether the real implementation still returns `.void` per `[Email_Send]`'s own "does not return a value" doc, or something else; 8.5's own documentation says it returns nothing, so `.void` is likely still correct even once it actually sends).

Parameter mapping (using §3's full shared surface):

| Dash-param | Maps to |
|---|---|
| `-to`/`-cc`/`-bcc` | `LassoSMTPAddressList.parse(...)` → `EmailMessage.to`/`.cc` / extra `SMTPEnvelope.recipients` (bcc — **never** `EmailMessage`, matching Perfect-SMTP's own structural Bcc-leak fix; see `SMTPMailer.send(_:bcc:envelopeFrom:)`) |
| `-from` | `EmailAddress` → `EmailMessage.from` |
| `-subject` | `EmailMessage.subject` |
| `-body`/`-html` | `EmailMessage.textBody`/`.htmlBody` |
| `-replyTo` | `EmailMessage.replyTo` |
| `-sender` | `EmailMessage.sender` |
| `-priority` | `EmailMessage.priority` (`High`/`Low`/default `Medium` → `.high`/`.low`/`.normal`) |
| `-contentType`/`-transferEncoding`/`-characterSet` | `EmailMessage.charset` where applicable; `-contentType`/`-transferEncoding` as raw overrides need checking against what `MIMEComposer` actually exposes as caller-overridable — **flag for review, may not have a 1:1 landing spot today** |
| `-extraMIMEHeaders` | `EmailMessage.extraHeaders` (already denylist-protected against Bcc/To/Cc/From/Return-Path reintroduction — Perfect-SMTP Phase 0) |
| `-tokens`/`-merge` | Mail-merge templating — **not a Perfect-SMTP concern at all**; this is pure string substitution the adapter must do itself, before ever constructing an `EmailMessage`, entirely inside `LassoPerfectSMTP` |
| `-immediate` | Maps to transport/queueing choice — `true` (or absent, likely the common case) → synchronous `SMTPMailer.send` now; `false` → hand off to `LassoEmailJobTracker` (§4.7) for async completion |
| `-host`/`-port`/`-username`/`-password` | Per-call override of the server-config-sourced `RelayConfig` (§4.6) — **only when explicitly given**; absent params use the configured default relay, never a bare unauthenticated connection to a caller-supplied arbitrary host unless the operator's config explicitly allows it (SSRF concern, §4.8) |
| `-timeout` | One value, no phase distinction in Lasso's model — map to `RelayConfig`'s connect timeout as the most user-visible one; document that Perfect-SMTP's own per-phase timeouts (reply, DATA-termination) aren't independently reachable through this one param |
| `-ssl` (Lasso 9 only) | `true` → `.startTLS` unless `-port=465` is also given, in which case `.implicit`; `false`/absent → whatever the configured relay's own `tls` mode is (do not silently force plaintext) |
| `-date` (Lasso 9 only) | Scheduled future send — **no Perfect-SMTP equivalent at all**; either implement via `LassoEmailJobTracker` holding the message until due (new adapter-side scheduling, not just wiring), or explicitly scope out of Phase A/C with a clear "not yet supported" error rather than silently ignoring `-date` and sending immediately |
| `-simpleform` (Lasso 9 only) | Send with no body — should just work naturally if `textBody`/`htmlBody` are both left nil, verify `MIMEComposer` doesn't reject an empty-body message |
| `-ContentDisposition` (8.5) | `EmailMessage.defaultDisposition`, per Perfect-SMTP's own already-resolved 8.5→9 routing note (§4.7 of the Perfect-SMTP plan) |

`email_compose` is the two-phase variant: build an `EmailMessage`/composed form without sending (mirrors `SMTPMailer.composeAndSign`'s existing two-phase shape almost exactly), returning something the caller can later hand to a send call. Land this alongside `email_send` in the same phase since the parameter-mapping work is identical.

### 4.4 `email_mxlookup`

A free function wrapping `DNSResolver.resolveMX(domain:)`, which already returns preference-ordered `MXRecord { preference, exchange }` — close to a direct pass-through. `-refresh` (bypass cache) has no obvious Perfect-SMTP hook today (`DNSResolver` doesn't cache at all — only `MTASTSPolicyManager` does — so `-refresh` may simply be a no-op here, always-fresh by construction; confirm and document rather than silently assuming). `-hostname` (reverse-lookup variant, if that's what it means in the real docs — verify against lassoguide.com during implementation, this plan's research didn't independently re-confirm `-hostname`'s exact semantics beyond the Perfect-SMTP plan's one-line mention).

### 4.5 Attachments / inline images — new file-loading capability, security-relevant

`-attachments`/`-htmlImages` each accept either an array of `name=data` pairs (maps directly onto `Attachment`/`InlineResource`, both already `Data`-based) or an array of filesystem paths — Perfect-SMTP has **no file I/O anywhere in it**, so path-based loading is entirely new adapter-side code.

`LassoSMTPAttachmentLoader` must resolve a path-string to `Data` with an explicit containment policy — **decide this during implementation, don't default to "read whatever path shows up"**: candidates are (a) resolve relative to a configured site root and reject any resolved path outside it (symlink-aware — a symlink inside the site root pointing outside it must also be rejected, not just a literal `../` string check), or (b) require an explicit per-server allowlist of readable directories. Enforce the documented 8MB total-size ceiling (§3) here, summed across all attachments+inline images for one send — Perfect-SMTP has no size cap of its own to lean on.

### 4.6 Shared mailer lifetime and relay configuration

A `LassoSMTPMailerRegistry` (actor, mirroring `FileMakerConnectionRegistry`'s role) built once at server startup from a new `smtp` block in `DatasourceFileConfig`:
```json
{
  "smtp": {
    "host": "...", "port": 587, "user": "...", "password": "...",
    "tls": "startTLS", "allowDirectMX": false, "dkimKeyPath": "...", "dkimSelector": "...", "dkimDomain": "..."
  }
}
```
plus `LASSO_SMTP_*` env-var fallbacks for the single-datasource smoke-test path, matching the `filemaker`/`mysql` blocks exactly. Holds one long-lived `SMTPMailer` (built over `RelayTransport`, so `SMTPConnectionPool`'s pooling/circuit-breaking is actually realized across many `email_send` calls in one server process) rather than constructing a fresh transport per call. If `-host`/`-port`/etc. are given per-call (§4.3), decide whether that spawns a short-lived, unpooled `SMTPMailer` for that one call, or is rejected/ignored when it doesn't match the configured relay — **this is a real design choice with SSRF implications, see §4.8**, not a detail to leave implicit.

### 4.7 `email_result`/`email_status` — net-new job tracking, no Perfect-SMTP equivalent

Perfect-SMTP's own plan deliberately never built an `enqueue`/`status(of:)` API (recorded as an explicit, reviewed deferral — nothing else in that library needed it). Lasso's model assumes one exists. `LassoEmailJobTracker` (actor) needs: a job-ID scheme (`UUID`, presumably rendered as a Lasso string), an in-memory `[JobID: JobState]` store (explicitly in-memory-only, matching this whole ecosystem's established "this is a library/server process, not a durable-across-restart daemon" posture — see `DirectMXRetryQueue`'s and `MTASTSPolicyManager`'s identical documented scope boundaries in Perfect-SMTP itself), and a bridge from `-immediate=false`/`-date`-scheduled sends into background `Task`s that eventually call `SMTPMailer.send` and record the resulting `DeliveryResult`s against the job ID. **Design this as its own self-contained piece** — it's the most novel, least-precedented part of this plan after `email_smtp` (§4.4 below), and shouldn't be treated as an incidental side effect of wiring `-immediate=false`.

### 4.8 `email_smtp` — the open design question, not a settled decision

No native type in this codebase today holds a live external resource (an open connection) across a sequence of `->method` calls — `date`/`bytes` store only `LassoValue`-representable data on the `LassoObjectInstance`; `web_request`/`web_response` store nothing and read a `LassoContext` side-channel slot instead. Two candidate designs, genuinely undecided pending review:

- **Stateless-envelope model** (closer to `date`/`bytes`): `->open`/`->command` accumulate plain `LassoValue`s (recipients, headers, body fragments) onto the object; `->send` is the only call touching the network, building an `EmailMessage` from the accumulated state and calling `SMTPMailer.send` once. Needs zero new Perfect-SMTP surface. Doesn't give real fidelity to `->command(-send,-expect,-multi,-read)`'s actual raw-protocol-command semantics.
- **Live-session model**: a new `LassoEmailSMTPRegistry` actor (mirroring `FileMakerConnectionRegistry`) holding real connection state keyed by an opaque session-ID `.string` carried on the object. Requires new public surface on Perfect-SMTP — today only `SMTPMailer`/the transports are public; `SMTPConnection` (the actual command-level handle) is not exposed. This is real, cross-repo work: a small, carefully-scoped addition to Perfect-SMTP's public API (not a violation of its "no Lasso knowledge" boundary, since the new surface would be generically useful to any caller wanting raw command-level control, not Lasso-shaped) — flagged here explicitly rather than assumed, since it means this phase can't be scoped to Perfect-Lasso alone.

**Recommendation carried into this plan, pending review:** ship the stateless-envelope model first (Phase D), explicitly deferring the live-session model — matching this project's own established pattern of picking the narrower, already-buildable option and recording the wider one as a documented future decision (the same shape as the DANE deferral in Perfect-SMTP's own plan). Real corpus usage of `email_smtp`'s raw `->command` interface, if any exists, should inform whether the live-session model is ever actually needed — this should be checked against real Lasso code (a corpus crawl, similar to how `email_send`'s corpus usage was already found) before committing effort to it.

## 5. Cross-cutting concerns

**SSRF exposure via `email_send`'s `-host`/`-to`.** A Lasso page that reads `-to` (or, worse, `-host`) from an untrusted request parameter and hands it straight to `email_send` is exactly the threat model `DirectMXConfig.allowPrivateAddresses` (default `false`) exists to defend against. `email_send`'s default path must never resolve MX/A/AAAA and connect directly to whatever a caller-influenced domain returns — it should route through the operator-configured relay (§4.6) unless an operator explicitly opts a site into direct-MX via server config. Per-call `-host` overrides (§4.3) should be treated with the same suspicion: either disallowed by default, or gated behind an explicit operator opt-in flag in the `smtp` config block, not implicitly trusted just because a Lasso developer wrote `-host=$queryParam`.

**Credential handling.** Follows §2's `DatasourceFileConfig` precedent directly — no new pattern needed, just a new block.

**DKIM/MTA-STS exposure.** These are operator/security-posture decisions (which domain signs with which key, whether MTA-STS enforcement is on) — they belong in the `smtp` server-config block (§4.6), not as per-`email_send`-call dash-params. Lasso's own dash-param surface (§3) has no DKIM/MTA-STS concept at all, which is a convenient forcing function: there's no legacy behavior to preserve here, so this can be designed cleanly rather than mapped from an existing param.

**Testing strategy.** `LassoSMTPAddressList` (§4.2) needs pure unit tests with the quote/comma edge cases called out explicitly. `email_send`/`email_compose`/`email_mxlookup` need tests exercising the actual Lasso parser/evaluator end-to-end (matching `LassoParserTests.swift`'s existing style), against Perfect-SMTP's already-established fake-server test patterns (`STARTTLSRealSocketTests`, `DirectMXRealSocketTests`) rather than a new mocking layer — reuse, don't reinvent. `LassoSMTPAttachmentLoader`'s path-containment logic needs adversarial tests (`../` traversal, symlink escape, size-ceiling enforcement) given its security relevance. `email_smtp`/`email_result`/`email_status` test strategy depends on which design (§4.8) is chosen.

## 6. Phasing

- **Phase A — `email_send` core.** Replace the stub; `-to`/`-cc`/`-bcc`/`-from`/`-subject`/`-body`/`-html`/`-replyTo`/`-sender`/`-priority`/`-extraMIMEHeaders`. Requires §4.2 (address parsing), §4.6 (shared mailer + config block), §5's SSRF-safe default. **First genuinely usable release** — covers the actual corpus usage already found (`importscripts/*.lasso`).
- **Phase B — Attachments/inline images.** `-attachments`/`-htmlImages` both shapes, `-contentType`/`-transferEncoding`/`-characterSet`, `-ContentDisposition`. Requires §4.5's path-containment design.
- **Phase C — `email_compose`, `email_mxlookup`.**
- **Phase D — `email_smtp`.** Design decision (§4.8) resolved first, then implemented — stateless-envelope model per this plan's current recommendation, live-session model explicitly deferred pending real corpus evidence it's needed.
- **Phase E — `email_result`/`email_status`.** The net-new job-tracking layer (§4.7), plus `-immediate`/`-date` wiring from Phase A.
- **Phase F — Operator-level policy.** DKIM key config, MTA-STS enforcement toggle, direct-MX opt-in, `-ssl`/`-tokens`+`-merge` mail-merge templating if not already folded into an earlier phase.

Each phase gets its own branch and its own milestone review (architecture, concurrency, protocol, security), matching this project's established discipline — no phase merges to `main` without one, same as Perfect-SMTP's own six phases.

## 7. Open decisions requiring explicit sign-off before implementation starts

1. **`email_smtp`'s design (§4.8)** — stateless-envelope (recommended) vs. live-session (requires new Perfect-SMTP public surface).
2. **`-date` scheduled-send (§4.3)** — implement via job-tracker scheduling in Phase E, or explicit "not yet supported" error in Phase A rather than silent immediate-send.
3. **Per-call `-host` override's SSRF posture (§4.3, §5)** — disallowed by default vs. operator-opt-in flag.
4. **Attachment path-containment policy (§4.5)** — site-root-relative vs. explicit allowlist.

## 8. Review record

*(To be filled in after the parallel expert review pass — architecture/Lasso-runtime-accuracy, concurrency, security. Not yet run as of this document's initial draft.)*

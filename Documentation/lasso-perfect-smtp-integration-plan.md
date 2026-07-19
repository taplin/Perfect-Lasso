# LassoPerfectSMTP — Integration Plan

Date: 2026-07-19
Status: **Reviewed once (architecture/Lasso-runtime-accuracy, concurrency, security), corrected, not yet implemented.** This document is the output of a research pass against both `/Users/timtaplin/Perfect-Lasso` and `/Users/timtaplin/Perfect-Resurrection/Perfect-SMTP`, an architecture draft, and a full parallel review pass that found one architecturally load-bearing gap in the original draft — see §4.0, added in response, and §9 (review record) for the full history.

## 1. Why this exists, and what it is not

Perfect-SMTP (`/Users/timtaplin/Perfect-Resurrection/Perfect-SMTP`) is a complete, from-scratch Swift 6.2/SwiftNIO SMTP client — implemented across six phases, each independently milestone-reviewed (architecture, concurrency, protocol, security), fully merged to `main`. It was explicitly built to have **zero knowledge of Lasso**: no Lasso-shaped types, no dash-param API, no target inside its own repo for a Lasso adapter. Its own plan document (§4.1, §6) reserved that work for a future, separate task living entirely inside the Perfect-Lasso repository — the same pattern already established by `LassoPerfectFileMaker` and `LassoPerfectCRUD`, which wrap `Perfect-FileMaker`/`Perfect-CRUD` from the outside, as plain consumers of those libraries' public APIs, with zero Lasso-awareness leaking back into the wrapped library.

This document is that future task. It plans a new `LassoPerfectSMTP` target inside Perfect-Lasso that gives `lasso-perfect-server` real, working `email_send`/`email_smtp`/`email_compose`/`email_mxlookup`/`email_result`/`email_status` support, replacing the current no-op stub.

**Scope boundary, restated because it matters:** nothing in this plan modifies Perfect-SMTP's *public API surface as a Lasso-shaped thing* — Perfect-SMTP gains no Lasso types, no dash-param handling, no knowledge Lasso exists. It does, however, turn out that this plan's own dispatch-registration problem (§4.0) requires new, generic, Lasso-agnostic protocol surface inside `LassoParser` itself (not Perfect-SMTP) — that is a correction from this plan's first draft, found during review, not a violation of the "zero Lasso knowledge" boundary, which only ever applied to Perfect-SMTP.

## 2. Current state, verified directly against both codebases

**Perfect-Lasso's existing adapter precedent.** `LassoPerfectFileMaker`, `LassoPerfectCRUD`, and `LassoPerfectSession` are all single-file SPM library targets under `Sources/`, each depending on exactly `LassoParser` plus the one resurrected library product they wrap (`Package.swift:32-59`). The FileMaker/CRUD adapters implement `LassoDynamicQueryExecutor` — **corrected during review: this is a one-method protocol** (`Providers.swift:993-995`: `func execute(_ request: LassoInlineRequest) async throws -> LassoInlineFrame`), not two as this plan's first draft claimed — that plugs into the **hardcoded** `"inline"` case in `RendererEngine.render` (`Renderer.swift:252-263`) via a `(any LassoInlineProvider)?` slot on `LassoContext` (`Runtime.swift:1079`). `LassoInlineProvider` is likewise one method (`executeInline`, `Providers.swift:989-991`). Neither adapter "registers a new tag" — they both reuse the one existing `[inline]` slot, populated per-request from `main.swift`. `LassoPerfectSession` follows the identical shape via its own `sessionProvider` slot.

**This "reuse an existing context slot" pattern is the ENTIRE precedent this codebase has for wiring an outside target into the interpreter — and it does not cover what this plan needs.** See §4.0.

**Tag/method dispatch is not one registry — it's three separate mechanisms:**
- **(a) Free-function tags**, via `LassoNativeRegistry` (`Runtime.swift:98-116`) — `register(name, function:)` where `function` is `@Sendable (arguments: [EvaluatedArgument], context: inout LassoContext) async throws -> LassoValue`. This is where the existing `email_send` stub already lives, registered inside `LassoNativeRegistry.registerDefaultFunctions()`, a **`private mutating func` inside the `LassoParser` target itself**.
- **(b) Native-type-with-methods**, via `LassoNativeTypeRegistry`/`LassoNativeType` (`NativeTypes.swift:1-70`) — a type name resolves to `.object(LassoObjectInstance(typeName:))`, and `->method(...)` calls dispatch through `LassoNativeMethod` closures registered on that type. Exactly four built-in types exist today: `web_request`, `web_response`, `date`, `bytes` — all registered by `registerDefaultTypes()`, also inside `LassoParser`.
- **(c) Hardcoded block-tag `switch` in `Renderer.swift`** — a fixed, closed set of block-tag names, not extensible without editing the renderer itself. Not relevant to this plan.

**The `email_send` stub, verbatim** (`LassoParser/Runtime.swift:918-930`):
```swift
// [Email_Send] (Lasso 8.5 Language Guide, "Process Tags"): a
// process tag -- "does not return a value" per its own doc -- that
// queues/sends a real email via SMTP (-Host/-To/-From/-Subject/
// -Body etc.). This project has no resurrected SMTP client, so a
// real send isn't possible; ...
register("email_send") { _, _ in .void }
```
The accompanying comment is now stale. A matching regression test, `emailSendIsARegisteredNoOpNotAnUnknownFunction` (`LassoParserTests.swift:5622-5634`), documents the real corpus call shape: `email_send: -to='a@example.com', -from='b@example.com', -subject='s', -body='b'` — Lasso 8's bare colon-call form, sourced from `importscripts/*.lasso`.

**No sync/async bridge is needed.** The entire render pipeline — `Evaluator`, `Renderer`, every `LassoNativeFunction`/`LassoNativeMethod` — is `async throws` end to end (confirmed live, and via `main.swift:1172-1183`'s doc comment stating no bridge is needed). `SMTPMailer.send` is itself `async throws` (`PerfectSMTP/SMTPMailer.swift:78-82`), so native closures `await` straight into it once dispatch is solved (§4.0).

**Error propagation — two live mechanisms, and `email_smtp`/`email_send` need the second one.** `LassoDynamicQueryExecutor` conformers auto-populate `context.currentError` via `LassoInlineFrame`'s error field — specific to the `[inline]` frame machinery, not available to a plain native function/method. `LassoRecoverableError` (`Providers.swift:57-63`) is caught only by `[protect]` (`Renderer.swift:191-212`); anything not caught there becomes a developer error page. **`email_send`/`email_smtp` will throw `LassoRecoverableError`.**

**Dash-param parsing** — no new infrastructure needed. `Array<EvaluatedArgument>` already exposes `firstValue(named:)`, `lastValue(named:)`, `strings(named:)`, `lastString(named:)`, `lastInt(named:)`, `hasTruthyFlag(_:)`, `positionalValue(at:)` (`Runtime.swift:1382-1418`).

**Credential/config source precedent** — `DatasourceFileConfig` (`LassoPerfectServer/main.swift:472-520`), loaded from a JSON file at `LASSO_DATASOURCE_CONFIG_PATH`, one top-level block per backend, env-var fallback per block. **Correction from review: the "chmod 600" convention this file's own doc comment recommends is documentation-only — no code anywhere in `main.swift` actually stats the file or enforces permissions at load time.** Acceptable for a rotatable password; not sufficient on its own for a DKIM private key (§4.6, §5).

**`FileMakerConnectionRegistry` does not do what this plan's first draft assumed — corrected during review, two independent reviews caught this.** It holds **no live connection or pool at all**. Read in full (`Sources/LassoPerfectServer/FileMakerConnectionRegistry.swift`): it's a pure `alias -> (host, port)` *resolution table*, built solely for the admin console's live "switch datasource" feature (`resolve(alias:)`, `switchAlias(_:to:)`). The actual FileMaker connection strategy is confirmed to be the deliberate opposite of pooling — `main.swift:833-839`'s own comment states a **fresh `FileMakerServer` per call**, "even though the resurrected `FileMakerServer` is now natively Sendable and could safely be built once and captured," to match pre-resurrection behavior. This plan's proposed shared, pooled `SMTPMailer` (§4.6) is still the right design on its own merits — SMTP is a genuinely stateful protocol session in a way FileMaker's HTTP-based Data API isn't, and `SMTPConnectionPool` exists specifically to make pooling safe and worthwhile — but it is **not** precedented by `FileMakerConnectionRegistry`, and the plan should not claim it is.

**Perfect-SMTP's actual public surface, verified `public`, including one significant correction:** `SMTPMailer` (`send` single/array/streaming, `composeAndSign`), `EmailMessage`/`EmailAddress`/`Attachment`/`InlineResource` (`Data`-based, no file-loading), `RelayTransport`/`LocalMTATransport`/`DirectMXTransport` and their `Config` types, `DirectMXConfig.allowPrivateAddresses` (defaults `false`, SSRF filter — **confirmed this filtering exists only on `DirectMXTransport`; `RelayConfig`/`RelayTransport` has no equivalent field at all**, see §5), `DNSResolver`, `MTASTSPolicy`/`MTASTSPolicyManager`, `DKIMSigner`/`SigningKey`. **Correction from review: `SMTPConnection` (`public final class`, `SMTPConnection.swift`), `SMTPBootstrap.connect` (`public static func`, `SMTPBootstrapHandler.swift:54`), and `SMTPConnectionPool.withConnection` (`public func`, `SMTPConnectionPool.swift:224`) are ALL already public today** — the original draft's claim that `email_smtp`'s live-session design "requires new public surface on Perfect-SMTP" was wrong. See §4.8.

**Address-list parsing — genuinely absent everywhere,** confirmed unchanged from the first draft: neither repo has an RFC-5322-aware, quote-comma-aware splitter. Has to be written from scratch (§4.2).

## 3. Lasso 8.5/9 email API surface (from Perfect-SMTP plan §6, restated here as the authoritative source for this plan)

Both Lasso versions ship a first-class, near-identically-named built-in email API — `[Email_Send]` (8.5, Language Guide Ch. 47) and `email_send` (9, now a method, lassoguide.com) — not an external binding, and Lasso 9 kept essentially every 8.5 parameter name verbatim (lowercased). There is no `Send_Mail` tag in 8.5.

**Full shared parameter surface:** `-to`/`-from`/`-subject` (from+subject always required, one of to/cc/bcc required), `-body`/`-html` (one required, both → multipart/alternative), `-cc`/`-bcc`, `-htmlImages` (array of paths OR array of `name=data` pairs), `-attachments` (array of paths OR `name=data` pairs, **8MB total-size ceiling documented by both versions**), `-tokens`/`-merge` (mail merge), `-priority` (`High`/`Low`, default `Medium`), `-replyTo`, `-sender`, `-contentType`/`-transferEncoding`/`-characterSet`, `-extraMIMEHeaders`, `-immediate`, `-host`/`-port` (default 25)/`-username`/`-password`/`-timeout`.

**Lasso-9-only additions:** `-ssl`, `-date` (schedule a future send), `-simpleform` (send with no body), and on `email_smtp`: `-clientIp` (HELO/EHLO identity), `-multi`.

**The one 8.5→9 incompatibility:** 8.5's `-ContentDisposition` lives directly on `[Email_Send]`; Lasso 9 moved it to `email_compose` only.

**Companion surface:** `email_compose` (build-then-send, two-phase), `email_smtp` (low-level connection type — `->open`/`->command(-send,-expect,-multi,-read)`/`->send`/`->close`), `email_mxlookup(domain, -refresh, -hostname)`, `email_result`/`email_status` (async job ID + polling).

## 4. Target architecture

### 4.0 The dispatch-registration seam — found missing during review, must be designed before any other phase can start

**This section did not exist in the first draft. It is the single most important correction from the review pass, and it changes the shape of every other section below.**

The original draft instructed "replace `Runtime.swift:918-930`'s no-op registration with a real implementation" as if that were a simple in-place edit. It is not. That registration lives inside `LassoNativeRegistry.registerDefaultFunctions()`, a `private mutating func` **inside the `LassoParser` target**, whose `Package.swift` dependencies are `Crypto` only — zero awareness of any resurrected library, by design, matching the same "zero knowledge" boundary Perfect-SMTP itself follows in the other direction. If that closure were rewritten to call `SMTPMailer.send` directly, `LassoParser` would need to `import PerfectSMTP`, which breaks the layering this entire ecosystem is built on (a core interpreter target must never depend on a specific resurrected library — `LassoPerfectFileMaker`/`LassoPerfectCRUD`/`LassoPerfectSession` all exist specifically so `LassoParser` never has to).

The existing three adapters never actually solve "add new dispatch surface from outside `LassoParser`" — they all reuse a **pre-existing, protocol-typed context slot** already designed into `LassoContext` (`inlineProvider`, `sessionProvider`, `requestProvider`; confirmed `public var` at `Runtime.swift:1075-1079`), populated per-request from `main.swift`. `LassoContext.natives`/`.nativeTypes` are technically `public var` and could in principle be swapped out via `LassoContext.init(natives:nativeTypes:...)`, but **no code anywhere does this today** — it is an unused, undesigned integration seam, not an established pattern.

**Required new design, split across both repos:**

1. **In `LassoParser`**: define a new, generically-named (Lasso-shaped, not SMTP-shaped) protocol on `LassoContext`, following the exact shape of `inlineProvider`/`sessionProvider` — e.g. `public protocol LassoEmailProvider: Sendable { func send(_ arguments: [EvaluatedArgument]) async throws -> LassoValue; /* ...compose, mxLookup, ... */ }` with a new `public var emailProvider: (any LassoEmailProvider)?` slot on `LassoContext`. Rewrite the existing `email_send` (and new `email_compose`/`email_mxlookup`) registrations in `registerDefaultFunctions()` to check `context.emailProvider` and either delegate to it or fall through to today's no-op/error behavior when it's `nil` (mirroring how `"inline"` behaves when `inlineProvider` is unset — throws `LassoRuntimeError.inlineNotConfigured` rather than silently no-op'ing, per `Renderer.swift`'s existing pattern; the new email functions should do the same rather than reverting to the current silent `.void` no-op once this exists).
2. **In `LassoPerfectSMTP`**: a concrete `LassoEmailProvider` conformer wrapping `SMTPMailer`, wired into `LassoContext` from `main.swift` exactly like `inlineProvider` is today.
3. **`email_smtp` is a harder, separate problem**, because it needs mechanism (b) — a native *type* — and **no side-channel-slot equivalent exists for native types at all**. `LassoNativeTypeRegistry.register(_:)` only accepts types built entirely inside `LassoParser` today; there is no `LassoContext`-level slot analogous to `inlineProvider` that a native type's methods can delegate through. This needs its own design, likely a second, type-specific protocol slot (`emailSMTPProvider` or similar) that `email_smtp`'s methods (also newly added to `registerDefaultTypes()` in `LassoParser`, gated behind that slot the same way) delegate to — do not assume this is a smaller version of problem 1 above; scope it explicitly once problem 1 is solved and reviewed, since it may surface its own complications.

This is real, reviewable design work in `LassoParser` itself, not just new files in a new target — it should be scoped, implemented, and milestone-reviewed as its own deliverable at the start of Phase A (§8), before `email_send`'s actual parameter mapping is implemented, since nothing else in this plan can be exercised end-to-end until it exists.

### 4.1 Package/target layout

```
Perfect-Lasso/
  Sources/LassoParser/
    (new: LassoEmailProvider protocol + emailProvider context slot, §4.0 problem 1;
     new native-type dispatch slot for email_smtp, §4.0 problem 3 -- scoped separately)
  Package.swift                          — add Perfect-SMTP to dependencies[], add
                                            .library(name: "LassoPerfectSMTP", ...) product
  Sources/LassoPerfectSMTP/
    LassoSMTPAddressList.swift           — RFC 5322-aware -to/-cc/-bcc tokenizer (§4.2)
    LassoSMTPMessageBuilder.swift        — dash-params -> EmailMessage/ReversePath
    LassoSMTPAttachmentLoader.swift      — path-or-inline attachment/htmlImage resolution (§4.5)
    LassoSMTPMailerRegistry.swift        — server-lifetime shared SMTPMailer(s) (§4.6)
    LassoEmailProviderImpl.swift         — the LassoEmailProvider conformer (§4.0 problem 2)
    LassoEmailSMTPType.swift             — email_smtp (§4.0 problem 3 + §4.8)
    LassoEmailJobTracker.swift           — email_result/email_status backing store (§4.7)
    LassoSMTPError.swift                 — LassoRecoverableError-producing error model
  Tests/LassoPerfectSMTPTests/
```

### 4.2 Address-list parsing (unchanged from first draft, not touched by review)

`LassoSMTPAddressList.parse(_ raw: String) -> [EmailAddress]` (or `throws` on malformed input — lean toward hard-fail). Must handle bare addresses, `Display Name <addr>`, `"Quoted, Name" <addr>` (comma inside quotes must not split), multiple comma-separated entries. Pure string parsing, no I/O — write and test standalone.

### 4.3 `email_send` / `email_compose` (Phase A/C core, once §4.0 exists)

Parameter mapping, corrected per review:

| Dash-param | Maps to |
|---|---|
| `-to`/`-cc` | `LassoSMTPAddressList.parse(...)` → `EmailMessage.to`/`.cc` |
| `-bcc` | `LassoSMTPAddressList.parse(...)` → `[EmailAddress]`, **then `.map(\.address)`** — `SMTPMailer.send(_:bcc:envelopeFrom:)`'s `bcc` parameter is `[String]`, not `[EmailAddress]` (type mismatch caught by review; never `EmailMessage`, matching Perfect-SMTP's structural Bcc-leak fix) |
| `-from` | `EmailAddress` → `EmailMessage.from` |
| `-subject` | `EmailMessage.subject` |
| `-body`/`-html` | `EmailMessage.textBody`/`.htmlBody` |
| `-replyTo` | `EmailMessage.replyTo` |
| `-sender` | `EmailMessage.sender` |
| `-priority` | `EmailMessage.priority` |
| `-contentType`/`-transferEncoding` | **Corrected, stronger finding than the first draft's hedge: there is currently no landing spot at all, not just an untried one.** `MIMEComposer.forbiddenExtraHeaderNames` explicitly includes `"content-type"`/`"content-transfer-encoding"` — routing these through `extraHeaders` throws `ComposerError.forbiddenHeader` at composition time. `MIMEComposer.textLeaf` computes `Content-Transfer-Encoding` automatically with no caller override anywhere in Perfect-SMTP's public API. **Decide explicitly in Phase B/F: either scope these two params out with an explicit unsupported-param error (recommended for the initial release), or open a small, separately-scoped addition to `EmailMessage`'s public surface in Perfect-SMTP itself (cross-repo work, outside this plan's original "nothing modifies Perfect-SMTP" framing — flag if pursued).** |
| `-characterSet` | `EmailMessage.charset` |
| `-extraMIMEHeaders` | `EmailMessage.extraHeaders`, and **whatever landing spot is eventually chosen for `-contentType`/`-transferEncoding` above must inherit the same `requireNoInjection`/`rejectHeaderInjection` discipline `extraHeaders` and `attachmentLeaf`/`inlineLeaf`'s `Content-Type` already use** — state this explicitly next to the row, don't leave it to be rediscovered. |
| `-tokens`/`-merge` | Mail-merge templating, pure adapter-side string substitution before `EmailMessage` construction. **New, explicit scoping rule from review: substitution applies only to `-body`/`-html`/`-subject` (and address display-names, which route through `encodePhrase` regardless) — never to `-host`/`-port`/`-username`/`-password`, `-attachments`/`-htmlImages` path entries, or `-extraMIMEHeaders` names.** Those latter fields are exactly the ones Perfect-SMTP has no header-injection-style opinion on (they aren't header values at all), so merge substitution reaching them would bypass `HeaderEncoder`'s protections entirely, not just risk header injection specifically (see §5). |
| `-immediate` | `true`/absent → synchronous `SMTPMailer.send` now; `false` → `LassoEmailJobTracker` (§4.7) |
| `-host`/`-port`/`-username`/`-password` | **Substantially revised per security review, see §5 — no longer "operator opt-in flag for an arbitrary caller-supplied host."** |
| `-timeout` | Maps to `RelayConfig`'s connect timeout; document that per-phase timeouts aren't independently reachable through this one param. |
| `-ssl` | `true` → `.startTLS` unless `-port=465`, then `.implicit`; `false`/absent → configured relay's own `tls` mode. |
| `-date` | No Perfect-SMTP equivalent. **Resolved (no longer open, §7 item 2): Phase A throws an explicit "not yet supported" error for `-date` rather than silently sending immediately.** Real scheduling lands in Phase E once `LassoEmailJobTracker` exists — scheduling genuinely needs that machinery to do correctly (a due-time to wait on, a way to observe/cancel the pending send), so it shouldn't be bolted onto Phase A just to avoid the error message. |
| `-simpleform` | Should work naturally with both bodies nil — verify `MIMEComposer` doesn't reject an empty-body message. |
| `-ContentDisposition` (8.5) | `EmailMessage.defaultDisposition`. |

`email_compose` mirrors `SMTPMailer.composeAndSign`'s two-phase shape. Land alongside `email_send` in the same phase.

### 4.4 `email_mxlookup`

A free function wrapping `DNSResolver.resolveMX(domain:)`. `-refresh` likely a no-op (`DNSResolver` doesn't cache). `-hostname`'s exact semantics need re-confirming against lassoguide.com during implementation — not independently re-verified by this plan or its review.

### 4.5 Attachments / inline images — corrected per security review to reuse existing code and close two gaps the first draft missed

`-attachments`/`-htmlImages`' `name=data` variant maps directly onto `Attachment`/`InlineResource` (already `Data`-based) — and its filename value is already protected by `MIMEComposer.sanitizedFilename`, which strips control characters and neutralizes path-traversal sequences before the value ever reaches a `Content-Disposition` header; the adapter needs no new sanitization for this variant, only for the path-based one below.

The path-based variant needs new adapter-side file-loading code, with:
- **Reuse `LassoSiteServer`'s existing containment helper, don't reinvent it.** `main.swift:1075-1118`'s `isWithinRoot` (`siteRoot.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()`, then a prefix check against the root) is already symlink-aware and already used for exactly this class of problem elsewhere in this codebase. `LassoSMTPAttachmentLoader` should call it (or a shared extraction of it), not write a second, subtly-different implementation.
- **Regular-file-type check + TOCTOU-safe read order, new finding from review, not in the first draft.** `Data(contentsOf:)` against a named pipe or a device file can hang or exhaust memory. After containment-checking the resolved path: open by the resolved path, `fstat` the open descriptor, verify `isRegularFile` and size-under-cap on that descriptor (not the path string, to close the race between check and read), then read.
- **A file-count ceiling, not just the 8MB byte ceiling.** The byte ceiling (enforced as a running sum, per the first draft) bounds memory but not syscall/fd volume against many-small-files. Add an explicit count cap.

### 4.6 Shared mailer lifetime and relay configuration — corrected per both concurrency and security review

A `LassoSMTPMailerRegistry` actor. **The first draft's claim that this "mirrors `FileMakerConnectionRegistry`'s role" is dropped — see §2's correction; that type does something orthogonal (live alias re-pointing, no pooling) and FileMaker's actual pattern is deliberately unpooled.** This design stands on its own justification instead: SMTP is a stateful protocol session Perfect-SMTP already built explicit, reviewed pooling machinery for (`SMTPConnectionPool`), and a long-lived, actor-held `SMTPMailer` over `RelayTransport` is the only way to actually realize that benefit across many `email_send` calls in one server process rather than constructing a fresh, unpooled transport per call.

Built once at server startup from a new `smtp` block in `DatasourceFileConfig`. **Revised shape per §5's SSRF finding — named relays, not a bare host string:**
```json
{
  "smtp": {
    "relays": {
      "primary": {"host": "...", "port": 587, "user": "...", "password": "...", "tls": "startTLS"},
      "marketing": {"host": "...", "port": 587, "user": "...", "password": "..."}
    },
    "defaultRelay": "primary",
    "allowDirectMX": false,
    "dkimKeyPath": "...", "dkimSelector": "...", "dkimDomain": "..."
  }
}
```
plus `LASSO_SMTP_*` env-var fallbacks for the single-relay smoke-test path, matching the `filemaker`/`mysql` blocks. `-host`/`-port`/`-username`/`-password` (§4.3) no longer select an arbitrary literal host — see §5.

**DKIM key handling — new, explicit guidance from security review, does not just "follow §2's precedent."** `DatasourceFileConfig`'s chmod-600 convention is documentation-only and unenforced in code (§2). That's an acceptable risk for a rotatable password; a leaked DKIM private key is not equivalently rotatable (revocation means republishing a DNS TXT record and waiting out its TTL — until then, forged mail as that domain is possible from anywhere, not just this server). When loading `dkimKeyPath`, `LassoPerfectSMTP` must `stat` the file and refuse to start (or hard-log) if it's group- or world-readable, and read it once at startup into the long-lived `SMTPMailer`/`DKIMSigner`, never per-call.

**Config-swap concurrency note, new from concurrency review.** If this registry is ever extended toward live relay-switching (the admin console already has this pattern for FileMaker, via `FileMakerConnectionRegistry.switchAlias` — see §2's correction on what that type actually does), swapping the active relay config is a fundamentally harder operation than FileMaker's host/port metadata swap, because it means tearing down a live `SMTPConnectionPool` that may have in-flight sends and pooled connections against it. `SMTPConnectionPool.shutdown()` (already reviewed correct in Perfect-SMTP) does the right thing when called, but nothing here currently specifies whether a live config swap should let in-flight sends finish or race them against `shutdown()`. Not needed for the initial config-file-only scope — flagged for whichever future phase adds live switching.

### 4.7 `email_result`/`email_status` — net-new job tracking, with explicit open questions from review

Perfect-SMTP's own plan deliberately never built an `enqueue`/`status(of:)` API. `LassoEmailJobTracker` (actor) needs a job-ID scheme (Foundation `UUID()` — CSPRNG-backed, 122 bits of entropy; explicitly *not* a sequential/incrementing scheme, stated here so a future "optimization" doesn't quietly weaken it), an in-memory `[JobID: JobState]` store (in-memory-only, matching `DirectMXRetryQueue`'s/`MTASTSPolicyManager`'s identical documented scope boundary in Perfect-SMTP), and a bridge from `-immediate=false`/`-date`-scheduled sends into background `Task`s recording `DeliveryResult`s against the job ID.

**Single-tenant confirmation, new from security review.** `lasso-perfect-server` runs one `LassoSiteServer` per process (confirmed, `main.swift:1798`, the only construction site). There is no cross-tenant isolation boundary for this job store to violate today — stated explicitly here so it's a tracked assumption, not a silently-reopened gap if this codebase ever grows a multi-site-per-process mode.

**Explicit unanswered questions for Phase E's implementation, new from concurrency review, given `DirectMXRetryQueue`'s own history of a real background-task-leak bug (a nudge-triggered restart that cancelled a sleep but never actually stopped the superseded task's own loop) caught during its milestone review:**
- What happens to a job's background `Task` if nobody ever polls its status again — does it still run to completion and sit in the store (bounded only if there's an eviction/TTL policy, which this sketch doesn't yet have), or is there a cancellation path?
- Does the tracker have any shutdown/drain story for a server restart while a `-date`-scheduled send is still pending, or does it vanish silently (acceptable if documented the same explicit way `DirectMXRetryQueue` documents its own in-memory-only limitation, not left implicit)?
- Confirm the background `Task` for a `-immediate=false` send is deliberately *not* scoped to the originating request's own async context (it must outlive the request), rather than assuming an ordinary `Task {}` created inside a request handler survives past that request by default.

### 4.8 `email_smtp` — substantially corrected per review; the original recommendation was built on an incorrect premise

**Two things review found wrong with the first draft's framing, both correcting the actual design tradeoff, not just a citation:**

1. **"Live-session model requires new public surface on Perfect-SMTP" is factually wrong.** `SMTPConnection` (`public final class`, with `public init`, `write`, `writeLine`, `negotiateCapabilities`, `authenticate`, `sendMessage`, `nextReply`), `SMTPBootstrap.connect(host:port:tls:...) async throws -> NIOAsyncChannel<SMTPReply, SMTPCommand>` (`public static func`), and `SMTPConnectionPool.withConnection` (`public func`) are all already public in Perfect-SMTP today — no new product, no new cross-repo work needed to reach them. **The real, narrower obstacle**: `SMTPConnectionPool.checkout`/`.release` are `private`, so a connection can't be held open across multiple independently-dispatched `->open`/`->command`/`->close` calls *via the pool's public API* — only within one Swift closure passed to `withConnection`. This doesn't block the live-session model at all; it just means `email_smtp` would dial directly via the already-public `SMTPBootstrap.connect` + `SMTPConnection.init`, **bypassing `SMTPConnectionPool` entirely for this one code path** (trading away pooling for this specific raw-command use case, a reasonable tradeoff for a feature whose real corpus usage is unconfirmed anyway).

2. **"Stateless-envelope model, closer to `date`/`bytes`" overstates the fit and elides a real, already-encountered problem in this exact codebase.** `date`'s methods were *originally* mutating and caused a real aliasing bug — `LassoValue.object` copies the enum case but not the underlying `LassoObjectInstance` class, so two variables could silently share mutations; the fix (`NativeTypes.swift`'s `date->add`/`->subtract` doc comment) was to make `date` non-mutating and rely on `Evaluator.selfMutatingMethods` (`Evaluator.swift:912-927`, a small hardcoded method-name set) for write-back-on-bare-statement instead. `bytes`' methods (`decodeBase64`/`encodeBase64`/`encodeUrl`) never mutate the receiver at all. **`email_smtp`'s `->open` then repeated `->command` then `->close` sequence needs exactly the cross-call state accumulation this codebase already tried and moved away from for `date`.** Two real, named options — the plan should pick one explicitly during Phase D design, not describe a third option that doesn't actually match either existing type:
   - **(a) Genuine in-place mutation** via `LassoObjectInstance.set(_:for:)` (already thread-safe, lock-guarded) inside the native-method closures — technically works with zero `Evaluator.swift` changes, but reintroduces the aliasing semantics the `date` migration explicitly moved away from as wrong (though a live connection handle arguably *should* have reference/aliasing semantics, unlike a value-like date — this is a real judgment call, not obviously wrong to choose).
   - **(b) Non-mutating-plus-write-back**, following `date`'s actual current pattern — add `"open"`/`"command"` etc. to `Evaluator.selfMutatingMethods` and thread the accumulated state through return values. Requires editing core `Evaluator.swift`, not just the new target — same category of cross-target work as §4.0.

**`-clientIp` (Lasso 9's `email_smtp` HELO/EHLO identity override, named in §3) was entirely unaddressed in the first draft — added here.** Maps to `RelayConfig.ehloHostname`, analogous to how `-host`/`-port` can override the configured relay per-call — resolve alongside that design (§4.3/§5) rather than as an afterthought.

**Deferral rationale, strengthened per concurrency review with a second, independent justification beyond the (now-corrected) API-surface argument.** SMTP is strictly sequential — command/response pairing depends on exactly one party writing and reading a connection in lock-step, an invariant Perfect-SMTP's own `SMTPConnectionPool` enforces structurally via checkout/release exclusivity. A live-session model keyed by a bare opaque session-ID string, with no equivalent checkout discipline, has no structural defense against two concurrent contexts referencing the same session ID and interleaving commands against one connection — corrupting the conversation, not just racing harmlessly. This is a real reason to prefer the narrower, already-buildable option independent of the (corrected, now-smaller) implementation-cost argument.

**Recommendation, carried forward with corrected justification:** ship option (a) from problem 2 above (in-place mutation, `date`-migration-aware, explicitly chosen rather than assumed) plus direct un-pooled dialing per problem 1, as the "live-enough" `email_smtp` for Phase D — closer to genuine `->command` fidelity than the first draft's stateless-envelope idea, and now correctly understood not to require any Perfect-SMTP-side work. Real corpus usage of `email_smtp`, if any exists, should still inform how much of `->command(-send,-expect,-multi,-read)`'s full surface is worth building versus a narrower subset.

## 5. Cross-cutting concerns

**SSRF exposure via `email_send`'s `-host` — substantially revised, this is now the plan's most important open-decision resolution, per the security review's critical finding.** The first draft's "operator opt-in flag" recommendation does not actually close this gap: `RelayConfig`/`RelayTransport` has **no address-routability filtering at all** — that machinery exists exclusively on `DirectMXTransport` via `allowPrivateAddresses`. If a per-call `-host` override were implemented as "spawn a short-lived `RelayTransport` to the caller-supplied host" (as §4.6's first draft sketched), flipping an opt-in flag would grant the exact internal-network-connect primitive (`127.0.0.1`, RFC 1918 ranges, cloud metadata endpoints, this same server's own FileMaker/MySQL/admin-API ports) that `DirectMXConfig.allowPrivateAddresses` exists to prevent — with none of that filtering applied, because the connection never goes through `DirectMXTransport`. A single process-wide boolean is also the wrong shape regardless of the filtering question, since it would apply to every page on the site, not just ones an operator specifically audited for this need.

**Corrected design: `email_send` never accepts an arbitrary literal `-host`.** §4.6's config now defines named relays (`relays: {"primary": {...}, "marketing": {...}}`); `-host` (when given at all) selects a name from that map, never a literal hostname/IP. `-to`'s domain carries no independent SSRF risk on the default relay path (only `RCPT TO` reaches the fixed, operator-configured relay — its own domain's DNS is never resolved by this library). If a genuine literal-host escape hatch is ever needed for a direct-MX-adjacent use case, it must route through `DirectMXTransport` with `allowPrivateAddresses: false`, never `RelayTransport`, stated explicitly rather than left for an implementer to discover after the fact.

**`-tokens`/`-merge` scope — see §4.3's table row.** Perfect-SMTP's own header-injection defenses (`HeaderEncoder.rejectHeaderInjection`, `MIMEComposer`'s `extraHeaders` denylist) apply at compose time regardless of how a string was assembled, so merge-substituted `-body`/`-subject`/display-name content is already covered. The actual gap is scope: merge substitution must never reach `-host`, attachment paths, or `-extraMIMEHeaders` *names* — none of those are header *values* Perfect-SMTP's injection defenses cover, and `-host` specifically feeds directly into the SSRF concern above.

**Credential handling.** Follows §2's `DatasourceFileConfig` precedent for ordinary username/password secrets; DKIM key material needs the stricter, explicit handling in §4.6.

**DKIM/MTA-STS exposure.** Operator/security-posture decisions, belong in the `smtp` server-config block (§4.6), not per-call dash-params — unchanged from the first draft, no correction needed here.

**Testing strategy.** `LassoSMTPAddressList` needs pure unit tests with quote/comma edge cases. `email_send`/`email_compose`/`email_mxlookup` need Lasso-parser-level end-to-end tests (matching `LassoParserTests.swift`'s style) plus §4.0's new `LassoEmailProvider` slot needs its own tests analogous to how `inlineProvider`/`sessionProvider` are exercised. Reuse Perfect-SMTP's fake-server test patterns rather than a new mocking layer. `LassoSMTPAttachmentLoader` needs adversarial tests (`../` traversal, symlink escape, regular-file-type rejection, TOCTOU-relevant ordering, count+size ceilings). `email_smtp`/`email_result`/`email_status` test strategy depends on the §4.8/§4.7 decisions above.

## 6. Phasing

- **Phase A — Dispatch seam (§4.0) + `email_send` core.** The `LassoEmailProvider` protocol/context-slot design in `LassoParser`, its concrete conformer in `LassoPerfectSMTP`, then `email_send`'s actual parameter mapping (`-to`/`-cc`/`-bcc`/`-from`/`-subject`/`-body`/`-html`/`-replyTo`/`-sender`/`-priority`/`-extraMIMEHeaders`), the named-relay config block (§4.6, minus DKIM), the corrected SSRF-safe `-host` design (§5). **This phase now spans both `LassoParser` and `LassoPerfectSMTP` — larger than the first draft's Phase A, since §4.0 wasn't previously accounted for.** First genuinely usable release, covering the real corpus usage already found.
- **Phase B — Attachments/inline images.** Both shapes, the reused `isWithinRoot` containment check, regular-file+TOCTOU handling, size+count ceilings, `-ContentDisposition`. `-contentType`/`-transferEncoding` explicitly scoped out (error) or deferred to Phase F per §4.3's decision.
- **Phase C — `email_compose`, `email_mxlookup`.**
- **Phase D — `email_smtp`.** §4.0 problem 3 (the native-type dispatch slot) resolved first, then the corrected design from §4.8 (direct unpooled dialing + explicit in-place-mutation choice), `-clientIp`.
- **Phase E — `email_result`/`email_status`.** The job-tracking layer with §4.7's now-explicit open questions resolved during implementation, not deferred past it.
- **Phase F — Operator-level policy.** DKIM key config (with the stricter loading/permission checks from §4.6), MTA-STS enforcement toggle, direct-MX opt-in, `-contentType`/`-transferEncoding` if pursued, `-tokens`+`-merge` templating if not already folded into Phase A.

Each phase gets its own branch and its own milestone review (architecture, concurrency, protocol, security) — unchanged discipline from the first draft, still correct.

## 7. Open decisions requiring explicit sign-off before implementation starts

1. **`email_smtp`'s design (§4.8)** — now recommended: direct unpooled dialing via already-public `SMTPBootstrap.connect`/`SMTPConnection`, with explicit in-place mutation (option (a)) on the native-type object — corrected from the first draft's stateless-envelope recommendation, which was based on an inaccurate premise.
2. **`-date` scheduled-send (§4.3)** — **resolved, no longer open**: Phase A throws an explicit "not yet supported" error; real scheduling lands in Phase E alongside `LassoEmailJobTracker`, which it genuinely depends on.
3. **`-host`/relay-selection posture (§4.3, §5)** — **resolved by review, no longer open**: named relays only, never a literal caller-supplied host, with a `DirectMXTransport`-routed escape hatch (never `RelayTransport`) if literal-host support is ever genuinely needed.
4. **Attachment path-containment policy (§4.5)** — **resolved by review, no longer open**: reuse `LassoSiteServer`'s existing `isWithinRoot`, add regular-file+TOCTOU handling and a count ceiling on top of the byte ceiling.
5. **`-contentType`/`-transferEncoding` landing spot (§4.3)** — new open decision from review: scope out with an explicit error (recommended for the initial release) vs. a small, separately-scoped addition to Perfect-SMTP's own public `EmailMessage` surface.

## 8. Next step

Phase A's implementation (§4.0's dispatch-seam design, together with `email_send`'s actual parameter mapping) should itself be milestone-reviewed the same way — architecture, concurrency, protocol, security — before merging, matching every phase of Perfect-SMTP's own six-phase build. Not yet started as of this revision.

## 9. Review record

This plan went through one full parallel review pass before any implementation started — the same structure Perfect-SMTP's own plan and every one of its six phases used:

1. **Application-architect / Lasso-runtime-accuracy review** — independently re-verified every file:line claim in the first draft against both codebases rather than trusting the draft's own citations. Found the dispatch-registration gap (§4.0, the review's headline finding — the first draft assumed the `email_send` stub could just be rewritten in place, which it can't without breaking `LassoParser`'s layering), corrected the `SMTPConnection`/`SMTPBootstrap.connect`/`SMTPConnectionPool.withConnection` public-surface claim that had driven the (wrong) `email_smtp` recommendation, corrected the `date`/`bytes` precedent-fit claim for the stateless-envelope model, corrected the `FileMakerConnectionRegistry` analogy, strengthened the `-contentType`/`-transferEncoding` finding from "no landing spot yet" to "actively forbidden today," caught the `-bcc` type mismatch (`[EmailAddress]` vs. `[String]`), found `-clientIp` entirely unaddressed, and fixed a minor citation error (`LassoDynamicQueryExecutor` is one-method, not two). All findings resolved above.
2. **Concurrency review** — independently confirmed the `FileMakerConnectionRegistry` correction from a different angle (read the actual precedent file directly), flagged that `LassoEmailJobTracker`'s one-paragraph sketch is at risk of repeating `DirectMXRetryQueue`'s own real, previously-fixed background-task-leak bug class and listed the specific unanswered questions Phase E's implementation must resolve, added a second, concurrency-native justification for deferring `email_smtp`'s live-session concerns (SMTP's strict sequentiality, independent of the corrected API-surface argument), and flagged the config-swap/pool-shutdown interaction as a genuine open question for any future live-relay-switching feature. All findings resolved above.
3. **Security review** — the most consequential finding of the whole pass: the first draft's `-host` override design (§5) had **no SSRF defense to inherit at all**, since `RelayTransport` has none of `DirectMXTransport`'s address filtering — resolved by redesigning around named, pre-configured relays rather than an arbitrary caller-supplied host. Also found the attachment-loading design should reuse `LassoSiteServer`'s existing, already-symlink-aware containment helper rather than reinventing it, added regular-file-type/TOCTOU/count-ceiling requirements the first draft missed, found the DKIM-key-handling gap (the `DatasourceFileConfig` chmod-600 convention is documentation-only and insufficient for non-rotatable key material), scoped `-tokens`/`-merge` substitution explicitly to close a header-injection-adjacent gap, and confirmed the single-tenant-per-process architecture means `LassoEmailJobTracker` has no cross-tenant isolation boundary to violate today. All findings resolved above.

Nothing from either review was left unresolved or silently dropped — every finding above either changed this document's design text directly, or (for the two items in §7 still marked open) was carried forward as an explicit, named decision for implementation to make rather than defaulted into.

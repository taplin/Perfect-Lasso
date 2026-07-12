# Outstanding Compatibility Project Plans

Last reviewed: July 12, 2026

This document expands the next nine compatibility tasks from
`Documentation/lasso-perfect-server.md` into implementation-ready project
plans. The plans are ordered by expected production leverage, not by difficulty.

Reference sets reviewed:

- Lasso 8.5: `References/Lasso/Lasso 8.5 Language Guide.pdf`, extracted with
  `pdftotext` for local search.
- Lasso 9 local docs: `References/Lasso/LP9Docs/*`.
- LassoGuide 9.3 online pages used to confirm current Lasso 9 semantics:
  `operations/sessions.html`, `operations/requests-responses.html`,
  `operations/date-duration.html`, `operations/serialization-compression.html`,
  `databases/database-interaction.html`, `databases/sql-data-sources.html`,
  and `language/types.html`.
- Corpus evidence: `Documentation/lasso-perfect-server.md`,
  `Documentation/compatibility-matrix.md`, and the scrubbed reports under
  `/Users/timtaplin/Documents/LassoAdapter-workfiles/Reports/`.

## 1. Live MySQL Verification And DB Error Framing

### Goal

Replace the current `inlineNotConfigured` uncertainty with live datasource
evidence, then finish the recoverable error model for actual connector failures.
The adapter already unit-tests dynamic reads, writes, raw SQL routing, and
capability denials. What remains is proof that those paths work against the
real Perfect-MySQL connector and that connector-level failures are surfaced to
Lasso code as `LassoInlineFrame.error` rather than fatal Swift errors.

### Reference Findings

Lasso 8.5 Chapter 7 documents `[Inline]` as the database action boundary and
describes nested/named inlines, `Action_Statement`, `-StatementOnly`, and the
`-Add`/`-Update`/`-Delete`/`-SQL` action families. Chapter 19 documents that
database and action errors are normally inspectable through `Error_CurrentError`
inside or immediately after an inline.

LassoGuide 9.3 keeps the same broad model: database actions are represented as
data-source-backed inlines, SQL datasources have their own SQL action surface,
and errors are part of the expected page-level control flow rather than only a
server crash path.

### Usage Evidence

The production-ish e-commerce report shows 480 `inline` uses, 1,002 `-search`,
733 `-table`, 689 `-database`, 672 `-ReturnField`, 604 `-op`, 149 `-update`,
123 each of `-KeyField` and `-KeyValue`, 123 `-MaxRecords`, and 93 `-sql`.
The second application corpus is even more SQL-heavy: 4,894 `inline` and 9,873 `-sql`
signals. Current recursive crawl results still include many `inlineNotConfigured`
failures because no live datasource is wired into those sweeps.

### Current Implementation Surface

- `LassoInlineRequest` captures action, datasource, table, SQL, return fields,
  sorts, limits, criteria, write assignments, `-KeyField`/`-KeyValue`, and
  `-StatementOnly`.
- `PerfectCRUDLassoExecutor` supports read actions, insert, update, delete, and
  raw SQL, with per-datasource capability gating.
- Capability denials already return recoverable `LassoInlineFrame` errors.
- Real connector exceptions still throw through as Swift errors.
- `lasso-perfect-server` can wire MySQL using `LASSO_MYSQL_*` plus
  `LASSO_DATASOURCE_ALIAS`.

### Plan

1. Add a gated live integration target or extend `LassoMySQLSmoke` so it can
   exercise:
   - structured `-Search` with return fields, sort, max/skip;
   - raw `-SQL` SELECT;
   - `-Add` with insert-id follow-up;
   - `-Update` with `-KeyField`/`-KeyValue`;
   - `-Delete` returning an empty found set;
   - denied write/raw-SQL paths with `error_currentError`.
2. Use a throwaway fixture schema, not private production tables. Reuse the
   pattern in `Documentation/mysql-fixture-testing.md`: opt in with an env var,
   create deterministic fixture data, clean up afterward.
3. Run `lasso-perfect-server` with:
   - `LASSO_SITE_ROOT=/path/to/real/site/root`
   - `LASSO_DATASOURCE_ALIAS=<configured datasource alias>`
   - local MySQL connection vars
   - write/raw-SQL toggles off first, then on for controlled smoke pages.
4. Run `LASSO_CRAWL_REPORT=1` with datasource configured. Compare the new
   report to the existing 1,690/1,989 baseline.
5. Wrap `queryHandler`, `mutationHandler`, and `rawSQLHandler` calls in
   `PerfectCRUDLassoExecutor` so connector errors become `LassoInlineFrame`
   values with `LassoErrorState`, not fatal throws, when the failure is a real
   datasource/action failure.
6. Keep fatal adapter/configuration errors fatal: missing provider, missing
   datasource alias, path escape, parser corruption, and unsupported syntax
   should still reach the developer error page.

### Tests

- Unit tests with fake handlers that throw connector-like errors for search,
  add, update, delete, and raw SQL.
- Gated live MySQL tests for each action.
- Crawl-report diff before and after datasource wiring.
- A Lasso fixture that checks `[Error_CurrentError]` and
  `[Error_CurrentError: -ErrorCode]` after a failing inline.

### Risks

- Do not broaden write/raw-SQL permissions by default while chasing live
  verification. The current read-only default is correct.
- Real Lasso numeric error codes remain only partially mapped. Use stable
  adapter-local codes until the exact Lasso 8.5 constants are extracted and
  classified.
- Raw SQL multi-statement behavior must remain opt-in.

## 2. Date_Format And Date Helper Support

### Goal

Implement enough date functionality to clear the `unknownFunction("Date_Format")`
crawl bucket and support known adjacent corpus forms: `Date`, `Server_Date`,
`Date_Add`, `Date_LocalToGMT`, and the Lasso 9-style `date(...)` /
`date_format(...)` spelling where it naturally falls out of the same code.

### Reference Findings

Lasso 8.5 Chapter 29 defines `Date`, `Date_Format`, `Date_SetFormat`,
`Date_GMTToLocal`, `Date_LocalToGMT`, `Date_GetLocalTimeZone`, `Date_Msec`,
and date math tags. It lists the classic format symbols used by the corpus:
`%D`, `%Q`, `%q`, `%r`, `%T`, `%Y`, `%y`, `%m`, `%B`, `%b`, `%d`, `%w`, `%W`,
`%A`, `%a`, `%H`, `%h`, `%M`, `%S`, `%p`, `%G`, `%z`, `%Z`, and `%%`, including
zero/space/no-padding variants.

LassoGuide 9.3 confirms the same creator/method shape as `date(...)`,
`date_format(value, -format=...)`, `date_gmtToLocal`, `date_localToGMT`, and
adds ICU date-format strings. For this adapter, the classic percent-token set
is the first compatibility target because the real corpus uses classic Lasso 8
symbols.

### Usage Evidence

The post-Output crawler surfaced `unknownFunction("Date_Format")` on 20 pages.
The reports show concrete uses:

- `Date_Format(Date, -Format='%w')` in a day-calculation include.
- HTTP cache header style formatting with
  `Date_Format(Date_LocalToGMT(Server_Date), -Format='%a, %m %Y %H:%M:%S')`.
- The second application corpus uses `%D` heavily and combines `Date_Format` with `Date_Add`.

### Current Implementation Surface

No dedicated date value exists in `LassoValue`; date-like values currently pass
through as strings. `PerfectCRUDLassoExecutor` converts connector date dynamic
values to ISO8601 strings. There is no default native registration for
`Date_Format`, `Date_Add`, `Server_Date`, or `Date_LocalToGMT`.

### Plan

1. Add a small internal `LassoDate` helper in `LassoParser`, not necessarily a
   new public `LassoValue` case at first.
   - Parse known Lasso 8.5 formats.
   - Parse ISO8601 strings emitted by PerfectCRUD.
   - Preserve timezone when the input includes GMT/offset.
2. Register Lasso 8 spellings:
   - `date`
   - `server_date`
   - `date_format`
   - `date_add`
   - `date_subtract` if trivial once add exists
   - `date_localtogmt`
   - `date_gmttolocal`
   - `date_msec`
3. Register Lasso 9-compatible lowercase/camel aliases through the same
   case-insensitive native registry. The registry lowercases names, so
   `Date_Format` and `date_format` already share one slot.
4. Implement classic format rendering first. Map tokens explicitly rather than
   trying to hand the format string directly to Foundation:
   - `%Q` -> `yyyy-MM-dd`
   - `%T` -> `HH:mm:ss`
   - `%D` -> `MM/dd/yyyy`
   - `%w` -> Sunday=1 through Saturday=7, matching Lasso, not Foundation's
     zero-based weekday habits.
5. Implement `%a`/`%A`/`%b`/`%B` using `en_US_POSIX` unless a future corpus
   need proves locale is required.
6. Implement padding modifiers (`%_m`, `%-m`) once the base symbols pass.
7. Defer ICU format strings until a crawler bucket shows real usage.

### Tests

- Golden tests for every corpus-observed format.
- GMT conversion tests independent of the local machine timezone.
- `Date_Add` month/day/hour tests, including negative values.
- `Server_Date` smoke test should not assert an exact instant; assert format
  and monotonic sanity.
- Crawl-report check that `unknownFunction("Date_Format")` disappears or moves
  to a deeper date helper bucket.

### Risks

- Lasso 8.5 and Lasso 9 differ on some date parsing defaults. Favor corpus and
  Lasso 8.5 for classic tags; document any deliberate approximation.
- Month math has edge cases. Use `Calendar` rather than seconds arithmetic for
  month/year increments.
- Do not introduce a `LassoValue.date` case unless member dispatch or database
  rows require it. A helper can clear the current blocker with less blast
  radius.

## 3. Decode_Base64

### Goal

Implement `Decode_Base64` as the inverse of existing `Encode_Base64`, clearing
the 20-page `unknownFunction("Decode_Base64")` bucket and supporting saved-cart
and URL-token flows.

### Reference Findings

Lasso 8.5 Chapter 17 defines Base64 encoding as a transport-safe ASCII
representation, not a security mechanism, and Table 3 lists `Decode_Base64` as
accepting one string parameter and returning the decoded value. LassoGuide 9.3
places binary/serialization operations in the modern operations docs, while
string/bytes method style is more common in Lasso 9.

### Usage Evidence

The production e-commerce reports show `Decode_Base64($temp_order_ID)` in saved-cart pages,
including inline search criteria such as `cart_id = Decode_Base64(...)`.
Encoding usage already exists in the corpus through `->encodebase64` and
`Encode_Base64`, which the adapter now implements through `LassoEncoding`.

### Current Implementation Surface

`LassoEncoding.base64(_:)` exists and `encode_base64` is registered as a native
free function. String member methods expose encoding transforms. There is no
decode helper.

### Plan

1. Add `LassoEncoding.decodeBase64(_:) -> String?`.
2. Register `decode_base64` in `LassoNativeRegistry`.
3. Add the Lasso 9-style string/bytes member if the member table already has a
   clean encoding-method family; otherwise keep first pass to the free tag.
4. Decide invalid input behavior:
   - first pass: return `.void` and set no current error, unless docs prove a
     recoverable error is expected;
   - add a test documenting this behavior.
5. Accept URL-safe padding-tolerant input only if corpus evidence requires it.
   The saved-cart examples appear to use ordinary Base64 then URL encoding.

### Tests

- Round trip: `Decode_Base64(Encode_Base64('abc')) == 'abc'`.
- Corpus shape: decoded ID used as an inline criterion.
- Invalid input returns the documented first-pass fallback.
- UTF-8 text round trip, plus non-ASCII smoke if the existing encoding helper
  claims UTF-8 semantics.

### Risks

- Lasso's byte stream model is richer than this adapter's current string-only
  value model. Keep the first pass string-focused and document binary data as a
  later file/media concern.
- Do not conflate Base64 with authentication or encryption.

## 4. Expression-Form inline(...)

### Implementation Status (2026-07-12)

Implemented — but the real root cause was different from this section's
original plan below. Live corpus investigation (all 15 failing pages,
pulled via `LASSO_CRAWL_REPORT_PATH` JSON and grepped directly) showed
every failing page used Lasso 8's **bare colon-call block form**
(`inline: -database=..., -sql=...; ... /inline;`, no parens at all), not a
value-returning expression or bare statement call. Two real, distinct
parser bugs, both in `Sources/LassoParser/ScriptBodyParser.swift`:

1. `"inline"` was missing from `emitStatement`'s `bareBlockNames` set
   (the same mechanism `Output_None`/`define_tag`/etc. already use to
   promote a bare colon-call into a real block-open `.tag(...)` node
   instead of an ordinary, unregistered function call). One-line fix.
2. `readStatement()` breaks a statement at the first bare (unparenthesized)
   newline — correct for the common one-statement-per-line style, but real
   corpus `inline:` calls are formatted one flag per line with no wrapping
   parens, so the statement was being truncated to just `inline:` before
   ever reaching its arguments. `grep`-counting every line ending inside
   the real `inline:`...`/inline;` blocks across all 15 files found exactly
   three trailing characters that mark "more follows on the next line":
   a trailing `,` (comma-separated flags), a trailing `+` (string
   concatenation spanning lines), and the block-opener's own trailing `:`.
   Fixed by continuing past a bare newline in exactly those three cases.

14 of the 15 pages now clear `unknownFunction("inline")` entirely (11 of
those land on the pre-existing, expected `inlineNotConfigured` bucket — no
live datasource wired into the sweep, same as ~87 other pages). One file,
`components/inSite/filtered_links.inc`, still fails — for a third, distinct,
deliberately deferred reason: Lasso 8's operator-less string/variable
juxtaposition concatenation (`'text' #localVar 'more text'`, no `+`
between them) inside an argument value. `ExpressionParser`'s argument-value
parser stops at the first complete sub-expression, so the rest becomes
separate top-level expressions rather than folding into the same argument
— a genuinely different parser gap from the block-opening fix above, not
in scope for this pass. A test documents this as a known, currently-failing
shape (`inlineBareColonCallWithJuxtaposedStringConcatenationIsADeferredGap`)
so it isn't a silent gap.

Verified via 5 new tests (98/98 total, no regressions) and a live
real-corpus crawl: clean-page count held at 1,690/1,989 (unchanged — the
14 fixed pages moved to the already-documented `inlineNotConfigured`
bucket, not fully clean, since no live datasource is wired into the quick
sweep).

Deferred, new backlog item: Lasso 8's string/variable juxtaposition
concatenation with no `+` operator (`'text' #var 'text'`) — affects at
least `filtered_links.inc`; scope/frequency elsewhere in the corpus not
yet surveyed.

### Goal

Investigate and implement the 15-page `unknownFunction("inline")` bucket that
appears after `[Inline: ...] ... [/Inline]` support is already working. The
likely gap is `inline(...)` used as an expression or bare statement rather than
as a container block.

### Reference Findings

Lasso 8.5 treats `[Inline] ... [/Inline]` as a container action. It also
documents named inlines and response tags that let results be consumed later.
The Lasso 9 database docs use method-style syntax more freely, and the local
LP9 docs model more operations as first-class objects/methods than classic
Lasso did.

### Usage Evidence

The recursive crawl reports `unknownFunction("inline")` on 15 pages after
`Output` stopped masking earlier failures. The older corpus summaries show
heavy inline use across both reviewed corpora, but the crawler bucket means these
specific pages do not parse into the existing `.block(name: "inline")` path.

### Current Implementation Surface

`Renderer.renderBlock` handles `case "inline"` by requiring an
`inlineProvider`, executing the inline request, pushing a `LassoInlineFrame`,
and rendering the body. `Runtime.swift` does not register an `inline` native
function, so expression-form calls currently fall through to
`unknownFunction("inline")`.

### Plan

1. Generate or inspect the latest crawl JSON for all `unknownFunction("inline")`
   paths.
2. Classify call shapes:
   - value-returning expression: `var(x = inline(...))`;
   - bare process statement: `inline(...);`;
   - script-mode container opener missed by parser;
   - named inline setup with later `records(-inlineName=...)`.
3. For value/bare statement forms, register a native `inline` function that:
   - builds `LassoInlineRequest` from evaluated arguments;
   - executes `context.inlineProvider`;
   - pushes current error state from the frame;
   - returns a map or object-like representation only if corpus usage needs a
     value.
4. If the expression form is only being used for side effects, return `.void`
   and set `records_map`, `found_count`, `action_statement`, and current error
   consistently with the block path.
5. If pages expect a real inline result object, introduce a lightweight
   `.object` native type or map with rows/found/action metadata.
6. Implement named-inline storage only after seeing a concrete corpus call that
   retrieves by `-InlineName`.

### Tests

- `inline(...)` bare statement executes provider once and updates
  `error_currentError`.
- `inline(...)` can be used before a `records` block only if named-inline
  evidence demands it.
- Missing provider still throws `inlineNotConfigured`.
- Crawl-report check that `unknownFunction("inline")` moves to either clean or
  a deeper datasource-specific bucket.

### Risks

- A native function cannot render a body. Do not try to shoehorn container
  behavior into it.
- Returning the wrong data shape may lock in a fake Lasso API. Start from real
  call sites.

## 5. File_ProcessUploads

### Goal

Implement Lasso 8 `[File_ProcessUploads]` so uploaded temp files can be moved
to durable storage before Perfect-NIO's retained multipart reader is released.

### Reference Findings

Lasso 8.5 Chapter 31 says uploaded files are stored temporarily and deleted at
the end of the page unless the Lasso page moves them. `[File_Uploads]` returns
metadata maps; `[File_ProcessUploads]` moves uploaded files into a destination
directory. It requires `-Destination` and supports `-UseTempNames`,
`-FileOverwrite`, `-Size`, and `-Extensions`. The same chapter also documents
manual movement through file copy/move tags.

Lasso 9 request docs expose upload metadata through
`web_request->fileUploads()` with keys `contenttype`, `fieldname`, `filename`,
`tmpfilename`, and `filesize`.

### Usage Evidence

Upload metadata is already implemented because checkout/upload forms exist in
the real corpus. The current backlog explicitly names `[File_ProcessUploads]`
as the missing move/copy step. The prior implementation verified that temp
files remain readable during render only because `MimeReader` is retained.

### Current Implementation Surface

- `ParsedPostBody` retains multipart reader state through render.
- `LassoUploadedFile` metadata is available from `LassoRequestProvider`.
- `web_request->fileUploads()` and `[File_Uploads]` are implemented.
- No native can move uploads or mark them as processed.

### Plan

1. Add an upload-processing provider to `LassoContext`, or extend
   `LassoRequestProvider` with a method that can move uploaded files. Avoid
   putting filesystem mutation in a pure metadata provider if the naming gets
   muddy.
2. Register `file_processuploads`.
3. Resolve destination paths using the same root confinement policy as
   `LassoFileSystemIncludeLoader`, unless a deployment-specific upload root is
   configured.
4. For each uploaded file:
   - enforce `-Size` maximum if present;
   - enforce `-Extensions` against original extension, case-insensitive;
   - choose original filename by default;
   - choose temp filename when `-UseTempNames` is set;
   - skip or error on existing destination unless `-FileOverwrite` is set.
5. Move when possible; copy+delete fallback if the temp and destination are on
   different volumes.
6. Return `.void` on success, matching docs that examples produce no output.
7. On file-level failure, set recoverable error state or throw
   `LassoRecoverableError` so `protect` can catch it.

### Tests

- Unit-level temp upload fixture with two files.
- Destination required.
- Size filter skips large file.
- Extension filter accepts only allowed extensions.
- Overwrite denied vs allowed.
- Live multipart smoke that proves the moved file survives after render.

### Risks

- Filename sanitization matters. Strip path separators and normalize weird
  browser-provided names.
- Do not allow upload moves outside the configured site/upload root without an
  explicit capability.
- Keep temp-file lifetime semantics front and center; this feature exists
  because those temp files disappear after render.

## 6. Custom Container Tags: -Container, -Looping, Run_Children

### Goal

Support Lasso 8 custom container tags defined with `Define_Tag(...,
-Container)` or `Define_Tag(..., -Looping)`, including `Run_Children`, without
breaking the current static block parser.

### Reference Findings

Lasso 8.5 Chapter 57 states that `-Container` and `-Looping` require matching
opening/closing tags and that `Run_Children` renders the enclosed contents.
`-Looping` updates `Loop_Count`; `-Container` does not. Container tag output is
not encoded by default. The same chapter explains overload ordering through
`-Priority` and `-Criteria`.

Lasso 9's local glossary describes the container concept as a `givenBlock`
association, and the Lasso 9 type docs describe the general member/callback
model. That confirms the longer-term design should treat the body as a callable
block attached to invocation, not as a hardcoded parser keyword.

### Usage Evidence

The startup-folder legacy pass deferred this because real startup libraries can
define container-like tags. The broad corpus has thousands of legacy closing
tags and custom tag definitions, so this is likely to matter as deeper pages
start executing.

### Current Implementation Surface

`BlockBuilder.blockNames` is a fixed set. Custom tag registration happens at
render time, after parsing. That means the parser cannot know whether
`[Ex_Font] ... [/Ex_Font]` is a block by consulting the tag registry. Current
`LassoCustomTagDefinition` stores body and parameter metadata, but not a
container/looping flag or deferred child body.

### Plan

1. Extend `LassoCustomTagDefinition` with metadata:
   - `isContainer`
   - `isLooping`
   - eventually `priority` and `criteria`.
2. Parse and store `-Container`/`-Looping` flags in both modern and legacy
   definition lowering.
3. Add a scanner/block-builder fallback for unknown matching tags:
   - when a non-block tag has a later matching closing tag, preserve it as a
     generic candidate container block rather than emitting an unexpected close;
   - keep diagnostics soft unless no matching close exists.
4. At render time, when a generic candidate block is reached:
   - if the registered tag is container/looping, invoke it with a child-render
     callback available as `Run_Children`;
   - otherwise render it as ordinary tag output and treat the closing tag as a
     diagnostic.
5. Implement `Run_Children` as a native function that renders the stored child
   nodes in the current call frame.
6. For `-Looping`, allow repeated `Run_Children` calls to update `Loop_Count`.
   Start with a simple per-call loop counter stack.
7. Defer `-Criteria` overload dispatch until a concrete corpus page needs it,
   but do not design the metadata in a way that blocks it.

### Tests

- Simple `Ex_Font` container wraps body once.
- `Run_Children` can be called twice and re-renders body twice.
- `-Looping` updates `Loop_Count` for repeated child renders.
- Non-container unknown close still reports a useful diagnostic.
- Legacy `Define_Tag: 'Name', -Container` and parenthesized form both lower to
  the same runtime definition.

### Risks

- This can destabilize parsing if the generic matching heuristic is too eager.
  Keep it limited to tag names with explicit closing tags in the same document.
- Rendering child nodes from inside evaluator-native calls crosses the same
  renderer/evaluator boundary as web_response include work. Prefer a small
  explicit callback frame over global mutable shortcuts.

## 7. Session Edge Cases

### Goal

Finish the documented session surface beyond the already-working named-session
core: `-useLink`, `-useAuto`, GET/POST `-lassosession` lookup, dynamic
`session_start` values, `session_deleteExpired()`, and live durable-driver
verification.

### Reference Findings

Lasso 8.5 Chapter 18 and LassoGuide 9.3 agree on the core model: sessions have
a name, a persisted variable list, and an ID. `session_start` loads or creates
a named session. ID lookup order is explicit `-id`, cookie, then
`-lassosession`. `session_deleteExpired()` is normally internal and triggers
cleanup of expired session storage. LassoGuide 9.3 documents `-useCookie`,
`-useLink`, `-useAuto`, `-useNone`, `-cookieExpires`, `-domain`, `-path`,
`-secure`, `-httponly`, and `-rotate`.

### Usage Evidence

The production e-commerce reports show 202 `-name`, 85 `-expires`, and 67 `-usecookie`
signals, including `Session_Start(-Name='<session>', -Expires=30, -UseLink,
-UseCookie)` and repeated `Session_Addvar`. Sulu and repo notes identify
sessions as a storefront/cart/auth concern.

### Current Implementation Surface

`LassoPerfectSession` implements named sessions over `PerfectSessionCore`.
`LassoSessionPreflight` recognizes literal `session_start(...)` calls.
`PerfectBackedLassoSessionProvider` prepares and finalizes async session work.
Memory and MySQL drivers are wired. Deferred: `-useLink`/`-useAuto`, GET/POST
fallback tracking, `session_deleteExpired()`, dynamic session names/flags, and
live MySQL session verification.

### Plan

1. Thread request query/post pairs into `PerfectBackedLassoSessionProvider`
   preparation so preflight can resolve `-lassosession:Name` fallback.
2. Add parsing for parameter names of the form `-lassosession:SessionName`,
   case-insensitive.
3. Implement `-useAuto`:
   - if tracker cookie exists, do not decorate links;
   - if no tracker cookie exists on first request, set cookie and mark response
     for link decoration.
4. Implement `-useLink` response decoration as a post-render transformation:
   - only `href` links;
   - only same-site relative/absolute paths;
   - skip `file://`, `ftp://`, `http://`, `https://`, `javascript:`,
     `mailto:`, `telnet://`, and `#`, matching LassoGuide behavior.
5. For HTML forms, do not auto-inject hidden inputs unless docs/corpus prove
   Lasso does. LassoGuide examples add hidden inputs manually.
6. Implement `session_deleteExpired()` as a native that calls a synchronous
   provider hook. Since `SessionDriver.clean()` is async, expose it at the
   server boundary or record a cleanup request for post-render async finalizing.
7. Add a second preflight path for simple dynamic names only if needed:
   literal variables assigned before `session_start` may be feasible; arbitrary
   computed names probably require async evaluator support and should remain
   deferred.
8. Live-test `LASSO_SESSION_DRIVER=mysql`.

### Tests

- Cookie lookup remains the primary default.
- Explicit `-id` wins over cookie.
- `-lassosession:Name` GET and POST fallback loads existing session.
- `-useLink` decorates only eligible links.
- `-useAuto` decorates first response and stops once cookie is present.
- `session_deleteExpired()` calls driver cleanup in a gated integration test.

### Risks

- Link rewriting is HTML-sensitive. Use a conservative parser/regex hybrid and
  avoid touching scripts, comments, and external URLs.
- Async session cleanup does not fit the current sync native function shape.
  Keep async work at the server boundary.

## 8. web_response->include*, includeBytes, sendFile

### Goal

Bridge Lasso 9 `web_response` include/file-serving methods to the adapter's
existing include/library and HTTP output machinery.

### Reference Findings

The local LP9 `Web Request and Response.txt` and LassoGuide 9.3 document
`web_response` as managing response data, includes, headers, cookies, and body
content. Methods include `include(path)`, `includeOnce(path)`,
`includeLibrary(path)`, `includeLibraryOnce(path)`, `includeBytes(path)`, and
`includes()`. The include path is restricted to the document root unless a full
path is explicitly converted.

Lasso 8.5 Chapter 31 documents `File_Serve` and `File_Stream`: serving a file
or data supersedes normal page output and effectively aborts the page. This is
the closest Lasso 8 analogue for `sendFile`-style behavior.

### Usage Evidence

`include` is already foundational: 415 production-ish e-commerce signals and 3,795
second-corpus signals. The backlog calls out `web_response->include*` specifically
because current include support exists only as `include()`/`library()` handled
inside `Renderer.renderExpression`, not as evaluator-level native type methods.

### Current Implementation Surface

`Renderer.renderInclude` and `renderLibrary` own include/library execution.
`NativeTypes.makeWebResponseType()` explicitly defers include methods because
native methods do not currently have a way to render loaded source. The server
response currently returns one accumulated HTML string after render, unless a
redirect is set.

### Plan

1. Introduce a `LassoRenderServices` or callback field on `LassoContext` that
   native methods can call for:
   - render include with output;
   - render include once;
   - execute library;
   - execute library once;
   - read raw bytes under include root.
2. Keep path policy in `LassoFileSystemIncludeLoader`; do not duplicate root
   confinement in `NativeTypes.swift`.
3. Refactor `Renderer.renderInclude`/`renderLibrary` to use the same service
   so free tags and `web_response` methods share behavior.
4. Implement:
   - `web_response->include(path)` returns rendered string;
   - `includeOnce(path)` returns rendered string once per request, then `.void`
     or empty string on subsequent calls after checking Lasso docs/corpus;
   - `includeLibrary(path)` executes definitions/output like `library`;
   - `includeLibraryOnce(path)` maps to existing per-request library dedupe;
   - `includes()` returns the include stack/history, not just current stack.
5. Add `includeBytes(path)` only after adding a byte representation or decide
   first pass returns a string decoded from bytes. Document this limitation.
6. For `sendFile`/`File_Stream`/`File_Serve`, add a response override to
   `ServerResponseSink`:
   - file URL/path;
   - content type;
   - download name;
   - status;
   - abort flag.
7. Teach `lasso-perfect-server` to return `FileOutput` or `BytesOutput` from
   that response override instead of the normal rendered HTML.

### Tests

- `web_response->include('x.lasso')` returns rendered include output.
- `web_response->includeLibraryOnce` registers a tag and dedupes per request.
- `includes()` records paths.
- Path escape tests mirror existing include-loader tests.
- File serving suppresses normal body and sets content type/name.

### Risks

- This crosses renderer/evaluator boundaries. Avoid making `LassoNativeMethod`
  itself render arbitrary nodes; pass a narrow service instead.
- Byte streams are not modeled. Be explicit about string fallback vs true bytes.
- File serving changes HTTP output shape, so server tests matter more than pure
  renderer tests.

## 9. Crawl/Report Filtering And Triage Quality

### Goal

Make `LASSO_CRAWL_REPORT=1` a sharper production-readiness tool by filtering
static/vendor HTML noise, preserving useful per-page data for diffing, and
supporting focused reruns for specific failure buckets.

### Reference Findings

This is an adapter tooling task rather than a Lasso language feature. The
relevant Lasso reference behavior is indirect: Lasso 8.5 pages can mix HTML and
Lasso syntax, and square brackets are always meaningful unless escaped by
`[noprocess]`/`[no_square_brackets]`. That means the crawler should not assume
every `.html` file under a site root is intended to be interpreted as Lasso.

LassoGuide 9.3 still supports mixed template/script use, so filtering must be
path/content-aware rather than extension-only.

### Usage Evidence

The first recursive run scanned 1,989 pages and found 1,666 clean. After Output
support, clean pages rose to 1,690. The notes identify
`unsupportedExpression("{")` and `unsupportedExpression("[")` buckets as mostly
vendor JavaScript demo pages with `.html` extensions, not genuine Lasso gaps.

### Current Implementation Surface

`CrawlReport.swift` discovers renderable pages by extension under
`LASSO_SITE_ROOT`, skips underscore-prefixed include-only files, requests each
page, groups failures by first unsupported construct, and can write per-page
JSON to `LASSO_CRAWL_REPORT_PATH`. Redirects count as clean.

### Plan

1. Add environment-configured excludes:
   - `LASSO_CRAWL_EXCLUDE_PATHS=assets/vendor,node_modules,...`
   - comma-separated substrings or glob-like patterns.
2. Add content heuristics for `.html`/`.htm`:
   - render if file contains `<?lasso`, `<?lassoscript`, square-bracket tags
     matching known Lasso names, or legacy closing tags;
   - skip if it is static/vendor-looking and contains no Lasso signals.
3. Keep `.lasso` and `.inc` behavior unchanged unless explicitly excluded.
4. Add focused rerun options:
   - `LASSO_CRAWL_ONLY_FAILURE=unknownFunction(\"Date_Format\")`
   - or `LASSO_CRAWL_PATH_LIST=/path/to/json-or-text`.
5. Improve JSON output:
   - include skipped files and skip reason when verbose mode is enabled;
   - include elapsed time and HTTP status;
   - include parser diagnostics separately from runtime errors.
6. Add baseline diff helper:
   - compare two JSON reports;
   - summarize newly clean, newly failing, changed failure bucket.
7. Document recommended crawl modes:
   - broad compatibility mode;
   - production-page mode with vendor excludes;
   - focused bucket mode after a fix.

### Tests

- Unit tests for path excludes.
- Unit tests for content heuristics on static HTML, Lasso-bearing HTML, and
  vendor JS demo HTML.
- JSON diff test using small fixture reports.
- Integration smoke against fixture site root.

### Risks

- Over-filtering can hide real Lasso pages. Default excludes should be empty;
  content heuristics should only apply to `.html`/`.htm` when configured or
  clearly static.
- The crawler is a diagnostic tool, not an implementation oracle. It should
  expose skip reasons so decisions stay auditable.

## Recommended Execution Order

1. Live MySQL verification and DB error framing.
2. `Date_Format` plus minimal date helpers.
3. `Decode_Base64`.
4. Expression-form `inline(...)`.
5. Crawl/report filtering, so later sweeps are less noisy.
6. `[File_ProcessUploads]`.
7. Session edge cases.
8. `web_response->include*` and file serving.
9. Custom container tags.

This differs slightly from the numbered priority list: crawler filtering moves
up after the top language/database buckets because it improves every subsequent
measurement pass, while custom container tags stay later despite being
important because they are the highest parser/runtime architecture risk.

# web_response->include*, includeBytes, sendFile (item 8)

## Status: Implemented, 2026-07-13

Item 8 of `Documentation/outstanding-compatibility-project-plans.md`'s
execution order. Unlike every other item in that backlog, a direct `grep`
against the real corpus found **zero** usages of anything this item
covers — `web_response->include*`, `sendFile`, `File_Serve`,
`File_Stream`, `includeBytes`, `includeLibrary`, `includeOnce`,
`includes()`. This matches the backlog doc's own framing: the item exists
for architectural completeness (the free `[include(...)]`/`[library(...)]`
tags already worked; the evaluator-level `web_response` method surface
didn't reach the same machinery), not an observed corpus gap. With no real
shape to mirror, this implementation follows the *documented* Lasso 8.5/9
contract precisely, and every place that contract was ambiguous is called
out explicitly below rather than silently resolved.

Design reviewed by `feature-dev:code-architect` before implementation
(including a live fetch of `lassoguide.com/operations/requests-responses.html`,
independently cross-checked). Implementation reviewed twice by
`feature-dev:code-reviewer`, with two real findings from the first pass
fixed before the second pass (which found nothing further).

## Reference contract (LassoGuide 9.3 + Lasso 8.5 Ch. 31)

`web_response` methods: `include(path)`, `includeOnce(path)`,
`includeLibrary(path)` (re-executes every call — no dedup, genuinely
different from `includeLibraryOnce`), `includeLibraryOnce(path)`,
`includeBytes(path)::bytes`, `includes()::trait_forEach` ("a stack of
currently executing filenames" — the live nesting stack), and
`sendFile(data::trait_each_sub, name=null, -type=null,
-disposition='attachment', -charset='', -skipProbe=false, -noAbort=false,
-chunkSize=..., -monitor=null)`. **`sendFile`'s `data` parameter is
already-evaluated content (string/bytes/file), not a path** — this
corrects the original backlog plan's framing, which conflated `sendFile`
with the genuinely path-based Lasso 8 `File_Serve`/`File_Stream`
(Chapter 31: "serving a file or data supersedes normal page output and
effectively aborts the page").

## Architecture

### `LassoIncludeRenderService`

A new protocol on `LassoContext` (`Sources/LassoParser/Providers.swift`),
matching this codebase's established provider-protocol convention
(`includeLoader`, `sessionProvider`, `responseSink`, `inlineProvider`,
`uploadProcessor` are all `(any SomeProtocol)?`, wired imperatively at
whichever call site constructs both a renderer and a context) rather than
a bare closure:

```swift
public protocol LassoIncludeRenderService: Sendable {
    func performInclude(path: String, once: Bool, context: inout LassoContext) throws -> String?
    func performLibrary(path: String, once: Bool, context: inout LassoContext) throws
}
```

`performInclude` returns `nil` (not `""`) when `once` is true and the path
was already included earlier in the same render — distinguishing "dedup
hit, no new output" from "include that legitimately rendered empty
output." Callers map `nil` to whatever no-op value fits their call site.

The concrete conformer, `RendererIncludeService`
(`Sources/LassoParser/Renderer.swift`), holds the *exact* pre-existing
cycle-detection/depth-limit/include-cache logic that used to live inline
in `Renderer.renderInclude`/`renderLibrary`, moved verbatim — this
guarantees zero behavioral drift for the free-tag path by construction,
not by re-implementation. `RendererEngine.init` wires
`evaluator.context.includeRenderService = RendererIncludeService()` the
same way it already wires `evaluator.renderNodes` (`Renderer.swift:29-40`).

**Exclusivity-safety rule**, followed at every call site (verified in code
review): a protocol witness stored on `context` cannot be invoked as
`context.includeRenderService?.performInclude(..., context: &context)` —
that's overlapping access to the same storage under Swift's exclusivity
checking. Every call site extracts to a local `let` first:
`guard let service = context.includeRenderService else { throw ... }`,
then `service.performInclude(..., context: &context)`.

### Dedup state

- `LassoContext.includedOncePaths: Set<String>` backs `includeOnce` —
  deliberately separate from `loadedLibraries` so an `include` path and a
  `library` path sharing a string don't cross-suppress each other.
- `includeLibraryOnce` and the free `library(...)` tag both use the
  pre-existing `loadedLibraries` dedup (the free tag's own doc comment
  already documented this as `library_once` semantics applied
  unconditionally — preserved exactly, not "fixed").
- `includeLibrary` (no dedup) needed its own guard — see "Found during
  review" below.

### `includeBytes`

No byte-level read API existed anywhere in this codebase before this
item, and no `LassoValue` case models binary data. First-pass, explicitly
lossy fallback: `LassoIncludeLoader` gained a `loadIncludeBytes(path:
from:)` sibling of `loadInclude` (default protocol-extension
implementation throws `.includeNotConfigured`, so the five other
`LassoIncludeLoader` conformers in this codebase — test/smoke loaders
predating `includeBytes` — don't need to change).
`LassoFileSystemIncludeLoader` shares 100% of `loadInclude`'s path-
resolution/root-confinement/extension-allowlist policy via a new private
`resolvedCandidateURL` helper; only the final read call differs
(`Data(contentsOf:)` vs `String(contentsOf:encoding:)`). The
`web_response->includeBytes` native does
`String(decoding: data, as: UTF8.self)` — lossy, never throws — and
returns `.string(...)`. **Documented limitation, not a crash**: a byte
sequence that isn't valid UTF-8 decodes with U+FFFD replacement
characters rather than failing the render or exposing raw bytes any other
way. Zero corpus evidence existed to size a real binary `LassoValue` case
correctly, so none was added this pass.

### `sendFile` / `file_serve` / `file_stream`

Two genuinely different constructs, kept separate:

- **`web_response->sendFile(data, name?, -type=, -disposition=, ...)`** —
  `data` is a plain Lasso string (already-evaluated content — e.g. from
  `includeBytes` or a variable), matching the real signature's
  string-accepting case exactly. No filesystem access at all. Sets a new
  `LassoFileServeRequest` on the response sink, then calls
  `context.setReturnSignal(.void)` — the exact short-circuit mechanism
  `web_response->abort()` already used (`NativeTypes.swift`), zero new
  control-flow machinery. `-noAbort` is unsupported (always aborts): this
  adapter's single-accumulated-response-string architecture has no "serve
  then keep composing more output" model.
- **`file_serve`/`file_stream` free-tag natives** (Lasso 8, genuinely
  path-based) — `-File`/`-Path` keyword or first positional, `-Type`
  override. Implemented as aliases of one identical registration (no
  documented behavioral distinction found between them for this adapter's
  purposes). The path is handed to the sink **unresolved** — actual
  existence/root-confinement happens at the server boundary via the same
  `fileURL(for:)` every other static-asset request already uses, so a
  missing or root-escaping path surfaces as a genuine HTTP 404/403 there,
  not a `[protect]`-catchable `LassoRecoverableError` (by the time that
  check runs, the page has already aborted via `returnSignal` — there's no
  page left for `[protect]` to catch anything on).
  **Deliberate divergence, flagged**: real Lasso 8's file-serving tags are
  very likely unconfined; this design root-confines them anyway, for
  consistency with every other filesystem-touching feature in this
  adapter (uploads, includes). No escape hatch this pass.

`LassoFileServeRequest` (`Providers.swift`) carries either `.data(Data)`
or `.path(String)`, plus optional `fileName`/`contentType`/`disposition`.
`disposition` is `nil` by default (not `"attachment"`) — `file_serve`/
`file_stream` have no documented disposition concept and never set it, so
the response builder correctly omits `Content-Disposition` entirely for
them; `sendFile` explicitly passes `"attachment"` when the caller didn't
override it, matching its real documented default.

`ServerResponseSink.serveFile` (`Sources/LassoPerfectServer/main.swift`)
just records the request (matching the existing `redirectURL`/
`headerPairs` "collect now, act after render" convention). `LassoSiteServer.render`
checks it **before** the existing redirect check — file-serving supersedes
normal page output. Response construction:
- `.path` source, no header override requested → real
  `FileOutput(localPath:)` — full ETag/Range support for free.
- `.path` source with an override, or any `.data` source → the file (if
  any) is read into memory and a `BytesOutput` is hand-assembled with
  headers. `Perfect-NIO`'s `FileOutput` is `public`, not `open` (confirmed
  by reading `FileOutput.swift` directly) — it cannot be subclassed to
  inject extra headers, so this branch is the only option when a
  `-Type`/name/disposition override is requested. **Deliberately no
  Range/ETag support in this branch** — a narrow, documented trade-off.

## Judgment calls (no confirmed documented answer in either reference)

- **`includeOnce`'s return value on a repeat call**: defaults to `.void`,
  matching `includeLibraryOnce`'s documented "no value" and this
  codebase's void-on-no-op convention elsewhere. Named explicitly in its
  own test (`includeOnceSecondCallReturnsVoidPendingDocConfirmation`).
- **`includes()`'s scope**: reflects the live include-family nesting stack
  only (`context.includeStack`) — `library`/`includeLibrary`/
  `includeLibraryOnce` calls never push onto it, matching the pre-existing
  free-tag `library(...)`'s own scope. Confirmed via LassoGuide 9.3's
  "currently executing filenames" wording, but which filenames count is
  the judgment call.
- **`file_serve` vs `file_stream`**: implemented as aliases of one
  identical registration. No documented behavioral distinction found.
- **Root confinement for `file_serve`/`file_stream`**: applied
  deliberately, diverging from real Lasso 8's likely-unconfined posture,
  for consistency with the rest of this adapter.
- **`sendFile -noAbort`**: unsupported (always aborts).

## Found and fixed during code review, before merge

1. **Stack-overflow risk in `includeLibrary`** (the no-dedup `once: false`
   path). `include`/`includeOnce` are protected by the pre-existing
   `includeStack` cycle/depth guard regardless of dedup state, and
   `includeLibraryOnce`/the free `library(...)` tag are protected by
   `loadedLibraries` dedup even on self-reference. `includeLibrary` had
   neither — a self- or mutually-recursive `includeLibrary` chain would
   have recursed through native Swift calls unboundedly and crashed the
   entire server process (an unrecoverable trap, not a catchable Lasso
   error), not just failed one request. Fixed with a new, independent
   `LassoContext.libraryStack` guard mirroring `includeStack`'s exactly,
   kept on a **separate** stack so it doesn't affect `includes()`'s
   documented include-family-only scope. Regression tests:
   `includeLibraryDetectsSelfReferentialCycleInsteadOfCrashing`,
   `includeLibraryEnforcesDepthLimitOnChainedRecursion`.
2. **`Content-Disposition`'s `filename="..."` wasn't escaping embedded `"`/
   `\`**. The pre-existing `headerSafe` helper only strips CR/LF
   (sufficient to prevent HTTP header/response-splitting, since CR/LF are
   the only HTTP line terminators) but doesn't escape quote characters
   inside an RFC 6266 `quoted-string`. A script-controlled filename
   containing `"` could terminate the quoted string early and inject
   trailing bogus header parameters. Fixed with a new `quotedStringSafe`
   helper (escapes `\` before `"`, applied after `headerSafe`). Regression
   test: `bytesFileOutputBuildsDispositionWithEscapedFilenameWhenNameGiven`.

## Test coverage

- `Tests/LassoParserTests/LassoParserTests.swift` — 23 new tests: include/
  includeOnce/includeLibrary/includeLibraryOnce round-trips (dedup vs not,
  both directions), the `includeOnce` void-on-repeat judgment call,
  `includes()` stack-scoping (nested include vs library-only), the
  `includeLibrary` cycle/depth regression, `includeBytes` (text round-trip
  + lossy-invalid-UTF8 case), path-escape rejection run through the
  `web_response` surface (not just the free tags) for `include`,
  `includeLibrary`, and `includeBytes` independently, `sendFile` (data
  payload, headers, abort short-circuit, legacy-sink no-op default), and
  `file_serve`/`file_stream` (path recording, aliasing, abort, default
  no-disposition, positional-argument form).
- `Tests/LassoPerfectServerTests/LassoPerfectServerTests.swift` — new test
  target (`LassoParserTests` can't reach the `LassoPerfectServer`
  executable target's code). 6 tests covering `headerSafe`,
  `quotedStringSafe`, and `bytesFileOutput`'s header assembly across all
  three response shapes (no override / name+type override / path override
  with no name).
- Regression: every pre-existing free-tag `[include(...)]`/`[library(...)]`
  test (including the real-corpus-fixture-backed `rendersCorpusFixtures`)
  still passes byte-for-byte after the `renderInclude`/`renderLibrary`
  refactor.
- **145/145 tests pass** across all four test targets
  (`LassoParserTests` 128, `LassoPerfectServerTests` 6,
  `LassoSubsetCrawlerTests` 1, `LassoCrawlReportTests` 10). No regressions.

## Live verification (real HTTP, 2026-07-13)

Since zero real corpus pages exercise any of this, "live verify" means a
throwaway set of pages placed directly in the real site root (see the
`lasso-real-corpus-paths` project memory for the path), served by
`lasso-perfect-server` over real HTTP, then removed. All results matched
exactly:

- **Include family** (`_item8_check.lasso`): `include` rendered the
  target file's content; the first `includeOnce` call rendered, the
  second returned empty (void); `includeLibrary` correctly registered a
  callable custom tag; `includeBytes` round-tripped text content;
  `includes()` was empty both outside any include and (separately
  confirmed) empty inside a library-only call, per its documented scope.
- **`sendFile`**: response body was *exactly* the payload string (the
  page's trailing text never rendered, confirming the abort
  short-circuit), with `Content-Type: text/plain` and
  `Content-Disposition: attachment; filename="item8.txt"` set correctly.
- **`file_serve`, no override**: `Accept-Ranges`/`ETag` present (the real
  `FileOutput` path), correct body.
- **`file_serve`, with `-Type` override**: correct `Content-Type`, no
  `ETag`/`Accept-Ranges` (the documented BytesOutput-fallback trade-off),
  correct body.
- **`file_serve`, path escaping the site root** (`../../../../etc/passwd`):
  real HTTP `403 Forbidden`, `/etc/passwd` never touched.
- **`file_serve`, missing file**: real HTTP `404 Not Found` — confirmed
  this is a genuine server-boundary 404, not a `[protect]`-catchable
  recoverable error, matching the documented design decision.

Also ran `LASSO_CRAWL_REPORT=1 LASSO_CRAWL_EXCLUDE_PATHS=vendor` against
the full real corpus (875 pages, 671 render cleanly) after the throwaway
files were removed: every failure category present
(`extensionNotAllowed`, `unknownFunction("if"/"File_ListDirectory"/etc.)`,
`fileNotFound`, `invalidAssignment`, various `unsupportedExpression`
cases) is a pre-existing, previously-documented gap unrelated to
include/library/file-serving — no new failure category appeared,
confirming no regression in the free-tag `[include(...)]`/`[library(...)]`
path that 415+/3,795+ real corpus signals depend on.

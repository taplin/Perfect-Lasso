# Crawl/Report Filtering And Triage Quality Plan

Last reviewed: July 12, 2026

## Implementation Status (2026-07-12)

Implemented. `Documentation/outstanding-compatibility-project-plans.md` item
9, next in the "Recommended Execution Order" after Live MySQL/DB-error
framing, Date_Format, Decode_Base64, and the `inline` bare-colon-call fix.

Grounded scope in real evidence, pulled directly from the two most recent
crawl JSONs this session already had on disk (from the `inline` fix
verification): **1,053 of 1,989 pages (53%)** live under a `*/vendor/*`
path, and **95 of the then-299 failing pages (32%)** were vendor pages
hitting `unsupportedExpression("{")`/`("[")`/`("-i")`/`("=")`/`("")`/
`("Member <unknown>")` — genuine third-party JS/HTML demo syntax
misparsed as Lasso, not real interpreter gaps.

Found a directly reusable precedent already in this repo:
`Sources/LassoSubsetCrawler/LassoSubsetCrawler.swift`'s `Scanner` (a
separate, older, static-analysis tool, not the live HTTP crawler) already
solves "does this .htm/.html file actually contain Lasso" via a marker
list, and already supports path-substring excludes. Ported the exact same
marker list into the new code rather than inventing new signals, so both
tools agree on what counts as real Lasso content.

**Architecture note**: extracted the crawler's logic out of
`LassoPerfectServer` (a genuine top-level-executing `main.swift`, not
`@main`-based) into its own new library target, `LassoCrawlReport`
(`Sources/LassoCrawlReport/CrawlReport.swift`). A test target depending
directly on `LassoPerfectServer` risked executing real server-startup code
(port binding, env-var-driven config) as a side effect of `@testable
import` — `LassoSubsetCrawlerTests` already depends directly on
`LassoSubsetCrawler`, but that target uses `@main struct { static func
main() }`, a meaningfully different (and safe-to-import) shape. Splitting
the pure, testable logic into its own library sidesteps the ambiguity
entirely rather than relying on unverified assumptions about SwiftPM/Swift
6 module-import semantics.

Implemented:

- **Path excludes** — `LASSO_CRAWL_EXCLUDE_PATHS` (comma-separated,
  case-insensitive substrings, e.g. `vendor`). Default empty.
- **Content heuristic for `.htm`/`.html` only** — `.lasso`/`.inc` behavior
  is completely unchanged.
- **Focused rerun**, two independent mechanisms: `LASSO_CRAWL_PATH_LIST`
  (a file of newline-delimited paths, `#`-comments allowed) and
  `LASSO_CRAWL_BASELINE` + `LASSO_CRAWL_ONLY_FAILURE` (reuses the
  crawler's own JSON output format as the baseline — no second file
  format invented).
- **Offline diff mode** — `LASSO_CRAWL_DIFF_BASELINE` +
  `LASSO_CRAWL_DIFF_CURRENT`, needs neither a site root nor a running
  server; short-circuits before `ServerConfig.load()`.
- **JSON output**: `elapsedMS` per page; a separate excluded-page count
  printed alongside clean/failing totals so filtering stays auditable.

**One real, non-obvious bug found and fixed while writing unit tests for
`discoverPaths`** (not part of the original plan, but directly caused by
it — this feature is what first put a temp-directory unit test on this
code path at all): the relative-path computation
(`String(url.path.dropFirst(siteRoot.path.count))`) silently mis-sized
whenever `FileManager`'s URL-based enumerator resolved a symlink in the
returned absolute paths that the caller's `siteRoot` hadn't already been
resolved through — concretely, macOS's `/var` → `/private/var` (a
firmlink, which `resolvingSymlinksInPath()` does not reliably normalize
either). This was a latent bug in the pre-existing code too, just never
triggered because `main.swift`'s `ServerConfig.load()` always pre-resolves
the real site root before ever calling in. Fixed by switching to the
path-relative `FileManager.enumerator(atPath:)` overload, which returns
paths already relative to the root — sidestepping absolute-path symlink
arithmetic entirely rather than trying to resolve it more carefully.

Verified via 10 new unit tests (`Tests/LassoCrawlReportTests/`, no live
server needed for any of them) and three live-verification passes against
the real corpus:

1. `LASSO_CRAWL_EXCLUDE_PATHS=vendor` — failing-page count dropped from
   299 to 204 (**exactly** the evidenced 95-page reduction), with 1,114
   pages correctly reported as excluded (matching the ~1,053-page vendor
   estimate plus the additional non-vendor static `.html`/`.htm` pages the
   content heuristic also now skips).
2. The diff mode, run directly against this session's own real
   before/after JSONs from the `inline` fix — reproduced, byte-for-byte,
   the exact 14-page `unknownFunction("inline")` → `inlineNotConfigured`
   bucket change already found by hand earlier in the session.
3. The focused-rerun mechanism (`LASSO_CRAWL_BASELINE` +
   `LASSO_CRAWL_ONLY_FAILURE`), crawling only the 14 pages matching
   `Encrypt_HMAC` instead of the full ~1,989-page site.

Deferred, with reason: separating "parser diagnostics" from "runtime
errors" in JSON output — every real failure bucket found this entire
session has been a runtime error, never a parse-time diagnostic reaching
this code path; no evidenced need yet.

## Goal

Make `LASSO_CRAWL_REPORT=1` a sharper production-readiness tool: filter
static/vendor HTML noise, preserve useful per-page data for diffing, and
support focused reruns for specific failure buckets — replacing the ad hoc
`python3 -c "..."` JSON diffing this project's own development sessions
repeated after every single fix pass.

## Design

### `LassoCrawlReport` library target

`Sources/LassoCrawlReport/CrawlReport.swift` — `public` types
(`CrawlPageResult`, `CrawlDiffSummary`) and a `public enum CrawlReport`
with `run`/`discoverPaths`/`looksLikeLassoSource`/`loadPathList`/
`loadBaseline`/`pathsMatchingFailure`/`diff`/`printDiff`/`printAndWrite`.
`LassoPerfectServer` depends on it and is otherwise unchanged in shape;
`Tests/LassoCrawlReportTests/` depends on it directly, mirroring the
existing `LassoSubsetCrawlerTests` → `LassoSubsetCrawler` pattern in
`Package.swift`, but without executing any of `LassoPerfectServer`'s
top-level server-startup code.

### Path excludes and content heuristic

`discoverPaths(siteRoot:extensions:excludePaths:)` (public, so tests can
exercise real filesystem discovery without a live server) filters, in
order: underscore-prefixed files (unchanged), hidden path components
(unchanged), `excludePaths` case-insensitive substring matches against the
site-root-relative path, then — only for `.htm`/`.html` — a real-content
check via `looksLikeLassoSource(_:)` against the same marker list
`LassoSubsetCrawler.Scanner` already uses (`<?lasso`, `[inline`,
`[records`, `[rows`, `[if`, `[var`, `[local`, `[include`, `[define`,
`[protect`, `[iterate`, `[loop`, `[while`, `[no_square_brackets`).

### Focused rerun and diff

`loadBaseline(_:)` reads the crawler's own JSON output format back in —
the same shape `printAndWrite` writes — reused both for
`LASSO_CRAWL_ONLY_FAILURE` (`pathsMatchingFailure(_:substring:)`) and the
offline `diff(baseline:current:)` mode, rather than inventing a second
file format for either. `diff` only compares pages present in both inputs
for clean/failing/bucket-change purposes; pages unique to either side are
reported separately (`onlyInBaseline`/`onlyInCurrent`) since that's a
path-list/exclude change between runs, not a render-outcome change.

## Files touched

- `Sources/LassoCrawlReport/CrawlReport.swift` — new (moved from
  `Sources/LassoPerfectServer/CrawlReport.swift`, made public, extended).
- `Sources/LassoPerfectServer/main.swift` — new env vars in `ServerConfig`;
  offline diff-mode short-circuit before `ServerConfig.load()`; focused-
  rerun/exclude wiring in the crawl-report block.
- `Package.swift` — new `LassoCrawlReport` library target,
  `LassoCrawlReportTests` test target.
- `Tests/LassoCrawlReportTests/CrawlReportTests.swift` — new.
- `Documentation/lasso-perfect-server.md` / `compatibility-matrix.md` /
  `outstanding-compatibility-project-plans.md` — narrative updates.

## Deferred

- Separating parser diagnostics from runtime errors in JSON output — no
  evidenced need; every real failure bucket found this session has been a
  runtime error.

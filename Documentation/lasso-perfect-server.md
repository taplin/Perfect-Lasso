# Lasso Perfect Test Server

Date: 2026-07-09

## Purpose

`lasso-perfect-server` is the first integration harness for serving existing
site files through the Swift Lasso parser/runtime and Perfect backend pieces.
It is intentionally a developer server, not a compatibility claim for a full
legacy site.

## Configuration

```bash
LASSO_SITE_ROOT='/path/to/your/site/root' \
LASSO_SERVER_PORT=8183 \
LASSO_DATASOURCE_ALIAS=catalog_mysql \
LASSO_MYSQL_HOST=localhost \
LASSO_MYSQL_DATABASE=catalog_mysql \
LASSO_MYSQL_USER=perfect \
LASSO_MYSQL_PASSWORD='...' \
swift run lasso-perfect-server
```

Environment variables:

- `LASSO_SITE_ROOT`: filesystem root to serve.
- `LASSO_SERVER_PORT`: port, default `8181`.
- `LASSO_RENDER_EXTENSIONS`: comma-separated extensions rendered through Lasso,
  default `lasso,inc,html,htm`.
- `LASSO_DATASOURCE_ALIAS`: datasource name used by Lasso pages, for example
  `catalog_mysql`.
- `LASSO_MYSQL_HOST`, `LASSO_MYSQL_PORT`, `LASSO_MYSQL_DATABASE`,
  `LASSO_MYSQL_USER`, `LASSO_MYSQL_PASSWORD`: backend MySQL connection.

## Current Behavior

- GET-only test server using Perfect-NIO.
- Non-rendered files are served as static files.
- Lasso-rendered files receive filesystem include loading rooted at
  `LASSO_SITE_ROOT`.
- Query parameters, headers, and cookies are exposed through the current
  `LassoRequestProvider` boundary.
- Structured `inline` reads can reach PerfectCRUD and Perfect-MySQL when a
  datasource alias is configured.
- Render failures return a developer HTML error page and stderr log line with
  the request URI, route path, resolved site path, filesystem path, Swift error
  type, include stack, and any parser diagnostics collected before the runtime
  failure.

## Verified

- Fixture root:
  - `/__lasso_health` returns `ok`.
  - `/billboard.lasso` renders an include-backed fixture page.
  - `/category.lasso` renders nested include/request-path output.
- Real corpus site root (an external, non-committed site checkout, pointed at
  via `LASSO_SITE_ROOT`):
  - `/__lasso_health` returns `ok`.
  - A static, non-rendered file serves successfully.
  - A representative real page using the `[/* ... */]` bracket-comment idiom
    previously crashed the renderer with `unsupportedExpression("*")`; fixed
    2026-07-09 (the template scanner now treats `/*` immediately inside a
    bracket tag as the start of a real Lasso comment that spans raw text and
    nested `[ ]` tags until the next literal `*/`, matching real Lasso
    semantics, instead of misparsing it as a closing tag or a bad
    expression). That page now returns `200 OK`, though it still renders no
    visible content until `library()`, custom-tag registration, and template
    includes (below) are implemented.
  - A representative script-mode real page previously reported
    `unknownFunction("library")`; fixed 2026-07-09 — `library()` now loads and
    caches a file's `define`d tags once per server process, shared across
    every request. See `Documentation/library-and-custom-tags.md`. That page
    now gets past the `library()` call and reaches a separate, newly-exposed
    gap (below) rather than failing immediately at line 1.
  - Loading a real startup library through the now-working `library()`
    surfaced a distinct, pre-existing gap, fixed 2026-07-09: `<?lasso ... ?>`
    and `<?= ... ?>` delimiter content (as opposed to `<?lassoscript ... ?>`
    or bracket-dialect `[ ]` tags) used to parse purely as a flat expression
    list (`ExpressionParser.parseList()`), with no concept of blocks at all.
    A real startup library using `if(!tag_exists(...)) => { library(...) }`
    control flow inside plain `<?lasso ?>` (the delimiter real Lasso library
    files typically use) parsed `if(...)` as an ordinary function call named
    `if`, failing at render time with `unknownFunction("if")`. This was
    unreachable before `library()` worked, since `library()` used to throw
    before ever loading a real library's content.
  - The fix: `.lasso`/`.echo` content now routes through the same
    block-aware `ScriptBodyParser` `.lassoscript` already used, and
    `ScriptBodyParser` was taught to close blocks opened with Lasso 9's
    arrow-brace style (`if(...) => { ... }`, including `if`/`else` pairs and
    mixed brace/slash-style nesting), not just the legacy slash-closed style
    (`if(...) ... /if`) it already handled. `ScriptBodyParser` also gained
    diagnostics collection along the way (unterminated brace bodies, stray
    closing braces, malformed `define`s) — it previously collected none at
    all.
  - Verified against the real corpus: `/api.lasso` no longer fails on
    `unknownFunction("if")`, and the subsequent
    `unknownFunction("lasso_tagexists")` gap is fixed 2026-07-09.
    `lasso_tagexists(name)` and `tag_exists(name)` now check both the native
    registry and the shared custom-tag registry, so startup-library guards can
    ask about built-in tags and `define`d tags.
  - The next distinct compatibility gap from the live server run was
    `unknownFunction("excludeBots")`. Follow-up inspection showed
    `excludeBots` is a normal `define`d custom tag in
    `components/site_setup_tags.inc`, while `_begin.lasso` only loads
    `components/koi_setup.inc` before calling it. Treat this as a
    startup/include ordering or missing-library-load issue, not as part of the
    `ApiHandler` object model.
  - `define Foo => type { ... }` is now partially implemented for the
    `ApiHandler` shape in `/api.lasso`: data members, public methods,
    `onCreate`, `self`, object construction, member access, and basic multiple
    dispatch. See `Documentation/lasso-type-object-support.md`.

The parser/runtime source and its smoke suite (`Sources/LassoParserSmoke`,
`Tests/LassoParserTests`) never hardcode a real site path or real page
content. Real-corpus verification of this kind is opt-in via
`LASSO_SMOKE_REAL_PAGE_PATH`/`LASSO_SMOKE_REAL_SITE_ROOT` (template pages) and
`LASSO_SMOKE_REAL_API_PAGE_PATH` (script-mode pages) on `LassoParserSmoke`, or
by pointing `lasso-perfect-server` itself at a real `LASSO_SITE_ROOT` locally.

## Next Compatibility Work

1. Resolve the `excludeBots` startup gap by determining whether
   `components/site_setup_tags.inc` should be loaded by `_begin.lasso`, by the
   local site harness, or by another startup file that the current server path
   is not executing.
2. Continue the object runtime toward the next corpus need: likely
   `_unknowntag`, rest parameters, or richer type/trait dispatch once a page
   actually exercises those constructs.
3. Expand request/response support for POST bodies, redirects, status, and
   cookies.
4. Add a crawl/report mode that requests many site paths and records the first
   unsupported construct per page.

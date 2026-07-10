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
- `LASSO_STARTUP_PATH`: filesystem path to a Lasso instance startup folder
  (real Lasso convention: `LassoStartup`, kept entirely outside the site
  webroot). No default — opt-in only. If set, every file in it matching
  `LASSO_RENDER_EXTENSIONS` is loaded once, in filename order, before the
  server accepts connections, registering any `define`d tags/types it
  contains into the shared registry every request uses. A file that fails
  to parse or render is logged to stderr and skipped; it does not prevent
  the server from starting or the rest of the folder from loading. See
  "Verified" below for what this surfaced against a real startup folder.
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
    another, unrelated setup include before calling it. Treat this as a
    startup/include ordering or missing-library-load issue, not as part of the
    `ApiHandler` object model.
  - `define Foo => type { ... }` is now partially implemented for the
    `ApiHandler` shape in `/api.lasso`: data members, public methods,
    `onCreate`, `self`, object construction, member access, and basic multiple
    dispatch. See `Documentation/lasso-type-object-support.md`.
  - **Instance startup folder.** A real Lasso instance keeps a `LassoStartup`
    folder entirely outside the site's webroot (a real instance's own
    `/var/lasso/instances/<name>/LassoStartup`) that gets loaded once,
    before any page is served, registering every tag/type definition in it —
    this is what makes tags like `excludeBots` available without any
    `library()` call on the page itself. `loadLassoStartupDirectory`
    (`Sources/LassoParser/StartupLoader.swift`) implements this: given a
    directory and an allowed-extensions set, it loads every matching file
    once, in filename order, sharing one `LassoTagRegistry` — a file that
    fails to parse or render is recorded (file name + error) rather than
    thrown, so one bad file doesn't block the rest of the folder. Wired into
    `lasso-perfect-server` via `LASSO_STARTUP_PATH` (opt-in, no default),
    using the same `LASSO_RENDER_EXTENSIONS` extension set already governing
    page rendering — real deployments commonly register custom extensions
    for both, so one setting covering both is correct, not a shortcut.
    Credentials embedded in real startup-folder tag bodies (verified: a real
    PayPal API key/signature in `paypal_express.inc`) never transit the
    website even when the tag using them is called from a page, since only
    the tag's *output* renders, never its source — this is treated as
    already-adequate protection for this class of secret, not a gap to close.
  - **Live-verified against a real instance's startup folder** (10 files): 5
    load cleanly with no errors (a site-setup include, a hash-test file, a
    cart-tag include, and two browser/bot-detection tag files — see the
    bracket-comment fix below for why those last two needed a real fix, not
    just verification). The other 5 fail on distinct, now-cataloged
    legacy-syntax gaps — see `Documentation/compatibility-matrix.md`'s new
    startup-folder rows for the full list (legacy `define_tag(...)`
    parenthesized-call style, legacy `define_type:`/`define_tag:` colon-call
    style, top-level expression-bodied `define name => 'literal'` with no
    braces, and `with x in y do { ... }` iteration). None of these are bugs
    in the loading mechanism itself — each is a real, unimplemented syntax
    form, confirmed by reading the exact failing line in each file.
  - **Bracket-comment fix, found and fixed via the same live verification.**
    Two of the ten real files use a real idiom (downloaded from
    lassosoft.com/tagswap): an entire custom tag — `define name(...) => {
    ... }`, comments and all — wrapped in one `[ ... ]` bracket span, with
    `//lasso` as the first line, a plain comment reminding a human reader
    the bracket holds Lasso code, not a directive with any parsing
    significance. Tim identified this from the real corpus content. Two
    bugs had to be fixed together for it to actually work, not just avoid
    throwing:
    1. `TemplateScanner.scanSquare()`'s bracket-boundary scan had no
       comment awareness at all — it tracked `'`/`"` quotes and looked for
       the closing `]` character by character, with nothing telling it a
       `//` or `/* ... */` span shouldn't count. The real file's own
       `/* ... */` header comment contains both an apostrophe ("Bil Cory's")
       and a literal `[lp_client_browser(9)]` example in its prose — the
       naive scan stopped at that inner `]`, treating a few lines of
       comment as the *entire* bracket body and silently turning the rest
       of the real file into raw template text. Fixed by teaching the scan
       to skip `//`-to-end-of-line and `/* ... */` spans (only outside an
       active quote) while searching for the true close.
    2. Even with the scan boundary fixed, the tag still didn't register:
       `emitCode`'s legacy-closing-tag check (`body.hasPrefix("/")`, for
       the `[/if]`-style convention) fired on the leading `//` of `//lasso`
       itself, since `//` does start with `/`. The whole body — including
       the real `define` — was swallowed as a bogus closing tag with a
       nonsense multi-line "name," registering nothing, but also throwing
       no error, so the file appeared to "load successfully" while
       silently doing nothing. Fixed by excluding `//` and `/*` from that
       prefix check. Separately, since this shape's real body needs
       multi-statement, comment-aware parsing (the existing single-
       expression bracket-tag path only ever kept the first parsed token),
       a bracket body that opens with `define` after skipping leading
       comments now routes through `ScriptBodyParser` — the same parser
       `<?lasso ?>` content already uses — instead of the flat
       `ExpressionParser.parseList()` path ordinary `[$var]`-style tags
       still use unchanged.
    A regression test
    (`squareBracketScanningSkipsCommentsWhenFindingTheClosingBracket`)
    reproduces the real shape end to end: defines a tag inside a
    `[//lasso ... ]` span with both comment styles present, then calls it
    and checks the real output, not just that parsing didn't throw.
  - **Found and fixed while live-verifying:** a real, evidenced parser bug,
    distinct from the legacy-syntax gaps above. `_begin_tags.inc` failed
    with `unknownFunction("STK_debug")` — surprising, since `STK_debug` is
    itself `define`d earlier in the same file. Root cause: its body's
    opening `{` sits on its own line after `=>` (`define STK_debug(...) =>`
    / `{` on the next line), and `ScriptBodyParser` only skipped same-line
    whitespace between `=>` and `{`, not newlines — so `parseDefineOpening`
    silently backed out of recognizing the `define` at all, and
    `STK_debug(...)` was then parsed and executed as an ordinary top-level
    function call to an undefined function. This is a very common real-world
    Lasso formatting style, not an edge case. Fixed by using the existing
    `skipTrivia()` (whitespace and comments, not just same-line spaces)
    instead of `skipHorizontalWhitespace()` at the two points — one in
    `parseDefineOpening`, one in the shared
    `consumeArrowBlockStartIfPresent()` used by `if`/`loop`/etc. — that
    check for `{` immediately after a matched `=>`. Verified: `_begin_tags.inc`
    now fails only on the legacy `define_tag(...)` call further down the
    file, past both `STK_debug` and `asbetterstring` (which has the same
    line-broken shape and now also registers correctly).
  - **A regression was caught and fixed in the same pass, before this
    landed.** The first attempt at the fix above made
    `consumeArrowBlockStartIfPresent()`'s *pre*-`=>` whitespace skip
    multi-line too. That broke ordinary slash-style blocks
    (`if(cond)\n  body\n/if`): the probe for `=>` would cross the newline
    onto the block body's first line, fail to find `=>` or `{` there, and
    return `false` — but its caller unconditionally calls
    `skipLineRemainder()` next, which then swallowed that first body line
    as if it were the block-opening line's own trailer. Caught by 3
    unrelated existing tests failing (`customTagDefinesCallsAndIsolatesLocals`,
    `customTagRecursionSucceedsAndDeepRecursionThrows`,
    `parsesAndRendersLassoScriptInlineJSON`) on the first `swift test` run
    after the change. Fixed by keeping the *pre*-`=>` skip same-line-only —
    multi-line skipping is only safe once `=>` has actually been matched and
    the parser is committed to arrow-brace mode. A regression test
    (`slashStyleBlockBodyIsNotSwallowedWhenNoArrowFollows`) now guards this
    specifically.
  - `excludeBots` is still unresolved, but the reason is now precisely
    known and different from the original guess (a startup/include ordering
    problem). `site_setup_tags.inc` — the file `excludeBots` lives in —
    fails to load at all, on its own *earlier* statement `define br =>
    '<br />'` (an expression-bodied, no-brace `define`, a different,
    still-unimplemented gap — see the compatibility matrix). Because
    `RendererEngine.render` aborts the whole file on the first throwing
    top-level statement, that one early failure prevents every later
    `define` in the file — including `excludeBots` — from ever registering,
    regardless of whether `excludeBots`'s own body would otherwise parse.
    Implementing expression-bodied top-level `define` support (mirroring
    `TypeBodyParser.parseExpressionMethodBody`, which already does this for
    type methods) is now the single highest-leverage next step for this
    gap — likely higher-leverage than `with...in...do` itself, since
    `excludeBots` can't even be reached to test that construct until this
    unblocks the file.

The parser/runtime source and its smoke suite (`Sources/LassoParserSmoke`,
`Tests/LassoParserTests`) never hardcode a real site path or real page
content. Real-corpus verification of this kind is opt-in via
`LASSO_SMOKE_REAL_PAGE_PATH`/`LASSO_SMOKE_REAL_SITE_ROOT` (template pages) and
`LASSO_SMOKE_REAL_API_PAGE_PATH` (script-mode pages) on `LassoParserSmoke`, or
by pointing `lasso-perfect-server` itself at a real `LASSO_SITE_ROOT` locally.

## Next Compatibility Work

1. Support top-level expression-bodied `define name => 'literal'` (no
   braces) in `ScriptBodyParser.parseDefineOpening` — the single
   highest-leverage remaining startup-folder gap; it's what blocks
   `excludeBots` from registering at all (see above), and it independently
   blocks all of `paypal_express.inc`'s constant tags.
2. Implement `with x in y do { ... }` iteration — needed once `excludeBots`
   itself can be reached, to actually call it (not just register it).
3. Evaluate whether legacy `define_tag('name', -flags) ... /define_tag`
   (parenthesized-call style, blocks `_begin_tags.inc`'s `send_email2` and
   all of `getGeoIPInfo.inc`) and legacy `define_type:`/`define_tag:`
   colon-call style (blocks all of `js_timer.inc`) are worth real support,
   given real corpus frequency — both are now precisely characterized (see
   `Documentation/compatibility-matrix.md`) but neither is implemented.
4. Continue the object runtime toward the next corpus need: likely
   `_unknowntag`, rest parameters, or richer type/trait dispatch once a page
   actually exercises those constructs.
5. Expand request/response support for POST bodies, redirects, status, and
   cookies.
6. Add a crawl/report mode that requests many site paths and records the first
   unsupported construct per page.

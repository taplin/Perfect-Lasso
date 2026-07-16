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
- `LASSO_DATASOURCE_ALIAS`: MySQL-only, legacy single-alias form; datasource
  name used by Lasso pages, for example `catalog_mysql`. Supports exactly
  one alias, and only MySQL — see `LASSO_DATASOURCE_CONFIG_PATH` below for
  multiple aliases and/or a FileMaker Server datasource.
- `LASSO_MYSQL_HOST`, `LASSO_MYSQL_PORT`, `LASSO_MYSQL_DATABASE`,
  `LASSO_MYSQL_USER`, `LASSO_MYSQL_PASSWORD`: backend MySQL connection.
- `LASSO_FILEMAKER_HOST`, `LASSO_FILEMAKER_PORT`, `LASSO_FILEMAKER_USER`,
  `LASSO_FILEMAKER_PASSWORD`, `LASSO_FILEMAKER_ALLOW_WRITES`: backend
  FileMaker Server connection — see "FileMaker Datasource" below. Only
  meaningful alongside `LASSO_DATASOURCE_CONFIG_PATH`, since there's no
  legacy single-alias env-var form for FileMaker (it postdates that
  convention).
- `LASSO_DATASOURCE_CONFIG_PATH`: path to a JSON file, for real deployments
  with more than one Lasso-side datasource alias, a FileMaker Server
  datasource, and/or where a real password shouldn't land on the command
  line or in shell history. Takes priority over the env vars above when
  set. Current shape:
  ```json
  {
    "mysql": {
      "host": "localhost",
      "port": 3306,
      "user": "perfect",
      "password": "...",
      "sessionDatabase": "sessions",
      "allowWrites": false,
      "allowRawSQL": false
    },
    "filemaker": {
      "host": "203.0.113.10",
      "port": 80,
      "user": "perfect",
      "password": "...",
      "allowWrites": false
    },
    "datasources": {
      "primary_mysql": {"type": "mysql", "schema": "primary_mysql"},
      "orders_mysql": {"type": "mysql", "schema": "orders_mysql"},
      "fm_catalog": {"type": "filemaker"},
      "fm_catalog_backup": {"type": "filemaker", "host": "192.0.2.5"}
    }
  }
  ```
  Both `mysql` and `filemaker` blocks are optional (a deployment with only
  one backend just omits the other); every field within each is itself
  optional, falling back to that backend's own env vars. `datasources`
  maps each Lasso-side `-database='...'` alias to which backend it lives
  on. A `mysql`-typed entry's `schema` names the real MySQL schema (every
  MySQL alias shares the one `mysql` connection — real deployments'
  MySQL datasources are typically separate schemas on the same server,
  not separate servers; there's no per-alias host/port override). A
  `filemaker`-typed entry needs no `schema` at all: the alias itself IS
  the FileMaker database-file name (real Lasso's documented FileMaker
  connector model — see "FileMaker Datasource" below), and every
  FileMaker alias shares the one `filemaker` connection's user/password
  by default. Unlike MySQL, a `filemaker`-typed entry *can* override
  `host`/`port` (`fm_catalog_backup` above) — e.g. to point a second
  alias at a dev/backup FileMaker Server while still authenticating with
  the shared block's credentials, for testing that instance without a
  separate config file or process. There's no per-alias user/password
  override — only host/port; the point is testing against the same
  account on a different box, not a different account. One known,
  accepted gap: FileMaker container-field (image/file) URLs are still
  prefixed with the *shared* `filemaker` block's host/port regardless of
  which alias a record came from, so an override alias's container-field
  links would point at the wrong host — not a concern for connectivity
  testing, the use case this exists for.
  Datasource alias keys are case-insensitive (matching Lasso's own
  `-database=` matching) and share one namespace across both backends —
  two keys differing only by case, MySQL vs. MySQL, FileMaker vs.
  FileMaker, or MySQL vs. FileMaker, is a config error the server refuses
  to start with, not a silent collision. `sessionDatabase` (inside
  `mysql`) is a separate concern from `datasources`: it's the schema
  `LASSO_SESSION_DRIVER=mysql` stores session data in (falls back to
  `LASSO_MYSQL_DATABASE` when omitted) — session storage isn't itself an
  inline-queryable Lasso datasource, so it doesn't belong in the
  `datasources` map. **This file should be `chmod 600` and kept outside
  the git repo** — matches this project's established "credentials go in
  a permissioned file, never on the command line" practice.
  `LassoSiteServer` rejects any MySQL datasource name that doesn't
  resolve to a configured schema (`unknownDatasource`), so an unrecognized
  `-database=` alias in a page fails closed rather than querying an
  arbitrary same-named schema on the server; an unrecognized alias falls
  through to that same MySQL rejection path regardless of which backend
  it was meant for (see "FileMaker Datasource" below for the routing
  design).

  **Back-compat**: a config file written before FileMaker support — flat
  top-level `host`/`port`/`user`/`password`/`sessionDatabase`/
  `allowWrites`/`allowRawSQL` fields (read as the `mysql` block when no
  nested `mysql` key is present) and a `datasources` map of bare
  `"alias": "schemaName"` strings (read as `{type: "mysql", schema:
  "schemaName"}`) — still decodes and behaves identically to before.
- `LASSO_CRAWL_REPORT=1`: after the server starts listening, request every
  discovered page (recursively, skipping underscore-prefixed include-only
  files) over real HTTP, print a report grouped by the first unsupported
  construct, and exit — see the crawl/report mode implementation note
  below. `LASSO_CRAWL_REPORT_PATH` optionally writes the full per-page
  JSON results to a file.
- `LASSO_ADMIN_CONSOLE=1`: start `PerfectAdminConsole` alongside the main
  server — see "Admin Console" below. Off by default.
- `LASSO_ADMIN_PORT`: admin console port, default `8990`. Always bound to
  `127.0.0.1` only, regardless of what `LASSO_SERVER_PORT` is bound to.
- `LASSO_ADMIN_TOKEN_PATH`: where the generated bearer token is written
  (`chmod 600`). Defaults under `NSTemporaryDirectory()`.

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
  - **Live-verified against a real instance's startup folder** (10 files): 7
    now load cleanly with no errors (a site-setup include, a hash-test file,
    a cart-tag include, two browser/bot-detection tag files — see the
    bracket-comment fix below for why those two needed a real fix, not just
    verification — plus `paypal_express.inc` and `site_setup_tags.inc`, both
    unblocked by the expression-bodied-`define`/bare-tag-call/`with...do`
    work further below). The other 3 fail on distinct, cataloged legacy
    syntax deliberately deferred as a separate, larger follow-up (legacy
    `define_tag(...)` parenthesized-call style, legacy
    `define_type:`/`define_tag:` colon-call style) — see
    `Documentation/compatibility-matrix.md`'s startup-folder rows for the
    full list. None of these are bugs in the loading mechanism itself — each
    is a real, unimplemented syntax form, confirmed by reading the exact
    failing line in each file.
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
  - **`excludeBots` resolved.** Three tightly coupled gaps were closed in
    one pass — see `Documentation/compatibility-matrix.md`'s rows for each:
    top-level expression-bodied `define name => <expr>` (no braces, needed
    for `site_setup_tags.inc`'s `br`/`keywordMap`/`botMap` and
    `paypal_express.inc`'s six PayPal constants — the earlier of which was
    blocking every later `define` in each file, `excludeBots` included,
    since `RendererEngine.render` aborts a file's whole render on its first
    throwing statement); bare-identifier zero-arg custom tag calls (needed
    for `botMap` referenced with no parens inside `with bot in botMap do`,
    and for `pp_express`'s `data public returnURL = pp_return` default
    value); and `with x in y do { ... }` iteration itself (`excludeBots`'s
    own body, plus 3 more spots in `paypal_express.inc`'s checkout type).
    Implementing "with" also surfaced a real, unrelated gap in
    `BlockBuilder.swift`: its `blockNames` allowlist gates which *opening*
    tags get recursively paired with their close at all — a brand-new
    block-style keyword needs adding there too, not just teaching
    `ScriptBodyParser` to emit the open/close tag pair, which the original
    plan for this work had assumed wasn't necessary.
  - **`array(...)` was missing entirely.** Testing the fixes above against
    `define botMap => array(...)` surfaced a genuinely separate bug:
    `map(...)` was already a registered native (used for `keywordMap`), but
    `array(...)` — needed by the very same file, one `define` later — was
    never registered as a callable native at all. Added alongside `map` in
    `Runtime.swift`.
  - **CRLF line endings silently dropped block content — found live-verifying,
    not something this plan anticipated.** `site_setup_tags.inc` (like every
    real file in this startup folder) is CRLF-terminated. Swift's
    `Character` type treats `\r\n` as a single extended grapheme cluster
    that equals neither the standalone `\r` nor `\n` most of this parser's
    newline checks compare against — `skipLineRemainder()` in particular,
    called right after an arrow-brace block's `{` opens, never recognized a
    CRLF as the newline it was scanning for, so it silently consumed
    everything up to the next *lone* `\n` it could find: in practice, the
    rest of the block's body and its own closing brace. A minimal
    reproduction (`if(true) => {\r\n\t$x = 1\r\n}\r\n`) reliably triggered
    "Unclosed if block" with an empty body even outside any real file.
    Fixed at the single earliest entry point, `TemplateScanner.init` —
    normalizing `\r\n`/`\r` to `\n` there means every downstream parser
    (`ScriptBodyParser`, `TypeBodyParser`, `ExpressionParser`) operates on
    already-normalized substrings with no changes needed anywhere else.
    This was a real, pre-existing bug (not introduced by this pass's other
    changes) that had simply never been exercised before, since every
    existing fixture and test used LF-only content.
  - **Live-verified end to end**: `excludeBots` now registers, is called
    (via `/api.lasso`), and runs its full `with bot in botMap do { ... }`
    loop — confirmed by watching the error change from
    `unknownFunction("excludeBots")` to a distinctly different, deeper gap:
    `unsupportedExpression("Member httpHost")`, from `botRedirect`'s
    `web_request->httpHost` (called from *inside* `excludeBots`'s own
    body, reached only after the `with` loop actually iterates and matches
    a bot).
  - **`web_request->httpHost` implemented, 2026-07-09.** Real Lasso's
    `httpHost` is just the request's `Host` HTTP header — no new provider
    protocol needed, `LassoRequestProvider.header(named:)` already exists
    and is already case-insensitive in every concrete implementation
    (`ServerRequestProvider` in this file, and the test fixtures). One new
    case in `Evaluator.nativeMember`:
    `("web_request", "httphost") -> header(named: "Host")`. Verified via a
    dedicated test reproducing the real `botRedirect`/`excludeBots` shape
    end to end (bot match → redirect URL built from the request's real
    host), not just that the member access itself resolves.
  - **`web_request`/`web_response` comprehensively implemented, native
    types unified with the object system, 2026-07-09.** Implementing
    `httpHost` (above) surfaced a much bigger gap: real Lasso documents
    ~35 `web_request` members and ~20 `web_response` members; this
    interpreter had 5 and 1 (a no-op stub). Before implementing more
    one-at-a-time, a research spike (two independent deep-dive passes —
    Lasso 8/9's actual language semantics, and this codebase's dispatch
    architecture) established why: real Lasso is a genuine
    object-oriented language whose own engine registers `web_request`
    through the *same* mechanism user-defined types use — there's no
    architectural native/user split, only a historical one in vocabulary.
    Two semantics that mattered directly: no property/method distinction
    (`web_request->httpHost` and `->httpHost()` are the same zero-arg
    dispatch, Ruby-like), and `-name=value` keyword params are a
    first-class calling convention, not sugar.

    Tracing this codebase's actual dispatch found the root cause: before
    this, `web_request` wasn't modeled as an object at all — a hardcoded
    `Evaluator.nativeMember` string-switch intercepted any bare-identifier
    receiver *before it was ever evaluated*, precisely because evaluating
    "web_request" as a real identifier yielded `.null`. `local(r) =
    web_request; #r->param('x')` silently broke as a result. Fixed by
    minting native receivers as real `.object(LassoObjectInstance)`
    values (same carrier user-defined types use) backed by a new
    `LassoNativeTypeRegistry`/`LassoNativeType`
    (`Sources/LassoParser/NativeTypes.swift`) — a flat name→Swift-closure
    method table per native type (deliberately *not*
    `LassoMethodDefinition`/`LassoMethodDispatcher`, which are Lasso-AST-
    bodied and arity-scored — real overkill for name-unique native
    builtins), checked in the same `.object` dispatch arm
    `invokeMemberMethod` already uses for user types. `nativeMember` is
    gone entirely.

    Implemented ~24 of ~35 `web_request` members and ~12 of ~20
    `web_response` members — see `Documentation/compatibility-matrix.md`
    for the full tiered list (implemented vs. explicitly deferred, each
    with a concrete reason: no POST body reading yet, no binary streaming
    response infrastructure, no server-lifecycle hook registration, etc.
    — nothing silently missing without explanation).

    **A second, more serious pre-existing bug found verifying the
    response side:** `main.swift`'s `render(...)` constructed
    `ServerResponseSink()` inline with no local variable holding a
    reference to it, then never read its collected `status`/
    `redirectURL`/cookies back after rendering — meaning the
    *already-existing* native functions `redirect_url`, `response_status`,
    and `cookie_set` were silently non-functional in the real server,
    not just the new `web_response` members. Fixed as part of this pass:
    `render(...)` keeps a local `sink` reference and assembles the real
    `HTTPHead`/`BytesOutput`/`RedirectOutput` from its collected state
    after rendering completes.

    47 Swift Testing cases pass (up from 41), including a dedicated
    regression proving native receivers are now real assignable values
    (the specific gap that motivated the redesign) and a full-suite
    re-run confirming the `.member` dispatch collapse didn't regress
    `.string`/`.array`/`.map`/`.object` access.
  - **Live-verified again after the fix**: the real corpus no longer
    throws on `httpHost` anywhere — 7 of 10 real startup files still load
    cleanly (unchanged; the 3 legacy-dialect failures are unrelated to
    this pass). The error on `/api.lasso` moved to a distinctly different,
    deeper gap: `unsupportedExpression("Member contains")`. Investigated
    precisely rather than assumed: confirmed *not* caused by the
    native-type work (identical error before and after this pass's
    changes) and *not* `.array`/`.map` missing a `.contains` method (no
    evidence of that shape anywhere in the traced corpus). Grep across
    the real site found the likely site: `_begin.lasso:66`'s one live
    (non-commented — most of that file is `/* ... */`-wrapped historical
    code, correctly skipped) statement,
    `excludeBots(web_request->header('USER-AGENT'), web_request->httpHost)`,
    whose body (`site_setup_tags.inc:99`) does `#request->contains(#bot)`
    — the exact same pattern this pass's own
    `excludeBotsFullRealShapeRedirectsUsingWebRequestHttpHost` test
    proves works correctly with a real `.string` receiver. Why the header
    value isn't behaving as a `.string` in this specific live-request
    context is unresolved — genuinely needs its own focused debugging
    pass, not something to guess at or silently absorb into this one.

The parser/runtime source and its smoke suite (`Sources/LassoParserSmoke`,
`Tests/LassoParserTests`) never hardcode a real site path or real page
content. Real-corpus verification of this kind is opt-in via
`LASSO_SMOKE_REAL_PAGE_PATH`/`LASSO_SMOKE_REAL_SITE_ROOT` (template pages) and
`LASSO_SMOKE_REAL_API_PAGE_PATH` (script-mode pages) on `LassoParserSmoke`, or
by pointing `lasso-perfect-server` itself at a real `LASSO_SITE_ROOT` locally.

## Native-type resolved: `library()` was caching at the wrong scope

Chasing the `->contains` gap above led to the real question: what is
`_begin.lasso`, mechanically, and does the interpreter treat it the way
real Lasso does? Checking confirmed `_begin.lasso` is **not** a Lasso
built-in convention at all — it isn't in the real instance's `LassoStartup`
folder, and there's no `define_atBegin` wrapping anywhere in it. It's a
plain site file that every real top-level page calls by hand as literally
its first line: `library('/_begin.lasso')`. So whether its logic "runs before every
request" is governed entirely by what `library()` itself does — worth
checking against LassoSoft's own documentation rather than assuming.

LassoSoft's `library_once`/`[Library_Once]` docs are explicit: "if used
multiple times referencing the **same Lasso page** then only the first...
will actually perform the include" — the dedup is scoped to a single
page's own render, not the server process's lifetime. This interpreter got
that scope wrong: `loadedLibraries` lived on the shared, process-wide
`LassoTagRegistry` (the code even said so — "One registry for the life of
this server process... `library()` caching... shared across every
request"). That meant any top-level executable code inside a `library()`'d
file — like `_begin.lasso:66`'s live `excludeBots(...)` call — only ever
ran once, ever, for the whole server process; every subsequent request
silently no-opped. Fixed by moving `loadedLibraries` onto `LassoContext`
(fresh per request, per `TagRegistry.swift`/`Runtime.swift`/`Renderer.swift`),
while tag/type *definitions* stay on the shared `tagRegistry` as before —
those genuinely are meant to persist process-wide. This is the most likely
real explanation for the original `->contains` symptom: whatever
`web_request->header('USER-AGENT')` evaluated to on the one first-ever
request got permanently baked in.

Verified via a rewritten, more precise unit test
(`libraryDedupesWithinOneRenderButReloadsPerIndependentContext`) proving
both halves at once: two `library()` calls to the same path *within one
render* still dedup to a single load (matching the real "same page" scope),
while two independent contexts (simulating separate requests) sharing the
same registry each reload and re-run the library's top-level code fresh.
47/47 tests pass.

Live end-to-end HTTP re-verification against the real corpus turned out to
be blocked by two further gaps, both previously masked by the very caching
bug just fixed (since before this fix, almost no request ever actually
reached this deep into `_begin.lasso`'s real dependency chain):

- Lasso 8's `condition ? whenTrue | whenFalse` ternary operator, used both
  inside one of `_begin.lasso`'s own component dependencies and
  independently across nearly every top-level page. Fixed (value form only — a bare
  `condition ? statement` guard form with no `|` branch, seen in
  `Auto_Record.inc`/`mini_cart_tag.inc`, is a separate dialect, not
  implemented) since it was small, single-purpose, and blocked literally
  every page identically.
- `X->member(...)` on a `.null` receiver (e.g. `action_param('template')
  ->size` when no such request param is present) — `Evaluator.member` had
  no case for `.null` at all, so any member call on a missing value threw,
  rather than behaving permissively the way real Lasso does.

## Resolved: `void` vs `null` member dispatch

Checked Lasso 8/9 documentation directly for this one rather than picking
a design by feel, since Tim suspected — correctly — that Lasso 9 has
genuinely stricter null handling than Lasso 8, alongside some path that
still supports the older, looser behavior.

Confirmed: `null` really is strict in Lasso 9, on purpose. It's the root
of the whole type hierarchy, and member-dispatch failure only degrades
gracefully if the type defines `_unknowntag` — "if `_unknowntag` is not
included in the type, an error will result that may terminate
processing." LassoSoft's own 8.5→9 migration notes independently confirm
this was a deliberate tightening: code that treated null and empty-string
as interchangeable in Lasso 8 only matches empty-string in Lasso 9.

But the resolving detail: lookup-miss methods like `web_request->param()`/
`action_param()`/header/cookie don't return `null` in real Lasso at all —
LassoGuide's docs state plainly "if no argument matches, a `void` value is
returned." `void` is its own distinct built-in type, separate from `null`.
This interpreter had every param/header/cookie "not found" fallback
returning `.null` (11 call sites across `NativeTypes.swift`/
`Runtime.swift`/`main.swift`), which was itself wrong regardless of the
dispatch question.

**Fix**: those 11 sites now return `.void`. `Evaluator.member` treats
`.void` as an empty string for any member access — delegates straight to
the existing `.string("")` dispatch, so `->size` → 0, `->contains(...)` →
false, etc. — matching how `.void` already behaved for truthiness (`false`)
and string output (`""`) elsewhere in this runtime. `.null` itself is
untouched and stays fully strict; a regression test confirms `null->
bogusMember` still throws. Also fixed a related latent bug: the parser
previously mapped the literal `void` keyword to the same `.null` AST node
as `null` (harmless before this distinction existed, wrong now) — `void`
now parses to its own `.void` node.

This cleanly maps onto the split Tim was after: strict `null` matches
Lasso 9's real, deliberately-tightened behavior; permissive `void` is
where Lasso 8-style looseness legitimately still lives, because that's
the sentinel Lasso 9 itself chose for "didn't find it."

**Live-verified end to end against the real corpus** (previously blocked
by this gap): a normal/bot/normal/bot/normal user-agent sequence against a
real top-level page correctly alternates `200/200/200/302/200` — the
bot-exclusion redirect fires exactly on the request with a matching UA,
not stuck from an earlier request, not silently disabled. A sweep of the
real site's top-level pages shows the large majority now rendering
cleanly end to end (0 did before this whole investigation began); the
remaining failures are unrelated (missing include files on disk, a
distinct legacy `if` dialect gap, a path-boundary check, one unrelated
`unsupportedExpression("")`) — none connected to library scoping, the
ternary operator, or void/null dispatch. 48/48 tests pass.

## Resolved: the three remaining real-page failures

Followed up on the 3 remaining real-corpus page failures cataloged above.
All three were real, root-caused, and fixed — grounded in direct
comparison against other real pages/templates in the same corpus, not
guesswork:

- **Colon-call `if:(condition);` control flow.**
  `ScriptBodyParser.parseBlockOpening()` required a block keyword
  (`if`/`loop`/`iterate`/...) to be immediately followed by `(` — Lasso
  8's colon-call convention (`if:(condition); ... else; ... /if;`) put a
  `:` there instead, so the guard declined to treat it as control flow at
  all. It fell through to being parsed as an ordinary colon-call
  expression statement (`if` treated as a bare function name), throwing
  `unknownFunction("if")` at evaluation. Fixed by accepting an optional
  `:` immediately before the `(`.
- **A relative `include()`/`library()` path resolved against the real
  filesystem root instead of the site root.** `LassoFileSystemIncludeLoader
  .loadInclude` stores `includingPath` verbatim — and real Lasso source
  overwhelmingly uses the leading-slash, site-root-relative style
  (`include('/includes/b2b/whatever.inc')`). `URL(fileURLWithPath:
  relativeTo:)` treats any string starting with `/` as a literal
  filesystem-absolute path and silently ignores `relativeTo`, so an
  un-stripped leading slash resolved the parent directory against the
  real filesystem root instead of the site root — every subsequent
  relative `include()` from inside that file then failed
  `pathOutsideRoot`. Fixed by stripping the leading slash from
  `includingPath` before use, matching the normalization already applied
  to `path` itself.
- **Real Lasso 8's `[Cache(-Name=..., -Expires=...)]` output-caching tag**
  wasn't recognized at all (`unknownFunction`). This interpreter has no
  output-caching layer — every render is already computed fresh — so the
  opening call is registered as a no-op native; the wrapped body still
  renders normally, matching real semantics minus the memoization. The
  matching `[/Cache]` needed no handling of its own — already covered by
  the existing generic legacy-closing-tag support.
- **`[noprocess]`/`[no_process]` — real Lasso's raw-content escape hatch —
  was never implemented at all.** The actual crash (`unsupportedExpression
  ("")`) traced to a real template's *unwrapped* embedded JavaScript:
  `[j++]` inside `<script>` content got scanned as an ordinary Lasso
  bracket tag (every `[...]` is, regardless of surrounding context), and
  `++` isn't a valid Lasso operator, so the expression parser hit EOF
  mid-token, producing an unrecoverable `.unknown("")` node. Checking the
  real corpus (Tim's direction, rather than guessing at a fallback
  behavior) showed `[noprocess]` already correctly wrapping equivalent JS
  in ~10 other real templates — confirming the crashing page was simply
  missing a wrapper other pages already use correctly, and that the real,
  correct fix was implementing the actual Lasso mechanism, not inventing
  speculative "malformed expression" recovery behavior. Implemented in
  `TemplateScanner`: content between `[noprocess]` and `[/noprocess]` is
  now emitted as verbatim text, never scanned for nested `<?lasso ?>`/
  `[ ]` constructs. The one real page still missing its wrapper continues
  to fail — correctly, since that's real content, not an interpreter gap
  — but every page that already uses `[noprocess]` properly now renders.

Corpus sweep after all three fixes: 13 of 17 real pages now render
cleanly end to end (up from 12 after the previous pass, 0 before this
whole investigation began). Of the 4 remaining failures: 2 need a real
database connection this quick verification run doesn't have
(`inlineNotConfigured` — expected, not a bug), 2 are missing include
files on this local checkout, and 1 is the confirmed missing-`[noprocess]`
site-content gap above. 52/52 tests pass.

## Planning docs + architect review, then error/protect model — 2026-07-10

Tim had another dev agent research and write five forward-looking planning
docs while this session's parser work was ongoing: `post-body-support-plan.md`,
`session-upload-support-plan.md`, `inline-write-raw-sql-plan.md`,
`error-protect-model-plan.md`, `legacy-define-tag-type-plan.md` — plus a new
`References/Lasso/` folder with a local copy of the Lasso 8.5 Language Guide
PDF and Lasso 9 LP9Docs text files, so future sessions don't depend on
increasingly-dead lassosoft.com mirrors. Per Tim's direction, ran a
`feature-dev:code-architect` review of all five plans against the actual
current codebase (not just the plans' own descriptions) before implementing
anything. Real findings, not a rubber stamp:

- The plans' *chronological* creation order isn't the right *implementation*
  order. `error-protect-model-plan` (written last) has zero dependencies and
  is the prerequisite `inline-write-raw-sql-plan`'s write/error paths need to
  avoid being built wrong and rewritten later.
- `post-body-support-plan`'s multipart/upload work and
  `session-upload-support-plan`'s upload milestone are the same slice of work
  described twice — the session/upload plan has the correct analysis (a real
  `MimeReader`/`BodySpec` temp-file-lifetime bug the other plan misses
  entirely). Session-upload-support owns uploads; post-body's multipart phase
  is superseded.
- `post-body-support-plan` proposed hand-writing a new form-urlencoded parser
  that duplicates Perfect-NIO's existing `QueryDecoder` outright.
- `legacy-define-tag-type-plan` cited a corpus path that doesn't exist on
  this machine — corrected to the real `LassoStartup` path this project's
  other sessions have used for live verification (see the `lasso-real-
  corpus-paths` project memory).
- Both plans that said they were blocked on missing Lasso 8.5 documentation
  are less blocked than they thought — the Language Guide PDF is now sitting
  locally in `References/Lasso/`; the blocker is page extraction, not finding
  the source.

Confirmed real implementation order: `error-protect-model-plan` →
`post-body-support-plan` Phase 1 (corrected) → `session-upload-support-plan`
Milestone 1 (uploads) → `inline-write-raw-sql-plan` →
`session-upload-support-plan` Milestones 2-4 (sessions, last — depends on the
error/transaction model from the others). `legacy-define-tag-type-plan` is
orthogonal parser work, runs in parallel, blocks nothing.

**Implemented `error-protect-model-plan`'s Milestones 1-3 and 6** (the
architect's "ready now" slice): `LassoErrorState`/`LassoRecoverableError`,
`LassoContext.currentError`/`lastError`, `LassoInlineFrame.error` (wired
through `pushInlineFrame`), and `protect` genuinely catching only
`LassoRecoverableError` — `return`/`abort` and fatal `LassoRuntimeError`s
pass through untouched. `error_currentError` (message / `-errorCode`)
implemented. Real database-failure integration and the full Lasso 8.5
error-code list are deferred to the `inline-write-raw-sql-plan` pass, per the
architect's dependency analysis. 55/55 tests pass.

**Implemented `post-body-support-plan`'s Phase 1**, corrected per the
architect review to consume Perfect-NIO's own `QueryDecoder` rather than
hand-rolling a form-urlencoded parser. Found and fixed a real prerequisite
gap the plan didn't even mention: the server only ever registered `.GET`
routes — no POST request could reach `handle` at all before this. Added
`.POST` routes mirroring the existing `.GET` ones; `handle` now reads/parses
the body asynchronously (`readPostBody`, using `HTTPRequest.readContent()`)
before the still-synchronous `LassoRenderer` runs, keeping async I/O
entirely at the boundary as the plan specified. New `LassoRequestPair`
ordered/duplicate-preserving pair model; `ServerRequestProvider` now builds
real `queryPairs`/`postPairs` (POST-then-GET combined for `parameter(named:)`/
`param(name)`, kept separate for `queryParam`/`postParam`).
`postParam`/`postParams`/`postString`/`param(name, joiner)`/`params()` are
real now, plus the Lasso 8 `client_*`/`form_param` aliases. Fixed a real
pre-existing bug as a byproduct: GET query parsing used `URLComponents`,
which doesn't treat `+` as space in query strings — switched to
`QueryDecoder` for GET too, which does. Live-verified end to end against a
real POST request: `+`-decoding, POST-before-GET combined ordering,
GET-only `queryParam` staying uncontaminated by POST data even when both
are present, and duplicate-name joining via `param(name, ',')`/
`param(name, void)` all confirmed correct over real HTTP. Corpus sweep
unchanged at 13/17 (no regression). 56/56 tests pass.

**Implemented `session-upload-support-plan`'s Milestone 1** (uploads,
absorbing `post-body-support-plan`'s deferred multipart phase per the
architect's overlap finding). Perfect-NIO's `MimeReader` does the actual
parsing; `readPostBody` separates its `BodySpec`s into ordinary `postPairs`
(non-file fields) and `LassoUploadedFile` metadata (file fields), matching
the exact `spec.file != nil` / empty-placeholder-filtering convention
Perfect-NIO's own `RequestDecoder.decode(_:content:)` already uses. The
plan's flagged risk was real and correctly handled: `MimeReader`/`BodySpec`
delete their temp files on `deinit`, so a naive implementation would have
the file vanish before Lasso code could read it — the reader is now
retained (`RetainedMimeReader`, a small `@unchecked Sendable` wrapper) for
the whole synchronous render, not just the async body-read step.
`web_request->fileUploads()` and Lasso 8's `[file_uploads]` both
implemented, projecting the same metadata under each dialect's own key
names. Live-verified with a real `curl -F` multipart upload: a regular
field parsed correctly, upload metadata (filename/content-type/size)
correct, and the file's `tmpfilename` path was genuinely still readable by
Lasso code during render — proving the retention fix actually matters, not
just filling in stub values. `[File_ProcessUploads]` (moving files)
deliberately deferred — this pass is metadata only. Corpus sweep unchanged
at 13/17. 57/57 tests pass.

**Implemented `inline-write-raw-sql-plan`** (all milestones), completing the
implementation order the architect review confirmed:
`error-protect-model-plan` → `post-body-support-plan` Phase 1 →
`session-upload-support-plan` Milestone 1 → `inline-write-raw-sql-plan`.
Widened PerfectCRUD's existing connector-agnostic dynamic-SQL layer
(`Dynamic.swift`: new `DynamicMutation`/`DynamicSQL`, `Database.mutate(_:)`/
`execute(_:)`) rather than adding MySQL-specific code — the `Database:
DynamicDatabaseProtocol` extension already generalizes over any
`SQLGenDelegate`/`SQLExeDelegate` connector, so this covers every connector
at once. Added `SQLExeDelegate.affectedRowCount()`/`lastInsertedID()`
(default-implemented `0`/`nil`, so existing conformers keep compiling;
MySQL's `MySQLStmtExeDelegate` implements them for real via `MySQLStmt`'s
own `affectedRows()`/`insertId()`). `LassoInlineRequest` (`Providers.swift`)
gained a `fieldAssignments: [LassoInlineAssignment]`/`writeCriteria:
[LassoInlineCriterion]` split from the pre-existing `criteria` field — in
`-Add`/`-Update`, unlabeled name/value args are values to write, not search
predicates, even though they parse identically to `-Search` criteria.
`PerfectCRUDLassoExecutor` (`PerfectCRUDLassoExecutor.swift`) rewritten with
three handler closures (`queryHandler`/`mutationHandler`/`rawSQLHandler` —
`DynamicDatabaseProtocol` isn't existential-safe due to its associated type,
which ruled out a single "hand back a database" resolver) and a new
`LassoDatasourceCapabilities` per-datasource policy struct
(`allowsSelect`/`allowsInsert`/`allowsUpdate`/`allowsDelete`/
`allowsRawSQL`/`allowsMultipleStatements`/table allowlist/max rows;
defaults read-only). Capability denial returns a `LassoInlineFrame` with
non-default `LassoErrorState` (adapter-local `InlineErrorCode`s, 1001-1006)
rather than throwing — the first real (non-synthetic) producer of frame
error state since `error-protect-model-plan`'s Milestone 1-3 work, and
observable via `error_currentError` without needing `protect` at all, since
`pushInlineFrame` already surfaces it unconditionally. `-Add` best-effort
follows up with a SELECT-by-insert-id for the inserted row; `-Delete`
returns an empty found set (both matching documented Lasso behavior).
`lasso-perfect-server`'s MySQL executor wiring (`main.swift`) gained
`LASSO_MYSQL_ALLOW_WRITES`/`LASSO_MYSQL_ALLOW_RAW_SQL` env toggles, both
default off. Deferred, matching the plan's own stated allowances:
`-StatementOnly`'s true non-execution semantic (parsed, not yet acted on —
`Dynamic.swift` has no compile-without-executing capability),
`-Key`-array-based multi-record targeting (only `-KeyField`/`-KeyValue`
single-predicate targeting is implemented), and real Lasso 8.5 numeric
error codes (isolated behind `InlineErrorCode` pending PDF extraction).
Real database/connector-level failures (e.g. a constraint violation) still
propagate as thrown Swift errors rather than being converted to recoverable
frames — only capability *denial* produces a frame so far. Verified at the
unit-test level only (61/61 tests pass, four new: field-assignment/criteria
splitting, add/update/delete routing to the mutation handler, raw-SQL
routing, and default-deny capability behavior) — live verification against
a real MySQL datasource was intentionally skipped this pass rather than
pass live credentials through the session; see
`Documentation/inline-write-raw-sql-plan.md`'s Implementation Status note.
Real-corpus GET-request regression sweep re-run against all top-level
`.lasso` pages: no new failures — every failing page traces to a
pre-existing, already-documented gap (missing includes, missing builtins,
or the expected `inlineNotConfigured` with no live datasource wired into
the sweep); two pages previously failing on unrelated bugs now get further
and stop only at the expected `inlineNotConfigured`, and one page still hits
its previously-catalogued `unsupportedExpression("")` gap, unrelated to this
change.

**Implemented `session-upload-support-plan`'s Milestones 2-4** (the
`PerfectSessionCore` session bridge). New target `LassoPerfectSession`
bridges the synchronous evaluator to async `SessionDriver` storage:
`LassoSessionPreflight.scan(document)` walks the parsed AST for literal
`session_start(...)` calls before render runs; `PerfectBackedLassoSessionProvider`
does the real async create/resume (`prepare`) and save/destroy (`finalize`)
work around the still-synchronous `LassoRenderer.render` call, exposing
only already-loaded state through the (redesigned) `LassoSessionProvider`
protocol. `render(fileURL:request:includePath:postBody:)` in
`LassoPerfectServer/main.swift` is now `async` to host this. Real function
surface: `session_start`, `session_id`, `session_result`, `session_addVar`,
`session_removeVar`, `session_end`, `session_abort` — `LassoContext` gained
`trackedSessionVariables`/`suppressedSessionSaves`/`sessionStartResults`
and a `finalizeSessions()` hook the renderer calls once per render.
`MemorySessionDriver` by default; `LASSO_SESSION_DRIVER=mysql` wires
`MySQLSessionDriver` using the existing `LASSO_MYSQL_*` connection vars.
Tracker cookies (`_LassoSessionTracker_<name>`) are set/cleared through the
same `ServerResponseSink` that already handles `redirect_url`/`cookie_set`.

**Correction, grounded in real docs before implementing:** the interpreter's
pre-existing `session(name)` function and `session->value`/`get` native-type
members modeled an unnamed, single-bucket key/value store that doesn't match
Lasso's documented named-session contract (`session_start(name, ...)`,
`session_addVar(sessionName, varName)` registering a variable for
persistence rather than taking a value directly) — verified against
`lassoguide.com/operations/sessions.html` per the plan's own "Sources
Reviewed," not assumed. Removed the old shape and replaced it with the real
one; the two existing tests and one smoke-script line that exercised the
old (incorrect) behavior were rewritten to real semantics, not patched to
keep the old assertions passing. Verified: 65/65 unit tests pass (new
coverage: preflight-scan literal/dynamic cases, cross-request persistence
via `MemorySessionDriver`, `session_end`/`session_abort`/`session_removeVar`).
Real-corpus GET-request regression sweep re-run: identical to the
pre-session-work baseline (19 of 28 top-level pages render cleanly, same 9
failures for the same pre-existing, already-documented reasons) — no
regression from making `render` async or adding the per-request
`finalizeSessions()` hook. Live verification against a real MySQL session
driver was not performed this pass (no live datasource credentials
available in this session). Deferred: `-useLink`/`-useAuto` GET/POST
`-lassosession` fallback tracking (only `-id` then cookie lookup is wired),
`session_deleteExpired()`, and dynamically-computed `session_start`
names/flags (the preflight scanner only recognizes literal arguments —
documented in `LassoSessionPreflight`'s own doc comment).

**Implemented `legacy-define-tag-type-plan`** (parenthesized-call and
colon-call `Define_Tag`/`Define_Type`, all previously-blocking startup
files). Real Lasso 8.5 documentation for the full `[Define_Tag]`/
`[Define_Type]` parameter/flag surface was recovered from the local
`References/Lasso/Lasso 8.5 Language Guide.pdf` (Chapters 57-58) —
`brew install poppler` provided `pdftotext` in this environment, since no
CLI text extractor was otherwise available. The actual blocker was bigger
than the two openers' syntax: `LassoParser.swift`'s square-bracket
handling only gave full statement/block-aware parsing to bodies opening
with modern `define`, so any other multi-statement `[...]` body —
including these, which real startup files wrap their entire content in —
silently kept only its first statement. Fixed generally
(`bodyOpensWithLegacyDefinition`), then `define_tag`/`define_type` lower
into the exact same `LassoCustomTagDefinition`/`LassoTypeDefinition`/
`LassoMethodDefinition`/`LassoDataMemberDefinition` models modern `define`
already registers with (new `Sources/LassoParser/LegacyDefinitions.swift`)
— no second runtime path. Colon-call-with-no-parens (`Define_Tag: 'name',
-Required='x';`, distinct from `if:(...)`'s still-parenthesized colon
form) needed its own recognition in `ScriptBodyParser.emitStatement`.

Two real, load-bearing bugs surfaced and fixed along the way, not just
missing syntax: `(Local: 'name')`/`(Var: 'name')` — Lasso 8's documented
way to *read* a variable's current value — had never been implemented
(`Evaluator.declare` only handled the assignment call shape, silently
returning `.void` for a bare read; this blocks nearly every legacy Lasso 8
tag/type body, which reads locals this way throughout); and constructor
`params` (`Local('ip' = (Params->First ? Params->First | client_ip))`,
needed for the real `getGeoIPInfo.inc` shape) — `Evaluator.instantiate` now
binds a `params` local before evaluating data member defaults, and
`.array->First` (needed to read it) was added alongside `size`/`get`.

Verified via 4 new tests (69/69 total, no regressions) and full live
verification: **all 10 real `LassoStartup` files now load with zero
failures** (previously 3 failed with `unknownFunction("define_tag")`/
`unknownFunction("define_type")`). Real-corpus GET-request sweep unchanged
(19 of 28 top-level pages render cleanly, same 9 pre-existing failures for
the same reasons). Deferred, matching the plan's own scope boundaries:
`-Container`/`-Looping` (`Run_Children` container-tag calling convention —
a real chicken-and-egg problem, since `BlockBuilder` recognizes block
keywords at parse time while custom-tag registration happens at render
time), `-Async`/`-Atomic`/`-RPC`/`-SOAP`/`-Priority`/`-Criteria` overload
dispatch, parent/base type name and `-Prototype` on `Define_Type` (parsed,
not acted on — no inheritance execution). A real dispatch nuance found but
left alone: a constructor called with more positional arguments than a
declared-zero-parameter `onCreate` silently skips `onCreate` entirely
(arity-aware dispatch, same scoring ordinary method calls use) rather than
passing extras through leniently the way real Lasso's docs describe — not
hit by any of the three priority corpus fixtures, so left as a documented
gap. See `Documentation/legacy-define-tag-type-plan.md`'s "Documented
Flags And Parameters" section for the full classification.

**Implemented a crawl/report mode** (`LASSO_CRAWL_REPORT=1`), replacing the
manual `curl`-in-a-loop sweeps used throughout this project's development
sessions with a repeatable, built-in tool (`Sources/LassoPerfectServer/
CrawlReport.swift`). Once the server starts listening, it recursively
discovers every renderable page under `LASSO_SITE_ROOT` (skipping
underscore-prefixed include-only files, the site's own convention),
requests each with an ordinary GET plus `Accept: application/json` (so
`developerErrorOutput` returns the first unsupported construct
structurally instead of the developer's HTML error page), prints a report
grouped by the *specific* construct (`unknownFunction("Output")`,
`unsupportedExpression("{")`, etc. — not the broad Swift error type, which
would lump dozens of distinct gaps into one `LassoRuntimeError` bucket),
and exits. `LASSO_CRAWL_REPORT_PATH` optionally writes the full per-page
JSON results to a file for diffing between runs. Redirects don't follow
(a dedicated `URLSessionTaskDelegate` returns `nil` from
`willPerformHTTPRedirection`) and count as clean, not a failure — a page
redirecting (e.g. the bot-exclusion flow) is a real, intentional Lasso
outcome, not a bug, and following it would either land on an unrelated
page's result or loop back into "too many redirects" for anything that
redirects toward itself.

First real run against the full real site (recursive — 1,989 pages, far
broader than any manual top-level-only sweep this project has done):
**1,666 of 1,989 (83.8%) render cleanly.** Two things worth calling out
from that run, not silently absorbed:
- `unknownFunction("Output")` is the single largest *genuine* gap (44
  pages) — `[Output]`/`Output(...)` (Chapter 14's "Table 1: Output Tags":
  applies default encoding to any expression, sub-tag, or member tag
  result) isn't implemented as a native at all yet. Not fixed this pass —
  flagged here as the crawl's actual first finding, exactly what this tool
  is for.
- The `unsupportedExpression("{")`/`unsupportedExpression("[")` buckets
  (45 and 40 pages) are mostly noise, not real Lasso gaps: third-party
  vendor JS library demo pages (`assets/vendor/.../index.html`) that
  happen to have a `.html` extension, which `LASSO_RENDER_EXTENSIONS`
  includes by default, so this interpreter tries to parse their raw
  JS/JSON as Lasso bracket syntax. The crawler discovers pages purely by
  file extension under the site root; it doesn't (yet) distinguish real
  Lasso content from vendored static assets that happen to share an
  extension. Worth refining (e.g. an exclude-path option) if this becomes
  the main sweep tool going forward, but not done this pass since it
  wasn't the ask.

**Implemented `output-tags-plan`** (`[Output]`/`Output(...)`, `Output_None`,
`HTML_Comment`, `Encode_Set`, and the full `Encode_*`/Lasso-9-string-method
encoding family). Grounded in both generations per direct request: the
local `References/Lasso/Lasso 8.5 Language Guide.pdf` (Chapters 14 and 17)
for the tag-style contract, and the online Lasso 9 reference
(lassoguide.com, fetched directly) confirming Lasso 9 exposes the
identical encoding keyword set through string instance methods
(`->encodeHtml`, etc.) rather than free tags. All transforms live once in
new `Sources/LassoParser/Encoding.swift`, reused by both the tag-style
natives and the existing `.string` member-dispatch cases — not two
implementations of the same thing. Real corpus usage was `grep`-counted
before implementing, not assumed: `-EncodeHTML` (35 sites), `-EncodeNone`
(28), `Encode_Smart` (22), several more with lower but real counts — every
keyword this pass implements has at least one real call site.
`Output_None` turned out far more load-bearing than `Output` itself:
dozens of real pages open with a bare `Output_None; ... /Output_None;`
wrapper around top-level variable setup, meaning those pages were failing
before ever reaching their real content.

Two real, separate bugs found and fixed along the way, not just missing
tags: the `[...]` square-bracket boundary scanner didn't account for
backslash-escaped quotes inside a string when hunting for the bracket's
closing `]` (`[Encode_SQL: 'it\'s']` — the scanner ended the string one
character early at the escaped quote, then misread the string's real
closing quote as *opening* a new one, losing track of the actual `]`;
`ExpressionParser.readString` already handled this correctly, the outer
bracket scanner had separate, more naive quote-tracking); and the
"route a multi-statement `[...]` body through `ScriptBodyParser`"
mechanism added for `legacy-define-tag-type-plan`'s `define_tag`/
`define_type` needed extending to the three new container keywords, plus
one more real shape it didn't yet cover: a keyword used completely bare
with no colon or parens, directly followed by `;` (`Output_None;` — the
"valid next character" check only allowed whitespace/`(`/`:`, not `;`).

Verified via 8 new tests (76/76 total, no regressions) and a live
real-corpus crawl (`LASSO_CRAWL_REPORT=1`): clean pages rose from 1,666 to
1,690 of 1,989, and `unknownFunction("Output")` no longer appears anywhere
in the failure report. The `inlineNotConfigured` bucket grew rather than
shrank — not a regression; several pages that previously failed on the
`Output` gap now progress further and correctly stop at the same
already-documented, expected "no live datasource wired into the sweep"
blocker. New gaps the deeper crawl surfaced once `Output` stopped masking
them: `unknownFunction("Date_Format")` (20 pages), `unknownFunction("Decode_Base64")`
(20 pages), `unknownFunction("inline")` (15 pages, a differently-shaped
usage from the already-supported `[Inline: ...]` block form) — added to
the backlog below, not fixed this pass.

**Investigated `-Container`/`-Looping` custom container tags** (Lasso 8) and
Lasso 9's `GivenBlock`/capture mechanism before planning any implementation,
per direct request to review documentation first. Reviewed both
generations: Lasso 8.5 Language Guide Chapter 57 "Custom Tags" (`[Tag]...
[/Tag]` container tags, `[Run_Children]`) and Chapter 22's upgrade notes;
Lasso 9's completely different `GivenBlock`/capture-based mechanism (not
`-Container`/`-Looping` at all — a genuinely different feature, found via
online search, not assumed to be the same thing under a new name). Then
`grep`-counted real corpus usage before committing to either dialect:
**zero** matches for `-Container`/`-Looping`/`Run_Children` anywhere in the
real site; the only `GivenBlock` usage (158 occurrences) is confined to a
vendored, dated (2013), third-party "DS Suite for Lasso 9" library folder,
not live application content. Surfaced this
finding rather than silently deciding either way; skipped in favor of a
corpus-validated item (`Date_Format`, below) — not implemented this pass.

**Implemented `date-format-plan`** (`Date`/`Date_Format`/
`Date_LocalToGMT`/`Date_GMTToLocal`/`Server_Date`, plus the Lasso 9
`date->format(...)` method) — the largest remaining real-corpus gap the
`Output`-tags crawl surfaced (`unknownFunction("Date_Format")`, 20 pages).
Grounded in both generations: the local Language Guide's Chapter 29 (Table
1 "Date Substitution Tags," Table 2 "Date Format Symbols") for the Lasso 8
tag-style contract, and the online Lasso 9 reference
(lassoguide.com/operations/date-duration.html, fetched directly) confirming
the identical `%`-symbol table is exposed via a `date->format(-format=...)`
method instead — same dual-dialect shape as the Output/Encoding pass.
Real corpus usage `grep`-counted before implementing: 13 of the ~20
documented `-Format` symbols actually appear (`%B %Y %Q %D %T %a %m %H %M
%S %r %w %d`); `Date_LocalToGMT`/`Server_Date` chain with `Date_Format` in
one real file.

**Design revised mid-plan per direct feedback.** The first `ExitPlanMode`
proposal hand-computed every `%`-symbol via raw `Calendar`/`DateComponents`
logic, deliberately avoiding both system `strftime` and `DateFormatter`.
Asked directly whether the renderer could instead be "based on the
standard DateFormatter with its extended and more detailed representation
without breaking normal lasso behavior" — revised to translate each
Lasso `%`-symbol into an ICU pattern letter (`%Y`→`"yyyy"`, `%B`→`"MMMM"`,
`%H`→`"HH"`, ...) and render every symbol through one reusable
`DateFormatter`. This is safe specifically because ICU's letter-repetition
pattern syntax shares no spelling with Lasso's own `%`-prefixed mini-
language — unlike reusing raw C `strftime` directly, which *would*
collide on spelling with different meaning (`%h` is 12-hour-hour in Lasso
but abbreviated-month in C `strftime`; `%w` is 1-7/Sunday-first in Lasso
vs. 0-6/Sunday-first in C; `%Q`/`%q`/`%G` aren't C `strftime` symbols at
all). Three symbols have no ICU equivalent and stay direct `Calendar`
computation: `%w` (Foundation's `.weekday` component already returns
exactly Lasso's own Sunday=1...Saturday=7 numbering, no translation
needed), `%W` (week of year), `%G` (GMT indicator, rendered as a fixed
`"GMT"` literal — lowest-confidence symbol in the table, no precise
corpus/doc example for either).

Represented as a native `"date"` object (`Sources/LassoParser/NativeTypes.swift`
— the same `LassoNativeType`/`LassoObjectInstance` mechanism `web_request`/
`web_response` already use), storing six wall-clock `.integer` fields
(year/month/day/hour/minute/second) rather than a `Foundation.Date` — a
raw `Date` conflates "an absolute instant" with "a time zone" in a way
that doesn't match Lasso's own wall-clock-oriented model (the actual
reason `Date_LocalToGMT`/`Date_GMTToLocal` exist as separate fixed-offset
shifts, not a real timezone reinterpretation). New
`Sources/LassoParser/DateFormatting.swift` (`LassoDateComponents`,
`LassoDateParsing`, `LassoDateFormatting`) holds the parsing/formatting
engine; `date`/`date_format`/`date_localtogmt`/`date_gmttolocal`/
`server_date` natives added to `Runtime.swift`; `date->format(...)` method
added to `NativeTypes.swift`, calling the exact same formatter the free
function uses — proven byte-for-byte identical in tests.

One real, non-obvious consequence of the native-object representation:
a bare `Date` identifier used with no call parens (`Date_Format(Date,
-Format='%D')`, the single most common real corpus shape) resolves
through the pre-existing "bare-identifier checks native types before
native functions" precedent (already established for `session`) to an
*empty* `"date"` object with no fields set. Rather than adding a special
case in the evaluator, both `LassoDateParsing.dateComponents(from:)` and
the `date->format` native method treat a missing/incomplete field set as
"now" — matching Lasso's own bare-`Date`-means-now semantics for free.

Verified via 10 new tests (86/86 total, no regressions) and a live
real-corpus crawl (`LASSO_CRAWL_REPORT=1`): `unknownFunction("Date_Format")`
no longer appears anywhere in the failure report; clean pages held steady
at 1,690 of 1,989 — not a regression, the same 20 pages now progress
further and stop at other, already-documented gaps (`Decode_Base64`,
`Select`, `Encrypt_HMAC`, `currency`), none of them newly introduced by
this pass.

**Implemented the `unknownFunction("inline")` fix** — item 4 of
`Documentation/outstanding-compatibility-project-plans.md`. That doc's own
plan speculated the gap was `inline(...)` used as a value-returning
expression; live corpus investigation (all 15 failing pages, pulled via
`LASSO_CRAWL_REPORT_PATH` JSON and grepped directly) showed a different,
more specific root cause: every failing page used Lasso 8's bare colon-call
block form (`inline: -database=..., -sql=...; ... /inline;`, no wrapping
parens at all), formatted one flag per line.

Two real, distinct bugs, both in `Sources/LassoParser/ScriptBodyParser.swift`:
`"inline"` was missing from `emitStatement`'s `bareBlockNames` set (the same
promotion mechanism `Output_None`/`define_tag` already use to turn a bare
colon-call into a real block-open node instead of an ordinary, unregistered
function call) — a one-line fix; and, once that was in place, a second,
deeper bug surfaced: `readStatement()` breaks a statement at the first bare
(unparenthesized) newline, which is correct for ordinary one-statement-
per-line code but truncated these real multi-line colon-calls down to just
`inline:` before ever reaching their arguments. `grep`-counting every line
ending inside the real `inline:`...`/inline;` blocks across all 15 files
found exactly three trailing characters that mark "more follows on the
next line" — a trailing `,` (comma-separated flags), a trailing `+`
(string concatenation spanning lines), and the block-opener's own trailing
`:` — and nothing else; fixed by continuing past a bare newline in exactly
those three cases.

14 of the 15 pages now clear `unknownFunction("inline")` entirely — 11 of
those land on the pre-existing, already-documented `inlineNotConfigured`
bucket (no live datasource wired into the sweep), which is why the overall
clean-page count held steady at 1,690/1,989 rather than rising. One file,
`components/inSite/filtered_links.inc`, still fails — for a third,
distinct, deliberately deferred reason: Lasso 8's operator-less
string/variable juxtaposition concatenation (`'text' #localVar 'more
text'`, no `+` between the pieces) inside an argument value, which
`ExpressionParser` doesn't fold into one expression. Flagged as a new,
separate backlog item — a test documents the current (still-unsupported)
behavior rather than leaving it a silent gap.

Verified via 5 new tests (98/98 total, no regressions) and the live
real-corpus crawl described above.

**Implemented `crawl-report-filtering-plan`** — item 9, next in the
outstanding-compatibility backlog's execution order. Quantified the
crawl's own noise directly from JSONs already on disk from the `inline`
fix verification, rather than assuming: 53% of all discovered pages (1,053
of 1,989) live under a `*/vendor/*` path, and 32% of then-failing pages
(95 of 299) were vendor pages hitting `unsupportedExpression`-family
errors on third-party JS/HTML demo syntax, not real interpreter gaps.
Found and reused a directly applicable precedent already in this repo:
`LassoSubsetCrawler.Scanner` (a separate, older, static-analysis tool)
already had both a path-exclude list and a marker-based
"does this .htm/.html file actually contain Lasso" check for its own
purposes — ported the same marker list rather than inventing new signals.

Added `LASSO_CRAWL_EXCLUDE_PATHS` (comma-separated path substrings,
e.g. `vendor`), a content heuristic for `.htm`/`.html` only
(`.lasso`/`.inc` behavior unchanged), two focused-rerun mechanisms
(`LASSO_CRAWL_PATH_LIST`; `LASSO_CRAWL_BASELINE` + `LASSO_CRAWL_ONLY_FAILURE`,
reusing the crawler's own JSON output as the baseline format), an offline
diff mode (`LASSO_CRAWL_DIFF_BASELINE`/`LASSO_CRAWL_DIFF_CURRENT`, needs
neither a site root nor a running server), and per-page `elapsedMS` plus
an excluded-page count in the report output.

Extracted the crawler's logic into its own new library target,
`LassoCrawlReport` (`Sources/LassoCrawlReport/CrawlReport.swift`), rather
than adding a test target that depends directly on the `LassoPerfectServer`
executable — that target's `main.swift` is genuine top-level-executing
code (not `@main`-based like `LassoSubsetCrawler`), so a test target
`@testable import`ing it risked executing real server-startup code
(port binding, env-driven config) as a side effect. Splitting the pure,
testable logic into its own library sidesteps the ambiguity rather than
relying on unverified assumptions about module-import semantics.

**One real, latent bug found and fixed while writing the first-ever unit
test for `discoverPaths`**: its relative-path computation
(`dropFirst(siteRoot.path.count)`) silently mis-sized whenever
`FileManager`'s enumerator resolved a symlink in the paths it returned
that the caller's `siteRoot` hadn't already been resolved through —
concretely, macOS's `/var` → `/private/var` firmlink, which
`resolvingSymlinksInPath()` doesn't reliably normalize either. This bug
already existed in the pre-existing code, just never triggered because
`main.swift` always pre-resolves the real site root before calling in;
a temp-directory unit test (which doesn't) exposed it immediately. Fixed
by switching to the path-relative `FileManager.enumerator(atPath:)`
overload, which returns already-relative paths and sidesteps the
absolute-path arithmetic entirely.

Verified via 10 new unit tests (no live server needed) and three live
passes against the real corpus: `LASSO_CRAWL_EXCLUDE_PATHS=vendor` dropped
the failing-page count from 299 to 204 — exactly the evidenced 95-page
reduction, with 1,114 pages correctly reported as excluded; the diff mode,
run against this session's own real before/after JSONs from the `inline`
fix, reproduced byte-for-byte the 14-page bucket change already found by
hand; the focused-rerun mechanism correctly crawled only the 14 pages
matching `Encrypt_HMAC` instead of the full site.

## FileMaker Datasource — 2026-07-14

Real Lasso 8.5 supports a second datasource connector type — FileMaker
Server, spoken to over classic XML Custom Web Publishing (`/fmi/xml/...`),
not the modern Data API (FileMaker Server 17+ only). This project's real
corpus has one FileMaker-backed datasource alongside its MySQL ones,
which previously failed with "no configured datasource" — this session
added a second, parallel backend rather than trying to make the MySQL
connector serve both.

### Real Lasso's FileMaker connector model

Confirmed against Lasso 8.5's own documentation (Ch. 11, "FileMaker
Queries"), not guessed from corpus inference:

- `-Database` names the whole FileMaker file; `-Table` names a *layout*
  within it, not a real SQL table.
- The key field is always FileMaker's internal record ID — real corpus
  confirms every `-KeyField` argument is passed as an empty string; only
  `-KeyValue` (the record ID) is ever meaningful for `-Update`/`-Delete`.
- Supported actions: `-Add`, `-Delete`, `-FindAll`, `-Search`, `-Update`.
  `-Duplicate`, `-Random`, `-Show`, and `-RX` (raw FileMaker search-symbol
  expressions) are documented but have zero real corpus evidence against
  this project's one FileMaker datasource — deliberately not implemented,
  not silently guessed at.
- Operators: `-BW` (begins-with) is the *default* when `-Op` is omitted —
  notably different from the MySQL connector's own `-EQ` (exact-match)
  default. `-CN`, `-EQ`, `-EW`, `-GT`, `-GTE`, `-LT`, `-LTE` are supported;
  there is no `-NEQ` — a bare `-Not` flag negates the entire compound
  query group that follows it instead (real corpus: two pages each use
  exactly one `-Not` to split a search into an un-negated group and a
  negated one).
- `-SQL` is explicitly documented as unsupported for FileMaker
  datasources — no raw-SQL analogue exists on this connector at all.

Two real, previously-unimplemented interpreter gaps were found and fixed
as prerequisites, independent of FileMaker specifically:
`LassoInlineRequest.criteriaGroups` (models `-Not` group negation;
`Providers.swift`) and the `keyfield_value` native tag (reads a row's
key value — for FileMaker, always the internal record ID — feeding
`-KeyValue=(KeyField_Value)` round-trips on every write flow).

### Executor design

`PerfectFileMakerLassoExecutor` (`Sources/LassoPerfectFileMaker/`) holds
no live `FileMakerServer` connection itself — it's parameterized by an
injected `queryHandler: @Sendable (FMPQuery, LassoFileMakerActionFailureKind,
String) throws -> FMPResultSet` closure, mirroring
`PerfectCRUDLassoExecutor`'s own `queryHandler`/`mutationHandler`/
`rawSQLHandler` convention exactly: the executor maps `LassoInlineRequest`
to a backend-specific query/error shape and back, while the real
backend connection is built once, at the composition root
(`LassoSiteServer.init` in `main.swift`), matching where MySQL's own
`Database<MySQLDatabaseConfiguration>` construction already lives. This
keeps the executor fully unit-testable with a fake handler — no live
server needed — and kept the blast radius of a later upstream API change
(see "Adapting to the resurrected Perfect-FileMaker" below) contained to
one closure in `main.swift`, not spread across the executor.

`LassoMultiBackendInlineProvider` (`Sources/LassoPerfectServer/MultiBackendInlineProvider.swift`)
routes each `[inline(...)]` call to the right backend by which alias set
its `-database=` value belongs to — a FileMaker-configured alias goes
straight to the FileMaker executor (no schema remapping: the alias name
IS the FileMaker database-file name), and everything else — including a
genuinely unconfigured alias — falls through to the MySQL provider,
whose own `unknownDatasource` rejection is the existing "is this alias
actually configured" security boundary. `LassoSiteServer.inlineProvider`
widened from the concrete `LassoDynamicInlineProvider` type to
`(any LassoInlineProvider)?` to hold either shape.

Deliberately deferred, flagged rather than silently resolved: `-RX`,
`-Duplicate`, `-Random`, `-Show`, portal/related-set (`FMPRecord.RecordItem
.relatedSet`) reads — zero real corpus evidence for any of them.
Container-field values map to a URL built from the configured
`host`/`port`/scheme prefixed onto the field's already-server-relative
`<data>` reference path — unverified against a real v16 server's exact
`<data>` shape until live-tested.

### Adapting to the resurrected Perfect-FileMaker

The local `Perfect-FileMaker`/`Perfect-XML` sibling forks (under
`~/Perfect-Resurrection/`) were modernized to this monorepo's current
Swift 6 standard shape mid-session: `FileMakerServer`'s blocking
`PerfectCURL`/libcurl transport became a genuinely `async`/`await`
`URLSession`-backed API, and its old percent-encoder (which never
escaped `& = ! ( ) * ;`) was replaced with a strict allow-list encoder,
fixing a real query-injection gap and a previously-silently-broken
`-GT`/`-LT`/`-GTE`/`-LTE` operator-encoding bug in the process.
`FMPQuery`'s public builder API was unchanged, so
`PerfectFileMakerLassoExecutor.swift` needed zero edits; only
`main.swift`'s `queryHandler` closure (the one place that actually calls
`FileMakerServer.query`) needed to change, confirming the closure-based
decoupling above was worth it.

That change surfaced a real, serious bug: the first async-to-sync bridge
attempt (`Task { } + DispatchSemaphore.wait()`, called inline from the
synchronous render pipeline) could deadlock the *entire* server, not
just FileMaker requests — every HTTP connection is handled by an
unstructured `Task` on Swift's fixed-size cooperative thread pool
(`Perfect-NIO`'s `Server.swift`), and the naive bridge blocked one
cooperative-pool thread while depending on a *second* cooperative-pool
thread to ever complete; enough concurrent requests exhausts the pool
outright. Fixed with two functions in `Sources/LassoPerfectServer/AsyncBridge.swift`:
`runBlockingOffCooperativePool` moves the *entire* synchronous render
(not just the FileMaker leaf call) onto a separate `libdispatch` queue
via a genuine `await`ed checked continuation — a real suspension point
that frees the cooperative-pool thread rather than blocking it — and
`runAsyncAndWait` (the actual async-to-sync bridge for
`FileMakerServer.query`) is only safe nested inside that wrapper. See
`Documentation/synchronous-render-pipeline.md` for the full design
rationale, including why this project's render pipeline stays
synchronous rather than becoming `async` end-to-end. Verified via a real
`Perfect-NIO` server bound to an ephemeral port with 50 concurrent real
HTTP requests (`Tests/LassoPerfectServerTests/LassoPerfectServerTests.swift`,
`realHTTPServerSurvivesConcurrentRequestsThroughTheBridgePattern`), not
just an in-process concurrency test — a prior fix attempt that looked
correct on paper passed narrower tests but still deadlocked under this
one, which is why the stronger test exists.

### Status

Implemented, code-reviewed (functional-correctness pass, a dedicated
security-focused pass, and an independent concurrency-correctness
verification pass after the deadlock fix above), and covered by unit
tests (executor request/response mapping, config decoding — including
full back-compat with the pre-FileMaker flat config shape,
`LassoMultiBackendInlineProvider` routing, the async bridge functions in
isolation and under real concurrent HTTP load).

**Live-verified against the real FileMaker Server** (2026-07-14, v16,
XML CWP, credentials supplied via the established `chmod 600` JSON
config file convention) using a new gated smoke executable
(`Sources/LassoFileMakerSmoke/`, `swift run lasso-filemaker-smoke`,
matching `LassoMySQLSmoke`'s existing pattern — `LASSO_FILEMAKER_TESTS=1`
plus `LASSO_FILEMAKER_HOST`/`_PORT`/`_USER`/`_PASSWORD`/`_DATASOURCE`/`_TABLE`).
A real `-FindAll` against the real corpus's FileMaker-backed alias and
layout returned a real found count (355 records) and correctly-mapped
`keyfield_value` for each returned record, with no error state —
confirming the full round trip end-to-end: config loading → executor →
`runAsyncAndWait` → real `FileMakerServer.query` → `LassoInlineFrame` →
`keyfield_value` native, against a real server, not a mock.

This also confirmed one of the security-review findings above is real
in practice, not just theoretical: the server logged `PerfectFileMaker:
sending credentials to http://<host>:80/... over plain HTTP (useTLS not
set and port != 443)` — this deployment's real FileMaker Server is on a
private-network address without TLS, so Basic-Auth credentials genuinely
transit in cleartext today. Flagged to the deployment owner; no code
change made without an explicit decision on whether that's an accepted
trade-off for this internal network or worth adding the missing `useTLS`
config override for.

**Not yet verified**: a real `-Add`/`-Update` write round trip (only a
read-only `-FindAll` has been live-tested; `allowWrites` was `false` for
this pass) and a `LASSO_CRAWL_REPORT=1` sweep with both datasources
configured to measure how many previously-`inlineNotConfigured` real
corpus pages now render cleanly.

## Admin Console — 2026-07-16

`PerfectAdminConsole` (a general-purpose, opt-in Perfect-NIO library
target — bound exclusively to `127.0.0.1`, bearer-token auth, CSRF on
mutating routes) is wired into `lasso-perfect-server` via
`LassoAdminDelegate` (`Sources/LassoPerfectServer/AdminConsoleIntegration.swift`).
Disabled by default; `LASSO_ADMIN_CONSOLE=1` starts it alongside the main
server as a background `Task`, matching the existing crawl-report-mode
pattern for "run something concurrently with the main serve loop without
blocking it."

What's wired in:

- **Status page**: server port/uptime, plus a "Lasso Site" section (site
  root, startup folder, render extensions, session driver, image proxy
  config if set).
- **Route inspector**: the actual five routes `LassoSiteServer.routes()`
  registers (`GET/POST /`, `GET/POST /**`, `GET /__lasso_health`) — a
  literal list, not introspected from `Routes<...>`, since Perfect-NIO's
  route tree isn't designed to be enumerated after construction. Keep
  this in sync by hand if `routes()` changes.
- **Datasource list + on-demand test**: every configured MySQL and
  FileMaker alias, sanitized (alias/schema/driver only, no credentials),
  with a real connectivity ping on demand (`Database(configuration:)`'s
  connect for MySQL, `FileMakerServer.databaseNames()` for FileMaker),
  latency reported in the toast. Both branches are `@concurrent`
  (SE-0461), matching `PerfectCRUDLassoExecutor.execute(_:)`'s own
  established pattern for keeping blocking/network work off whatever
  executor called in.
- **Live FileMaker datasource switching** (`GET /api/datasources`'
  `configs` field, `POST /api/datasources/switch`): each FileMaker alias
  lists every known connection profile — the shared `filemaker` config
  block (`id: "primary"`) plus one profile per alias carrying its own
  `host`/`port` override in the datasources file (see
  `ServerConfig.filemakerHostOverrides` under "Configuration" above) —
  with `isActive` marking the one currently in use. `switchDatasource`
  re-points an alias at any of those already-known profiles live, no
  restart, confirmed with a real connectivity probe
  (`FileMakerServer.databaseNames()`) before reporting success.
  Implementation: `FileMakerConnectionRegistry`
  (`Sources/LassoPerfectServer/FileMakerConnectionRegistry.swift`), an
  actor holding a fixed profile set (config-file-level, chmod-600
  protected — switching never introduces a new, unaudited host at
  runtime) plus a mutable "which profile is each alias using right now"
  map. Every FileMaker query resolves through this registry, so a switch
  takes effect on the very next request. MySQL aliases report an empty
  `configs` list — there's no equivalent per-alias override concept for
  that backend yet.
- **Crawl-report custom action** (`GET /api/actions`, `POST
  /api/actions` with `{"action":"crawl-report"}`): runs the full
  `CrawlReport.run(...)` sweep (see "Crawl Report" section below for the
  crawler itself) as a background `Task`, logging a start line, a
  finish summary (pages crawled/clean/failing/excluded), and writing
  the same JSON output file the `LASSO_CRAWL_REPORT=1` CLI mode
  produces, if `LASSO_CRAWL_REPORT_OUTPUT` is set. Deliberately does
  **not** reuse the CLI mode's own code path in `main.swift`, which
  wraps the crawl in a `Task { ... exit(0) }` — that `exit(0)` is a
  process-level exit that would kill the whole server (admin console
  included) the moment an admin-triggered crawl finished. This action
  calls `CrawlReport.run`/`CrawlReport.printAndWrite` directly, with no
  `exit()` anywhere in its path.
  - **Known limitation, not yet fixed**: page discovery is a filesystem
    walk (every on-disk template file, requested bare with no query
    string/session state), not a link-following crawl — it can't see
    pages only reachable through a dynamically generated link (e.g. a
    record-detail page keyed by `?id=123`). Treat a clean crawl-report
    run as "every statically discoverable page renders," not "the site
    works." See `Documentation/crawl-report-filtering-plan.md`'s "Known
    limitation" section for the full writeup.
  - **Live status on the action's chip**: `CrawlRunTracker`
    (`Sources/LassoPerfectServer/CrawlRunTracker.swift`), an actor the
    delegate holds, tracks whether a crawl is currently running, its
    live progress, and the last completed run's summary.
    `availableActions()` builds the `crawl-report` action's
    `description` fresh from the tracker on every call, so instead of a
    static blurb the dashboard shows "Running now — 340/1,989 pages,
    started 2m ago" while a crawl is in flight, or "Last run: 1,943
    page(s), 1,897 clean, 46 failing, 892 excluded (finished 11:04 AM)."
    once it's idle again. `AdminWebUI`'s dashboard re-fetches
    `/api/actions` on every periodic refresh (not just once at page
    load), so this updates live without a reload. `executeAction`
    rejects a second `crawl-report` trigger while one is already
    running (`CrawlRunTracker.tryBegin()` is atomic — actor
    serialization rules out two near-simultaneous `POST /api/actions`
    calls both starting a crawl) rather than letting two sweeps race
    against the same site. `CrawlReport.run` gained an optional
    `onProgress: (Int, Int) -> Void` callback (default `nil`, so the
    CLI mode and every existing caller/test is unaffected) that this
    action wires to `crawlTracker.progress(completed:total:)`.
- **Metrics** (`GET /api/metrics`): `AdminMetrics`, constructed
  alongside `LogCapture` whenever `LASSO_ADMIN_CONSOLE=1`, is fed from
  the single choke point every site-serving request passes through
  (`LassoSiteServer.handle(request:trailingPath:)`) —
  `recordRequest(route:)` on every request (route key
  `"METHOD:///path"`), `recordError()` on any thrown/developer-error
  response. The admin console's own routes (including the health check)
  aren't counted, only real site traffic.
- **Log tail** (`GET /api/logs`, `DELETE /api/logs`): `LogCapture`, fed
  from `logDatasourceActionFailure` (MySQL and FileMaker query/mutation
  failures) plus the admin-triggered crawl-report and datasource-switch
  actions' own start/finish/result lines. `logDatasourceActionFailure`
  itself stays a plain synchronous function — its callers are
  `PerfectCRUDLassoExecutor`'s synchronous `queryHandler`/
  `mutationHandler`/`rawSQLHandler` closures, which can't become `async`
  — and fires a background `Task { await logCapture.capture(...) }` for
  the actor-isolated write instead.

Tested: `Tests/LassoPerfectServerTests/LassoPerfectServerTests.swift`'s
`lassoAdminDelegate*` tests (config → `DatasourceInfo` mapping, status
section content, action listing/execution, unknown-datasource/unknown-
action failure paths) plus a dedicated `fileMakerConnectionRegistry*`
suite (default-to-primary resolution, per-alias override resolution,
profile listing with correct `isActive`, live `switchAlias` mutation,
unknown-alias/unknown-profile failure paths) — 253 tests passing across
the full suite, zero failures.

Live-verified against the real corpus server (`LASSO_ADMIN_CONSOLE=1`,
a real FileMaker primary alias plus its `192.168.1.157` backup
datasource): curled `/api/status`, `/api/routes`, `/api/datasources`
(both FileMaker aliases correctly listing both connection profiles
with accurate `isActive`); switched the primary FileMaker alias live
to its backup profile and back via `POST /api/datasources/switch`,
confirming both the returned `DatasourceTestResult` and the subsequent
`/api/datasources` snapshot reflected the change, and confirming the
switch is fully reversible; triggered the `crawl-report` action
against the real ~2,000-page corpus and confirmed via `/api/logs` that
(a) it logs a start line, real per-page datasource failures as they
happen, and (b) — the critical check, given the `exit(0)` gotcha this
action was deliberately designed around — both the site server and the
admin console stayed up and responsive throughout and after the crawl.
Confirmed `/api/metrics` accurately counts real site requests and
errors as they're served.

## Next Compatibility Work

1. Implement `[File_ProcessUploads]` (Lasso 8) and any equivalent move/copy
   helper for uploaded temp files — `web_request->fileUploads()`/
   `[file_uploads]` expose metadata (including the temp file's current
   path) but nothing yet lets Lasso code move an upload out of the
   short-lived temp location before the request ends and it's cleaned up.
   `MimeReader` wired in carefully (its `BodySpec` deletes temp upload
   files on `deinit`, so the reader/temp-file handles must be retained
   through render). See `Documentation/session-upload-support-plan.md`
   Milestone 1.
2. Implement `-Container`/`-Looping` custom container tags
   (`[Tag]...[/Tag]` with `[Run_Children]`) — deferred out of the legacy
   `define_tag`/`define_type` pass since it needs a different mechanism
   than `BlockBuilder`'s fixed parse-time keyword set (custom-tag
   registration happens at render time). Also: `-Priority`/`-Criteria`
   overload-chain dispatch, and `Define_Type`'s parent/base type name and
   `-Prototype` (parsed, not acted on — no inheritance execution yet).
   **Investigated and deliberately skipped**: zero real corpus usage of
   `-Container`/`-Looping`/`Run_Children` (Lasso 8) or `GivenBlock`
   (Lasso 9, and the only 158 real hits are confined to a vendored,
   dated, third-party library, not live content) — see the investigation
   note above. Revisit only if real corpus evidence appears.
3. ~~Bridge `web_response->include*`/`sendFile` with the existing
   `include()`/`library()` machinery (currently in `Renderer.swift`'s
   `renderExpression`, not reachable from the Evaluator-level native-type
   method tables) — deliberately deferred out of the comprehensive
   `web_response` pass as a separate integration.~~ Done — 2026-07-13, see
   `Documentation/web-response-include-plan.md`. `include`/`includeOnce`/
   `includeLibrary`/`includeLibraryOnce`/`includeBytes`/`includes` now
   live on `web_response`, backed by a new `LassoIncludeRenderService`
   protocol on `LassoContext` (the free `[include(...)]`/`[library(...)]`
   tags now delegate to the same service, byte-for-byte unchanged).
   `sendFile` (string data) and new `file_serve`/`file_stream` (path-based
   Lasso 8 natives) supersede normal page output via the existing
   `returnSignal` abort mechanism; the server boundary
   (`LassoSiteServer.render`) builds the HTTP response from a real
   `FileOutput` (full ETag/Range support) when no header override is
   requested, or a hand-assembled `BytesOutput` when one is. Zero real
   corpus usage of any of this — implemented against the documented
   contract and live-verified over real HTTP instead.
4. Continue the object runtime toward the next corpus need: likely
   `_unknowntag` (real Lasso 9's general per-type opt-in mechanism for
   graceful unknown-member dispatch — confirmed real and documented while
   researching the void/null fix above, still unimplemented here), rest
   parameters, or richer type/trait dispatch once a page actually
   exercises those constructs.
5. ~~Add a crawl/report mode that requests many site paths and records the
   first unsupported construct per page.~~ Done — `LASSO_CRAWL_REPORT=1`,
   see the implementation note above.
6. Real corpus pages still hitting distinct gaps as of the
   `inline-write-raw-sql-plan` sweep: one page hits
   `unsupportedExpression("")`. Two pages that previously hit
   `unknownFunction("if")` and `pathOutsideRoot` respectively now get
   further and stop only at `inlineNotConfigured` (expected — no live
   datasource wired into the quick sweep), so those two original gaps
   appear to already be resolved by other work in this session; not
   independently re-verified with a live datasource yet. Two more pages hit
   distinct missing built-ins (`unknownFunction`), and three pages hit
   `fileNotFound` on missing include files on this local checkout (not
   interpreter bugs).
7. ~~Implement `[Output]`/`Output(...)`~~ Done — see the `output-tags-plan`
   implementation note above.
8. ~~`unknownFunction("Date_Format")` (20 pages)~~ Done — see the
   `date-format-plan` implementation note above. `unknownFunction("Decode_Base64")`
   (20 pages) — real, common Lasso 8 tag, surfaced once `Output` stopped
   masking it in the crawl/report sweep. Not yet implemented.
9. ~~`unknownFunction("inline")` (15 pages)~~ Done — see the implementation
   note above. Real root cause was Lasso 8's bare colon-call block form
   (`inline: -database=..., -sql=...; ... /inline;`, no parens), not a
   value-returning expression as originally guessed; 14 of 15 pages fixed.
10. Lasso 8's operator-less string/variable juxtaposition concatenation
    (`'text' #localVar 'more text'`, no `+` between the pieces) inside an
    argument value — the one real remaining gap the `inline` fix surfaced
    (`components/inSite/filtered_links.inc`). `ExpressionParser`'s
    argument-value parser stops at the first complete sub-expression
    instead of folding the rest into the same argument. Scope/frequency
    elsewhere in the corpus not yet surveyed. Not yet implemented.
11. ~~`unknownFunction("Encrypt_HMAC")` (14 pages, password-reset token
    generation)~~ Done — 2026-07-13, see `outstanding-compatibility-project-plans.md`
    item 10. Surfaced a pre-existing, separate gap in `field()`'s
    request-parameter fallback (flagged there, not fixed this pass).
    ~~`unknownFunction("currency")` (10 pages) and `unknownFunction("percent")`
    (masked by an earlier gap)~~ Done — same date, same doc item —
    672/875 pages now render cleanly (up from 671).
    ~~`unknownFunction("Select")` (19 pages, a Lasso 8 switch-statement
    construct)~~ Done — same date, same doc item. Lowered into the
    existing `if`/`else` block representation at parse time — no new AST
    node, no `Renderer.swift` changes. 680/875 pages now render cleanly
    (up from 672).

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
unchanged at 13/17 (no regression). 56/56 tests pass. Multipart/file
uploads deferred to `session-upload-support-plan.md`'s upload milestone.

## Next Compatibility Work

1. Implement multipart/form-data and file uploads — `application/x-www-
   form-urlencoded` POST bodies are real now (see above), but
   `multipart/form-data` still returns empty; needs Perfect-NIO's
   `MimeReader` wired in carefully (its `BodySpec` deletes temp upload
   files on `deinit`, so the reader/temp-file handles must be retained
   through render). See `Documentation/session-upload-support-plan.md`
   Milestone 1.
2. Evaluate whether legacy `define_tag('name', -flags) ... /define_tag`
   (parenthesized-call style, blocks `_begin_tags.inc`'s `send_email2` and
   all of `getGeoIPInfo.inc`) and legacy `define_type:`/`define_tag:`
   colon-call style (blocks all of `js_timer.inc`) are worth real support,
   given real corpus frequency — both are now precisely characterized (see
   `Documentation/compatibility-matrix.md`) but neither is implemented;
   deliberately deferred as a separate, larger follow-up (each is
   effectively a second, Lasso-8-shaped type-definition sub-parser).
3. Bridge `web_response->include*`/`sendFile` with the existing
   `include()`/`library()` machinery (currently in `Renderer.swift`'s
   `renderExpression`, not reachable from the Evaluator-level native-type
   method tables) — deliberately deferred out of the comprehensive
   `web_response` pass as a separate integration.
4. Continue the object runtime toward the next corpus need: likely
   `_unknowntag` (real Lasso 9's general per-type opt-in mechanism for
   graceful unknown-member dispatch — confirmed real and documented while
   researching the void/null fix above, still unimplemented here), rest
   parameters, or richer type/trait dispatch once a page actually
   exercises those constructs.
5. Add a crawl/report mode that requests many site paths and records the first
   unsupported construct per page.
6. Real corpus pages still hitting distinct gaps after this pass: one page
   hits `unknownFunction("if")` (a different legacy dialect than the
   arrow-brace one already supported), another hits
   `unsupportedExpression("")`, and a third hits `pathOutsideRoot` on a
   relative include path (may be a real site-structure quirk, not
   necessarily an interpreter bug). Not yet investigated.

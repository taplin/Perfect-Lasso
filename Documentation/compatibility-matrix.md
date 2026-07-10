# Lasso Compatibility Matrix

Status values: `M1` parser milestone, `M2` runtime milestone, `DB` database
milestone, `Later`, `Research`, and `Unsupported`.

Corpus evidence is drawn from two internal production Lasso codebases used to
validate this matrix during development (one Lasso 8-heavy e-commerce corpus,
one Lasso 8-heavy multi-application corpus with a smaller Lasso 9 startup
library). Codebase names are intentionally omitted from this document; see
local project notes for the source mapping.

| Feature | Lasso 8 | Lasso 9 | Corpus evidence | Status |
| --- | --- | --- | --- | --- |
| HTML/template text | Yes | Yes | Universal | M1 |
| Square delimiters | Primary | Supported | Dominant in both corpora | M1 |
| `<?lasso ?>` / `<?= ?>` (block/control-flow support) | No | Yes | First corpus and its startup files | M1 parse, M2 execute — now shares `.lassoscript`'s block-aware parsing, including arrow-brace (`=> { ... }`) block closing, not just slash-closed (`/if`) |
| `[no_square_brackets]` | Yes | Yes | Documented compatibility | M1 |
| Strings, integers, decimals, booleans | Yes | Yes | Universal | M1 |
| `$global` variables | Primary | Compatibility | 26,000+ sightings | M1 |
| `#local` variables | Limited | Primary | Lasso 9 startup files | M1 |
| Colon calls (`field:'id'`) | Primary | Compatibility | Dominant in the second corpus | M1 |
| Parenthesized calls | Partial | Primary | First corpus and Lasso 9 files | M1 |
| Named parameters (`-sql=...`) | Yes | Yes | Heavy database use | M1 |
| Member dispatch (`->`) | Yes | Yes | Both corpora | M1 |
| Arithmetic/comparison/boolean operators | Yes | Yes | Both corpora | M1 |
| Legacy closing tags | Primary | Compatibility | 20,000+ sightings | M1 |
| `if`, `else`, loops | Yes | Yes | Heavy use | M1 parse, M2 execute |
| Assignments / `var` / `local` | Yes | Yes | Heavy use | M1 parse, M2 execute |
| `define name(params) => { ... }` custom tags | Different | Primary | Startup libraries | M2 implemented |
| `define Foo => type { ... }` object/type definitions | Different | Primary | Startup libraries, `api.lasso`-style pages | M2 first pass: data, methods, `onCreate`, `self`, object construction, basic multiple dispatch |
| `lasso_tagexists` / `tag_exists` | Yes | Yes | Startup-library guards | M2 implemented; checks native functions and shared custom-tag registry |
| `library(path)` | N/A | Primary | `_begin.lasso`-style startup files | M2 implemented, cached per server instance |
| Instance startup folder (`LassoStartup`, auto-loaded before any request) | Primary | Primary | A real instance's `LassoStartup` folder outside its site webroot | M2 implemented via `loadLassoStartupDirectory` + `LASSO_STARTUP_PATH`; 7 of 10 real files load cleanly, 3 hit distinct, cataloged legacy-syntax gaps — see `Documentation/lasso-perfect-server.md` |
| `[//lasso ... define name(...) => { ... } ...]` — a full custom tag wrapped in one bracket span, `//lasso` a plain leading comment | Primary | Primary | Real startup folder (two files downloaded from lassosoft.com/tagswap) | M2 implemented: `TemplateScanner.scanSquare()` now skips `//` and `/* ... */` comments (including quotes/`]` inside them) while finding the bracket's true close, and a bracket body that opens with `define` (after leading comments) routes through `ScriptBodyParser` instead of the single-expression path, which used to silently drop everything but the first parsed token |
| Legacy `define_tag('name', -flags) ... /define_tag` (parenthesized-call style) | Primary | No | Real startup folder (`_begin_tags.inc`'s `send_email2`, all of `getGeoIPInfo.inc`) | Unsupported — tracked follow-up, deliberately deferred (see `lasso-perfect-server.md`) |
| Legacy `define_type: 'name', 'base'; define_tag: 'name'; ... /define_tag; /define_type;` (colon-call style) | Primary | No | Real startup folder (all of `js_timer.inc`) | Unsupported — tracked follow-up, deliberately deferred |
| Top-level expression-bodied `define name => <expr>` (no braces, string/array/map literals) | Different | Primary | Real startup folder (`paypal_express.inc`'s constant tags, `site_setup_tags.inc`'s `br`/`keywordMap`/`botMap`) | M2 implemented — `ScriptBodyParser.parseDefineOpening()` falls back to reading the remainder as one statement (mirrors `TypeBodyParser.parseExpressionMethodBody`) instead of backing out when no `{` follows `=>` |
| Bare identifier resolves to a zero-arg custom tag call (e.g. `botMap` used with no parens) | Yes | Yes | Real startup folder (`with bot in botMap do`, `pp_express`'s `data public returnURL = pp_return` default value) | M2 implemented — `Evaluator.evaluate(_:)`'s `.identifier` case checks the tag registry (same slot natives are already checked in) before falling back to variable lookup |
| `with x in y do { ... }` iteration | No | Primary | Real startup folder (`excludeBots` itself; 3 more spots in `paypal_express.inc`'s checkout type) | M2 implemented — new `ScriptBodyParser.parseWithOpening()`/`readUntilKeyword(_:)`, new `Renderer.swift` `case "with":` mirroring `iterate`'s array/map iteration with a named binding instead of the fixed `loop_value` |
| `array(...)` literal constructor | Yes | Yes | Real startup folder (`define botMap => array(...)`) | M2 implemented — found missing while testing the fixes above; `map(...)` was already a native, `array(...)` was not. Added alongside it in `Runtime.swift` |
| CRLF (`\r\n`) line endings | N/A | N/A | Real startup folder (all Windows-authored `.inc` files) | M2 implemented, `TemplateScanner.init` — Swift's `Character` treats `\r\n` as one grapheme cluster that matches neither the standalone `\r` nor `\n` most newline checks compared against, so every CRLF-terminated file previously risked `skipLineRemainder()` silently swallowing an entire block body past its real closing brace. Normalized once at the earliest entry point (all downstream parsers operate on already-normalized substrings) |
| Native types unified with the object system (`web_request`, `web_response`, `session`) | Yes | Yes | Every real page touches `web_request`; found implementing `httpHost` | M2 implemented — a research spike (Lasso 8/9 language semantics + this codebase's dispatch architecture) confirmed real Lasso has no genuine native/user-type split; `web_request` etc. now evaluate to real `.object(LassoObjectInstance)` values (previously a hardcoded string-switch intercepted the bare identifier before it was ever evaluated, so e.g. `local(r) = web_request` silently broke). New `LassoNativeTypeRegistry`/`LassoNativeType` (`Sources/LassoParser/NativeTypes.swift`) backs native receivers with Swift-closure method tables, checked in the same `.object` dispatch arm user-defined types already use |
| `web_request` members | Yes | Yes | Real startup folder + `api.lasso` | M2 implemented, ~24 of ~35 documented members: `param(s)`, `header(s)`, `cookie(s)`, `httpHost`, `rawHeader`, `queryParam(s)`/`queryString`, `requestMethod`, `requestURI`, `path`, `isHttps`, `remoteAddr`/`remotePort`, `serverName`/`serverPort`, `contentType`/`contentLength`, plus the cheap header-name aliases (`httpAccept`, `httpUserAgent`, etc.). `postParam`/`postParams`/`postString` are wired but return empty — no POST body reading exists yet (tracked separately below). `fileUploads()` and CGI-era fields with no real meaning in a standalone Perfect-NIO server (`gatewayInterface`, `scriptFilename`, `serverAdmin`, `serverSoftware`, ...) are explicitly deferred, not silently missing |
| `web_response` members | Yes | Yes | Real startup folder (`botRedirect`) | M2 implemented, ~12 of ~20 documented members: `setStatus`/`getStatus`, `header`/`headers()`/`addHeader`/`replaceHeader`/`setHeaders` (real now — `replaceHeader` was a no-op stub before), `setCookie` (full `-domain`/`-expires`/`-path`/`-secure`/`-httponly` param set)/`cookies()`, `abort()` (rides the existing `return`-signal short-circuit, no new control-flow mechanism needed). `include*`/`sendFile`/`sendChunk`/`rawContent`/`addAtEnd`/`define_atBegin`/`define_atEnd` explicitly deferred — each needs infrastructure this pass doesn't touch (Renderer-level include bridging, binary streaming, server-lifecycle hooks) |
| Response pipeline actually applies status/redirect/headers/cookies to the HTTP response | Yes | Yes | `lasso-perfect-server`'s own response handling | M2 implemented — found while widening `web_response`: `main.swift`'s `render(...)` constructed `ServerResponseSink()` inline with no local reference, then never read its collected state back; the pre-existing native functions `redirect_url`/`response_status`/`cookie_set` were silently non-functional in the real server, not just the new members. Fixed by keeping a local `sink` reference and assembling the real `HTTPHead`/`BytesOutput`/`RedirectOutput` from it after rendering |
| `array(...)` literal constructor | Yes | Yes | Real startup folder (`define botMap => array(...)`) | M2 implemented — found missing while testing the fixes above; `map(...)` was already a native, `array(...)` was not. Added alongside it in `Runtime.swift` |
| CRLF (`\r\n`) line endings | N/A | N/A | Real startup folder (all Windows-authored `.inc` files) | M2 implemented, `TemplateScanner.init` — Swift's `Character` treats `\r\n` as one grapheme cluster that matches neither the standalone `\r` nor `\n` most newline checks compared against, so every CRLF-terminated file previously risked `skipLineRemainder()` silently swallowing an entire block body past its real closing brace. Normalized once at the earliest entry point (all downstream parsers operate on already-normalized substrings) |
| `X->contains(...)` on a non-`.string` receiver in the real `excludeBots`/`_begin.lasso` bot-exclusion flow | Partial | Partial | Real corpus, `/api.lasso` request flow | Unsupported in at least one live-request scenario — investigated (not caused by the native-type work: identical error before and after; not `.array`/`.map` missing `.contains`, no evidence of that shape in the traced corpus). Likely site: `_begin.lasso:66`'s live `excludeBots(web_request->header('USER-AGENT'), ...)` call → `site_setup_tags.inc:99`'s `#request->contains(#bot)` — the exact reason the header value isn't behaving as a `.string` in this live context is unresolved; a dedicated regression test proves the identical pattern works with a real `.string` receiver. Needs its own focused debugging session |
| Includes | Yes | Yes | 4,000+ sightings | M1 parse, M2 execute, reparse-skipped when unchanged |
| Custom/native tags | Yes | Yes | Site startup libraries | M2 implemented, shared across requests on one server instance |
| POST body reading | Yes | Yes | Real corpus form/checkout flows | Unsupported — this interpreter has never parsed POST bodies; `web_request->postParam`/`postParams`/`postString` are wired (return empty) but real POST body reading needs async content-reading in `ServerRequestProvider.init`, itself synchronous today. Tracked, not part of any pass so far |
| Request params, headers, cookies | Yes | Yes | Both corpora | M2 |
| Sessions and auth | Yes | Yes | First corpus | Later provider |
| `inline`, `records`, `field` | Yes | Yes | Core application behavior | DB |
| Structured find/search actions | Yes | Yes | Heavily represented in the first corpus | DB |
| Raw `-sql` | Yes | Yes | Nearly 10,000 sightings | DB |
| Types, traits, captures, query expressions | No/directly different | Yes | Documentation, sparse page use | Later |
| LassoApp packaging/admin UI | Yes | Yes | Deployment concern | Research |
| FileMaker native protocol emulation | Yes | Yes | Possible legacy dependency | Research |
| Binary Lasso modules/C extensions | Yes | Yes | Outside pure Swift goal | Unsupported |

## Milestone 1 Acceptance

- Every fixture lexes without losing source text or delimiter information.
- Lasso 8 and Lasso 9 calls normalize to shared expression nodes.
- AST nodes retain source ranges and original syntax dialect.
- Unsupported syntax produces diagnostics and recoverable unknown nodes.
- No fixture contains production credentials or personal data.

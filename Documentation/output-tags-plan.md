# Output Tags Plan

Last reviewed: July 12, 2026

## Implementation Status (2026-07-12)

Implemented. Grounded in both Lasso generations per the request: the local
`References/Lasso/Lasso 8.5 Language Guide.pdf` (Chapter 14 "Programming
Fundamentals," Table 1 "Output Tags"; Chapter 17 "Encoding," the full
"Encoding Formats" list) for the Lasso 8 tag-style contract, and the online
Lasso 9 reference (lassoguide.com, fetched directly) confirming Lasso 9
exposes the identical encoding keyword set through string instance methods
(`->encodeHtml`, `->encodeUrl`, etc.) rather than free tags — both
dialects share one set of encoding semantics, just two different calling
conventions.

Implemented: `[Output]`/`Output(...)` (applies an encoding to an
expression, default `-EncodeHTML`, overridable per-call or via an
enclosing `[Encode_Set]`); `Output_None`/`[Output_None] ... [/Output_None]`
(processes its body for side effects, suppresses the rendered text);
`[HTML_Comment] ... [/HTML_Comment]` (wraps rendered output in `<!-- -->`);
`[Encode_Set: -EncodeXxx] ... [/Encode_Set]` (changes the default encoding
for nested `Output` calls with no explicit keyword of their own); the full
standalone `Encode_*` tag family (`Encode_HTML` already existed;
`Encode_Smart`/`Encode_Break`/`Encode_XML`/`Encode_URL`/`Encode_StrictURL`/
`Encode_SQL`/`Encode_Base64` added); and the matching Lasso 9 string
methods (`->encodeSmart`/`->encodeBreak`/`->encodeXML`/`->encodeStrictURL`/
`->encodeSQL`/`->encodeBase64`, alongside the pre-existing
`->encodeHTML`/`->encodeURL`). All transforms live once in
`Sources/LassoParser/Encoding.swift` (`enum LassoEncoding`), reused by both
the tag-style natives and the string-member dispatch — not two
implementations of the same thing.

Real corpus usage (`grep`-counted directly, not assumed) confirmed scope
and priority: `-EncodeHTML` (35 sites), `-EncodeNone` (28), `Encode_Smart`
(22), `Encode_StrictURL`/`Encode_Set` (4 each), `Encode_HTML`/`Encode_Base64`
(2 each), `Encode_SQL`/`Encode_Break` (1 each) — every documented keyword
this pass implements has at least one real call site. `Output_None` itself
turned out to be used far more heavily than `Output` — dozens of real
pages open with a bare `Output_None; ... /Output_None;` wrapper around
top-level variable setup, meaning those pages were failing before this
pass ever reached their real content.

**Two real, separate bugs found and fixed along the way, not just missing
tags:**
- The `[...]` square-bracket boundary scanner (`LassoParser.swift`'s
  `scanSquare`) didn't account for backslash-escaped quotes inside a
  string when hunting for the bracket's closing `]` — `[Encode_SQL:
  'it\'s']` ended the string one character early at the escaped quote,
  then misread the string's real closing quote as *opening* a new one,
  losing track of the actual `]`. `ExpressionParser.readString` already
  handled this correctly; the outer bracket scanner had its own, separate,
  more naive quote-tracking. Found testing `Encode_SQL` with a real
  apostrophe-containing string, fixed to skip the escaped character the
  same way.
- The same "route a multi-statement `[...]` body through `ScriptBodyParser`"
  fix `inline-write-raw-sql-plan`'s predecessor session added for
  `define_tag`/`define_type` needed extending to `output_none`/
  `html_comment`/`encode_set` too (`bodyOpensWithLegacyDefinition`, now
  covering all five keywords) — plus one more real shape: `Output_None;`
  used completely bare with no colon or parens at all, directly followed
  by `;`. The existing "valid next character" check only allowed
  whitespace/`(`/`:` after the keyword, not `;`, so this exact shape
  (extremely common in the real corpus) silently fell through to the
  single-expression fallback that would have swallowed everything after
  the first statement, the same failure mode this whole mechanism exists
  to prevent. Fixed by adding `;` to the accepted set.

Verified via 8 new tests (76/76 total, no regressions) and a live
real-corpus crawl (`LASSO_CRAWL_REPORT=1`, see
`Documentation/lasso-perfect-server.md`): clean pages rose from 1,666 to
1,690 of 1,989, and `unknownFunction("Output")` no longer appears anywhere
in the failure report. Several pages that previously failed on the
`Output` gap now progress further and stop at `inlineNotConfigured`
(expected — no live datasource wired into the sweep), which is why that
bucket's count grew rather than shrank — not a regression, pages getting
further before hitting the next, already-documented, expected blocker.

Deferred, not needed by real corpus evidence this pass: `Encode_Set`'s
real Lasso semantics allow nesting/stacking multiple active encodings
(this implementation only tracks a single override stack per `Output`
lookup, which is sufficient for the corpus's actual usage — always a
single `-EncodeNone` scope, never nested `Encode_Set`s); `->decodeHtml`
and other decode-direction string methods (mentioned only incidentally in
the Lasso 9 reference search results, no real corpus usage found);
extended-ASCII/foreign-character numeric-entity encoding for the default
`-EncodeHTML` path (the existing `String.htmlEncoded` extension — reused
here rather than duplicated — only escapes the five HTML-reserved
characters, not extended-ASCII; left unchanged to avoid regressing
already-passing corpus fixture tests that depend on its current exact
behavior).

## Goal

Implement Lasso's `[Output]`/`Output(...)` tag and its documented sibling
output/encoding tags (`Output_None`, `HTML_Comment`, the `Encode_*` family,
`Encode_Set`), grounded in both Lasso 8 tag-style and Lasso 9 method-style
documentation, prioritized by real corpus usage evidence.

## Sources Reviewed

- `References/Lasso/Lasso 8.5 Language Guide.pdf`, Chapter 14 "Programming
  Fundamentals" (Table 1: Output Tags) and Chapter 17 "Encoding" (Encoding
  Rules, Encoding Formats).
- Online Lasso 9 reference: `lassoguide.com/language/methods.html` (does
  not cover built-in output/encoding methods — general method-definition
  syntax only) and `lassoguide.com/operations/strings.html` (via search —
  confirms the Lasso 9 encoding keyword set and that encoding is exposed
  through string instance methods, e.g. `->encodeHtml`, rather than free
  tags).
- Real corpus (site root path in the `lasso-real-corpus-paths` project
  memory, not hardcoded here since it embeds a real instance/site
  identifier) — `grep`-counted usage of
  every `Output`/`Encode_*`/`Output_None`/`HTML_Comment`/`Encode_Set`
  construct before implementing, to ground scope in evidence rather than
  the documentation's theoretical ceiling.

## Documented Surface

### `[Output]` / `Output(...)`

Applies an encoding to any expression, member tag, or sub-tag result.
Default `-EncodeHTML` per Chapter 17's "Encoding Rules" ("Substitution
Tags which output a value to the site visitor have a default encoding of
-EncodeHTML"). Overridable by an explicit keyword on the call, or by an
enclosing `[Encode_Set]` scope.

### Encoding keywords / `Encode_*` tags / Lasso 9 string methods

| Keyword | Standalone tag | Lasso 9 method | Transform |
| --- | --- | --- | --- |
| `-EncodeNone` | — | — | No transform |
| `-EncodeHTML` (default) | `[Encode_HTML]` | `->encodeHtml` | Escapes `& < > " '` |
| `-EncodeSmart` | `[Encode_Smart]` | `->encodeSmart` | Escapes only extended-ASCII/foreign chars (`&#nnn;`); HTML-reserved chars untouched |
| `-EncodeBreak` | `[Encode_Break]` | `->encodeBreak` | HTML-encodes, then converts line breaks to `<br>` |
| `-EncodeXML` | `[Encode_XML]` | `->encodeXML` | Escapes `& < > "` plus `'` → `&apos;` (XML's named entity, distinct from HTML's numeric `&#39;`) |
| `-EncodeURL` | `[Encode_URL]` | `->encodeURL` | Percent-encodes illegal URL characters (`.urlQueryAllowed` charset) |
| `-EncodeStrictURL` | `[Encode_StrictURL]` | `->encodeStrictURL` | Percent-encodes the above plus reserved name/value-pair characters (`; / ? : @ = &`) — RFC 3986 unreserved charset |
| `-EncodeSQL` | `[Encode_SQL]` | `->encodeSQL` | Escapes `\` then `"` then `'` for safe SQL string-literal splicing |
| `-EncodeBase64` | `[Encode_Base64]` | `->encodeBase64` | Base64-encodes |

### `Output_None` / `[Output_None] ... [/Output_None]`

"Hides a portion of page from being output, but processes the Lasso tags
within" (Chapter 14, Table 1). Implemented as a container tag: renders its
body (so assignments/side effects happen) but discards the rendered text.

### `HTML_Comment` / `[HTML_Comment] ... [/HTML_Comment]`

Wraps the body's rendered output in `<!-- -->` — content still reaches the
client (visible via "View Source") but isn't part of the visible page.

### `Encode_Set` / `[Encode_Set: -EncodeXxx] ... [/Encode_Set]`

Changes the default encoding for nested substitution tags within its
scope, without requiring `-EncodeNone` (or another keyword) on each one
individually.

## Deferred

- `Encode_Set` nesting/stacking beyond a single active override (real
  corpus only ever uses one un-nested `-EncodeNone` scope).
- Decode-direction methods (`->decodeHTML`, etc.) — no real corpus usage
  found.
- Extended-ASCII/foreign-character numeric-entity encoding for the
  default HTML encoding path (the existing, already-tested
  `String.htmlEncoded` extension covers only the five reserved
  characters) — left unchanged to avoid touching already-passing
  behavior; a real but separate gap from this pass's scope.

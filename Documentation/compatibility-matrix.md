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
| Includes | Yes | Yes | 4,000+ sightings | M1 parse, M2 execute, reparse-skipped when unchanged |
| Custom/native tags | Yes | Yes | Site startup libraries | M2 implemented, shared across requests on one server instance |
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

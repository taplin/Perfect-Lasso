# Lasso 9 Language-Compliance Gap Analysis (Top-Down, LassoGuide 9.3-Driven)

## Method

Built a ground-truth inventory directly from lassoguide.com 9.3 (Language Guide + Operations Guide reference sections — Strings, Byte Streams, Math, Date/Duration, Regular Expressions, Collections, Encryption, Serialization/Compression, Files; Literals, Variables, Operators, Control Flow, Captures, Query Expressions, Methods, Types, Traits, Error Handling), then cross-referenced every documented name against `Sources/LassoParser/Evaluator.swift` (`member(_:_:_:)`, ~line 435 — the single dispatch point for all `->` member calls on primitives), `Runtime.swift` (`registerDefaultFunctions()`, free-tag natives), `NativeTypes.swift` (`web_request`/`web_response`/`date`/`bytes` native-type method tables), `TypeSystem.swift` (`LassoMethodDispatcher`, user-type dispatch), and `TagCatalog.swift`/`Renderer.swift` (block-level control flow). Existing tracked-gap docs (`compatibility-matrix.md`, `outstanding-compatibility-project-plans.md`, `legacy-define-tag-type-plan.md`, `library-and-custom-tags.md`, `lasso-type-object-support.md`) were read first; anything already tracked there is only mentioned in one line below, not re-analyzed.

**Headline finding**: the corpus-driven approach built a real, well-engineered *tag/parsing/runtime infrastructure* (control-flow blocks, custom tags/types, sessions, datasources, includes) but the *primitive value method surface* — the actual `->` methods real Lasso code calls constantly on strings/arrays/maps/integers/decimals/dates — is a small fraction of what's documented. `Evaluator.member` (the one function handling every `->` call on a non-object value) implements roughly 20 string methods, 4 array methods, and 2 map/pair methods total, against LassoGuide's ~140 documented. This is exactly the blind spot the task predicted: a site whose corpus never happens to call `->sort`, `->find`, `math_round`, `->beginsWith`, etc. will never surface these gaps through crawling, yet they are foundational, frequently-used language surface.

---

## 1. String Methods

Implemented today (`Evaluator.swift:452-561`): `size`, `uppercase`, `lowercase`, `asstring`, `encodehtml`, `encodeurl`, `encodesmart`, `encodebreak`, `encodexml`, `encodestricturl`, `encodesql`, `encodebase64`, `decodebase64`, `contains`, `split`, `replace`, `append`, `trim`, `substring`/`sub`. That's it — no case-inspection, no find/compare, no padding, no iteration.

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `->find` / `->findLast` | P0 | missing | `->contains` exists but real code very commonly needs the *position* (`->find` returns 0 if not found, matching Lasso's 1-based/0-miss convention already used by `->substring`) | `Evaluator.swift` member switch |
| `->beginsWith` / `->endsWith` | P0 | missing | Extremely common string-prefix/suffix check; currently code must fake this with `->substring` slicing | `Evaluator.swift` |
| `->compare` / `->equals` | P1 | missing | Ordered/equality comparison distinct from `==` (locale-aware in real Lasso); `->equals` at minimum is trivial | `Evaluator.swift` |
| `->get` (single character at position) | P1 | missing | Documented core string-inspection method; only `->substring` exists today, which is a workable but non-idiomatic substitute | `Evaluator.swift` |
| `->titlecase` | P1 | missing | Sibling of implemented `->uppercase`/`->lowercase`; trivial to add (`String.capitalized` is close but not exact — needs per-word logic matching Lasso's docs) | `Evaluator.swift` |
| `->padLeading` / `->padTrailing` | P1 | missing | Common formatting need (zero-padding IDs, aligning report columns) | `Evaluator.swift` |
| `->removeLeading` / `->removeTrailing` | P1 | missing | Documented sibling of `->trim`, which IS implemented; asymmetric string trimming is a real, common need | `Evaluator.swift` |
| `->reverse` | P2 | missing | Documented manipulation method | `Evaluator.swift` |
| `->merge` (insert at position) | P2 | missing | Documented; `->append` (end-only) exists but not general insertion | `Evaluator.swift` |
| `->toLower(position)` / `->toUpper(position)` / `->toTitle(position)` | P2 | missing | Per-position case methods, distinct from the whole-string `->uppercase`/`->lowercase` already implemented | `Evaluator.swift` |
| Unicode character-class tests (`->isAlpha`, `->isDigit`, `->isUpper`, `->isLower`, `->isSpace`, `->isPunct`, `->isAlnum`, etc. — ~20 documented `->isXxx`/`->isUXxx` methods) | P2 | missing entirely | Character-classification family, used for input validation/parsing loops; large but mechanical (map to Swift `Character`/`Unicode.Scalar` properties) | `Evaluator.swift`, likely a new small helper file (`StringInspection.swift`) given the volume |
| `->normalize` / `->decompose` / `->foldCase` | P3 | missing | Unicode normalization — real but rare need | `Evaluator.swift` |
| `->decodeHtml` / `->decodeXml` / `->encodeHtmlToXml` | P1 | missing | `->encodeHtml`/`->encodeXml` exist (encode-only, one direction); decode is the missing half, needed for round-tripping stored/escaped content | `Evaluator.swift` / `Encoding.swift` (add `LassoEncoding.decodeHTML`/`decodeXML`) |
| `->encodeSql92` | P3 | missing | `->encodeSql` (MySQL-flavor) exists; SQL-92 variant is a documented sibling, low corpus likelihood given this project's MySQL/FileMaker focus | `Encoding.swift` |
| `->asBytes` | P1 | missing | Bridges string↔bytes; currently `bytes()` constructor exists as a free function but the *method* form on an existing string doesn't — blocks idiomatic Lasso 9 code | `Evaluator.swift`, `BytesType.swift` |
| `->hash` (simple hash) | P3 | missing | Low-stakes, rarely load-bearing | `Evaluator.swift` |
| `->unescape` | P3 | missing | Reverse of literal escape-sequence parsing; edge case | `Evaluator.swift` |
| `->forEachCharacter`/`->forEachWordBreak`/`->forEachLineBreak`/`->forEachMatch` and `->eachCharacter`/`->eachWordBreak`/`->eachLineBreak`/`->eachMatch` (iteration family) | P1 | missing | No capture/block-callback method-calling mechanism exists at all yet (see Section 6/8) — these need that infrastructure first, so they're gated on a larger gap, not a quick add | `Evaluator.swift` + new capture-invocation support |
| `->values` (array of characters) | P2 | missing | `->split` exists (delimiter-based); this is the char-array-with-no-delimiter documented sibling | `Evaluator.swift` |
| `->keys` (character-position series) | P3 | missing | Depends on `GenerateSeries`/series type, itself unimplemented (Section 6) | `Evaluator.swift` |

## 2. Array / Map / Pair / Collection Methods

Implemented today: `.array` → `size`, `first`, `insert`, `get` (`Evaluator.swift:577-621`); `.map` → `insert`, and a bare-subscript fallback (`values[normalized]`) that acts as an implicit `get`; `.pair` → `first`, `second`. No `staticarray`, `list`, `queue`, `stack`, or real `set` type exists — `set(...)` (`Runtime.swift:361`) is explicitly a plain `.array` alias with a documented, un-fixed dedup gap.

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `array->sort` | P0 | missing | One of the single most common array operations in real templates (sorted product/category lists); total absence | `Evaluator.swift` |
| `array->reverse` | P1 | missing | — | `Evaluator.swift` |
| `array->last` / `array->second` | P1 | missing | `->first` exists; `->last` and `->second` are documented direct siblings, trivial | `Evaluator.swift` |
| `array->join` | P0 | missing | Extremely common (building CSV/comma lists, breadcrumb trails); no equivalent exists at all today | `Evaluator.swift` |
| `array->find` / `array->findPosition` / `array->count` / `array->contains(matching)` (predicate form) | P1 | missing | Only element-existence via a different mechanism is missing entirely — there's no `contains` on `.array` at all (string has one, array doesn't); `find`/`count` fully absent | `Evaluator.swift` |
| `array->remove` / `array->removeAll` | P1 | missing | Only `insert`/`get` exist; no way to delete an element at all | `Evaluator.swift` |
| `array->sub` (slice) | P2 | missing | Documented range-extraction method | `Evaluator.swift` |
| `array->get=` / index-assignment | P2 | missing | Only read-`get` exists; positional overwrite absent | `Evaluator.swift` |
| `array + array` (combine operator) | P2 | missing | `+` on `.array`/`.string` isn't handled in `Evaluator.binary` (only numeric/string-coercion paths exist, `Evaluator.swift:374-381`) | `Evaluator.swift` (`binary` func) |
| `map->keys` / `map->values` | P0 | missing | One of the most common map operations (iterating a map's own keys); `.map` dispatch (`Evaluator.swift:622`) has *no* named methods at all beyond `insert` and the implicit subscript-get — `keys()`/`values()` don't exist even as a workaround | `Evaluator.swift` |
| `map->find` (miss-safe lookup) / `map->contains` | P1 | missing | Today an unknown key silently falls through to `.null` via the bare subscript (`Evaluator.swift:622`) with no way to test for presence first | `Evaluator.swift` |
| `map->remove` / `map->removeAll` / `map->size` | P1 | missing | No deletion or count operation on maps at all | `Evaluator.swift` |
| `pair->first=` / `pair->second=` (mutating setters) | P3 | missing | Read-only pair access exists; mutation is rare | `Evaluator.swift` |
| `staticarray` type (literal `(: 1, 2, 'x')` and its whole method family) | P1 | missing entirely | Documented as a first-class literal syntax (`literals.html`) AND its own operations page section; this interpreter has no `LassoValue` case or parser support for `(: ... )` staticarray literals at all — a real parse gap, not just missing methods | `ExpressionParser.swift` (literal parsing) + new case in `TypeSystem.swift`/`LassoValue` |
| `list` / `queue` / `stack` types | P2 | missing entirely | Documented ordered-collection types (insertFirst/insertLast/removeFirst etc.) with no corpus-evidenced usage found in prior work, but real language surface for anything doing FIFO/LIFO processing | new file, e.g. `Collections.swift`, following the `date`/`bytes` native-type pattern in `NativeTypes.swift` |
| Real `set` semantics (unique-insert dedup) | P1 | implemented but diverges from spec | `Runtime.swift:361`'s `set(...)` is a plain array — `LassoValidation`/`Documentation` itself flags this as a known, un-fixed correctness gap (duplicate-preserving where real Lasso dedups) | `Runtime.swift` — needs either a real `.set` `LassoValue` case or a native-object wrapper enforcing uniqueness on `->insert` |
| `array->asStaticArray` | P3 | missing | Depends on staticarray existing first | `Evaluator.swift` |

## 3. Math

**Total gap**: not one of LassoGuide's documented `math_*` free functions or bitwise integer methods exists anywhere in this codebase. `Runtime.swift` has zero `math_` registrations; `Evaluator.member` has only `asstring`/`ceil` on `.integer`/`.decimal` (`Evaluator.swift:562-574`), and `.integer`'s own `"ceil"` case is actually a bug (returns the integer unchanged — a no-op that should probably not exist as a distinct case at all, since ceiling of an integer is itself).

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `math_abs`, `math_min`, `math_max`, `math_round`, `math_floor` (free-function form; `math_ceil` too, distinct from the buggy integer-member `ceil`) | P0 | missing entirely | Core arithmetic helpers used pervasively in any pricing/quantity/pagination logic — real corpus almost certainly needs at least `math_round`/`math_max`/`math_min` even if not yet crawled | `Runtime.swift`, alongside `currency`/`percent`/`date_format` registrations |
| `math_mod`, `math_div`, `math_mult`, `math_add` | P2 | missing | Functional equivalents of `%`/`/`/`*`/`+` operators (which do work); lower priority since the operators already cover the common case | `Runtime.swift` |
| `math_pow`, `math_sqrt` | P1 | missing | Common in any calculation-heavy page (shipping/tax formulas, geometry) | `Runtime.swift` (`Foundation.pow`/`sqrt` trivially back these) |
| `math_random` | P1 | missing | Used for randomized display order, session tokens, A/B testing — real corpus precedent already exists for `set`'s dedup logic hinting at randomization use cases | `Runtime.swift` |
| Trig/log family (`math_sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`atan2`/`exp`/`ln`/`log`/`log10`) | P3 | missing | Rare in typical e-commerce/CMS Lasso code; documented completeness item only | `Runtime.swift` |
| `math_roman`, `math_convertEuro` | P3 | missing | Obscure/legacy-specific formatters | `Runtime.swift` |
| Integer bitwise methods (`->bitAnd`/`->bitOr`/`->bitXOr`/`->bitNot`/`->bitShiftLeft`/`->bitShiftRight`/`->bitClear`/`->bitFlip`/`->bitSet`/`->bitTest`) | P2 | missing entirely | Real but infrequent outside permission-flag/bitmask-style code | `Evaluator.swift` member switch, `.integer` case |
| `.integer` member `"ceil"` returning the value unchanged | P3 | implemented but likely vestigial/harmless | Not wrong per se (ceiling of an int is itself) but reads as leftover scaffolding rather than a documented method — low priority cleanup, not a real compatibility gap | `Evaluator.swift:574` |

## 4. Date / Duration

Implemented: `date(...)` constructor (string/component forms), `date_format`, `date->format` (native-type method), `date_localtogmt`, `date_gmttolocal`, `server_date`. Everything else documented on `date-duration.html` — the entire `duration` type, all date math, and every date field-accessor method — is absent.

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `date_add` / `date_subtract` / `date->add` / `date->subtract` | P0 | missing | `date_add` was explicitly planned in `outstanding-compatibility-project-plans.md` item 2's own scope list but never shipped — the plan doc's later status notes only cover `Date_Format`, `Decode_Base64`, etc.; `date_add` itself has no registration anywhere in `Runtime.swift`. Date arithmetic (expiration checks, "N days from now") is foundational | `Runtime.swift` (free function) + `NativeTypes.swift` `makeDateType()` (member form) |
| `date->year()`, `->month()`, `->day()`/`->dayOfMonth()`, `->hour()`, `->minute()`, `->second()`, `->dayOfWeek()` | P0 | missing entirely | `LassoDateParsing`/`LassoDateComponents` already store these six fields internally (per the date-format plan doc) but expose **zero** field-accessor methods — `date->format('%Y')` is the only way to extract a year today, forcing every date-field read through string formatting instead of a direct accessor. This is a real, load-bearing gap for any date-comparison/date-math logic that isn't purely display-formatting | `NativeTypes.swift` `makeDateType()` — trivial once `LassoDateComponents`' existing stored fields are exposed |
| `date->asInteger` (epoch seconds) | P1 | missing | Needed for date comparison/sorting/serialization without string round-tripping | `NativeTypes.swift` |
| `date_difference` / `date->difference` / `date->daysBetween`/`->hoursBetween`/etc. | P1 | missing | Common "days until X" / "time since Y" real-world need | `Runtime.swift` + `NativeTypes.swift` |
| `duration` type (constructor + all accessors + date`+`/`-`duration operators) | P1 | missing entirely | A distinct documented type with no representation in `LassoValue`/`LassoNativeTypeRegistry` at all — durations (shipping windows, session timeouts, elapsed-time displays) have no way to be represented as values, only as raw seconds/strings | new `makeDurationType()` in `NativeTypes.swift`, mirroring `makeDateType()`'s pattern |
| `date->set`/`->clear`/`->roll` | P2 | missing | Mutation methods on date objects | `NativeTypes.swift` |
| `date->timezone`/`->gmt`/`->dst`/`->zoneOffset`/`->dstOffset` | P2 | missing | Timezone-introspection methods; `date_localtogmt`/`date_gmttolocal` cover the conversion case but not introspection | `NativeTypes.swift` |
| `date->am`/`->pm`/`->ampm`/`->hourOfAMPM` | P3 | missing | Cosmetic/display helpers, largely coverable via `->format` already | `NativeTypes.swift` |
| `date_setFormat`/`date->setFormat`/`->getFormat`, `date_getLocalTimeZone`, `date_minimum`/`date_maximum`, `date_msec` | already tracked | deferred (see `outstanding-compatibility-project-plans.md` item 2) | — | — |

## 5. Regular Expressions

**Total gap** — no `regexp` type, no `string->findRegExp`/`->replaceRegExp`, nothing. `LassoValidation`'s email check uses `NSRegularExpression` internally but that's a private implementation detail, not exposed Lasso language surface.

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `regexp(...)` type + `->find`/`->matches`/`->replaceAll`/`->replaceFirst`/`->split`/`->groupCount`/`->matchString` | P1 | missing entirely | Regular expressions are core, frequently-used Lasso 9 language surface (input validation, URL routing, text extraction) — this is a whole documented type category with zero implementation, not an edge case. NSRegularExpression is readily available in Foundation to back it | new `Regexp.swift`, registered as a native type in `NativeTypes.swift` following the `date`/`bytes` pattern |
| `string->findRegExp` / `string->replaceRegExp` | P1 | missing | The two documented string-side regex convenience methods; simplest, most likely-used entry point (site validation/formatting logic) even before a full `regexp` type is built | `Evaluator.swift` string member switch, can be added independently of the full `regexp` type using `NSRegularExpression` directly |

## 6. Type System, Introspection, Traits, Captures, Query Expressions

Prior work built a solid first-pass object system (`data`, `onCreate`, `self`, multiple dispatch by arity/type — see `lasso-type-object-support.md`). What's missing is everything LassoGuide documents beyond that baseline.

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| Type introspection (`->type()`, `->isA()`, `->isNotA()`, `->hasMethod()`, `->listMethods()`, `->parent()`) | P1 | missing entirely | `Evaluator.member`'s `.object` case (`Evaluator.swift:623-634`) only ever attempts native-method dispatch, tag-registry method dispatch, or falls to a raw data-member read — there is no reflection surface at all. Real Lasso code frequently branches on `->isA(::sometype)`; without it, any polymorphic dispatch pattern in real code fails silently (falls through to a data-member miss returning `.null`) | `Evaluator.swift` `.object` case, or a small `TypeIntrospection.swift` |
| Inheritance (`parent` section, `inherited->`/`..member`, method override chains) | already tracked | parsed-but-inert (`legacy-define-tag-type-plan.md`, `lasso-type-object-support.md` "Known Gaps") | — | — |
| Traits (`define X => trait {...}`, `require`/`provide`/`import`, trait composition `+`, `isA` trait matching, `trait`/`setTrait`/`addTrait`) | P2 | missing entirely | Real, documented Lasso 9 language feature (whole dedicated Language Guide section) with no parser/runtime representation at all — `compatibility-matrix.md` marks this "Later" at the matrix level, but it's worth flagging concretely here since prior work never assessed *how much* surface that one line represents (an entire type-composition mechanism, not a handful of methods) | new parser support (`ScriptBodyParser`/`TypeBodyParser`) + new `LassoTraitDefinition` model paralleling `LassoTypeDefinition` |
| Captures (`{...}`/`{^...^}` literal blocks, `->invoke`, `yield`/`return`/`detach`, `currentCapture()`) | P1 | missing entirely | This is the single biggest structural gap found in this review: captures are Lasso 9's fundamental block/closure primitive — they're the mechanism `forEach`/`eachXxx`/`with...do` associated-block syntax (`=> {...}`) is actually built on in real Lasso, and everything in Sections 1/2 tagged "needs capture/block-callback infrastructure" (`forEachCharacter`, `array->forEach`, custom `->find(matching)` predicates) is gated behind this not existing. This project's `with x in y do {...}` (already implemented per `library-and-custom-tags.md`) is a hardcoded special case of what should be general capture-passing, not a first-class value | Large: needs a new `LassoValue.capture` case, parser support for bare `{...}` as an expression, and `->invoke`/association-operator (`=>`) wiring through `Evaluator` |
| Query Expressions (`query_expressions.html`'s SQL-like `with x in y where ... select ...`, `GenerateSeries`, "queriable" trait) | P2 | missing entirely | Documented, real Lasso 9 syntax layered on top of captures; gated behind captures existing first. `compatibility-matrix.md` already tracks this at "Later" | new parser support once captures exist |
| Series literals (`0 to 10 by 2`) / `GenerateSeries` type | P2 | missing | Documented literal syntax (`literals.html`) with no parser recognition — `to`/`by` aren't special-cased anywhere in `ExpressionParser.swift` | `ExpressionParser.swift` |
| Operator overloading on user types (`public +(rhs)`, `onCompare`, `asString`, `contains`, `invoke`, `_unknowntag`) | P2 | partially implemented | `onConvert`/ordinary member dispatch works (per `lasso-type-object-support.md`), but `Evaluator.binary` (arithmetic dispatch, `Evaluator.swift:374+`) never checks whether an operand is a `.object` with a user-defined operator method — `+`/`-`/etc. on custom types silently fall through rather than dispatching; `_unknowntag` fallback explicitly listed as a known gap already | `Evaluator.swift` `binary`/`member` |

## 7. Control Flow & Scoping — real, previously-unflagged bugs

This section surfaced the most concrete, high-confidence findings of the whole review — genuine correctness gaps in already-"working" control flow, not just missing documented sugar.

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `loop_abort()` | **P0** | **missing entirely — real bug, not just an unimplemented method** | Confirmed via direct grep: zero references to `loop_abort` anywhere in `Sources/`. Every loop construct (`loop`, `while`, `iterate`, `with...do` — `Renderer.swift:155-330`) is a fixed Swift `for`/`while` with no early-exit hook at all. Real Lasso code uses `loop_abort` constantly to break out of search-result loops once a condition is met (e.g., "find the first matching SKU, then stop"). Today, a real page calling `loop_abort()` hits `unknownFunction("loop_abort")` (breaking the whole page) or, worse, if some later fix makes it a silent no-op, the loop runs to completion every time — silently doing more/slower work than the real page intends, with no crash to reveal it. This is exactly the class of gap the corpus-crawl approach is structurally blind to: `loop_abort` inside a loop over a *small* found-set produces byte-identical output to a correctly-early-exiting loop, so it would never show up as a rendering diff | `Renderer.swift` — needs a new signal (parallel to the existing `returnSignal` mechanism) that block-render loops check after each iteration |
| `loop_continue()` | **P0** | **missing entirely**, same class of bug as above | Same mechanism gap; "skip this iteration" is a extremely common real-world loop pattern (skip out-of-stock items, skip hidden categories) | `Renderer.swift`, same signal mechanism as `loop_abort` |
| `loop_key()` | P1 | missing | `iterate` over a `.map` (`Renderer.swift:280`) already converts each entry to a `.pair(key, value)` and exposes it via the binding variable — but there's no `loop_key()` accessor for code that doesn't use the `iterate(map, var(x))` binding form and instead relies on `loop_value`/`loop_key` directly, the documented default pattern | `Renderer.swift`'s `iterate` case — trivial once the pair is already being computed |
| `given`/query-expression-driven loops | P2 | missing | See Section 6 (Query Expressions) | — |
| `match`/`case` (Lasso 9 canonical form, `match(x) case(c1,c2)...case.../match`) | P1 | missing (distinct from what's implemented) | `[Select]`/`[Case]` (Lasso 8 legacy form) is implemented and lowered into `if`/`else` (`outstanding-compatibility-project-plans.md` item 10) — but `match`/`case` is a **separately documented, differently-named Lasso 9 construct** (`control-flow.html`), not just a syntax alias of `Select`/`Case`. No parser recognizes bare `match(`/`case(` as anything other than an ordinary (unregistered) function call today. Given `Select`/`Case`'s lowering-into-`if` design already exists and works, `match`/`case` could reuse the identical `BlockBuilder` lowering strategy with `match`/`case` as additional recognized keywords | `TagCatalog.swift` (add entries), `BlockBuilder.swift` (extend the existing `select`/`case` lowering to also trigger on `match`/`case`) |
| Decompositional assignment (`local(one, two, three) = (: 1, 2, 3)`, wildcard `_`, nested) | P2 | missing | Documented `variables.html` feature; no support in `ExpressionParser`'s assignment handling. Gated in part on staticarray literal support (Section 2) existing first | `ExpressionParser.swift` |
| Increment/decrement (`++`/`--`) | P2 | missing | `ExpressionParser.swift:50`'s operator token list has no `++`/`--`; only `+=`/`-=` compound-assignment forms are tokenized | `ExpressionParser.swift` |
| Strict equality (`===`/`!==`) | P2 | missing | Documented distinct-from-`==` operator (no type coercion); `ExpressionParser.swift:50` only tokenizes `==`/`!=` | `ExpressionParser.swift`, `Evaluator.swift` `binary` |
| `!>>` (does-not-contain) | P2 | missing | `>>` (contains) is tokenized and implemented (`Evaluator.swift:396`); its documented negation isn't | `ExpressionParser.swift`, `Evaluator.swift` |
| `:=` (assign-produce) | P3 | missing | Documented but narrow-use operator (assignment that also yields the assigned value as an expression result) | `ExpressionParser.swift` |
| `->\` / `\` (method-escape syntax), `&` (retarget operator) | P3 | missing | Advanced/rare invocation-control syntax | `ExpressionParser.swift` |
| Ternary bare-statement-guard form (`condition ? statement`, no `|` branch) | already tracked | deferred, see `compatibility-matrix.md` row 49 | — | — |

## 8. Encryption / Hashing

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `encrypt_md5` | P1 | missing | `encrypt_hmac` exists (keyed MAC); plain one-way MD5 hashing (used for cache keys, non-security checksums, legacy password-storage compat) is a separate, simpler, commonly-needed sibling with zero implementation | `Hashing.swift` (trivial — `Insecure.MD5.hash`, same `swift-crypto` dependency already in use) |
| `cipher_digest` (general digest: SHA1/SHA256/etc. as a standalone hash, not HMAC) | P1 | missing | `encrypt_hmac` only produces a *keyed* MAC; there's no way to compute a plain SHA-256/SHA-1 digest of a value at all today, a real and common need (file integrity checks, cache keys, non-authenticated fingerprints) | `Hashing.swift` |
| `encrypt_blowfish` / `decrypt_blowfish` | P2 | missing | Real, documented reversible-encryption pair for legacy interop (blowfish is Lasso 8-era but still documented in 9.3); `swift-crypto` doesn't include Blowfish out of the box, so this needs either a vendored implementation or an explicit "not supported" decision — worth a scoping conversation, not a quick add | new file or explicit deferral note in `Hashing.swift` |
| `cipher_encrypt` / `cipher_decrypt` (general keyed-cipher framework, e.g. AES) | P2 | missing | Modern equivalent of blowfish for new code; `swift-crypto` has AES-GCM readily available | `Hashing.swift` |
| `cipher_list` | P3 | missing | Introspection/discovery helper, low standalone value | `Hashing.swift` |
| `encrypt_hmac -cram` | already tracked | deferred, zero corpus evidence (`outstanding-compatibility-project-plans.md` item 10) | — | — |

## 9. Serialization & Compression

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `serialize()` / `serialization_reader`/`->read` (generic object serialize/deserialize) | P2 | missing | `json_serialize` exists (`Runtime.swift:364`, JSON-only, one-way — no `json_deserialize`/`deserialize` counterpart at all) but the documented generic Lasso serialization protocol (works on any type implementing `trait_serializable`) doesn't exist | new file, e.g. `Serialization.swift` |
| `json_deserialize`/equivalent | P1 | missing | Asymmetric with the existing `json_serialize` — real applications that serialize also need to read JSON back (API integration, cached data, session restore uses a bespoke JSON encoder already per `Runtime.swift:750-774`'s `LassoValue.from(json:)`, but that's an internal helper, not exposed as a callable Lasso method) | `Runtime.swift` — `LassoValue.from(json:)` already exists internally and could back a `json_deserialize` registration directly |
| `compress`/`decompress`/`uncompress` | P2 | missing | Documented byte-stream compression (gzip/zlib-family); real use cases include compressed session/cache storage and file downloads | new file, backed by `zlib`/Foundation's `Compression` framework or swift-nio's existing gzip support (already a transitive dependency via Perfect-NIO) |

## 10. Byte Streams (`bytes` type)

`NativeTypes.swift`'s `makeBytesType()` explicitly implements only 3 of ~35 documented `bytes` methods (`decodeBase64`, `encodeBase64`, `encodeUrl`) — deliberately scoped to what one real corpus chain used (per its own doc comment, `NativeTypes.swift:417-425`).

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `bytes->size` / `->get` / `->getRange` | P1 | missing | Core inspection methods with no substitute today — a `bytes` object can currently only be constructed and re-encoded, never inspected | `NativeTypes.swift` `makeBytesType()` |
| `bytes->find`/`->contains`/`->beginsWith`/`->endsWith` | P2 | missing | Documented inspection family, mirrors the string gaps in Section 1 | `NativeTypes.swift` |
| `bytes->asString` | P1 | missing | The natural inverse of the string→bytes path (`bytes(stringValue)` constructor exists); currently no documented way to get a plain string back out of a `bytes` object except via the narrow `decodeBase64` path | `NativeTypes.swift` |
| `bytes->encodeHex`/`->decodeHex` | P1 | missing | Extremely common for binary-to-text representations (tokens, hashes) alongside the existing base64 support | `NativeTypes.swift` |
| `bytes->append`/`->trim`/`->split`/`->sub` (manipulation family) | P2 | missing | Mirrors the string-manipulation gaps; `bytes` today is effectively write-only (construct, then only re-encode) | `NativeTypes.swift` |
| `bytes->export8bits`…`->export64bits` / `->import8bits`…`->import64bits` (binary integer packing) | P3 | missing | Real but specialized (binary protocol/file-format work); lowest-likelihood need for a typical web app corpus | `NativeTypes.swift` |
| `bytes->crc` | P3 | missing | Checksum utility, narrow use | `NativeTypes.swift` |

## 11. File System (`file`/`dir` types)

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `file`/`dir` types (open/read/write/exists/delete/list, entire family) | P2 | missing entirely | This interpreter has real filesystem-touching infrastructure (`LassoFileSystemIncludeLoader`, `LassoFileSystemUploadProcessor`) but it's all internal service-protocol plumbing, never exposed as Lasso-callable `file`/`dir` objects. Real Lasso 8 sites commonly use `[File]`-family tags directly for logging, flat-file data, and config reading outside the database layer — likely under-represented in any corpus sweep specifically because pages using it may already be failing for unrelated reasons and getting deprioritized | new `Files.swift`, registered as a native type via `NativeTypes.swift`'s established pattern, reusing the same root-confinement policy `LassoFileSystemIncludeLoader` already implements |

## 12. Error Handling — completeness vs. the existing first-pass model

`error-protect-model-plan.md`'s work (`protect`, `error_currentError`, `LassoRecoverableError`/`LassoErrorState`) is a solid foundation, but the full documented error-handling surface is much larger.

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `fail(msg)` / `fail(code, msg)` / `fail_if(condition, ...)` | P1 | missing | The documented way *application code itself* raises a recoverable error for `protect` to catch (as opposed to the adapter's own internal capability-denial/write-failure errors, which already produce `LassoRecoverableError`) — real corpus validation logic (`fail_if(#email->size == 0, 'Email required')`-style patterns) has no way to trigger this today | `Runtime.swift` — should throw the existing `LassoRecoverableError`/`LassoErrorState`, no new error model needed, just a new entry point into it |
| `handle() => {...}` / `handle_failure() => {...}` | P1 | missing | Documented `finally`-style and `catch`-style block forms, distinct from `protect`'s single-block model; `protect` alone can't express "always run this cleanup regardless of success/failure" | `Renderer.swift`, likely alongside the existing `protect` block case |
| `abort()` | already implemented | Rides `returnSignal` (per `outstanding-compatibility-project-plans.md` item 8 and `web_response->abort`) — the free-function form `abort()` itself (vs. only `web_response->abort`) should be checked for parity, worth a quick verification pass | `Runtime.swift` |
| `error_push`/`error_pop`/`error_stack`/`error_reset` | P2 | missing | Multi-level error-stack inspection, beyond the current single-current-error model (`context.currentError`/`lastError`) | `Providers.swift` (`LassoErrorState`) |
| `error_code_*` documented error-code constants (e.g. `error_code_fileNotFound`, `error_code_divideByZero`) | P2 | missing as named constants | Real Lasso code checks `error_currentError(-errorCode) == error_code_fileNotFound`-style comparisons against named constants, not raw numbers; this adapter's own error codes (`InlineErrorCode` 1001-1006, encryption 3001-3002, file 2001-2003) are project-local and don't line up with the documented real Lasso numbering — worth an explicit reconciliation pass, flagged as a judgment call already made once (`error-protect-model-plan.md`) but not revisited against the full documented constant table | `Providers.swift` |
| Automatic divide-by-zero / method-not-found error surfacing as *recoverable* (catchable by `protect`) rather than fatal Swift throws | P1 | diverges from spec | `Evaluator.binary`'s `"/"` case (`Evaluator.swift:380`) does plain Swift division — a literal zero denominator either produces `inf`/`nan` silently (for `.decimal`) or a Swift crash (for `.integer`, via `%`'s already-present `max(...,1)` protection, but division itself has no equivalent guard) rather than the documented catchable `error_code_divideByZero` | `Evaluator.swift` `binary` |

## 13. Output Formatting / Encoding

Mostly solid (`output-tags-plan.md`, Section 1's encode/decode gaps aside). One additional finding:

| Name | Priority | Status | Rationale | Suggested location |
|---|---|---|---|---|
| `Locale_Format` / `Scientific` (Currency/Percent's documented siblings) | already tracked | deferred, zero corpus evidence (`outstanding-compatibility-project-plans.md` item 10) | — | — |

## 14. Web/Session/Request Context

Already extensively covered by prior corpus-driven work (`compatibility-matrix.md` rows 42-51, `outstanding-compatibility-project-plans.md` items 1, 7, 8). This top-down pass found no *additional* documented member beyond what those docs already enumerate and classify — `web_request`/`web_response`/session coverage is genuinely close to complete relative to `requests-responses.html`/`sessions.html`. Not re-analyzed here per the task's own instruction.

## 15. Validation

`Valid_Email`/`Valid_CreditCard` are implemented and well-researched (`Validation.swift`). LassoGuide 9.3 doesn't have a dedicated "validation" reference page distinct from these two Lasso-8-era tags, so no further top-down gaps found here beyond what's already tracked.

---

## Top 10 — Do First

Ranked by (documented pervasiveness × likelihood of silent/undetectable failure in the existing corpus-crawl process):

1. **`loop_abort()` / `loop_continue()`** (Section 7) — genuinely missing control-flow primitives, not just sugar; their absence is invisible to output-diffing on small found-sets, making this the single highest-value fix: it's a correctness bug the existing crawl methodology structurally cannot detect. `Renderer.swift`.
2. **`date->year()`/`->month()`/`->day()`/etc. field accessors** (Section 4) — the date object already stores every needed field internally; only the accessor methods are missing. Cheapest-possible fix for a foundational, constantly-needed capability (any date comparison/math outside pure display formatting). `NativeTypes.swift`.
3. **`array->sort` / `array->join` / `map->keys` / `map->values`** (Section 2) — the four single most commonly used collection operations in real templates, all completely absent. `Evaluator.swift`.
4. **`date_add`/`date->add` (date arithmetic)** — was explicitly planned in this project's own backlog and never shipped; "N days from now" is one of the most common real-world date operations. `Runtime.swift` + `NativeTypes.swift`.
5. **`string->find`/`->beginsWith`/`->endsWith`** (Section 1) — core string-inspection methods with no substitute; `->contains` alone can't answer "does it start with" or "where is it."
6. **`math_*` free-function family, starting with `abs`/`min`/`max`/`round`/`sqrt`/`random`** (Section 3) — zero math helper functions exist at all today; any pricing/quantity/discount calculation beyond the four bare arithmetic operators has no support.
7. **`regexp` type + `string->findRegExp`/`->replaceRegExp`** (Section 5) — a whole documented Lasso 9 type category with zero implementation; validation/parsing/routing logic in real sites very plausibly depends on this even though no corpus crawl surfaced it (crawling only exercises GET rendering of static-ish pages, not the input-validation code paths where regex usage concentrates).
8. **Captures (`{...}` blocks, `->invoke`, associated-block `=>` syntax)** (Section 6) — the structural prerequisite blocking a whole cluster of other gaps (`forEach`-style iteration, predicate-based `find`, general callback-taking methods). Worth scoping as its own project, since it's the biggest single piece of missing language machinery found in this review.
9. **`array->remove`/`->removeAll` and `map->remove`/`->size`/`->contains`** (Section 2) — collections can be built and read but never shrunk or queried for size/presence; a real, load-bearing asymmetry.
10. **Type introspection (`->isA`, `->hasMethod`, `->type()`)** (Section 6) — the object system (per `lasso-type-object-support.md`) supports construction and dispatch but has no reflection surface at all, blocking any real code that branches polymorphically on an object's type — a common pattern once user-defined types are used for more than simple data records.

---

## Files referenced

- `/Users/timtaplin/Perfect-Lasso/Sources/LassoParser/Evaluator.swift` (member dispatch, ~line 435-637; binary operators, ~line 365-412)
- `/Users/timtaplin/Perfect-Lasso/Sources/LassoParser/Runtime.swift` (free-function native registry, `registerDefaultFunctions()` ~line 117-723)
- `/Users/timtaplin/Perfect-Lasso/Sources/LassoParser/NativeTypes.swift` (`web_request`/`web_response`/`date`/`bytes` native-type method tables)
- `/Users/timtaplin/Perfect-Lasso/Sources/LassoParser/TypeSystem.swift` (`LassoObjectInstance`, `LassoMethodDispatcher`)
- `/Users/timtaplin/Perfect-Lasso/Sources/LassoParser/TagCatalog.swift` / `Renderer.swift` (block-level control flow: `if`/`loop`/`while`/`iterate`/`with`/`protect`)
- `/Users/timtaplin/Perfect-Lasso/Sources/LassoParser/ExpressionParser.swift` (operator tokenization, `~line 50, 420`)
- `/Users/timtaplin/Perfect-Lasso/Sources/LassoParser/Validation.swift`, `Hashing.swift`, `Encoding.swift`, `DateFormatting.swift`, `NumberFormatting.swift`, `BytesType.swift` (supporting implementations referenced throughout)
- `/Users/timtaplin/Perfect-Lasso/Documentation/compatibility-matrix.md`, `outstanding-compatibility-project-plans.md`, `legacy-define-tag-type-plan.md`, `library-and-custom-tags.md`, `lasso-type-object-support.md` (existing tracked-gap docs, consulted first to avoid duplication)

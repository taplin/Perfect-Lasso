# Captures Subsystem Scoping Pass

## Additional corpus evidence (2026-07-21) — two more real Lasso 9 codebases

Tim provided two more real, independent Lasso 9 codebases not covered by the
original scoping pass:
`.../DevWorkArchive/TS_lasso9` (61 `.lasso`/`.inc` files, a tennis-court
booking/POS system) and `.../DevWorkArchive/bugcity9` (24 files, an
e-commerce site). Direct grep + manual inspection of every `=>` occurrence in
both (file-by-file, not sampled) found **real, uncommented, non-trivial
capture-family usage the original two corpora (scrubsSite/scrubs9) showed
zero evidence for**:

- **`#AIMParams->forEachPair => { #AIMParamArray->insert(#1->first = #1->second) }`**
  (`bugcity9/StartUpTags/AuthorizeNet_AIM_9.inc`) — genuine `forEach`-family
  iteration over a map, with `#1` positional capture-parameter binding, in a
  real payment-gateway (Authorize.net AIM) integration file — not a toy
  example. **`forEach`/`forEachPair` do not exist anywhere in this codebase
  today** (confirmed via grep — zero hits in `Evaluator.swift`/
  `Collections.swift`/`Runtime.swift`). This single line is concrete,
  real-world proof that Stage 4's `->forEach` work (§5) has an actual
  consumer, contradicting the original pass's "zero corpus hits" finding —
  the original corpora simply didn't happen to include this idiom.
- **`inline(-host=..., -database=..., -sql=$sqlcode, -maxrows='all')=>{ records=>{ ... } }`**
  (repeated across `TS_lasso9/index.lasso` and 4 near-duplicate siblings) —
  `inline`/`records` invoked as an ORDINARY EXPRESSION with parens and an
  associated capture block, not the bracket-tag `[Inline]...[/Inline]` form
  this codebase implements as a hardcoded `.block(name: "inline")` parse
  node. This is real evidence of the general "arbitrary call + `=>{...}`"
  mechanism (§4.1) being used for tags beyond the six hardcoded keywords
  (`define`/`if`/`while`/`loop`/`match`/`iterate`) already covered.
- **`(-inlinename='menulist')=>{^	 ^}`** and **`loop(10)=>{^ ... ^}`**
  (`TS_lasso9/index copy.lasso`, `courts/main.lasso`) — the auto-collect
  `{^...^}` literal form, real (if the first example is a trivial/empty
  body) — the original pass found zero live `{^...^}` usage anywhere.
- **`with current_result in #AIMResultArray do => { #counter += 1 ... }`**
  (`bugcity9/StartUpTags/AuthorizeNet_AIM_9.inc`) — a genuinely NEW,
  currently-unparseable variant of the already-implemented `with...do`:
  **confirmed by direct code inspection** (`ScriptBodyParser.swift:503-509`,
  `parseWithOpening`) that the parser requires `do` followed directly by
  `{` (via `skipTrivia()` then a hard `characters[index] == "{"` check) —
  it never calls `consumeArrowBlockStartIfPresent()` the way `parseElseTag`
  does, so an explicit `=>` between `do` and `{` fails to parse today. This
  is a small, concrete, independently-fixable gap (accept an optional `=>`
  in `parseWithOpening`, mirroring `parseElseTag`'s existing pattern) that
  doesn't need to wait for the rest of the Captures subsystem.
- **`select(found_count)=>{ case(0) ... }`** (`TS_lasso9/authenticate.lasso`,
  `ccp/pos_tags.lasso`) — the legacy `Select`/`Case` construct (already
  lowered to `if`/`else`, per `outstanding-compatibility-project-plans.md`
  item 10) invoked via the arrow-association call form rather than the
  bracket-tag form — not independently verified against the current
  `select`/`case` parser support in this pass; worth checking when Stage 1's
  general `=>`-as-expression-operator work lands, since it may already
  self-resolve.
- A commented-out (`/* ... */`, dead) example in `TS_lasso9/courts/main.lasso`
  — `$atimes->foreach=>{$xset->insert(#1)};` — not live evidence on its own,
  but shows the same developer reaching for this exact `->foreach`+`#1`
  idiom independently in a second file, consistent with the AuthorizeNet
  finding above rather than a one-off.

**Net effect on the staged plan**: Stage 4 (`->forEach`) now has real,
non-hypothetical corpus justification, not just "the docs say `Set->ForEach`
needs it." The `with...do=>{...}` arrow-form gap is real but independent of
the rest of this plan — worth fixing as a standalone quick patch whenever
convenient, not gated on Stage 1-3. Everything else in the original pass's
architecture/risk analysis (§§1-7) is unaffected by this new evidence.

## Status note (2026-07-21)

**§8's "do not build now" recommendation below was made on corpus-evidence
grounds alone — Tim overrode it explicitly: "Captures is important even if
it's not used in the current corpus examples."** This project's corpus is
known to skew Lasso 8.5-era code, and Captures is genuinely foundational
Lasso 9 language machinery (not a rarely-hit convenience method) — corpus
absence is the wrong signal for whether to build core language primitives,
only for how to prioritize among many already-real gaps. Implementation is
proceeding per the staged plan in §5, starting with Stage 1. The rest of this
document (inventory, architecture, risk assessment, staged plan) remains
accurate and is the active reference for that work — only §8's go/no-go
verdict is superseded.

## Methodology

Ground truth for this pass is lassoguide.com's Lasso 9.3 documentation, fetched
directly (`curl` + local HTML-to-text conversion, since `WebFetch`'s
summarizing layer refused verbatim quotes) — Captures are a Lasso 9 concept
with **zero** coverage in the local Lasso 8.5 Language Guide PDF, confirmed
directly via `pdftotext` + `grep -ni "capture\|closure"` (only unrelated hits:
generic English "capture errors," `Null->DetachReference`,
`OS_Process->Detach`). `lasso85-gap-analysis-plan.md` has zero mentions of
Captures anywhere either — confirmed absent, not merely unmentioned.
Cross-referenced against the actual current codebase
(`/Users/timtaplin/Perfect-Lasso-captures/Sources/LassoParser/`) via direct
grep, and against real corpus usage
(`/Users/timtaplin/scrubsSite`, `/Users/timtaplin/Documents/scrubs9`, 1,817
files total, searched file-by-file). Existing tracked docs
(`lasso9-lassoguide-gap-analysis-plan.md` §6, `collections-subsystem-plan.md`
for methodology/format precedent) were read first.

## 1. Full Inventory — Real, Documented Captures API Surface

Source: `https://lassoguide.com/language/captures.html` (Lasso 9.3). All
quotes below are exact.

### 1.1 What a capture is

> "Captures are the basic frame of execution in Lasso. All code that executes
> does so within a capture. When a method is invoked, a capture is first
> automatically created for that method to execute in."

A capture's state (verbatim): the current method's code, the current `self`
and `inherited`, the current `params` staticarray, the current set of local
variables and their values, the current program counter ("PC"), the name of
the current method call, the current continuation, the set of handlers that
must run before the capture completes, and a home capture (the capture in
which this capture was created).

### 1.2 Two literal forms

- Regular: `local(cap) = { /* ... */ }`
- Auto-collect: `local(cap) = {^ /* ... */ ^}` — "concatenates the result of
  calling the `asString` method on every value produced inside the capture
  when the capture is executed," retrieved via `capture->autoCollectBuffer`.

Both confirmed real (not Lasso-8-only or hypothetical) — Query Expressions'
`do` clause explicitly reuses both forms.

### 1.3 The association operator `=>` and "capture block"

> "Captures can also be manually created by using curly braces as an
> expression. When using the association operator (`=>`) to invoke an object
> by passing it a capture, the capture is known as the object's associated
> block or capture block."
>
> ```
> #ary->forEach => {
>    // ... a capture of the surrounding code ...
> }
> ```

Critically, `=>` is **not** `forEach`-specific. `control-flow.html` states,
verbatim, of `if`/`match`/every loop construct: "The second form uses the
association/code block syntax," e.g. `if(expression1) => { ... }`,
`while(expression) => {...}`, `loop(5) => {...}`, `iterate(#lv) => {...}`.
**In real Lasso, `if`/`while`/`loop`/`match`/`iterate` are not special
grammar — they are ordinary built-in methods invoked with an associated
capture block, the exact same mechanism as `forEach`.** This is the single
most important structural fact this pass surfaced (see §4.1).

### 1.4 Invocation, parameters, `givenBlock`

> "Captures are executed by calling their `invoke` method:
> `#cap->invoke // Invoke the capture` / `#cap() // Shorthand invocation`"

Parameters arrive via positional special locals (`#1`, `#2`, ...). A method
that receives an associated block accesses it via the `givenBlock` keyword,
not a normal parameter — demonstrated in Query Expressions' `trait_queriable`
worked example:

```lasso
public forEach() => {
   local(gb) = givenBlock
   #gb->invoke('Krinn'='Jones')
   ...
}
```

### 1.5 Closure semantics — the hardest question, answered directly

> "Stored captures can be executed at any point and the code contained within
> will operate as if it had been executed in the context in which it was
> created. This means that it will have access to the surrounding local
> variables where the capture was created even when the capture is being
> executed in code that has a different scope."

Worked example (the load-bearing citation for the whole architecture
question):

```lasso
define method1 => {
   local(my_local)
   local(my_cap) = {
      #my_local->append(#1)
   }
   #my_local = 'Hello'
   method2(#my_cap)
   return #my_local
}
define method2(cap::capture) => {
   #cap(', world.')
}
method1
// => Hello, world.
```

**This is genuine live-reference closure semantics**, not snapshot-at-creation:
`#my_local` is mutated by `method2` reaching back into `method1`'s
already-returned-into local scope through the passed capture, and the
mutation is visible when `method1` itself later reads `#my_local`. A
snapshot-at-creation implementation would not reproduce this — the docs'
own canonical example rules snapshot semantics out as "correct," see §4.2.

Crucially: **`define`d methods' own automatically-created captures have no
home** — "Captures created automatically based on the invocation of a method
will not have a home." Closure-by-reference applies only to a **manually
created** `{...}`/`{^...^}` capture literal (which always has a home), never
to an ordinary method body reaching back further than its own caller.

### 1.6 `yield` / `return` / `detach` / `yieldHome` / `returnHome`

> "Captures can produce values by using `yield` or `return`. Both `yield` and
> `return` halt the execution of any of the capture's remaining code and
> produce the specified value... A `return` will reset the capture's PC to
> the top while a `yield` will not modify the PC... A capture that has been
> yielded from will begin executing immediately after the expression that
> caused it to yield."

```lasso
local(cap) = {
   yield 1
   yield 2
   yield 3
   yield 4
}->detach

#cap()  // => 1
#cap()  // => 2
#cap()  // => 3
#cap()  // => 4
#cap()  // => 1   // Capture reached the end and reset
```

Non-local return/yield through nested captures without a home boundary:

> "Because captures are intended to execute as if they had been invoked
> directly within their home, `return` and `yield` will both behave by
> exiting from the current home as well as itself. This is known as a
> **non-local return**."

```lasso
define contains(a::array, val) => {
   #a->forEach => {
      #val == #1 ?
         return true // This return is non-local
   }
   return false
}
```

`detach` escapes this: "detaches the capture from its home ... returns
itself." `yieldHome`/`returnHome` do the inverse. The docs note
`loop_continue`/`loop_abort` "both rely on using these forms" internally in
real Lasso.

### 1.7 `currentCapture()` and the `capture` type's full method table

- `currentCapture()` — "Returns a reference to the capture that is currently
  executing."
- `capture->invoke(...)`, `->detach()`, `->restart()`, `->continuation()`,
  `->home()`, `->callSite_file()`/`->callSite_line()`/`->callSite_col()`,
  `->callStack()`, `->givenBlock()`, `->autoCollectBuffer()`/`=(value)`,
  `->calledName()`/`->methodName()`, `->invokeAutoCollect(...)`.

### 1.8 Method Escaping (`\identifier`, `->\identifier`) — related but separate

`operators.html`: `\meth` / `#lv->\meth` produce a **`memberstream`** object,
not a capture — it names an already-defined method/tag by reference, with no
anonymous-block-literal or closure-over-locals concept. This directly
resolves an open question `collections-subsystem-plan.md` §3.3 left hedged
(it guessed `\TagName` was "very likely" this mechanism without a confirmed
citation) — now confirmed: `\identifier` is real Lasso 9's documented Method
Escaping operator, and `TagReference.swift`'s existing implementation is a
correct, if narrower, instance of it — not a Captures-adjacent guess.

### 1.9 Query Expressions — layered on Captures, confirmed

`with variable_name in source [, ...]`, optional `where`/`let`/`skip`/`take`/
`order by [ascending|descending]`/`group ... by ... into ...`, one terminal
action: `select`/`do`/`sum`/`average`/`min`/`max`. The `do` action: "consists
of the word `do` followed by either a single expression or a capture using
either the regular curly brace form (`{ ... }`) or the auto-collect curly
brace form (`{^ ... ^}`)... **The block of code given to a `do` remains
attached to the surrounding method context, such that one could `return` or
`yield` or access and create local variables.**" This IS this codebase's
existing `with x in y do {...}` construct's real full name and real full
scope — a stripped-down special case of one action of a full query
expression, missing every operation clause and the other four actions.

`GenerateSeries` (`generateSeries(from, to, by=1)`, literal `2 to 11 by 2`)
produces an integer series usable in a `with` clause. Making a type queriable
needs `trait { import trait_queriable }` + a `forEach` member method invoking
`givenBlock` per element (the exact shape any future `->forEach` work needs
to match).

### 1.10 `onCompare`/`invoke` type-level callbacks — adjacent, not Captures

`invoke` — auto-called when `()` is applied to an object; `onCompare` —
auto-dispatched by `==`/`!=`/`<`/etc. Both real, general implicit-callback
mechanisms, and `onCompare` is already `collections-subsystem-plan.md`'s own
flagged highest-risk open item. `invoke`-on-user-types is a new, adjacent,
previously-untracked small gap surfaced by this pass.

## 2. Current Implementation Cross-Reference (grep-verified)

- **`with x in y do {...}`** — hand-rolled text-pattern parsing, not general
  capture/association machinery. `ScriptBodyParser.swift:475-525`
  (`parseWithOpening`) scans for the literal keyword sequence and emits a
  fixed `.tag(name: "with", ...)` node; its own doc comment already discloses
  this. Execution (`Renderer.swift:329-352`) is Swift-side control flow over
  `[LassoNode]` — **no `LassoValue` of any kind is ever produced for the
  body**, nothing is reified as a storable/invokable value.
- **`if`/`while`/`loop`/`match`/`iterate`** — same architecture: each is its
  own hardcoded AST `.block(name:...)` node (`Syntax.swift:171-184`) and its
  own `case` in `Renderer.render`'s switch. Per §1.3, real Lasso treats all
  of these as one mechanism; this codebase independently reimplements each.
  Bare-form auto-collection already happens to match auto-collect-capture
  semantics by direct string accumulation — accidentally, not by design.
- **`=>` tokenization** — real but narrow. `ExpressionParser.swift:75` lexes
  it, but the `precedence` table (line ~657) has no entry for it — never
  consumed as a general infix operator. Only consumed at fixed statement-level
  positions hardcoded in `ScriptBodyParser.swift` (lines 385, 809, 857, 947)
  and `TypeBodyParser.swift:110`. **A general
  `#ary->forEach => { ... }`-shaped expression cannot parse today.**
- **`LassoValue`** (`Runtime.swift:11-28`) — confirmed `indirect enum`, no
  `.capture` case, no block/callback-shaped case of any kind.
- **`LassoCustomTagDefinition`** (`TagRegistry.swift:3-13`) — the only
  existing precedent for "store a deferred block of Lasso code," but always
  *named* (looked up by string) and always invoked in a *fresh* scope — maps
  onto real Lasso's automatically-created, homeless method captures (§1.5)
  correctly, but has no analogue for a manually-created `{...}` literal with
  a home.
- **`Evaluator.invokeCustomTag`** (`Evaluator.swift:283-312`) — the mechanism
  a general `capture->invoke` would need to generalize from: evaluate args →
  bind into fresh locals → `snapshotLocals()`/`replaceLocals()` (whole-
  dictionary swap) → render body → restore via `defer`. `if`/`while`/`with`
  bodies never call this at all (render inline in the *same* locals
  dictionary) — which is why `return` inside `if(...) { return X }` already
  correctly propagates out through the whole enclosing method today,
  matching real Lasso's non-local-return rule for homed captures — by
  accident of implementation, not capture-aware design.
- **`LassoContext`** (`Runtime.swift:1721+`) — a Swift **struct** (value
  type), `locals: [String: LassoValue]` is one flat dictionary, no nested
  scope-frame stack. `snapshotLocals()`/`replaceLocals(_:)` (lines
  2116-2122) are the entire scoping primitive. **This is the central
  architectural fact for the closure-semantics decision (§4.2)**: because
  `LassoContext` is a value type with no per-variable indirection, two
  different copies (a stored capture snapshot vs. the enclosing method's
  continuing execution) cannot observe each other's later mutations to the
  same named local. Identical structural fact to the `@`/`[Reference]` gap's
  own explicit punt.
- **`TagReference.swift`** — confirmed a real, working instance of Method
  Escaping (§1.8), not a guess.
- **`LassoTagInvocationService`** (`Providers.swift:555-606`) — the closest
  existing precedent for "invoke stored Lasso code later with fresh
  arguments," but its own doc comment discloses it's "deliberately NARROWER
  than `Evaluator.invokeCustomTag`." Solves "invoke an existing named tag,"
  closer to Method Escaping than to a Captures literal — does not solve
  anonymous block literals, closures, or `yield`/`detach`.
- **`Set->ForEach`/`->InsertFrom`** — confirmed still unimplemented.
  `Collections.swift:330-339`'s own comment speculatively scoped this as
  maybe-solvable via `\TagName` — per §1.9's real docs, `forEach` needs a
  genuine capture block, not a `\TagName` reference, so this deferral is
  **not** actually unblocked by the already-shipped `\TagName` work.
- **`invoke`/`onCompare` type-callback dispatch** — confirmed absent (zero
  hits in `TypeSystem.swift`/`Evaluator.swift`'s user-type dispatch).

## 3. Real Corpus Usage Evidence

Grep'd `/Users/timtaplin/scrubsSite` (882 files) and
`/Users/timtaplin/Documents/scrubs9` (935 files) directly, file-by-file.

| Pattern | scrubsSite | scrubs9 |
|---|---|---|
| `->invoke` | 2 files | 0 |
| `yield` | 0 | 0 |
| `detach` | 0 | 0 |
| `->forEach` | 7 files | 0 |
| `->eachCharacter`/`eachWordBreak`/`eachLineBreak`/`eachMatch` | 0 | 0 |
| `with IDENT in ... do` | 16 files (real) | 6 files (3 real, 3 false-positive prose) |
| `currentCapture` | 3 files | 0 |
| `=>` (any use, incl. already-implemented forms) | 33 files | 12 files |
| `order by` | 8 files | 6 files — all confirmed raw SQL text inside `-SQL=` strings, not Lasso syntax |
| `group...by...into` / `select #` / `generateSeries` / `trait_queriable` / `eacher(` | 0 | 0 |

Every genuinely live-page/include/component `=>` hit resolves to already-
implemented forms only (`define X(...) => {...}`, `if(...) => {...}`, etc.) —
zero instances of `objectExpr->method => {...}` (general capture-block
association) anywhere in live site code.

**All 7 `->forEach` hits and all 3 `currentCapture` hits, plus the entire
sophisticated `->invoke`/`givenblock` cluster, live exclusively inside
`scrubsSite/lassoBackup/scrubs/LassoApps/ds/`** — e.g.:

```
lassoBackup/scrubs/LassoApps/ds/ds.lasso:1173:
   ds(dsinfo->extend(:#rest || staticarray),true,params)->silent(true)->invoke => givenblock
```

A real, sophisticated `ds` datasource-abstraction LassoApp genuinely exercises
`->invoke`, `givenblock`, `currentCapture`, and general `=>` association — but
it is almost certainly dead code, not live corpus: (1) it lives under
`lassoBackup/`, a full backup snapshot (siblings: `LassoApps_disabled`,
`LassoStartup_disabled`, `LassoLibraries_disabled`); (2) zero matches
anywhere outside `LassoApps/ds/` for `ds(`/`ds_row`/`ds_result` call sites —
nothing in the live pages/includes/components tree calls into it; (3)
entirely absent from `scrubs9`, which otherwise substantially overlaps
`scrubsSite`'s live set.

**The only confirmed-live, actively-exercised Captures-family construct
anywhere in either corpus is `with p in #x->split('&') do { ... }`** (e.g.
`components/paypal_express.inc:36,67,97`, present in both corpora) — which is
**already fully implemented**.

## 4. Architectural Decisions

### 4.1 Do not unify `if`/`while`/`loop`/`match`/`iterate`/`with` under real Captures

Real Lasso treats all six as one mechanism; this codebase implements six
independent special cases. Structurally truer would be to unify them, but
**recommendation: do not.** All six are already implemented, tested, and
§3 shows zero corpus evidence any is missing observable behavior a real
unification would fix. Add Captures, if built at all, as new, additive,
non-invasive machinery alongside them — same posture the Collections plan
already took for `with...do` vs. built-in Comparators.

### 4.2 Closure semantics: real Lasso requires live-reference, and this codebase's storage model cannot cheaply provide it

§1.5's worked example is unambiguous, direct primary-source evidence of
genuine reference-typed closure — no reading permits snapshot-at-creation as
"a merely narrower but still correct" cut; it would produce an observably
wrong result on the docs' own canonical example. Per §2, `LassoContext.locals`
has no per-variable indirection anywhere — providing real closures needs
either:

- **(a) Per-variable boxing** — locals become `class Box { var value:
  LassoValue }` cells; a capture stores references to the boxes for names it
  closes over. Same shape of storage-indirection layer the `@`/`[Reference]`
  work explicitly declined to build, with an ongoing performance/complexity
  cost on every local read/write, not just capture-adjacent ones.
- **(b) Scope-object indirection** — replace/supplement `LassoContext.locals`
  with a reference-typed scope chain (`final class LassoScope { var values:
  [String: LassoValue]; let parent: LassoScope? }`); a capture stores a
  strong reference to its home's scope. Smaller blast radius at the point of
  variable access, but still a genuinely new architectural layer replacing
  the flat-dictionary-on-a-value-type-struct model everything else in this
  codebase currently assumes.

Neither is a routine addition; both are comparable in kind to the
`@`/`[Reference]` deferral.

### 4.3 `with...do` should NOT be refactored onto general Captures

Fully correct for its one real corpus pattern already; a refactor buys
nothing observable per §4.1. Leave it exactly as-is even if Captures gets
built later for other reasons.

### 4.4 A narrow, snapshot-semantics first cut is architecturally possible, but doesn't serve any real consumer today

Unlike the Comparator precedent (built-ins shipped as free tags before the
real `\TagName` syntax existed, serving a real, already-evidenced need), a
snapshot-semantics `forEach` here would be scoping work in search of a
consumer — `Array->forEach`, the `eachXxx` family, and full Query Expressions
all show **zero** corpus hits, not just lower priority.

## 5. Staged Implementation Plan (if pursued — see §7 for whether/when)

**Stage 1 — `.capture` value + literal parsing + non-closure invoke** ✅ done
(2026-07-21) — `LassoValue.capture(LassoCaptureValue)` (an immutable class:
`body: [LassoNode]`, `autoCollect: Bool`, `capturedLocals` snapshot — no PC/
yield-position slot yet, that's Stage 2). Parser: `{...}`/`{^...^}` recognized
as a primary expression via a brace-balanced, quote-aware raw-text scan
(`ExpressionLexer.readCaptureBody`) feeding the same `ScriptBodyParser`+
`BlockBuilder` two-pass every other nested block body already uses; `=>`
recognized as a genuine trailing modifier on any call-shaped expression (not
just the six already-hardcoded keywords). `capture->invoke`/`#cap()`
shorthand, positional `#1`/`#2`/... binding, snapshot semantics only
(disclosed). 670/670 tests passing.

**Design correction found by architect re-review, before merge**: the
original sketch above ("supplying a capture as `givenBlock`") was under-
specified in the FIRST implementation — the capture was folded as an
ordinary UNLABELED trailing positional argument, not through any real
`givenBlock` channel. This shipped a genuine bug: whenever a call provided
FEWER explicit arguments than the callee declared parameters (a completely
normal shape relying on trailing optional/default parameters), the appended
capture would silently land in and overwrite that later parameter's slot
instead of being kept separate — and when the explicit argument count
already matched exactly, the capture was silently dropped with no signal at
all. Fixed properly, not just guarded: the capture argument is labeled
`"givenblock"` at fold time (`ExpressionParser.foldAssociatedCapture`), and
a new `Evaluator.extractGivenBlock` helper pulls it out of the evaluated
argument list — before it ever reaches `bindParameters`/
`LassoMethodDispatcher.resolve` — threading it instead through a genuine new
per-call context slot (`LassoContext.givenBlockStack`, mirroring
`selfStack`'s own push/pop-per-invocation discipline) that the invoked body
reads back via a real, bare (no `#`/`$` sigil) `givenBlock` identifier,
matching the real Language Guide's own documented contract exactly ("A
method that receives an associated block accesses it via the `givenBlock`
keyword, not a normal parameter"). Verified decisive by reverting the label
change in an isolated copy and confirming the regression test (`association
OperatorDoesNotCorruptATrailingOptionalParameterWhenFewerExplicitArgumentsA
reGivenThanDeclared`) fails exactly as predicted (`"5|capture"` instead of
`"5|"`).

Unblocks nothing in the corpus by itself; structural prerequisite for every
later stage — Stage 4's `->forEach` work will read its own associated block
via this same `givenBlock` mechanism, matching the real docs' own
`trait_queriable` worked example (`local(gb) = givenBlock`) exactly rather
than needing its own separate design.

**Stage 2 — `yield`/`return`/`detach`/`restart`/PC semantics.** New
control-flow state distinct from the existing one-shot
`clearReturnSignal`/`consumeReturnSignal` pair (assumes complete-or-return,
never pause-and-resume). Non-local return/yield through homed nested
captures needs a new signal-propagation path.

**Stage 3 — live-reference closure semantics.** Pick and implement §4.2(a)
or (b). By far the largest and riskiest single stage — see §7.

**Stage 4 — `->forEach` (array/list/set/etc.) + `Set->ForEach`/
`->InsertFrom`.** Once Stage 1 exists, wire to invoke the associated capture
once per element, matching §1.9's worked example shape. Directly closes
`Collections.swift:330-339`'s disclosed deferral. Needs only snapshot
semantics (Stage 1) — could ship right after Stage 1, deferring Stages 2/3.

**Stage 5 — string iteration family** (`->eachCharacter`/`->eachWordBreak`/
`->eachLineBreak`/`->eachMatch`). Same mechanism as Stage 4, applied to
`StringOperations.swift`.

**Stage 6 — predicate-taking `->find(matching)`.** Needs Stage 1 only.

**Stage 7 — `currentCapture()`/`givenBlock`/introspection family.** Low
corpus need; bookkeeping once Stage 1-2 exist.

**Stage 8 — Query Expressions** (`where`/`let`/`skip`/`take`/`order by`/
`group by`/`select`/`sum`/`average`/`min`/`max`, `generateSeries`,
`trait_queriable`, `eacher`). Largest new-parser-surface stage; gated on
Stage 1 (strict superset of already-implemented `with...do`) and, for full
nested-control-flow correctness, Stage 2.

## 6. Deferred, With Reasoning

- **Everything in §5 as a whole** — see §7; not merely sequenced carefully,
  not recommended to start at all given current corpus evidence.
- **Repeated-invocation accumulation across calls** — architect re-review of
  Stage 1 flagged, concretely, that real Lasso's live-reference semantics
  mean a stored capture invoked repeatedly (e.g. inside a `forEach`-style
  loop) naturally accumulates state, since there's only ever one real copy of
  the variable being mutated — exactly the shape of the real corpus example
  motivating Stage 4 (`#AIMParams->forEachPair => { #AIMParamArray
  ->insert(...) }`, accumulating into `#AIMParamArray` across iterations).
  Stage 1's `capturedLocals` snapshot is an immutable `let` set once at
  construction, so each invocation starts fresh from the same unchanged
  snapshot — this specific real corpus idiom will NOT work correctly even
  once Stage 4's `->forEach` exists, until a later stage makes closure
  semantics genuinely live-reference (§4.2/Stage 3), not just this one
  particular narrow case. Not a new gap — the same already-disclosed §4.2
  limitation — but worth this concrete illustration for whoever picks up
  Stage 4, so the exact real corpus line that motivated it doesn't get
  assumed-working without checking.
- **`capture->autoCollectBuffer()`** (Ch. "Captures" §1.7) — documented but
  not implemented; Stage 1's `invokeCapture` approximates auto-collect
  semantics by returning the body's own rendered output directly as the
  invocation's return value, without a separately-retrievable buffer
  property. Low priority — no corpus evidence for the explicit-retrieval
  form specifically, only for auto-collect capture invocation itself
  (already covered).
- **`invoke` type-level callback and `onCompare` auto-dispatch** — real,
  documented, but a distinct implicit-callback architecture, not Captures
  itself. `onCompare` already tracked as the Collections plan's own
  highest-risk item; `invoke`-on-user-types is a new, adjacent, previously-
  untracked small gap — worth a one-line addition to that plan's deferred
  list, not scoped here.
- **`LassoApps/ds`'s specific usage** — not worth targeting directly; dead/
  vendored code with zero live call sites.
- **Method Escaping's dynamic-name form** (`#lv->\(meth + 'name')`) — real,
  documented, separate from both Captures and the shipped static-name
  `\TagName`; no corpus evidence either; flag as its own small item if
  `TagReference.swift` is ever revisited.

## 7. Risk Assessment

1. **Highest risk: live-reference closure semantics (§4.2/Stage 3).** Real
   documented semantics collide head-on with this codebase's core value-
   type/flat-dictionary scoping model having no precedent for it — the exact
   same wall the `@`/`[Reference]` work hit and declined to climb.
2. **Real, contained risk: general `=>`-as-expression-operator parsing
   (Stage 1).** Regression surface across already-tested, high-traffic
   parsing code (`if`/`while`/`loop`/`match`/`iterate`/`define` all
   currently depend on the current narrow behavior).
3. **Moderate, well-precedented risk: non-local return/yield propagation
   (Stage 2).** New plumbing, but extends an existing, understood pattern
   rather than inventing from nothing.
4. **Low risk, routine once Stage 1-3 land: `->forEach`/`eachXxx`/
   predicate-`find` (Stages 4-6).**
5. **Separately tracked: `onCompare` auto-dispatch** — already the
   Collections plan's own flagged highest-risk item; confirmed still open,
   still genuinely different in kind.

## 8. Recommendation

**Do not build the Captures subsystem now** — for a stronger reason than the
`@`/`[Reference]` precedent. `@`/`[Reference]` had a documented feature with
no confirmed consumer either way. Captures has an *actively negative*
signal: a full, direct, file-by-file grep of both corpora (1,817 files) shows
**zero** live usage of anonymous capture syntax, `yield`, `detach`,
`currentCapture`, `forEach`, any `eachXxx` string-iteration method, or any
real query-expression clause beyond the already-implemented `with...do`. The
one place sophisticated, correct capture-family code genuinely exists in the
corpus (`LassoApps/ds`) sits in a backup snapshot with no confirmed live call
site anywhere — the opposite of the pattern that has justified every other
batch of work this project has done.

The downstream gaps Captures would unblock (`forEach`, `eachXxx`, predicate-
`find`, Query Expressions) show no corpus urgency either — so even a
deliberately narrow first stage doesn't currently have a real gap to unblock.
Building Stage 1+4 (snapshot captures + `->forEach`) would be scoping ahead
of evidence, not behind it.

**If this changes** — a new corpus sample surfaces real `forEach`/query-
expression usage, or a specific site feature is found to need it — the right
entry point is Stage 1 → Stage 4, deferring the genuinely hard closure-
semantics work (§7 item 1) until something concrete actually requires
live-reference behavior. Until then, this should stay scoped-but-unstarted,
re-audited the next time this project does a corpus-usage sweep.

## Files Referenced

- `https://lassoguide.com/language/captures.html`, `/language/query-expressions.html`, `/language/operators.html`, `/language/control-flow.html`, `/language/methods.html`, `/language/types.html` (Lasso 9.3, fetched directly)
- `/Users/timtaplin/Perfect-Lasso/References/Lasso/Lasso 8.5 Language Guide.pdf` (confirmed zero Captures coverage)
- `/Users/timtaplin/Perfect-Lasso/Documentation/{lasso9-lassoguide-gap-analysis-plan,lasso85-gap-analysis-plan,collections-subsystem-plan}.md`
- `/Users/timtaplin/Perfect-Lasso-captures/Sources/LassoParser/{Runtime,Evaluator,ExpressionParser,ScriptBodyParser,TypeBodyParser,Renderer,TagCatalog,TagRegistry,TagReference,Collections,Syntax,Providers}.swift`
- `/Users/timtaplin/scrubsSite`, `/Users/timtaplin/Documents/scrubs9` (corpus grep, both file-by-file)

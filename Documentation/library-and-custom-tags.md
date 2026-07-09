# Library Loading And Custom Tags

Date: 2026-07-09

## Finding

Real Lasso code depends on `library(path)` and `define`d custom tags as a
baseline requirement — the corpus crawl found `define` in the real
codebases, and `library('/_begin.lasso')` plus a custom tag were exactly
what blocked the real page used for dev-server smoke testing. Neither had
any support before this work; `library(...)` threw `unknownFunction`, and
`define` either failed to parse (script mode) or silently dropped the tag's
name and parameters (bracket dialect, a real pre-existing bug, unrelated to
script mode).

## Scope note: what "compiled" means here

This interpreter is a tree-walking evaluator — the project chose that
architecture (Option A in the top-level project notes) over a bytecode VM.
"Compiled" here means *parsed once into a reusable AST, stored in a shared
registry* — not lowered to bytecode or Swift. A `define`d tag's body is
parsed exactly once, at definition time; every call afterward walks that
same cached `[LassoNode]` tree rather than re-parsing source text. That is
the standard and correct behavior for this class of interpreter.

## Sharing model

`LassoTagRegistry` (`Sources/LassoParser/TagRegistry.swift`) is a
thread-safe, lock-protected store for compiled tag definitions and the set
of library paths already loaded. `LassoContext` always has one — a fresh,
private instance by default (so `define`/custom tags work standalone, with
zero extra wiring, in smoke tests, fixtures, or any single-page use) — but
`LassoSiteServer` constructs exactly one `LassoTagRegistry` per process and
threads that same instance into every request's `LassoContext`. That one
line of sharing is what makes tags compile once and stay callable for the
lifetime of the server process, across every request and every site path it
serves — not just within one request.

## Concurrency model

`LassoTagRegistry` is a `final class ... : @unchecked Sendable` guarded by a
plain `NSLock`, not a Swift actor, matching the pattern this codebase
already used for other shared mutable state (`ServerResponseSink`,
`SmokeSessionProvider`). An actor was considered and rejected: the entire
evaluate/render call chain (`LassoRenderer`, `Evaluator`, `RendererEngine`)
is synchronous `throws` today, with no `await` anywhere — routing every tag
lookup and include-cache check through actor isolation would force `async`
through that whole chain for a data structure whose actual critical
sections (dictionary/set reads and writes) are trivially short. A lock is
the surgical fit; revisit only if this registry's access patterns grow
performance-sensitive enough that lock contention becomes measurable.

## Why `Evaluator` can render a tag body

`Evaluator` only evaluates expressions — it has no concept of rendering a
list of `LassoNode`s into text; that capability belongs to `RendererEngine`
in `Renderer.swift`, which already wraps an `Evaluator` for its own
expression sub-evaluation. Calling a custom tag needs the reverse direction
too: `Evaluator.evaluate(.call)` has to run a tag's `body: [LassoNode]` and
get text back. Rather than merging the two types (a much larger refactor)
or hand-rolling a second, cut-down node walker inside `Evaluator`,
`RendererEngine.init` injects a closure — `evaluator.renderNodes = { nodes,
context in ... }` — that spins up a nested `RendererEngine` and returns its
output. This breaks the circular dependency with a single closure property
instead of restructuring either type.

## `library(path)`

Handled the same way `include` is — intercepted directly in the renderer
(it needs the include loader plus the ability to render the loaded source,
which a plain native-function closure can't do). On each call:

1. `LassoTagRegistry.markLibraryLoaded(path)` — `false` means this path was
   already processed (by this request or any earlier one sharing the same
   registry); return immediately. This is the caching fast path — no
   re-read from disk, no re-parse, no re-execution.
2. Otherwise, load and render the source once. This executes any `define`
   blocks it contains (registering them, see below) plus any other
   top-level code the library has. The library's own text output, if any,
   is discarded — library files aren't meant to inject visible HTML; only
   the registry side effects (registered tags, one-time setup code having
   run) persist.

## `include(path)` — cached differently than `library`, on purpose

The key difference: an `include` can produce output on every use (its
content commonly depends on the current page's variables, loop position,
request params, and so on), where a `library` never does — nothing about a
library's use ever surfaces in the page. That difference means `include`
cannot use the same "process once, ever" gate `library` uses; instead it
caches the *parse*, not the *result*:

1. `include` always reads the source via the configured `LassoIncludeLoader`
   on every use — there's no other way to detect whether the underlying
   file changed since last time, since the loader protocol exposes no
   separate staleness signal (no mtime, no hash, no `Sendable`-safe file
   handle) — just `loadInclude(path:from:) throws -> String`.
2. The freshly read source is compared against what's cached (keyed by
   `includingPath` + `path`, since relative-path resolution is
   context-sensitive — the same relative string can mean a different file
   depending on where it's included from). An identical match skips
   re-parsing (`LassoParser().parse(...)`, plus the `BlockBuilder` pairing
   pass) and reuses the cached `LassoDocument`. A mismatch — the file
   changed, or this is the first time this key has been seen — reparses and
   updates the cache.
3. Either way, the (cached or freshly parsed) document is rendered fresh for
   this call site, every time. Re-parsing is what gets skipped, not
   re-rendering — reusing a rendered *string* across uses would silently
   ignore context that legitimately differs per call site.

The cache has no eviction and no size bound, matching the existing tradeoff
already accepted for `library`'s loaded-path set — sites with a very large
number of distinct include paths over a long-running process trade memory
for the reparse savings. No known real-world corpus size has approached
where this would matter in practice.

## `define name(params) => { body }`

Recognized in both syntactic forms found in the corpora:

- **Script mode** (`<?lassoscript ?>`, the dominant real-world shape):
  parsed directly in `ScriptBodyParser` via a dedicated
  `parseDefineOpening()` — reads the name, optional `(...)` parameters
  (default values supported, e.g. `#greeting = 'Hello'`), an optional
  `::type` return annotation (accepted, ignored), then a balanced `{ }`
  body. The extracted body is parsed recursively (`ScriptBodyParser` calling
  itself) and then run through the same `BlockBuilder` pairing pass the
  top-level parser uses, so nested `if`/`loop`/etc. inside a tag body work
  correctly — recursively parsing alone only produces a flat open/close-tag
  stream; it does not pair them into nested blocks by itself.
- **Bracket dialect** (`[define tagname(params)] ... [/define]`): fixed a
  real bug where the existing tag-detection logic only inspected the first
  parsed expression, which for this input is the bare keyword `define` —
  `tagname` and its parameters were silently dropped. The block's reported
  `name` stays the literal `"define"` keyword (so `[/define]` pairing keeps
  matching unchanged); the real tag name travels as a synthetic first
  argument, giving both dialects the same shape for the renderer to handle
  uniformly.

Encountering `define name(...) => { ... }`, the renderer registers the
definition (name, parameter list, body — none of it evaluated yet) into
`context.tagRegistry` and produces no output. Nothing executes until the tag
is actually called.

A malformed `define` (keyword matched but no name, no `=>`, or no `{`
follows) falls back to treating it as ordinary code — same recovery
behavior as before — but now also records a diagnostic
(`ScriptBodyParser.diagnostics`, e.g. "Malformed 'define': expected a tag
name") instead of failing silently. `ScriptBodyParser` collects diagnostics
generally now; see `Documentation/lasso-perfect-server.md` for the rest
(unterminated brace bodies, stray closing braces, and the general
arrow-brace block-closing mechanism this diagnostics work accompanied).

## Calling a compiled tag

A call to an undefined native function falls back to a `tagRegistry` lookup
before finally throwing `unknownFunction`. On a hit:

- **Parameter binding**: label match first (named arguments), then
  positional, then the parameter's own default-value expression (evaluated
  at call time, not definition time), then `.null` if none of those apply.
- **Local-scope isolation**: the caller's `#locals` are snapshotted and
  replaced with a fresh dictionary seeded from the bound parameters before
  the body runs, then restored afterward (via `defer`). A tag setting its
  own `#result` can never leak into or clobber a caller's same-named local.
  `$globals` are unaffected — they remain shared across calls, matching real
  Lasso.
- **`return`**: sets a signal on the context rather than throwing (a thrown
  error would lose whatever output had already accumulated in the enclosing
  render loop on unwind). Every node-rendering loop checks the signal after
  each node and breaks early, so the signal naturally propagates up through
  nested `if`/`loop`/tag-body structures with no extra plumbing — a `return`
  several `if`s deep inside a tag body correctly unwinds all the way back to
  the call site. The call site is where the signal is consumed and cleared,
  becoming that call's result value (`.void` if the body never hit
  `return`). A `return` at page/include level (not inside a called tag)
  still contributes its value to the page's output, preserving the existing
  `<?lassoscript ... return json_serialize(...) ?>` API-page pattern.
- **Recursion depth guard**: capped at 20 nested tag calls
  (`LassoRuntimeError.tagCallDepthExceeded`), mirroring the existing
  32-deep include-cycle guard, so a runaway recursive tag definition fails
  cleanly instead of crashing the process. This started at 64 but was
  lowered after the real `swift test` suite (see
  `Documentation/swift-test-codesign-workaround.md`) caught what the
  command-line smoke executable couldn't: a 100-level recursive tag call
  overflowed the C stack outright before the 64-level guard's own check
  ever fired, because each level of tag-call recursion here costs several
  real Swift stack frames — the `renderNodes` closure, a fresh
  `RendererEngine`, the `Evaluator` call chain — not one, and an XCTest
  worker thread has a smaller default stack than a plain executable's main
  thread. 20 was chosen for real margin, not as the largest number that
  happened to survive testing.

## Explicitly out of scope for now

- **`define Foo => type { ... }`** — Lasso 9 object/type definitions
  (properties, `self`, method dispatch on instances). The parser detects and
  safely skips this shape (consumes the balanced body, registers nothing) so
  it doesn't crash the surrounding page, but the type/method model itself is
  not implemented. Full object-model support is a materially larger,
  separate feature.
- **Lasso 8 `define_tag`/`define_type`** legacy syntax — not observed with
  real frequency in the gathered corpus evidence (`define`: 12 sightings
  total in the first corpus, see `compatibility-matrix.md`).

# The Synchronous Render Pipeline

Date: 2026-07-14

## Current shape

`LassoRenderer.render(_:context:)` and everything it calls —
`Evaluator`, `RendererEngine`, `LassoInlineProvider.executeInline(_:)`,
`LassoDynamicQueryExecutor.execute(_:)`, every native tag in
`Runtime.swift`/`NativeTypes.swift` — is plain, synchronous Swift. No
`async`, no `await`, anywhere in that call graph. A Lasso page's
top-to-bottom, single-threaded evaluation model maps directly onto a
single Swift call stack.

The one place this touches async code at all is at the very top:
`LassoSiteServer.render(fileURL:request:includePath:postBody:)`
(`Sources/LassoPerfectServer/main.swift`) is `async throws` (it's a
Perfect-NIO route handler), reads the request body and does session
preflight with real `await`s, then calls the fully synchronous
`LassoRenderer().render(document, context: &context)` inline, in the
middle of that async function, and keeps going. Nothing hands the
render off to a different thread or execution context — it just runs,
synchronously, on whatever thread the async function's continuation
happened to resume on.

## Why it's built this way

This wasn't an oversight — a few real constraints pushed toward
synchronous:

- **Semantic fit.** Real Lasso 8.5 has no concurrency model of its own;
  a page runs top to bottom on one thread. A synchronous interpreter is
  the direct, low-risk port of that semantics — every native tag,
  `[inline]` call, and custom-tag invocation composes as an ordinary
  function call, with none of `async`'s coloring problem (a function
  becomes `async` and that's contagious up its entire caller chain).
- **MySQL's own connector never needed it.** `PerfectCRUD`'s
  `Database.select(query)`/`.mutate(_:)`/`.execute(_:)` are themselves
  synchronous, blocking C-level calls (via `PerfectMySQL`). There was
  never an `async` API on the other end of `PerfectCRUDLassoExecutor`'s
  `queryHandler` to bridge to — the connector is exactly as synchronous
  as the pipeline calling it, no adaptation needed.
- **Session/upload I/O is already isolated at the boundary.** Where
  genuine `async` I/O already exists (session create/resume against
  `SessionDriver`, reading the POST body), it's deliberately done
  *before* the synchronous render starts (`LassoSessionPreflight.scan`
  + `sessionBridge.prepare(...)`, `readPostBody(...)`) — see
  `Documentation/session-upload-support-plan.md` and
  `Documentation/post-body-support-plan.md`. That's the same idea taken
  to its logical endpoint: keep `async` at the edges, keep the
  interpreter itself synchronous.

## What changed

The FileMaker datasource work (`Documentation/lasso-perfect-server.md`'s
FileMaker Datasource section) introduced the first backend whose
*native* API is `async`: the resurrected `Perfect-FileMaker` replaced
its blocking `PerfectCURL`/libcurl transport with `URLSession`'s
`async`/`await` API (`FileMakerServer.query(_:) async throws ->
FMPResultSet`). `PerfectFileMakerLassoExecutor`'s `queryHandler` closure
type stayed synchronous (matching the existing
`LassoDynamicQueryExecutor` protocol, which every executor implements),
so `main.swift`'s composition-root wiring has to bridge `async` down to
sync to call it — the first place this project has needed that bridge
at all.

The first version of that bridge (`Task { ... } ` + `DispatchSemaphore`,
run inline on whatever thread the synchronous render happened to be
executing on) turned out to be a real bug, not just an inelegance: see
the "Concerns" section below. It's being fixed by isolating the bridge
onto its own dedicated thread pool (tracked separately) — a targeted
fix, not a pipeline-wide change. This document is about the larger
question that fix deliberately does *not* answer: should the pipeline
itself become `async`?

## What an async pipeline would look like

The mechanical change: `LassoInlineProvider.executeInline(_:)` and
`LassoDynamicQueryExecutor.execute(_:)` (`Sources/LassoParser/Providers.swift`)
become `async throws`, `LassoRenderer.render(_:context:)` and everything
between it and those two call sites becomes `async` too (`Evaluator`,
`RendererEngine`, the native-tag closures that can reach an inline call
— which is most of them, since custom tags/includes/library calls can
all nest a `[inline]` inside). `PerfectCRUDLassoExecutor`'s `queryHandler`
would either stay synchronous internally (MySQL has no async API to
gain from this) or get wrapped the same way FileMaker's own bridge
works today, just moved to the call site instead of the executor.

## Advantages

- **Removes the bridge entirely**, for every future backend, not just
  this one. Any datasource whose real API is `async` (which is
  increasingly the default shape for new Swift networking/database
  libraries, including whatever gets resurrected next) plugs in
  directly — no semaphore, no thread-pool-isolation dance, no risk of
  re-introducing the exact deadlock this session just found and fixed.
- **Frees the cooperative thread pool during I/O.** A genuinely `async`
  FileMaker call suspends rather than blocks while waiting on the
  network — the thread it was running on goes back to the pool and
  serves other requests in the meantime. Under concurrent load, this is
  a real throughput win over the current synchronous-blocking model
  (which today affects both MySQL and, until fixed, FileMaker).
- **Matches where the rest of this codebase is already headed.** The
  request-handling layer, session I/O, and POST body reading are all
  already `async`; making the render pipeline `async` too removes the
  one remaining synchronous/asynchronous seam in the request lifecycle
  instead of leaving it as a permanent, load-bearing exception.

## Concerns and barriers

- **This is a real, wide-blast-radius refactor, not a signature tweak.**
  `async` is contagious: every function in the call chain from
  `LassoRenderer.render` down to a leaf native tag that can reach
  `[inline]` needs the keyword, and every *caller* of those functions
  needs `await`. Given how deeply custom tags/includes/libraries can
  nest arbitrary Lasso code (which can always contain an `[inline]`),
  in practice this means most of `Evaluator`/`RendererEngine`'s surface
  changes, not a small, contained subset.
- **Every native tag closure's signature changes.**
  `LassoNativeFunction` (`Runtime.swift`) is currently `@Sendable
  (_ arguments: [EvaluatedArgument], _ context: inout LassoContext)
  throws -> LassoValue` — a large registry of these
  (`registerDefaultFunctions()` alone is hundreds of entries) would
  need to become `async throws`, even though the overwhelming majority
  never touch I/O and gain nothing from it. That's a lot of mechanical
  churn for no behavioral benefit in the common case.
- **`context: inout LassoContext` and `async` interact badly.** Swift
  does not allow capturing an `inout` parameter in an escaping closure,
  and many of the `async` boundary-crossing patterns (dispatching work
  to a different executor, `withCheckedThrowingContinuation`) need
  exactly that. `LassoContext` would likely need to become a reference
  type (a class) or otherwise restructured before an async pipeline is
  practical — itself a nontrivial, independently-risky change (the
  interpreter currently gets real value from `LassoContext`'s
  value-type copy-on-write semantics for custom-tag-local scoping; see
  how `renderNodes`/`Evaluator` push and pop local scopes today).
- **Regression surface.** This interpreter's entire value proposition
  is faithfully reproducing real Lasso 8.5 semantics against a large
  real-world corpus (`Documentation/compatibility-matrix.md`,
  `Documentation/outstanding-compatibility-project-plans.md`). A
  refactor this wide touches nearly every render path at once — the
  kind of change most likely to introduce a subtle behavioral
  regression that only shows up against real corpus pages, not unit
  tests, and hardest to bisect after the fact specifically because it's
  one large mechanical change rather than many small semantic ones.
- **Unclear payoff at this project's current scale.** Every barrier
  above is a real cost paid immediately; the throughput benefit only
  matters under concurrent load this project doesn't yet have (no
  FileMaker deployment is live; MySQL's existing blocking calls haven't
  been reported as a bottleneck). Worth revisiting if/when concurrent
  load becomes a real, measured problem — not speculatively.

## Recommendation

Don't do this as a reaction to the FileMaker bridge bug. Fix the bridge
narrowly (isolate it to its own thread pool, keeping the rest of the
pipeline untouched) and treat a full async pipeline as a separate,
deliberately-scoped project of its own — one that starts with a design
pass on `LassoContext`'s value-vs-reference-type question before
touching call signatures, and that budgets for a full corpus re-crawl
to catch regressions, not just the unit test suite.

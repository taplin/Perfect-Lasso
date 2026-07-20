# Error And Protect Model Plan

Last reviewed: July 10, 2026

## Implementation Status (2026-07-10)

Milestones 2, 3, 4, and 6 are implemented, following an architect review
that recommended this plan run first (no dependencies, and
`inline-write-raw-sql-plan` needs its error-state shape). `LassoErrorState`/
`LassoRecoverableError` (`Providers.swift`), `LassoContext.currentError`/
`lastError` (`Runtime.swift`), `LassoInlineFrame.error` wired through
`pushInlineFrame` (`Runtime.swift`), `protect` catching only
`LassoRecoverableError` (`Renderer.swift`), and `error_currentError`
(`Runtime.swift`) are all live and tested (`Tests/LassoParserTests/
LassoParserTests.swift`: `protectCatchesRecoverableErrorAndSetsCurrentError`,
`protectDoesNotCatchReturnOrFatalErrors`,
`errorCurrentErrorDefaultsToNoErrorAndInlineFramesUpdateIt`).

**Update (`language-primitives-batch3` branch)**: Milestones 1 and 5 are now
done — `Sources/LassoParser/ErrorHandling.swift`'s `Code` enum extracts and
assigns the real Lasso 8.5 Appendix A Table 1 codes (verified via
`pdftotext -layout` against column-interleaving artifacts) plus the handful
of additional named codes only documented on lassoguide.com's Lasso 9 side
(`error_code_divideByZero`, `error_code_fileNotFound`, etc. — confirmed
genuinely absent from the 8.5 PDF's own Appendix A, not just missed). The
same work also added `fail`/`fail_if` (throwing the existing
`LassoRecoverableError`, so already catchable by `protect`), the general
`Error_*` tag family (`error_code`/`error_msg`/`error_push`/`error_pop`/
`error_reset`/`error_setErrorCode`/`error_setErrorMessage`), ten of Table 4's
14 named-constant tags (`Error_DatabaseConnectionUnavailable`/
`Error_DatabaseTimeout`/`Error_FileNotFound`/`Error_OutOfMemory`/
`Error_RequiredFieldMissing` don't map to a single clean Appendix A code and
are deliberately left out, disclosed in `ErrorHandling.swift`'s own comment),
and a fix making integer/decimal division by zero throw a catchable
`LassoRecoverableError` (`error_code_divideByZero`) instead of crashing or
producing `inf`/`nan`. Still explicitly NOT implemented, disclosed in
`ErrorHandling.swift`'s own top-of-file comment: `Handle`/`Handle_Error`
container-tag blocks and `Protect`'s own queued-callback-at-block-end
execution of them — a materially different mechanism (a per-container
deferred-callback queue, plus a new "halt current container and jump to its
handlers" control-flow signal for `Fail`) than `protect`'s existing simple
try/catch, comparable in scope to this project's other deferred structural
gaps (Captures, the RegExp Table 10 stateful tags).

Still open, deferred to the `inline-write-raw-sql-plan` pass per the
architect's dependency analysis:
- Milestone 7 (the dynamic inline executor actually constructing
  `LassoInlineFrame`s with real connector-failure error state — currently
  only reachable via a synthetic test native, not real database failures).

## Goal

Design the Lasso error/protect model so real pages can catch expected runtime
failures, inspect database/action errors, and continue rendering where Lasso
would continue, without hiding serious adapter bugs.

The current implementation parses `protect` but renders its body directly. This
is enough for simple pages, but it does not model Lasso's recoverable error
state or error inspection tags.

## Sources Reviewed

- `References/Lasso/Lasso 8.5 Language Guide.pdf`
- `References/Lasso/LP9Docs`
- `Sources/LassoParser/Renderer.swift`
- `Sources/LassoParser/Runtime.swift`
- `Sources/LassoParser/Evaluator.swift`
- `Sources/LassoParser/StartupLoader.swift`

Relevant Lasso 8.5 pages found so far:

- 142: database actions report errors via `[Error_CurrentError]`.
- 143-153: add/update/delete examples check `[Error_CurrentError]` inside
  `inline` blocks after write actions.
- 264 and nearby pages: index/search hits for `[Error_AddError]` and related
  database error tags.

Further research needed:

- enumerate the documented Lasso 8.5 `Error_*` tags and constants from the
  Error Control chapter;
- review LassoGuide 9 failure/protect/capture behavior for the Lasso 9 side;
- promote exact semantics into fixtures before implementing broad error tags.

## Current State

Current behavior:

- Most interpreter/runtime failures are Swift `throw`s.
- `protect` is parsed as a block but simply renders the body.
- Startup loading catches per-file failures and records them, allowing later
  startup files to load.
- Server rendering catches unhandled failures and returns a developer error
  page with request/path/error context.
- `web_response->abort()` uses the existing return-signal short-circuit.
- Inline frames already carry `affectedRows` and `actionStatement`.

Missing:

- request-local/current Lasso error state;
- error code/message values on `LassoInlineFrame`;
- `Error_CurrentError`;
- common error constants such as `Error_AddError`;
- a real `protect` catch boundary;
- a distinction between recoverable Lasso failures and fatal adapter bugs;
- `fail_if`, `fail_ifnot`, `fail`, or Lasso 9 failure helpers if required by
  corpus/docs;
- hooks for `session_abort`/transaction rollback on protected failure paths.

## Design Principle

Do not treat every Swift `throw` as a catchable Lasso error.

Recommended categories:

1. Recoverable Lasso failure
   - database action failure;
   - missing optional value where Lasso docs define a failure;
   - explicit `fail(...)` once implemented;
   - file/upload/session operation failure that Lasso code is expected to
     inspect.

2. Control-flow signal
   - `return`;
   - `yield`;
   - `abort`;
   - future `web_response->abort`.

3. Fatal adapter/configuration error
   - parser corruption;
   - unsupported expression shape;
   - missing required provider for a feature;
   - path escape attempt;
   - coding bug or impossible state.

`protect` should catch category 1. It should not swallow category 2. Category 3
should remain fatal unless we later prove Lasso catches it and continuing is
safe.

## Proposed Runtime Model

Add an error value:

```swift
public struct LassoErrorState: Equatable, Sendable {
    public var code: Int
    public var message: String
    public var kind: String
    public var detail: String?
}
```

Add request-local state to `LassoContext`:

```swift
public var currentError: LassoErrorState
public var lastError: LassoErrorState?
public mutating func setError(_ error: LassoErrorState)
public mutating func clearError()
```

Default success:

```swift
LassoErrorState(code: 0, message: "No Error", kind: "none")
```

Add a catchable error type:

```swift
public struct LassoRecoverableError: Error, Equatable, Sendable {
    public var state: LassoErrorState
}
```

Inline providers should prefer returning an inline frame with error metadata for
expected database failures. They should throw `LassoRecoverableError` only when
there is no meaningful frame to return but Lasso should still allow `protect`
to catch it.

## Inline Error Model

Extend `LassoInlineFrame`:

```swift
public let error: LassoErrorState
```

Behavior:

- successful inline sets `currentError` to No Error;
- failed database action sets `currentError` to connector/Lasso-compatible
  error;
- body still renders for database action failures when Lasso would expose
  `[Error_CurrentError]` inside the inline;
- fatal datasource misconfiguration can still throw outside the Lasso error
  model unless explicitly protected.

This supports the documented Lasso 8 pattern:

```lasso
[Inline: -Add, ...]
[Error_CurrentError: -ErrorCode]: [Error_CurrentError]
[/Inline]
```

## `protect` Semantics

First-pass behavior:

- render the protected body in the same context;
- catch only `LassoRecoverableError`;
- set `context.currentError`;
- suppress output generated after the failure point inside the protected body;
- preserve output generated before the failure point only if the existing
  renderer architecture makes that safe;
- continue rendering after the `protect` block;
- do not catch return/abort signals;
- do not catch fatal adapter errors.

Open question:

- Does Lasso preserve partial output from inside a protected block before the
  failure, or discard the protected body output? This should be verified before
  finalizing output behavior. If uncertain, start conservative and discard the
  failed protected body's partial output.

## Error Tags To Implement First

Minimum useful surface:

- `error_currenterror`
  - no argument: message
  - `-errorcode`: code
- `error_code`
  - alias or helper if documented/corpus requires it
- `error_msg` / `error_message`
  - only if documented/corpus requires it
- constants:
  - `error_noerror`
  - `error_adderror`
  - `error_updateerror`
  - `error_deleteerror`
  - `error_no_permission` / permission constant if documented

Exact names should be finalized from the Lasso 8.5 Error Control chapter before
coding. Do not invent the full constant list from memory.

## Error Code Mapping

Define adapter-side stable codes, then map connector errors into them.

Recommended first set:

- `0`: No Error
- add failed
- update failed
- delete failed
- SQL failed
- datasource not configured
- table not allowed
- raw SQL not allowed
- validation/required parameter missing
- file/upload failure
- session failure

Use real Lasso numeric codes when confirmed. Until then, isolate numeric values
behind named constants so changing them later is straightforward.

## Interaction With Server Errors

Unhandled fatal errors should keep the current developer error page behavior.
That page is useful and should not be removed.

But once recoverable errors exist:

- database constraint failures inside an inline should not automatically become
  developer error pages;
- protected recoverable failures should not become developer error pages;
- startup loader should continue recording file-level failures, but should mark
  whether a failure was recoverable/protected/fatal when available.

## Interaction With Transactions And Sessions

Protect/error handling affects backend side effects:

- raw SQL/mutation failures should leave `affectedRows = 0`;
- if a mutation uses a transaction and fails, rollback should happen inside the
  executor before returning/throwing;
- `session_abort` should prevent end-of-request session save after recoverable
  failures where Lasso code requests it;
- upload temp-file cleanup should still run after protected failures.

## Test Plan

Parser/runtime tests:

1. `protect` catches a synthetic `LassoRecoverableError` and continues after the
   block.
2. `protect` does not catch `return`/`abort`.
3. `protect` does not catch fatal unsupported-expression errors.
4. `Error_CurrentError` returns `0: No Error` shape after success.
5. `Error_CurrentError(-ErrorCode)` returns only the code.
6. Failed inline action sets current error and still renders the inline body
   when represented as an inline-frame error.

Inline/executor tests:

1. Add/update/delete connector failure maps to action-specific error state.
2. Raw SQL disabled maps to a recoverable permission/capability error when the
   inline is protected.
3. Raw SQL disabled remains fatal or developer-visible outside `protect` if we
   choose that policy.
4. Transaction rollback occurs on mutation failure.

Server tests:

1. Unprotected fatal render failure still returns developer error page.
2. Protected recoverable inline failure returns normal page output and error
   text.
3. Startup loader reports recoverable versus fatal failures if exposed.

## Implementation Milestones

1. Finish documentation extraction for Lasso 8.5 Error Control tags/constants.
2. Add `LassoErrorState` and `LassoRecoverableError`.
3. Add `currentError` to `LassoContext`.
4. Extend `LassoInlineFrame` with error state.
5. Implement `Error_CurrentError` and the minimum constants.
6. Change `protect` to catch only recoverable Lasso errors.
7. Update dynamic inline executor to return/throw recoverable errors for
   expected database failures.
8. Add tests covering protected and unprotected paths.

## Open Decisions

- Whether failed inline actions should return an inline frame with error state
  or throw a recoverable error. Recommendation: prefer frames for normal
  database action errors because Lasso examples inspect errors inside the
  inline body.
- Whether `protect` should preserve partial output before the failure point.
- Whether raw SQL capability denial should be recoverable by default or fatal
  unless wrapped in `protect`.
- Which exact Lasso numeric error codes to adopt first.

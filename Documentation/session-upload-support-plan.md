# Session and Upload Support Plan

Last reviewed: July 10, 2026

## Implementation Status (2026-07-10)

Milestone 1 (uploads) is implemented, absorbing `post-body-support-plan`'s
originally-planned multipart phase per the architect review's overlap
finding (this plan's `MimeReader`/`BodySpec` temp-file-lifetime analysis
was the correct one). `LassoUploadedFile` (`Providers.swift`), real
`uploadedFiles` on `ServerRequestProvider` with the `RetainedMimeReader`
lifetime fix (`LassoPerfectServer/main.swift`), `web_request->fileUploads()`
(`NativeTypes.swift`), and Lasso 8's `[file_uploads]` (`Runtime.swift`) are
all live, tested, and live-verified against a real `curl -F` multipart
upload. `[File_ProcessUploads]` (moving files) deliberately not
implemented — this pass is metadata only.

**File_ProcessUploads runtime support (2026-07-12):** the parser/runtime now
has a dedicated upload-processing boundary (`LassoUploadProcessor`) plus a
root-confined filesystem implementation (`LassoFileSystemUploadProcessor`).
`[File_ProcessUploads]` is registered, accepts `-Destination`,
`-UseTempNames`, `-FileOverwrite`, `-Size`, and `-Extensions`, moves matching
temporary upload files into the destination, and reports operational failures
as `LassoRecoverableError` so existing `[protect]` handling can catch them.
Focused tests cover moving, size/extension filtering, temp-name destination
selection, overwrite denial, and root confinement. `lasso-perfect-server`
now injects a process-lifetime `LassoFileSystemUploadProcessor` rooted at
`LASSO_SITE_ROOT`, so `-Destination` remains site-root-confined in live
requests.

**Milestones 2-4 (2026-07-12): the `PerfectSessionCore` session bridge is
implemented.** New target `LassoPerfectSession` (`Package.swift`) bridges
`LassoParser`'s synchronous evaluator to `PerfectSessionCore.SessionDriver`
(async): `LassoSessionPreflight.scan(document)` (`Sources/LassoParser/
SessionPreflight.swift`) walks the parsed AST for literal `session_start(...)`
calls before render; `PerfectBackedLassoSessionProvider` (`Sources/
LassoPerfectSession/PerfectBackedLassoSessionProvider.swift`) does the real
async create/resume (`prepare`, before render) and save/destroy (`finalize`,
after render) work, exposing only synchronous, already-loaded state to the
evaluator through the (redesigned) `LassoSessionProvider` protocol.
`lasso-perfect-server`'s `render` is now `async` to host this; it wires the
bridge in only when a page's preflight scan actually finds a
`session_start` call (`Sources/LassoPerfectServer/main.swift`).

Real, documented free-function surface implemented: `session_start`,
`session_id`, `session_result`, `session_addVar` (corrected to its real
two-argument `(sessionName, varName)` form — see below), `session_removeVar`,
`session_end`, `session_abort`. `LassoContext` gained `trackedSessionVariables`/
`suppressedSessionSaves`/`sessionStartResults` and a `finalizeSessions()`
hook the renderer calls once per render, after the return-signal is consumed.
`MemorySessionDriver` (default) and `MySQLSessionDriver` (`LASSO_SESSION_DRIVER=mysql`,
reusing the existing `LASSO_MYSQL_*` connection vars) are wired at the server
boundary — PostgreSQL/Redis/SQLite backends already exist in Perfect-Session
but aren't wired here yet (deferred: this adapter has no other configured use
of those three; adding one is the same mechanical pattern once a deployment
needs it, not a design gap).

**A real correction, not just an addition:** the interpreter's pre-existing
`session(name)` free function and `session->value`/`get` native-type members
did not match Lasso's documented session contract at all — they modeled an
unnamed, single-bucket key/value store (`session_addvar(varName, value)`
directly set a value), when real Lasso sessions are named
(`session_start(name, ...)`) and `session_addVar(sessionName, varName)`
registers an *existing* variable for end-of-request persistence, it does not
take a value. That earlier shape was an unverified placeholder (its own code
comment already flagged it as "out of scope for this pass"), not a
considered design — verified against `lassoguide.com/operations/sessions.html`
(cited in this plan's own "Sources Reviewed") before implementing. `session(name)`
and the native `session` type were removed outright and replaced with the
real, named-session surface above; the two tests and the one smoke-script
line that exercised the old (incorrect) contract were rewritten to the real
one, not just patched to keep passing.

Deferred, with reasons: `-Key`-style multi-session `-useLink`/`-useAuto`
GET/POST `-lassosession` fallback tracking (only `-id` then cookie lookup is
implemented; the documented third fallback needs the request's query/post
pairs threaded into the preflight scan, not yet wired); `session_deleteExpired()`
(a cross-request maintenance operation, not naturally scoped to one request's
session bridge); dynamically-computed session names/flag values in
`session_start(...)` (the preflight scanner only recognizes literal
arguments — documented directly in `LassoSessionPreflight`'s doc comment,
not a silent gap). Verified via 65/65 unit tests (new: preflight-scan
coverage, `PerfectBackedLassoSessionProvider` persistence across two
simulated requests via `MemorySessionDriver`, end/abort/removeVar) and a
real-corpus GET-request regression sweep showing no change from the
pre-session-work baseline (same 19/28 pages render cleanly, same 9 failures
for the same pre-existing reasons) — live verification against a real MySQL
session driver was not performed this pass (no live datasource credentials
in this session, matching the same call made for `inline-write-raw-sql-plan`).

## Goal

Add sessions and uploads in a way that maps early to the native Perfect Swift
APIs:

- uploads should wrap `PerfectNIO.HTTPRequest.readContent()` and its
  `MimeReader`/`QueryDecoder` output;
- sessions should wrap `PerfectSessionCore.SessionDriver` and
  `PerfectSession`, rather than creating adapter-specific storage.

The Lasso runtime should see Lasso-compatible request/session objects, but the
server boundary should own the HTTP/body/session lifecycle.

## Sources Reviewed

- `References/Lasso/LP9Docs/Web Request and Response.txt`
- `References/Lasso/Lasso 8.5 Language Guide.pdf`
- `https://lassoguide.com/operations/requests-responses.html`
- `https://lassoguide.com/operations/sessions.html`
- `/Users/timtaplin/Perfect-Resurrection/Perfect-NIO/Sources/PerfectNIO`
- `/Users/timtaplin/Perfect-Resurrection/Perfect-Session/Sources`

## Lasso Upload Semantics

Lasso 9:

- request body processing happens before request handler code runs;
- `application/x-www-form-urlencoded` and `multipart/form-data` are parsed
  automatically;
- ordinary multipart fields become POST params;
- file uploads are not included in POST params;
- uploads are exposed through `web_request->fileUploads()`;
- uploaded files are stored in a temporary location and deleted if not moved.

Lasso 9 upload metadata keys:

- `fieldname`
- `contenttype`
- `filename`
- `tmpfilename`
- `filesize`

Lasso 8.5:

- `[File_Uploads]` returns an array of maps.
- `[File_ProcessUploads]` moves uploaded files into a destination directory and
  can filter by size or extension.

Lasso 8.5 upload metadata keys:

- `Path`
- `File`
- `Size`
- `Type`
- `Param`
- `OrigName`
- `OrigPath`
- `OrigExtension`

## Perfect Upload Surface

Perfect-NIO already provides the right low-level shape:

- `HTTPRequest.readContent() async throws -> HTTPRequestContentType`
- `HTTPRequestContentType.urlForm(QueryDecoder)`
- `HTTPRequestContentType.multiPartForm(MimeReader)`
- `HTTPRequestContentType.other([UInt8])`

`MimeReader` parses multipart fields and writes file uploads to temp files.
Its `BodySpec` exposes:

- `fieldName`
- `fieldValue`
- `contentType`
- `fileName`
- `fileSize`
- `tmpFileName`
- `file`

Important lifecycle detail: `MimeReader` and `BodySpec` clean up temp upload
files on deinit. The Lasso adapter must keep the `MimeReader` or retained temp
file handles alive through the render and any post-render upload-processing
work. If we copy only the path string and allow `MimeReader` to deinit, the temp
file may disappear too early.

## Upload Recommendation

Use Perfect-NIO as the parser and add only a Lasso-shaped projection layer.

Recommended model:

```swift
public struct LassoUploadedFile: Equatable, Sendable {
    public var fieldName: String
    public var contentType: String
    public var originalFilename: String
    public var temporaryFilename: String
    public var size: Int
}

public struct LassoRequestBody: Sendable {
    public var postPairs: [LassoRequestPair]
    public var uploads: [LassoUploadedFile]
    public var rawPostBytes: [UInt8]
    public var retainedMultipartReader: AnyObject?
}
```

In the real implementation, avoid `AnyObject?` if possible by keeping the
Perfect-NIO-specific `MimeReader` retention inside `LassoPerfectServer`, while
the parser/runtime only receives value projections.

Implementation flow:

1. In the async route handler, call `request.readContent()` before rendering.
2. Convert `.urlForm(QueryDecoder)` to ordered POST pairs.
3. Convert `.multiPartForm(MimeReader)` to:
   - ordered POST pairs for non-file fields;
   - upload metadata for file fields;
   - retained multipart reader for temp-file lifetime.
4. Convert `.other([UInt8])` to raw body bytes/string only.
5. Construct `ServerRequestProvider` with the parsed body.
6. Render synchronously.
7. After render, either:
   - let unprocessed temp files clean up naturally; or
   - keep files that Lasso code explicitly moved/processed.

Do not write a custom multipart parser unless Perfect-NIO's `MimeReader` proves
insufficient under tests.

## Lasso Session Semantics

Lasso sessions are named. A session has:

- a session name;
- a set of variables to persist;
- an ID string that identifies the visitor for that named session.

Documented Lasso 9 methods:

- `session_start(name, -expires=?, -id=?, -useCookie=?, -useLink=?,
  -useNone=?, -useAuto=?, -cookieExpires=?, -domain=?, -path=?, -secure=?,
  -httponly=?, -rotate=?)`
- `session_id(sessionName)`
- `session_addVar(sessionName, varName)`
- `session_removeVar(sessionName, varName)`
- `session_end(sessionName, -secure=false, -httponly=false)`
- `session_abort(sessionName)`
- `session_result(sessionName)`
- `session_deleteExpired()`

The docs state:

- `session_start` must be called once per request that needs session variables.
- It creates or loads a session.
- The ID lookup order is explicit `-id`, cookie, then GET/POST
  `-lassosession`.
- The tracker cookie name is `_LassoSessionTracker_` plus the Lasso session
  name.
- Variables added with `session_addVar` are saved at the end of the request.
- `session_abort` prevents saving, which matters after partial failures.

## Perfect Session Surface

Perfect-Session already has a backend-neutral async driver:

```swift
public protocol SessionDriver: Sendable {
    func create(ipaddress: String, useragent: String) async -> PerfectSession
    func resume(token: String) async throws -> PerfectSession
    func save(_ session: PerfectSession) async
    func destroy(token: String) async
    func clean() async
    func setup() async
}
```

`PerfectSession` stores:

- `token`
- `userid`
- `created`
- `updated`
- `idle`
- `data: [String: Any]`
- `ipaddress`
- `useragent`
- `_state`

Drivers already exist for:

- memory
- MySQL
- PostgreSQL
- Redis
- SQLite

## Session Recommendation

Add a Lasso session bridge over `PerfectSessionCore`.

Recommended server-side shape:

```swift
public final class PerfectBackedLassoSessionProvider: LassoSessionProvider {
    let driver: any SessionDriver
    let requestCookies: [String: String]
    let requestParams: [LassoRequestPair]
    let responseSink: any LassoResponseSink
    var loaded: [String: LoadedLassoSession]
}
```

Because `SessionDriver` is async and the current evaluator is sync, do the
actual create/resume/destroy/save work at the server boundary:

1. `session_start` records a desired named session in the render context.
2. The server bridge synchronously exposes already-loaded session values to the
   renderer.
3. For first implementation, preload lazily requested sessions before render if
   the page can be scanned for `session_start(...)`, or add an async
   pre-render/session-start hook at the server layer.
4. At end of render, collect tracked variables, write them into
   `PerfectSession.data`, call `driver.save`, and emit tracker cookies through
   `ServerResponseSink`.

The cleanest longer-term option is to add an async preflight phase before sync
render:

```swift
handle async
  -> read/parse request body
  -> inspect page/startup includes for session_start calls when feasible
  -> create/resume requested named sessions with SessionDriver
  -> render sync with loaded sessions
  -> save/end/destroy sessions async
  -> emit response
```

If exact lazy `session_start` behavior is needed, the evaluator will eventually
need an async native-call path. Avoid that until tests prove preflight is not
enough.

## Data Mapping

Lasso named sessions do not map one-to-one to Perfect's single token unless we
choose the token carefully.

Recommended token strategy:

- external Lasso session ID remains the cookie/form value;
- Perfect `token` stores a composite key such as `lasso:<sessionName>:<id>`;
- Lasso `session_id(name)` returns only the external ID;
- Perfect storage can still use `token` as its primary key.

Cookie strategy:

- read `_LassoSessionTracker_<name>` for a named Lasso session;
- write `_LassoSessionTracker_<name>` on `session_start` when cookie tracking is
  enabled;
- respect `-domain`, `-path`, `-secure`, `-httponly`, and cookie expiration
  where supported by `ServerResponseSink`.

Variable strategy:

- `session_addVar(sessionName, varName)` registers a variable name, not a
  direct value at call time.
- On load, restore saved variables into the Lasso context.
- On save, read those variable names from the Lasso context and serialize into
  `PerfectSession.data`.
- Store only JSON-safe values at first: string, integer, decimal, boolean,
  arrays, maps, null/void as empty/null-compatible values.

## Current Interpreter State

Already present:

- `LassoSessionProvider`
- `session(name)` and `session->value/get`
- `session_addvar`
- stub `session_start`

Missing:

- real `session_start`
- named-session lifecycle
- `session_id`
- `session_result`
- `session_removeVar`
- `session_end`
- `session_abort`
- end-of-request save
- tracker cookies
- link/form fallback tracking

## Recommended Milestones

### Milestone 1: Uploads Via Perfect-NIO

- Use `request.readContent()` in `lasso-perfect-server`.
- Map URL form and multipart fields into `LassoRequestProvider.postPairs`.
- Map multipart files into upload metadata.
- Implement `web_request->fileUploads()`.
- Implement Lasso 8 `[File_Uploads]` metadata projection.
- Defer `[File_ProcessUploads]` until file type/member methods can move files
  safely.

### Milestone 2: Session Core Bridge

- Add `PerfectSessionCore` dependency to `LassoPerfectServer`.
- Introduce `PerfectBackedLassoSessionProvider`.
- Support memory-backed sessions for tests and local smoke.
- Implement named `session_start`, `session_id`, `session_result`,
  `session_addVar`, and end-of-request save.
- Use `_LassoSessionTracker_<name>` cookies by default.
- Add fixture server tests that prove state persists across two requests.

### Milestone 3: Durable Session Drivers

- Wire MySQL/SQLite/Redis/PostgreSQL drivers by configuration.
- Add schema/setup docs.
- Prefer the existing `SessionDriver.setup()` instead of adapter-owned schema
  code.
- Add integration tests only where local services are explicitly configured.

### Milestone 4: Full Legacy Session Surface

- `session_removeVar`
- `session_end`
- `session_abort`
- `-id`
- `-expires`
- `-cookieExpires`
- `-domain`
- `-path`
- `-secure`
- `-httponly`
- `-rotate`
- `-useNone`
- link/form fallback tracking for `-useLink`/`-useAuto`

## Key Risks

- The current renderer/evaluator is synchronous, while Perfect sessions are
  async. Keep async driver calls at the server boundary until there is strong
  evidence that native calls must become async.
- Lasso session variables are thread variables, not simple key/value writes.
  Saving must read the current variable values at the end of the request.
- Upload temp-file cleanup depends on retaining Perfect-NIO's multipart reader
  or moving files before it is released.
- Lasso 9 uses pair/staticarray/trait iteration shapes. The current value model
  still needs a better pair representation for fully faithful params/uploads.

## Recommendation

Implement uploads first because Perfect-NIO already provides the native Swift
surface. Then implement a memory-backed PerfectSession bridge for named sessions
and two-request persistence tests. Durable database-backed session storage can
come immediately after the adapter contract is correct.

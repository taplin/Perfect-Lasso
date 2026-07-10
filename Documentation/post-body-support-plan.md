# POST Body Support Plan

Last reviewed: July 10, 2026

## Implementation Status (2026-07-10)

Phase 1 (`application/x-www-form-urlencoded`) is implemented, corrected per
an architect review to consume Perfect-NIO's own `QueryDecoder` rather than
the hand-rolled parser this plan originally proposed (Step 3/"URL Decoding
Rules" — `QueryDecoder` already does exactly this). Also found and fixed a
prerequisite gap this plan didn't anticipate: `lasso-perfect-server` only
ever registered `.GET` routes, so no POST request could reach the render
path at all before this. `LassoRequestPair` (`Providers.swift`),
`ServerRequestProvider` real `queryPairs`/`postPairs`
(`LassoPerfectServer/main.swift`), `postParam`/`postParams`/`postString`/
`param(name, joiner)`/`params()` (`NativeTypes.swift`), and the Lasso 8
`client_*`/`form_param` aliases (`Runtime.swift`) are all live and
live-verified against a real POST request. Fixed a related pre-existing bug
as a byproduct: GET query parsing used `URLComponents`, which doesn't treat
`+` as space — switched to `QueryDecoder` for GET too.

Still open, per the architect's recommended sequencing: Phase 2/3
(`multipart/form-data`, file uploads, raw JSON/XML/SOAP body capture) —
deferred to `session-upload-support-plan.md`'s upload milestone, which
already correctly analyzes the `MimeReader`/`BodySpec` temp-file-lifetime
risk this plan's own Phase 2 section didn't account for.

## Goal

Add real POST body support at the Perfect server boundary so Lasso code sees
request data through native Lasso-compatible APIs before rendering begins.
The renderer should receive an already-normalized Swift request model instead
of parsing body data lazily from individual tags or native-type members.

This is required for real form workflows, checkout/search flows, SOAP-style
request bodies, and upload forms.

## Documentation Findings

### Lasso 9 / 9.3

Sources reviewed:

- `References/Lasso/LP9Docs/Web Request and Response.txt`
- original source path: `/Users/timtaplin/Documents/LP9Docs/Web Request and Response.txt`
- `https://lassoguide.com/operations/requests-responses.html`

Lasso 9 makes request data available through `web_request`, created once per
request before user code runs. The relevant POST/body behaviors are:

- GET arguments are exposed as query params.
- POST body data is processed according to `Content-Type`.
- `multipart/form-data` and `application/x-www-form-urlencoded` are handled
  automatically.
- File uploads are not included in normal POST argument pairs; they are exposed
  through `web_request->fileUploads`.
- `web_request->queryParam(name)` and `web_request->postParam(name)` return the
  first matching value, or `void` when there is no match.
- `web_request->queryParams()`, `postParams()`, and `params()` return iterable
  name/value pair collections.
- `web_request->params()` combines POST and GET arguments, with POST arguments
  occurring first.
- `web_request->param(name, joiner=?)` supports duplicate argument names. With a
  string joiner, duplicates are joined; with `void`, duplicates are returned as
  an array/staticarray-like value.
- Values are byte-oriented in real Lasso 9. The current interpreter can map
  these to strings initially, then introduce byte values when the value model
  grows.
- `web_request->postString()` is reconstructed from parsed POST pairs using
  `name=value` joined by `&`. It may differ from the exact original body for
  multipart input.
- Upload metadata keys in Lasso 9 are:
  - `fieldname`
  - `contenttype`
  - `filename`
  - `tmpfilename`
  - `filesize`

### Lasso 8.5

Source reviewed:

- `References/Lasso/Lasso 8.5 Language Guide.pdf`
- original source path: `/Users/timtaplin/Documents/Lasso 8.5 Language Guide.pdf`

Relevant PDF pages:

- Pages 34-35: HTML GET/POST form behavior. POST form fields are sent in the
  HTTP request body as URL-encoded `application/x-www-form-urlencoded` data.
- Pages 94-95: `[Action_Param]` and `[Action_Params]` pull submitted HTML form
  or URL values into inline database actions. `[Action_Param]` is documented as
  equivalent to older `[Form_Param]`.
- Pages 98-99: Action parameter tags return information about the current
  action; outside an inline, they refer to the action that caused the current
  page to be served.
- Pages 437-438: `[File_Uploads]` returns an array of maps for uploaded files;
  `[File_ProcessUploads]` moves uploads to a destination and can filter by size
  or extension.
- Pages 628-629: request tags include:
  - `[Client_ContentLength]`
  - `[Client_ContentType]`
  - `[Client_FormMethod]`
  - `[Client_GETArgs]`
  - `[Client_GETParams]`
  - `[Client_POSTArgs]`
  - `[Client_POSTParams]`
  - `[Client_Headers]`
- Page 699: a documented `[Define_Tag]` example redefines `[Form_Param]` using
  `[Client_PostParams]`, confirming that `Client_PostParams` is the legacy API
  for POST-only form parameters.
- Pages 819-820: LJAPI request constants include `ContentLength`,
  `ContentType`, `MethodKeyword`, `PostKeyword`, and `SearchArgKeyword`.

Lasso 8 upload metadata uses different keys from Lasso 9:

- `Path`
- `File`
- `Size`
- `Type`
- `Param`
- `OrigName`
- `OrigPath`
- `OrigExtension`

## Current Interpreter State

Current relevant files:

- `Sources/LassoParser/Providers.swift`
- `Sources/LassoParser/NativeTypes.swift`
- `Sources/LassoParser/Runtime.swift`
- `Sources/LassoPerfectServer/main.swift`
- `Tests/LassoParserTests/LassoParserTests.swift`

`LassoRequestProvider` already exposes:

- `parameters`
- `queryParameters`
- `postParameters`
- request method, URI, path, HTTPS flag, addresses, ports
- content type and content length

But POST support is stubbed:

- `web_request->postParam(...)` returns `void`.
- `web_request->postParams()` returns an empty map.
- `web_request->postString()` returns an empty string.
- `fileUploads()` is not implemented.

`ServerRequestProvider` currently builds a synchronous provider from
`HTTPRequest` and only reads query params, headers, cookies, and metadata. The
Perfect route handler is async, but rendering is sync. That is a good shape:
read and parse the body in the async handler before constructing the provider,
then pass immutable parsed request data into the sync renderer.

The main data model limitation is that request params are currently dictionaries.
That loses:

- duplicate parameter names
- original ordering
- Lasso 9 combined `params()` ordering where POST pairs precede GET pairs
- `param(name, joiner)` semantics

## Recommended Architecture

### Add Request Body Model

Add Swift value types in `LassoParser` or a small shared server-support module:

```swift
public struct LassoRequestPair: Equatable, Sendable {
    public var name: String
    public var value: LassoValue
}

public struct LassoUploadedFile: Equatable, Sendable {
    public var fieldName: String
    public var contentType: String
    public var originalFilename: String
    public var temporaryFilename: String
    public var size: Int
}

public struct LassoRequestBody: Equatable, Sendable {
    public var rawPostString: String
    public var postPairs: [LassoRequestPair]
    public var uploads: [LassoUploadedFile]
}
```

Keep dictionary accessors as convenience projections for existing code, but use
ordered pairs as the source of truth.

### Extend `LassoRequestProvider`

Keep existing defaults so test providers and smoke providers do not all break at
once.

Recommended additions:

```swift
var queryPairs: [LassoRequestPair] { get }
var postPairs: [LassoRequestPair] { get }
var uploadedFiles: [LassoUploadedFile] { get }
var rawPostString: String { get }
func queryParameter(named name: String) -> LassoValue
func postParameter(named name: String) -> LassoValue
func parameter(named name: String, joiner: LassoValue?) -> LassoValue
```

Default implementations can project from the existing dictionaries. Real server
requests should override the pair-based members.

### Parse at the Perfect Boundary

Change the Perfect server flow from:

```swift
handle async -> render sync -> ServerRequestProvider(request)
```

to:

```swift
handle async
  -> read HTTP body if needed
  -> parse body using content type
  -> build ServerRequestProvider(request, parsedBody)
  -> render sync
```

This keeps async I/O out of the renderer and maps request data to Swift/Perfect
native structures as early as possible.

### Content-Type Handling

Phase 1:

- `application/x-www-form-urlencoded`
- empty/no body
- unknown content type captured as `rawPostString`, with no parsed POST pairs

Phase 2:

- `multipart/form-data`
- ordinary non-file fields become POST pairs
- file fields become `uploadedFiles`
- temporary upload files are written under a controlled temp directory

Phase 3:

- Preserve JSON/XML/SOAP body as raw post data.
- Do not automatically parse JSON into params unless a Lasso compatibility
  source proves that behavior. SOAP examples in the 8.5 guide indicate raw POST
  body access matters.

### URL Decoding Rules

For form-urlencoded bodies:

- split pairs on `&`
- split first `=` only
- convert `+` to space
- percent-decode names and values
- preserve empty values
- preserve duplicate names in `postPairs`
- use lowercase lookup keys for case-insensitive convenience lookup, matching
  the current provider pattern

### API Compatibility Targets

Implement Lasso 9 first:

- `web_request->postParam(name)`
- `web_request->postParams()`
- `web_request->postString()`
- `web_request->param(name)`
- `web_request->param(name, joiner)`
- `web_request->params()`
- `web_request->fileUploads()`

Then fill Lasso 8 aliases/tags:

- `client_postargs`
- `client_postparams`
- `client_getargs`
- `client_getparams`
- `client_contentlength`
- `client_contenttype`
- `client_formmethod`
- `form_param`
- `action_param`
- `action_params`
- `file_uploads`

`action_param` can continue to call the combined provider lookup, but combined
lookup should include POST and GET, with POST first to match Lasso 9 `params()`.

`action_params` is trickier because it must be usable as an inline argument
array. Implement it as an ordered array of name/value pairs once inline argument
expansion supports that shape.

## Test Plan

Unit tests:

1. Parse `application/x-www-form-urlencoded` body with:
   - normal pairs
   - duplicate names
   - blank values
   - `+` spaces
   - percent-encoded characters
2. Verify `postParam` returns first matching POST value.
3. Verify `postParams` preserves all POST pairs in iterable output once the
   runtime has pair-array support.
4. Verify `postString` reconstructs parsed POST pairs.
5. Verify combined `param` prefers POST before GET.
6. Verify `param(name, ',')` joins duplicate values.
7. Verify `param(name, void)` returns duplicate values as an array/staticarray
   compatible value.
8. Verify legacy `client_postargs` and `client_postparams`.
9. Verify `action_param` sees submitted POST values.
10. Verify unknown content type keeps raw body but produces no form params.
11. Verify multipart fields and uploads after Phase 2.

Server smoke tests:

1. Run `lasso-perfect-server` against a temporary fixture site.
2. `curl` a GET-only request and verify existing query behavior is unchanged.
3. `curl -X POST -H 'Content-Type: application/x-www-form-urlencoded'` with
   form data and verify Lasso output from `web_request->postParam`.
4. `curl -F` multipart form with one text field and one small file and verify
   `web_request->postParam` plus `web_request->fileUploads`.

Regression tests:

- Keep the current "POST params are empty not broken" test only until the new
  implementation lands, then replace it with real positive coverage.
- Preserve existing `void` lookup semantics for missing params.
- Preserve existing header/cookie/query behavior.

## Implementation Steps

1. Add pair/upload/body request structs and provider defaults.
2. Update `ServerRequestProvider` to accept parsed query pairs and parsed body
   data, while still exposing dictionary projections for existing methods.
3. Add a pure Swift form-urlencoded parser.
4. Change the Perfect route handler to read the body asynchronously before
   render and pass parsed body data into `ServerRequestProvider`.
5. Implement Lasso 9 native members for POST, combined params, joiner behavior,
   and `postString`.
6. Add Lasso 8 request aliases for client/form/action POST behavior.
7. Add tests for parser, native APIs, and a server smoke fixture.
8. Implement multipart parsing and upload temp-file handling.
9. Add file upload tests and compatibility docs updates.

## Open Decisions

- Whether `LassoValue` needs a first-class pair/staticarray type before
  `params()` and `postParams()` can be fully compatible. A temporary array of
  maps can work for internal tests, but Lasso code expects pair-like iteration.
- Whether upload temp files should be deleted at end of request automatically or
  kept until process cleanup. Real Lasso deletes unprocessed temporary uploads,
  so request-lifetime cleanup is the closer target.
- Exact maximum body size default. Recommendation: introduce
  `LASSO_MAX_BODY_BYTES`, defaulting to a conservative value such as 10 MB, and
  fail oversized requests with 413.
- Whether to implement `[File_ProcessUploads]` in the same milestone or defer it
  until `web_request->fileUploads()` and `[File_Uploads]` are stable.

## Recommendation

Start with form-urlencoded POST support and the pair-based request model. That
unblocks real forms, keeps Perfect/NIO async body handling at the boundary, and
sets up the right data shape for multipart uploads and legacy Lasso 8 tags
without creating end-use-specific APIs.

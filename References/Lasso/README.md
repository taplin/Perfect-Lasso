# Lasso Reference Sources

This folder keeps the Lasso documentation sources used for compatibility
research so future work sessions do not depend on remembering local document
locations.

## Local Copies

- `Lasso 8.5 Language Guide.pdf`
  - Original source path: `/Users/timtaplin/Documents/Lasso 8.5 Language Guide.pdf`
  - Primary use: Lasso 8 compatibility behavior, especially classic tags such
    as `[Action_Param]`, `[Action_Params]`, `[Form_Param]`,
    `[Client_POSTParams]`, `[Client_POSTArgs]`, `[File_Uploads]`, and
    `[File_ProcessUploads]`.
  - POST/body pages reviewed:
    - 34-35: HTML GET/POST form behavior.
    - 94-95: `[Action_Param]` and `[Action_Params]` in inline actions.
    - 98-99: action parameter tag definitions.
    - 437-438: upload forms, `[File_Uploads]`, `[File_ProcessUploads]`.
    - 628-629: request tags including `Client_*` GET/POST/body metadata tags.
    - 699: documented `Define_Tag` replacement of `[Form_Param]` using
      `[Client_PostParams]`.
    - 819-820: LJAPI request constants for body/method/content metadata.

- `LP9Docs/`
  - Original source path: `/Users/timtaplin/Documents/LP9Docs`
  - Primary use: early Lasso 9 language/runtime documentation.
  - Most relevant POST/body file:
    - `Web Request and Response.txt`
  - Relevant `web_request` members:
    - `contentLength`
    - `contentType`
    - `param`
    - `params`
    - `queryParam`
    - `queryParams`
    - `queryString`
    - `postParam`
    - `postParams`
    - `postString`
    - `fileUploads`
    - `requestMethod`

## External Canonical Reference

- LassoGuide 9.3: https://lassoguide.com/
- Web Requests and Responses:
  https://lassoguide.com/operations/requests-responses.html
- Sessions:
  https://lassoguide.com/operations/sessions.html

The LassoGuide 9.3 request documentation is especially useful because it states
that:

- request data is parsed before handler code runs;
- query params and POST params can be retrieved separately or together;
- combined `params()` returns POST arguments before GET arguments;
- `multipart/form-data` and `application/x-www-form-urlencoded` are processed
  automatically;
- file uploads are exposed through `web_request->fileUploads`;
- `postString()` is reconstructed from parsed POST pairs and may differ from
  the exact original body for multipart input.

## Project Notes Using These References

- `Documentation/post-body-support-plan.md`
- `Documentation/session-upload-support-plan.md`
- `Documentation/inline-write-raw-sql-plan.md`
- `Documentation/error-protect-model-plan.md`
- `Documentation/compatibility-matrix.md`
- `Documentation/lasso-perfect-server.md`

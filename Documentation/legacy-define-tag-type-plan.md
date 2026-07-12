# Legacy `define_tag` / `define_type` Plan

Date: 2026-07-10

## Implementation Status (2026-07-12)

Implemented. Real Lasso 8.5 documentation for `Define_Tag`/`Define_Type`
was recovered from the local `References/Lasso/Lasso 8.5 Language Guide.pdf`
(no working CLI text extractor was available in this environment —
`pdftotext`/`PyPDF2`/`pymupdf` were all missing; installed `poppler` via
`brew install poppler` to get `pdftotext`, then located the real "Custom
Tags" (Chapter 57) and "Custom Types" (Chapter 58) chapters — see the
"Documented Flags And Parameters" section below for what those chapters
actually say, sourced directly rather than inferred from corpus usage
alone, per [[lasso-adapter-feedback]]'s "verify against docs" pattern).

**The real root cause was bigger than the syntax of the two openers.**
Tracing why a real `[Define_Tag(...); ...; /Define_Tag;]` body silently
lost everything after its first statement found that `LassoParser.swift`'s
square-bracket (`[...]`) handling only gave full statement/block-aware
parsing (`ScriptBodyParser`) to bodies opening with modern `define` — any
other multi-statement `[...]` body (including legacy `define_tag`/
`define_type`, which real startup files wrap their ENTIRE body in) fell
through to a single-expression fallback that silently dropped every
statement after the first. Fixed by adding the same `ScriptBodyParser`
routing for bodies opening with `define_tag`/`define_type`
(`bodyOpensWithLegacyDefinition` in `LassoParser.swift`) — confirmed via a
temporary diagnostic probe (not part of this repo) that a real corpus-shaped
body collapsed to one node before the fix and parsed correctly after.

Once bodies parsed fully, the actual `define_tag`/`define_type` block
recognition needed two more additive fixes: `BlockBuilder.blockNames` and
`ScriptBodyParser`'s own `emitStatement` (for the bare colon-call form with
no enclosing parens, e.g. `Define_Tag: 'name', -Required='x';` — a
genuinely different shape from `if:(...)`'s still-parenthesized colon
form, which `parseBlockOpening` already handled). Legacy definitions lower
into the *same* runtime models modern `define`/`define ... => type {...}`
already use (`LassoCustomTagDefinition`, `LassoTypeDefinition`,
`LassoMethodDefinition`, `LassoDataMemberDefinition`) via new
`Sources/LassoParser/LegacyDefinitions.swift` — no second runtime path, per
this plan's own "Step 2" design goal.

**Two real, load-bearing bugs found and fixed along the way, not just
syntax gaps:**
- `(Local: 'name')`/`(Var: 'name')` — Lasso 8's documented way to *read* a
  local/page variable's current value — had never been implemented.
  `Evaluator.declare` only handled the assignment form
  (`local('name' = value)`); a bare read silently returned `.void`. This
  blocks nearly all legacy Lasso 8 tag/type bodies, which read locals this
  way throughout (confirmed directly against the Lasso 8.5 Language
  Guide's own Custom Tags chapter examples). Fixed to return the read
  value for the non-assignment form while keeping the assignment form
  returning `.void` unchanged (an early attempt at this fix returned the
  *assigned* value too, which broke three passing corpus fixture tests
  that rely on `[local('x' = 1)]` producing no output as a bare
  statement — reverted to keep that path exactly as it was).
- Constructor `params` (`Local('ip' = (Params->First ? Params->First |
  ...))`, needed for the real `getGeoIPInfo.inc` shape): `Evaluator.instantiate`
  now binds a `params` local (an array of the evaluated constructor call
  arguments) before evaluating data member defaults, matching this plan's
  own "Constructor params" recommendation. `.array->First` (needed to read
  it) was also missing and added.

Verified via 4 new tests (standalone parenthesized `Define_Tag`, colon-call
`Define_Tag` with `-Required`/`-Type` parameter translation, parenthesized
`Define_Type` with data-member defaults reading constructor `params` and a
method reading/writing instance data via `self`, and a colon-call
`Define_Type` matching the real `js_timer.inc` shape) plus the full existing
69-test suite (65 prior + 4 new; no regressions). **Live-verified against
the real `LassoStartup` folder: all 10 startup files now load with zero
failures** (previously 3 failed with `unknownFunction("define_tag")`/
`unknownFunction("define_type")`) — see `lasso-real-corpus-paths` project
memory for the path. Real-corpus GET-request sweep unchanged (19 of 28
top-level pages render cleanly, same 9 pre-existing failures for the same
reasons — no regression from this pass).

A real, known dispatch nuance found but not fixed (out of scope for this
pass): `onCreate` (or any nested `define_tag` method) is matched by
`LassoMethodDispatcher.resolve` using the same arity-aware scoring as
ordinary method calls — a constructor called with more positional
arguments than `onCreate` declares parameters for silently skips `onCreate`
entirely (`missingIsVoid: true`) rather than passing the extra arguments
through leniently the way real Lasso's docs describe ("called ... with any
parameters that were passed to the tag that created the type"). Not hit by
any of the three priority corpus fixtures (their `onCreate`s don't declare
fixed parameters), so left as a documented gap rather than fixed under
this pass's scope.

Deferred, matching this plan's own "Recommended Scope Boundaries":
`-Container`/`-Looping` container-tag calling convention (`Run_Children`) —
a real, separate feature, since `BlockBuilder` only recognizes a fixed
keyword set at parse time while custom-tag registration happens at render
time, a chicken-and-egg ordering problem for treating an arbitrary
registered tag name as block-shaped; `-Async`/`-Atomic`/`-RPC`/`-SOAP`
behavior; `-Priority`/`-Criteria` overload-chain dispatch (redefining/
layering multiple same-named tags); parent/base type name and
`-Prototype` on `Define_Type` (parsed as positional arguments, not acted
on — no inheritance execution); `[Private]`/frozen-properties instance
variable privacy. None of the three priority corpus fixtures need these to
load cleanly.

## Purpose

Prepare the next compatibility discussion and implementation pass for the two
remaining startup-folder legacy definition dialects:

- parenthesized-call style: `define_tag('name', -flags) ... /define_tag`
- colon-call style: `define_type: 'name', 'base'; ... /define_type;`

This plan is intended as a handoff for another dev agent. It assumes the
current uncommitted progress in this working tree remains in place.

## Current Progress Snapshot

Recent committed work already moved the adapter well past the original
`api.lasso` blockers:

- first-pass Lasso 9 `define Foo => type { ... }` object/runtime support;
- instance `LassoStartup` folder loading via `LASSO_STARTUP_PATH`;
- expression-bodied modern `define name => <expr>`;
- bare zero-arg custom tag lookup;
- `with x in y do { ... }`;
- native type dispatch for `web_request`, `web_response`, and `session`;
- corrected `library()` caching scope;
- void/null behavior fixes;
- colon-call control-flow openers such as `if:(...)`;
- no-op `[Cache]`;
- `[noprocess]` / `[no_process]`.

Per the current server doc, the real-corpus page sweep is at 13 of 17 pages
rendering cleanly. The remaining real startup-loader failures are now
specific legacy definition forms, not broad parser/runtime ambiguity.

The working tree is currently dirty with additional uncommitted progress in:

- `Documentation/compatibility-matrix.md`
- `Documentation/lasso-perfect-server.md`
- `Sources/LassoParser/LassoParser.swift`
- `Sources/LassoParser/Providers.swift`
- `Sources/LassoParser/Runtime.swift`
- `Sources/LassoParser/ScriptBodyParser.swift`
- `Tests/LassoParserTests/LassoParserTests.swift`

Do not overwrite or revert that work. Treat it as the baseline for the next
implementation session.

## Documentation Grounding

Public Lasso 9 docs are useful for the target runtime semantics even though
the syntax here is Lasso 8-era:

- LassoGuide Methods: signatures support required, optional, keyword, rest,
  and type-constrained parameters. The docs explicitly say `...` rest
  parameters produce a local named `rest`, and keyword parameters cannot
  distinguish overloads during method selection.
- LassoGuide Multiple Dispatch: candidates are selected by name, arity, and
  type constraints; constrained parameters sort above unconstrained ones,
  required above optional, and declared parameters above rest-parameter
  matches. Ambiguity is a failure or may be resolved at definition time by
  replacement.
- LassoGuide Types: Lasso types are data plus methods. Type expressions have
  sections including `data`, `parent`, `trait`, and public/protected/private
  methods. Data members are instance-specific, `self->'name'` and `.'name'`
  access internal data, public data creates getters/setters, and `onCreate`
  is the constructor hook.

References:

- <https://lassoguide.com/language/methods.html>
- <https://lassoguide.com/language/types.html>

The legacy syntax shapes below are grounded in local real-corpus files, but
they are not the intended ceiling of support:

- `getGeoIPInfo.inc`
- `js_timer.inc`
- `_begin_tags.inc`

(Corrected 2026-07-10 — an architect review found the path this section
originally cited doesn't exist on this machine. The real `LassoStartup`
path these three files live under is the one this whole project's other
sessions have used for live verification — see the `lasso-real-corpus-
paths` project memory rather than hardcoding it in committed docs, since it
embeds a real instance/site identifier.)

Important implementation stance: support the documented Lasso 8
`define_tag`/`define_type` contract intentionally, not only the shapes that
happen to appear in these samples. The corpus determines priority and fixture
selection; the Lasso 8 documentation determines the supported flag/parameter
surface.

Current doc-acquisition status:

- The known LassoSoft archive entry
  `https://www.lassosoft.com/LP8_5-Document-Downloads` returned HTTP 500 when
  checked on 2026-07-10.
- Resolved 2026-07-12: the Language Guide PDF was already present locally
  at `References/Lasso/Lasso 8.5 Language Guide.pdf` (849 pages). No CLI
  text-extraction tool was available in this environment initially
  (`pdftotext`/`PyPDF2`/`pymupdf` all missing, and `textutil -convert txt`
  silently copied raw PDF bytes instead of extracting text) —
  `brew install poppler` provided a working `pdftotext`, used with
  `-layout` to extract the full document, then `grep`/`sed` to locate
  Chapter 57 "Custom Tags" and Chapter 58 "Custom Types" (found by
  listing every `^Chapter [0-9]` heading and its first line, not by
  guessing page numbers).

## Documented Flags And Parameters

Source: `References/Lasso/Lasso 8.5 Language Guide.pdf`, Chapter 57
"Custom Tags" (`Table 2: [Define_Tag] Parameters`) and Chapter 58 "Custom
Types" (`Table 1: Tags for Creating Custom Data Types`, `Table 3: Prototype
Tag`, `Table 4: Callback Tags`).

### `[Define_Tag]` parameters (Chapter 57, Table 2)

| Flag | Documented meaning | Status |
| --- | --- | --- |
| `'Tag Name'` (positional) | Name of the tag being defined. Required. | Implemented |
| `-Required='name'` | Declares a required parameter, bound as a local. | Implemented (binder doesn't yet error on a missing one — see below) |
| `-Optional='name'` | Declares an optional parameter. | Implemented (same binder as `-Required`; this interpreter doesn't yet distinguish the two at bind time, for either legacy or modern tags) |
| `-Type='typeName'` | Type-constrains the immediately preceding `-Required`/`-Optional` parameter. | Implemented — translated to the same `name::type` binary shape modern `define` parameters already use |
| `-Copy` | The preceding parameter is passed by copy instead of by reference. | Deferred — this interpreter's `LassoValue` is already Swift value-type/copy-on-write, so parameter aliasing (the real problem `-Copy` solves) isn't a hazard here the same way; recognized and discarded, not acted on |
| `-Namespace` | Places the tag in a namespace. | Deferred — this interpreter has one flat tag registry for every tag, modern or legacy; not a legacy-specific gap |
| `-Async` | Runs the tag in a separate thread; can't return a value. | Deferred — no background/thread execution model exists |
| `-Atomic` | Serializes concurrent calls to the same tag. | Deferred — no concurrency-guarding primitive wired to custom tags |
| `-Container` | Marks the tag as a container tag (`[Tag]...[/Tag]`, body via `[Run_Children]`). | Deferred — real feature gap: `BlockBuilder` recognizes a fixed keyword set at *parse* time, while custom-tag registration happens at *render* time; treating an arbitrary registered tag name as block-shaped needs a different mechanism, not a quick add |
| `-Looping` | Container tag that also advances `[Loop_Count]`. | Deferred, same reason as `-Container` |
| `-Priority='High'/'Low'/'Replace'` | Where the tag sits in an overload/redefinition calling chain. | Deferred — no multi-definition calling-chain model; last registration for a name wins |
| `-Criteria=(expr)` | Guards whether this definition is used for a given call. | Deferred, same reason as `-Priority` |
| `-Description` | Free-text description, retrievable via `[Tag->Description]`. | Deferred — no tag-reflection member surface for legacy-defined tags yet |
| `-EncodeNone` | Suppresses default encoding of the tag's return value. | Deferred — this interpreter doesn't auto-HTML-encode substitution tag output the way real Lasso does, so this flag has no analogous behavior to hook into yet |
| `-Privileged` | Runs with the defining user's permissions, not the caller's. | Deferred — no permission/user model in this interpreter at all |
| `-ReturnType` | Type-checks the tag's return value. | Deferred — parsed as an ordinary flag and discarded; no return-type enforcement for modern tags either |
| `-RPC` / `-SOAP` | Exposes the tag as an XML-RPC/SOAP remote procedure call. | Deferred — no RPC/SOAP layer in this adapter |

### `[Define_Type]` (Chapter 58, Table 1) and related tables

| Item | Documented meaning | Status |
| --- | --- | --- |
| `'Type Name'` (positional) | Name of the type. Required. | Implemented |
| Additional positional strings | Parent/base types this type inherits from. | Parsed (kept as ordinary positional arguments, not dropped/erroring) but not acted on — no inheritance execution |
| `-Namespace` | Namespace for the type. | Deferred, same as `Define_Tag`'s `-Namespace` |
| `-Prototype` (Table 3) | Compiles the type definition once and copies the pre-built prototype per instance, for performance. | Parsed, not acted on — this interpreter always re-runs data-member-default evaluation per instance already (no prototype-copy optimization exists, for legacy or modern types), so the *behavior* is already correct, just not the *performance characteristic* the flag is about |
| `-Description` | Free-text description. | Deferred, same as `Define_Tag`'s `-Description` |
| `[Local]`/`local:` inside the type body | Instance data member declaration with a default-value expression. | Implemented — becomes `LassoDataMemberDefinition`; default expressions can reference a constructor-local `params` (see Implementation Status above) |
| `[Define_Tag]`/`define_tag:` inside the type body | Member tag (method) declaration. | Implemented — becomes `LassoMethodDefinition`, dispatched through the same `LassoMethodDispatcher` modern type methods use |
| `[Private]`...`[/Private]` (Table 1) | Marks wrapped instance variables/tags as private to the type. | Deferred — no visibility enforcement distinct from `.public` for legacy-declared members |
| `[Null->onCreate]` (Table 4 callback) | Called after instance construction, with the constructor's own call arguments. | Implemented, with a known arity-dispatch nuance — see Implementation Status above |
| `[Null->onConvert]` (Table 4) | Called when the instance is cast to string/integer/decimal. | Works as an ordinary member method already (no special-casing needed — it's just a `Define_Tag('onConvert')` inside the type, dispatched like any other method); automatic invocation on implicit cast (e.g. string interpolation) is not wired up, matching this interpreter's existing (pre-legacy-pass) `onConvert` support level for modern types |
| `[Null->onDestroy]`/`onSerialize`/`onDeserialize`/`_UnknownTag` (Table 4) | Destruction/serialization/unknown-member callbacks. | Deferred — no object lifecycle/serialization hooks exist in this interpreter for modern types either; not a legacy-specific gap |

No silent gaps: everything documented above is either implemented or named
with a concrete reason it's deferred.

## Corpus Shapes To Support

### 1. Parenthesized Legacy Type

Seen in `getGeoIPInfo.inc`:

```lasso
[
    define_type('GeoIPInfo');
        local(
            'ip' = (params->first ? params->first | client_ip),
            'country' = string,
            'connection' = array(-database='site_mysql', -table='ip_blocks')
        );

        define_tag('onCreate');
            inline(self->connection, -sql=(...));
            self->country = field('countryname');
        /define_tag;

        define_tag('onConvert');
            return(...)
        /define_tag;
    /define_type;
]
```

Interpretation:

- `define_type('GeoIPInfo')` opens a type definition.
- Top-level `local(...)` inside the type body appears to declare instance
  data members and defaults.
- Nested `define_tag('onCreate')` and `define_tag('onConvert')` are methods
  on that type.
- `params` appears to be the constructor-call argument collection available
  during type initialization/default evaluation.
- `self->field` and `self->'field'` both need to target object data.

### 2. Parenthesized Legacy Custom Tag

Seen in `_begin_tags.inc`:

```lasso
define_tag('send_email2', -required='body')
    email_send(
        -to='...',
        -from='...',
        -subject='SiteDebugging Information',
        -body=#body)
/define_tag
```

Interpretation:

- `define_tag('send_email2', -required='body')` opens a standalone custom
  tag/method definition.
- `-required='body'` should become a required parameter named `body`.
- The body is slash-closed by `/define_tag`, with optional semicolon.
- The existing modern `LassoCustomTagDefinition` storage can likely be reused.

### 3. Colon-Call Legacy Type

Seen in `js_timer.inc`:

```lasso
[
define_type: 'js_timer', 'integer', -prototype;
    local: 'timer'=integer;

    define_tag: 'oncreate';
        (self->'timer') = _date_msec;
    /define_tag;

    define_tag: 'onconvert';
        local: 'output'=(_date_msec - (self->'timer'));
        #output ->(setformat: -groupchar=' ');
        return: #output + ' ms';
    /define_tag;

    define_tag: 'reset';
        (self->'timer') = _date_msec;
    /define_tag;

    define_tag: 'integer';
        return: (_date_msec - (self->'timer'));
    /define_tag;

    define_tag: 'seconds';
        return: (_date_msec - (self->'timer')) / 1000.0;
    /define_tag;

/define_type;
]
```

Interpretation:

- `define_type:` is a colon-call opener with positional args:
  type name, parent/base type, and flags such as `-prototype`.
- `local:` inside the type body declares data members/defaults.
- `define_tag:` inside the type body declares methods.
- Legacy `return:` colon-call syntax should be normalized to current
  `return(...)`.
- Parent/base type can initially be parsed and stored but not fully executed,
  unless the specific `integer` base/prototype behavior is required by tests.

## Recommended Implementation Plan

### Step 1: Add Fixtures Before Behavior

Add focused parser/runtime tests using scrubbed, minimal versions of the three
real shapes:

- `legacyDefineTagParenthesizedRegistersStandaloneTag`
- `legacyDefineTypeParenthesizedRegistersTypeAndMethods`
- `legacyDefineTypeColonRegistersTypeAndMethods`
- `startupLoaderReportsNoErrorsForLegacyDefinitionFixtures`

Keep the fixtures small and credential-free. Preserve the real delimiter
shapes (`[...]`, semicolons, slash closers, colon calls).

### Step 2: Normalize Legacy Definition Syntax Into Existing Runtime Models

Do not build a second runtime path. Legacy syntax should lower into the same
models already used by modern syntax:

- standalone `define_tag(...)` -> `LassoCustomTagDefinition`
- nested `define_tag(...)` inside a type -> `LassoMethodDefinition`
- `define_type(...)` / `define_type:` -> `LassoTypeDefinition`
- legacy `local(...)` / `local:` inside type -> `LassoDataMemberDefinition`

This keeps dispatch, object construction, `self`, and `onCreate` shared.

### Step 3: Add A Legacy Definition Body Parser

Add a small parser helper rather than expanding `ScriptBodyParser` into a
monolith. Suggested shape:

```swift
struct LegacyDefinitionParser {
    mutating func parseDefineTagOpening(...)
    mutating func parseDefineTypeOpening(...)
    mutating func readUntilLegacyClose("define_tag" / "define_type")
}
```

It should handle:

- parenthesized-call opener: `define_tag('name', -required='x')`
- colon-call opener: `define_tag: 'name';`
- optional trailing semicolon;
- slash closer with optional semicolon: `/define_tag;`
- nested `define_tag` inside `define_type`;
- comments and CRLF-normalized input.

### Step 4: Map Legacy Parameters And Flags

This is a documentation-driven step. Do not treat the observed corpus flags as
the full surface. First recover the official Lasso 8/8.5 definition of
`define_tag` and `define_type`, then implement the documented set in priority
order.

Known from corpus and therefore first-priority:

- `-required='name'` -> required positional parameter `name`
- `-optional='name'` with no observed default -> optional parameter defaulting
  to `void`
- positional opener values naming the tag/type
- nested `define_tag` inside `define_type`
- prototype/base-type metadata on `define_type`

Expected documentation work before implementation:

- enumerate every documented `define_tag` parameter/flag;
- enumerate every documented `define_type` parameter/flag;
- classify each as semantic, metadata-only, or unsupported/deferred;
- add parser fixtures for every documented flag, even when runtime behavior is
  intentionally a no-op;
- record unsupported documented flags with explicit diagnostics and matrix
  entries, not silent drops.

Implementation principle: unknown flags should only be "unknown" after the
documented list has been consulted. If a flag is documented but not yet
implemented, call it out as a known unsupported compatibility gap. If a flag is
not documented and only appears in corpus, catalog it separately as an observed
extension/variant.

### Step 5: Map Legacy Type Locals To Data Members

Inside `define_type`, treat:

```lasso
local('timer'=integer)
local: 'timer'=integer;
```

as data member definitions. Defaults should be parsed as expressions and
evaluated during object construction, matching the existing modern data
member path.

Potential special case:

- `local('ip' = (params->first ? params->first | client_ip))`

This needs either:

- a constructor-local `params` value during object construction, or
- a narrower fallback where `params->first` reads the first constructor
  argument.

Recommendation: add a real constructor-local `params` as an array/staticarray
of evaluated constructor args before evaluating data defaults and `onCreate`.

### Step 6: Support Legacy `return:` And Parenthesized Self Members

The corpus uses:

- `return: expression`
- `(self->'timer') = value`
- `#output ->(setformat: -groupchar=' ')`

The first two are needed for the legacy definition fixtures. The `setformat`
member call can be deferred if `js_timer` only needs to load, but it will be
needed to execute `onConvert` faithfully.

### Step 7: Verify Against Real Startup Folder

Run the startup loader against the real instance's `LassoStartup` folder
(see the `lasso-real-corpus-paths` project memory for the path — not
hardcoded here since it embeds a real instance identifier).

Acceptance:

- all 10 startup files load without parser/runtime errors, or any remaining
  failures are new, explicitly cataloged constructs;
- no credentials or real startup source are committed;
- fixture tests pass;
- live server smoke still renders the previously passing pages.

## Recommended Scope Boundaries

Do now:

- parse both legacy definition openers;
- register standalone custom tags;
- register legacy types and methods;
- map legacy type-local declarations to data members;
- support constructor `params` enough for `getGeoIPInfo`;
- support legacy `return:`.
- implement or explicitly classify the documented `define_tag`/`define_type`
  flags.

Defer unless immediately encountered:

- full prototype/base-type semantics for `-prototype`;
- full `onConvert`/`asString` coercion behavior beyond ordinary method calls;
- `setformat` formatting fidelity;
- inheritance beyond storing the parent/base type name;
- LJAPI/LCAPI binary tag compatibility.

## Risks

- Legacy `define_type` can look syntactically like ordinary colon-call code,
  so the parser must only commit after seeing known openers.
- The current modern type system is first-pass; forcing full Lasso 8
  inheritance/prototype behavior into it too early may destabilize the better
  understood Lasso 9 path.
- `params` in legacy constructors is semantically important and easy to fake
  incorrectly. Add explicit tests for first argument/default behavior.
- Startup loading intentionally records per-file errors and continues; tests
  should assert the specific file error list, not only "some files loaded."

## Suggested Work Session Plan

1. Recover authoritative Lasso 8/8.5 docs for `define_tag` and `define_type`.
2. Add a "Documented Flags And Parameters" section to this plan with source
   citations and a support classification for every documented item.
3. Create scrubbed fixtures from the three corpus snippets above.
4. Add additional parser fixtures for every documented flag/parameter shape.
5. Add failing parser/runtime tests.
6. Implement legacy standalone `define_tag(...)`.
7. Implement legacy `define_type(...)` with nested `define_tag(...)`.
8. Implement colon-call `define_type:` / `define_tag:`.
9. Add constructor `params` support.
10. Run `swift build --target LassoParser`, `swift run LassoParserSmoke`, and
   `swift test`.
11. Run startup-loader smoke against the real `LassoStartup` directory.
12. Update `compatibility-matrix.md`, `lasso-perfect-server.md`, and Sulu.
13. Commit as one coherent compatibility pass if tests and startup smoke pass.

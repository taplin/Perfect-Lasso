# Legacy `define_tag` / `define_type` Plan

Date: 2026-07-10

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
- Before implementing the full legacy-definition pass, recover the Lasso 8 /
  Lasso 8.5 docs from another source if needed: downloaded PDF, Wayback
  capture, local archive, LassoSoft support copy, or another trustworthy mirror.
- Once found, add a short sourced summary of `define_tag` and `define_type`
  parameters/flags to this document before coding the general parser.

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

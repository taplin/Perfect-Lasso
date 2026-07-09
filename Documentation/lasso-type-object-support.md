# Lasso Type And Object Support

Date: 2026-07-09

## Scope

This is the first runtime slice for Lasso 9 `define Name => type { ... }`
support. It is intentionally a durable foundation, not a complete Lasso
object model.

Implemented:

- `define Name => type { ... }` parses into a first-class `LassoTypeDefinition`
  node instead of being skipped with an unsupported diagnostic.
- `data` declarations are preserved as object data members.
- `public`/`protected`/`private` method declarations are parsed and stored.
- Object construction through `Name(...)` creates a `LassoObjectInstance`.
- `onCreate(...)` is invoked after construction when present.
- `self` is available while running a method body.
- `self->member = value` mutates object data.
- `object->member` reads object data when no method matches.
- `object->method(...)` dispatches to stored methods.
- Basic multiple dispatch is implemented by method name, arity/defaults, and
  simple type constraints such as `value::integer` versus unconstrained
  fallback methods.
- The `.member` shorthand parses as `self->member`, enough for expression
  bodies and common method internals.

The implementation stays inside the existing synchronous tree-walking
interpreter. No bytecode VM, async runtime, or external language dependency
was introduced.

## Dispatch Notes

Lasso 9's documented method system uses multiple dispatch: methods sharing a
name are selected at call time based on parameter shape and type constraints,
not keyword labels alone.

This first pass resolves candidates by:

1. method name;
2. positional argument count fitting required/default parameters;
3. simple type-constraint matches against `LassoValue.typeName`;
4. highest specificity score, where constrained earlier parameters outrank
   unconstrained/defaulted parameters.

This covers the immediate corpus shape (`onCreate(store::string)`,
`requestFeatured()`, `requestCategory(category::string, skip=0)`) and gives
the resolver a place to grow toward the full documented behavior.

## Current Corpus Findings

`/Library/WebServer/scrubsSite/api.lasso` defines:

- `ApiHandler`
- `data public store::string`
- `public onCreate(store::string)`
- `public requestFeatured()`
- `public requestCategory(category::string, skip=0)`

The type body uses:

- `self->store = #store`
- `self->store` inside `inline(...)`
- object construction with `ApiHandler($store_abbrev)`
- object method calls like `#api->requestFeatured()`

Those constructs are now represented and executable in the parser/runtime
test fixture.

Separately, the live `/api.lasso` blocker found before this work,
`unknownFunction("excludeBots")`, is not part of `ApiHandler`. It is a normal
custom tag defined in `components/site_setup_tags.inc`, while `_begin.lasso`
only loads `components/koi_setup.inc` before calling `excludeBots`. That
should be investigated as a startup/include ordering issue or as a missing
startup library load, not as object dispatch.

## Known Gaps

- Traits and parent/inheritance metadata are not implemented.
- Full method visibility enforcement is not implemented.
- `inherited`, `..member`, and deeper parent dispatch are not implemented.
- Rest parameters (`...`) are not implemented in method dispatch.
- Keyword-parameter validation is not complete.
- Type constraints currently match primitive/object type names directly; full
  Lasso `isa`/trait matching remains future work.
- `_unknowntag` fallback is not implemented.
- Expression-bodied methods are parsed for simple return expressions, but the
  first verified runtime path uses brace bodies.

## Verification

Passed:

- `swift build --target LassoParser`
- `swift build --target LassoPerfectCRUD`
- already-built `.build/out/Products/Debug/LassoParserSmoke`
- real API parse smoke via `LASSO_SMOKE_REAL_API_PAGE_PATH`

Blocked:

- full `swift test` could not be rerun in this session because SwiftPM
  regenerated a duplicate checkout file
  `.build/checkouts/swift-nio/Sources/_NIOBase64/Base64 2.swift`; removing
  that generated file requires elevated approval, and the approval system was
  out of quota at the time. This is an environment/generated-build-state
  blocker, not a source compile failure in the changed targets.

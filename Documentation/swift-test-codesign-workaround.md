# `swift test` Codesign Workaround

Date: 2026-07-09

## The problem

`swift test` (and `swift build --build-tests`) has failed since this
package's earliest commits with:

```
.../LassoParserTests.xctest: resource fork, Finder information, or similar
detritus not allowed
error: CodeSign .../LassoParserTests.xctest failed with a nonzero exit code
```

Root cause: files in this development environment (both hand-authored
source and the fixture files bundled as test resources via `.copy(...)` in
`Package.swift`) carry macOS extended attributes — `com.apple.provenance`
and sometimes `com.apple.macl` — that get copied into the generated
`.xctest` bundle. Apple's ad-hoc codesign step (`codesign --sign -`) rejects
bundles containing that metadata.

## Workaround

```bash
xattr -cr Sources Tests Documentation Package.swift Package.resolved
rm -rf .build
export COPYFILE_DISABLE=1
swift test
```

- `xattr -cr` strips the extended attributes from source and test-resource
  files before the build reads them.
- `rm -rf .build` forces a fully fresh build — an incremental build can
  reuse an already-tainted intermediate bundle from before the attributes
  were cleared.
- `COPYFILE_DISABLE=1` stops macOS's resource-copy machinery from
  re-attaching this metadata while SwiftPM copies fixture files into the
  bundle during the build.

**This is not fully deterministic.** In testing, this recipe succeeded on
about 2 of 3 clean attempts and failed the same way on the third, with no
observed difference in the commands run. If `swift test` fails with the
codesign error after running the recipe above, just retry the whole
sequence (`xattr -cr` again, `rm -rf .build` again, `swift test` again) —
it has reliably succeeded within one or two retries. Once one `swift test`
run succeeds in a session, subsequent runs in the same `.build` tend to keep
working without needing to repeat the recipe, unless a source change forces
the test bundle to be regenerated from scratch.

## Why this matters

Before this was found, verification for this package's parser/runtime work
relied entirely on the custom `LassoParserSmoke` executable (`swift run
LassoParserSmoke`), because `swift build --build-tests` and `swift test`
never completed. That executable remains useful (it's a faster, more direct
smoke check, and doesn't depend on this workaround), but it isn't a
substitute for actually running the Swift Testing suite in
`Tests/LassoParserTests/LassoParserTests.swift` — this workaround makes that
possible for the first time.

## A real bug this uncovered

Running the actual test suite (rather than the smoke executable) surfaced a
genuine bug the smoke executable's plain command-line execution had been
masking: a test recursing a custom tag 100 levels deep crashed the entire
test process outright (signal 10 / SIGBUS) instead of hitting the intended
`LassoRuntimeError.tagCallDepthExceeded` guard. The guard was set to trip at
64 nested calls, but each level of tag-call recursion in this interpreter
costs several real Swift stack frames (the `renderNodes` closure, a fresh
`RendererEngine`, the `Evaluator` call chain) — enough that an XCTest worker
thread's smaller default stack overflowed before the 64-level guard's own
check ever got a chance to fire. The command-line smoke executable never
hit this because a plain process's main thread gets a much larger default
stack. Fixed by lowering the guard to 20 (see
`Sources/LassoParser/Runtime.swift`, `maximumTagCallDepth`) — comfortably
below where a real overflow occurs, not just below the number that happened
to crash in this one test.

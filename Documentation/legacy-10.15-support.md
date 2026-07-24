# Legacy macOS 10.15 (Catalina) / 11 (Big Sur) Support

**Branch:** `legacy_10.15`. **Never merged into `main`** — pull *from* `main`
periodically (`git merge main`), never push this branch's own content the
other direction. `main` stays permanently free of the dylib-bundling/rpath
logic this document covers.

This document is the single source of truth for this branch: why it exists,
exactly what it does and doesn't do, its security model, and how to build,
package, and deploy it.

## Status: concluded, not being pursued further (2026-07-24)

**Verdict**: real hardware confirmed the concurrency-dylib bundling in this
document works, but also surfaced a second, harder blocker
(`libmysqlclient` needing a from-source rebuild — see
[First real-hardware result](#first-real-hardware-result-2026-07-24)) on
top of the already-known `URLSession.data(for:)` gap. Together, that's more
from-scratch C/Swift rebuild effort than is reasonable to maintain as an
ongoing burden for one hardware tier. **Recommendation: use
[OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher)
to get 10.15/11-capped hardware onto macOS 12+ instead**, where this
project's existing, fully verified support just works — see
`Documentation/macos-deployment-targets.md`'s Verdict section for the full
reasoning.

This branch, its release (`v0.2.1-legacy10.15`), and everything below are
kept for the record, not deleted — matching this project's usual practice
for superseded investigations. Nothing here should be represented as
"working": the real-hardware run below is the closest this got, and it
didn't reach a launched server.

## Why this branch exists and what it actually changes

Real demand: a family of Intel Mac hardware whose OS support ended at 10.15
is currently running real Lasso sites. Supporting it — with a clear upgrade
path to newer hardware — helps those operators test and onboard
Perfect-Lasso. `main` is capped at macOS 12.0 (Monterey) as of this session;
this branch is the one place work toward the two versions below that lives.

### The toolchain constraint that shaped this branch's real scope

Two things make "just lower `platforms:` further" not work, discovered
before writing any code here:

1. **This machine's SwiftPM cannot emit a binary honestly labeled below
   macOS 12.0.** The SDK's `SDKSettings.plist` declares
   `MinimumDeploymentTarget = 12.0`, and `swift build` silently clamps to it
   regardless of what `Package.swift` requests — already documented in
   `Documentation/macos-deployment-targets.md`'s Method section, re-confirmed
   live via `plutil -p` on the SDK's `SDKSettings.plist`. Setting
   `platforms: [.macOS(.v10_15)]` here would build fine and silently produce
   a `minos 12.0` binary anyway — actively misleading, which is why
   `Package.swift` on this branch deliberately still declares `.v12`, with a
   comment explaining why.
2. **An older Xcode isn't a workaround.** The code needs
   `swift-tools-version: 6.2` and modern Swift 6 language features (actors,
   `@concurrent`, etc.) that no Xcode old enough to lack the 12.0 clamp can
   even parse.
3. **The target OS can't build this project itself either.** 10.15/11 can't
   run a modern-enough Xcode/Swift toolchain, so this project's *existing*
   release pattern (git-tag a source tarball; the deploying machine runs
   `swift build -c release` itself — see `Documentation/releasing.md`) is
   structurally impossible for this tier. This branch instead ships a
   **pre-built binary** via a GitHub Release — the first time this project
   has done that; see [Packaging](#packaging) below.

Given this, what the branch actually does is narrower and more honest than
the original "target 10.15" framing:

- Build at `.v12` (same as `main` — this toolchain's floor, not a choice).
- Bundle the Swift concurrency runtime dylib **and** every other
  non-system dylib the release binary actually links against, and add an
  `@executable_path` rpath, as a **defensive, not guaranteed**, measure —
  10.15/11 don't ship `libswift_Concurrency.dylib` as part of the OS the way
  12.0+ does, and the same is true (for a different reason) of the whole
  Homebrew `mysql-client` cascade. See
  [Packaging](#packaging) for the full, empirically-verified bundle list —
  it's six dylibs, not one; a first pass at this script only bundled the
  concurrency dylib and would have shipped a binary that immediately failed
  with `Library not loaded` for `libmysqlclient` on any machine without
  Homebrew installed.
- A best-effort (grep + Apple-docs cross-reference, **not**
  compiler-verified) audit of what else in the dependency graph might not
  run on 10.15/11 even if the dylib question is solved — see
  [API audit](#api-audit-task-198-reframed) below. This audit already found
  a real, more-serious-than-the-dylib-question blocker.

## Security review: the rpath + bundled-dylib attack surface

`-Xlinker -rpath -Xlinker @executable_path` (in `Package.swift`'s
`LassoPerfectServer` target, this branch only) tells dyld to search the
directory containing the executable for any `@rpath/...`-referenced dylib.
The packaging script bundles six such dylibs alongside the binary (see
[Packaging](#packaging)) — most prominently `libswift_Concurrency.dylib`,
needed because 10.15/11 don't provide it as part of the OS. This is a
textbook dylib side-loading surface: **anyone who can write into that
directory can plant a malicious same-named dylib and get arbitrary code
execution inside `lasso-perfect-server`'s process** the next time it
launches.

### Threat model, established before designing mitigations

- **No code-signing/Library Validation exists in this project** — no
  Developer ID, ad-hoc builds only. The OS-level protection that would
  normally block a wrong-Team-ID dylib from loading isn't available here.
  Filesystem permissions are the *only* real control — this is not a
  "belt and suspenders" situation, it's the whole belt.
- **`lasso-perfect-server` already runs unprivileged.** Confirmed in
  `Sources/LassoPerfectServer/main.swift`: default port 8181 (admin console
  8990, FM Admin API 16000, both 127.0.0.1-only), no root, no
  setuid/seteuid anywhere. Real deployments (`Documentation/lasso-perfect-server.md`)
  front it with an nginx reverse proxy that itself runs unprivileged too. So
  the worst case here is compromise of whatever service account runs the
  process — serious (database/FileMaker credentials, site content, network
  position) but not a root-level system compromise.

### Mitigations — enforced by the packaging script and runbook, not just documented

1. **Directory permissions are a hard requirement.** The deploy directory
   must be owned by the service account only, mode `750`; the dylib `640`.
   `Scripts/package-legacy-release.sh` sets these inside the tarball (`tar`
   preserves mode bits on extract); the [deploy runbook](#deploy-runbook)
   makes an `ls -la` permission check an explicit pre-flight step before
   ever running the binary — not a footnote, a command you actually run.
2. **Supply-chain integrity.** The packaging script computes SHA-256 of
   both the binary and the dylib it copies from the Xcode toolchain, writes
   `CHECKSUMS.txt` into the release, and the pull command on the test
   server verifies it **before** extracting anything — guards against
   tampering in transit or a compromised release channel.
3. **Narrow rpath.** `@executable_path` only — nothing broader, nothing
   shared with any other process or service.
4. **Blast-radius containment.** This mechanism ships only in this branch's
   own release artifact. It never touches `main`'s `Package.swift`, never
   affects the default `.v12` build or release path — the "clear
   separation" this branch exists to provide, enforced structurally (a
   `git diff main` on `Package.swift` shows exactly one added
   `linkerSettings` block on one target) rather than by convention alone.
5. **Ad-hoc code-signing** (`codesign --sign -`) is a normal, free step in
   the packaging script — stated plainly: this is Gatekeeper/quarantine
   bookkeeping only, **not** a security control here. Without a real
   Developer ID there is no Library Validation to enable.

### Residual risk — stated plainly, not softened

This is fundamentally a **directory-trust model**. If the deploy
directory's permissions are ever misconfigured — group-writable, world-
writable, wrong owner — this rpath is remote code execution against
whatever the service account can reach. There is no defense against that
beyond getting the permissions right and keeping them right. Treat the
`ls -la` check in the runbook as load-bearing, not optional.

## API audit (task #198, reframed)

A real compiler-verified typecheck against 10.15/11 isn't achievable with
this toolchain (same clamp as above), and hand-invoking `swiftc` file-by-
file across ~10 separate packages with C interop (MySQL/FileMaker/
PostgreSQL client libraries) isn't a practical use of effort for a
still-unverified target. Instead, this is a grep-based sweep of the full
dependency graph — `Perfect-CRUD`, `Perfect-XML`, `Perfect-MySQL`,
`Perfect-PostgreSQL`, `Perfect-Redis`, `Perfect-SQLite`, `Perfect-FileMaker`,
`Perfect-FileMaker-AdminAPI`, `Perfect-Session`, `Perfect-SMTP`,
`Perfect-NIO`, and `Perfect-Lasso` itself — for `@available(macOS N, *)`
markers and known post-10.15/11 API families, explicitly **not**
compiler-verified.

### Finding: `URLSession.data(for:)` is a real, unsolved 12.0-exact floor

This is the audit's most important result, and it's a **different, more
serious problem than the concurrency-dylib question**: `URLSession`'s
async `data(for:)` / `data(for:delegate:)` methods are Apple's own API,
gated at exactly `@available(macOS 12.0, *)` in Foundation — and unlike the
core Swift concurrency runtime, **this is not part of the back-deployable
runtime story**. There is no toolchain-provided dylib to bundle for it; it's
tied to the OS's own shipped `Foundation.framework` version. If it's
genuinely absent below 12.0 (expected, unconfirmed without real hardware),
no amount of dylib bundling fixes it.

Found in active use in:

| Package | File |
|---|---|
| `Perfect-Lasso` | `Sources/LassoParser/NetworkRequests.swift` (the `network_request`-style native tag) |
| `Perfect-Lasso` | `Sources/LassoCrawlReport/CrawlReport.swift` |
| `Perfect-Lasso` | `Sources/LassoCrawlReport/Sitemap.swift` |
| `Perfect-FileMaker` | `Sources/PerfectFileMaker/FileMakerServer.swift` |
| `Perfect-FileMaker-AdminAPI` | `Sources/PerfectFileMakerAdminAPI/FMAdminClient.swift` |
| `Perfect-FileMaker-AdminAPI` | `Sources/PerfectFileMakerAdminAPI/FMAdminSession.swift` |
| `Perfect-SMTP` | `Sources/PerfectSMTP/MTASTS/MTASTSHTTPFetching.swift` |
| `Perfect-SMTP` | `Sources/PerfectSMTP/MTASTS/MTASTSPolicyManager.swift` |

**Practical implication**: any Lasso site using outbound network-request
tags, the crawl-report tool, sitemap fetching, FileMaker connectivity (the
FileMaker Data API/Admin API client both go through `URLSession`), or
SMTP's MTA-STS policy fetching is expected **not to work** on 10.15/11,
independent of whether the concurrency-dylib bundling in this branch
resolves cleanly. This is real follow-up work (a completion-handler-based
`URLSession` fallback path, `#available`-gated same as the WebSocket-
upgrade-handler pattern already used in `Perfect-NIO`) — not attempted in
this branch, since it's a second, separately-scoped piece of work per
package, and there's no point building it before the concurrency-dylib
question itself is verified on real hardware.

### Everything else checked

- **No other `@available(macOS N, *)` markers above 11 exist anywhere in
  the dependency graph**, except `Perfect-NIO/Sources/PerfectNIO/Server.swift`'s
  `configureUpgrade` (`@available(macOS 13, *)`) — already handled: its own
  `configureUpgradeFallback` runs automatically below 13.0, this is not a
  new gap.
- **No `Regex`/`RegexBuilder` (Swift's native regex, macOS 13+) usage
  anywhere.** Perfect-Lasso's own regex handling
  (`Sources/LassoParser/RegularExpressions.swift`) is built entirely on
  `NSRegularExpression` (ICU-backed, stable since OS X 10.7) — likely-safe.
- **No `Network.framework` (`NWConnection`/`NWListener`) usage** anywhere.
- **No `AttributedString`, `.formatted(...)`, `ISO8601FormatStyle`, or other
  newer Foundation formatting-API usage** anywhere — the handful of grep
  hits were all comments referencing already-fixed `Duration`/
  `ContinuousClock` code (see Tiers 1-2 of the parent plan) or an unrelated
  `connectDuration` string field, not live API calls.
- **Structured concurrency itself (`async`/`await`, actors, task groups) is
  not the blocker** — genuinely good news, confirmed in the parent
  investigation (`macos-deployment-targets.md`): a minimal async/await +
  `TaskGroup` program compiles, links, and runs at
  `-target x86_64-apple-macosx10.15` on this machine. The core concurrency
  runtime *is* back-deployable, which is the entire premise this branch's
  dylib bundling is built on.

This audit is a snapshot, not a guarantee — it can't catch a symbol that's
merely *weak-linked* rather than `@available`-gated, and it can't catch
runtime-only failures. Treat "no gap found" as "no gap found by this method,"
not "confirmed safe."

## Packaging

`Scripts/package-legacy-release.sh` builds, bundles, checksums, and tars a
release artifact. It does **not** publish anything — it stops short of
`gh release create`/`git push` (a real, externally-visible action) and
prints the exact command to run instead. See the script itself for the
full step list; summary:

1. Sanity checks (on `legacy_10.15`, clean tree, recently merged from `main`,
   `dylibbundler` and the Intel `mysql-client` present).
2. `swift build -c release --triple x86_64-apple-macosx12.0` — the honest,
   buildable target. Intel, since 10.15/11-capped hardware predates Apple
   Silicon.
3. **Bundle the general third-party dependency cascade with `dylibbundler`**
   (`brew install dylibbundler`) — recursively finds and rewrites everything
   the binary needs that isn't part of the OS: `libmysqlclient.24.dylib` and
   its own cascade (`libssl.3`, `libcrypto.3`, Homebrew's `libz.1`
   — a *different* build from the system one, `libzstd.1`), plus
   `libswiftCompatibilitySpan.dylib` (a newer Swift 6.2-era back-deployment
   shim, needed on *any* OS since it's too new to be part of any shipping
   macOS's system Swift runtime yet — not 10.15/11-specific). Verified
   directly: a first attempt at this script only bundled the concurrency
   dylib and would have shipped a binary that fails immediately with
   `Library not loaded: /usr/local/opt/mysql-client/lib/libmysqlclient.24.dylib`
   on any machine without that exact Homebrew install — `dylibbundler` is
   what `Documentation/release-target-plan.md §4` had already identified as
   the right tool for this, from an earlier, separate investigation into
   pre-built binaries.
4. **Bundle `libswift_Concurrency.dylib` by hand**, separately from step 3 —
   `dylibbundler`'s system-library heuristic always treats anything under
   `/usr/lib/swift/` as "the OS already has this," which is correct for
   every sibling `libswiftXXX.dylib` there (real system content since
   10.14.4) but specifically wrong for this one file below 12.0. Also adds
   an rpath of `/usr/lib/swift` **to this dylib itself** — it has its own
   internal `@rpath/libswiftCore.dylib` reference that needs to resolve
   against the real system Swift runtime, not dyld's default fallback
   search path (`/usr/local/lib`, `/usr/lib`), which doesn't include
   `/usr/lib/swift`.
5. A verification pass: `otool -L` on the final binary must show only
   `@executable_path/`-, `/usr/lib/`-, or `/System/Library/`-prefixed
   dependencies — anything else fails the script outright rather than
   producing a silently-broken artifact.
6. Ad-hoc `codesign --sign -` on the binary and every bundled dylib
   (bookkeeping only — see the security review above). Done *last*, after
   every `install_name_tool` call, since each one invalidates any earlier
   signature.
7. `shasum -a 256` on all six files → `CHECKSUMS.txt`.
8. `chmod` the staged files (`750`/`640`) before tarring.
9. `tar czf lasso-perfect-server-vX.Y.Z-legacy10.15-x86_64.tar.gz`.
10. Print the `gh release create` command for you to review and run.

## Deploy runbook

Run on the test server itself, in order — don't skip the checksum or
permission steps:

```bash
# 1. Download the release artifact and its checksums
curl -fsSL -O https://github.com/taplin/Perfect-Lasso/releases/download/vX.Y.Z-legacy10.15/lasso-perfect-server-vX.Y.Z-legacy10.15-x86_64.tar.gz
curl -fsSL -O https://github.com/taplin/Perfect-Lasso/releases/download/vX.Y.Z-legacy10.15/CHECKSUMS.txt

# 2. Extract — CHECKSUMS.txt lists the files *inside* the tarball, so it
#    can only be checked against them after extracting. Extracting itself
#    is harmless (nothing executes); the checksum gate that matters is the
#    one below, which runs before anything is ever launched.
mkdir -p ~/lasso-legacy && tar -xzf lasso-perfect-server-*.tar.gz -C ~/lasso-legacy
cp CHECKSUMS.txt ~/lasso-legacy/

# 3. Verify BEFORE running anything
cd ~/lasso-legacy && shasum -a 256 -c CHECKSUMS.txt

# 4. Lock down permissions
chmod 750 ~/lasso-legacy
chmod 750 ~/lasso-legacy/lasso-perfect-server
chmod 640 ~/lasso-legacy/*.dylib

# 5. Confirm permissions before ever running it — this is not optional
ls -la ~/lasso-legacy

# 6. First real-hardware test
~/lasso-legacy/lasso-perfect-server
```

Two possible outcomes, both useful:

- **`dyld: Library not loaded` / `symbol not found`** — a real API gap
  surfaced on real hardware. Report exactly what it says; it feeds directly
  back into the [API audit](#api-audit-task-198-reframed) above (start by
  checking if it's the known `URLSession.data(for:)` gap, or something new).
- **Clean launch** — the first real verification this whole approach has
  ever had. Confirms the dylib bundling + rpath actually resolves on a
  machine that doesn't already have the system copy (impossible to verify
  on any machine capable of building this project — see
  [Known limitations](#known-limitations)).

## First real-hardware result (2026-07-24)

`v0.2.1-legacy10.15` was actually run on real 10.15/11 hardware for the
first time. Mixed result, but the harder half of the two open questions
came back **positive**:

- **The Swift concurrency dylib bundling worked.** No duplicate Objective-C
  class registration, no `Foundation.framework`-conflict crash — the
  specific failure mode that could never be reproduced or ruled out on any
  machine with the system runtime already present (see below) simply didn't
  happen. This is the first real evidence the core premise of this whole
  branch is sound.
- **It failed one step later, on `libmysqlclient.24.dylib` itself:**
  ```
  dyld: Symbol not found: __ZTTNSt3__118basic_stringstreamIcNS_11char_traitsIcEENS_9allocatorIcEEEE
    Referenced from: /Users/gsp/lasso-legacy/./libmysqlclient.24.dylib (which was built for Mac OS X 14.0)
    Expected in: /usr/lib/libc++.1.dylib
  Abort trap: 6
  ```
  Exactly the gap flagged below as suspected — now confirmed with the
  precise missing symbol. **This is a full launch blocker, not a degraded
  MySQL-only feature**: dyld resolves every needed symbol for the whole
  binary before any code runs, so `lasso-perfect-server` cannot start at
  all — independent of whether the deployment actually uses MySQL — until
  this is fixed. The Homebrew bottle's C++ standard library usage needs
  something from a newer `libc++.1.dylib` than 10.15/11 ships.
- **Not yet reached**: the `URLSession.data(for:)` gap, full MySQL runtime
  behavior, or anything else — the process aborts at dyld load time, before
  any application code runs.

**Next step**: build `libmysqlclient` from source with an explicit low
deployment target (e.g. `-DCMAKE_OSX_DEPLOYMENT_TARGET=10.15`) rather than
relying on the current Homebrew bottle — not yet attempted, real work
(MySQL's client library pulls in OpenSSL, which would need the same
treatment). This is now the critical-path item for this tier: nothing else
can be verified until the binary can launch at all.

## Known limitations

- **`minos` reads 12.0, not 10.15.** This is expected and documented above,
  not a bug to "fix" by editing `Package.swift`'s `platforms:` — see the
  toolchain-constraint section.
- **The dylib-resolution question was unverifiable on any machine that
  already has the system Swift concurrency runtime — until the first real
  10.15/11 run (above) confirmed it works.** This session had reproduced
  and precisely diagnosed why *dev-machine* testing could never settle this
  (an earlier probe in `macos-deployment-targets.md` had only observed the
  symptom): running the fully-bundled binary here crashes at startup with
  `objc[...]: Class _TtCs25CheckedContinuationCanary is implemented in both
  /usr/lib/swift/libswift_Concurrency.dylib and .../libswift_Concurrency.dylib`
  — `Foundation.framework` on any machine capable of building this project
  has its own direct, absolute-path dependency on the system
  `libswift_Concurrency.dylib`, which loads independently of and *in
  addition to* this binary's own (correctly rewritten,
  `@executable_path`-relative) reference, producing duplicate Objective-C
  class registrations. A genuine 10.15/11 `Foundation.framework` predates
  Swift concurrency entirely and has no such dependency — and indeed, the
  real-hardware run above hit no such conflict.
- **`URLSession.data(for:)` is a known, real, unresolved blocker** for
  several code paths — see the audit above. Not yet reached on real
  hardware (the `libmysqlclient` failure above happens first, before any
  application code runs) or attempted in this branch.
- **Confirmed on real hardware: the bundled `libmysqlclient` cascade does
  not work** — see [First real-hardware result](#first-real-hardware-result-2026-07-24)
  above for the exact symbol and why it's a full launch blocker.
  `otool -L` had already confirmed the final binary has no remaining
  non-`@executable_path`/non-system dependency *paths*, and each bundled
  dylib was individually re-signed and its own `install_name`/rpath
  double-checked — but static path resolution was never sufficient to
  predict this: the actual C++ symbols the bottle needs simply aren't
  present in 10.15/11's own `libc++.1.dylib`. This blocks the whole binary
  from launching, so `URLSession.data(for:)` and everything else downstream
  remains untested for the same reason: nothing gets the chance to run.
- **Root cause identified: the Intel `mysql-client` Homebrew bottle is
  itself built for macOS 14.0, not 12.0 or below.** Suspected from a build-
  time linker warning (`building for macOS-12.0, but linking with dylib
  '...libmysqlclient.24.dylib' which was built for newer version 14.0`),
  now confirmed as the actual real-hardware failure — a missing
  `libc++` symbol (`__ZTTNSt3__118basic_stringstreamIcNS_11char_traitsIcEENS_9allocatorIcEEEE`)
  that 10.15/11's own `libc++.1.dylib` doesn't export. Fixing this needs a
  `mysql-client` build (from source, with an explicit low deployment
  target, or an older bottle/release) that doesn't depend on anything newer
  — not attempted yet; see the critical-path note above. `libpq`
  (`Perfect-PostgreSQL`) is unverified in the same way, untested either
  direction.
- **The audit above is grep-based, not compiler-verified** — treat it as a
  starting point for real-hardware testing, not a guarantee.

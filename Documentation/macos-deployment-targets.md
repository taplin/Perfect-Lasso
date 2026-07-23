# macOS Deployment Targets — Findings and Baselines

## Current target

**macOS 14.0 (Sonoma), Apple Silicon + Intel.** This is the actual, enforced
minimum across the full dependency graph behind `lasso-perfect-server`:
`Perfect-XML` → `Perfect-FileMaker` / `Perfect-FileMaker-AdminAPI`,
`Perfect-CRUD` → `Perfect-MySQL`, `Perfect-Session` (+ its `Perfect-PostgreSQL`
/ `Perfect-Redis` / `Perfect-SQLite` resolution deps), `Perfect-NIO`,
`Perfect-SMTP`, and `Perfect-Lasso` itself. Every manifest in that graph
declares `platforms: [.macOS(.v14)]`.

This document records two things: (1) exactly what is fixed and why 14.0 is
the real floor, and (2) what it would additionally take to reach three
progressively lower targets — **13.0 (Ventura)**, **12.0 (Monterey)**, and
**10.15 (Catalina) / 11 (Big Sur)** — motivated by real demand: there's a
family of hardware whose OS support ended at 10.15, and people currently
running Lasso on that hardware would be able to test and onboard this
project if it ran there too, with a clear upgrade path to newer hardware
afterward. None of the three levels below are built/merged yet — this is
scoping, not a changelog — but each is broken down by exactly what's known,
what's already built-and-verified-but-unmerged, and what's still an open
question, so a future session can pick up any one of them without
re-deriving this research.

**Status at a glance:**

| Target | Blockers found | Built & verified | Merged |
|---|---|---|---|
| 14.0 (current) | — | — | ✅ |
| 13.0 (Ventura) | 2 packages, 15 call sites | ❌ | ❌ |
| 12.0 (Monterey) | + 2 independent Perfect-NIO API gaps | 1 of 2 | ❌ |
| 10.15/11 (Catalina/Big Sur) | + concurrency runtime back-deployment packaging, + an unaudited API range | ❌ | ❌ |

## Method

Every number below came from actually compiling, not from reading
`@available` annotations and guessing. The one hard lesson from this pass:
`swift build -Xswiftc -target -Xswiftc arm64-apple-macosxN.N` does **not**
override the compiled target when the manifest declares `platforms:` —
SwiftPM/XCBuild appends its own `-target` flag derived from the manifest
*after* the override, and the last one on the command line wins. A `swift
build` that reports "Build complete!" under that technique may have silently
compiled at whatever the manifest says, not the intended lower target. The
only reliable methods: edit `platforms:` directly in the manifest and run a
plain `swift build`/`swift test`, or bypass SwiftPM and invoke
`swiftc`/`clang` directly. Either way, the proof is inspecting the actual
compiled output — `otool -l <object-or-binary> | grep -A3 LC_BUILD_VERSION`
— and confirming `minos` matches intent. This document's numbers were all
otool-verified this way, not inferred from "it compiled."

This machine's toolchain (Xcode 27.0 / macOS 27.0 SDK) also enforces its own
hard floor: `SDKSettings.plist` declares `MinimumDeploymentTarget = 12.0`, and
`swift build` silently clamps anything below that regardless of what a
manifest requests. Nothing below macOS 12.0 can be verified with `swift
build` on this install — an older Xcode might not have this restriction, but
that's untested.

## Why 14.0 is the real floor (not something lower)

**`Perfect-NIO`'s connection accept loop** (`Sources/PerfectNIO/Server.swift`,
`runAcceptLoop`) uses `withThrowingDiscardingTaskGroup` to spawn one child
task per accepted connection for the server's entire lifetime, without
retaining completed-connection result storage. That API requires macOS 14.0
(Sonoma) — otool-confirmed on the unmodified code: `minos 14.0` exactly, no
lower and no higher. This is the single highest floor in the graph, and 14.0
absorbs everything else in the stack without any code changes.

**`Perfect-XML`** used to have a *higher* floor — 15.0 (Sequoia), via
`String(validating: bytes, as: UTF8.self)` in `XMLStream.swift`'s
`String(_:count:default:)` initializer (a deliberate fix for a real bug: the
previous `Int8`-cast decode trapped on any UTF-8 continuation byte ≥ 0x80).
Fixed by swapping to Foundation's `String(bytes:encoding:)`, which validates
identically (`nil` on invalid UTF-8) with no OS version gate at all —
otool-confirmed down to 12.0. This fix is what actually unblocks reaching
14.0 for the whole graph, since 15.0 would otherwise have been the binding
constraint, not Perfect-NIO's 14.0.

**Everything else** in the graph (`Perfect-CRUD`, `Perfect-MySQL`,
`Perfect-Session`, `Perfect-FileMaker`/`-AdminAPI`, `Perfect-SMTP`,
`Perfect-PostgreSQL`, `Perfect-Redis`, `Perfect-SQLite`) has a real code floor
at or below 13.0 — comfortably under 14.0 with no changes needed.

## Intel (x86_64) support at 14.0

Verified directly via SwiftPM's real cross-compilation support, not just
reasoning about portability:

```
swift build --triple x86_64-apple-macosx14.0
```

Both `Perfect-XML` and `Perfect-NIO` (the two highest-risk packages — the
latter pulls in `NIOSSL`'s vendored BoringSSL, which ships genuine
per-architecture assembly, e.g. `chacha-x86_64-apple.S`,
`aes128gcmsiv-x86_64-linux.S`) built clean. Confirmed the output was a real
x86_64 Mach-O (`file <object>.o`) at `minos 14.0` (`otool -l`). This is
repeatable for any package in the graph as a manual verification step —
there is no automated CI in this ecosystem yet (no `.github/workflows` exist
in any of these repos' actual git history; the `ci/` scripts and
`.github/workflows/linux.yml` sitting in the parent `Perfect-Resurrection`
directory are local-only validation tooling for Linux, not wired to any of
these packages' now-separate GitHub repos).

**Known, currently-unverifiable gap:** the actual Homebrew-installed C client
libraries (`mysql-client`, `mariadb-connector-c`, `libpq`) that
`Perfect-MySQL`/`Perfect-MariaDB`/`Perfect-PostgreSQL` link against via
`pkg-config`. This dev machine is Apple Silicon only — no Intel-side Homebrew
(`/usr/local/Homebrew`) is installed — so there's no way to link-test an
x86_64 build of those three packages here. There's no specific reason to
expect a problem (these are standard, widely-bottled libraries), but it's
unverified without real Intel hardware or an Intel Homebrew install.
Separately: this machine's *currently installed* arm64 bottles for those
libraries are themselves built at `minos 26.0` — a bottle-freshness issue,
not a code issue, but worth remembering when actually deploying to an older
OS on either architecture: whoever builds/installs the C client library
needs a bottle (or from-source build) that targets 14.0 or lower, independent
of anything in this Swift code.

## Baseline: what it would take to reach macOS 13.0 (Ventura)

**Two packages need changes** — this is wider than it first looked. The
original pass through this investigation only checked the dependency graph
(`Perfect-SMTP`) and found the floor there; a later pass swept
`Perfect-Lasso`'s *own* source (`grep` for `Duration`/`ContinuousClock`/
`Task.sleep(for:)`) and found the identical API family used **13 more times
across 5 files**, previously undocumented:

| File | Call sites |
|---|---|
| `Sources/LassoCrawlReport/CrawlReport.swift` | 1 |
| `Sources/LassoPerfectSMTP/LassoEmailProviderImpl.swift` | 1 |
| `Sources/LassoPerfectServer/AdminConsoleIntegration.swift` | 5 (3× `Task.sleep(for:)`, 2× bare `ContinuousClock()` construction sites, plus a `ContinuousClock.Instant`-typed helper) |
| `Sources/LassoPerfectServer/RestartReadiness.swift` | 2 |
| `Sources/LassoPerfectServer/main.swift` | 6 |

All of these are `Task.sleep(for: .milliseconds(...))`/`.seconds(...)` or
`ContinuousClock()`/`ContinuousClock.Instant` — the same fix pattern as
`Perfect-SMTP`'s already-scoped rewrite below applies directly: swap
`Task.sleep(for:)` for `Task.sleep(nanoseconds:)` (no floor beyond basic
concurrency), and replace `ContinuousClock`-based monotonic deadline/elapsed
tracking with `DispatchTime` arithmetic. Mechanical and bounded, but real
work across meaningfully more surface area than previously documented — not
yet scoped file-by-file the way `Perfect-SMTP`'s two sites are below.

**`Perfect-SMTP`**'s floor is exactly 13.0, from two `Duration`/
`ContinuousClock` call sites:

- `Sources/PerfectSMTPCore/RetryBackoffPolicy.swift` — `Duration`-typed
  backoff config (`.seconds(900)` etc.), converted to `TimeInterval` via a
  `Duration.timeIntervalValue` extension for `Date().addingTimeInterval(...)`.
  Trivially replaceable: change the fields to `TimeInterval` directly, drop
  the conversion extension. No design tradeoff — `Duration` has no unique
  capability over `TimeInterval` here.
- `Sources/PerfectSMTP/SMTPConnectionPool.swift` — `Duration`-typed
  `idleTimeout`/`circuitBreakerResetTimeout`/`replyTimeout`/
  `dataTerminationTimeout`, and `ContinuousClock`/`ContinuousClock.Instant`
  for monotonic idle/circuit-breaker deadline tracking (`returnedAt`,
  `case open(until: ContinuousClock.Instant)`). This one is a genuine,
  deliberate correctness choice — `ContinuousClock` is immune to wall-clock
  adjustments, `Date`-based elapsed-time tracking is not. Replacing it means
  rewriting the deadline logic against `DispatchTime`
  (`DispatchTime.now() + .seconds(...)`, comparing `.uptimeNanoseconds`),
  which is monotonic too but a more involved, bounded rewrite — not just a
  type swap. Would need its own correctness re-verification (the existing
  circuit-breaker/idle-timeout tests would need to keep passing under the
  `DispatchTime` implementation) before merging.

Nothing else in the graph is above 13.0, so this is the only work item.

## Baseline: what it would take to reach macOS 12.0 (Monterey)

Two independent things, both in `Perfect-NIO`, neither of which is a simple
manifest edit:

### 1. The accept loop's 14.0 requirement (`withThrowingDiscardingTaskGroup`)

A working, tested fix exists (built and verified during this investigation,
then set aside once 14.0 became the actual target — not merged, kept here as
a reference in case Monterey support is revisited):

```swift
private static func runAcceptLoop(_ serverChannel: HTTPServerChannel,
                                  finder: any RouteFinder,
                                  isTLS: Bool) async {
    do {
        if #available(macOS 14, *) {
            try await withThrowingDiscardingTaskGroup { connections in
                try await serverChannel.executeThenClose { inbound in
                    for try await upgradeResult in inbound {
                        connections.addTask {
                            await Server.handleConnection(upgradeResult, finder: finder, isTLS: isTLS)
                        }
                    }
                }
            }
        } else {
            try await Server.runAcceptLoopBounded(serverChannel, finder: finder, isTLS: isTLS)
        }
    } catch {
        // Server channel closed (cancellation / shutdown) or the accept loop failed.
    }
}

/// Pre-macOS-14 fallback: a regular task group has no way to release a finished
/// child's result without the body calling `next()`, so an unbounded add-and-forget
/// loop here would retain bookkeeping for every connection accepted over the
/// server's whole lifetime. Capping in-flight connections and calling `next()` to
/// free a slot before accepting past the cap keeps memory bounded; new connections
/// simply queue at the kernel/NIO level until a slot frees.
private static func runAcceptLoopBounded(_ serverChannel: HTTPServerChannel,
                                         finder: any RouteFinder,
                                         isTLS: Bool) async throws {
    let maxConcurrentConnections = 4096
    try await withThrowingTaskGroup(of: Void.self) { connections in
        var active = 0
        try await serverChannel.executeThenClose { inbound in
            for try await upgradeResult in inbound {
                if active >= maxConcurrentConnections {
                    _ = try await connections.next()
                    active -= 1
                }
                connections.addTask {
                    await Server.handleConnection(upgradeResult, finder: finder, isTLS: isTLS)
                }
                active += 1
            }
        }
    }
}
```

Verified by forcing the fallback branch permanently on (`#available(macOS
999, *)`) and running the full `PerfectNIOSmokeTests` suite (46 tests —
plain HTTP, WebSocket echo, WebSocket-upgrade rejection, multi-socket
reuse-port) against it: all pass, including clean cancellation/shutdown
through `withServer`'s teardown path. Also otool-confirmed a scratch build
at `platforms: [.macOS(.v12)]` with this change compiles — this part alone
would get the accept loop to 12.0.

The bounded cap (4096) is a real, deliberate behavior change versus today's
unbounded design — new connections queue once the cap is hit rather than
every accept immediately spawning a handler task. Worth a proper
`swift-concurrency-pro` review before ever merging, same as any change to
this file.

### 2. A second, independent 13.0 floor: the typed WebSocket-upgrade handler

Discovered only by actually trying to build at 12.0 with the accept-loop fix
in place — the accept loop was not the only constraint.
`Server.configureUpgrade`/`bind()` (run unconditionally for *every*
connection, regardless of whether the app defines any WebSocket routes)
uses `NIOTypedHTTPServerUpgradeHandler<HTTPOrWebSocket>`, which the compiler
rejects below macOS 13.0: "runtime support for parameterized protocol types
is only available in macOS 13.0.0 or newer." This is internal to
`swift-nio`'s typed-upgrade API, not something in Perfect-NIO's own code that
was previously touched. Confirmed empirically: build fails at `.v12`,
succeeds at exactly `.v13`.

So the accept-loop fix alone only gets Perfect-NIO to **13.0**, not 12.0.

A further fix is structurally possible — `swift-nio`'s `NIOHTTP1` module
still ships the older, non-generic `HTTPServerUpgradeHandler` (confirmed
present, no version gate), so a second `#available(macOS 13, *)` dual path
could fall back to it below 13.0. This is **not implemented** — it's a
separate, comparably-sized piece of work from the accept-loop fix: it
touches `configureUpgrade`'s pipeline construction directly (not just the
accept loop), and needs its own correctness verification of the WebSocket
handshake/rejection behavior (the same things `testWebSocketEcho` /
`testWebSocketRejectsNonWebSocketPath` cover today). Scoping and
implementing this would be the actual next step if Monterey support is ever
revisited.

### Net picture for a 12.0 target

Perfect-XML's fix (already shipped) + Perfect-SMTP's fix (documented above,
not done) + Perfect-NIO's accept-loop fix (built, verified, not merged) get
everything to **13.0**. Reaching 12.0 specifically requires the additional,
unscoped WebSocket-upgrade-handler rework in Perfect-NIO.

## Baseline: what it would take to reach macOS 10.15 (Catalina) / 11 (Big Sur)

This is new ground — nothing below 12.0 had been investigated before this
pass, and this machine's toolchain can't even reach it via a normal `swift
build` (see Method above: `SDKSettings.plist` clamps at 12.0). Everything in
this section comes from direct `swiftc`/`clang` invocation and outside
research, not a real SwiftPM build of this project, and none of it has been
tested against real 10.15/11 hardware or a VM.

### The core issue: Swift's concurrency runtime isn't part of the OS below 12.0

Async/await, actors, and task groups themselves are **not** the blocker —
this is the one genuinely good news item in this whole investigation.
Verified directly: a minimal async/await + `TaskGroup` program compiles,
links, and *runs* when built with `swiftc -target x86_64-apple-macosx10.15`
on this machine (`otool -l` confirms `minos 10.15` on the resulting binary).
What actually changes below macOS 12.0 is that the OS no longer ships
`libswift_Concurrency.dylib` as part of its own built-in Swift runtime — the
compiled binary weak-links `@rpath/libswift_Concurrency.dylib` with an rpath
of `/usr/lib/swift`, which macOS 12+ populates itself but 10.15/11 do not.

Apple has genuinely, officially supported back-deploying concurrency to
macOS 10.15/iOS 13 since Xcode 13.2 (announced alongside the original
concurrency rollout) — the toolchain ships a back-deployment copy of the
dylib at
`$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib`
(confirmed present on this machine, ~1.1 MB) for exactly this purpose.

### The complication: this support is undocumented for command-line tools

Apple's back-deployment story is well-trodden for **app bundles** — embed
the dylib in `Contents/Frameworks/`, which Xcode/`.app` structure already
has a natural place for. `lasso-perfect-server` is a bare SwiftPM
executable, not an app bundle, and Apple's release notes and official docs
say nothing about that case at all. A community-established, [Apple-DTS-confirmed
recipe exists](https://nonstrict.eu/blog/2023/using-async-await-in-a-commandline-tool-on-older-macos-versions/)
for CLI tools specifically:

1. Copy `libswift_Concurrency.dylib` from the toolchain path above to
   alongside the built executable.
2. Add an executable-relative rpath so the dynamic linker finds the bundled
   copy: in `Package.swift`'s executable target,
   ```swift
   linkerSettings: [
       .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
   ]
   ```
   (or `@executable_path/../lib` if the dylib ships in a sibling `lib/`
   directory instead of directly alongside the binary).

Reported caveats from that write-up: ~1.1 MB size overhead, and Apple DTS
involvement was needed to confirm the bundle-placement approach avoids code
signing issues — this is real but non-trivial ground, not a one-line fix.

**Verification gap, found directly and worth being honest about**: I built
both the plain and the bundled-dylib versions of the probe binary on this
machine (macOS 27) and used `DYLD_PRINT_LIBRARIES=1` to see which copy of
`libswift_Concurrency.dylib` actually got loaded at runtime. Even with the
bundled copy present and `@executable_path` in the rpath list, **dyld on
this machine loaded the system's own `/usr/lib/swift/libswift_Concurrency.dylib`
instead of the bundled one** — modern dyld silently prefers an OS-cached
copy of a system-install-name dylib over a same-named bundled one. This
means the actual runtime-resolution behavior of this recipe is **not
verifiable on any machine that already has the system copy** — which is
every machine capable of building this project today. Confirming this
recipe genuinely works requires a real bare 10.15 or 11 install (or VM)
with no system-provided concurrency runtime at all; that verification has
not been done and shouldn't be assumed from the write-up alone.

### What's still completely unscoped for this range

- **The 13 additional 13.0-floor call sites and Perfect-NIO's two 12.0
  items** (both sections above) still apply on top of everything in this
  section — they don't go away at a lower target, they compound.
- **No API audit has been done for the 10.15–12.0 range itself.** Everything
  above 12.0 was checked via real `swift build`; everything below 12.0 has
  only had the concurrency-runtime question probed directly. `Perfect-CRUD`,
  `Perfect-MySQL`, `Perfect-Session`, `Perfect-FileMaker`/`-AdminAPI` were
  asserted in the 14.0 section above to have "a real code floor at or below
  13.0" — but that check only confirmed *at or below 13.0*, not specifically
  *at or above 10.15*. A real audit needs either an Xcode version whose SDK
  doesn't clamp below 12.0, or continued direct `swiftc`/`clang` probing
  package-by-package the way the concurrency-runtime question was probed
  here.
- **The C client libraries** (`mysql-client` for `Perfect-MySQL`,
  `libpq` for `Perfect-PostgreSQL`) are a separate, already-flagged concern
  from the 14.0 section above (Homebrew bottles built at whatever macOS
  version Homebrew currently targets, independent of this project's own
  Swift code) — this gets *more* binding, not less, at a 10.15/11 target,
  since it's less likely a current Homebrew bottle for either library
  supports linking against something that old at all. Unverified either
  way; would need checking against whatever a real 10.15/11 deployment
  actually uses for its C client library (a from-source build, a vendored
  older bottle, or a different distribution channel entirely).

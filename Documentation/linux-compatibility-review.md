# Linux Compatibility Review — Lasso Adapter

## Goal

The Lasso adapter (`LassoParser`/`LassoPerfectServer`/`LassoCrawlReport`/
`LassoPerfectCRUD`/`LassoPerfectSession`/`LassoSubsetCrawler`) was meant to
inherit the parent `Perfect Resurrection` project's Linux-portability goal,
but the push to get a working interpreter has been macOS-only in practice:
every build/test/live-verify this whole project has done so far ran on this
one macOS dev machine, using macOS-specific tooling (Homebrew MySQL client
paths, Gatekeeper codesign/xattr workarounds). Tim's target: ship a simple
build early adopters — many hosting their existing Lasso sites on Linux
VMs — can run against their real content.

## Method

Rather than reason about Linux-compatibility purely from reading the code,
I used Apple's `container` CLI (already installed on this machine,
`brew install container`) to actually attempt a real Linux build — the same
`swift:6.3.2-noble`-based image the parent monorepo's existing
`ci/Dockerfile.linux`/`ci/validate-linux.sh` already use for Linux CI of the
underlying Perfect-NIO/Perfect-CRUD/Perfect-MySQL/Perfect-Session libraries
— against a scratch copy of the adapter, with the real parent monorepo
mounted read-only to satisfy its local path dependencies. This produces
concrete compiler output, not speculation.

## Headline finding

**The Lasso adapter itself has never been built on Linux, and is not part
of the parent monorepo's existing Linux CI at all.** The parent
`Perfect-Resurrection` monorepo (a sibling directory, not this repo) already
has real, working Linux validation — `.github/workflows/linux.yml` +
`ci/validate-linux.sh`, Ubuntu container-based, covering Perfect-NIO,
Perfect-CRUD, Perfect-MySQL, Perfect-Session, and everything else it
resurrected — but a `grep` across that entire CI setup for any mention of
this adapter (`LassoParser`, `LassoPerfectServer`, etc.) returns nothing.
The dependency graph this adapter builds on is Linux-proven; the adapter's
own code has not been.

This is good news structurally (the hard, load-bearing parts — SwiftNIO
HTTP server, MySQL/session drivers — are already known to work on Linux)
and means the actual gap is narrow and concretely fixable, not a rewrite.

## Confirmed blocking issues (empirically reproduced)

### 1. `swift-tools-version: 6.4` cannot be satisfied by any current Linux Swift toolchain

Checked live today: `swift:6.4-noble` and `swift:latest` on Docker Hub both
still resolve to **Swift 6.3.2** — 6.4 has not shipped as an official Linux
image yet (matches the parent monorepo's own CI notes, which hit the exact
same wall and pinned to `6.3.2-noble` for that reason). Attempting to
resolve the adapter's own `Package.swift` (which declares
`swift-tools-version: 6.4`) against that toolchain fails immediately:

```
error: 'perfect resurrection': package 'perfect resurrection' is using Swift tools version 6.4.0 but the installed version is 6.3.2
```

Every dependency this adapter has — Perfect-NIO, Perfect-CRUD,
Perfect-MySQL, Perfect-Session, and every other resurrected library in the
parent monorepo — declares `swift-tools-version: 6.2`. Nothing in the
adapter's own source uses a 6.3- or 6.4-only language feature; this reads
as an artifact of whatever local Xcode toolchain default was active when
the file was created, not a deliberate requirement.

**Fix:** change line 1 of `Package.swift` to `// swift-tools-version: 6.2`
— matches every dependency exactly, zero known risk.

### 2. `LassoCrawlReport` uses `URLSession`/`URLRequest` without the Linux `FoundationNetworking` import guard

On Linux, `swift-corelibs-foundation` splits networking types
(`URLSession`, `URLRequest`, `URLSessionTaskDelegate`, etc.) into a separate
`FoundationNetworking` module that must be explicitly imported — plain
`import Foundation` isn't enough. `Sources/LassoCrawlReport/CrawlReport.swift`
uses all three with only `import Foundation`. This exact class of bug was
already found and fixed elsewhere in this project family before ("
`FoundationNetworking` conditional import added to Perfect-Authentication
and Perfect-FileMaker-DataAPI" — parent monorepo CI history) — it just
never got applied here since this file has never been compiled on Linux.

Since `LassoPerfectServer` (the actual server executable) unconditionally
`import`s `LassoCrawlReport` (it backs the `LASSO_CRAWL_REPORT=1` self-crawl
diagnostic), this is a hard compile-time blocker for the **entire server
binary** on Linux — not just an optional-feature gap early adopters could
route around.

**Fix** (the same pattern already proven elsewhere in this project family):

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

at the top of `CrawlReport.swift`.

## Checked and confirmed clean (no gap found)

- No `import Darwin` / `import ObjectiveC` / `import Security` /
  `import CryptoKit` anywhere in the adapter's own source.
- No `#if os(macOS)` / `#if !os(Linux)` conditionals anywhere — nothing is
  deliberately gated to Apple platforms only.
- No macOS-only filesystem paths baked into source. The `/opt/homebrew`,
  `/Users/...`, `/var/lasso/...` paths that appeared throughout this
  project's session history were all environment/shell-level, for this one
  dev machine's local corpus/MySQL setup — never compiled into the adapter.
- `ObjCBool` / `FileManager.fileExists(atPath:isDirectory:)` (4 call sites)
  — present and correct in `swift-corelibs-foundation` on Linux.
- `NSRegularExpression` (`LassoSubsetCrawler`, 2 sites) — available on
  Linux (ICU-backed). Not independently regex-behavior-tested this pass;
  flagged as a "re-check once building," not a known gap.
- No POSIX signal handling anywhere (the many `returnSignal` hits in
  `LassoParser` are an unrelated internal control-flow value, not OS
  signals).
- No `Network.framework` / `NIOTransportServices` (Apple-only NIO
  transport) — the server stack is built entirely on standard,
  cross-platform `NIOPosix` + `NIOSSL`, which Perfect-NIO's own prior
  Linux resurrection work already validated (its Tier C Linux CI job).
  Perfect-NIO already carries the correct `#if canImport(Darwin) / import
  Darwin #else / import Glibc #endif` pattern in `TempFile.swift`,
  `MimeReader.swift`, and `#if os(Linux)` blocks in `Server.swift` — the
  adapter inherits this for free.
- All tests use `swift-testing` exclusively — zero `XCTest` anywhere —
  already cross-platform.
- `Package.swift`'s `platforms: [.macOS(.v26)]` does **not** block Linux —
  that array only constrains Apple-platform minimum deployment targets and
  has no bearing on Linux/Windows builds at all. Worth noting as unusually
  restrictive if native macOS support to a wider Mac OS version range is
  ever wanted, but it's not a Linux concern.

## Recommendations

1. **Immediate, zero-risk:** drop `Package.swift` to
   `swift-tools-version: 6.2`.
2. **Immediate, proven pattern:** add the `canImport(FoundationNetworking)`
   guard to `CrawlReport.swift`.
3. **Before an early-adopter release:** add this adapter to the parent
   monorepo's existing `linux.yml`/`ci/validate-linux.sh` — it is the one
   package in the whole ecosystem missing from that infrastructure, and the
   scaffolding (image, tiers, pattern) all already exist; this is a matter
   of one more entry, not new infrastructure.
4. **Deployment-readiness, adjacent to Linux specifically:** there is no
   README at this repo's root, and the only documented MySQL build setup
   (`PKG_CONFIG_PATH=/opt/homebrew/opt/mysql-client/lib/pkgconfig`) is
   Homebrew-specific. Linux hosts need a parallel note:
   `apt install libmysqlclient-dev pkg-config` (Debian/Ubuntu-family;
   package name varies slightly by distro/MySQL vendor), and — unlike
   Homebrew's keg-only install — the client library is usually already on
   the default `pkg-config` search path, so `PKG_CONFIG_PATH` typically
   doesn't need to be set at all on Linux.
5. This project's own codesign/xattr build-retry workaround (used
   throughout this session for macOS Gatekeeper flakiness) is a non-issue
   on Linux — one fewer thing to go wrong for early adopters, not a gap.

## Verification status (2026-07-13, both fixes applied)

Both fixes have been applied to this repo:
- `Package.swift` line 1: `swift-tools-version: 6.2` (was `6.4`).
- `Sources/LassoCrawlReport/CrawlReport.swift`: `#if canImport(FoundationNetworking) import FoundationNetworking #endif` added after `import Foundation`.

Confirmed:
- macOS build still passes unchanged (`swift build`, clean).
- `swift package resolve` against the real `swift:6.3.2-noble`-based Linux
  image (the same `perfect-ci` image the parent monorepo's own Linux CI
  uses) now succeeds cleanly — exit code 0, every dependency including the
  new `swift-crypto` package resolves without error. This confirms finding
  1 is fixed.

**Not re-attempted: a full from-scratch `swift build` of the adapter on
Linux.** A first attempt at this ran for 3.5+ hours (far beyond what a
build this size should take) before the `container` CLI's own control
plane (its `exec`/`stop`/`kill` commands) stopped responding, and had to be
force-killed at the host process level. Whether that run was genuinely
stuck mid-compile or just abnormally slow under this environment's
virtualization couldn't be determined — the tooling itself, not
necessarily the build, was the failure. Given the resolve-level check
above plus the source-level static analysis already done (no Darwin/ObjC/
Security imports, no macOS-only conditionals, `FoundationNetworking` now
guarded correctly, Perfect-NIO's own dependency chain already Linux-CI-
proven), a full compile is very likely to succeed but hasn't been
empirically confirmed end-to-end. **Recommended next step, not done as
part of this review:** run this via the parent monorepo's own
`ci/validate-linux.sh` / GitHub Actions Linux runner (a supervised,
timeout-bounded CI job) rather than an ad hoc local container run, once
this adapter is added to that infrastructure per Recommendation 3 above.

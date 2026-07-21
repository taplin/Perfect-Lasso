# `lasso-perfect-server` release: build-from-source + GitHub source-tarball releases — plan

Date: 2026-07-21
Status: Research complete, empirically verified, scope finalized with the user. Ready to implement.

## 1. Goal, and how it changed from the first draft

The original ask was a downloadable pre-built binary. Investigating that (see §2 below, kept for the record) surfaced enough real friction — bundling five Homebrew dylibs with `dylibbundler`, Gatekeeper/ad-hoc-signing tradeoffs, an unscoped Intel-vs-arm64 question — that the user redirected: **have someone who wants to run this build it locally from source**, with GitHub Releases cutting versioned **source tarballs** (not compiled binaries) so someone who doesn't need the bleeding edge of `main` can grab a stable point-in-time snapshot instead of tracking a moving branch. This is a much smaller, lower-risk project — no packaging script, no dylib bundling, no CI build-and-upload workflow, no codesigning story at all (a locally-built binary is never quarantined the way a browser-downloaded one is, so the Gatekeeper question from the first draft is moot here).

## 2. Superseded: the original pre-built-binary investigation (kept for the record, not being pursued)

Four decisions were made for that approach before the pivot: bundle `libmysqlclient` + `dylibbundler`/rpath fixes (not switch to the currently-broken Perfect-MariaDB — see below), macOS-only, GitHub Releases, ad-hoc signing with documented Gatekeeper bypass. The `otool -L` dependency-graph research from that investigation (§4 below) is still directly useful for anyone who revisits pre-built binaries later, which is why it's kept rather than deleted.

**Perfect-MariaDB, investigated as a `libmysqlclient` alternative**: architecturally viable (same `Perfect-CRUD` backend as Perfect-MySQL, MariaDB Connector/C is LGPL with a real static-link story `libmysqlclient` lacks) but **currently broken** on the dev machine — `swift test` in `/Users/timtaplin/Perfect-Resurrection/Perfect-MariaDB` fails to link against the installed Homebrew `mariadb-connector-c` 3.4.9 with missing symbols (`mysql_stmt_reset`, `mysql_store_result`, etc.), contradicting that package's own README claim of being "real, working, tested infrastructure." Not relevant to the build-from-source approach at all (a user builds against whatever they installed), but worth fixing as its own separate, unscoped task someday.

## 3. What's needed now, verified empirically (not assumed)

**A truly clean clone builds standalone, with zero local-checkout assumptions — confirmed by actually doing it.** Cloned Perfect-Lasso into a scratch directory with no `.swiftpm` mirror config at all, checked out `main`, and ran `swift build -c release --product lasso-perfect-server`: succeeded purely by resolving every Perfect-Resurrection sibling from its `github.com/taplin/*` URL over the network — this is exactly the payoff of the earlier package-mirroring migration (`Package.swift`'s dependencies were switched from local sibling paths to public GitHub URLs specifically so a standalone clone would work; this is the first time that migration's actual purpose has been verified end-to-end rather than just built against the local mirror). Then ran the built binary with a scratch `LASSO_SITE_ROOT` and confirmed it serves a real HTTP request correctly. **Both of these — "does a bare clone build" and "does the built binary actually run and serve" — are the two claims a build-from-source README needs to make, and both are now proven, not asserted.**

**Build prerequisites are smaller than initially assumed.** Checked what's actually required by inspecting the built binary's linked libraries (`otool -L`) and each dependency's own `pkg-config` resolution:
- **`libxml2` and `zlib` need no Homebrew install at all.** `pkg-config --exists libxml-2.0`/`zlib` both succeed on a machine with neither formula installed via Homebrew (confirmed: `brew list libxml2 zlib` reports neither is installed here) — macOS's own SDK ships both headers and `pkg-config` metadata for these natively. The built binary's actual linked copies are macOS's own system dylibs (`/usr/lib/libxml2.2.dylib`, `/usr/lib/libz.1.dylib`), not Homebrew's.
- **`mysql-client` is the one real Homebrew prerequisite** (`Perfect-MySQL`'s `Package.swift` declares `.systemLibrary(pkgConfig: "mysqlclient", providers: [.brew(["mysql-client"])])`). It's Homebrew's "keg-only" (not symlinked into `/opt/homebrew`'s default search paths, so bare `pkg-config --exists mysqlclient` fails even with it installed) — but this is a non-issue for `swift build`: SwiftPM's own `systemLibrary` resolution already runs `brew --prefix <formula>` for each declared `.brew(...)` provider and adds that prefix's `lib/pkgconfig` to its search automatically. **No `PKG_CONFIG_PATH` environment variable needs to be set by hand** — `brew install mysql-client` alone is sufficient, verified by the clean-clone build above succeeding with no `PKG_CONFIG_PATH` set in the shell at all.
- **Toolchain**: this machine's confirmed-working setup is Xcode 27.0 / Swift 6.4 (`swift-driver version: 1.167 Apple Swift version 6.4`), targeting the macOS 27 SDK — newer than `Package.swift`'s declared `.macOS(.v26)` minimum. Document the confirmed-working version (Xcode 27+) rather than assuming the bare declared minimum is sufficient, since it hasn't been tested against an older toolchain on this project.

**No submodules, no monorepo-layout assumptions.** `git clone` alone (no `--recursive`, no sibling repos needed nearby) is sufficient — confirmed by the clean-clone test above.

## 4. Superseded reference material: the pre-built-binary dylib graph (kept for future reference, not acted on now)

For whoever revisits a pre-built-binary release later: a real `swift build -c release` output's `otool -L` showed exactly five non-system dylibs would need bundling — `libmysqlclient.24`, and its own cascade of `libssl.3`/`libcrypto.3` (openssl@3), `libz.1` (a *different* build, Homebrew's `zlib-ng-compat`, not the system one), and `libzstd.1` (zstd) — all Homebrew-absolute-pathed. `libxml2`/`zlib` linked directly by the main binary were already confirmed to be macOS's own system copies and would need no bundling. `dylibbundler` (`brew install dylibbundler`, not currently installed) was identified as the right tool for the recursive rewrite over hand-rolling `install_name_tool` calls.

## 5. Design

### 5.1 Root `README.md` (currently absent — a first for this repo)

Sections, in order:
1. **What this is** — one paragraph, matching this project's own consistently honest maturity framing found elsewhere in `Documentation/` (explicitly not claimed production-ready).
2. **Requirements** — Xcode 27+ (Swift 6.2 tools-version minimum, confirmed working on Xcode 27/Swift 6.4), Homebrew, `brew install mysql-client` (the one real prerequisite — explicitly note libxml2/zlib need no separate install).
3. **Build** — `git clone https://github.com/taplin/Perfect-Lasso.git`, `cd Perfect-Lasso`, `swift build -c release --product lasso-perfect-server`. Note the built binary's location (`swift build -c release --show-bin-path`).
4. **Run** — minimum viable invocation (`LASSO_SITE_ROOT=/path/to/your/site <binary>`), pointer to the fuller configuration reference.
5. **Configuration** — a short summary + link to `Documentation/lasso-perfect-server.md`'s existing Configuration section (already comprehensive; adapt/excerpt rather than duplicate) covering `LASSO_SITE_ROOT`, `LASSO_SERVER_PORT`, the datasource config file (`LASSO_DATASOURCE_CONFIG_PATH`) for MySQL/FileMaker/SMTP, and a pointer to `Documentation/admin-console.md` for the optional admin console.
6. **Using a tagged release instead of `main`** — how to check out a specific `vX.Y.Z` tag (or download that tag's source tarball from the GitHub Releases page) if you don't want to track the bleeding edge.
7. **One enforced, security-relevant startup requirement worth calling out explicitly**: SMTP DKIM key files are hard-rejected at startup (not a warning) if group/world-readable (`ServerConfigError.dkimKeyFilePermissionsTooPermissive`) — `chmod 600` is required, or the server refuses to boot, if DKIM is configured at all.

### 5.2 GitHub Releases with source tarballs

GitHub already auto-generates and attaches "Source code (zip)"/"Source code (tar.gz)" archives to every tag's Release page with zero configuration — no new packaging/build automation is needed for the tarball itself. What genuinely needs doing:
1. Confirm `Package.resolved` is committed and accurate at the moment of tagging (already tracked in this repo) — this is what actually makes a tagged source tarball meaningfully different from an arbitrary `git archive` of `main`: it pins the exact resolved versions of every dependency (including the `branch: "main"`-tracking Perfect-Resurrection siblings) that were known-working at that point in time, so someone building from the tarball later gets the same dependency graph, not whatever those siblings' `main` branches have drifted to since.
2. Cut the tag + Release itself. Given there's no build artifact to attach beyond what GitHub already auto-generates, this can be as simple as `gh release create vX.Y.Z --generate-notes` (auto-generated release notes from commits since the last tag) run manually when a release is warranted — no GitHub Actions workflow is strictly required for this. **Flag explicitly**: creating a public GitHub Release is a visible-to-others action — the actual first tag/release should be a separate, explicitly-confirmed step, not something to do automatically as part of writing the README.

**Full step-by-step runbook (pre-flight checks, the actual tag/release commands, post-release verification, and rollback): [`Documentation/releasing.md`](releasing.md).**

**Real, previously-unknown blocker found while writing that runbook**: `Perfect-Lasso` itself has never been pushed to GitHub at all. Confirmed directly — `git remote -v` in the canonical repo returns nothing, and `gh repo view taplin/Perfect-Lasso` fails with "Could not resolve to a Repository." This is unlike every sibling Perfect-Resurrection library (`Perfect-SMTP`, `Perfect-MySQL`, etc.), all of which already have a real `origin` at `github.com/taplin/*`. The README's `git clone https://github.com/taplin/Perfect-Lasso.git` instruction describes the intended eventual state, not something that works today. Pushing this repo to GitHub for the first time is its own separate, explicitly-confirmed decision (asked and explicitly deferred — "hold off on pushing anything" — as of this writing) — `releasing.md` documents it as an explicit prerequisite step, not something bundled into the release process itself.

### 5.3 Versioning

`vMAJOR.MINOR.PATCH`, starting at `v0.1.0` (not `v1.0.0`) — matches this project's own consistent "early, functional, not yet battle-hardened" framing found elsewhere in its docs.

## 6. Phasing

Small enough to be one phase, not several: write the README, verify every command in it actually works (already partially done above — re-verify against the final README text once written, including the tagged-release-checkout instructions), cut nothing publicly yet. A lightweight review (does the README's instructions actually work when followed literally, is anything overstated/understated about maturity or requirements) before the first real tag gets pushed — scaled to this work's low risk, not the four-way review a security-sensitive feature gets.

## 7. Open items for implementation to resolve

1. Exact wording/tone for the "what this is" maturity framing — match existing `Documentation/` precedent rather than inventing new language.
2. Whether to also add a `CONTRIBUTING.md`/dev-setup section (running the test suite, the `swift-test-codesign-workaround.md` Gatekeeper-on-`.xctest`-bundles issue) — out of scope for "install and run," but worth a one-line pointer if a contributor stumbles onto this repo via the new README.

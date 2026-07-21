# Downloadable `lasso-perfect-server` release binary — plan

Date: 2026-07-21
Status: Research complete, four key decisions made explicitly by the user, not yet implemented.

## 1. Goal

Let someone download a pre-built `lasso-perfect-server` binary (no `swift build` required), configure it purely via environment variables/a config file to point at their own Lasso site codebase, and run it as a working Lasso server — the same way one would download any other server binary (e.g. a database server, a static-site generator) rather than clone and compile a Swift package.

## 2. Decisions made (explicit, not to be re-litigated without a new finding)

1. **MySQL client**: bundle the existing, proven-working `libmysqlclient` dylib (and its own transitive dependencies) alongside the binary, with `install_name_tool`/`dylibbundler`-based rpath fixes — not a switch to Perfect-MariaDB. (Perfect-MariaDB was investigated as an alternative: architecturally viable — same `Perfect-CRUD` backend, MariaDB Connector/C is LGPL and has a genuine static-link story `libmysqlclient` lacks — but it is **currently broken** on the dev machine: `swift test` in `/Users/timtaplin/Perfect-Resurrection/Perfect-MariaDB` fails to link against the installed Homebrew `mariadb-connector-c` 3.4.9 with missing symbols (`mysql_stmt_reset`, `mysql_store_result`, etc.), contradicting that package's own README claim of being "real, working, tested infrastructure." Fixing that would be its own separate, unscoped debugging task — explicitly deferred, not part of this plan.)
2. **Platforms**: macOS only for the first release. Linux is explicitly out of scope for now — `Documentation/linux-compatibility-review.md` already states a full `swift build` of this adapter has never completed end-to-end on Linux (only `swift package resolve` has been verified); getting that working is unproven, non-packaging work that would inflate this plan's scope.
3. **Distribution**: GitHub Releases on `taplin/Perfect-Lasso`, matching how every other Perfect-Resurrection library is already hosted (all have `github.com/taplin/*` origins per the recent package-mirroring migration).
4. **Code signing**: ship ad-hoc signed (`codesign`'s default for an unsigned build — confirmed the current release build is `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not set`), and document the standard Gatekeeper bypass (right-click → Open, or a one-line `xattr -d com.apple.quarantine` command) in the release README. **Not** pursuing Developer ID signing + notarization for v1 — this machine has no "Developer ID Application" certificate (`security find-identity` shows only personal "Apple Development" identities, which are not valid for distributing software to third parties), and enrolling in the paid Apple Developer Program is out of scope for this plan. Revisit if user feedback makes the Gatekeeper friction a real problem.

## 3. Current state, verified directly (not assumed)

**Configuration is already fully portable — the good news that makes this plan tractable at all.** `ServerConfig.load()` (`Sources/LassoPerfectServer/main.swift:322`) reads `LASSO_SITE_ROOT` from the environment, defaulting to the current working directory if unset, and validates the directory exists. Nothing else is mandatory to boot: `LASSO_SERVER_PORT` defaults to `8181`, `LASSO_RENDER_EXTENSIONS` defaults to `lasso,inc,html,htm`, and with no datasource config at all the server still starts (inline datasource calls just throw a clear, catchable `inlineNotConfigured` error at request time). Every optional subsystem (crawl-report, image proxy, admin console, CWP janitor, SMTP) is off by default and independently opt-in via its own `LASSO_*` var. `Documentation/lasso-perfect-server.md`'s "Configuration" section (lines 12–172) already documents this whole surface close to release-ready. **This plan does not need to change any of this — it only needs to make the binary itself runnable outside this dev machine.**

**Dylib dependency tree of the actual release build, verified via `otool -L` on a real `swift build -c release --product lasso-perfect-server` output (not assumed from source):**
```
lasso-perfect-server
├── /usr/lib/libc++.1.dylib                                    — system, fine
├── /usr/lib/libz.1.dylib                                       — system, fine (macOS's own zlib)
├── /usr/lib/libxml2.2.dylib                                    — system, fine (macOS's own libxml2)
├── /System/Library/Frameworks/{Foundation,CoreFoundation,CryptoKit,Security} — system, fine
├── /usr/lib/libobjc.A.dylib, libSystem.B.dylib                — system, fine
├── /usr/lib/swift/libswift*.dylib                              — Swift runtime, OS-provided since ABI stability, fine
└── /opt/homebrew/opt/mysql-client/lib/libmysqlclient.24.dylib — ★ THE problem: Homebrew-absolute-path
    ├── /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib         — also Homebrew-absolute-path
    ├── /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib      — also Homebrew-absolute-path
    ├── /opt/homebrew/opt/zlib-ng-compat/lib/libz.1.dylib      — also Homebrew-absolute-path (NOT the system libz — a different build)
    ├── /opt/homebrew/opt/zstd/lib/libzstd.1.dylib             — also Homebrew-absolute-path
    ├── /usr/lib/libresolv.9.dylib, libc++.1.dylib, libSystem.B.dylib — system, fine
    └── (libssl/libcrypto/zlib-ng-compat/libzstd each only depend on each other + system libs — the graph terminates here, confirmed via otool -L on all four)
```
**Exactly five non-system dylibs need bundling: `libmysqlclient.24`, `libssl.3`, `libcrypto.3`, `libz.1` (zlib-ng-compat's, distinct from the system one already linked directly), `libzstd.1`.** This is a real, but bounded and well-understood problem — not an open-ended one. `libxml2`/`zlib` (the main binary's *direct* links) already resolve to macOS's own system copies and need no bundling at all — a materially smaller problem than the three-system-library risk originally flagged during initial research.

**`dylibbundler`** (a mature, purpose-built macOS tool: walks a binary's full `otool -L` dependency graph recursively, copies every non-system dylib into a target directory, and rewrites every load command via `install_name_tool` to a relative path) is not currently installed (`brew install dylibbundler`) but is the right tool for this — hand-rolling five dylibs' worth of recursive `install_name_tool -change`/`-id` calls correctly (including cross-references between the five, e.g. `libssl` depending on `libcrypto`) is exactly the class of fiddly, easy-to-get-subtly-wrong work this tool exists to automate reliably.

**No CI/release infrastructure exists in Perfect-Lasso today.** Confirmed: no `.github/`, no `ci/` directory, ever, in this repo's history. (The sibling `Perfect-Resurrection` monorepo has its own `.github/workflows/{linux,macos}.yml` + `ci/Dockerfile.linux`/`validate-linux.sh`, but those cover only the Perfect-Resurrection *library* packages — `Documentation/linux-compatibility-review.md` states explicitly the Lasso adapter itself "is not part of the parent monorepo's existing Linux CI at all.") This plan's GitHub Actions workflow is new infrastructure, not an extension of something partial.

**No top-level README exists in Perfect-Lasso.** `Documentation/admin-console.md` is a genuinely polished, close-to-reusable user guide (quick start, dashboard walkthrough, restart mechanics). `Documentation/lasso-perfect-server.md`'s Configuration section is comprehensive but embedded in a long, dated engineering-log-style document, not a standalone doc — needs extraction/adaptation, not authoring from scratch.

**`platforms: [.macOS(.v26)]`** in `Package.swift` sets macOS 26 as the minimum for any build, including the release binary — a very recent OS version for a distributable artifact. Not changing this in this plan (out of scope — lowering it would need investigating whether any actually-used API is macOS-26-specific, a separate, unscoped compatibility investigation) but flagging it here as a real adoption-friction point worth a future look.

**Admin console credentials are self-provisioning** — if `LASSO_ADMIN_CONSOLE=1` is set, the server auto-generates a random bearer token on first run, writes it `chmod 600` to `LASSO_ADMIN_TOKEN_PATH`, and prints it to stdout. No manual setup needed; just needs a line in the release docs telling a user where to look.

**One enforced, security-relevant startup requirement worth calling out in release docs**: SMTP DKIM key files are hard-rejected at startup (not a warning) if group/world-readable (`ServerConfigError.dkimKeyFilePermissionsTooPermissive`, `main.swift:918–924`) — a user setting up DKIM will need `chmod 600` on that key file or the server refuses to boot.

## 4. Design

### 4.1 Release build & packaging script

New script, e.g. `scripts/package-release.sh` (or `Scripts/`, matching whatever casing convention this repo already uses elsewhere — check before creating):
1. `swift build -c release --product lasso-perfect-server`.
2. Create a staging directory, e.g. `lasso-perfect-server-<version>-macos-arm64/`, containing:
   - The built `lasso-perfect-server` binary.
   - A `lib/` subdirectory holding the five bundled dylibs (via `dylibbundler -od -b -x <path-to-binary> -d <staging>/lib -p @executable_path/lib`, or equivalent flags — confirm exact flag set against the tool's actual current CLI during implementation, don't guess from memory).
   - A `README.md` (see §4.4) and a copy of `Documentation/admin-console.md` (optional, or a trimmed pointer to it).
3. Verify the packaged binary's dylib references now resolve to `@executable_path/lib/...` for all five (`otool -L` on the *staged copy*, not the original build output — dylibbundler modifies in place or copies, confirm which during implementation and adjust the script accordingly).
4. Archive as `.tar.gz` (standard for Unix binaries; avoids the macOS `.zip`-specific extended-attribute/quarantine quirks a `.zip` can introduce, and is the more common convention for this class of tool).
5. Compute and record a SHA-256 checksum of the archive (standard practice for downloadable release artifacts; costs nothing, lets users verify integrity, and is a near-zero-effort addition worth including from the start rather than retrofitting later).

**Critical verification step, not optional**: test the packaged archive actually runs on a copy of this machine with Homebrew's `mysql-client`/`openssl@3`/`zlib-ng-compat`/`zstd` kegs *not present* — e.g. temporarily `brew unlink mysql-client` (and confirm the other three aren't relied on by anything else currently linked) and confirm the server still starts and can open a real MySQL connection, or use a scratch non-admin macOS user account / a fresh VM without Homebrew at all. Do not assume the rpath fix worked just because `otool -L` shows relative paths — actually run it in an environment where the absolute Homebrew paths would fail to resolve, and confirm a real MySQL query succeeds end-to-end.

### 4.2 GitHub Actions workflow

New file, e.g. `.github/workflows/release.yml`, triggered on a version-tag push (`tags: ['v*']`). Runner: `macos-26-arm64` (matching the exact runner choice already established for this project's other CI work, per memory — confirm this runner label is actually available/correct for GitHub-hosted runners at implementation time, since macOS 26 hosted runners may not exist yet on GitHub Actions as of this writing; if not, this may need a self-hosted runner or a documented manual-release fallback — a real open question to resolve during implementation, not to guess past now).

Steps: checkout, install Homebrew deps (`mysql-client`, plus whatever's needed to satisfy `libxml2`/`zlib`'s `pkg-config` lookup even though the *linked* copies end up being system ones — confirm build-time `pkg-config` requirements are satisfied on a clean runner), `brew install dylibbundler`, run `scripts/package-release.sh`, then use `softprops/action-gh-release` (or `gh release create`/`gh release upload` directly, matching whatever's simplest and doesn't require a new third-party Action dependency) to attach the archive + checksum to the GitHub Release for that tag.

### 4.3 Versioning

A simple `vMAJOR.MINOR.PATCH` git-tag scheme (e.g. `v0.1.0` for the first release), matching common convention. Given this project has no prior release history, starting at `v0.1.0` (not `v1.0.0`) honestly signals "early, functional, not yet battle-hardened" — matches this project's own consistent framing elsewhere (`Documentation/linux-compatibility-review.md`, README corrections found during the earlier README audit) that Perfect-Lasso is explicitly *not* claimed to be production-ready yet.

### 4.4 Release documentation

New `README.md` at the repo root (currently absent) — a first for this repo, covering: what this project is (one paragraph, honest about maturity status per the existing established framing), how to download and run the release binary, the Gatekeeper bypass instructions, a link to/adapted excerpt of `Documentation/lasso-perfect-server.md`'s Configuration section for `LASSO_SITE_ROOT`/datasource config, a pointer to `Documentation/admin-console.md` for the optional admin console, and the DKIM permission requirement called out explicitly (§3 above). This becomes both the repo's front door *and* the basis for a shorter `README.md` bundled directly inside the release archive itself.

## 5. Phasing

- **Phase A — packaging script + local verification.** Write `scripts/package-release.sh`, install `dylibbundler` locally, produce a packaged archive by hand, and prove it runs correctly with the relevant Homebrew kegs unlinked/absent (§4.1's critical verification step). No CI yet — this phase is entirely about proving the packaging approach actually works before automating it.
- **Phase B — GitHub Actions release workflow.** Author `.github/workflows/release.yml`, resolve the runner-availability open question (§4.2), push a `v0.1.0-rc1`-style test tag to confirm the workflow actually produces and attaches a working artifact, then a real `v0.1.0` tag for the first genuine release.
- **Phase C — documentation.** Root `README.md`, release-bundled `README.md`, any small adaptation of existing `Documentation/` content needed to support both.

Each phase gets its own milestone review before merging, matching this project's established discipline — scaled to this work's nature: Phase A's review should focus on whether the verification step genuinely proves portability (not just "the script ran"); Phase B's on whether the workflow is correct/secure (e.g. `GITHUB_TOKEN` permissions scoped correctly, no secrets mishandled); Phase C is low-risk documentation, a lighter pass is fine.

## 6. Open items for implementation to resolve (flagged now, not guessed at)

1. Exact `dylibbundler` CLI flags/behavior (in-place modification vs. copy-then-fix) — confirm against the tool's real current version during implementation.
2. GitHub Actions macOS runner label availability for macOS 26 — confirm what's actually offered by GitHub-hosted runners at implementation time; have a fallback plan (e.g., a self-hosted runner, or a documented manual local-build-and-upload release process) ready if `macos-26-arm64`-equivalent hosted runners don't exist yet.
3. Whether any build-time `pkg-config`/system-library installs are needed on a clean CI runner even though the final linked libxml2/zlib end up being macOS's own system copies (i.e., does the *build* step need Homebrew's libxml2/zlib present to satisfy `systemLibrary` pkg-config resolution, separate from what the *linked binary* references at runtime) — verify empirically on a clean runner, don't assume.

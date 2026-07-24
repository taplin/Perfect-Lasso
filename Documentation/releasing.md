# Cutting a release

Maintainer runbook for tagging a `lasso-perfect-server` release and publishing its source tarball, per `Documentation/release-target-plan.md`'s build-from-source distribution model. Not needed by anyone just building/running this project — see the root [`README.md`](../README.md) for that.

## Prerequisite — pushed to GitHub

`taplin/Perfect-Lasso` is public and live, matching every sibling Perfect-Resurrection library. `origin` is already configured; `main` is pushed and tracked.

## Version scheme

`vMAJOR.MINOR.PATCH`, starting at `v0.1.0` — matches this project's own consistently honest "early, functional, not yet battle-hardened" framing (see the root README). Check what's already tagged before picking the next version:

```bash
git tag -l 'v*' | sort -V | tail -5
# once the repo is on GitHub:
gh release list --repo taplin/Perfect-Lasso
```

## Pre-flight checks (every time, before tagging)

This repo has no CI yet, so these are the only verification gate — don't skip them:

1. **Clean, on `main`**: `git status --short` empty, `git branch --show-current` is `main`.
2. **Build and test pass locally**:
   ```bash
   swift build
   swift test
   ```
3. **`Package.resolved` reflects the dependency state you actually want pinned.** This matters more here than in most repos: several dependencies (`Perfect-CRUD`, `Perfect-MySQL`, `Perfect-NIO`, `Perfect-Session`, `Perfect-FileMaker`, `Perfect-FileMaker-AdminAPI`) are declared as `branch: "main"` in `Package.swift` — it's the *committed* `Package.resolved` entry, not whatever those siblings' `main` branches have moved to since, that a source tarball built later will actually use. Decide whether you want this release pinned to what's already committed, or to pick up each sibling's latest:
   ```bash
   swift package resolve   # updates Package.resolved to each dependency's current branch tip
   git diff Package.resolved
   ```
   Review the diff (if any), and commit it *before* tagging — a release should never be tagged with an uncommitted or accidental `Package.resolved` change.
4. **A standalone-clone build check** — this is the exact class of "only works because of my local checkout" mistake the whole build-from-source effort exists to avoid, so verify it directly rather than trusting the working copy you've been developing in:
   ```bash
   rm -rf /tmp/release-verify && git clone --no-local . /tmp/release-verify
   cd /tmp/release-verify && git checkout main
   swift build -c release --product lasso-perfect-server
   ```
   (`--no-local` forces a real clone over the git protocol layer even for a local path, rather than a hardlink-optimized copy that could hide a real remote-fetch issue.)
5. **Review documentation, not just code — before tagging, not after.** Read this repo's own `README.md` top-to-bottom and confirm it's still accurate against what's actually shipping (version/feature claims, platform requirements, anything this release's commits changed). If this release touched or bumped a dependency (a `branch: "main"`-tracked sibling in `Package.swift`), skim that sibling's own `README.md` too for claims that might now be stale (a deployment-target bump, a new capability, a removed one) — dependency repos drift silently since their own doc updates don't show up in this repo's diff. **Why this is here**: `v0.2.1` (2026-07-23) was an entire extra release cut solely to fix a README that had been stale since before `v0.2.0`, plus a docs-only pointer this repo's own README should have gotten in `v0.2.0` in the first place — both were catchable in one pre-flight read, and doing that read one release earlier would have meant one release instead of two.

## Cutting the tag and release

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
gh release create v0.1.0 --generate-notes
```

`--generate-notes` drafts release notes from commits since the previous tag (or the repo's start, for the first release) — read them before publishing; edit if the auto-generated summary is misleading (`gh release edit v0.1.0` opens it in your editor, or use the GitHub web UI).

GitHub automatically attaches "Source code (zip)" and "Source code (tar.gz)" archives to every Release — no separate packaging or upload step is needed for these; that's the whole benefit of the build-from-source model over a pre-built-binary one (see `release-target-plan.md` §2 for why pre-built binaries were investigated and set aside).

## Post-release verification — don't skip this either

Download the actual tarball GitHub just generated (not just re-clone `main`, which isn't necessarily the same content once further commits land) and confirm it builds and runs standalone — this is the literal artifact a user will download, so it's the one that needs verifying directly:

```bash
curl -L -o release-check.tar.gz "https://github.com/taplin/Perfect-Lasso/archive/refs/tags/v0.1.0.tar.gz"
mkdir release-check && tar -xzf release-check.tar.gz -C release-check --strip-components=1
cd release-check
swift build -c release --product lasso-perfect-server
LASSO_SITE_ROOT=/path/to/a/scratch/site \
"$(swift build -c release --show-bin-path)/lasso-perfect-server"   # confirm it actually starts and serves a request
```

## If something's wrong after publishing

Prefer a new patch release (`v0.1.1`) over rewriting an already-public tag — someone may already have pulled it. If a release genuinely needs to be pulled (e.g. it doesn't build at all):

```bash
gh release delete v0.1.0 --yes
git push origin :refs/tags/v0.1.0
git tag -d v0.1.0
```

## Legacy 10.15/11 release (`legacy_10.15` branch only)

Everything above is for `main`'s normal `vX.Y.Z` source-tarball releases.
The `legacy_10.15` branch is the one exception to the build-from-source
model (`release-target-plan.md §2` explains why pre-built binaries were
originally set aside for `main`) — the target OS there can't run a modern
enough Swift toolchain to build this project itself, so that branch ships
a pre-built binary instead. This is a separate, manual process with its
own tag suffix (`vX.Y.Z-legacy10.15`), not part of this repo's CI (which
doesn't exist yet, same as everything else in this document).

**Read `Documentation/legacy-10.15-support.md` in full before cutting one
of these** — it has the security review (this artifact bundles dylibs with
an `@executable_path` rpath, a real attack surface if the deploy
directory's permissions are ever wrong), the known-broken-on-10.15/11
findings from its API audit, and the full deploy runbook.

```bash
git checkout legacy_10.15
git merge main          # pick up whatever's landed since the last cut
swift test               # full suite, native arch — confirms nothing broke
Scripts/package-legacy-release.sh vX.Y.Z-legacy10.15
# review the printed `gh release create` command before running it
```

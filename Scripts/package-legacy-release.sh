#!/usr/bin/env bash
#
# package-legacy-release.sh — build, bundle, checksum, and tar a
# legacy_10.15 release artifact for lasso-perfect-server.
#
# Read Documentation/legacy-10.15-support.md in full before running this,
# especially its security review — this script bundles several dylibs
# alongside the binary with an @executable_path rpath, which has real
# implications for how the resulting tarball must be deployed.
#
# This script does NOT publish anything. It stops after producing the
# tarball + checksums and prints the `gh release create` command for you
# to review and run yourself.
#
# Usage:
#   Scripts/package-legacy-release.sh vX.Y.Z-legacy10.15
#
# Prerequisites:
#   - Run from the legacy_10.15 branch, clean working tree.
#   - An Intel (x86_64) Homebrew prefix at /usr/local with mysql-client
#     installed (`arch -x86_64 /usr/local/bin/brew install mysql-client`) —
#     the arm64 bottle under /opt/homebrew cannot link for x86_64.
#   - dylibbundler (`brew install dylibbundler`) — used to recursively
#     bundle mysql-client's own dylib cascade (openssl, zlib, zstd) and
#     any other genuinely-third-party dependency. See the "why two bundling
#     mechanisms" note below for why the Swift concurrency runtime dylib
#     specifically is handled separately, by hand.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 vX.Y.Z-legacy10.15" >&2
    exit 1
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-legacy10\.15$ ]]; then
    echo "error: version '$VERSION' doesn't match vX.Y.Z-legacy10.15" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Repo/branch sanity checks
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "legacy_10.15" ]]; then
    echo "error: on branch '$CURRENT_BRANCH', expected 'legacy_10.15'" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is not clean — commit or stash first" >&2
    git status --short >&2
    exit 1
fi

BEHIND_MAIN="$(git rev-list --count HEAD..main 2>/dev/null || echo "unknown")"
if [[ "$BEHIND_MAIN" != "0" && "$BEHIND_MAIN" != "unknown" ]]; then
    echo "warning: $BEHIND_MAIN commit(s) behind main — consider 'git merge main' first" >&2
fi

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

INTEL_MYSQL_PKGCONFIG="/usr/local/opt/mysql-client/lib/pkgconfig"
if [[ ! -d "$INTEL_MYSQL_PKGCONFIG" ]]; then
    cat >&2 <<EOF
error: Intel mysql-client not found at $INTEL_MYSQL_PKGCONFIG

Cross-compiling for x86_64 needs an Intel-side mysql-client. Install one
under an Intel Homebrew prefix (Rosetta 2 required):

  arch -x86_64 /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  arch -x86_64 /usr/local/bin/brew install mysql-client

See Documentation/legacy-10.15-support.md's Known limitations section: the
resulting binary is expected to be built by that bottle at a HIGHER minos
than this script's own target (confirmed once already: 14.0 vs our 12.0) —
MySQL connectivity on real 10.15/11 hardware is not expected to work until
that's separately resolved. This script still proceeds past that specific
gap since it's a link-time warning, not an error.
EOF
    exit 1
fi

if ! command -v dylibbundler > /dev/null 2>&1; then
    echo "error: dylibbundler not found — install with: brew install dylibbundler" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

TARGET_TRIPLE="x86_64-apple-macosx12.0"
echo "==> Building lasso-perfect-server for $TARGET_TRIPLE (release)..."
PKG_CONFIG_PATH="$INTEL_MYSQL_PKGCONFIG" swift build -c release --triple "$TARGET_TRIPLE"

BUILT_BINARY="$REPO_ROOT/.build/out/Products/Release/lasso-perfect-server"
if [[ ! -f "$BUILT_BINARY" ]]; then
    # Fall back to a search in case the local build-system layout differs.
    BUILT_BINARY="$(find "$REPO_ROOT/.build" -type f -name "lasso-perfect-server" -newer "$REPO_ROOT/Package.swift" -print -quit)"
fi
if [[ -z "$BUILT_BINARY" || ! -f "$BUILT_BINARY" ]]; then
    echo "error: couldn't locate the built lasso-perfect-server binary" >&2
    exit 1
fi

ACTUAL_ARCH="$(file -b "$BUILT_BINARY" | grep -o 'x86_64' || true)"
if [[ "$ACTUAL_ARCH" != "x86_64" ]]; then
    echo "error: built binary at $BUILT_BINARY is not x86_64 (got: $(file -b "$BUILT_BINARY"))" >&2
    exit 1
fi
echo "==> Built: $BUILT_BINARY ($(file -b "$BUILT_BINARY"))"

# ---------------------------------------------------------------------------
# Locate toolchain paths
# ---------------------------------------------------------------------------

TOOLCHAIN_LIB="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib"

# The swift-6.2/macosx dir holds libswiftCompatibilitySpan.dylib and similar
# newer back-deployment shims dylibbundler needs as a search path (its own
# @rpath reference doesn't point here directly on every Xcode version, so
# giving dylibbundler this as an explicit -s search path is what lets it
# find and bundle it automatically instead of prompting interactively).
SWIFT_TOOLCHAIN_MACOSX_DIR="$(find "$TOOLCHAIN_LIB" -maxdepth 1 -type d -name "swift-6.*" -print -quit)/macosx"
if [[ ! -d "$SWIFT_TOOLCHAIN_MACOSX_DIR" ]]; then
    echo "error: couldn't find a swift-6.x/macosx toolchain lib dir under $TOOLCHAIN_LIB" >&2
    exit 1
fi

# The back-deployment concurrency runtime — NOT part of the OS below 12.0.
# Handled separately from dylibbundler below: it lives at a path
# (/usr/lib/swift/) that dylibbundler's system-library heuristic always
# treats as "already on the target OS, skip it" — true for every OTHER
# /usr/lib/swift/libswiftXXX.dylib (real system content since 10.14.4 per
# this SDK's own SwiftOSRuntimeMinimumDeploymentTarget), but specifically
# false for this one file on 10.15/11.
CONCURRENCY_DYLIB="$(find "$TOOLCHAIN_LIB" -maxdepth 2 -type d -name "swift-5.5" -print -quit)/macosx/libswift_Concurrency.dylib"
if [[ ! -f "$CONCURRENCY_DYLIB" ]]; then
    echo "error: back-deployment concurrency dylib not found under $TOOLCHAIN_LIB/swift-5.5" >&2
    echo "(expected to ship with any Xcode 13.2+ install)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Stage and bundle
#
# Two separate bundling mechanisms, deliberately:
#   1. dylibbundler recursively finds and bundles every genuinely-third-party
#      dependency (mysql-client + its own openssl/zlib/zstd cascade, and
#      newer Swift back-deployment shims like libswiftCompatibilitySpan.dylib
#      that live outside /usr/lib/swift). This is the general case and
#      dylibbundler gets it right automatically.
#   2. libswift_Concurrency.dylib is bundled and rewritten BY HAND, because
#      it lives at /usr/lib/swift/ — a path dylibbundler always treats as
#      "the OS already has this," which is true for every sibling dylib
#      there except this one. It also needs its OWN rpath added (pointing
#      at /usr/lib/swift) so ITS OWN internal @rpath/libswiftCore.dylib
#      reference resolves against the real system Swift runtime rather than
#      falling back to /usr/local/lib or /usr/lib directly, where it isn't.
# ---------------------------------------------------------------------------

STAGING_DIR="$REPO_ROOT/dist/legacy_10.15/$VERSION/staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp "$BUILT_BINARY" "$STAGING_DIR/lasso-perfect-server"

echo "==> Running dylibbundler for the general third-party dependency cascade..."
dylibbundler \
    -x "$STAGING_DIR/lasso-perfect-server" \
    -b \
    -d "$STAGING_DIR" \
    -p "@executable_path/" \
    -s "$SWIFT_TOOLCHAIN_MACOSX_DIR" \
    -of -cd -ns

# dylibbundler rewrites every existing LC_RPATH entry to the new value
# individually rather than collapsing duplicates — clean that up to one.
RPATH_COUNT="$(otool -l "$STAGING_DIR/lasso-perfect-server" | grep -c "path @executable_path/ " || true)"
for ((i = 1; i < RPATH_COUNT; i++)); do
    install_name_tool -delete_rpath "@executable_path/" "$STAGING_DIR/lasso-perfect-server"
done

echo "==> Manually bundling the Swift concurrency back-deployment dylib..."
cp "$CONCURRENCY_DYLIB" "$STAGING_DIR/libswift_Concurrency.dylib"
chmod +w "$STAGING_DIR/libswift_Concurrency.dylib"
install_name_tool -id "@executable_path/libswift_Concurrency.dylib" "$STAGING_DIR/libswift_Concurrency.dylib"
install_name_tool -add_rpath "/usr/lib/swift" "$STAGING_DIR/libswift_Concurrency.dylib"
install_name_tool -change "/usr/lib/swift/libswift_Concurrency.dylib" "@executable_path/libswift_Concurrency.dylib" "$STAGING_DIR/lasso-perfect-server"

echo "==> Ad-hoc signing everything (bookkeeping only — no Library Validation without a real Developer ID; see the security review before assuming this provides any protection)..."
for f in "$STAGING_DIR"/*.dylib "$STAGING_DIR/lasso-perfect-server"; do
    codesign --sign - --force "$f"
done

echo "==> Verifying no unexpected non-system absolute paths remain..."
UNEXPECTED="$(otool -L "$STAGING_DIR/lasso-perfect-server" | tail -n +2 | awk '{print $1}' \
    | grep -v -E "^(@executable_path/|/usr/lib/|/System/Library/)" || true)"
if [[ -n "$UNEXPECTED" ]]; then
    echo "error: unexpected dependency path(s) survived bundling:" >&2
    echo "$UNEXPECTED" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Checksums, permissions, tar
# ---------------------------------------------------------------------------

echo "==> Computing checksums..."
(
    cd "$STAGING_DIR"
    shasum -a 256 -- *.dylib lasso-perfect-server > CHECKSUMS.txt
)
cat "$STAGING_DIR/CHECKSUMS.txt"

echo "==> Setting permissions (750 dir/binary, 640 dylibs/checksums — see the security review's directory-trust model)..."
chmod 750 "$STAGING_DIR"
chmod 750 "$STAGING_DIR/lasso-perfect-server"
chmod 640 "$STAGING_DIR"/*.dylib "$STAGING_DIR/CHECKSUMS.txt"

# Flat contents — no extra nesting level, matches the deploy runbook's
# `tar -xzf ... -C ~/lasso-legacy` expecting files at the archive root.
TARBALL_NAME="lasso-perfect-server-${VERSION}-x86_64.tar.gz"
OUTPUT_DIR="$REPO_ROOT/dist/legacy_10.15/$VERSION"
TARBALL_PATH="$OUTPUT_DIR/$TARBALL_NAME"

echo "==> Creating $TARBALL_PATH..."
(cd "$STAGING_DIR" && tar -czf "$TARBALL_PATH" -- *.dylib lasso-perfect-server CHECKSUMS.txt)

# A top-level checksums file too, so the release page can publish one
# without needing to unpack the tarball first (the runbook downloads and
# verifies this one before ever extracting).
cp "$STAGING_DIR/CHECKSUMS.txt" "$OUTPUT_DIR/CHECKSUMS.txt"

echo
echo "==> Done. Artifact: $TARBALL_PATH"
echo
echo "This script does not publish anything. To create the GitHub Release yourself, review and run:"
echo
echo "  gh release create $VERSION \\"
echo "    \"$TARBALL_PATH\" \\"
echo "    \"$OUTPUT_DIR/CHECKSUMS.txt\" \\"
echo "    --title \"$VERSION\" \\"
echo "    --notes \"Legacy macOS 10.15/11 build. UNVERIFIED on real hardware — see Documentation/legacy-10.15-support.md before deploying.\""

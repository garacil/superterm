#!/bin/sh
# Build, package and (optionally) publish the macOS assets for a superterm release.
#
#   ./release.sh 5.2.2              build + package + verify, leave the files in dist/
#   ./release.sh 5.2.2 --upload     the same, then upload them to the GitHub release
#
# Refuses to continue on anything that would ship a wrong or empty artifact. Run it as a
# normal user: a root-owned build/ makes the compiler fail or, worse, go stale silently.
set -eu

VERSION="${1:-}"
UPLOAD="${2:-}"
REPO="garacil/superterm"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$(dirname "$0")/dist"

die() { printf 'release: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

[ -n "$VERSION" ] || die "usage: $0 <version> [--upload]"
[ "$(id -u)" -ne 0 ] || die "do not run this as root; a root-owned build/ breaks the next build"
[ "$(uname -s)" = "Darwin" ] || die "this builds the macOS assets and only runs on macOS"

# Homebrew is where gh lives, and launchd-style environments do not have it on PATH.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

cd "$ROOT"

# The version must be the tree's own, or the tarball name lies about its contents.
TREE_VERSION="$(cat VERSION)"
[ "$TREE_VERSION" = "$VERSION" ] ||
    die "VERSION says $TREE_VERSION but you asked for $VERSION; check out the right tag first"

say "Building $VERSION at $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown commit')"
./configure >/dev/null
rm -rf build bin
mkdir -p build/units/release build/x86_64 bin

# The Darwin flags live in Makefile.in on macos-support. Passing them here too means this
# script also works from a detached release tag that predates that block.
make FPCFLAGS_EXTRA="-vm6058 -k-w" 2>&1 | tee /tmp/superterm-macos-build.log | tail -3
if grep -qE '(Error|Fatal|Warning|Note|Hint):' /tmp/superterm-macos-build.log; then
    grep -E '(Error|Fatal|Warning|Note|Hint):' /tmp/superterm-macos-build.log >&2
    die "the build is not clean; fix it before releasing"
fi

say "Cross-building x86_64 and making the universal binary"
fpc -Px86_64 -Tdarwin -Mobjfpc -Sh -O4 -gl -vm6058 -k-w \
    -Fu"$ROOT/vendor/fv322" -FU"$ROOT/build/x86_64" -FE"$ROOT/bin" \
    -o"$ROOT/bin/superterm-x86_64" "$ROOT/src/superterm.lpr" >/dev/null

lipo -create bin/superterm bin/superterm-x86_64 -output bin/superterm-universal

# lipo invalidates the signatures of the slices it joins, so sign AFTER lipo, never before.
codesign --force -s - bin/superterm
codesign --force -s - bin/superterm-universal

say "Packaging"
rm -rf "$DIST"
mkdir -p "$DIST"

package() {
    binary="$1"; name="$2"
    stage="$(mktemp -d)"
    dir="$stage/superterm-$VERSION"
    mkdir -p "$dir/examples"
    cp "$binary" "$dir/superterm"
    # Listed one by one on purpose: zsh does not word-split an unquoted variable, and a
    # loop over "$DOCS" once shipped a tarball with the binary and nothing else.
    cp README.md LICENSE CHANGELOG.md "$dir/"
    cp examples/superterm.ini.example "$dir/examples/"
    ( cd "$stage" && tar czf "$name" "superterm-$VERSION" )
    cp "$stage/$name" "$DIST/$name"
    ( cd "$DIST" && shasum -a 256 "$name" > "$name.sha256" )

    # Verify the artifact we are about to publish, not the tree we built it from.
    check="$(mktemp -d)"
    tar xzf "$DIST/$name" -C "$check"
    got="$("$check/superterm-$VERSION/superterm" --version 2>/dev/null | head -1)"
    [ "$got" = "superterm $VERSION" ] ||
        die "$name contains '$got' instead of 'superterm $VERSION'"
    for f in README.md LICENSE CHANGELOG.md examples/superterm.ini.example; do
        [ -f "$check/superterm-$VERSION/$f" ] || die "$name is missing $f"
    done
    rm -rf "$stage" "$check"
    printf '   %s  ok (%s)\n' "$name" "$got"
}

package bin/superterm           "superterm-$VERSION-macos-arm64.tar.gz"
package bin/superterm-universal "superterm-$VERSION-macos-universal.tar.gz"

printf '\n'
lipo -info bin/superterm-universal
cat "$DIST"/*.sha256

if [ "$UPLOAD" != "--upload" ]; then
    say "Not uploading. Re-run with --upload, or:"
    printf '   gh release upload v%s %s/* --repo %s --clobber\n' "$VERSION" "$DIST" "$REPO"
    exit 0
fi

command -v gh >/dev/null || die "gh is not on PATH (it lives in /opt/homebrew/bin)"
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 ||
    die "release v$VERSION does not exist yet; create it before uploading"

say "Uploading to v$VERSION"
gh release upload "v$VERSION" \
    "$DIST/superterm-$VERSION-macos-arm64.tar.gz" \
    "$DIST/superterm-$VERSION-macos-arm64.tar.gz.sha256" \
    "$DIST/superterm-$VERSION-macos-universal.tar.gz" \
    "$DIST/superterm-$VERSION-macos-universal.tar.gz.sha256" \
    --repo "$REPO" --clobber

say "Verifying what the release now serves"
remote="$(mktemp -d)"
gh release download "v$VERSION" --repo "$REPO" --pattern '*macos*.sha256' --dir "$remote" --clobber
for arch in arm64 universal; do
    r="$(awk '{print $1}' "$remote/superterm-$VERSION-macos-$arch.tar.gz.sha256")"
    l="$(awk '{print $1}' "$DIST/superterm-$VERSION-macos-$arch.tar.gz.sha256")"
    [ "$r" = "$l" ] || die "$arch: the uploaded checksum does not match the local one"
    printf '   %s  sha256 matches\n' "$arch"
done
rm -rf "$remote"

printf '\nDone. If the notes have no macOS section yet, add notes-snippet.md.\n'

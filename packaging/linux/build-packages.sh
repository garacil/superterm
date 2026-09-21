#!/bin/bash
# Build the GNU/Linux release artifacts: a portable tarball and one native
# package for each of the three families.
#
#   ./packaging/linux/build-packages.sh [OUTDIR]
#
# The 5.2.2 artifacts were built by hand outside the repository, so the layout
# they established -- which is the layout already installed on users' machines
# and the one an upgrade has to match -- existed only inside the published
# files. It is written down here instead.
#
# One staged tree feeds every format. They differ in exactly two things, and
# only because each family says so:
#
#   licence    Arch  usr/share/licenses/superterm/LICENSE
#              RPM   usr/share/doc/superterm/LICENSE
#              deb   usr/share/doc/superterm/copyright
#   dependency Arch  glibc      deb  libc6      RPM  autodetected from the ELF
#
# makepkg refuses to run as root, so the Arch package is built as an
# unprivileged user when this script is run by root.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:-$ROOT/dist}
VERSION=$(cat "$ROOT/VERSION")
REL=1
PKGDESC='GNU/macOS terminal multiplexer'
URL='https://www.superterm.org'
MAINTAINER='German Luis Aracil Boned <garacilb@gmail.com>'
DESC_1='Persistent, shared, multi-client terminal workspace with PTY-backed panes'
DESC_2='in a Turbo Vision-style desktop, detachable sessions and an optional'
DESC_3='dedicated OpenSSH entry.'

say() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- build ----
say "superterm $VERSION"
make -C "$ROOT" release >/dev/null
[ -x "$ROOT/bin/superterm" ] || { echo "no binary at bin/superterm" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE=$WORK/stage
mkdir -p "$OUT"

# ------------------------------------------------------- the common tree ----
# The published binary is stripped: 2.7MB against 6.6MB, and the line info the
# build keeps for crash reports is not wanted in a distribution package.
mkdir -p "$STAGE/usr/bin" \
         "$STAGE/usr/share/doc/superterm" \
         "$STAGE/usr/share/superterm/backgrounds" \
         "$STAGE/usr/share/superterm/examples"
install -m 0755 "$ROOT/bin/superterm" "$STAGE/usr/bin/superterm"
strip "$STAGE/usr/bin/superterm"
install -m 0644 "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$STAGE/usr/share/doc/superterm/"
for doc in "$ROOT"/docs/*.md; do
  install -m 0644 "$doc" "$STAGE/usr/share/doc/superterm/$(basename "$doc")"
done
install -m 0644 "$ROOT"/backgrounds/*.art "$STAGE/usr/share/superterm/backgrounds/"
install -m 0644 "$ROOT/examples/superterm.ini.example" \
  "$STAGE/usr/share/superterm/examples/superterm.ini.example"

sum() { (cd "$OUT" && sha256sum "$1" > "$1.sha256"); say "$1"; }

# ------------------------------------------------------------- tarball ----
# Flat and self-contained: the binary plus what a reader needs, no prefix.
TB=$WORK/superterm-$VERSION
mkdir -p "$TB"
cp "$STAGE/usr/bin/superterm" "$TB/"
cp "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/LICENSE" "$TB/"
cp "$ROOT/examples/superterm.ini.example" "$TB/"
(cd "$WORK" && tar czf "$OUT/superterm-$VERSION-gnu-x86_64.tar.gz" "superterm-$VERSION")
sum "superterm-$VERSION-gnu-x86_64.tar.gz"

# ------------------------------------------------------------- Debian ----
DEB=$WORK/deb
mkdir -p "$DEB/DEBIAN"
cp -a "$STAGE"/usr "$DEB/"
install -m 0644 "$ROOT/LICENSE" "$DEB/usr/share/doc/superterm/copyright"
cat > "$DEB/DEBIAN/control" <<EOF
Package: superterm
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libc6
Maintainer: $MAINTAINER
Description: $PKGDESC
 $DESC_1
 $DESC_2
 $DESC_3
EOF
dpkg-deb --root-owner-group --build "$DEB" \
  "$OUT/superterm_${VERSION}_amd64.deb" >/dev/null
sum "superterm_${VERSION}_amd64.deb"

# ---------------------------------------------------------------- RPM ----
RPMTOP=$WORK/rpm
mkdir -p "$RPMTOP"/{BUILD,RPMS,SOURCES,SPECS,BUILDROOT}
RB=$RPMTOP/BUILDROOT/superterm-$VERSION-$REL.x86_64
mkdir -p "$RB"
cp -a "$STAGE"/usr "$RB/"
install -m 0644 "$ROOT/LICENSE" "$RB/usr/share/doc/superterm/LICENSE"
cat > "$RPMTOP/SPECS/superterm.spec" <<EOF
Name:           superterm
Version:        $VERSION
Release:        $REL
Summary:        $PKGDESC
License:        GPLv3
URL:            $URL
BuildArch:      x86_64
# The tree is staged by the script; rpmbuild only packages it.
%description
$DESC_1
$DESC_2
$DESC_3
%files
/usr/bin/superterm
/usr/share/doc/superterm
/usr/share/superterm
%changelog
EOF
rpmbuild --define "_topdir $RPMTOP" --define "_build_id_links none" \
  --buildroot "$RB" -bb "$RPMTOP/SPECS/superterm.spec" >/dev/null 2>&1
cp "$RPMTOP/RPMS/x86_64/superterm-$VERSION-$REL.x86_64.rpm" \
   "$OUT/superterm-$VERSION-$REL.x86_64.rpm"
sum "superterm-$VERSION-$REL.x86_64.rpm"

# --------------------------------------------------------------- Arch ----
# A pkg.tar.zst is a tar of the payload plus .PKGINFO and .MTREE. makepkg
# writes both and refuses to run as root, so when this runs as root the build
# is handed to an unprivileged user in a world-writable directory.
AR=$WORK/arch
mkdir -p "$AR/src"
cp -a "$STAGE"/usr "$AR/src/"
install -D -m 0644 "$ROOT/LICENSE" "$AR/src/usr/share/licenses/superterm/LICENSE"
cat > "$AR/PKGBUILD" <<EOF
pkgname=superterm
pkgver=${VERSION}
pkgrel=${REL}
pkgdesc='$PKGDESC'
arch=('x86_64')
url='$URL'
license=('GPL3')
depends=('glibc')
makedepends=('fpc')
options=('!strip' '!debug')
package() {
  cp -a "\$startdir/src/usr" "\$pkgdir/"
}
EOF
if [ "$(id -u)" -eq 0 ]; then
  # makepkg chmods its own source directory, so ownership has to be handed
  # over rather than permissions widened: root-owned files refuse the chmod
  # and the build dies with nothing but "an unknown error has occurred".
  BUILDER=${SUDO_USER:-}
  if [ -z "$BUILDER" ]; then
    BUILDER=$(stat -c %U "$ROOT")
  fi
  [ "$BUILDER" = root ] && BUILDER=nobody
  # mktemp -d is 0700 root: the builder cannot even traverse into it.
  chmod a+x "$WORK"
  chown -R "$BUILDER" "$AR"
  su -s /bin/bash "$BUILDER" -c \
    "cd '$AR' && HOME='$AR' PKGDEST='$AR' makepkg -f --nodeps --noconfirm"
else
  (cd "$AR" && PKGDEST="$AR" makepkg -f --nodeps --noconfirm)
fi
cp "$AR/superterm-$VERSION-$REL-x86_64.pkg.tar.zst" "$OUT/"
sum "superterm-$VERSION-$REL-x86_64.pkg.tar.zst"

say "done: $OUT"
ls -l "$OUT" | awk 'NR>1 {printf "    %10s  %s\n", $5, $9}'

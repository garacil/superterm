#!/bin/sh
# ---------------------------------------------------------------------------
#  Build the macOS executable with one double-click (from Finder) or one
#  command, from the repository root:
#      bin/superterm        the console client / session server (this Mac's
#                           architecture; for the universal binary and a full
#                           release use packaging/macos/release.sh instead)
#
#  Uses fpc directly with the project's strict contract, so it needs neither
#  ./configure nor make — the macOS counterpart of build.bat.
#
#  Override the compiler location by setting SUPERTERM_FPC before running:
#      SUPERTERM_FPC=/path/to/fpc ./build.command
# ---------------------------------------------------------------------------
set -u

FPC="${SUPERTERM_FPC:-/usr/local/bin/fpc}"
if [ ! -x "$FPC" ]; then
  # Homebrew's fpc as a fallback before giving up.
  if [ -x /opt/homebrew/bin/fpc ]; then
    FPC=/opt/homebrew/bin/fpc
  else
    echo "[error] fpc not found at $FPC."
    echo "        Set SUPERTERM_FPC to your fpc and run again, e.g.:"
    echo "            SUPERTERM_FPC=/usr/local/bin/fpc ./build.command"
    exit 1
  fi
fi

# This script lives in the repository root; build from here (bin/ hangs off it).
cd "$(dirname "$0")" || { echo "[error] cannot enter the repository root"; exit 1; }

# Never build as root: a root-owned build/ makes the next normal build fail
# with "Can't create assembler file" or, worse, go stale silently.
if [ "$(id -u)" -eq 0 ]; then
  echo "[error] do not build as root; run it as your normal user."
  exit 1
fi

# The same strict contract as build.bat and the Makefile, plus the two
# darwin-only noise flags the Makefile adds behind uname:
#   -vm6058  mute the ~69 "inline is not inlined" notes the aarch64-darwin RTL
#            emits for vendored FreeVision FillChar/Move (Linux never does)
#   -k-w     silence ld64's duplicate -lc warning (GNU ld lacks -w)
FLAGS="-B -Mobjfpc -Sh -Sewnh -vewnh -vm11030,11031,6058 -k-w -O4 -gl -FEbin"

mkdir -p bin build/units/mac-release

echo "=== [1/1] superterm ==="
# shellcheck disable=SC2086
"$FPC" $FLAGS -Fuvendor/fv322 -FUbuild/units/mac-release \
  -obin/superterm src/superterm.lpr || {
  echo
  echo "=== BUILD FAILED ==="
  echo "If fpc could not create files under build/ or bin/, an earlier sudo"
  echo "build likely left them root-owned. Fix with:"
  echo "    sudo chown -R \"\$USER\":staff ."
  exit 1
}

echo
echo "=== OK: built into bin/ ==="
./bin/superterm --version
exit 0

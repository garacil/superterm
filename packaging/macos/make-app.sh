#!/bin/sh
# Build SuperTerm.app: a Dock-pinnable launcher that opens superterm in the
# user's terminal. The app itself is a thin wrapper — iTerm2 when installed
# (it shows ⌥ shortcuts and an arrow-capable ecosystem), Terminal.app
# otherwise — so the real binary stays wherever it is installed.
#
#   ./make-app.sh              builds dist/SuperTerm.app
#   ./make-app.sh --install    the same, then copies it to /Applications
#
# The icon is derived from packaging/windows/alien-hacker.ico so both
# platforms share the same face.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="$HERE/dist/SuperTerm.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- Info.plist -------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>SuperTerm</string>
  <key>CFBundleDisplayName</key>     <string>SuperTerm</string>
  <key>CFBundleIdentifier</key>      <string>com.garacil.superterm.launcher</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>SuperTerm</string>
  <key>CFBundleIconFile</key>        <string>superterm</string>
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# --- launcher ---------------------------------------------------------------
cat > "$APP/Contents/MacOS/SuperTerm" <<'LAUNCH'
#!/bin/sh
# Find the real binary: the installed one first, the repo build as fallback.
for BIN in /usr/local/bin/superterm /opt/superterm/bin/superterm; do
  [ -x "$BIN" ] && break
done

if [ -d /Applications/iTerm.app ]; then
  osascript <<EOF
tell application "iTerm"
  activate
  create window with default profile command "$BIN"
end tell
EOF
else
  osascript <<EOF
tell application "Terminal"
  activate
  do script "clear; exec $BIN"
end tell
EOF
fi
LAUNCH
chmod +x "$APP/Contents/MacOS/SuperTerm"

# --- icon: windows .ico -> .icns -------------------------------------------
ICO="$ROOT/packaging/windows/alien-hacker.ico"
if [ -f "$ICO" ]; then
  TMP="$(mktemp -d)"
  # Largest frame of the .ico to PNG, then the sizes iconutil wants.
  sips -s format png "$ICO" --out "$TMP/base.png" >/dev/null 2>&1 || true
  if [ -f "$TMP/base.png" ]; then
    mkdir -p "$TMP/superterm.iconset"
    for s in 16 32 64 128 256 512; do
      sips -z $s $s "$TMP/base.png" \
        --out "$TMP/superterm.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
      d=$((s * 2))
      sips -z $d $d "$TMP/base.png" \
        --out "$TMP/superterm.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$TMP/superterm.iconset" \
      -o "$APP/Contents/Resources/superterm.icns" 2>/dev/null || true
  fi
  rm -rf "$TMP"
fi

codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/SuperTerm.app
  cp -R "$APP" /Applications/SuperTerm.app
  echo "installed: /Applications/SuperTerm.app"
  echo "Pin it: open it once, right-click its Dock icon -> Options -> Keep in Dock"
fi

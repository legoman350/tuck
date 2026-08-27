#!/bin/bash
# Build Tuck.app from Tuck.swift
#   ./build.sh           -> builds ./Tuck.app
#   ./build.sh install   -> builds and copies to /Applications, then launches it
set -euo pipefail

cd "$(dirname "$0")"

APP="Tuck.app"
BIN="Tuck"
BUNDLE_ID="local.tuck.agent"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found. Install the Command Line Tools first:"
  echo "       xcode-select --install"
  exit 1
}

echo "==> Compiling"
rm -rf "$APP" "$BIN"
swiftc -O -framework Cocoa -framework ApplicationServices -o "$BIN" Tuck/Tuck.swift

echo "==> Assembling bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Tuck</string>
    <key>CFBundleDisplayName</key>        <string>Tuck</string>
    <key>CFBundleExecutable</key>         <string>$BIN</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, stable identifier)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

if [[ "${1:-}" == "install" ]]; then
  echo "==> Installing to /Applications"
  pkill -x "$BIN" 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "==> Launching"
  open "/Applications/$APP"
  echo "Running. Look at the right side of your menu bar."
else
  echo "Built: $(pwd)/$APP"
  echo "Run it with:  open $(pwd)/$APP"
fi

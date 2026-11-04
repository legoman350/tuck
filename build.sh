#!/bin/bash
# Build Tuck.app from Tuck.swift
#   ./build.sh           -> builds ./build/Release/Tuck.app (same location Xcode uses)
#   ./build.sh install   -> builds and copies to /Applications, then launches it
set -euo pipefail

cd "$(dirname "$0")"

# Keep the product where Xcode puts it (SYMROOT = $(SRCROOT)/build), so both
# build paths agree and the repo keeps a single, gitignored build folder.
APP_NAME="Tuck.app"
APP="build/Release/$APP_NAME"
BIN="Tuck"
BUNDLE_ID="local.tuck.agent"
# Single 1024px master icon; the .icns is generated from it below.
ICON_PNG="Tuck/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
ICON_NAME="AppIcon"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found. Install the Command Line Tools first:"
  echo "       xcode-select --install"
  exit 1
}

echo "==> Compiling"
# NOTE: never use "Tuck" as the compiler output path — it collides with the
# source directory "Tuck/". Compile straight into the bundle instead.
rm -rf "$APP"
mkdir -p "$(dirname "$APP")" "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -framework Cocoa -framework ApplicationServices -o "$APP/Contents/MacOS/$BIN" Tuck/main.swift Tuck/Tuck.swift

echo "==> Assembling bundle"

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
    <key>CFBundleIconFile</key>           <string>$ICON_NAME</string>
    <key>CFBundleIconName</key>           <string>$ICON_NAME</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

echo "==> Packaging app icon"
# Xcode compiles Assets.xcassets with actool; the script path has no Xcode
# requirement, so build the .icns straight from the 1024px master with the
# Command Line Tools (sips + iconutil).
if [[ ! -f "$ICON_PNG" ]]; then
  echo "error: missing icon master: $ICON_PNG"
  exit 1
fi
ICONSET="build/IconSet/$ICON_NAME.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$ICON_NAME.icns"
rm -rf "$ICONSET"

echo "==> Signing (ad-hoc, stable identifier)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

if [[ "${1:-}" == "install" ]]; then
  echo "==> Installing to /Applications"
  pkill -x "$BIN" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME"
  cp -R "$APP" /Applications/
  echo "==> Launching"
  open "/Applications/$APP_NAME"
  echo "Running. Look at the right side of your menu bar."
else
  echo "Built: $(pwd)/$APP"
  echo "Run it with:  open $(pwd)/$APP"
fi

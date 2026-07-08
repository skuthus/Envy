#!/bin/bash
# Builds Envy.app — a real, double-clickable macOS app bundle — from the
# SwiftPM package. Re-run this any time you want to rebuild after code changes.
#
# Usage: Scripts/build-app.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Envy"
BUNDLE_ID="com.skylerschoos.envy"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building release binary..."
swift build -c release --product "$APP_NAME"
BINARY_PATH="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "==> Regenerating app icon..."
swift build -c release --product IconGenerator
ICON_GEN_PATH="$(swift build -c release --product IconGenerator --show-bin-path)/IconGenerator"
mkdir -p "$ROOT_DIR/build-resources/AppIcon.iconset"
"$ICON_GEN_PATH" "$ROOT_DIR/build-resources/icon-1024.png"

SRC="$ROOT_DIR/build-resources/icon-1024.png"
ICONSET="$ROOT_DIR/build-resources/AppIcon.iconset"
sips -z 16 16 "$SRC" --out "$ICONSET/icon_16x16.png" > /dev/null
sips -z 32 32 "$SRC" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
sips -z 32 32 "$SRC" --out "$ICONSET/icon_32x32.png" > /dev/null
sips -z 64 64 "$SRC" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png" > /dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png" > /dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png" > /dev/null
cp "$SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ROOT_DIR/build-resources/AppIcon.icns"

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/build-resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo ""
echo "Run it locally:        open \"$APP_BUNDLE\""
echo "Install to Applications: cp -R \"$APP_BUNDLE\" /Applications/"

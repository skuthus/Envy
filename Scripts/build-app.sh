#!/bin/bash
# Builds Envy.app — a real, double-clickable macOS app bundle — from the
# SwiftPM package. Re-run this any time you want to rebuild after code changes.
#
# Usage: Scripts/build-app.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/Scripts/embed-sparkle.sh"

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
ICONSET="$ROOT_DIR/build-resources/AppIcon.iconset"
mkdir -p "$ICONSET"

# Each size is rendered natively rather than downscaled from one 1024 master:
# the brow is a thin arc, and sips' resampling softens it into mush at 16 and
# 32. IconGenerator compensates the geometry per size instead — see Tuning.
render_icon() { "$ICON_GEN_PATH" "$ICONSET/$2" "$1" > /dev/null; }
render_icon 16   icon_16x16.png
render_icon 32   icon_16x16@2x.png
render_icon 32   icon_32x32.png
render_icon 64   icon_32x32@2x.png
render_icon 128  icon_128x128.png
render_icon 256  icon_128x128@2x.png
render_icon 256  icon_256x256.png
render_icon 512  icon_256x256@2x.png
render_icon 512  icon_512x512.png
render_icon 1024 icon_512x512@2x.png
# Kept for anything that wants a flat master (README, website, press).
"$ICON_GEN_PATH" "$ROOT_DIR/build-resources/icon-1024.png" 1024 > /dev/null

iconutil -c icns "$ICONSET" -o "$ROOT_DIR/build-resources/AppIcon.icns"

# Assembled and signed under /tmp, not $DIST_DIR — this project folder lives
# under ~/Documents, which macOS's "iCloud Drive: Desktop & Documents"
# syncing backs even though the path looks purely local. bird/fileproviderd
# continuously re-tag bundle-type directories (.app/.framework/.xpc) as they
# sync, which made codesign's "resource fork, Finder information, or similar
# detritus not allowed" a near-constant failure once Sparkle.framework's ~150
# files were added — not a one-time race that a few retries could win, but an
# ongoing background process. /tmp isn't iCloud-synced, so signing there
# sidesteps the problem entirely instead of fighting it.
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT
TMP_APP_BUNDLE="$BUILD_TMP/$APP_NAME.app"

echo "==> Assembling $APP_NAME.app..."
mkdir -p "$TMP_APP_BUNDLE/Contents/MacOS" "$TMP_APP_BUNDLE/Contents/Resources"
cp "$BINARY_PATH" "$TMP_APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/build-resources/AppIcon.icns" "$TMP_APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Scripts/Info.plist" "$TMP_APP_BUNDLE/Contents/Info.plist"

SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

echo "==> Embedding Sparkle.framework..."
embed_sparkle "$TMP_APP_BUNDLE" "$APP_NAME" "$SIGNING_IDENTITY"

echo "==> Signing with Developer ID..."
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "No Developer ID Application certificate found — falling back to ad-hoc signing."
  echo "(Run this after installing your Developer ID cert to get a distributable build.)"
  sign_with_retry "$TMP_APP_BUNDLE" --force --deep --sign -
else
  echo "    Using: $SIGNING_IDENTITY"
  sign_with_retry "$TMP_APP_BUNDLE" --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY"
fi

echo "==> Copying signed build to $DIST_DIR..."
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
cp -R "$TMP_APP_BUNDLE" "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo ""
echo "Run it locally:        open \"$APP_BUNDLE\""
echo "Install to Applications: cp -R \"$APP_BUNDLE\" /Applications/"

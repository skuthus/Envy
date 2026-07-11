#!/bin/bash
# Builds EnvyTest.app — a separately-named, separately-bundle-ID copy of Envy
# for local testing, so it can run side by side with the real installed
# Envy.app without colliding in /Applications, in `open -a`/Launch Services
# name resolution, or in UserDefaults (com.skylerschoos.envy.test is a
# distinct preferences domain, so pointing EnvyTest at a scratch notes folder
# never touches the real app's real folder configuration).
#
# Usage: Scripts/build-test-app.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/Scripts/embed-sparkle.sh"

APP_NAME="EnvyTest"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building release binary..."
swift build -c release --product "Envy"
BINARY_PATH="$(swift build -c release --product "Envy" --show-bin-path)/Envy"

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
cp "$ROOT_DIR/Scripts/Info-Test.plist" "$TMP_APP_BUNDLE/Contents/Info.plist"

SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"

echo "==> Embedding Sparkle.framework..."
embed_sparkle "$TMP_APP_BUNDLE" "$APP_NAME" "$SIGNING_IDENTITY"

echo "==> Signing with Developer ID..."
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "No Developer ID Application certificate found — falling back to ad-hoc signing."
  sign_with_retry "$TMP_APP_BUNDLE" --force --deep --sign -
else
  echo "    Using: $SIGNING_IDENTITY"
  sign_with_retry "$TMP_APP_BUNDLE" --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY"
fi

echo "==> Copying signed build to $DIST_DIR..."
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
cp -R "$TMP_APP_BUNDLE" "$APP_BUNDLE"

echo "==> Installing to /Applications/$APP_NAME.app..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "$TMP_APP_BUNDLE" /Applications/

echo "==> Done: /Applications/$APP_NAME.app"
echo ""
echo "Run it:    open -a $APP_NAME"
echo "Its own prefs domain: com.skylerschoos.envy.test (safe to repoint at a scratch folder)"

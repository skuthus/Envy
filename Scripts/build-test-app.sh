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

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/build-resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Scripts/Info-Test.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Signing with Developer ID..."
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
# Stray extended attributes (a resource fork, Finder info, etc.) on any file
# inside the bundle make codesign fail outright — seen intermittently here,
# likely a race with something (Gatekeeper/Spotlight) touching the
# freshly-written icon PNGs. xattr -cr alone doesn't reliably dodge it since
# the attribute can reappear after clearing but before codesign reads the
# file, so retry a few times rather than failing the whole build over it.
for attempt in 1 2 3; do
  xattr -cr "$APP_BUNDLE"
  if [ -z "$SIGNING_IDENTITY" ]; then
    if [ "$attempt" = 1 ]; then echo "No Developer ID Application certificate found — falling back to ad-hoc signing."; fi
    codesign --force --deep --sign - "$APP_BUNDLE" && break
  else
    if [ "$attempt" = 1 ]; then echo "    Using: $SIGNING_IDENTITY"; fi
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" && break
  fi
  if [ "$attempt" = 3 ]; then
    echo "codesign failed after 3 attempts." >&2
    exit 1
  fi
  echo "    codesign attempt $attempt failed (stray extended attributes), retrying..."
  sleep 1
done

echo "==> Installing to /Applications/$APP_NAME.app..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" /Applications/

echo "==> Done: /Applications/$APP_NAME.app"
echo ""
echo "Run it:    open -a $APP_NAME"
echo "Its own prefs domain: com.skylerschoos.envy.test (safe to repoint at a scratch folder)"

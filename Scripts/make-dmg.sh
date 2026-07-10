#!/bin/bash
# Builds, signs, and notarizes Envy.app, then packages it as Envy.dmg — the
# actual file meant for the website's download button. Unlike make-zip.sh,
# this mounts as a normal macOS disk image with a shortcut to /Applications,
# the standard "drag it over there" install experience.
#
# Usage: Scripts/make-dmg.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Envy.app"
DMG_PATH="$DIST_DIR/Envy.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"

echo "==> Building Envy.app..."
"$ROOT_DIR/Scripts/build-app.sh"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  "$ROOT_DIR/Scripts/notarize.sh"
else
  echo "==> No Developer ID certificate found, skipping notarization."
  echo "    (This dmg will trigger Gatekeeper's 'unidentified developer' warning.)"
fi

echo "==> Assembling disk image contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Building Envy.dmg..."
rm -f "$DMG_PATH"
hdiutil create -volname "Envy" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"

# The dmg itself isn't notarized/stapled — only the .app inside is — since
# Gatekeeper's actual check happens against the app bundle once it's dragged
# out and opened, not the disk image wrapper. The app's own staple (from
# notarize.sh above) covers that.

echo "==> Done: $DMG_PATH"

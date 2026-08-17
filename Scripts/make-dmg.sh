#!/bin/bash
# Builds, signs, and notarizes Envy.app, then packages it as Envy.dmg — the
# actual file meant for the website's download button. Unlike make-zip.sh,
# this mounts as a normal macOS disk image with a shortcut to /Applications,
# the standard "drag it over there" install experience.
#
# Also updates the Sparkle appcast (EnvyWebsite/assets/updates/appcast.xml)
# so already-installed copies of Envy can discover this release — see
# Scripts/README (or the comments below) for what that step needs.
#
# Usage: Scripts/make-dmg.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Envy.app"
DMG_PATH="$DIST_DIR/Envy.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"
UPDATES_DIR="$ROOT_DIR/../EnvyWebsite/assets/updates"
GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

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

if [ -x "$GENERATE_APPCAST" ] && [ -d "$(dirname "$UPDATES_DIR")/.." ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Scripts/Info.plist")"
  echo "==> Updating Sparkle appcast for version $VERSION..."
  mkdir -p "$UPDATES_DIR"
  # generate_appcast keeps every past release's archive around (it needs
  # them to build delta updates and a full version history) — only the
  # website's main "Download for Mac" button points at the always-latest
  # dist/Envy.dmg copied elsewhere; this versioned copy is purely for
  # Sparkle's own feed.
  cp "$DMG_PATH" "$UPDATES_DIR/Envy-$VERSION.dmg"
  # Without --download-url-prefix, generate_appcast assumes the archives
  # directory is served from the site's root, producing enclosure URLs like
  # https://envynote.app/Envy-1.0.1.dmg — wrong, since these dmgs actually
  # live under assets/updates/.
  # Phased rollout: Sparkle sorts every install into one of 7 stable groups and
  # only offers the update to group N once N intervals have passed, so at 12
  # hours the release reaches everyone over 3 days rather than all at once. The
  # point is time — with no telemetry in Envy by design, a broken release is
  # only ever discovered by someone reporting it, and this buys a few days to
  # hear about it and run push-to-prod.sh --rollback while most users have not
  # been offered the build yet.
  #
  # Two things it deliberately does not do. It never gates a manual "Check for
  # Updates…", which always offers the newest version regardless of group. And
  # since SUEnableAutomaticChecks is false, it only ever applies to users who
  # opted into background checks — which is the population worth protecting,
  # since they are the ones who would take a bad build without noticing.
  #
  # For a security fix, where slow propagation is the problem rather than the
  # protection, add --critical-update-version "$VERSION" to bypass phasing.
  PHASED_ROLLOUT_INTERVAL=43200  # 12 hours; full rollout in 3 days
  "$GENERATE_APPCAST" \
    --download-url-prefix "https://envynote.app/assets/updates/" \
    --phased-rollout-interval "$PHASED_ROLLOUT_INTERVAL" \
    "$UPDATES_DIR"
  echo "==> appcast.xml updated: $UPDATES_DIR/appcast.xml"
  echo "    (phased rollout: ${PHASED_ROLLOUT_INTERVAL}s per group, ~3 days to reach everyone)"
  echo "    (deploy EnvyWebsite, e.g. via netlify deploy, for this to take effect)"
else
  echo "==> Skipping appcast update (generate_appcast or ../EnvyWebsite not found)."
fi

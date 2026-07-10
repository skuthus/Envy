#!/bin/bash
# Submits the already-built, Developer ID-signed Envy.app to Apple for
# notarization, then staples the resulting ticket to the app bundle.
# Requires a stored notarytool keychain profile (see README for setup).
#
# Usage: Scripts/notarize.sh [keychain-profile-name]
#   defaults to "envy-notary" if omitted

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROFILE="${1:-envy-notary}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Envy.app"
SUBMIT_ZIP="$DIST_DIR/Envy-notarize-submit.zip"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: $APP_BUNDLE not found. Run Scripts/build-app.sh first." >&2
  exit 1
fi

echo "==> Zipping $APP_BUNDLE for submission..."
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$SUBMIT_ZIP"

echo "==> Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket to $APP_BUNDLE..."
xcrun stapler staple "$APP_BUNDLE"

rm -f "$SUBMIT_ZIP"

echo "==> Done. $APP_BUNDLE is signed, notarized, and stapled."

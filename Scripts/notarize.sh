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

if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: $APP_BUNDLE not found. Run Scripts/build-app.sh first." >&2
  exit 1
fi

# Submission + staple both happen on a /tmp copy, not $APP_BUNDLE directly —
# this project folder lives under iCloud Drive's Desktop & Documents sync,
# and notarization's multi-minute wait is long enough for the synced copy to
# drift from what was actually submitted (seen once already: stapler kept
# failing with "record not found" because the on-disk cdhash no longer
# matched the notarized cdhash). /tmp isn't synced, so the file submitted is
# guaranteed to be the exact same bytes stapled a few minutes later.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
WORK_APP="$WORK_DIR/Envy.app"
SUBMIT_ZIP="$WORK_DIR/Envy-notarize-submit.zip"
cp -R "$APP_BUNDLE" "$WORK_APP"

echo "==> Zipping Envy.app for submission..."
ditto -c -k --keepParent "$WORK_APP" "$SUBMIT_ZIP"

echo "==> Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket..."
xcrun stapler staple "$WORK_APP"

echo "==> Copying stapled build back to $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
cp -R "$WORK_APP" "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

echo "==> Verifying..."
spctl -a -vv "$APP_BUNDLE"

echo "==> Done. $APP_BUNDLE is signed, notarized, and stapled."

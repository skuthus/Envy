#!/bin/bash
# Builds Envy.app and zips it up for sharing with others.
#
# Usage: Scripts/make-zip.sh [version]
#   version defaults to "latest" if omitted, e.g.:
#     Scripts/make-zip.sh 1.1.0   -> dist/Envy-1.1.0-macOS.zip

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-latest}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Envy.app"
ZIP_PATH="$DIST_DIR/Envy-$VERSION-macOS.zip"

echo "==> Building Envy.app..."
"$ROOT_DIR/Scripts/build-app.sh"

echo "==> Zipping..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Done: $ZIP_PATH"

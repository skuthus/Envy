# Embeds and signs Sparkle.framework into an app bundle. Sourced by
# build-app.sh and build-test-app.sh rather than duplicated in both, since
# Sparkle's nested structure — a helper .app plus two XPC services living
# inside the framework — needs identical inside-out signing wherever it's
# embedded.
#
# Usage: embed_sparkle "$APP_BUNDLE" "$APP_NAME" "$SIGNING_IDENTITY"
# (SIGNING_IDENTITY may be empty, in which case everything signs ad-hoc —
# matching how the calling script's own outer-bundle signing falls back.)

embed_sparkle() {
  local app_bundle="$1"
  local app_name="$2"
  local signing_identity="$3"

  local binary_path
  binary_path="$(swift build -c release --product Envy --show-bin-path)/Envy"
  local release_dir
  release_dir="$(dirname "$binary_path")"
  local sparkle_src="$release_dir/Sparkle.framework"
  if [ ! -d "$sparkle_src" ]; then
    echo "error: Sparkle.framework not found at $sparkle_src (expected next to the release binary)." >&2
    exit 1
  fi

  local frameworks_dir="$app_bundle/Contents/Frameworks"
  mkdir -p "$frameworks_dir"
  rm -rf "$frameworks_dir/Sparkle.framework"
  cp -R "$sparkle_src" "$frameworks_dir/Sparkle.framework"

  # The binary only carries @loader_path by default (SwiftPM's own build
  # layout, where the framework sits right next to the executable) —
  # @executable_path/../Frameworks is what actually resolves once
  # repackaged into a real .app, where the framework lives in
  # Contents/Frameworks instead.
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_bundle/Contents/MacOS/$app_name" 2>/dev/null || true

  local sign_args=(--force --options runtime --timestamp)
  if [ -z "$signing_identity" ]; then
    sign_args+=(--sign -)
  else
    sign_args+=(--sign "$signing_identity")
  fi

  # Sparkle ships its framework ad-hoc signed. A shallow or --deep sign of
  # just the outer app isn't reliable for a bundle-in-bundle structure this
  # deep, so each nested component gets its own real signature first,
  # working inward-out: XPC services, then the helper .app, then the
  # framework itself — each with the same identity as the outer app will
  # ultimately be signed with.
  local sparkle_dir="$frameworks_dir/Sparkle.framework"
  for xpc in "$sparkle_dir"/Versions/B/XPCServices/*.xpc; do
    [ -d "$xpc" ] || continue
    sign_with_retry "$xpc" "${sign_args[@]}"
  done
  if [ -d "$sparkle_dir/Versions/B/Updater.app" ]; then
    sign_with_retry "$sparkle_dir/Versions/B/Updater.app" "${sign_args[@]}"
  fi
  sign_with_retry "$sparkle_dir" "${sign_args[@]}"
}

# Belt-and-suspenders retry for the occasional "resource fork, Finder
# information, or similar detritus not allowed" from codesign. The main
# cause — this project folder living under iCloud Drive's Desktop &
# Documents sync, which continuously re-tags bundle-type directories — is
# avoided entirely by callers assembling and signing under /tmp rather than
# inside the synced project folder, but a plain retry stays cheap insurance
# against any other transient cause (e.g. Spotlight indexing a freshly
# written file).
sign_with_retry() {
  local target="$1"
  shift
  for attempt in 1 2 3; do
    xattr -cr "$target"
    if codesign "$@" "$target"; then
      return 0
    fi
    if [ "$attempt" = 3 ]; then
      echo "codesign failed after 3 attempts: $target" >&2
      exit 1
    fi
    sleep 1
  done
}

#!/bin/bash
# Ships Envy. One command, from a clean tree to a release users can install.
#
# Usage:
#   Scripts/push-to-prod.sh --version 1.11.0     full release
#   Scripts/push-to-prod.sh --site-only          website changes only, no new build
#   Scripts/push-to-prod.sh --rollback           un-offer the current release
#   ...plus --dry-run on any of the above, which stops short of every
#   irreversible step and tells you what it would have done instead, and
#   --yes, which skips the confirmations (saying "push to prod" is the
#   approval). Failed checks still abort the run either way.
#
# The long-form reasoning behind each phase lives in Scripts/RELEASE.md. This
# file is the executable version of that document; if the two ever disagree,
# RELEASE.md is the one that explains why, and this one is the one that runs.
#
# Nothing here is silent. Every phase announces itself, every check prints its
# actual result rather than just passing, and the two approval gates stop dead
# until you type the word they ask for. A release that reaches users cannot be
# recalled, so this script is deliberately slower and chattier than it needs to
# be.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SITE_DIR="$ROOT_DIR/../EnvyWebsite"
DRAFTS_DIR="$ROOT_DIR/../EnvyWebsite-drafts"
DIST_DIR="$ROOT_DIR/dist"
UPDATES_DIR="$SITE_DIR/assets/updates"
DOWNLOADS_DIR="$SITE_DIR/assets/downloads"
INFO_PLIST="$ROOT_DIR/Scripts/Info.plist"
GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
NOTARY_PROFILE="envy-notary"
SITE_URL="https://envynote.app"

VERSION=""
MODE="release"
DRY_RUN=0
ASSUME_YES=0

# ── plumbing ────────────────────────────────────────────────────────────────

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "    %s\n" "$*"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "    \033[33m!\033[0m %s\n" "$*"; }
die()  { printf "\n\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

phase() { printf "\n\033[1m══ %s\033[0m\n" "$*"; }

# Every gate wants a specific word typed out, not a y/n. A stray keystroke
# should not be able to ship a release, and "yes" is hard to hit by accident.
gate() {
  local prompt="$1" want="$2" answer
  if [ "$DRY_RUN" = 1 ]; then
    warn "dry run: would stop here and ask you to type '$want'"
    return 0
  fi
  # --yes exists because saying "push to prod" is itself the approval, so being
  # asked again adds nothing. It skips the confirmations only; every automatic
  # check still aborts the run on failure, which is the part actually doing the
  # protecting.
  if [ "$ASSUME_YES" = 1 ]; then
    info "auto-confirmed (--yes): $(echo "$prompt" | head -1)"
    return 0
  fi
  printf "\n\033[1m%s\033[0m\n" "$prompt"
  printf "Type '%s' to continue, anything else to abort: " "$want"
  read -r answer
  [ "$answer" = "$want" ] || die "Aborted at the gate. Nothing has been published."
}

# Wraps anything that changes the outside world — deploys, pushes, releases.
# In a dry run it prints the command instead of running it, which is what makes
# --dry-run trustworthy rather than merely well-intentioned.
live() {
  if [ "$DRY_RUN" = 1 ]; then
    printf "    \033[33m[dry run]\033[0m %s\n" "$*"
    return 0
  fi
  "$@"
}

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="${2:-}"; shift 2 ;;
    --site-only) MODE="site"; shift ;;
    --rollback)  MODE="rollback"; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    -h|--help)   usage ;;
    *)           die "Unknown argument: $1 (try --help)" ;;
  esac
done

[ -d "$SITE_DIR" ] || die "Website not found at $SITE_DIR.
The two repos must sit side by side under the same parent folder — make-dmg.sh
resolves the site as ../EnvyWebsite, and the appcast step skips silently if it
cannot find it."
SITE_DIR="$(cd "$SITE_DIR" && pwd)"
DRAFTS_DIR="$(dirname "$SITE_DIR")/EnvyWebsite-drafts"

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
LOG_DIR="$DIST_DIR/release-logs/${VERSION:-$CURRENT_VERSION}"
mkdir -p "$LOG_DIR"

# ── phase 0: preflight ──────────────────────────────────────────────────────
#
# Read-only. Collects every failure before reporting, rather than stopping at
# the first one, so a broken setup takes one round trip to fix instead of five.

preflight() {
  phase "Preflight"
  local failures=()

  # Credentials. The certificate expiry check matters more than it looks: a
  # Developer ID cert lasts five years and then simply stops working, and the
  # first sign of trouble is a failed release rather than a warning.
  local identity
  identity="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)"
  if [ -z "$identity" ]; then
    failures+=("No Developer ID Application certificate in the keychain.")
  else
    ok "signing identity: $(echo "$identity" | sed -E 's/.*"(.*)"/\1/')"
    local expiry
    expiry="$(security find-certificate -c "Developer ID Application" -p 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    if [ -n "$expiry" ]; then
      local days_left
      days_left=$(( ( $(date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
      if [ "$days_left" -lt 0 ]; then
        failures+=("Signing certificate EXPIRED ($expiry).")
      elif [ "$days_left" -lt 45 ]; then
        warn "signing certificate expires in $days_left days ($expiry) — renew soon"
      else
        ok "certificate valid for $days_left more days"
      fi
    fi
  fi

  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    ok "notary profile '$NOTARY_PROFILE' works"
  else
    failures+=("Notary keychain profile '$NOTARY_PROFILE' missing or rejected.")
  fi

  # Must run from the site directory: netlify resolves the linked project from
  # .netlify/state.json in the current folder, so checking from the app repo
  # reports "not linked" no matter how healthy the real link is.
  if (cd "$SITE_DIR" && netlify status >/dev/null 2>&1); then
    ok "netlify authenticated, project linked"
  else
    failures+=("Netlify CLI not authenticated, or $SITE_DIR is not linked to a project.")
  fi

  # gh's /user endpoint returns 503 through some sandboxed environments while
  # repo-scoped endpoints work fine, so this deliberately tests a repo call
  # rather than an identity call. A 503 from `gh api user` is not an auth error.
  if gh release list --repo skuthus/Envy --limit 1 >/dev/null 2>&1; then
    ok "github reachable and authenticated for skuthus/Envy"
  else
    failures+=("Cannot reach skuthus/Envy via gh. Check 'gh auth status'.")
  fi

  if [ "$MODE" = "release" ]; then
    if [ -x "$GENERATE_APPCAST" ]; then
      ok "generate_appcast present"
    else
      # Worth failing loudly on. make-dmg.sh treats a missing generate_appcast
      # as a skippable step and still exits successfully, which would hand you
      # a finished dmg and an unchanged appcast — a release nobody is offered.
      failures+=("generate_appcast missing at $GENERATE_APPCAST.
      Run 'swift build -c release --product Envy' to fetch Sparkle, then retry.")
    fi
  fi

  # Gate 1: uncommitted work stops the run. Not negotiable, and never resolved
  # by discarding anything — this only ever reports.
  local dirty=0
  for repo in "$ROOT_DIR" "$SITE_DIR"; do
    if [ -n "$(git -C "$repo" status --porcelain)" ]; then
      dirty=1
      printf "\n"
      warn "uncommitted changes in $(basename "$repo"):"
      git -C "$repo" status --short | sed 's/^/        /'
    fi
  done
  if [ "$dirty" = 1 ]; then
    # Recorded rather than fatal-on-the-spot, so a dirty tree and a missing
    # credential surface in the same run. Dying here would hide every check
    # below it and turn one round trip into several.
    failures+=("Uncommitted work in one or both repos (listed above).
      Commit it, or stash it yourself, then run this again. This script will not
      discard, stash, or commit your work for you — deciding what ships is your
      call, not its own.")
  else
    ok "both working trees clean"
  fi

  # Anything sitting in the publish root goes live, because Netlify uploads the
  # folder wholesale. Drafts belong in ../EnvyWebsite-drafts for exactly this
  # reason. This catches a draft that wandered back in.
  local unpublished=()
  for f in "$SITE_DIR"/*.html; do
    local name code
    name="$(basename "$f" .html)"
    # Follows redirects on purpose: Netlify's pretty-URL handling 301s /index
    # to /, which would otherwise flag the homepage as an unpublished draft on
    # every single run. A page that genuinely does not exist still 404s.
    code="$(curl -sL -o /dev/null -w "%{http_code}" "$SITE_URL/$name" || echo 000)"
    [ "$code" = "200" ] || unpublished+=("$(basename "$f") (currently $code on prod)")
  done
  if [ ${#unpublished[@]} -gt 0 ]; then
    warn "pages in the publish root that are NOT currently live:"
    printf "        %s\n" "${unpublished[@]}"
    info "these will go live with this deploy — move drafts to $DRAFTS_DIR to hold them back"
  else
    ok "no unpublished pages sitting in the publish root"
  fi

  if [ ${#failures[@]} -gt 0 ]; then
    printf "\n"
    printf "\033[31m✗ %s\033[0m\n" "${failures[@]}" >&2
    die "Preflight failed. Nothing was changed."
  fi
  ok "preflight passed"
}

# ── rollback ────────────────────────────────────────────────────────────────
#
# Not an undo. Anyone who already updated stays updated — software cannot be
# recalled from someone's machine. What this does is stop offering the release
# to everyone who has not taken it yet, which is the part that is still in your
# control and the part that matters when a release turns out to be bad.

do_rollback() {
  phase "Rollback: stop offering $CURRENT_VERSION"

  local snapshot="$DIST_DIR/release-logs/$CURRENT_VERSION/appcast.previous.xml"
  [ -f "$snapshot" ] || die "No pre-release appcast snapshot at $snapshot.
Without it there is nothing to restore. Recover by hand: delete the newest
<item> block from $UPDATES_DIR/appcast.xml, restore the previous dmg to
$DOWNLOADS_DIR/Envy.dmg, and deploy."

  local previous
  previous="$(grep -m1 -o '<sparkle:shortVersionString>[^<]*' "$snapshot" | cut -d'>' -f2)"
  info "restoring the feed to its state before $CURRENT_VERSION (top item: $previous)"

  [ -f "$UPDATES_DIR/Envy-$previous.dmg" ] || die "Previous build Envy-$previous.dmg is missing; cannot restore the download button."

  gate "This restores the appcast to $previous and points the download button back at $previous.
Anyone who already installed $CURRENT_VERSION keeps it." "rollback"

  live cp "$snapshot" "$UPDATES_DIR/appcast.xml"
  live cp "$UPDATES_DIR/Envy-$previous.dmg" "$DOWNLOADS_DIR/Envy.dmg"
  live bash -c "cd '$SITE_DIR' && netlify deploy --prod"

  if [ "$DRY_RUN" = 0 ]; then
    local served
    served="$(curl -s "$SITE_URL/assets/updates/appcast.xml" | grep -m1 -o '<sparkle:shortVersionString>[^<]*' | cut -d'>' -f2)"
    [ "$served" = "$previous" ] && ok "feed now offers $served" || die "Feed still offers $served. Investigate immediately."
  fi

  bold "Rolled back. Fix the problem, then ship a new version — never re-use $CURRENT_VERSION."
  info "Sparkle keys updates by version number, so a re-used version reaches nobody who already has it."
}

# ── site-only track ─────────────────────────────────────────────────────────

do_site_only() {
  phase "Website-only deploy"

  # A draft deploy is free and gives a real, working URL on the real host. It
  # is the closest thing to a staging environment this setup has, and skipping
  # it means production is the first place the change is ever seen.
  info "publishing a draft to preview before anything touches production..."
  local draft_url=""
  if [ "$DRY_RUN" = 0 ]; then
    draft_url="$(cd "$SITE_DIR" && netlify deploy --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("deploy_url",""))')"
    [ -n "$draft_url" ] && ok "preview: $draft_url" || warn "draft deploy produced no URL"
  else
    warn "dry run: would publish a draft deploy and print its preview URL"
  fi

  gate "Open the preview above and confirm it looks right. This next step publishes to $SITE_URL." "ship it"

  live bash -c "cd '$SITE_DIR' && netlify deploy --prod"
  ok "deployed"

  phase "Verifying"
  if [ "$DRY_RUN" = 0 ]; then
    local code
    code="$(curl -s -o /dev/null -w "%{http_code}" "$SITE_URL")"
    [ "$code" = "200" ] && ok "$SITE_URL responds 200" || die "$SITE_URL returned $code"
  fi
  bold "Website is live. Commit and push the site repo when you're ready — that's history, not deployment."
}

# ── full release ────────────────────────────────────────────────────────────

do_release() {
  [ -n "$VERSION" ] || die "A full release needs --version X.Y.Z (current: $CURRENT_VERSION)."
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must look like 1.11.0, got '$VERSION'."
  [ "$VERSION" != "$CURRENT_VERSION" ] || die "Version $VERSION is already what's in Info.plist.
Sparkle keys updates by version number, so shipping the same number twice
reaches nobody who already has it."

  # Release notes have to exist before anything is built. The script can verify
  # they were written; it cannot write them, and a release with no notes is a
  # release nobody can evaluate before installing.
  phase "Checking release notes exist"
  grep -q "^## $VERSION " "$ROOT_DIR/CHANGELOG.md" \
    || die "No '## $VERSION — <date>' section in CHANGELOG.md. Write the release notes first."
  ok "CHANGELOG.md has an entry for $VERSION"
  grep -q "id=\"v${VERSION//./-}\"" "$SITE_DIR/changelog.html" \
    || die "No section id=\"v${VERSION//./-}\" in changelog.html. Add the matching web entry first."
  ok "changelog.html has an entry for $VERSION"

  preflight

  phase "Bumping version: $CURRENT_VERSION → $VERSION"
  live /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
  live /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST"
  ok "Info.plist updated"

  phase "Building the test app for verification"
  # EnvySelfCheck only depends on EnvyCore. The whole Envy executable target —
  # the editor, the styler, search — is outside its reach, so this is a partial
  # check and gets described as one rather than being allowed to imply coverage.
  # --product Envy, not a blanket build: EnvySelfCheck does @testable import
  # EnvyCore, and a release build does not enable testing, so building the whole
  # package in release fails with ModuleNotTestable before it reaches anything
  # useful. build-app.sh scopes its build the same way for the same reason.
  #
  # SelfCheck then runs in debug, where -enable-testing is on by default. It is
  # a correctness check, so the build configuration it runs under does not
  # matter; the release binary above is what actually ships.
  live swift build -c release --product Envy
  live swift run EnvySelfCheck
  ok "EnvySelfCheck passed (covers EnvyCore only, not the app target)"
  live "$ROOT_DIR/Scripts/build-test-app.sh"

  gate "Open dist/EnvyTest.app and confirm it works.
This is the only real coverage the app target gets, so it is worth the minute." "it works"

  phase "Building, notarizing, and packaging the release"
  live "$ROOT_DIR/Scripts/make-dmg.sh"

  if [ "$DRY_RUN" = 0 ]; then
    [ -f "$DIST_DIR/Envy.dmg" ] || die "make-dmg.sh finished but dist/Envy.dmg is missing."
    grep -q "<sparkle:shortVersionString>$VERSION<" "$UPDATES_DIR/appcast.xml" \
      || die "appcast.xml has no entry for $VERSION.
generate_appcast did not run. Users would never be offered this release."
    ok "appcast contains $VERSION"

    # A missing interval means the release would go to everyone at once. Not
    # fatal — it still works — but it silently removes the window that makes
    # --rollback useful, so it is worth saying out loud rather than assuming.
    if grep -q "sparkle:phasedRolloutInterval" "$UPDATES_DIR/appcast.xml"; then
      ok "phased rollout active ($(grep -m1 -o 'phasedRolloutInterval>[0-9]*' "$UPDATES_DIR/appcast.xml" | cut -d'>' -f2)s per group)"
    else
      warn "no phased rollout interval — this release goes to every auto-updating user at once"
    fi
  fi

  smoke_test_dmg
  update_website
  ship
}

# The thing users actually download is otherwise never opened before shipping.
# EnvyTest.app is a different bundle with a different identifier, so it proves
# the code works, not that the package works. This mounts the real dmg, copies
# the app out the way a user would, applies the quarantine flag macOS attaches
# to anything downloaded, and asks Gatekeeper what it thinks.
smoke_test_dmg() {
  phase "Smoke-testing the actual dmg"
  if [ "$DRY_RUN" = 1 ]; then
    warn "dry run: would mount dist/Envy.dmg and run Gatekeeper against the copied app"
    return 0
  fi

  local mount_point
  mount_point="$(mktemp -d)"
  hdiutil attach "$DIST_DIR/Envy.dmg" -nobrowse -quiet -mountpoint "$mount_point"
  # shellcheck disable=SC2064
  trap "hdiutil detach '$mount_point' -quiet 2>/dev/null || true; rm -rf '$mount_point'" RETURN

  local test_copy="$DIST_DIR/smoke-test"
  rm -rf "$test_copy"; mkdir -p "$test_copy"
  cp -R "$mount_point/Envy.app" "$test_copy/"

  # Without this the test is dishonest: notarize.sh strips extended attributes,
  # so the local bundle has no quarantine flag and Gatekeeper waves it through
  # on a path no downloading user ever takes.
  xattr -w com.apple.quarantine "0081;00000000;Safari;" "$test_copy/Envy.app"

  if spctl -a -vv "$test_copy/Envy.app" 2>&1 | grep -q "accepted"; then
    ok "Gatekeeper accepts the app as downloaded (quarantined)"
  else
    spctl -a -vv "$test_copy/Envy.app" 2>&1 | sed 's/^/        /'
    die "Gatekeeper REJECTED the shipped app. Users would see 'unidentified developer'. Do not ship."
  fi

  local shipped_version
  shipped_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$test_copy/Envy.app/Contents/Info.plist")"
  [ "$shipped_version" = "$VERSION" ] || die "The dmg contains version $shipped_version, not $VERSION."
  ok "dmg contains version $shipped_version"

  rm -rf "$test_copy"
}

update_website() {
  phase "Updating the website"

  # make-dmg.sh writes assets/updates/ and nothing else. This is the file the
  # download button serves, and forgetting it produces the worst kind of
  # half-broken release: Sparkle correctly offers the new version to existing
  # users while the front page still hands new visitors the old one.
  live cp "$DIST_DIR/Envy.dmg" "$DOWNLOADS_DIR/Envy.dmg"
  ok "download button now serves $VERSION"

  local bytes size
  bytes="$(stat -f%z "$DIST_DIR/Envy.dmg" 2>/dev/null || echo 0)"
  size="$(python3 -c "print(f'{$bytes/1e6:.1f}')")"
  info "dmg is $bytes bytes ($size MB)"

  if [ "$DRY_RUN" = 0 ]; then
    python3 - "$SITE_DIR/index.html" "$CURRENT_VERSION" "$VERSION" "$size" <<'PY'
import re, sys
path, old_ver, new_ver, new_size = sys.argv[1:5]
html = open(path).read()

# The version and size are hardcoded in seven places in index.html and none of
# them are generated. Replacing the literal strings is safe precisely because
# they are so specific — a bare version number appears nowhere else in the file.
n_ver = html.count(old_ver)
old_size = re.search(r'(\d+\.\d+) MB', html)
if not old_size:
    sys.exit("Could not find a '<n.n> MB' size string in index.html")
old_size = old_size.group(1)
n_size = html.count(f'{old_size} MB')

if n_ver == 0:
    sys.exit(f"index.html contains no occurrence of {old_ver}; refusing to guess")

html = html.replace(old_ver, new_ver).replace(f'{old_size} MB', f'{new_size} MB')
open(path, 'w').write(html)
print(f"    ✓ index.html: {n_ver} version string(s) {old_ver}→{new_ver}, "
      f"{n_size} size string(s) {old_size}→{new_size} MB")
PY
  else
    warn "dry run: would rewrite version and size strings in index.html"
  fi

  # Cross-check every place a version can disagree. Catching this here is the
  # difference between a typo and a release that claims two different versions.
  if [ "$DRY_RUN" = 0 ]; then
    phase "Version consistency"
    local plist_v appcast_v index_v
    plist_v="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
    appcast_v="$(grep -m1 -o '<sparkle:shortVersionString>[^<]*' "$UPDATES_DIR/appcast.xml" | cut -d'>' -f2)"
    index_v="$(grep -m1 -o '"softwareVersion": "[^"]*' "$SITE_DIR/index.html" | cut -d'"' -f4)"
    printf "        Info.plist   %s\n        appcast.xml  %s\n        index.html   %s\n" "$plist_v" "$appcast_v" "$index_v"
    [ "$plist_v" = "$VERSION" ] && [ "$appcast_v" = "$VERSION" ] && [ "$index_v" = "$VERSION" ] \
      || die "Version numbers disagree. Fix before shipping."
    ok "all three agree on $VERSION"
  fi

  warn "docs.html is not updated automatically — check whether this release changes anything documented there"
}

ship() {
  # Saved before the deploy, because after the deploy it is gone and rollback
  # depends on it. This one file is the entire difference between "restore the
  # previous feed in thirty seconds" and "reconstruct it by hand under pressure".
  live cp "$UPDATES_DIR/appcast.xml" "$LOG_DIR/appcast.previous.xml.tmp" 2>/dev/null || true
  if [ "$DRY_RUN" = 0 ] && [ -f "$LOG_DIR/appcast.previous.xml.tmp" ]; then
    # Strip the new item so the snapshot represents the world before this release.
    python3 - "$LOG_DIR/appcast.previous.xml.tmp" "$LOG_DIR/appcast.previous.xml" "$VERSION" <<'PY'
import re, sys
src, dst, version = sys.argv[1:4]
xml = open(src).read()
pattern = re.compile(r'\s*<item>(?:(?!</item>).)*?<sparkle:shortVersionString>'
                     + re.escape(version) + r'</sparkle:shortVersionString>.*?</item>', re.S)
open(dst, 'w').write(pattern.sub('', xml, count=1))
PY
    rm -f "$LOG_DIR/appcast.previous.xml.tmp"
    ok "rollback snapshot saved to $LOG_DIR/appcast.previous.xml"
  fi

  phase "Preview deploy"
  local draft_url=""
  if [ "$DRY_RUN" = 0 ]; then
    draft_url="$(cd "$SITE_DIR" && netlify deploy --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("deploy_url",""))')"
    ok "preview: $draft_url"
  else
    warn "dry run: would publish a draft deploy first"
  fi

  phase "Ready to publish"
  cat <<EOF

    version        $CURRENT_VERSION → $VERSION
    dmg            $(ls -lh "$DIST_DIR/Envy.dmg" 2>/dev/null | awk '{print $5}') at dist/Envy.dmg
    sha256         $(shasum -a 256 "$DIST_DIR/Envy.dmg" 2>/dev/null | cut -d' ' -f1)
    preview        ${draft_url:-<dry run>}
    goes live at   $SITE_URL
    github release v$VERSION on skuthus/Envy

    Deploying publishes the appcast, which is the moment every installed copy of
    Envy starts seeing this update. That cannot be undone — only superseded.
EOF

  gate "Publish to production?" "ship it"

  phase "Publishing"
  live bash -c "cd '$SITE_DIR' && netlify deploy --prod"
  ok "website deployed"

  if [ "$DRY_RUN" = 0 ]; then
    phase "Verifying what production actually serves"
    local served_version served_len appcast_len
    served_version="$(curl -s "$SITE_URL/assets/updates/appcast.xml" | grep -m1 -o '<sparkle:shortVersionString>[^<]*' | cut -d'>' -f2)"
    [ "$served_version" = "$VERSION" ] && ok "appcast offers $VERSION" || die "appcast still offers $served_version"

    served_len="$(curl -sI "$SITE_URL/assets/updates/Envy-$VERSION.dmg" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')"
    appcast_len="$(grep -o "Envy-$VERSION.dmg\" length=\"[0-9]*" "$UPDATES_DIR/appcast.xml" | grep -o '[0-9]*$')"
    # Sparkle refuses an update whose download does not match the advertised
    # length. Catching that here costs one curl; catching it later costs a bug
    # report from someone whose updater silently stopped working.
    if [ "$served_len" = "$appcast_len" ]; then
      ok "served dmg length matches the appcast ($served_len bytes)"
    else
      die "Length mismatch: appcast says $appcast_len, server sends $served_len. Sparkle will reject this update."
    fi

    curl -s "$SITE_URL/" | grep -q "$VERSION" && ok "homepage shows $VERSION" || warn "homepage does not mention $VERSION"
  fi

  phase "Committing and tagging"
  live bash -c "cd '$SITE_DIR' && git add -A && git commit -m 'Envy $VERSION release: dmg, appcast, homepage version' && git push"
  live git add -A
  live git commit -m "Release $VERSION"
  live git tag "v$VERSION"
  live git push
  live git push --tags

  phase "GitHub release"
  local notes="$LOG_DIR/release-notes.md"
  if [ "$DRY_RUN" = 0 ]; then
    awk "/^## $VERSION /{flag=1; next} /^## /{flag=0} flag" "$ROOT_DIR/CHANGELOG.md" > "$notes"
    printf '\n---\n\nSHA-256 of `Envy.dmg`:\n\n```\n%s\n```\n' \
      "$(shasum -a 256 "$DIST_DIR/Envy.dmg" | cut -d' ' -f1)" >> "$notes"
  fi
  live gh release create "v$VERSION" --repo skuthus/Envy \
    --title "Envy $VERSION" --notes-file "$notes" "$DIST_DIR/Envy.dmg"

  phase "Done"
  cat <<EOF

    $VERSION is live.

    Worth doing by hand now:
      • Open an older copy of Envy and check Envy menu → "Check for Updates…"
      • Retitle the GitHub release if you want a headline, e.g.
        gh release edit v$VERSION --repo skuthus/Envy --title "Envy $VERSION: <headline>"
      • Stay near a laptop for a few hours. If it goes wrong, the fix is
        Scripts/push-to-prod.sh --rollback

EOF
}

# ── main ────────────────────────────────────────────────────────────────────

[ "$DRY_RUN" = 1 ] && bold "DRY RUN — nothing will be published"

case "$MODE" in
  rollback) do_rollback ;;
  site)     preflight; do_site_only ;;
  release)  do_release ;;
esac

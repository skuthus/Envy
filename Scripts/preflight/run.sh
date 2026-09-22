#!/bin/bash
# Envy preflight — the gate before every push to prod (see Scripts/RELEASE.md).
#
# Checks, in order: repo state, the release build, EnvySelfCheck, security and
# hygiene (secrets, debug leftovers, update-feed and transport settings,
# dependency pins), the signed EnvyTest bundle (signature, hardened runtime,
# entitlements), then drives EnvyTest end to end with real clicks and typing
# against a throwaway clone of the test vault — correctness in the note files,
# performance budgets, background work, and crashes.
#
# Usage: Scripts/preflight/run.sh [--quick] [--allow-dirty]
#   --quick        skip the live UI suite (build, self-check, security only)
#   --allow-dirty  don't fail on uncommitted changes (for trying it mid-work)
#
# The live suite takes over the mouse and keyboard for ~10 minutes — don't use
# the Mac while it runs. It never touches the real vault: it works in a clone
# (~/EnvyPreflightVault, from $ENVY_PREFLIGHT_VAULT or ~/TestFolder), and it
# restores EnvyTest's settings and deletes the clone on exit, however it ends.
#
# Exit status 0 means every check passed. The report is dist/preflight-report.md.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

QUICK=0; ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

WORK="$(mktemp -d /tmp/envy-preflight.XXXXXX)"
REPORT="$ROOT_DIR/dist/preflight-report.md"
mkdir -p "$ROOT_DIR/dist"
TEST_DOMAIN="com.skylerschoos.envy.test"
SOURCE_VAULT="${ENVY_PREFLIGHT_VAULT:-$HOME/TestFolder}"
CLONE="$HOME/EnvyPreflightVault"

PASSED=(); FAILED=()
pass() { PASSED+=("$1"); printf '   ok    %s%s\n' "$1" "${2:+ — $2}"; }
fail() { FAILED+=("$1${2:+ — $2}"); printf '   FAIL  %s%s\n' "$1" "${2:+ — $2}"; }
section() { printf '\n== %s\n' "$1"; }

# Runs a command with a hard time limit (seconds); output goes to $WORK/<name>.log.
limited() {
  local seconds="$1" name="$2"; shift 2
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@" > "$WORK/$name.log" 2>&1
}

# ---------------------------------------------------------------- restore
SAVED_PREFS=0
restore() {
  if [ "$SAVED_PREFS" = 1 ]; then
    # A graceful quit first, so no half-open window state is saved for next time.
    perl -e 'alarm 10; exec @ARGV' osascript -e 'tell application "/Applications/EnvyTest.app" to quit' >/dev/null 2>&1
    sleep 1
    pkill -9 -f "EnvyTest.app/Contents/MacOS/EnvyTest" 2>/dev/null
    sleep 1
    for key in indexPath menuBarTaskPin taskShowCompleted appVisibility lastSeenWhatsNewVersion; do
      if [ -f "$WORK/pref.$key" ]; then
        defaults write "$TEST_DOMAIN" "$key" "$(cat "$WORK/pref.$key")"
      else
        defaults delete "$TEST_DOMAIN" "$key" 2>/dev/null
      fi
    done
    [ -f "$WORK/pref.taskShowCompleted" ] && defaults write "$TEST_DOMAIN" taskShowCompleted -bool "$( [ "$(cat "$WORK/pref.taskShowCompleted")" = 1 ] && echo true || echo false )"
    rm -rf "$CLONE"
    SAVED_PREFS=0
  fi
  [ -x "$WORK/release-keys" ] && "$WORK/release-keys"
}
trap restore EXIT
trap 'echo; echo "interrupted"; exit 130' INT TERM

# A tiny tool that clears any logically held modifier key (see the harness).
cat > "$WORK/release-keys.swift" <<'EOF'
import CoreGraphics
let s = CGEventSource(stateID: .hidSystemState)
for code: CGKeyCode in [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E] {
    for down in [true, false] { let e = CGEvent(keyboardEventSource: s, virtualKey: code, keyDown: down); e?.flags = []; e?.post(tap: .cghidEventTap) }
}
if let e = CGEvent(source: s) { e.type = .flagsChanged; e.flags = []; e.post(tap: .cghidEventTap) }
EOF
swiftc -O "$WORK/release-keys.swift" -o "$WORK/release-keys" 2>/dev/null

echo "Envy preflight — $(git rev-parse --short HEAD) on $(git branch --show-current)"

# ---------------------------------------------------------------- repo
section "Repository"
if [ -z "$(git status --porcelain)" ]; then
  pass "Working tree is clean"
elif [ "$ALLOW_DIRTY" = 1 ]; then
  pass "Working tree has changes (allowed by --allow-dirty)"
else
  fail "Working tree has uncommitted changes" "commit or stash first (or pass --allow-dirty)"
fi
[ "$(git branch --show-current)" = "main" ] && pass "On main" || fail "Not on main" "releases ship from main"

# ---------------------------------------------------------------- build
section "Build and self-checks"
if limited 900 build swift build -c release --product Envy && grep -q "Build complete" "$WORK/build.log"; then
  pass "Release build" "$(grep -c 'warning:' "$WORK/build.log") warnings"
else
  fail "Release build" "$(grep -m3 'error:' "$WORK/build.log" | tr '\n' ' ')"
fi
if limited 900 selfcheck swift run --build-system native EnvySelfCheck && grep -q "All checks passed" "$WORK/selfcheck.log"; then
  pass "EnvySelfCheck" "$(grep -c '^PASS:' "$WORK/selfcheck.log") checks"
else
  fail "EnvySelfCheck" "$(grep -m5 '^FAIL:' "$WORK/selfcheck.log" | tr '\n' ' ')$(grep -m1 'error:' "$WORK/selfcheck.log")"
fi

# ---------------------------------------------------------------- security
section "Security and hygiene"
TRACKED="$(git ls-files)"
SECRETS="$(git ls-files -z | xargs -0 grep -nIE \
  -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
  -e 'AKIA[0-9A-Z]{16}' -e 'gh[pousr]_[A-Za-z0-9]{36,}' -e 'xox[abprs]-[A-Za-z0-9-]{10,}' \
  -e 'sk-(proj-|ant-)?[A-Za-z0-9_-]{20,}' -e 'NETLIFY_AUTH_TOKEN *= *[A-Za-z0-9]' \
  -e '(api[_-]?key|secret|password|passwd|token) *[:=] *"[^"]{12,}"' 2>/dev/null | grep -v '^Scripts/preflight/run.sh:' || true)"
[ -z "$SECRETS" ] && pass "No secrets in tracked files" || fail "Possible secrets in tracked files" "$(echo "$SECRETS" | head -3 | cut -c1-120 | tr '\n' ' ')"
KEYFILES="$(echo "$TRACKED" | grep -iE '\.(pem|p12|p8|key|cer|mobileprovision|keychain)$|(^|/)\.env' || true)"
[ -z "$KEYFILES" ] && pass "No key, certificate, or .env files tracked" || fail "Key/cert files tracked" "$KEYFILES"
LEFTOVERS="$(grep -rnE '\b(print|NSLog|debugPrint|dump)\(|TASKDBG|KEYDBG|DRAGDBG|FOCUSDBG|taskDbg|dragDbg|focusDbg' Sources/Envy Sources/EnvyCore 2>/dev/null | grep -vE '^[^:]+:[0-9]+: *//' || true)"
[ -z "$LEFTOVERS" ] && pass "No debug output left in shipping code" || fail "Debug output in shipping code" "$(echo "$LEFTOVERS" | head -3 | cut -c1-120 | tr '\n' ' ')"
for plist in Scripts/Info.plist Scripts/Info-Test.plist; do
  feed="$(plutil -extract SUFeedURL raw "$plist" 2>/dev/null || true)"
  key="$(plutil -extract SUPublicEDKey raw "$plist" 2>/dev/null || true)"
  ats="$(plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw "$plist" 2>/dev/null || true)"
  if [ "$plist" = Scripts/Info.plist ]; then
    [[ "$feed" == https://* ]] && pass "Update feed is HTTPS" "$feed" || fail "Update feed isn't HTTPS" "$feed"
    [ -n "$key" ] && pass "Updates are signature-checked (SUPublicEDKey set)" || fail "No SUPublicEDKey — updates wouldn't be verified"
  fi
  [ "$ats" != "true" ] && pass "No arbitrary-loads exception in $(basename "$plist")" || fail "NSAllowsArbitraryLoads is on in $plist"
done
if [ -f Package.resolved ] && python3 -c '
import json,sys
pins=json.load(open("Package.resolved"))["pins"]
bad=[p["identity"] for p in pins if not p.get("state",{}).get("revision") or not p["location"].startswith("https://")]
sys.exit(1 if bad else 0)'; then
  pass "Dependencies pinned to exact revisions over HTTPS" "$(python3 -c 'import json;print(", ".join(p["identity"]+" "+p["state"].get("version","") for p in json.load(open("Package.resolved"))["pins"]))')"
else
  fail "Dependencies not all pinned to exact revisions over HTTPS"
fi

# ---------------------------------------------------------------- bundle
section "Signed test bundle"
if limited 900 testapp bash Scripts/build-test-app.sh && grep -q "Done:" "$WORK/testapp.log"; then
  pass "Built and installed EnvyTest.app"
  APP=/Applications/EnvyTest.app
  codesign --verify --deep --strict "$APP" > "$WORK/verify.log" 2>&1 && pass "Code signature verifies (deep, strict)" || fail "Code signature doesn't verify" "$(head -2 "$WORK/verify.log" | tr '\n' ' ')"
  # Captured first: under pipefail, grep -q exiting early would fail the pipe.
  SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
  [[ "$SIGNATURE" == *"flags=0x"*"(runtime)"* ]] && pass "Hardened runtime on" || fail "Hardened runtime off"
  [[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] && pass "Signed with Developer ID" "$(echo "$SIGNATURE" | grep -m1 'Authority=' | cut -d= -f2)" || fail "Not signed with a Developer ID"
  ENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null | grep -oE 'com\.apple\.security\.(get-task-allow|cs\.disable-library-validation|cs\.allow-unsigned-executable-memory|cs\.allow-jit|cs\.allow-dyld-environment-variables|cs\.disable-executable-page-protection)' || true)"
  [ -z "$ENTS" ] && pass "No debugging or code-injection entitlements" || fail "Risky entitlements present" "$ENTS"
else
  fail "Build EnvyTest.app" "$(tail -3 "$WORK/testapp.log" | tr '\n' ' ')"
  QUICK=1
fi

# ---------------------------------------------------------------- live
if [ "$QUICK" = 0 ]; then
  section "Live UI suite (hands off the Mac — ~10 min)"
  if [ ! -d "$SOURCE_VAULT" ]; then
    fail "Test vault" "$SOURCE_VAULT not found (set ENVY_PREFLIGHT_VAULT)"
  else
    for key in indexPath menuBarTaskPin taskShowCompleted appVisibility lastSeenWhatsNewVersion; do
      defaults read "$TEST_DOMAIN" "$key" > "$WORK/pref.$key" 2>/dev/null || rm -f "$WORK/pref.$key"
    done
    SAVED_PREFS=1
    rm -rf "$CLONE" && cp -cR "$SOURCE_VAULT" "$CLONE"
    defaults write "$TEST_DOMAIN" indexPath "$CLONE"
    defaults write "$TEST_DOMAIN" taskShowCompleted -bool true
    defaults write "$TEST_DOMAIN" appVisibility both
    # What's New would open over the first launch of a new build; it's been "seen".
    defaults write "$TEST_DOMAIN" lastSeenWhatsNewVersion "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/EnvyTest.app/Contents/Info.plist)"
    ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i envytest > "$WORK/crashes.before" || true
    if limited 300 harness-build swiftc -O Scripts/preflight/harness/AX.swift Scripts/preflight/harness/Harness.swift \
         Scripts/preflight/harness/Tests.swift Scripts/preflight/harness/main.swift -o "$WORK/preflight-ui"; then
      perl -e 'alarm shift; exec @ARGV' 1800 "$WORK/preflight-ui" "$CLONE" "$WORK/ui-report.md" "$WORK" | tee "$WORK/ui.log"
      UI_STATUS=${PIPESTATUS[0]}
      while IFS= read -r line; do
        case "$line" in
          "- PASS "*) PASSED+=("UI: ${line#- PASS }") ;;
          "- FAIL "*) FAILED+=("UI: ${line#- FAIL }") ;;
        esac
      done < "$WORK/ui-report.md"
      [ "$UI_STATUS" -gt 1 ] && FAILED+=("UI suite stopped early (exit $UI_STATUS) — see the log")
    else
      fail "Build the UI harness" "$(grep -m3 error: "$WORK/harness-build.log" | tr '\n' ' ')"
    fi
    section "Crashes"
    NEW_CRASHES="$(ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i envytest | grep -vxF -f "$WORK/crashes.before" || true)"
    [ -z "$NEW_CRASHES" ] && pass "No crash reports from the run" || fail "EnvyTest crashed during the run" "$NEW_CRASHES"
  fi
fi

# ---------------------------------------------------------------- report
restore
{
  echo "# Envy preflight — $(date)"
  echo
  echo "Commit $(git rev-parse --short HEAD) on $(git branch --show-current)"
  echo
  echo "## Failures (${#FAILED[@]})"
  for f in "${FAILED[@]+"${FAILED[@]}"}"; do echo "- $f"; done
  echo
  echo "## Passed (${#PASSED[@]})"
  for p in "${PASSED[@]+"${PASSED[@]}"}"; do echo "- $p"; done
  [ -f "$WORK/ui-report.md" ] && { echo; echo "---"; echo; cat "$WORK/ui-report.md"; }
} > "$REPORT"

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "PREFLIGHT PASSED — ${#PASSED[@]} checks. Report: dist/preflight-report.md"
  exit 0
else
  echo "PREFLIGHT FAILED — ${#FAILED[@]} of $(( ${#FAILED[@]} + ${#PASSED[@]} )) checks:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "Report: dist/preflight-report.md   Logs: $WORK"
  exit 1
fi

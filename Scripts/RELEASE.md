# Release procedure — "push to prod"

What Claude executes when Skyler says **"push to prod"**. Two tracks: pick by
whether the app version changes.

- **Track A — website only.** Copy edits, CSS fixes, docs wording. No new
  build, no version bump, no GitHub release. Skip to §A.
- **Track B — full release.** New app version reaching users. §0 through §7.

Ask which track it is only if it is genuinely ambiguous. A changed file under
`Sources/` means Track B; changes confined to `~/Documents/Claude/EnvyWebsite`
mean Track A.

## The two gates

These are not optional, and neither is skippable by inferring approval from the
original "push to prod".

1. **Uncommitted work halts the run.** Show the diff, stop, wait. Never
   `git checkout`, `git stash`, or overwrite anything without showing it first.
2. **Confirm immediately before the irreversible step.** Print exactly what will
   go live, then wait for an explicit yes. Deploying the appcast starts pushing
   an update to every installed copy of Envy. There is no undo.

Never add a `Co-Authored-By:` trailer or any generated-with footer to a commit.

## Ground truth

| Thing | Path |
|---|---|
| App repo | `/Users/skuthus/Documents/Claude/Envy` → `skuthus/Envy` (public) |
| Site repo | `/Users/skuthus/Documents/Claude/EnvyWebsite` → `skuthus/Envy-website` (private) |
| Netlify publish root | `/Users/skuthus/Documents/Claude/EnvyWebsite` (project `envynote`) |
| Drafts, never shipped | `/Users/skuthus/Documents/Claude/EnvyWebsite-drafts` |
| Version of record | `Scripts/Info.plist` → `CFBundleShortVersionString` + `CFBundleVersion` |
| Sparkle feed | `assets/updates/appcast.xml`, served at `https://envynote.app/assets/updates/appcast.xml` |
| Download button target | `assets/downloads/Envy.dmg` |

Netlify is **not** connected to the git repo: `build_settings.repo_url` is
`null`, there is no build command. `git push` does not deploy anything.
Publishing is `netlify deploy --prod`, which uploads the publish root wholesale.
Anything sitting in that folder goes live, which is why drafts live outside it.

`make-dmg.sh` resolves the site as `$ROOT_DIR/../EnvyWebsite`. Keep the two repos
as siblings under `~/Documents/Claude/` or the appcast step silently skips.

---

## §A — Track A: website only

1. `git -C ~/Documents/Claude/EnvyWebsite status --short`. Anything unexpected,
   stop and show it.
2. Confirm no drafts crept into the publish root:
   `ls ~/Documents/Claude/EnvyWebsite/*.html` and compare against what is live.
   A file present locally and 404 on prod is a draft that is about to ship.
3. Diff local against production for every page being changed:
   `curl -s https://envynote.app/<page> | diff - <page>`. This catches edits made
   directly on the folder that were never deployed.
4. **Gate 2.** Print the file list and the diff summary. Wait for yes.
5. `cd ~/Documents/Claude/EnvyWebsite && netlify deploy --prod`
6. Verify live: re-`curl` each changed page and confirm the change is present.
7. Commit and push the site repo. The commit is for history, not for deploying.

---

## §0 — Track B: preflight (read-only, abort on any failure)

Nothing here changes state. Run it all, report failures together rather than
stopping at the first.

```bash
# identity and credentials
security find-identity -v -p codesigning | grep "Developer ID Application"
xcrun notarytool history --keychain-profile envy-notary 2>&1 | head -3
netlify status                       # expect: skuthus, project envynote
gh release list --repo skuthus/Envy --limit 1

# tooling
ls .build/artifacts/sparkle/Sparkle/bin/generate_appcast

# state
git -C ~/Documents/Claude/Envy status --short
git -C ~/Documents/Claude/EnvyWebsite status --short
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Scripts/Info.plist
```

Notes on expected results:

- `gh api user` returns **HTTP 503** through this sandbox, and so does a raw
  `curl` to `/user` with the same token. Repo-scoped endpoints and `gh release`
  work fine. Do not read that 503 as broken auth.
- Missing `generate_appcast` just means Sparkle has not been fetched yet; a
  `swift build -c release --product Envy` restores it. Do not proceed to §3
  without it, or the appcast step skips and users never see the release.
- **Gate 1** applies here. Uncommitted work in either repo halts the run.

Confirm the new version is greater than the current one, and get the release
headline (GitHub release titles read `Envy 1.10.0: Turn Off What You Don't Use`).

## §1 — Bump the version

Both keys in `Scripts/Info.plist`, kept identical:

```
CFBundleShortVersionString   X.Y.Z
CFBundleVersion              X.Y.Z
```

`Info-Test.plist` is the EnvyTest bundle and carries its own identity. Leave it
unless the change is specifically about the test build.

## §2 — Verify the build, then stop

Speed is the priority for this codebase, so anything touching the editor or
search needs a latency check, not just a correctness check.

```bash
swift build -c release
swift run -c release EnvySelfCheck      # EnvyCore only — does NOT cover Envy
Scripts/build-test-app.sh               # -> dist/EnvyTest.app
```

`EnvySelfCheck` depends only on `EnvyCore`. `MarkdownStyler`, `MarkdownTextView`,
and everything else in the `Envy` executable target are outside its reach. Say so
plainly rather than implying the checks cover the change.

**Stop here.** Hand over `dist/EnvyTest.app` and wait for Skyler to confirm it
works. This gate exists because it is the only real coverage the app target gets.

## §3 — Build the release artifacts

```bash
Scripts/make-dmg.sh
```

One command, and it does all of this:

1. `build-app.sh` — release binary, regenerates the icon at every size, embeds
   and inside-out signs `Sparkle.framework`, Developer ID signs the bundle
2. `notarize.sh` — submits to Apple, waits, staples the ticket, `spctl` verifies
3. Packages `dist/Envy.dmg`
4. Copies it to `EnvyWebsite/assets/updates/Envy-X.Y.Z.dmg`
5. Runs `generate_appcast --download-url-prefix https://envynote.app/assets/updates/`,
   which rewrites `appcast.xml`, signs each enclosure with the EdDSA key, and
   builds delta updates against every prior release

Assembly and signing happen under `/tmp` on purpose. This project folder is
inside iCloud's Desktop & Documents sync, and `bird`/`fileproviderd` re-tag
bundle directories while they sync, which makes `codesign` fail with "resource
fork, Finder information, or similar detritus not allowed". Do not move the work
back into the project folder to make a path look tidier.

Verify before moving on:

```bash
spctl -a -vv dist/Envy.app                              # accepted, Developer ID
head -20 ~/Documents/Claude/EnvyWebsite/assets/updates/appcast.xml
```

The top `<item>` must be the new version, its `<enclosure>` must carry a
`sparkle:edSignature`, and `length` must equal the real byte size of the DMG.

## §4 — Update the website

`make-dmg.sh` handles `assets/updates/` and nothing else. The download button is
a separate file and a manual copy:

```bash
cp dist/Envy.dmg ~/Documents/Claude/EnvyWebsite/assets/downloads/Envy.dmg
```

Forget this and the site keeps serving the previous release from its main
download button while Sparkle correctly offers the new one to existing users.

Then get the real size and update every hardcoded string. `index.html` carries
the version and size in several places, and none of them are generated:

| Location | Contents |
|---|---|
| `<meta name="description">` | size in MB |
| JSON-LD `"softwareVersion"` | X.Y.Z |
| `#e-ver` | `X.Y.Z &middot; macOS` |
| `#e-dl-meta` | `<size> MB &middot; macOS 14+` |
| spec table `Size` row | size in MB |
| `#e-cta-meta` | `<size> MB &middot; macOS 14+` |
| `.e-fineprint` | size in MB |

The `#e-ver` / `#e-dl-meta` / `#e-cta-meta` IDs are also rewritten at runtime by
the Windows-detection script near the bottom of `index.html`. That path swaps in
Beta/Windows copy and does not read the appcast, so the macOS values must be
correct in the HTML itself.

Also:

- **`changelog.html`** — new `<section class="docs-section" id="vX-Y-Z">` at the
  top of `.docs-content`, matching the existing shape: `<h2>` with the version
  and a styled `&middot; Month D, YYYY`, a one-line summary `<p>`, headline items
  as `<div class="docs-callout">`, smaller items as `<li><strong>…</strong></li>`.
- **`CHANGELOG.md`** in the app repo — the same content as `## X.Y.Z — Month D, YYYY`.
  Keep the two in sync; the file says so in its own header.
- **`docs.html`** — update any feature the release changes. This is the step most
  likely to be skipped and most likely to be noticed by users.
- **`sitemap.xml`** — `lastmod` for pages that actually changed.

## §5 — Gate 2

Print, and wait for an explicit yes:

- version, old → new
- DMG byte size and its SHA
- every website file being changed, with a diff summary
- the full contents of the publish root, flagging anything not currently live
- the GitHub release title and the tag about to be created

## §6 — Ship (irreversible, in this order)

```bash
cd ~/Documents/Claude/EnvyWebsite && netlify deploy --prod
```

This is the moment the release reaches users: the appcast goes live and installed
copies start seeing the update. Verify immediately, before anything else:

```bash
curl -s https://envynote.app/assets/updates/appcast.xml | head -20
curl -sI https://envynote.app/assets/downloads/Envy.dmg | head -3
curl -sI https://envynote.app/assets/updates/Envy-X.Y.Z.dmg | head -3
curl -s https://envynote.app/ | grep -o 'X\.Y\.Z'
```

Served `Content-Length` must match the appcast's `length` attribute exactly. A
mismatch means Sparkle will reject the update, and that is worth catching in the
first minute rather than from a bug report.

Then the repos:

```bash
git -C ~/Documents/Claude/EnvyWebsite add -A && git -C ~/Documents/Claude/EnvyWebsite commit -m "…" && git -C ~/Documents/Claude/EnvyWebsite push

cd ~/Documents/Claude/Envy
git add -A && git commit -m "Release X.Y.Z"
git tag vX.Y.Z
git push && git push --tags

gh release create vX.Y.Z --repo skuthus/Envy \
  --title "Envy X.Y.Z: <headline>" \
  --notes-file <changelog-section> \
  dist/Envy.dmg
```

Both repos commit straight to `main`. Release assets are named `Envy.dmg`, and
tags are `vX.Y.Z`.

## §7 — Post-deploy check

- `gh release view vX.Y.Z --repo skuthus/Envy` — asset attached, tag correct
- Both repos level with their remotes, working trees clean
- `https://envynote.app` shows the new version
- Best real test: an installed older copy sees the update via
  Envy menu → "Check for Updates…"

Report what actually happened, including anything skipped. Do not report success
for a step that was not run.

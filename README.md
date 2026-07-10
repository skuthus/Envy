# Envy

A fast, flat-file note-taking app for macOS. One search box, instant results, and notes stored as plain `.md` files you can grep, sync, or edit with anything else you like.

## Features

- **Instant search-driven workflow** — type to filter notes as you type; press Return to open the top match or create a new note from your search text if nothing matches.
- **Flat-file storage** — every note is a plain `.md` file on disk. No database, no proprietary format.
- **Live markdown styling** — headings, bold, italic, strikethrough, code, lists, task checkboxes, footnotes, and blockquotes all render directly in the editor as you type, no separate preview mode. A plain-text mode toggle shows the raw markdown instead when you want it.
- **Wiki-links** — link notes with `[[Note Title]]`; ⌘-click to follow a link, which creates the target note on the spot if it doesn't exist yet.
- **Tags** — write `#tag` anywhere in a note and Envy picks it up automatically, rendered bold with a tinted background. Search `tag:name` to filter by it, including partial matches.
- **Date search** — `date:today`, `date:week`, `date:month`, or an exact date in whatever format you'd naturally type it.
- **Scattered multi-word search** — search several words at once and Envy finds notes containing all of them anywhere in the text, not just as one phrase.
- **Pinning** — pin a note to keep it at the top of the list regardless of sort. A search that doesn't match a pinned note still hides it, same as any other note.
- **Live external-edit detection** — editing a note in another app while it's open in Envy updates it automatically, with the changed portion briefly flashing so you don't miss it.
- **Multiple note folders** — merge notes from more than one folder into a single searchable list, with per-folder cycling.
- **Undo a delete** — deleted notes go to Trash, not gone for good, and can be restored right back where they were.
- **Fully remappable shortcuts** — every keyboard shortcut in the app can be customized in Settings → Shortcuts.
- **Global hotkey** — `⌥⌘↩` shows or hides Envy from anywhere, even when another app is focused.
- **Themes & appearance** — customizable fonts and colors (including per-syntax-element colors), adjustable window blur, note list density, and independent System/Light/Dark mode.
- **Open at login** — optional toggle to launch Envy automatically when you log in.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (Swift 6 toolchain) — a full Xcode install is not required

## Building & Running

Envy is a Swift Package Manager project; there is no Xcode project file.

```sh
swift build
swift run Envy
```

### Packaging as a `.app`

```sh
Scripts/build-app.sh
```

Builds a release binary, generates the app icon, assembles `dist/Envy.app`, and signs it with a Developer ID certificate if one is installed (falls back to ad-hoc signing otherwise).

### Signing, notarizing, and distributing

```sh
Scripts/notarize.sh   # submits dist/Envy.app to Apple and staples the ticket
Scripts/make-zip.sh   # build-app.sh + notarize.sh, then zips dist/Envy.app
Scripts/make-dmg.sh   # build-app.sh + notarize.sh, then packages dist/Envy.dmg
```

`make-dmg.sh` is the one actually used for distribution — it produces a normal macOS disk image with a shortcut to `/Applications`, ready to hand to someone else. Requires a Developer ID Application certificate and a stored `notarytool` keychain profile (see `Scripts/notarize.sh`).

## Notes Storage

By default, notes live in `~/Documents/Envy`. This folder (and any additional folders you configure in Settings → General) is created automatically on first launch, along with a welcome note covering the basics.

## Keyboard Shortcuts

Every shortcut below can be remapped in Settings → Shortcuts.

| Keys | Action |
|---|---|
| `⌥⌘↩` | Show or hide Envy — works from any app |
| `⌘N` | New note |
| `⌘⌫` | Delete the selected note |
| `⌘⇧⌫` | Restore the most recently deleted note(s) |
| `⌥⌘P` | Pin or unpin the selected note |
| `⌘`-click a `[[link]]` | Open the linked note (creates it if it doesn't exist) |
| `↑` / `↓` | Move the highlighted note while searching |
| `↩` | Open the highlighted note, or create one from your search text |
| `⌘↩` | Center the window on screen |
| `⌘⇧L` | Toggle horizontal / vertical layout |
| `⌘⇧P` | Toggle plain-text mode |
| `⌥→` / `⌥←` | Show only the next / previous folder's notes |
| `⌥↓` / `⌥↑` | Move focus between search, list, and editor |
| `⌘B` / `⌘I` | Bold / italicize the selected text |
| `⌘+` / `⌘-` / `⌘0` | Zoom the note text in, out, or reset it |
| `⌘,` | Settings |

## Project Structure

- `Sources/VelocityCore` — the note model and `NoteStore` data layer (platform-agnostic)
- `Sources/Envy` — the SwiftUI app
- `Sources/IconGenerator` — standalone tool that renders the app icon
- `Sources/VelocitySelfCheck` — a manual assertion-based check suite (used in place of Swift Testing, which doesn't run reliably without a full Xcode install)
- `Scripts/build-app.sh` — packages the release `.app` bundle
- `Scripts/build-test-app.sh` — packages a separately bundle-ID'd `EnvyTest.app` for local testing, isolated from the real app's preferences
- `Scripts/notarize.sh` / `Scripts/make-zip.sh` / `Scripts/make-dmg.sh` — signing, notarization, and packaging for distribution

## License

Proprietary. All rights reserved. See [LICENSE](LICENSE).

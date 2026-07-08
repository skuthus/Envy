# Envy

A fast, flat-file note-taking app for macOS, inspired by [Notational Velocity](https://notational.net/). One search box, instant results, and notes stored as plain `.md` files you can grep, sync, or edit with anything else you like.

## Features

- **Instant search-driven workflow** — type to filter notes as you type; press Return to open the top match or create a new note from your search text if nothing matches.
- **Flat-file storage** — every note is a plain `.md` file on disk. No database, no proprietary format.
- **Live markdown styling** — headings, bold, italic, and inline code render directly in the editor as you type, no separate preview mode.
- **Wiki-links** — link notes with `[[Note Title]]`; ⌘-click to follow a link, which creates the target note on the spot if it doesn't exist yet.
- **Multiple note folders** — merge notes from more than one folder into a single searchable list.
- **Global hotkey** — `⌥⌘↩` shows or hides Envy from anywhere, even when another app is focused.
- **Themes & appearance** — customizable fonts and colors, adjustable window blur, and independent System/Light/Dark mode.
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

This builds a release binary, generates the app icon, assembles `dist/Envy.app`, and ad-hoc code-signs it. Run it locally with `open dist/Envy.app`, or install it with:

```sh
cp -R dist/Envy.app /Applications/
```

## Gatekeeper Warning

Releases are ad-hoc signed, not notarized by Apple. On first launch, macOS will likely say Envy "can't be opened because it is from an unidentified developer" (or "is damaged and can't be opened"). To open it anyway:

1. Right-click (or Control-click) `Envy.app` and choose **Open**, then click **Open** again in the dialog.
2. If that doesn't work, run `xattr -cr /path/to/Envy.app` in Terminal.

You only need to do this once per copy of the app.

## Notes Storage

By default, notes live in `~/Documents/Envy`. This folder (and any additional folders you configure in Settings → General) is created automatically on first launch, along with a welcome note covering the basics.

## Keyboard Shortcuts

| Keys | Action |
|---|---|
| `⌥⌘↩` | Show or hide Envy — works from any app |
| `⌘N` | New note |
| `⌘⌫` | Delete the selected note |
| `⌘`-click a `[[link]]` | Open the linked note (creates it if it doesn't exist) |
| `↑` / `↓` | Move the highlighted note while searching |
| `↩` | Open the highlighted note, or create one from your search text |
| `⌘↩` | Center the window on screen |
| `⌘⇧L` | Toggle horizontal / vertical layout |
| `⌘,` | Settings |

## Project Structure

- `Sources/VelocityCore` — the note model and `NoteStore` data layer (platform-agnostic)
- `Sources/Envy` — the SwiftUI app
- `Sources/IconGenerator` — standalone tool that renders the app icon
- `Sources/VelocitySelfCheck` — a manual assertion-based check suite (used in place of Swift Testing, which doesn't run reliably without a full Xcode install)
- `Scripts/build-app.sh` — packages the release `.app` bundle

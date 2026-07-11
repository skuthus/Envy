# Envy

A flat-file, frictionless note-taking application for macOS. One search box, instant results, and notes stored as plain `.md` files you can grep, sync, or edit with anything else you like.

Built by [Skyler Schoos](https://github.com/skuthus), with [Claude Code](https://claude.com/claude-code).

## Download

Get the latest signed, notarized build at **[envynote.app](https://envynote.app)** — click "Download for Mac" for a ready-to-run `.dmg`. Envy updates itself after that (Envy menu → "Check for Updates…"), so there's no need to come back here for new versions.

This repository is published for source transparency. The code is proprietary (see [License](#license)) — Envy isn't intended to be built or packaged by anyone but its maintainer, so there are deliberately no build instructions here.

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

- `Sources/EnvyCore` — the note model and `NoteStore` data layer (platform-agnostic)
- `Sources/Envy` — the SwiftUI app
- `Sources/IconGenerator` — standalone tool that renders the app icon
- `Sources/VelocitySelfCheck` — a manual assertion-based check suite (used in place of Swift Testing, which doesn't run reliably without a full Xcode install)

## License

Proprietary. All rights reserved. See [LICENSE](LICENSE).

## A Note on AI Usage

*Envy is built with help from Claude Code. Architecture, feature decisions, and design direction are the maintainer's; a large share of the implementation, debugging, and this documentation were done in collaboration with Claude.*

Guys, I am not a programmer or engineer by trade so this is my only option. I just wanna make cool stuff that I use every day. If you really don't like AI usage, don't use my apps. I promise that I work really hard to make them great, anyway.

# Changelog

Also published at [envynote.app/changelog.html](https://envynote.app/changelog.html).

## 1.0.1 — July 10, 2026

**The big one: Envy can now update itself.** New versions install right from the app — "Check for Updates…" in the Envy menu — no more downloading a fresh copy from the site by hand.

- Markdown pairs now auto-close as you type: `[[`, `**`, `*`, `` ` ``, `~~`, and the `(url)` half of a `[text](url)` link all get their closing half inserted automatically, with typing through an existing closer instead of duplicating it.
- Typing inside an open `[[` now offers a live inline suggestion for a matching existing note, ranked by which one you edited most recently — Tab accepts it, right-arrow dismisses it.
- Backlinks: the footer now shows a count of notes linking to the one you're viewing, expandable into a clickable list that opens upward from the footer. Toggle with ⌘⇧B (remappable in Settings → Shortcuts) or the new "Show backlinks in footer" setting.
- Fixed Envy silently reappearing after being hidden, on multi-monitor setups where each display runs its own Space. Hiding now orders the window out directly instead of using a full "Hide Application," which was tying into Mission Control's per-Space "last active app" bookkeeping.

## 1.0.0 — July 10, 2026

Initial public release.

- Instant search-as-you-type, with `tag:` and `date:` operators and scattered multi-word matching.
- Live markdown rendering: headings, bold, italic, strikethrough, code, lists, task checkboxes, footnotes, and blockquotes, with no separate preview mode.
- `#tag` hashtags with dedicated bold, tinted-background styling and `tag:` search, including partial matches.
- `[[wiki-links]]` between notes, creating the target note on the spot if it doesn't exist yet.
- Note pinning, keeping a note at the top of the list regardless of sort.
- Live detection of a note being edited by another app while open in Envy, with the changed portion briefly flashing.
- Multiple notes folders merged into a single searchable list, with per-folder cycling.
- Every keyboard shortcut fully remappable in Settings.
- A global summon hotkey and menu bar access from anywhere.
- Customizable fonts, colors (including per-syntax-element colors), window blur, and layout.
- Signed and notarized with a Developer ID certificate.

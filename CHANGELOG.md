# Changelog

Also published at [envynote.app/changelog.html](https://envynote.app/changelog.html).

## 1.1.1 — unreleased

**A pinnable menu bar note.** Right-click the eyecon for "Pin to Menu Bar" on any note (or "New Pinned Note" / "New Pinned Note from Template" to create one on the spot), then set Settings → General → "Clicking the menu bar icon" to "Show Pinned Note" — a click now shows that note in a small, resizable, editable popup instead of opening the full app. Good for a running to-do list or a reminder you want one click away.

- The popup is a real, user-resizable window (remembers its size across launches), with its own pin button to keep it open and floating above other windows instead of closing on the next outside click, and its own font zoom (⌘+/⌘-/⌘0) independent of the main editor's.
- Its title is editable right there in the popup, same rename behavior (and collision handling) as renaming any other note.
- Settings → General has a new "Show tags in title bar" toggle (off by default) — a note's `#tags` show as chips next to its title. Click one to search `tag:whatever` without losing your place — the note you clicked from stays open.
- Task-list checkboxes no longer need a leading `-` — `[ ]`/`[x]` at the start of any line is now a live, clickable checkbox on its own, not just as part of a `- [ ]` list item. (`- [ ]` still works exactly as before, and still gets the bulleted-list treatment.)
- `[ ]`/`[x]` typed inside inline code (`` `[ ]` ``) stays literal text instead of turning into a checkbox, matching how every other markdown marker already behaves inside a code span.
- Fixed checkboxes occasionally rendering misaligned until you clicked into the editor — the checkbox glyph's position is now computed after forcing layout to fully complete, instead of trusting whatever the layout manager had already lazily cached, which could still be based on a provisional (pre-final-layout) width right after opening a note.

## 1.1.0 — July 12, 2026

**A major performance upgrade.** Envy now stays fast with thousands of notes — search, scrolling, and switching between notes were all rebuilt to scale, tested up to 15,000 notes in one folder.

- Search typing was the big one: results are now computed on a short debounce instead of on every keystroke, and the results list itself is cached instead of being recalculated on every unrelated screen update (it was previously re-running a full search on every re-render, not just when you actually typed). Combined with switching to a much faster substring search and caching each note's searchable text instead of recomputing it every time, typing in the search box with 10,000+ notes went from noticeably laggy to instant.
- Switching between notes is faster too — the backlinks count and list had the same "recomputed too often" problem search did, fixed the same way.
- Opening the app (or reloading after any change) is faster — note files are now read in parallel instead of one at a time, and tag/wiki-link parsing per note is now done once and cached instead of every time it's needed.
- Fixed the "Loading notes…" indicator flashing repeatedly during a large import or external sync — Envy was treating every filesystem notification as a reason to rescan, including ones from Spotlight indexing new files in the background. It now only reacts to notifications that mean a note's content actually changed, and the indicator itself moved into the footer bar (next to the backlinks toggle) so it no longer shifts the note list around when it does appear.
- Settings → General now has "Show Envy in": Dock Only, Menu Bar Only, or Dock and Menu Bar (default, unchanged from before). Menu Bar Only still gets a full Dock icon and menu bar whenever a window is actually open — dropping back to menu-bar-only once every window closes — so everything that only lives in the menu (Font, Navigate, Folders, Check for Updates, and more) stays reachable.
- Fixed the search bar rendering much too dark in Light mode, and the same underlying color bug in inline code's (backtick-wrapped text) background. The search bar also picked up a more visible resting-state outline out of this.
- Fixed task-list checkboxes becoming unreliable — intermittently failing to render, then flickering — after being toggled a few times. Checkboxes now draw as a small overlay instead of substituting a glyph onto the underlying text, which was never fully reliable in AppKit.
- Fixed list bullets and unchecked checkboxes rendering invisible (white-on-white) in Light mode — the same underlying color-resolution bug as the search bar and inline code fixes above, just not caught until the checkbox rendering rework above surfaced it.

## 1.0.3 — July 11, 2026

**Templates.** Type `template:` in the search box to browse, create, or use a template — same "type and hit Return" feel as a regular search. Templates live as plain `.md` files in a `Templates` folder, so making one is as simple as writing a note.

- `template:daily` searches by name; Return uses the top (or arrow-key-highlighted) match, or creates a new template if nothing matches yet.
- `{{date}}`, `{{time}}`, and `{{title}}` in a template's title or body are filled in when a note is created from it — a template literally named "Daily Notes {{date}}" produces a note titled with today's date automatically. `{{date}}`'s format is a free-text pattern in Settings → General → Templates (e.g. `MMMM d, yyyy` or `yyyy-MM-dd`), with a live preview.
- Right-click a template to edit it directly in Envy's own live-markdown editor, reveal it in Finder, or delete it (recoverable from Trash).
- Right-click any note to turn it into a template, and right-click a template to move it back to your notes — restores to the folder it came from, or the default folder if that one's gone.
- Settings → General → Templates lets you choose one shared Templates folder or a separate one per notes folder.
- Three starter templates (Daily Notes, To-Do List, Study Notes) are created automatically the first time you use the feature.
- The menu bar "eyecon" now opens when Envy's window is showing and closes when it's hidden, with a green pupil matching the app's own icon.
- Added an easter egg — blink and you'll miss it!
- Fixed Envy sometimes failing to come to the front when summoned while using [AeroSpace](https://github.com/nikitabobko/AeroSpace) (by [nikitabobko](https://github.com/nikitabobko)) — AeroSpace hides windows belonging to a workspace you're not currently on, and Envy's global hotkey bypasses AeroSpace entirely, so it had no way to know a summon just happened. Envy now talks to AeroSpace's own socket protocol directly (if it's running) to move its window onto your current workspace right before showing it.
- Fixed a checked task-list item (`- [x]`) silently failing to render as a checkbox — showing the raw `- [x]` text instead — whenever its text also contained other inline markdown, like `` `code` `` or **bold**.

## 1.0.2 — July 10, 2026

- Summoning Envy now keeps focus wherever it was before you hid the app, instead of always jumping to the search box. Toggle "Keep focus where it was when summoned" in Settings → General to go back to the old always-search behavior.

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

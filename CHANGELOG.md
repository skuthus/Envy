# Changelog

Also published at [envynote.app/changelog.html](https://envynote.app/changelog.html).

## 1.1.8 — unreleased

- Fixed the pinned note popup's title clipping the last character at rest, even on titles well under the 25-character truncation limit — the label's fixed width was measured with a font approximation that occasionally landed a hair narrower than what actually got rendered.

## 1.1.7 — July 15, 2026

**Lagless at any library size.** The whole search pipeline (matching, ranking, sorting, pinning) now runs off the main thread over a snapshot of your notes — typing in the OmniBar stays instant even with tens of thousands of notes. First-character searches, previously the worst case (one letter matches nearly everything), no longer block anything.

- Typing in very large notes is faster too: the per-keystroke markdown styling pass now only re-processes the region around your edit on big documents (full styling still applies when searching or when the note contains fenced code blocks, where matches can be document-wide), and checkbox layout work is skipped entirely for notes without checkboxes.
- Fixed a fast backspace right after typing — or a quick re-click of a checkbox — occasionally restoring the just-deleted text: the editor's own debounced save could echo back through the external-file-change detector and be mistaken for another app editing the note.
- Every color swatch in Settings → Appearance now has a reset-to-default button, and the Focus Highlight color moved in with the rest of the Focus Highlight settings instead of living two sections away.
- Theme colors are now uniformly "system until you customize them" under the hood, fixing a class of appearance-tracking edge cases (colors freezing at whatever Light/Dark resolved to at launch).
- Backlink computation and the wiki-link autocomplete index also moved off the main thread — both could previously cause brief hitches on large libraries.

## 1.1.6 — July 14, 2026

**A full theme system.** Settings → Theme now has a gallery of ready-made looks — Tokyo Night, Dracula, Monokai, both Solarized themes, and two new Velocity Light/Dark themes modeled on the original Notational Velocity — plus your own saved themes, with save, duplicate, rename, delete, import, and export.

- Every color is always editable, right down to the note editor's own title bar, tag colors, and text-selection highlight — no more toggling "Use Custom Theme" first.
- Search-match highlighting, tag chips, and selected text now automatically flip to black or white when the theme's own color choice would otherwise be unreadable against its background.
- Fixed tag text rendering in the wrong color: the legibility check above was reading a tag's translucent background as if it were fully opaque, which could wrongly trigger that black/white flip on perfectly readable tag colors.
- Fixed text selection (dragging to select text) losing its highlight entirely in some cases — the selection color was being frozen at whatever the system happened to resolve at app launch instead of tracking it live.

## 1.1.5 — July 13, 2026

- Fixed hiding Envy (hotkey, menu bar icon, or the red button) sometimes snapping an unrelated window — occasionally a minimized one — to the foreground while AeroSpace is running. Turned out not to be AeroSpace-specific at all: ordering out Envy's only visible window makes AppKit auto-activate the "next" window in the global window-server order, and AeroSpace keeps off-workspace windows parked in that order even though they're off-screen, so AppKit's pick routinely landed on a window from a different workspace. Fixed by capturing whichever app was frontmost right before summoning Envy and explicitly reactivating it after hiding — a plain macOS app activation, not routed through AeroSpace at all, so it can't un-minimize anything and helps even without a window manager running.

## 1.1.4 — July 13, 2026

- Hotfix for AeroSpace interactions: removed the "restore previous focus on hide" behavior added in 1.1.2. Re-focusing a window in AeroSpace un-minimizes it, and if the captured ID went stale, hiding Envy could un-minimize and raise a completely unrelated window — jarring and unrelated to anything you were doing. No longer needed: with Envy set to always float (via an on-window-detected rule in AeroSpace's own config), the accordion-mode bug this was originally working around shouldn't occur in the first place.

## 1.1.3 — July 13, 2026

- Fixed a serious delay between summoning Envy (hotkey or menu bar icon) and the window actually appearing — a regression from 1.1.2's AeroSpace fixes, which added several socket round trips directly on the main thread before the window could show. That work now happens in the background, after the window is already on screen.

## 1.1.2 — July 13, 2026

- The note-preview snippet (Settings → General → "Show note preview") now shows inline next to the title instead of on its own line below it.
- The pinned note popup's title now truncates to 25 characters at rest, and scrolls across to reveal the rest on hover — click it to rename, same as before.
- Fixed summoning or hiding Envy while [AeroSpace](https://github.com/nikitabobko/AeroSpace) is running in accordion layout mode sometimes bumping an unrelated app's window to the front instead of (or alongside) Envy.
- Fixed blockquotes (`>`) rendering too faint to read comfortably — quoted text was using the same very low-contrast color reserved for dimming collapsed markdown markers, not actual content.
- Added a dedicated global hotkey (⌥⌘↓ by default, editable in Settings → Shortcuts) to show or hide your pinned note from any app, independent of what "Clicking the menu bar icon" is set to.
- Fixed the pinned note popup always opening at the top of the note — it now restores your cursor position (and scrolls it into view) from wherever you last were, even though it still reloads the note fresh from disk on every open.
- Replaced the New Note shortcut with Jump to OmniBar (⌘L by default) — the search bar's own "type a name, hit ↩" already creates a note, so ⌘N was redundant. The new shortcut jumps focus to the search bar from anywhere, including mid-edit in a note. New Note is still available from the File menu and the menu bar icon's right-click menu, just without its own keyboard shortcut.

## 1.1.1 — July 12, 2026

**A pinnable menu bar note.** Right-click the eyecon for "Pin to Menu Bar" on any note (or "New Pinned Note" / "New Pinned Note from Template" to create one on the spot), then set Settings → General → "Clicking the menu bar icon" to "Show Pinned Note" — a click now shows that note in a small, resizable, editable popup instead of opening the full app. Good for a running to-do list or a reminder you want one click away.

- The popup is a real, user-resizable window (remembers its size across launches), with its own pin button to keep it open and floating above other windows instead of closing on the next outside click, and its own font zoom (⌘+/⌘-/⌘0) independent of the main editor's.
- Its title is editable right there in the popup, same rename behavior (and collision handling) as renaming any other note.
- Settings → General has a new "Show tags in title bar" toggle (off by default) — a note's `#tags` show as chips next to its title. Click one to search `tag:whatever` without losing your place — the note you clicked from stays open.
- New search operators: `todo:` (notes with an unchecked task), `folder:name` (restrict to one configured folder), and `-word`/`-tag:x`/`-folder:x` (exclude notes matching a term, tag, or folder — combines with anything else in the query).
- Comma-separated search groups are OR'd together — `dog, bone, leash` matches anything with any one of the three. `dog bone leash` (no commas) is unchanged, still requiring all three terms.
- Tab now indents a list item (bullet, numbered, or task) a level deeper, and Shift-Tab outdents it — makes sub-tasks practical: press Return under a checkbox, then Tab, and the new line nests as a child instead of a sibling.
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

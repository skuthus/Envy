import Foundation

/// Content for the notes Envy creates automatically on its very first launch,
/// to onboard new users directly inside the app they're learning.
enum WelcomeContent {
    static let title = "Welcome to Envy"
    static let linkedNoteTitle = "Example Linked Note"

    static let welcomeBody = """
    # Welcome to Envy

    Envy is a fast, flat-file note-taking app inspired by Notational Velocity — one search box, instant results, and notes stored as plain `.md` files you can grep, sync, or edit with anything else you like.

    This note was created automatically so you'd have something to look at on first launch. Delete it whenever you're ready — it won't come back.

    ## Quick Start

    - Type in the search box at the top to filter your notes as you type.
    - Press **↩** to open the highlighted note, or to create a new one if nothing matches your search.
    - Use **↑ / ↓** to move the highlighted note without leaving the search box.
    - **⌘N** creates a blank note directly.
    - **⌘⌫** deletes the selected note (moved to Trash, not permanently deleted).

    That search box is the whole app — there's no separate "new note" dialog. If what you typed doesn't match an existing title, hitting Return just creates it.

    ## Formatting

    Envy renders markdown live as you type, right in the editor — there's no separate preview mode to switch into. Try editing the lines below to see it in action:

    - `# Heading` becomes a large **heading**
    - `**bold**` becomes **bold**
    - `*italic*` becomes *italic*
    - `` `code` `` becomes `code` with a subtle background

    The raw syntax characters (`#`, `*`, `` ` ``) stay visible but dimmed, so you can always see exactly what you typed.

    ## Linking Notes

    Type `[[Note Title]]` anywhere in a note to link to another one. For example, this links to a small companion note: [[Example Linked Note]]

    Hold **⌘** and click a link to follow it. If the note doesn't exist yet, clicking creates it empty and takes you straight there — handy for jotting a quick outline of related notes before you've written any of them.

    ## Multiple Folders

    Settings → General → Storage lets you add more than one notes folder. Envy merges every folder into one flat, searchable list — the folder a note lives in is invisible in search, but you can see and change it from a note's right-click menu ("Move to Folder"). The first folder in that list is where new notes get created by default.

    ## Customizing the Look

    Settings → Appearance has font, color, and window-blur controls, plus a System / Light / Dark mode picker that's independent of your custom colors. Settings → General also has a layout toggle (⌘⇧L) for switching between a side-by-side and a stacked list/editor arrangement.

    ## Reference

    - **Envy → About Envy** has the full keyboard shortcut list and a markup cheat sheet, any time you need them again.
    - The global shortcut **⌥⌘↩** shows or hides Envy from anywhere on your Mac, even when another app is focused — no need to switch apps or find the Dock icon.

    Enjoy the app.
    """

    static let linkedNoteBody = """
    This is a real note, not a dead link. Following [[Welcome to Envy]] with ⌘-click landed you here — that's how linking works throughout Envy: any `[[Note Title]]` becomes a clickable path to another note, creating it on the spot if it doesn't exist yet.
    """
}

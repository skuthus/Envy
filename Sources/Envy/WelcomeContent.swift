import Foundation

/// Content for the notes Envy creates automatically on its very first launch,
/// to onboard new users directly inside the app they're learning.
enum WelcomeContent {
    static let title = "Welcome to Envy"
    static let linkedNoteTitle = "Example Linked Note"

    static let welcomeBody = """
    # 👋 Welcome to Envy

    Envy is a flat-file, frictionless note-taking application. Type in one search box to find or create any note. Every note is a plain `.md` file, so you can edit it with anything else you like too.

    This note was created automatically the first time you launched Envy. Delete it whenever you're ready. It won't come back.

    ## ⚡ Quick Start

    - Type in the search box to filter your notes as you type.
    - Search several words at once, like `dog bone leash`, and Envy finds notes containing all of them anywhere in the text, even scattered across different lines.
    - Click **Name** or **Date** above the list to sort by it. Click the same one again to reverse the direction.
    - Right-click a note (or press **⌥⌘P**) to pin it. Pinned notes stay at the top of the list regardless of sort, marked with a small pin icon. A search that doesn't match a pinned note still hides it, same as any other note.
    - Press **↩** to open the highlighted note. If nothing matches, pressing **↩** creates a new note with that title instead.
    - Use **↑** and **↓** to move the highlighted note without leaving the search box.
    - **⌥↓** and **⌥↑** move keyboard focus between the search box, the note list, and the editor.
    - If your search matches the start of an existing title, the rest of it shows up in grey. Press **→** to complete it.
    - **⌘N** creates a blank note directly.
    - **⌘⌫** deletes the selected note. It goes to Trash, not gone for good.
    - **⌘⇧⌫** restores the note(s) you just deleted, right back where they were.
    - Cmd-click notes in the list to select several at once. Shift-click to select every note between your last click and the new one.

    There's no separate "new note" dialog. The search box handles both jobs.

    ## ✍️ Formatting

    Envy renders markdown live as you type. There's no preview mode to switch into. Syntax characters like `#` and `**` fade out of view once your cursor moves away, and reappear when you click back in to edit them. Try it right here:

    Prefer to see the raw markdown instead? **⌘⇧P** (or Settings → General) turns on plain-text mode, which shows every note as plain, unstyled text with none of the live formatting. Your notes are always plain markdown files either way. This just changes how Envy displays them.

    ### 🔤 Text styles

    - `# Heading` becomes a large **heading**. Use up to six `#`s for smaller headings.
    - `**bold**` becomes **bold**
    - `*italic*` becomes *italic*
    - `***bold italic***` combines both
    - `~~strikethrough~~` becomes ~~strikethrough~~
    - Select some text and press **⌘B** or **⌘I** to bold or italicize it directly, no typing asterisks by hand. Press again to undo it.

    ### 💻 Code

    - `` `inline code` `` gets a subtle background
    - A fenced code block, opened and closed with three backticks on their own lines, renders as monospaced text. Nothing inside it gets reinterpreted as markdown.

    ### 🏗️ Structure

    - `> a quote` renders as an indented blockquote
    - `---` on its own line renders as a horizontal rule

    ### 📋 Lists

    - Start a line with `-` for a bullet list. Use `*` instead and it renders as an actual bullet character.
    - Start a line with `1.` for a numbered list. Press Return to add the next item automatically. The numbers stay in order even if you add or delete an item in the middle.
    - Start a line with `- [ ]` for a task list, and click the checkbox to mark it done.

    ### 🌐 Links

    - `[[Note Title]]` links to another note. Cmd-click to follow it, and it creates the note if it doesn't exist yet.
    - `[text](url)` links to a web address. Cmd-click opens it in your browser.
    - A bare URL like https://example.com becomes clickable on its own.
    - `[text](#heading)` jumps to a heading in this note, like this link to [Structure](#structure). Click it, no modifier needed. The heading part matches the heading's own text, lowercased with spaces turned into hyphens.

    ### 🔖 Footnotes

    - `text[^1]` adds a small clickable reference number, like this one[^1]. Click it to jump straight to its definition.
    - `[^1]: explanation` defines it. Definitions can live anywhere in the note, though the bottom is the usual spot.

    ### 😀 Emoji

    - Type a shortcode like `:smile:` and finish it with the closing colon. It's replaced with the real emoji right away.

    ## 🔗 Linking Notes

    `[[Note Title]]` links work throughout Envy, not just in the list above. Here's one to a small companion note: [[Example Linked Note]]

    Hold **⌘** and click a link to follow it. If the note doesn't exist yet, clicking creates it and takes you straight there. That makes it easy to sketch out related notes before you've written any of them.

    Hold **⌥** (Option) and click a link instead to peek at it without leaving where you are — a small floating preview opens, and you can click straight into it to edit right there. Works on backlinks too. Settings → General can turn this off or change the trigger.

    ## 📆 Due Dates

    Write `due@04-16-26` (or `due@2026-04-16`) anywhere in a note, like this: Finish the quarterly report due@04-16-26

    Envy picks it up automatically — no separate field to fill in. It shows as a colored pill wherever the note appears (the editor, the title bar, the note list), colored by urgency: not-yet-due, due-soon, and overdue each get their own color from your theme.

    Search `due:today`, `due:tomorrow`, `due:yesterday`, `due:week`, `due:nextweek`, `due:month`, `due:overdue` (or `due:past`), or `due:future` for the matching bucket, an exact date the same way `date:` accepts one, or a bare `due:` for "has a due date at all, whenever it is."

    Sort the note list by due date from the column headers, same as Name or Date. Settings → General can turn the due-date sort option and the title bar pill off independently, if you'd rather not see either.

    ## 🏷️ Tags

    Write `#work` anywhere in a note's text and Envy picks it up as a tag automatically, no separate tagging step needed. Tags render bold with a tinted background so they stand out from the rest of the text, like this: #work

    Search `tag:work` to see every note tagged that way — it's not case-sensitive, and partial names work too: `tag:techn` matches `#technology`.

    Combine it with regular search words, like `tag:work meeting`, to narrow further to tagged notes that also mention "meeting".

    ## 📅 Searching by Date

    Search `date:today` or `date:yesterday` for notes modified that day, or `date:week` / `date:month` for the last 7 or 30 days.

    An exact date works too, in whichever format you'd naturally type it: `date:2026-04-15`, `date:4-15-26`, and `date:04-15-2026` all mean the same day.

    ## 🗂️ Multiple Folders

    Settings → General lets you add more than one notes folder. Envy merges them into a single searchable list. Which folder a note lives in doesn't affect search, but you can see and change it from a note's right-click menu.

    Uncheck a folder in that list to hide its notes from the list without removing the folder itself. Check it again any time to bring them back.

    **⌥→** and **⌥←** cycle through your folders one at a time, showing only that folder's notes. "All Folders" is one of the stops too, so cycling always brings you back to the merged view. It's the same checkbox from Settings, just faster.

    The title bar always shows which you're looking at: a folder's name when scoped to one, or "All Notes" for the merged view.

    ## 🎨 Customizing the Look

    - Settings → Theme has a gallery of ready-made looks — Tokyo Night, Dracula, Monokai, both Solarized themes, and Velocity Light/Dark (modeled on the original Notational Velocity) — plus any themes you've saved yourself. Click one to apply it instantly.
    - Every color swatch is always editable. Change one and it becomes a custom variation of whatever theme you started from — save it as a new named theme, duplicate it, rename it, or reset any single swatch back to its default.
    - Colors are grouped by where they show up: Editor (text, background, links, code, tags, and more), List (file list background/text, the note editor's own title bar), and Highlight (search matches, focus border, text selection).
    - Export a theme to a file to share it, or import one someone else made.
    - A blur strength control adjusts how translucent the window background is.
    - A note list density picker controls how much space each note takes up in the list.
    - A mode setting matches System, Light, or Dark, independent of your custom colors.
    - Moving focus to the search box, note list, or editor (by clicking, or with ⌥↓/⌥↑) highlights it with a border. A "Fade out focus highlight" toggle controls whether that border stays as long as it's focused or fades away after a moment, and its color and thickness are both customizable too.

    ## 🧭 Getting Around

    - **⌘⇧L** toggles between a side-by-side and a stacked layout.
    - **⌘+** and **⌘-** zoom the note text larger or smaller. **⌘0** resets it.
    - **⌘↩** centers the window on screen.
    - **⌥⌘↩** shows or hides Envy from anywhere on your Mac, even when another app is focused.
    - A menu bar icon does the same thing on click. Right-click it for New Note, Settings, and Quit.
    - Settings → General has a toggle to automatically hide Envy the moment you click into a different app or an empty part of the screen.
    - Settings → General has a toggle for whether pressing Return in the search box also moves your cursor into the editor, in case you'd rather stay in the search box instead.
    - Settings → General can also show a small clock in the editor's footer, with an optional date in a few different formats, and an option to only show it while in full screen.
    - Every shortcut above (plus the global summon key) can be changed in Settings → Shortcuts. Click a shortcut, then press a new combination to save it right away. A Reset button sits next to each one, plus a "Reset All to Defaults" for starting over.
    - Edit a note in another app while it's open in Envy, and the change appears here automatically. The part that changed briefly flashes so you don't miss it, in the same color as your theme's search highlight.

    ## 📚 Reference

    **Envy → About Envy** has more reference material, including:

    - The full keyboard shortcut list
    - A markup cheat sheet covering everything above
    - A searchable list of every emoji shortcode

    [^1]: This is where that footnote reference above points. Notice how clicking it scrolled you all the way down here.

    Enjoy the app.
    """

    static let linkedNoteBody = """
    This is a real note, not a dead link. Following [[Welcome to Envy]] with a Cmd-click landed you here. That's how linking works throughout Envy: any `[[Note Title]]` becomes a clickable path to another note, and clicking creates it on the spot if it doesn't exist yet.
    """
}

import Foundation

/// Content for the notes Envy creates automatically on its very first launch,
/// to onboard new users directly inside the app they're learning.
enum WelcomeContent {
    static let title = "Welcome to Envy"
    static let linkedNoteTitle = "Example Linked Note"

    static let welcomeBody = """
    # Welcome to Envy

    Envy is a fast, flat-file note-taking app inspired by Notational Velocity. Type in one search box to find or create any note. Every note is a plain `.md` file, so you can edit it with anything else you like too.

    This note was created automatically the first time you launched Envy. Delete it whenever you're ready. It won't come back.

    ## Quick Start

    - Type in the search box to filter your notes as you type.
    - Click **Name** or **Date** above the list to sort by it. Click the same one again to reverse the direction.
    - Press **↩** to open the highlighted note. If nothing matches, pressing **↩** creates a new note with that title instead.
    - Use **↑** and **↓** to move the highlighted note without leaving the search box.
    - If your search matches the start of an existing title, the rest of it shows up in grey. Press **→** to complete it.
    - **⌘N** creates a blank note directly.
    - **⌘⌫** deletes the selected note. It goes to Trash, not gone for good.

    There's no separate "new note" dialog. The search box handles both jobs.

    ## Formatting

    Envy renders markdown live as you type. There's no preview mode to switch into. Syntax characters like `#` and `**` fade out of view once your cursor moves away, and reappear when you click back in to edit them. Try it right here:

    ### Text styles

    - `# Heading` becomes a large **heading**. Use up to six `#`s for smaller headings.
    - `**bold**` becomes **bold**
    - `*italic*` becomes *italic*
    - `***bold italic***` combines both
    - `~~strikethrough~~` becomes ~~strikethrough~~
    - Select some text and press **⌘B** or **⌘I** to bold or italicize it directly, no typing asterisks by hand. Press again to undo it.

    ### Code

    - `` `inline code` `` gets a subtle background
    - A fenced code block, opened and closed with three backticks on their own lines, renders as monospaced text. Nothing inside it gets reinterpreted as markdown.

    ### Structure

    - `> a quote` renders as an indented blockquote
    - `---` on its own line renders as a horizontal rule

    ### Lists

    - Start a line with `-` for a bullet list. Use `*` instead and it renders as an actual bullet character.
    - Start a line with `1.` for a numbered list. Press Return to add the next item automatically. The numbers stay in order even if you add or delete an item in the middle.
    - Start a line with `- [ ]` for a task list, and click the checkbox to mark it done.

    ### Links

    - `[[Note Title]]` links to another note. Cmd-click to follow it, and it creates the note if it doesn't exist yet.
    - `[text](url)` links to a web address. Cmd-click opens it in your browser.
    - A bare URL like https://example.com becomes clickable on its own.
    - `[text](#heading)` jumps to a heading in this note, like this link to [Structure](#structure). Click it, no modifier needed. The heading part matches the heading's own text, lowercased with spaces turned into hyphens.

    ### Footnotes

    - `text[^1]` adds a small clickable reference number, like this one[^1]. Click it to jump straight to its definition.
    - `[^1]: explanation` defines it. Definitions can live anywhere in the note, though the bottom is the usual spot.

    ### Emoji

    - Type a shortcode like `:smile:` and finish it with the closing colon. It's replaced with the real emoji right away.

    ## Linking Notes

    `[[Note Title]]` links work throughout Envy, not just in the list above. Here's one to a small companion note: [[Example Linked Note]]

    Hold **⌘** and click a link to follow it. If the note doesn't exist yet, clicking creates it and takes you straight there. That makes it easy to sketch out related notes before you've written any of them.

    ## Multiple Folders

    Settings → General lets you add more than one notes folder. Envy merges them into a single searchable list. Which folder a note lives in doesn't affect search, but you can see and change it from a note's right-click menu.

    Uncheck a folder in that list to hide its notes from the list without removing the folder itself. Check it again any time to bring them back.

    **⌥→** and **⌥←** cycle through your folders one at a time, showing only that folder's notes. "All Folders" is one of the stops too, so cycling always brings you back to the merged view. It's the same checkbox from Settings, just faster.

    Whenever you're scoped down to one folder, its name shows in the title bar, right next to "Envy".

    ## Customizing the Look

    - Settings → Appearance lets you pick your own font and colors.
    - A blur strength control adjusts how translucent the window background is.
    - A note list density picker controls how much space each note takes up in the list.
    - A file list highlight color picker changes what the selected note looks like.
    - A mode setting matches System, Light, or Dark, independent of your custom colors.

    ## Getting Around

    - **⌘⇧L** toggles between a side-by-side and a stacked layout.
    - **⌘+** and **⌘-** zoom the note text larger or smaller. **⌘0** resets it.
    - **⌘↩** centers the window on screen.
    - **⌥⌘↩** shows or hides Envy from anywhere on your Mac, even when another app is focused.
    - A menu bar icon does the same thing on click. Right-click it for New Note, Settings, and Quit.
    - Settings → General has a toggle for whether pressing Return in the search box also moves your cursor into the editor, in case you'd rather stay in the search box instead.
    - Settings → General can also show a small clock in the editor's footer, with an optional date in a few different formats, and an option to only show it while in full screen.

    ## Reference

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

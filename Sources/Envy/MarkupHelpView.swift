import SwiftUI

struct MarkupHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingEmojiShortcodes = false

    private struct Entry: Identifiable {
        let id = UUID()
        let syntax: String
        let description: String
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    private let groups: [Group] = [
        Group(title: "Headings & Emphasis", entries: [
            Entry(syntax: "# Heading", description: "Larger, bold heading text. Use up to six #'s for smaller heading levels."),
            Entry(syntax: "**bold**", description: "Bold text — select text and press Cmd+B to wrap or unwrap it"),
            Entry(syntax: "*italic*", description: "Italic text — select text and press Cmd+I to wrap or unwrap it"),
            Entry(syntax: "***bold italic***", description: "Bold and italic together"),
            Entry(syntax: "~~strikethrough~~", description: "Strikethrough text"),
        ]),
        Group(title: "Code", entries: [
            Entry(syntax: "`code`", description: "Inline code with a subtle background"),
            Entry(syntax: "```\ncode block\n```", description: "Fenced code block — monospaced, and markdown syntax inside it is left alone"),
        ]),
        Group(title: "Structure", entries: [
            Entry(syntax: "> quote", description: "Blockquote — indented and italic"),
            Entry(syntax: "---", description: "Horizontal rule"),
        ]),
        Group(title: "Lists", entries: [
            Entry(syntax: "- item", description: "Bullet list (\"-\", \"*\", or \"+\" — \"*\" renders as an actual bullet)"),
            Entry(syntax: "1. item", description: "Numbered list — stays sequential automatically as you add or remove items"),
            Entry(syntax: "- [ ] task", description: "Task list with a clickable checkbox — \"- [x]\" for checked"),
        ]),
        Group(title: "Links", entries: [
            Entry(syntax: "[[Note Title]]", description: "Link to another note. Cmd+Click to open it — creates the note if it doesn't exist yet. Option+Click instead to preview it without leaving where you are (Settings → General to change or turn off)."),
            Entry(syntax: "[[Note Title|any words]]", description: "Same link, shown as your own words instead of the note's name — so a link can sit inside a sentence without the filename interrupting it. Rename the note and your wording stays. Click inside a link you're already in to put the cursor there and edit it."),
            Entry(syntax: "[[Note Title#Heading]]", description: "Links to the note. Envy doesn't jump to the heading yet, but the reference is kept as written, so notes brought over from other apps stay linked."),
            Entry(syntax: "[text](url)", description: "Link to a web address. Cmd+Click to open in your browser."),
            Entry(syntax: "<https://…>", description: "Autolink — bare URLs are also detected and made clickable automatically"),
            Entry(syntax: "[text](#heading)", description: "Jump to a heading in this note — click, no modifier needed. Matches the heading's text lowercased with spaces turned into hyphens."),
            Entry(syntax: "![[Note Title]]", description: "Embed another note's live content inline — on its own line, followed by a blank line. The marker stays visible above as an ordinary link; edit or delete it to change or remove the embed. The embedded note is marked by a rule down its left edge, like a blockquote. Click into it to edit that note directly; edits save to it, not this note. Starts read-only so scrolling past it can't accidentally start typing into a different note."),
        ]),
        Group(title: "Fleeting Notes", entries: [
            Entry(syntax: "inbox:", description: "Show the fleeting notes waiting in your Inbox — captures you haven't filed yet. They're ordinary notes living in an Inbox folder inside The Index, marked in the list with an amber dot, and the count beside the search box says how many are waiting (click it to review, click again to come back)."),
            Entry(syntax: "inbox: any words", description: "Captures a fleeting note with that title, without leaving where you are. If a fleeting note by that name already exists it opens instead, the same rule the search box follows."),
            Entry(syntax: "-inbox:", description: "Hide fleeting notes from a search."),
        ]),
        Group(title: "Footnotes", entries: [
            Entry(syntax: "text[^1]", description: "Footnote reference — click it to jump straight to its definition"),
            Entry(syntax: "[^1]: explanation", description: "The footnote's definition. Can live anywhere in the note, though the bottom is the usual spot."),
        ]),
        Group(title: "Tags", entries: [
            Entry(syntax: "#tag", description: "Tag — rendered bold with a tinted background. Search \"tag:name\" to find every note tagged that way, including partial matches."),
        ]),
        Group(title: "Due Dates", entries: [
            Entry(syntax: "@04-16-26", description: "Due date — also accepts \"@2026-04-16\". Shows as a colored pill (urgency-tinted) in the editor, title bar, and note list. Search \"due:today\", \"due:overdue\", \"due:week\", an exact date, or a bare \"due:\" for any due date at all. Sort the note list by it from the column headers."),
            Entry(syntax: "@today", description: "Due today, literally. \"@tomorrow\" and \"@yesterday\" work the same way."),
            Entry(syntax: "@monday", description: "A day name instead of a date — always the next occurrence of that day, even if today already is one. Any day of the week works. It's converted to that actual date the moment you finish typing it, so it stays put and goes overdue when the day passes rather than sliding to the following week."),
            Entry(syntax: "click a due date", description: "Toggles it crossed out — a crossed-out due date no longer shows a pill or matches \"due:\" searches. Click again to restore it. Checking off a task-list box whose text contains a due date does this automatically."),
        ]),
        Group(title: "Emoji", entries: [
            Entry(syntax: ":smile:", description: "Replaced with 😄 as soon as you finish typing it — the note just contains the emoji itself"),
        ]),
        Group(title: "Ligatures", entries: [
            Entry(syntax: "->", description: "Replaced with → as soon as you finish typing it — same instant-expansion as emoji shortcodes. Skipped inside code."),
            Entry(syntax: "<-", description: "Replaced with ←"),
            Entry(syntax: "=>", description: "Replaced with ⇒"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Markup Commands")
                .font(.title2.bold())

            Text("Envy renders these live as you type — marker characters (like # or **) collapse out of view once you move your cursor away, and reappear when you click back into them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            ForEach(group.entries) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(entry.syntax)
                                        .font(.system(.body, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        .frame(width: 160, alignment: .leading)
                                    Text(entry.description)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)

            HStack {
                Button("View Emoji Shortcodes…") {
                    showingEmojiShortcodes = true
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .sheet(isPresented: $showingEmojiShortcodes) {
            EmojiShortcodesView()
        }
    }
}

import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ShortcutPreferences.storageKey) private var customShortcutsRaw = ""

    private struct Entry: Identifiable {
        let id = UUID()
        var action: ShortcutAction?
        var staticKeys: String?
        let description: String

        init(action: ShortcutAction, description: String) {
            self.action = action
            self.description = description
        }

        init(keys: String, description: String) {
            self.staticKeys = keys
            self.description = description
        }
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    // Entries tied to a ShortcutAction resolve their displayed keys from the
    // user's current customization (Settings → Shortcuts) instead of a fixed
    // string, so this reference sheet can't drift out of sync with what a
    // shortcut is actually bound to.
    private var groups: [Group] {
        [
            Group(title: "Global", entries: [
                Entry(action: .summonApp, description: "Show or hide Envy — works from any app"),
            ]),
            Group(title: "Notes", entries: [
                Entry(action: .newNote, description: "New note"),
                Entry(action: .deleteNote, description: "Delete the selected note"),
                Entry(keys: "⌘-click a [[link]]", description: "Open the linked note (creates it if it doesn't exist)"),
            ]),
            Group(title: "Search & Navigation", entries: [
                Entry(keys: "↑ / ↓", description: "Move the highlighted note while searching"),
                Entry(keys: "↩", description: "Open the highlighted note, or create one from your search text"),
            ]),
            Group(title: "Window", entries: [
                Entry(action: .centerWindow, description: "Center the window on screen"),
                Entry(action: .toggleLayout, description: "Toggle horizontal / vertical layout"),
                Entry(action: .togglePlainTextMode, description: "Toggle plain-text mode (ignores all markdown formatting)"),
            ]),
            Group(title: "Folders", entries: [
                Entry(action: .nextFolder, description: "Show only the next folder's notes"),
                Entry(action: .previousFolder, description: "Show only the previous folder's notes"),
            ]),
            Group(title: "Font", entries: [
                Entry(action: .bold, description: "Bold the selected text (wraps it in **, or unwraps it if already bold)"),
                Entry(action: .italic, description: "Italicize the selected text (wraps it in *, or unwraps it if already italic)"),
                Entry(action: .zoomIn, description: "Zoom in on the note text"),
                Entry(action: .zoomOut, description: "Zoom out on the note text"),
                Entry(action: .actualSize, description: "Reset the note text zoom"),
            ]),
            Group(title: "Standard", entries: [
                Entry(keys: "⌘,", description: "Settings"),
                Entry(keys: "⌘Q", description: "Quit"),
                Entry(keys: "⌘W", description: "Close window"),
            ]),
        ]
    }

    private func keys(for entry: Entry) -> String {
        if let action = entry.action {
            return ShortcutPreferences.binding(for: action, raw: customShortcutsRaw).displayString
        }
        return entry.staticKeys ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            ForEach(group.entries) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(keys(for: entry))
                                        .font(.system(.body, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .frame(minWidth: 150, alignment: .leading)
                                    Text(entry.description)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    Text("Customize any of these in Settings → Shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

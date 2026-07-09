import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let keys: String
        let description: String
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    private let groups: [Group] = [
        Group(title: "Global", entries: [
            Entry(keys: "⌥⌘↩", description: "Show or hide Envy — works from any app"),
        ]),
        Group(title: "Notes", entries: [
            Entry(keys: "⌘N", description: "New note"),
            Entry(keys: "⌘⌫", description: "Delete the selected note"),
            Entry(keys: "⌘-click a [[link]]", description: "Open the linked note (creates it if it doesn't exist)"),
        ]),
        Group(title: "Search & Navigation", entries: [
            Entry(keys: "↑ / ↓", description: "Move the highlighted note while searching"),
            Entry(keys: "↩", description: "Open the highlighted note, or create one from your search text"),
        ]),
        Group(title: "Window", entries: [
            Entry(keys: "⌘↩", description: "Center the window on screen"),
            Entry(keys: "⌘⇧L", description: "Toggle horizontal / vertical layout"),
        ]),
        Group(title: "Folders", entries: [
            Entry(keys: "⌘→", description: "Show only the next folder's notes"),
            Entry(keys: "⌘←", description: "Show only the previous folder's notes"),
        ]),
        Group(title: "Font", entries: [
            Entry(keys: "⌘B", description: "Bold the selected text (wraps it in **, or unwraps it if already bold)"),
            Entry(keys: "⌘I", description: "Italicize the selected text (wraps it in *, or unwraps it if already italic)"),
            Entry(keys: "⌘+", description: "Zoom in on the note text"),
            Entry(keys: "⌘-", description: "Zoom out on the note text"),
            Entry(keys: "⌘0", description: "Reset the note text zoom"),
        ]),
        Group(title: "Standard", entries: [
            Entry(keys: "⌘,", description: "Settings"),
            Entry(keys: "⌘Q", description: "Quit"),
            Entry(keys: "⌘W", description: "Close window"),
        ]),
    ]

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
                                    Text(entry.keys)
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

import SwiftUI

struct EmojiShortcodesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let allEntries: [(shortcode: String, emoji: String)] = EmojiShortcodes.map
        .map { ($0.key, $0.value) }
        .sorted { $0.shortcode < $1.shortcode }

    private var filteredEntries: [(shortcode: String, emoji: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return allEntries }
        return allEntries.filter { $0.shortcode.contains(trimmed) }
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Emoji Shortcodes")
                .font(.title2.bold())

            Text("Type a shortcode and finish it with the closing colon — it's replaced with the emoji immediately.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search shortcodes", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(filteredEntries, id: \.shortcode) { entry in
                        HStack(spacing: 6) {
                            Text(entry.emoji)
                            Text(":\(entry.shortcode):")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 420)

            if filteredEntries.isEmpty {
                Text("No shortcodes match \u{201C}\(query)\u{201D}.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

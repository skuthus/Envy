import SwiftUI

struct MarkupHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let syntax: String
        let description: String
    }

    private let entries: [Entry] = [
        Entry(syntax: "# Heading", description: "Larger, bold heading text. Use up to six #'s for smaller heading levels."),
        Entry(syntax: "**bold**", description: "Bold text"),
        Entry(syntax: "*italic*", description: "Italic text"),
        Entry(syntax: "`code`", description: "Inline code with a subtle background"),
        Entry(syntax: "[[Note Title]]", description: "Link to another note. Cmd+Click to open it — creates the note if it doesn't exist yet.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Markup Commands")
                .font(.title2.bold())

            Text("Velocity renders these inline as you type — the marker characters are dimmed rather than hidden, so you can always see the raw syntax.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.syntax)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .frame(width: 150, alignment: .leading)
                        Text(entry.description)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

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

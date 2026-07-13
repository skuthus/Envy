import SwiftUI
import EnvyCore

struct NoteRow: View {
    let note: Note
    var showPreview: Bool
    var showDateModified: Bool
    var dateDisplayStyle: DateDisplayStyle
    var textColor: Color?
    var bold: Bool = false
    var isPinned: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(textColor ?? Color.secondary)
            }
            // layoutPriority(1) so the title always keeps its full width —
            // the preview (default priority) is what gives way and
            // truncates when the row is too narrow for both, never the
            // other way around.
            Text(note.title)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(textColor ?? Color.primary)
                .fontWeight(bold ? .bold : nil)
                .layoutPriority(1)
            if showPreview && !note.preview.isEmpty {
                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontWeight(bold ? .bold : nil)
                    .lineLimit(1)
            }
            if showDateModified {
                Spacer()
                dateText
                    .font(.caption)
                    .foregroundStyle(textColor ?? Color.secondary)
                    .fontWeight(bold ? .bold : nil)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var dateText: some View {
        if dateDisplayStyle == .relative {
            Text(note.modifiedDate, style: .relative)
        } else {
            Text(dateDisplayStyle.format(note.modifiedDate))
        }
    }
}

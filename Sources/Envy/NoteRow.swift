import SwiftUI
import VelocityCore

struct NoteRow: View {
    let note: Note
    var showPreview: Bool
    var showDateModified: Bool
    var dateDisplayStyle: DateDisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(note.title)
                    .font(.body)
                    .lineLimit(1)
                if showDateModified {
                    Spacer()
                    dateText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if showPreview && !note.preview.isEmpty {
                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

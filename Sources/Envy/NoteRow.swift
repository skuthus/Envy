import SwiftUI
import VelocityCore

struct NoteRow: View {
    let note: Note
    var showPreview: Bool
    var showDateModified: Bool
    var dateDisplayStyle: DateDisplayStyle
    var textColor: Color?
    var bold: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(note.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(textColor ?? Color.primary)
                    .fontWeight(bold ? .bold : nil)
                if showDateModified {
                    Spacer()
                    dateText
                        .font(.caption)
                        .foregroundStyle(textColor ?? Color.secondary)
                        .fontWeight(bold ? .bold : nil)
                        .lineLimit(1)
                }
            }
            if showPreview && !note.preview.isEmpty {
                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

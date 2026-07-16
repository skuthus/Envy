import SwiftUI
import EnvyCore

struct NoteRow: View {
    let note: Note
    var showPreview: Bool
    var showDateModified: Bool
    var dateDisplayStyle: DateDisplayStyle
    /// Which column's date actually shows in the trailing slot — a
    /// traditional sortable list shows whatever you're sorted by (Finder's
    /// Date Modified column doesn't stick around once you sort by name and
    /// add Date Created instead), not a fixed field regardless of sort.
    /// Sorting by name falls back to modifiedDate, same as before this
    /// existed — only .due actually changes what's displayed.
    var sortField: NoteSortField
    var theme: Theme
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
            if showDateModified, let displayedDate {
                Spacer()
                dateText(displayedDate)
                    .font(.caption)
                    .foregroundStyle(dateTextColor(for: displayedDate))
                    .fontWeight(bold ? .bold : nil)
                    .lineLimit(1)
            }
        }
    }

    /// nil when sorted by due date but this particular note doesn't have
    /// one — shown as a blank trailing slot rather than silently falling
    /// back to modifiedDate, same as a traditional sorted column leaves a
    /// row's cell empty rather than substituting an unrelated value.
    private var displayedDate: Date? {
        sortField == .due ? note.due : note.modifiedDate
    }

    /// Modified date stays plain (textColor override or secondary, same as
    /// always) — urgency coloring only applies when the slot is actually
    /// showing a due date, matching the same overdue/soon/later split used
    /// in the editor and its title-bar chip.
    private func dateTextColor(for date: Date) -> Color {
        guard sortField == .due else { return textColor ?? Color.secondary }
        switch NoteStore.dueUrgency(for: date) {
        case .overdue: return Color(nsColor: theme.resolvedDueOverdueColor)
        case .soon: return Color(nsColor: theme.resolvedDueSoonColor)
        case .later: return textColor ?? Color(nsColor: theme.resolvedDueColor)
        }
    }

    /// " +N" once there's more than one active due date on this note (the
    /// slot's showing the earliest of them), matching the same "+N" shape
    /// already used for multiple tags in WikilinkPreviewPopover — empty
    /// otherwise, including whenever this slot isn't showing a due date at
    /// all (sorted by Name/Date instead).
    private var dueCountSuffix: String {
        guard sortField == .due, note.dueDateCount > 1 else { return "" }
        return " +\(note.dueDateCount - 1)"
    }

    @ViewBuilder
    private func dateText(_ date: Date) -> some View {
        if dateDisplayStyle == .relative {
            Text(date, style: .relative) + Text(dueCountSuffix)
        } else {
            Text(dateDisplayStyle.format(date) + dueCountSuffix)
        }
    }
}

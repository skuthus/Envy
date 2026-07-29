import SwiftUI
import EnvyCore

/// How a note's subfolder is shown in the list row.
enum FolderListDisplay: String, CaseIterable, Identifiable {
    case dot, name, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dot: return "Colored dot"
        case .name: return "Folder name"
        case .off: return "Nothing"
        }
    }
}

struct NoteRow: View {
    @Environment(\.interfaceFontScale) private var interfaceFontScale
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
    /// Set for a note sitting in `Inbox/` — the one visible difference
    /// between a fleeting note and any other.
    var isFleeting: Bool = false
    /// The color of the subfolder this note lives in, when its folder has one
    /// assigned. Shown as a dot, unless the note is fleeting — the amber inbox
    /// dot takes that one slot, since "unfiled" outranks a folder category.
    var folderColor: Color? = nil
    /// When true the folder indicator sits just after the title instead of
    /// before it. The Inbox mark is unaffected — it always leads, since it's a
    /// different kind of signal ("unfiled") than a folder category.
    var dotTrailing: Bool = false
    /// The note's subfolder as a relative path ("Projects" or "Projects/Ideas"),
    /// for the "Folder name" display. nil for a root or Inbox note.
    var folderName: String? = nil
    /// How the subfolder shows in the list — a colored dot, a labelled chip, or
    /// nothing.
    var folderDisplay: FolderListDisplay = .dot

    /// The dot's quick hover label (see folderIndicator) — hand-rolled
    /// because .help()'s system delay isn't tunable.
    @State private var showsFolderTip = false
    @State private var dotHoverTask: Task<Void, Never>?

    /// Written by the marker's right-click color menu; ContentView observes
    /// this key and rebuilds the folder-color caches, so every row repaints.
    @AppStorage(FolderColorPreferences.storageKey) private var folderColorsRaw = ""

    var body: some View {
        HStack(spacing: 6) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10 * interfaceFontScale))
                    .foregroundStyle(textColor ?? Color.secondary)
            }
            fleetingMark
            if !dotTrailing { folderIndicator }
            // The ⎈ AI-provenance mark is hidden until the feature is
            // designed. Note.aiProvenance still parses it, so restoring the
            // badge is re-adding this block — nothing downstream was removed.
            // layoutPriority(1) so the title always keeps its full width —
            // the preview (default priority) is what gives way and
            // truncates when the row is too narrow for both, never the
            // other way around.
            Text(note.title)
                .font(.system(size: 13 * interfaceFontScale))
                .lineLimit(1)
                .foregroundStyle(textColor ?? Color.primary)
                .fontWeight(bold ? .bold : nil)
                .layoutPriority(1)
            if dotTrailing { folderIndicator }
            if showPreview && !note.preview.isEmpty {
                Text(note.preview)
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .fontWeight(bold ? .bold : nil)
                    .lineLimit(1)
            }
            if showDateModified, let displayedDate {
                Spacer()
                dateText(displayedDate)
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(dateTextColor(for: displayedDate))
                    .fontWeight(bold ? .bold : nil)
                    .lineLimit(1)
            }
        }
    }

    /// The Inbox mark (amber "!"), for a fleeting note. Always leads the title,
    /// independent of the folder-dot side, because "unfiled" is a different
    /// signal than a folder colour. Empty for a filed note — and an empty
    /// builder adds no HStack spacing, so a filed note lays out unchanged.
    @ViewBuilder
    private var fleetingMark: some View {
        if isFleeting {
            FleetingDot(theme: theme)
        }
    }

    /// The subfolder indicator, on whichever side `dotTrailing` chooses. Gated on
    /// `!isFleeting` so a fleeting note only ever shows the "!" — the two never
    /// stack. A colored dot (only for a colored folder), a labelled chip (for any
    /// subfolder, tinted to its color when it has one), or nothing.
    @ViewBuilder
    private var folderIndicator: some View {
        if !isFleeting {
            switch folderDisplay {
            case .off:
                EmptyView()
            case .dot:
                if let folderColor {
                    Circle()
                        .fill(folderColor)
                        .frame(width: 7 * interfaceFontScale, height: 7 * interfaceFontScale)
                        // The dot alone says "in a colored folder" but not
                        // which — hovering names it. A hand-rolled label, not
                        // .help(): the system tooltip's ~1.5s delay isn't
                        // tunable and reads as "nothing happens". A slightly
                        // larger invisible hit area so a 7pt dot isn't a
                        // pixel-hunt to hover.
                        .contentShape(Rectangle().inset(by: -3))
                        .onHover { hovering in
                            dotHoverTask?.cancel()
                            if hovering, folderName != nil {
                                dotHoverTask = Task { @MainActor in
                                    // Just enough delay that sweeping the
                                    // cursor across the list doesn't strobe
                                    // labels; a deliberate pause shows it.
                                    try? await Task.sleep(for: .milliseconds(250))
                                    guard !Task.isCancelled else { return }
                                    showsFolderTip = true
                                }
                            } else {
                                showsFolderTip = false
                            }
                        }
                        .overlay(alignment: .top) {
                            if showsFolderTip, let folderName {
                                Text(folderName)
                                    .font(.system(size: 10 * interfaceFontScale))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundStyle(folderColor)
                                    .padding(.horizontal, 6 * interfaceFontScale)
                                    .padding(.vertical, 2)
                                    .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                                    .overlay(Capsule().strokeBorder(folderColor.opacity(0.4), lineWidth: 1))
                                    // Floats above the dot, over the previous
                                    // row — which paints earlier, so this
                                    // draws on top of it.
                                    .offset(y: -(16 * interfaceFontScale))
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel(folderName.map { "In folder \($0)" } ?? "In a colored folder")
                        .contextMenu { folderColorMenu }
                }
            case .name:
                if let folderName {
                    Text(folderName)
                        .font(.system(size: 10 * interfaceFontScale))
                        .lineLimit(1)
                        .foregroundStyle(folderColor ?? Color.secondary)
                        .padding(.horizontal, 5 * interfaceFontScale)
                        .padding(.vertical, 1)
                        .background((folderColor ?? Color.secondary).opacity(0.15), in: Capsule())
                        .help(folderName)
                        .contextMenu { folderColorMenu }
                }
            }
        }
    }

    /// Right-clicking the folder marker recolors its folder — the same menu a
    /// tag chip offers, writing the same preference the Settings color wells
    /// edit. Attached to the marker itself, so it wins over the row's own
    /// context menu only when the click lands on the dot/chip.
    @ViewBuilder
    private var folderColorMenu: some View {
        if let folderName {
            ForEach(FolderColorPreferences.presets, id: \.name) { preset in
                Button {
                    folderColorsRaw = FolderColorPreferences.setting(preset.color, for: folderName, in: folderColorsRaw)
                } label: {
                    Text("\(preset.emoji)  \(preset.name)")
                }
            }

            Button("Custom Color…") {
                FolderColorPanel.present(
                    initial: NSColor(folderColor ?? .secondary),
                    for: folderName)
            }

            if FolderColorPreferences.color(for: folderName, raw: folderColorsRaw) != nil {
                Divider()
                Button("Remove Color", role: .destructive) {
                    folderColorsRaw = FolderColorPreferences.setting(nil, for: folderName, in: folderColorsRaw)
                }
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
        if sortField == .due {
            // Never the live-ticking Text(_:style:.relative) below, even
            // when dateDisplayStyle is .relative — a due date is a
            // calendar-day value with no meaningful time-of-day or
            // sub-day granularity to tick (SwiftUI's own relative style
            // compares exact instants, so it showed "in 14 hours" for a
            // note due tomorrow, or "10 hours ago" for one due today).
            // formatDueDate handles every style's due-specific formatting
            // statically instead — see its own comment for the full story.
            Text(dateDisplayStyle.formatDueDate(date) + dueCountSuffix)
        } else if dateDisplayStyle == .relative {
            Text(date, style: .relative)
        } else {
            Text(dateDisplayStyle.format(date))
        }
    }
}

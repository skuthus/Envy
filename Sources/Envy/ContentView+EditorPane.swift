import SwiftUI
import AppKit
import EnvyCore

// The editor side of the split view: the note editor (or template editor,
// or empty state), the backlinks panel, and the footer bar with its clock,
// loading indicator, and word count. Split out of ContentView.swift purely
// for file size/navigability — same type, zero behavior change.
extension ContentView {
    var editorPane: some View {
        VStack(spacing: 0) {
            Group {
                if let editingTemplate {
                    TemplateEditorView(
                        store: store,
                        template: editingTemplate,
                        theme: theme,
                        requireModifierForLinkClick: requireModifierForLinkClick,
                        showTitleHeader: showEditorTitleHeader,
                        fontZoom: CGFloat(editorFontZoom),
                        plainTextMode: plainTextMode,
                        noteTitles: noteTitlesByRecencyCache,
                        focusedField: $focusedField,
                        onDone: { self.editingTemplate = nil }
                    )
                    .id(editingTemplate.id)
                } else if let selectedID, store.notes.contains(where: { $0.id == selectedID }) {
                    NoteEditorView(
                        store: store,
                        noteID: selectedID,
                        focusedField: $focusedField,
                        onNavigate: navigateToNote,
                        onRename: { newTitle in renameSelectedNote(to: newTitle) },
                        onTagSearch: searchByTag,
                        theme: theme,
                        requireModifierForLinkClick: requireModifierForLinkClick,
                        searchQuery: editorSearchQuery,
                        showTitleHeader: showEditorTitleHeader,
                        showTagsInTitleBar: showTagsInTitleBar,
                        fontZoom: CGFloat(editorFontZoom),
                        plainTextMode: plainTextMode,
                        noteTitles: noteTitlesByRecencyCache,
                        onStatsChange: { words, characters in
                            editorWordCount = words
                            editorCharacterCount = characters
                        }
                    )
                    // Forces a fresh NoteEditorView (and its underlying NSTextView)
                    // per note instead of patching the same instance in place —
                    // patching relied on noteID and content always updating in the
                    // same render pass, which isn't guaranteed and could show one
                    // note's content inside another's editor.
                    .id(selectedID)
                } else {
                    ContentUnavailableView("No Note Selected", systemImage: "note.text")
                }
            }
            .frame(maxHeight: .infinity)
            .focusHighlight(
                isFocused: focusedField == .editor,
                fadeOut: fadeFocusHighlight,
                color: Color(nsColor: theme.resolvedFocusHighlightColor),
                lineWidth: CGFloat(theme.focusHighlightThickness),
                shape: Rectangle()
            )
            // Lives here (not inside NoteEditorView) specifically so it stays
            // visible — clock included — even when no note is selected and
            // NoteEditorView isn't in the view hierarchy at all.
            Divider()
            // Sits directly above the footer bar (rather than the bar
            // growing to contain it) so expanding the list grows the panel
            // upward into the editor instead of pushing the footer down.
            if backlinksExpanded && !currentBacklinkNotes.isEmpty && editingTemplate == nil {
                backlinksExpandedList
                Divider()
            }
            editorFooter
        }
        // Opaque, not the window's translucent backdrop — in horizontal
        // layout this is the detail column of a NavigationSplitView, which
        // (unlike the sidebar's search/sort chrome) had nothing of its own
        // covering the strip between the opaque native title bar and where
        // NoteEditorView's own background starts, letting the blur show
        // through there and reading as a stray transparent gap.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea(edges: .top))
        .onChange(of: selectedID) { _, newValue in
            if newValue == nil {
                editorWordCount = 0
                editorCharacterCount = 0
            }
            recomputeBacklinkNotes()
        }
    }

    private var editorFooter: some View {
        ZStack {
            // The clock is centered on the whole bar via this overlay
            // rather than sitting between two Spacers in the HStack below —
            // a Spacer-based center only looks centered when both sides
            // happen to be the same width, and the right side now varies
            // (backlinks toggle present or not).
            if showFooterClock && (!showFooterClockOnlyWhenFullScreen || isFullScreen) {
                // TimelineView instead of a plain Text so the clock actually
                // ticks forward — a static Text computed once in body would
                // freeze at whatever time the view last happened to redraw.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(clockString(for: context.date))
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
            }
            HStack {
                HStack(spacing: 10) {
                    // Lives here (rather than floating above the notes list,
                    // where it used to be) so it doesn't shift that list's
                    // layout every time it appears/disappears — a scan over
                    // several thousand notes is common enough (external
                    // sync, bulk import) that the old spot was popping in
                    // and out distractingly often.
                    if showLoadingIndicator {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading notes…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }
                    if selectedID != nil, showBacklinks, !currentBacklinkNotes.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { backlinksExpanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                // Points where the panel will move on the next
                                // tap — up to expand (the list grows upward),
                                // down to collapse back.
                                Image(systemName: backlinksExpanded ? "chevron.down" : "chevron.up")
                                    .font(.caption2)
                                Text("\(currentBacklinkNotes.count) Backlink\(currentBacklinkNotes.count == 1 ? "" : "s")")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                if selectedID != nil {
                    Text("\(editorWordCount) words, \(editorCharacterCount) characters")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
            }
        }
        // A touch more than the usual 10pt — this bar runs edge-to-edge at
        // the bottom of the window, where the screen/window corner
        // curvature can clip content sitting right at 10pt.
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.bar)
        .animation(.easeInOut(duration: 0.15), value: showLoadingIndicator)
    }

    private var backlinksExpandedList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(currentBacklinkNotes) { linked in
                Button {
                    navigateToNote(titled: linked.title)
                } label: {
                    Text(linked.title)
                        .font(.body)
                        .foregroundStyle(Color(nsColor: theme.resolvedLinkColor))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func clockString(for date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard showFooterClockDate else { return time }
        return "\(footerClockDateFormat.format(date)) · \(time)"
    }
}

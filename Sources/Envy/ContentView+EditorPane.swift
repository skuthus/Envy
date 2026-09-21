import SwiftUI
import AppKit
import EnvyCore

// The editor side of the split view: the note editor (or template editor,
// or empty state), the backlinks panel, and the footer bar with its clock,
// loading indicator, and word count. Split out of ContentView.swift purely
// for file size/navigability — same type, zero behavior change.
extension ContentView {
    /// The selected note, when it's a fleeting one — drives the two review
    /// buttons in the title bar and nothing else.
    private var fleetingNote: Note? {
        guard inboxEnabled, let selectedID, let note = store.note(withID: selectedID),
              store.isInboxNote(note) else { return nil }
        return note
    }

    var editorPane: some View {
        VStack(spacing: 0) {
            editorContentArea
                .frame(maxHeight: .infinity)
            // Lives here (not inside NoteEditorView) specifically so it stays
            // visible — clock included — even when no note is selected and
            // NoteEditorView isn't in the view hierarchy at all.
            Divider()
            // Sits directly above the footer bar (rather than the bar
            // growing to contain it) so expanding the list grows the panel
            // upward into the editor instead of pushing the footer down.
            if backlinksExpanded && hasAnyInterlinks && !isTemplateQuery {
                interlinksExpandedList
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
        // In Glassify the editor body becomes a frosted panel so the deepened
        // backdrop reads through it, still filling up under the title bar.
        .background(editorPaneBackground.ignoresSafeArea(edges: .top))
        .onChange(of: selectedID) { _, newValue in
            if newValue == nil {
                editorWordCount = 0
                editorCharacterCount = 0
            }
            recomputeInterlinks()
        }
    }

    /// One editor pane when not split; two panes side by side (or stacked) when
    /// the split is on and no search operator has taken over the pane.
    @ViewBuilder
    var editorContentArea: some View {
        if splitEnabled && !isEditorQueryMode {
            PersistentVSplitView(
                storageKey: "editorSplitFraction",
                defaultTopFraction: 0.5,
                isVertical: !splitStacked
            ) {
                notePane(noteID: leadingPaneID, isActive: !activePaneIsTrailing, trailing: false)
            } bottom: {
                notePane(noteID: trailingPaneID, isActive: activePaneIsTrailing, trailing: true)
            }
            // Recreate on a direction flip so the NSSplitView takes the new axis.
            .id(splitStacked)
        } else {
            singleEditorArea
        }
    }

    /// One physical editor pane in a split: the note editor (or an empty
    /// placeholder), a thin accent bar along the active pane's top edge, and a
    /// click anywhere in it that makes it the active pane.
    @ViewBuilder
    func notePane(noteID: String?, isActive: Bool, trailing: Bool) -> some View {
        Group {
            if let noteID, store.note(withID: noteID) != nil {
                noteEditorContent(noteID: noteID, isActive: isActive)
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "note.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The inactive pane recedes under a faint scrim so the active one reads
        // as focused at a glance — light enough that its note stays readable,
        // and non-interactive so a click still activates the pane underneath.
        .overlay {
            if !isActive {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .allowsHitTesting(false)
            }
        }
        // A thin accent line marks the active pane's top edge.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(isActive ? Color(nsColor: theme.resolvedFocusHighlightColor) : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        // Simultaneous so it never eats a click meant for the editor — any
        // click in a pane just also makes it active.
        .simultaneousGesture(TapGesture().onEnded { activatePane(trailing: trailing) })
    }

    var singleEditorArea: some View {
        Group {
            if isTemplateQuery {
                    // Whichever template is highlighted (arrow keys, a click,
                    // or a freshly-created one) shows here, live-editable and
                    // auto-saving — clicking/browsing just opens it, same as
                    // opening a regular note. "Create Note from Template" is
                    // its own explicit button right in the header, not a
                    // side effect of looking.
                    if let template = matchingTemplatesForQuery.first(where: { $0.id == highlightedTemplateID }) {
                        TemplateEditorView(
                            store: store,
                            template: template,
                            theme: theme,
                            requireModifierForLinkClick: requireModifierForLinkClick,
                            fontZoom: CGFloat(editorFontZoom),
                            plainTextMode: plainTextMode,
                            noteTitles: noteTitlesByRecencyCache,
                            focusedField: $focusedField,
                            onDone: { highlightedTemplateID = nil },
                            onCreateNote: { createFromTemplate(template, title: template.name) },
                            // A template's id is its path, so renaming it
                            // means re-pointing the highlight at the moved
                            // file or the pane goes blank underneath you —
                            // and the cached template list has to pick up
                            // the move too, for the same reason: the
                            // highlight lookup above runs against it.
                            onRenamed: { movedURL in
                                refreshTemplates()
                                highlightedTemplateID = movedURL.path
                            }
                        )
                        .id(template.id)
                    } else {
                        ContentUnavailableView("No Template Selected", systemImage: "doc.badge.plus")
                    }
                } else if isTrashQuery {
                    trashPreviewPane

                } else if isTagBrowseQuery {
                    ContentUnavailableView("Browsing Tags", systemImage: "tag", description: Text("Pick a tag to see its notes."))

                } else if isFolderBrowseQuery {
                    ContentUnavailableView("Browsing Folders", systemImage: "folder", description: Text("Pick a folder to see its notes."))

                } else if let selectedID, store.note(withID: selectedID) != nil {
                    noteEditorContent(noteID: selectedID, isActive: true)
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
    }

    /// The note editor for one note, used by the single pane and by each split
    /// pane. `isActive` gates the shared footer's word/char counts to the active
    /// pane so the inactive pane's editing doesn't overwrite them.
    ///
    /// Deliberately NOT given `.id(noteID)`: an id recreated the whole
    /// NoteEditorView + NSTextView per note switch, flashing the editor blank.
    /// It's reused and swaps content in place — NoteEditorView.switchNote handles
    /// the per-note reset (flush the old save, load new content, reset
    /// undo/scroll) keyed off `noteID` changing.
    @ViewBuilder
    func noteEditorContent(noteID: String, isActive: Bool) -> some View {
        let paneNote = store.note(withID: noteID)
        let isFleeting = isActive && inboxEnabled && (paneNote.map(store.isInboxNote) ?? false)
        NoteEditorView(
            store: store,
            noteID: noteID,
            focusedField: $focusedField,
            onNavigate: navigateToNote,
            onExtractSelection: extractSelectionToNote,
            onRename: { newTitle in
                if let note = store.note(withID: noteID) { renameNote(note, to: newTitle) }
            },
            // Resolved at CLICK time, never captured: a Submit menu's closure can
            // outlive a note switch, and a submit auto-advances the selection, so
            // a captured note value would re-submit the already-moved note.
            onSubmitFleeting: !isFleeting ? nil : { folder in
                if let note = store.note(withID: noteID), store.isInboxNote(note) {
                    submitFromInbox(note, toSubfolder: folder)
                }
            },
            onDeleteFleeting: !isFleeting ? nil : {
                if let note = store.note(withID: noteID), store.isInboxNote(note) {
                    deleteFromInbox(note)
                }
            },
            submitFolders: indexIncludeSubfolders ? subfolderCache : [],
            submitFolderSwatch: { folderSwatchCache[$0] },
            onTagSearch: searchByTag,
            onFolderSearch: searchByFolder,
            theme: theme,
            requireModifierForLinkClick: requireModifierForLinkClick,
            searchQuery: editorSearchQuery,
            revealLine: taskRevealNoteID == noteID ? taskRevealLine : nil,
            showTagsInTitleBar: showTagsInTitleBar,
            showFolderInTitleBar: showFolderInTitleBar,
            showDuePill: showDuePill,
            linkPreviewTrigger: linkPreviewTrigger,
            fontZoom: CGFloat(editorFontZoom),
            plainTextMode: plainTextMode,
            protectAISignature: protectAISignature,
            noteTitles: noteTitlesByRecencyCache,
            onStatsChange: { words, characters in
                if isActive {
                    editorWordCount = words
                    editorCharacterCount = characters
                }
            }
        )
    }

    /// Shown in the editor pane's own slot while "trash:" is typed — read
    /// only, since browsing trash is meant to be safe to click through
    /// without accidentally changing anything. Restore/Reveal/Delete are
    /// explicit buttons right here, the same three actions the row's own
    /// right-click menu offers, so acting on what you're looking at never
    /// requires guessing where the controls are.
    @ViewBuilder
    private var trashPreviewPane: some View {
        if let note = matchingTrashForQuery.first(where: { $0.id == highlightedTrashID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(note.title)
                        .font(.system(size: 15 * interfaceFontScale, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Restore") {
                        restoreFromTrash(note)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([note.url])
                    }
                    Button("Delete", role: .destructive) {
                        deleteFromTrash(note)
                    }
                }
                .padding(12)
                Divider()
                ScrollView {
                    Text(note.content)
                        .font(.system(size: 13 * interfaceFontScale))
                        .foregroundStyle(Color(nsColor: theme.resolvedTextColor))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .background(Color(nsColor: theme.resolvedBackgroundColor))
        } else {
            ContentUnavailableView("No Trashed Note Selected", systemImage: "trash")
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
                        .font(.system(size: 10 * interfaceFontScale))
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
                                .font(.system(size: 10 * interfaceFontScale))
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }
                    if selectedID != nil, showBacklinks, hasAnyInterlinks {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { backlinksExpanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                // Points where the panel will move on the next
                                // tap — up to expand (the list grows upward),
                                // down to collapse back.
                                Image(systemName: backlinksExpanded ? "chevron.down" : "chevron.up")
                                    .font(.system(size: 10 * interfaceFontScale))
                                Text("\(interlinksCount) Interlink\(interlinksCount == 1 ? "" : "s")")
                                    .font(.system(size: 10 * interfaceFontScale))
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    if selectedID != nil {
                        Text("\(editorWordCount) words, \(editorCharacterCount) characters")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10 * interfaceFontScale))
                    }
                    if showFooterVaultCounts {
                        if selectedID != nil {
                            Rectangle()
                                // The same color and 1pt thickness as the
                                // horizontal rule above the bar, so the two
                                // read as one family of chrome lines meeting
                                // at a right angle.
                                .fill(Color(nsColor: .separatorColor))
                                // Spans the bar's full height: tall enough to
                                // cover the text row plus the footer's 4pt
                                // vertical paddings, with the negative padding
                                // letting that extra height draw into the
                                // paddings instead of growing the bar. Sharp
                                // corners, since its ends meet the edges.
                                .frame(width: 1, height: 12 * interfaceFontScale + 8)
                                .padding(.vertical, -4)
                        }
                        Text(vaultCountsLabel)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10 * interfaceFontScale))
                    }
                }
            }
        }
        // A touch more than the usual 10pt — this bar runs edge-to-edge at
        // the bottom of the window, where the screen/window corner
        // curvature can clip content sitting right at 10pt.
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.xs)
        .chromeBar(glassify)
        .animation(.easeInOut(duration: 0.15), value: showLoadingIndicator)
    }

    /// The editor body's fill: an opaque window background normally, a frosted
    /// material in Glassify. A `@ViewBuilder` (not the `chromePanel` modifier)
    /// because this one is composed with `.ignoresSafeArea(edges:)` at the call
    /// site to keep filling up under the native title bar.
    @ViewBuilder
    var editorPaneBackground: some View {
        if glassify {
            // The editor's actual surface in Glassify: a low-alpha tint of the
            // theme background painted here in SwiftUI (the text stack above is
            // fully transparent — see MarkdownTextView.applyTheme), so it
            // composites cleanly over the window's behind-window blur while
            // keeping enough tint for body text to stay legible.
            Color(nsColor: theme.resolvedBackgroundColor).opacity(0.55)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    var hasAnyInterlinks: Bool {
        !currentBacklinkNotes.isEmpty || !currentForwardLinkedNotes.isEmpty || !currentSuggestedLinks.isEmpty
    }

    var interlinksCount: Int {
        currentBacklinkNotes.count + currentForwardLinkedNotes.count + currentSuggestedLinks.count
    }

    /// Whole-vault totals for the footer: every loaded note (fleeting ones
    /// included; Templates and Trash never load), and the folder count only
    /// when subfolder scanning is on — without it folders don't factor into
    /// Envy at all, so a count would just be noise. Both are O(1) reads of
    /// state that's already maintained.
    var vaultCountsLabel: String {
        let noteCount = store.notes.count
        let notes = "\(noteCount) note\(noteCount == 1 ? "" : "s")"
        guard indexIncludeSubfolders else { return notes }
        let folderCount = subfolderCache.count
        return "\(notes) · \(folderCount) folder\(folderCount == 1 ? "" : "s")"
    }

    private var interlinksExpandedList: some View {
        // Side by side when there's room; falls back to stacked when the pane
        // gets too narrow for readable columns (slim window, or the vertical
        // layout's editor pane). The threshold leaves ~130pt per column for
        // three columns. Width 0 = not yet measured → default to columns.
        let stacked = interlinksWidth > 0 && interlinksWidth < 400
        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) { interlinkColumns }
            } else {
                HStack(alignment: .top, spacing: 20) { interlinkColumns }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { interlinksWidth = $0 }
        .chromeBar(glassify)
    }

    /// The three interlink sections (only the non-empty ones), each an
    /// equal-width, top-aligned column. Shared by both the side-by-side and
    /// stacked arrangements above — the container decides the axis.
    @ViewBuilder
    private var interlinkColumns: some View {
        if !currentForwardLinkedNotes.isEmpty {
            interlinkSection(title: "Links") {
                ForEach(currentForwardLinkedNotes) { linked in
                    interlinkRow(for: linked)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !currentBacklinkNotes.isEmpty {
            interlinkSection(title: "Backlinks") {
                ForEach(currentBacklinkNotes) { linked in
                    interlinkRow(for: linked)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !currentSuggestedLinks.isEmpty {
            interlinkSection(title: "Suggested") {
                ForEach(currentSuggestedLinks) { suggestion in
                    suggestedLinkRow(for: suggestion)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func interlinkSection<Content: View>(title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10 * interfaceFontScale, weight: .semibold))
                .foregroundStyle(.secondary)
            rows()
        }
    }

    /// Shared row for both the "Links" (forward) and "Backlinks" sections —
    /// same navigate/preview behavior either direction, since both are
    /// just "another note this one is connected to."
    private func interlinkRow(for linked: Note) -> some View {
        Button {
            // Same NSEvent.modifierFlags check ContentView+ListPane
            // already uses to distinguish shift/cmd-click on a note
            // row — a plain SwiftUI Button action has no modifier
            // info of its own to inspect otherwise. Only actually
            // means "open the preview instead" in .optionClick
            // trigger mode, and only for a note that isn't already
            // the one open in the main editor (see
            // WikilinkPreviewController.show's own note on why
            // previewing that note specifically is skipped) — every
            // other case, option-click is just an ordinary click
            // that navigates like any other.
            if linkPreviewTrigger == .optionClick, NSEvent.modifierFlags.contains(.option), linked.id != selectedID,
               let anchorView = backlinkAnchorViews[linked.id] {
                showBacklinkPreview(for: linked, anchorView: anchorView)
            } else {
                navigateToNote(titled: linked.title)
            }
        } label: {
            Text(linked.title)
                .font(.system(size: 13 * interfaceFontScale))
                .foregroundStyle(Color(nsColor: theme.resolvedLinkColor))
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            WikilinkAnchorProbe(anchorView: Binding(
                get: { backlinkAnchorViews[linked.id] },
                set: { backlinkAnchorViews[linked.id] = $0 }
            ))
        )
    }

    /// A mentioned-but-unlinked title — clicking "Link" is the only thing
    /// that ever wraps it in "[[...]]"; the row itself doesn't navigate,
    /// since the note doesn't have a real link there yet to follow.
    private func suggestedLinkRow(for suggestion: SuggestedLink) -> some View {
        HStack(spacing: 6) {
            Text(suggestion.title)
                .font(.system(size: 13 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Link") {
                acceptSuggestedLink(suggestion)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10 * interfaceFontScale, weight: .semibold))
            .foregroundStyle(Color(nsColor: theme.resolvedLinkColor))
        }
    }

    /// Same panel WikilinkPreviewController already shows for the editor's
    /// inline wikilinks — just anchored to this row's own probe view
    /// instead of a range within a shared NSTextView. The hit-test for "did
    /// an outside click land back on this exact row" is a plain bounds
    /// check rather than a character-index lookup (there's no shared text
    /// view to disambiguate a position within), and unlike the editor's own
    /// version it requires no modifier at all, matching how a backlink
    /// already navigates on any plain click, not just ⌘-click.
    private func showBacklinkPreview(for linked: Note, anchorView: NSView) {
        backlinkPreviewController.configure(
            store: store,
            theme: theme,
            requireModifierForLinkClick: requireModifierForLinkClick,
            showDuePill: showDuePill,
            showTagsInTitleBar: showTagsInTitleBar,
            noteTitles: noteTitlesByRecencyCache,
            currentlyOpenNoteID: selectedID,
            onNavigate: { [self] title in navigateToNote(titled: title) }
        )
        backlinkPreviewController.show(
            title: linked.title,
            anchorRect: anchorView.bounds,
            in: anchorView,
            shouldNavigateOnOutsideClick: { [weak anchorView] point, _ in
                anchorView?.bounds.contains(point) ?? false
            }
        )
    }

    private func clockString(for date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard showFooterClockDate else { return time }
        return "\(footerClockDateFormat.format(date)) · \(time)"
    }
}

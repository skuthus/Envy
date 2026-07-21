import SwiftUI
import AppKit
import EnvyCore

// The note-list side of the split view: search field (with ghost-text
// completion and operator styling), sort header, the list itself, and the
// template-browsing rows that replace it during a "template:" query.
// Split out of ContentView.swift purely for file size/navigability — same
// type, zero behavior change.

// A dynamic resolver rather than one fixed color — needs to darken the
// outline in Light mode and lighten it in Dark mode, not blend a static
// NSColor the way searchFieldBackground below does (same reasoning:
// resolving inside the closure, at actual draw time, is what tracks
// appearance correctly). Top-level in this file (not a static on
// ContentView) because extensions can't hold static stored properties.
private let searchFieldBorderColor = NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return isDark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.28)
}

extension ContentView {
    var listPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                searchRow
                listSortHeader
            }
            // Opaque, not blurred — an exception to the rest of the window's
            // translucent backdrop so the search/sort chrome (and, via the
            // window's own opaque title bar, everything above it) reads as
            // one solid block instead of fading into whatever's behind it.
            // Deliberately NOT tinted by fileListBackgroundColor — that
            // setting is scoped to the scrollable notes below, not this
            // header, which stays looking like the rest of the window chrome.
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isTemplateQuery {
                            matchingTemplateRows
                        } else if isTrashQuery {
                            matchingTrashRows

                        } else {
                            ForEach(filteredNotes) { note in
                                noteRow(for: note)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: selectedID) { _, newValue in
                    if let newValue {
                        proxy.scrollTo(newValue)
                    }
                }
                // Makes the list itself a real stop for Focus Next/Previous
                // Area, not just something you tap into — arrow keys move the
                // selection the same as they do from the search box, and
                // Return drops straight into the editor.
                .focusable()
                // The system's own default focus ring would otherwise show up
                // here too, on top of the custom border below — and unlike
                // that border, it's drawn by AppKit itself, so it ignores the
                // fade entirely and just sits there permanently.
                .focusEffectDisabled()
                .focused($focusedField, equals: .list)
                .onKeyPress(keys: [.downArrow]) { press in
                    handleListArrowKey(delta: 1, shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(keys: [.upArrow]) { press in
                    handleListArrowKey(delta: -1, shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.return) {
                    // Browsing trash: never acts on its own — Restore/Delete
                    // are always an explicit button or right-click away, so
                    // Return here is intentionally a no-op rather than
                    // mirroring actOnHighlightedTemplate()'s create-on-Return.
                    if isTemplateQuery { actOnHighlightedTemplate() }
                    else if isInboxQuery { focusedField = .editor }
                    else if !isTrashQuery { focusedField = .editor }
                    return .handled
                }
                .focusHighlight(
                    isFocused: focusedField == .list,
                    fadeOut: fadeFocusHighlight,
                    color: Color(nsColor: theme.resolvedFocusHighlightColor),
                    lineWidth: CGFloat(theme.focusHighlightThickness),
                    shape: Rectangle()
                )
            }
            .background(fileListBackground)
            // queryHasExactTitleMatch comes from the background search pass
            // rather than scanning every title here in the body on each
            // keystroke render — it trails typing by the debounce, which
            // for a hint pill is imperceptible.
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && !isSearchOperatorQuery && !queryHasExactTitleMatch {
                Text("Press \u{23CE} to create \"\(query)\"")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
    }

    /// One row in the regular (non-template, non-trash) note list. Pulled
    /// out of listPane's own body — that ForEach's row content, inline,
    /// pushed the whole already-large view body past the type checker's
    /// budget ("unable to type-check this expression in reasonable time"),
    /// the same class of problem FocusHighlight.swift's own split addressed
    /// for EditorViewNotifications.
    @ViewBuilder
    private func noteRow(for note: Note) -> some View {
        NoteRow(note: note, showPreview: showNotePreview, showDateModified: showDateModified, dateDisplayStyle: dateDisplayStyle, sortField: sortField, theme: theme, textColor: theme.fileListTextColor?.color, bold: boldFileListText, isPinned: isPinned(note), isFleeting: store.isInboxNote(note))
            .padding(.vertical, listDensity.rowVerticalPadding)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected(note) ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.shift) {
                    selectRange(to: note)
                } else if NSEvent.modifierFlags.contains(.command) {
                    toggleMultiSelect(note)
                } else {
                    selectSingle(note)
                }
            }
            .contextMenu {
                if fullSelection.count > 1 && fullSelection.contains(note.id) {
                    bulkContextMenuItems
                } else {
                    singleContextMenuItems(for: note)
                }
            }
            .id(note.id)
    }

    /// An opaque fill behind the note list, applying regardless of the blur
    /// strength setting — nil (the default, "no color") shows the window's
    /// own blur/solid backdrop through instead, same as before this setting
    /// existed.
    @ViewBuilder
    private var fileListBackground: some View {
        if let fileListColor = theme.fileListBackgroundColor {
            fileListColor.color
        } else {
            Color.clear
        }
    }

    private var searchField: some View {
        ZStack(alignment: .leading) {
            // The real field has to paint first (bottom of the stack) even
            // though its own text is invisible in the operator-styled case
            // below — its native text-selection highlight is part of that
            // same paint pass, and drawing it *above* the styled/ghost
            // overlay text would blot out the very characters a drag-select
            // is meant to highlight. Underneath, the highlight box still
            // shows through (nothing opaque covers it), it just no longer
            // covers the readable text on top of it.
            TextField("Search or Create Note", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * interfaceFontScale))
                .foregroundColor(isSearchOperatorQuery ? .clear : nil)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            if let suggestionRemainder {
                (Text(query).foregroundColor(.clear) + Text(suggestionRemainder).foregroundColor(.secondary))
                    .font(.system(size: 13 * interfaceFontScale))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            // Only shown (and only makes the real field's own text invisible
            // above) once there's an actual recognized prefix — leaves the
            // common case of an empty field or a plain search completely
            // untouched, including the TextField's native placeholder.
            if isSearchOperatorQuery {
                styledQueryText
                    .font(.system(size: 13 * interfaceFontScale))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .focused($focusedField, equals: .search)
        .onKeyPress(keys: [.downArrow]) { press in
            handleListArrowKey(delta: 1, shiftHeld: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(keys: [.upArrow]) { press in
            handleListArrowKey(delta: -1, shiftHeld: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard suggestionRemainder != nil else { return .ignored }
            completeSuggestion()
            return .handled
        }
        // ⌥⌫ empties the omnibar outright. macOS would ordinarily delete the
        // previous word here, but the omnibar is a command line more than a
        // text field — you're usually abandoning a whole query, not editing
        // one — and ⌘⌫ is already Delete Note, which must not be shadowed by
        // anything that merely clears text.
        .onKeyPress(keys: [.delete]) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            guard !query.isEmpty else { return .handled }
            query = ""
            return .handled
        }
        .onSubmit { handleEnter() }
        .onChange(of: query) { _, _ in
            // Debounced rather than recomputed inline — with several
            // thousand notes even the fast path below is real work, and
            // running it synchronously on every single keystroke was
            // competing with the search field's own text-insertion
            // rendering for the same main-thread frame. 60ms is well under
            // the threshold where typing itself starts to feel delayed,
            // but coalesces anything faster than that (fast typing bursts,
            // rapid backspacing) into one recompute instead of many.
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                // The pipeline itself runs on a background task (see
                // recomputeFilteredNotes) — this await is just sequencing,
                // so the reconciles below read the fresh results.
                await recomputeFilteredNotes()
                guard !Task.isCancelled else { return }
                reconcileSelection()
                reconcileTemplateHighlight()
                reconcileTrashHighlight()
                // The open note's search-match highlighting settles here
                // too, on the same debounce as the results list — see
                // editorSearchQuery's declaration for why the editor never
                // sees the live per-keystroke query.
                editorSearchQuery = query
            }
        }
        // A plain .glassEffect alone reads as barely-there against the
        // search/sort header's own opaque .windowBackgroundColor (see
        // listPane below) — this fill sits behind the glass so the search
        // field is reliably a touch lighter than its surroundings no matter
        // the appearance, blur setting, or file-list color customization,
        // none of which reach this deliberately opaque header area anyway.
        .background(Capsule().fill(searchFieldBackground))
        .glassEffect(.regular, in: Capsule())
        // A resting-state outline — without it the search field barely
        // reads as a distinct control against the header in Light mode,
        // where the lightened fill above and the header's own background
        // are close in value. .separatorColor (the system's own dynamic
        // divider color) was tried first but read as too faint; a fixed
        // black/white blend at a deliberately higher opacity, via the
        // dynamic-resolver-closure pattern, is more pronounced.
        .overlay(Capsule().strokeBorder(Color(nsColor: searchFieldBorderColor), lineWidth: 1.5))
        .focusHighlight(
            isFocused: focusedField == .search,
            fadeOut: fadeFocusHighlight,
            color: Color(nsColor: theme.resolvedFocusHighlightColor),
            lineWidth: CGFloat(theme.focusHighlightThickness),
            shape: Capsule()
        )
    }

    /// The search field and, when anything is waiting, the fleeting-note
    /// count beside it.
    private var searchRow: some View {
        HStack(spacing: 8) {
            // Strictly "something is waiting". With the inbox empty,
            // "inbox:" is just an operator that matches nothing — no
            // different from a tag: search with no hits — so there's nowhere
            // to go back *from*, and clearing the query is the ordinary way
            // out of any query.
            if fleetingCount > 0 { fleetingBadge }
            searchField
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    /// How many notes are sitting in Inbox/ — read from every note rather
    /// than from the filtered list, so the count is the size of the backlog
    /// and not of whatever happens to be on screen.
    var fleetingCount: Int {
        store.notes.reduce(into: 0) { total, note in
            if NoteStore.isInInboxFolder(note) { total += 1 }
        }
    }

    /// The search field's own height, expressed the way the field builds it:
    /// one line of its font plus its vertical padding. Derived rather than
    /// a fixed number so the badge stays a circle at every Interface Text
    /// Size, instead of drifting into an oval at the extremes.
    private var searchControlDiameter: CGFloat { 15.6 * interfaceFontScale + 12 }

    /// The count of fleeting notes, as a circle matching the search field —
    /// same fill, same glass, same border, same height.
    ///
    /// This is the whole reason the inbox can be a filter rather than a mode:
    /// the notes stay out of the way, but the number doesn't, so a backlog
    /// can't quietly accumulate unseen. Hidden entirely at zero — an empty
    /// inbox is the goal state, and a "0" sitting there permanently would
    /// nag about nothing.
    private var fleetingBadge: some View {
        // The same control in two states rather than two controls: in the
        // inbox it's the way out, everywhere else it's the way in. One
        // position, one shape, and the button that got you somewhere is the
        // button that brings you back.
        Button {
            query = isInboxQuery ? "" : "inbox:"
            focusedField = .search
        } label: {
            Group {
                if isInboxQuery {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12 * interfaceFontScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(fleetingCount)")
                        .font(.system(size: 13 * interfaceFontScale, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: theme.resolvedDueSoonColor))
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: searchControlDiameter, minHeight: searchControlDiameter)
            .background(Capsule().fill(searchFieldBackground))
            .glassEffect(.regular, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: searchFieldBorderColor), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(badgeHelp)
    }

    private var badgeHelp: String {
        if isInboxQuery { return "Back to all notes" }
        return fleetingCount == 1
            ? "1 fleeting note waiting — click to review"
            : "\(fleetingCount) fleeting notes waiting — click to review"
    }

    /// A fixed step lighter than the header's own opaque background,
    /// blending toward white rather than picking an absolute light/dark
    /// color — the same fractional blend reads as "a bit lighter" correctly
    /// in both appearances, rather than needing a separate light-mode and
    /// dark-mode constant.
    ///
    /// Wrapped in a dynamic NSColor resolver rather than blending eagerly
    /// here — calling .blended(withFraction:of:) directly on a dynamic
    /// color like .windowBackgroundColor forces it to resolve to a fixed
    /// RGB snapshot immediately, using whatever appearance happens to be
    /// "current" at that exact moment. This property is a plain computed
    /// value evaluated during SwiftUI's render pass, not inside an actual
    /// AppKit drawing context, so that snapshot isn't reliably light-mode
    /// even when the window genuinely is — it showed up as a much-too-dark
    /// search bar in light mode. A resolver closure is only invoked by
    /// AppKit at actual draw time, with the correct appearance already
    /// active, so resolving .windowBackgroundColor and blending it inside
    /// the closure (not before it) is what actually tracks appearance
    /// correctly — same technique AeroSpaceInterop's menuBarOutlineColor
    /// already relies on.
    private var searchFieldBackground: Color {
        Color(nsColor: NSColor(name: nil) { _ in
            NSColor.windowBackgroundColor.blended(withFraction: 0.12, of: .white) ?? NSColor.windowBackgroundColor
        })
    }

    private var listSortHeader: some View {
        HStack(spacing: 0) {
            sortHeaderButton(field: .name, label: "Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            if showDueSort {
                sortHeaderButton(field: .due, label: "Due")
                    .padding(.trailing, 12)
            }
            sortHeaderButton(field: .date, label: "Date")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func sortHeaderButton(field: NoteSortField, label: String) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortFieldRaw = field.rawValue
                sortAscending = field.defaultAscending
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9 * interfaceFontScale, weight: .bold))
                }
            }
            .font(.system(size: 11 * interfaceFontScale, weight: .semibold))
            .foregroundStyle(sortField == field ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Shown in place of the note list while "template:" is typed — click a
    /// row (or arrow through them) just opens it for editing, live and
    /// auto-saving, in the editor pane's own template branch — same
    /// click-to-open feel as a regular note, no separate "Edit Template"
    /// step. "Create Note from Template" is its own deliberate action now
    /// (Return, the button in the editor pane's header, or right-click),
    /// never a side effect of merely opening one to look at it. ⇧-click,
    /// ⌘-click, and ⇧↑/⇧↓ multi-select the same way the regular note list
    /// does, for bulk actions in the context menu.
    @ViewBuilder
    private var matchingTemplateRows: some View {
        ForEach(matchingTemplatesForQuery) { template in
            templateRow(for: template)
        }
        if matchingTemplatesForQuery.isEmpty {
            if let fragment = templateNameFragment?.trimmingCharacters(in: .whitespaces), !fragment.isEmpty {
                Text("Press \u{23CE} to create template \"\(fragment)\"")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                Text("No templates yet — type a name to create one.")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func templateRow(for template: NoteTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .foregroundStyle(.secondary)
            Text(template.name)
                .font(.system(size: 13 * interfaceFontScale))
            Spacer()
        }
        .padding(.vertical, listDensity.rowVerticalPadding)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTemplateSelected(template) ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                selectTemplateRange(to: template)
            } else if NSEvent.modifierFlags.contains(.command) {
                toggleMultiSelectTemplate(template)
            } else {
                selectSingleTemplate(template)
            }
        }
        .contextMenu {
            if fullTemplateSelection.count > 1 && fullTemplateSelection.contains(template.id) {
                bulkTemplateContextMenuItems
            } else {
                Button("Create Note from Template") {
                    createFromTemplate(template, title: template.name)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([template.url])
                }
                Button("Move Back to Notes List") {
                    convertTemplateToNote(template)
                }
                Button("Delete", role: .destructive) {
                    deleteTemplate(template)
                }
            }
        }
    }

    @ViewBuilder
    private var bulkTemplateContextMenuItems: some View {
        let templates = selectedTemplates()
        let count = templates.count
        Button("Create \(count) Notes from Templates") {
            for template in templates {
                createFromTemplate(template, title: template.name)
            }
        }
        Button("Reveal \(count) Templates in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(templates.map(\.url))
        }
        Button("Move \(count) Templates Back to Notes List") {
            for template in templates {
                convertTemplateToNote(template)
            }
            multiSelectedTemplateIDs.removeAll()
        }
        Button("Delete \(count) Templates", role: .destructive) {
            for template in templates {
                deleteTemplate(template)
            }
            multiSelectedTemplateIDs.removeAll()
        }
    }

    /// Shown in place of the note list while "trash:" is typed — click a row
    /// (or arrow keys) just browses, same as the regular note list; clicking
    /// never restores or deletes anything by itself. The highlighted note's
    /// content shows read-only in the editor pane (see trashPreviewPane), and
    /// Restore/Reveal/Delete are always a deliberate right-click or Return
    /// press away, never a side effect of merely looking at something.
    /// ⇧-click, ⌘-click, and ⇧↑/⇧↓ multi-select the same way the regular
    /// note list does.
    @ViewBuilder
    private var matchingTrashRows: some View {
        ForEach(matchingTrashForQuery) { note in
            trashRow(for: note)
        }
        if matchingTrashForQuery.isEmpty {
            Text("Trash is empty.")
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func trashRow(for note: Note) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(note.title)
                .font(.system(size: 13 * interfaceFontScale))
            Spacer()
            Text(dateDisplayStyle.format(note.modifiedDate))
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, listDensity.rowVerticalPadding)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTrashSelected(note) ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                selectTrashRange(to: note)
            } else if NSEvent.modifierFlags.contains(.command) {
                toggleMultiSelectTrash(note)
            } else {
                selectSingleTrash(note)
            }
        }
        .contextMenu {
            if fullTrashSelection.count > 1 && fullTrashSelection.contains(note.id) {
                bulkTrashContextMenuItems
            } else {
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
        }
    }

    @ViewBuilder
    private var bulkTrashContextMenuItems: some View {
        let notes = selectedTrashNotes()
        let count = notes.count
        Button("Restore \(count) Notes") {
            for note in notes {
                restoreFromTrash(note)
            }
            multiSelectedTrashIDs.removeAll()
        }
        Button("Reveal \(count) Notes in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(notes.map(\.url))
        }
        Button("Delete \(count) Notes", role: .destructive) {
            for note in notes {
                deleteFromTrash(note)
            }
            multiSelectedTrashIDs.removeAll()
        }
    }

    // MARK: - Query interpretation

    /// True if any whitespace-separated word in the query is a recognized
    /// search operator — matches NoteStore.filtered(query:), which honors
    /// all of these anywhere in the query (combined with free-text terms
    /// and, since comma-separated groups were added, split across groups
    /// too — but this check works at the word level regardless of which
    /// comma group a word happens to be in, so nothing extra is needed
    /// here for that).
    private var containsSearchOperator: Bool {
        query.split(separator: " ").contains { word in
            let lowered = word.lowercased()
            return lowered.hasPrefix("tag:") || lowered.hasPrefix("date:")
                || lowered.hasPrefix("due:")
                || lowered.hasPrefix("link:") || lowered.hasPrefix("-link:")
                || lowered == "orphan:" || lowered == "linked:"
                || lowered.hasPrefix("-tag:")
                || lowered == "todo:"
                || (lowered.hasPrefix("-") && lowered.count > 1)
        }
    }

    /// "tag:xyz"/"date:xyz" are search operators, not literal titles — Enter
    /// shouldn't offer (or fall back to) creating a note literally named
    /// after the whole query when one's present.
    var isSearchOperatorQuery: Bool {
        containsSearchOperator || isTemplateQuery || isTrashQuery || isInboxQuery
    }

    /// "template:xyz" — like tag:/date:, but a create action rather than a
    /// filter, so unlike them it only counts when it's the query's first
    /// word (not combinable mid-query) and drives creating a note from a
    /// template instead of filtering existing ones.
    var templateNameFragment: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("template:") else { return nil }
        return String(trimmed.dropFirst("template:".count))
    }

    var isTemplateQuery: Bool { templateNameFragment != nil }

    /// Templates whose name contains the typed fragment — an empty
    /// fragment (just "template:" typed so far) matches everything, same
    /// as tag:/date: showing everything until you narrow it.
    var matchingTemplatesForQuery: [NoteTemplate] {
        guard let fragment = templateNameFragment else { return [] }
        let needle = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return availableTemplates }
        return availableTemplates.filter { $0.name.lowercased().contains(needle) }
    }

    /// "trash:xyz" — browses every note currently sitting in one of The
    /// Index's `.trash` subfolders (see NoteStore.trashedNotes), same
    /// query-prefix shape as template:, so you can find, restore, or
    /// permanently delete a trashed note without leaving the search box.
    var trashNameFragment: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("trash:") else { return nil }
        return String(trimmed.dropFirst("trash:".count))
    }

    var isTrashQuery: Bool { trashNameFragment != nil }

    /// "inbox:xyz" — browses fleeting notes waiting in `Inbox/`, same
    /// query-prefix shape as template: and trash:. Unlike those two,
    /// pressing Return on an unmatched fragment *captures* it: the operator
    /// that scopes the box is the one that routes writing into it, so
    /// there's no separate create syntax to learn.
    var inboxNameFragment: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("inbox:") else { return nil }
        return String(trimmed.dropFirst("inbox:".count))
    }

    var isInboxQuery: Bool { inboxNameFragment != nil }

    /// The fleeting notes currently listed — just the filtered list, since
    /// `inbox:` is a real search operator handled in NoteStore.filtered.
    /// Used for picking what to land on after a submit or delete.
    var matchingInboxForQuery: [Note] {
        filteredNotes.filter { store.isInboxNote($0) }
    }

    /// Trashed notes whose title contains the typed fragment — an empty
    /// fragment (just "trash:" typed so far) matches everything, same as
    /// template:'s own fragment filtering.
    var matchingTrashForQuery: [Note] {
        guard let fragment = trashNameFragment else { return [] }
        let needle = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return availableTrashedNotes }
        return availableTrashedNotes.filter { $0.lowercasedTitle.contains(needle) }
    }

    /// The typed query with every recognized operator word dimmed slightly,
    /// to acknowledge it's being read as a command rather than literal
    /// search text — whitespace is preserved exactly as typed, only the
    /// operator/non-operator words differ in styling. Rendered as an
    /// overlay in place of the search TextField's own (made-invisible) text
    /// — see searchField above.
    private var styledQueryText: Text {
        guard containsSearchOperator else { return Text(query) }
        var result = Text("")
        var index = query.startIndex
        while index < query.endIndex {
            if query[index] == " " {
                var end = index
                while end < query.endIndex, query[end] == " " { end = query.index(after: end) }
                result = result + Text(query[index..<end])
                index = end
            } else {
                var end = index
                while end < query.endIndex, query[end] != " " { end = query.index(after: end) }
                let word = query[index..<end]
                let lowered = word.lowercased()
                let isOperator = lowered.hasPrefix("tag:") || lowered.hasPrefix("date:") || lowered.hasPrefix("template:")
                    || lowered.hasPrefix("due:") || lowered.hasPrefix("trash:") || lowered.hasPrefix("inbox:")
                    || lowered.hasPrefix("link:") || lowered.hasPrefix("-link:")
                    || lowered == "orphan:" || lowered == "linked:"
                    || lowered.hasPrefix("-tag:")
                    || lowered == "todo:" || (lowered.hasPrefix("-") && lowered.count > 1)
                result = result + Text(word).foregroundColor(isOperator ? Color.primary.opacity(0.8) : .primary)
                index = end
            }
        }
        return result
    }

    /// The remainder of the cached suggestion (computed in the background
    /// search pass) beyond what's currently typed. Revalidated against the
    /// *live* query — the cache trails typing by the search debounce, so a
    /// character that breaks the prefix match hides the ghost text
    /// immediately instead of showing a stale completion, and a character
    /// that extends the same match shrinks the remainder without waiting.
    /// Tag completion (see tagSuggestionRemainder) takes priority whenever
    /// the query's last word is actually a tag: operator, since a note
    /// title match against the same text wouldn't mean anything there.
    private var suggestionRemainder: String? {
        if let tagRemainder = tagSuggestionRemainder { return tagRemainder }
        guard let note = suggestionNoteCache, !query.isEmpty,
              note.title.count > query.count,
              note.lowercasedTitle.hasPrefix(query.lowercased()) else { return nil }
        let startIndex = note.title.index(note.title.startIndex, offsetBy: query.count)
        return String(note.title[startIndex...])
    }

    /// Whichever operator prefix ("tag:" or "-tag:") the last word currently
    /// being typed starts with, if any, plus whatever's been typed after it
    /// — ghost-text always assumes you're typing at the very end of the
    /// query, same assumption the note-title suggestion above makes, so
    /// only the trailing word is considered, not tag: operators earlier in
    /// a multi-word query.
    private var tagCompletionContext: (prefix: String, fragment: String)? {
        guard let lastWord = query.split(separator: " ").last else { return nil }
        let lowered = lastWord.lowercased()
        for prefix in ["-tag:", "tag:"] {
            if lowered.hasPrefix(prefix) {
                return (prefix, String(lastWord.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// "tag:xyz"/"-tag:xyz" — the tag-name equivalent of the note-title
    /// suggestion, completing against every tag used anywhere in The Index
    /// (see allTagsByFrequencyCache), most-used first when several share a
    /// prefix.
    private var tagSuggestionRemainder: String? {
        guard let (_, fragment) = tagCompletionContext, !fragment.isEmpty else { return nil }
        let lowered = fragment.lowercased()
        guard let match = allTagsByFrequencyCache.first(where: { $0.lowercased().hasPrefix(lowered) && $0.count > fragment.count }) else { return nil }
        return String(match.dropFirst(fragment.count))
    }

    /// Accepts whichever suggestion is currently showing (⇥/→) — replaces
    /// just the trailing word for a tag: completion (preserving any earlier
    /// words in a multi-word query), or the whole query for a note-title
    /// completion, matching how each kind of ghost text is displayed.
    func completeSuggestion() {
        if let (prefix, fragment) = tagCompletionContext, let remainder = tagSuggestionRemainder {
            var words = query.split(separator: " ").map(String.init)
            if !words.isEmpty {
                words[words.count - 1] = prefix + fragment + remainder
            }
            query = words.joined(separator: " ")
            return
        }
        if suggestionRemainder != nil, let note = suggestionNoteCache {
            query = note.title
        }
    }

    /// Column sort is authoritative over the list's order — it applies on
    /// top of (not instead of) the search filter, so typing still narrows
    /// down which notes show up, but the active column always decides the
    /// order they appear in, like Notational Velocity's Name/Date headers.
    /// Static over explicit parameters so the background search pipeline
    /// (ContentView.computeSearch) can run it off the main actor.
    nonisolated static func sortNotes(_ notes: [Note], field: NoteSortField, ascending: Bool) -> [Note] {
        switch field {
        case .name:
            return notes.sorted {
                let result = $0.title.localizedStandardCompare($1.title)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .date:
            return notes.sorted {
                ascending ? $0.modifiedDate < $1.modifiedDate : $0.modifiedDate > $1.modifiedDate
            }
        case .due:
            // A note with no due date always sorts to the end, regardless of
            // direction — "no due date" isn't smaller or larger than an
            // actual date, it's simply absent, and undated notes burying
            // dated ones (or vice versa) depending on which arrow is
            // clicked would be surprising either way.
            return notes.sorted {
                switch ($0.due, $1.due) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return ascending ? a < b : a > b
                }
            }
        }
    }

}

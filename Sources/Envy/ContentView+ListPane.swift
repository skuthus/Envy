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
                searchField
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
                    if isTemplateQuery { actOnHighlightedTemplate() } else if !isTrashQuery { focusedField = .editor }
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
                    .font(.caption)
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
        NoteRow(note: note, showPreview: showNotePreview, showDateModified: showDateModified, dateDisplayStyle: dateDisplayStyle, sortField: sortField, theme: theme, textColor: theme.fileListTextColor?.color, bold: boldFileListText, isPinned: isPinned(note))
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
            if let suggestionRemainder {
                (Text(query).foregroundColor(.clear) + Text(suggestionRemainder).foregroundColor(.secondary))
                    .font(.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            // Only shown (and only makes the real field's own text invisible
            // below) once there's an actual recognized prefix — leaves the
            // common case of an empty field or a plain search completely
            // untouched, including the TextField's native placeholder.
            if isSearchOperatorQuery {
                styledQueryText
                    .font(.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            TextField("Search or Create Note", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundColor(isSearchOperatorQuery ? .clear : nil)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
            guard suggestionRemainder != nil, let note = suggestionNoteCache else { return .ignored }
            query = note.title
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
        .padding(.horizontal, 10)
        .padding(.top, 10)
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
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .font(.caption.weight(.semibold))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                Text("No templates yet — type a name to create one.")
                    .font(.caption)
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
                .font(.caption)
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
            Spacer()
            Text(dateDisplayStyle.format(note.modifiedDate))
                .font(.caption)
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
                || lowered.hasPrefix("-tag:")
                || lowered == "todo:"
                || (lowered.hasPrefix("-") && lowered.count > 1)
        }
    }

    /// "tag:xyz"/"date:xyz" are search operators, not literal titles — Enter
    /// shouldn't offer (or fall back to) creating a note literally named
    /// after the whole query when one's present.
    var isSearchOperatorQuery: Bool {
        containsSearchOperator || isTemplateQuery || isTrashQuery
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
                    || lowered.hasPrefix("due:") || lowered.hasPrefix("trash:")
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
    private var suggestionRemainder: String? {
        guard let note = suggestionNoteCache, !query.isEmpty,
              note.title.count > query.count,
              note.lowercasedTitle.hasPrefix(query.lowercased()) else { return nil }
        let startIndex = note.title.index(note.title.startIndex, offsetBy: query.count)
        return String(note.title[startIndex...])
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

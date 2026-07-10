import SwiftUI
import AppKit
import VelocityCore

enum LayoutMode: String {
    case horizontal
    case vertical
}

enum NoteSortField: String {
    case name
    case date

    /// The direction each field starts in when first selected — matches
    /// Notational Velocity's convention (names A→Z, dates newest first).
    var defaultAscending: Bool {
        switch self {
        case .name: return true
        case .date: return false
        }
    }
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @StateObject private var store = NoteStore(directories: NotesDirectoryPreference.loadEnabled())
    @State private var query = ""
    @State private var selectedID: String?
    /// Extra notes ⌘-selected alongside selectedID, for multi-select bulk
    /// actions (Delete/Move/Open in Finder). selectedID stays the "primary"
    /// selection driving the editor pane and keyboard navigation, unchanged
    /// from before multi-select existed — this is purely additive.
    @State private var multiSelectedIDs: Set<String> = []
    /// The fixed starting point for ⇧-click range selection — set by a plain
    /// click, left alone by ⇧-click itself so repeated ⇧-clicks each
    /// recompute the range from the same anchor rather than chaining from
    /// wherever the previous ⇧-click landed (matching Finder).
    @State private var selectionAnchorID: String?
    @State private var renamingNote: Note?
    @State private var renameText = ""
    @State private var cachedWindowTitle: String?
    @State private var editorWordCount = 0
    @State private var editorCharacterCount = 0
    @State private var isFullScreen = false
    @State private var showLoadingIndicator = false
    @State private var loadingIndicatorTask: Task<Void, Never>?
    @FocusState private var focusedField: FocusField?
    @AppStorage("layoutMode") private var layoutModeRaw = LayoutMode.vertical.rawValue
    @AppStorage("theme") private var theme = Theme()
    @AppStorage("backgroundBlurStrength") private var backgroundBlurStrengthRaw = BlurStrength.strong.rawValue
    @AppStorage("showNotePreview") private var showNotePreview = false
    @AppStorage("showDateModified") private var showDateModified = false
    @AppStorage("dateDisplayStyle") private var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") private var requireModifierForLinkClick = true
    @AppStorage("showEditorTitleHeader") private var showEditorTitleHeader = true
    @AppStorage(NotesDirectoryPreference.storageKey) private var notesDirectoryPathsRaw = ""
    @AppStorage(NotesDirectoryPreference.disabledStorageKey) private var disabledDirectoryPathsRaw = ""
    @AppStorage("hasCreatedWelcomeNote") private var hasCreatedWelcomeNote = false
    @AppStorage("moveFocusToEditorOnEnter") private var moveFocusToEditorOnEnter = true
    @AppStorage("listDensity") private var listDensityRaw = ListDensity.compact.rawValue
    @AppStorage("noteSortField") private var sortFieldRaw = NoteSortField.date.rawValue
    @AppStorage("noteSortAscending") private var sortAscending = false
    @AppStorage("showFooterClock") private var showFooterClock = false
    @AppStorage("showFooterClockDate") private var showFooterClockDate = false
    @AppStorage("footerClockDateFormat") private var footerClockDateFormatRaw = ClockDateFormat.short.rawValue
    @AppStorage("showFooterClockOnlyWhenFullScreen") private var showFooterClockOnlyWhenFullScreen = false
    @AppStorage("editorFontZoom") private var editorFontZoom: Double = 0
    @AppStorage("plainTextMode") private var plainTextMode = false
    @AppStorage("fadeFocusHighlight") private var fadeFocusHighlight = false
    @AppStorage("boldFileListText") private var boldFileListText = false
    // Newline-joined note ids (paths), matching the encoding NotesDirectoryPreference
    // already uses for a list of paths in one AppStorage string.
    @AppStorage("pinnedNotePaths") private var pinnedNotePathsRaw = ""

    private var layoutMode: LayoutMode {
        LayoutMode(rawValue: layoutModeRaw) ?? .horizontal
    }

    private var sortField: NoteSortField {
        NoteSortField(rawValue: sortFieldRaw) ?? .date
    }

    private var dateDisplayStyle: DateDisplayStyle {
        DateDisplayStyle(rawValue: dateDisplayStyleRaw) ?? .smart
    }

    private var listDensity: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .compact
    }

    private var footerClockDateFormat: ClockDateFormat {
        ClockDateFormat(rawValue: footerClockDateFormatRaw) ?? .short
    }

    private var backgroundBlurStrength: BlurStrength {
        BlurStrength(rawValue: backgroundBlurStrengthRaw) ?? .strong
    }

    private var filteredNotes: [Note] {
        NoteStore.applyPinning(sortedNotes(store.filtered(query: query)), pinnedIDs: pinnedNoteIDs)
    }

    private var pinnedNoteIDs: Set<String> {
        Set(pinnedNotePathsRaw.split(separator: "\n").map(String.init))
    }

    private func isPinned(_ note: Note) -> Bool {
        pinnedNoteIDs.contains(note.id)
    }

    private func togglePin(_ note: Note) {
        var ids = pinnedNoteIDs
        if ids.contains(note.id) {
            ids.remove(note.id)
        } else {
            ids.insert(note.id)
        }
        pinnedNotePathsRaw = ids.joined(separator: "\n")
    }

    /// Called wherever a note's id changes out from under it (rename, move)
    /// so a pin doesn't silently vanish just because the underlying path did.
    private func carryPinnedStatus(from oldID: String, to newID: String) {
        guard oldID != newID, pinnedNoteIDs.contains(oldID) else { return }
        var ids = pinnedNoteIDs
        ids.remove(oldID)
        ids.insert(newID)
        pinnedNotePathsRaw = ids.joined(separator: "\n")
    }

    /// True if any whitespace-separated word in the query is a recognized
    /// "tag:"/"date:" operator — matches NoteStore.filtered(query:), which
    /// now honors these anywhere in the query (combined with free-text
    /// terms), not just when the whole query starts with one.
    private var containsSearchOperator: Bool {
        query.split(separator: " ").contains { word in
            let lowered = word.lowercased()
            return lowered.hasPrefix("tag:") || lowered.hasPrefix("date:")
        }
    }

    /// "tag:xyz"/"date:xyz" are search operators, not literal titles — Enter
    /// shouldn't offer (or fall back to) creating a note literally named
    /// after the whole query when one's present.
    private var isSearchOperatorQuery: Bool {
        containsSearchOperator
    }

    /// The typed query with every recognized operator word dimmed slightly,
    /// to acknowledge it's being read as a command rather than literal
    /// search text — whitespace is preserved exactly as typed, only the
    /// operator/non-operator words differ in styling. Rendered as an
    /// overlay in place of the search TextField's own (made-invisible) text
    /// — see searchField below.
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
                let isOperator = lowered.hasPrefix("tag:") || lowered.hasPrefix("date:")
                result = result + Text(word).foregroundColor(isOperator ? Color.primary.opacity(0.8) : .primary)
                index = end
            }
        }
        return result
    }

    /// Column sort is authoritative over the list's order — it applies on
    /// top of (not instead of) the search filter, so typing still narrows
    /// down which notes show up, but the active column always decides the
    /// order they appear in, like Notational Velocity's Name/Date headers.
    private func sortedNotes(_ notes: [Note]) -> [Note] {
        switch sortField {
        case .name:
            return notes.sorted {
                let result = $0.title.localizedStandardCompare($1.title)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        case .date:
            return notes.sorted {
                sortAscending ? $0.modifiedDate < $1.modifiedDate : $0.modifiedDate > $1.modifiedDate
            }
        }
    }

    // Split out of `body` — the full modifier chain in one expression (this
    // plus onAppear/onChange/alert below) got too long for the type checker
    // ("unable to type-check this expression in reasonable time"). Giving
    // this its own `some View`-typed property lets the compiler solve it
    // independently instead of as one combinatorially large expression.
    private var notificationHandledLayout: some View {
        Group {
            switch layoutMode {
            case .horizontal:
                NavigationSplitView {
                    listPane
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                } detail: {
                    editorPane
                }
                // NavigationSplitView auto-adds a leading sidebar-toggle
                // button to the window's toolbar — an unbalanced leading
                // item throws off the title's centering (which is computed
                // relative to the space between leading/trailing toolbar
                // items, not the raw window width).
                .toolbar(removing: .sidebarToggle)
            case .vertical:
                PersistentVSplitView(storageKey: "verticalSplitFraction", defaultTopFraction: 0.6) {
                    listPane
                } bottom: {
                    editorPane
                }
            }
        }
        .background(backgroundView.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .newNoteRequested)) { _ in
            createBlankNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .summonRequested)) { _ in
            focusedField = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedRequested)) { _ in
            deleteSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreDeletedNoteRequested)) { _ in
            restoreLastDeleted()
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePinRequested)) { _ in
            guard let selectedID, let note = store.notes.first(where: { $0.id == selectedID }) else { return }
            togglePin(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleLayoutRequested)) { _ in
            layoutModeRaw = (layoutMode == .horizontal ? LayoutMode.vertical : .horizontal).rawValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomInRequested)) { _ in
            editorFontZoom = min(60, editorFontZoom + 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOutRequested)) { _ in
            editorFontZoom = max(-8, editorFontZoom - 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomResetRequested)) { _ in
            editorFontZoom = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextFolderRequested)) { _ in
            cycleActiveFolder(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .previousFolderRequested)) { _ in
            cycleActiveFolder(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlainTextModeRequested)) { _ in
            plainTextMode.toggle()
        }
        .modifier(FocusAndFullScreenNotifications(
            cycleFocus: cycleFocus,
            isFullScreen: $isFullScreen
        ))
    }

    var body: some View {
        notificationHandledLayout
        .onAppear {
            isFullScreen = NSApp.windows.first?.styleMask.contains(.fullScreen) ?? false
            createWelcomeNoteIfNeeded()
            selectDefaultIfNeeded()
            focusedField = .search
            applyWindowTitleVisibility()
        }
        .onChange(of: notesDirectoryPathsRaw) { _, _ in
            switchNotesDirectories()
        }
        .onChange(of: disabledDirectoryPathsRaw) { _, _ in
            switchNotesDirectories()
        }
        .onChange(of: store.notes) { _, _ in
            // Fires once a reload actually finishes (folder switch, note
            // added/removed/renamed elsewhere, etc.) — falls back to the
            // first note only if the current selection no longer exists in
            // the fresh list, rather than assuming it doesn't.
            reconcileSelection()
        }
        .onChange(of: store.isLoading) { _, isLoading in
            // A fade transition alone didn't stop the flash — a reload that
            // finishes in well under the fade's own duration still visibly
            // flickers the indicator in and back out. The actual fix is not
            // showing it at all unless loading has been running long enough
            // to be worth mentioning; local folder scans almost always
            // finish under this delay, so it normally never appears.
            loadingIndicatorTask?.cancel()
            if isLoading {
                loadingIndicatorTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    showLoadingIndicator = true
                }
            } else {
                showLoadingIndicator = false
            }
        }
        .onChange(of: layoutModeRaw) { _, _ in
            // Horizontal and vertical layouts are structurally different
            // top-level views (NavigationSplitView vs PersistentVSplitView)
            // — swapping between them makes SwiftUI reassert the
            // WindowGroup's own declared title ("Envy") on top of whatever
            // we'd set, same as the reassertion noted in EnvyApp.swift.
            // Deferred a tick so this reapplies after that reassertion,
            // not before it.
            DispatchQueue.main.async {
                applyWindowTitleVisibility()
            }
        }
        .alert("Rename Note", isPresented: Binding(
            get: { renamingNote != nil },
            set: { if !$0 { renamingNote = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let note = renamingNote {
                    renameNote(note, to: renameText)
                }
                renamingNote = nil
            }
            Button("Cancel", role: .cancel) {
                renamingNote = nil
            }
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if let material = backgroundBlurStrength.material {
            VisualEffectBackground(material: material)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
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

    /// A fixed step lighter than the header's own opaque background,
    /// blending toward white rather than picking an absolute light/dark
    /// color — the same fractional blend reads as "a bit lighter" correctly
    /// in both appearances, rather than needing a separate light-mode and
    /// dark-mode constant.
    private var searchFieldBackground: Color {
        let base = NSColor.windowBackgroundColor
        let lightened = base.blended(withFraction: 0.12, of: .white) ?? base
        return Color(nsColor: lightened)
    }

    private var listPane: some View {
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
            if showLoadingIndicator {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading notes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredNotes) { note in
                            NoteRow(note: note, showPreview: showNotePreview, showDateModified: showDateModified, dateDisplayStyle: dateDisplayStyle, textColor: theme.fileListTextColor?.color, bold: boldFileListText, isPinned: isPinned(note))
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
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.return) { focusedField = .editor; return .handled }
                .focusHighlight(
                    isFocused: focusedField == .list,
                    fadeOut: fadeFocusHighlight,
                    color: Color(nsColor: theme.resolvedFocusHighlightColor),
                    lineWidth: CGFloat(theme.focusHighlightThickness),
                    shape: Rectangle()
                )
            }
            .background(fileListBackground)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && !isSearchOperatorQuery && store.exactTitleMatch(for: query) == nil {
                Text("Press \u{23CE} to create \"\(query)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showLoadingIndicator)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            Group {
                if let selectedID, store.notes.contains(where: { $0.id == selectedID }) {
                    NoteEditorView(
                        store: store,
                        noteID: selectedID,
                        focusedField: $focusedField,
                        onNavigate: navigateToNote,
                        onRename: { newTitle in renameSelectedNote(to: newTitle) },
                        theme: theme,
                        requireModifierForLinkClick: requireModifierForLinkClick,
                        searchQuery: query,
                        showTitleHeader: showEditorTitleHeader,
                        fontZoom: CGFloat(editorFontZoom),
                        plainTextMode: plainTextMode,
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
        }
    }

    private var editorFooter: some View {
        HStack {
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
            Spacer()
            if selectedID != nil {
                Text("\(editorWordCount) words, \(editorCharacterCount) characters")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func clockString(for date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard showFooterClockDate else { return time }
        return "\(footerClockDateFormat.format(date)) · \(time)"
    }

    /// The top title-prefix match for the current search text, if any —
    /// what the inline ghost-text completion offers and ⇾ accepts.
    private var suggestionNote: Note? {
        guard !query.isEmpty else { return nil }
        let lowered = query.lowercased()
        return filteredNotes.first {
            $0.title.lowercased().hasPrefix(lowered) && $0.title.count > query.count
        }
    }

    private var suggestionRemainder: String? {
        guard let note = suggestionNote else { return nil }
        let startIndex = note.title.index(note.title.startIndex, offsetBy: query.count)
        return String(note.title[startIndex...])
    }

    private var listSortHeader: some View {
        HStack(spacing: 0) {
            sortHeaderButton(field: .name, label: "Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeaderButton(field: .date, label: "Date")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Non-nil only when there's actually more than one folder configured —
    /// with just a single folder total, scoping isn't a meaningful concept,
    /// so the window title shows no scope suffix at all. Otherwise "All
    /// Notes", or a specific folder's name if scoped to exactly one via
    /// ⌥→/⌥← or unchecking others in Settings.
    private var folderScopeLabel: String? {
        let allDirectories = NotesDirectoryPreference.decode(notesDirectoryPathsRaw)
        guard allDirectories.count > 1 else { return nil }
        let disabled = NotesDirectoryPreference.decodeDisabled(disabledDirectoryPathsRaw)
        let enabled = allDirectories.filter { !disabled.contains($0.path) }
        if enabled.count == 1 {
            return enabled[0].lastPathComponent
        }
        return "All Notes"
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
        // A plain .glassEffect alone reads as barely-there against the
        // search/sort header's own opaque .windowBackgroundColor (see
        // listPane below) — this fill sits behind the glass so the search
        // field is reliably a touch lighter than its surroundings no matter
        // the appearance, blur setting, or file-list color customization,
        // none of which reach this deliberately opaque header area anyway.
        .background(Capsule().fill(searchFieldBackground))
        .glassEffect(.regular, in: Capsule())
        .focusHighlight(
            isFocused: focusedField == .search,
            fadeOut: fadeFocusHighlight,
            color: Color(nsColor: theme.resolvedFocusHighlightColor),
            lineWidth: CGFloat(theme.focusHighlightThickness),
            shape: Capsule()
        )
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .focused($focusedField, equals: .search)
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.rightArrow) {
            guard let suggestionNote else { return .ignored }
            query = suggestionNote.title
            return .handled
        }
        .onSubmit { handleEnter() }
        .onChange(of: query) { _, _ in reconcileSelection() }
    }

    /// Cycles keyboard focus through search → list → editor (and back around),
    /// wrapping in both directions. When nothing is focused yet, "next" lands
    /// on search and "previous" lands on editor, so either direction always
    /// does something sensible from a cold start.
    private func cycleFocus(by direction: Int) {
        let order: [FocusField] = [.search, .list, .editor]
        if let current = focusedField, let currentIndex = order.firstIndex(of: current) {
            let newIndex = (currentIndex + direction + order.count) % order.count
            focusedField = order[newIndex]
        } else {
            focusedField = direction > 0 ? order.first : order.last
        }
    }

    private func moveSelection(_ delta: Int) {
        multiSelectedIDs.removeAll()
        let list = filteredNotes
        guard !list.isEmpty else { return }
        if let currentID = selectedID, let idx = list.firstIndex(where: { $0.id == currentID }) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            selectedID = list[newIdx].id
        } else {
            selectedID = delta > 0 ? list.first?.id : list.last?.id
        }
    }

    private func reconcileSelection() {
        let list = filteredNotes
        if let selectedID, list.contains(where: { $0.id == selectedID }) { return }
        selectedID = list.first?.id
    }

    private var fullSelection: Set<String> {
        multiSelectedIDs.union(selectedID.map { [$0] } ?? [])
    }

    private func isSelected(_ note: Note) -> Bool {
        fullSelection.contains(note.id)
    }

    private func selectSingle(_ note: Note) {
        selectedID = note.id
        multiSelectedIDs.removeAll()
        selectionAnchorID = note.id
    }

    /// ⇧-click range selection — selects every note between the fixed
    /// anchor (see selectionAnchorID) and the clicked note, inclusive, in
    /// the list's current sorted/filtered order. The clicked note becomes
    /// the primary selection driving the editor, matching how ⌘-click
    /// already updates selectedID when it lands on a new note.
    private func selectRange(to note: Note) {
        let list = filteredNotes
        guard let anchorID = selectionAnchorID ?? selectedID,
              let anchorIndex = list.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = list.firstIndex(where: { $0.id == note.id }) else {
            selectSingle(note)
            return
        }
        let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selectedID = note.id
        multiSelectedIDs = Set(list[range].map(\.id)).subtracting([note.id])
    }

    /// Toggles a note's membership in the selection. Demoting the current
    /// primary (selectedID) promotes another selected note to take its place
    /// if one exists, since selectedID always drives the editor pane and
    /// must stay in sync with "is anything selected at all".
    private func toggleMultiSelect(_ note: Note) {
        if note.id == selectedID {
            if let newPrimary = multiSelectedIDs.first {
                multiSelectedIDs.remove(newPrimary)
                selectedID = newPrimary
            } else {
                selectedID = nil
            }
        } else if multiSelectedIDs.contains(note.id) {
            multiSelectedIDs.remove(note.id)
        } else {
            multiSelectedIDs.insert(note.id)
        }
    }

    private func selectDefaultIfNeeded() {
        if selectedID == nil {
            selectedID = store.notes.first?.id
        }
    }

    /// Seeds the default folder with a welcome note (and a small companion note
    /// it links to) the very first time the app launches, and opens it. Gated by
    /// a persisted flag rather than "notes list is empty" so it only ever fires
    /// once, even if the user later deletes every note.
    private func createWelcomeNoteIfNeeded() {
        guard !hasCreatedWelcomeNote else { return }
        hasCreatedWelcomeNote = true

        let linked = store.create(title: WelcomeContent.linkedNoteTitle)
        var linkedWithBody = linked
        linkedWithBody.content = WelcomeContent.linkedNoteBody
        store.save(linkedWithBody)

        let welcome = store.create(title: WelcomeContent.title)
        var welcomeWithBody = welcome
        welcomeWithBody.content = WelcomeContent.welcomeBody
        store.save(welcomeWithBody)

        selectedID = welcome.id
    }

    private func navigateToNote(titled title: String) {
        let target = store.exactTitleMatch(for: title) ?? store.create(title: title)
        selectedID = target.id
        query = ""
    }

    private func handleEnter() {
        // A search operator's "highlighted note" is whatever
        // reconcileSelection() already settled selectedID on as the list
        // narrowed — Enter just moves into it, same as the empty-query case
        // below, rather than falling through to the exact-match/create-new-
        // note logic (which would otherwise create a note literally titled
        // "tag:xyz" or "date:xyz").
        if isSearchOperatorQuery {
            if selectedID != nil, moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }
        if let exact = store.exactTitleMatch(for: query) {
            selectedID = exact.id
            if moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if selectedID != nil, moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }

        let newNote = store.create(title: trimmed)
        selectedID = newNote.id
        query = ""
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    private func createBlankNote() {
        let note = store.create(title: "")
        selectedID = note.id
        query = ""
        focusedField = .editor
    }

    private func deleteSelected() {
        if fullSelection.count > 1 {
            bulkDelete()
            return
        }
        guard let currentID = selectedID, let note = store.notes.first(where: { $0.id == currentID }) else { return }
        deleteNote(note)
    }

    private func deleteNote(_ note: Note) {
        store.delete(note)
        if selectedID == note.id {
            selectedID = filteredNotes.first?.id
        }
        focusedField = .search
    }

    private func otherDirectories(for note: Note) -> [URL] {
        let currentDirectory = note.url.deletingLastPathComponent()
        return store.noteDirectories.filter { $0 != currentDirectory }
    }

    @ViewBuilder
    private func singleContextMenuItems(for note: Note) -> some View {
        Button(isPinned(note) ? "Unpin Note" : "Pin Note") {
            togglePin(note)
        }
        Button("Rename") {
            renameText = note.title
            renamingNote = note
        }
        Button("Open in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([note.url])
        }
        let otherFolders = otherDirectories(for: note)
        if !otherFolders.isEmpty {
            Menu("Move to Folder") {
                ForEach(otherFolders, id: \.self) { directory in
                    Button(directory.lastPathComponent) {
                        moveNote(note, to: directory)
                    }
                }
            }
        }
        Button("Delete", role: .destructive) {
            deleteNote(note)
        }
    }

    @ViewBuilder
    private var bulkContextMenuItems: some View {
        let count = fullSelection.count
        Button("Open \(count) Notes in Finder") {
            bulkOpenInFinder()
        }
        if !store.noteDirectories.isEmpty {
            Menu("Move \(count) Notes to Folder") {
                ForEach(store.noteDirectories, id: \.self) { directory in
                    Button(directory.lastPathComponent) {
                        bulkMove(to: directory)
                    }
                }
            }
        }
        Button("Delete \(count) Notes", role: .destructive) {
            bulkDelete()
        }
    }

    private func selectedNotes() -> [Note] {
        let ids = fullSelection
        return store.notes.filter { ids.contains($0.id) }
    }

    private func bulkOpenInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedNotes().map(\.url))
    }

    /// Moved notes get new ids (Note.id is the file path), so the old
    /// selection can't carry over meaningfully — just clear it.
    private func bulkMove(to directory: URL) {
        for note in selectedNotes() {
            let moved = store.move(note, to: directory)
            carryPinnedStatus(from: note.id, to: moved.id)
        }
        multiSelectedIDs.removeAll()
        selectedID = nil
    }

    private func bulkDelete() {
        // A single call so the whole selection is recorded as one delete
        // action — restoring afterward brings back every note, not just
        // the last one a loop of individual deletes would have remembered.
        store.delete(selectedNotes())
        multiSelectedIDs.removeAll()
        selectedID = filteredNotes.first?.id
        focusedField = .search
    }

    private func restoreLastDeleted() {
        let restored = store.restoreLastDeleted()
        guard let first = restored.first else { return }
        if restored.count == 1 {
            selectedID = first.id
        }
        focusedField = .search
    }

    private func moveNote(_ note: Note, to directory: URL) {
        let moved = store.move(note, to: directory)
        carryPinnedStatus(from: note.id, to: moved.id)
        if selectedID == note.id {
            selectedID = moved.id
        }
    }

    private func renameNote(_ note: Note, to newTitle: String) {
        let renamed = store.rename(note, to: newTitle)
        carryPinnedStatus(from: note.id, to: renamed.id)
        if selectedID == note.id {
            selectedID = renamed.id
        }
    }

    private func renameSelectedNote(to newTitle: String) {
        guard let currentID = selectedID, let note = store.notes.first(where: { $0.id == currentID }) else { return }
        renameNote(note, to: newTitle)
    }

    private func switchNotesDirectories() {
        let allDirectories = NotesDirectoryPreference.decode(notesDirectoryPathsRaw)
        let disabled = NotesDirectoryPreference.decodeDisabled(disabledDirectoryPathsRaw)
        let enabledDirectories = allDirectories.filter { !disabled.contains($0.path) }
        // Falls back to the full list rather than letting NoteStore's own
        // "no directories" handling silently switch to an unrelated default
        // folder if every configured folder happens to be disabled.
        store.setDirectories(enabledDirectories.isEmpty ? allDirectories : enabledDirectories)
        query = ""
        // Deliberately NOT touching selectedID here: setDirectories() reloads
        // asynchronously, so store.notes at this exact point is still the
        // *previous* folder's notes — picking .first from it here would grab
        // a note that's about to disappear. Keeping the current selection
        // (still valid until the reload actually replaces store.notes) means
        // the editor keeps showing it right up until the swap, instead of a
        // premature flash to "No Note Selected" and back. The onChange(of:
        // store.notes) below reconciles it once the new notes actually land.
        focusedField = .search
        applyWindowTitleVisibility()
    }

    /// Reuses the enable/disable checkboxes from Settings rather than a
    /// separate transient "view filter" — cycling enables exactly one
    /// folder (or all of them) and disables the rest, persisting like any
    /// other checkbox change. "All Folders" is itself one of the stops in
    /// the cycle (state 0), sitting between the last folder and the first —
    /// so cycling forward from "all" goes to folder 1, and cycling forward
    /// from the last folder wraps back around to "all", same the other way.
    /// If the current enabled set doesn't match any single stop exactly
    /// (e.g. an arbitrary subset checked by hand in Settings), treats that
    /// as "all" rather than guessing which folder was meant.
    private func cycleActiveFolder(by direction: Int) {
        let allDirectories = NotesDirectoryPreference.decode(notesDirectoryPathsRaw)
        guard allDirectories.count > 1 else { return }
        let disabled = NotesDirectoryPreference.decodeDisabled(disabledDirectoryPathsRaw)
        let enabledDirectories = allDirectories.filter { !disabled.contains($0.path) }

        let stateCount = allDirectories.count + 1 // 0 = all folders, 1...N = single folder N-1
        let currentState: Int
        if enabledDirectories.count == 1, let index = allDirectories.firstIndex(where: { $0.path == enabledDirectories[0].path }) {
            currentState = index + 1
        } else {
            currentState = 0
        }

        let newState = (currentState + direction + stateCount) % stateCount

        if newState == 0 {
            disabledDirectoryPathsRaw = ""
        } else {
            let target = allDirectories[newState - 1]
            let newDisabled = Set(allDirectories.map(\.path)).subtracting([target.path])
            disabledDirectoryPathsRaw = NotesDirectoryPreference.encodeDisabled(newDisabled)
        }
    }

    /// Blanks the title text rather than toggling titleVisibility — with a
    /// unified/fullSizeContentView toolbar, .hidden makes AppKit recompute the
    /// toolbar's space distribution and the trailing items visibly jump toward
    /// center. Keeping the title slot reserved (just empty) avoids that.
    private func applyWindowTitleVisibility() {
        guard let window = NSApp.windows.first else { return }
        if cachedWindowTitle == nil {
            cachedWindowTitle = window.title.isEmpty ? "Envy" : window.title
        }
        window.titleVisibility = .visible
        // Shown *alone*, not appended after "Envy —": AppKit centers the
        // title string as a whole, so prefixing it with a fixed "Envy —"
        // pushed the actually-meaningful part (the scope name) off to the
        // right of true center instead of centering it.
        window.title = folderScopeLabel ?? cachedWindowTitle ?? "Envy"
    }
}

/// Split out of ContentView's body purely to keep the compiler's type-checking
/// time reasonable — too many chained `.onReceive` modifiers in one expression
/// has repeatedly hit "unable to type-check in reasonable time" as more were
/// added, and splitting into a separate modifier lets the compiler solve this
/// batch independently of the rest.
private struct FocusAndFullScreenNotifications: ViewModifier {
    let cycleFocus: (Int) -> Void
    @Binding var isFullScreen: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .focusNextAreaRequested)) { _ in
                cycleFocus(1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusPreviousAreaRequested)) { _ in
                cycleFocus(-1)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
                guard (note.object as? NSWindow) === NSApp.windows.first else { return }
                isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                guard (note.object as? NSWindow) === NSApp.windows.first else { return }
                isFullScreen = false
            }
    }
}

/// Draws a stroked border around whichever pane currently has keyboard focus
/// (search box or editor). With "Fade out focus highlight" off, it just
/// tracks focus directly — on while focused, off the moment focus leaves.
/// With it on, the border appears the same way but fades away on its own
/// after a moment, so it reads as a brief "you're here now" cue rather than
/// a persistent outline around wherever the cursor happens to be.
private struct FocusHighlight<S: Shape>: ViewModifier {
    let isFocused: Bool
    let fadeOut: Bool
    let color: Color
    let lineWidth: CGFloat
    let shape: S

    @State private var visible = false
    @State private var fadeTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(shape.stroke(color, lineWidth: lineWidth).opacity(visible ? 1 : 0))
            .onChange(of: isFocused) { _, focused in
                fadeTask?.cancel()
                if focused {
                    withAnimation(.easeInOut(duration: 0.15)) { visible = true }
                    if fadeOut {
                        fadeTask = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { visible = false }
                        }
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { visible = false }
                }
            }
    }
}

private extension View {
    func focusHighlight<S: Shape>(isFocused: Bool, fadeOut: Bool, color: Color, lineWidth: CGFloat, shape: S) -> some View {
        modifier(FocusHighlight(isFocused: isFocused, fadeOut: fadeOut, color: color, lineWidth: lineWidth, shape: shape))
    }
}

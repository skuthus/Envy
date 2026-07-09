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
    @State private var renamingNote: Note?
    @State private var renameText = ""
    @State private var cachedWindowTitle: String?
    @State private var editorWordCount = 0
    @State private var editorCharacterCount = 0
    @State private var isFullScreen = false
    @State private var showLoadingIndicator = false
    @State private var loadingIndicatorTask: Task<Void, Never>?
    @FocusState private var focusedField: FocusField?
    @AppStorage("layoutMode") private var layoutModeRaw = LayoutMode.horizontal.rawValue
    @AppStorage("theme") private var theme = Theme()
    @AppStorage("backgroundBlurStrength") private var backgroundBlurStrengthRaw = BlurStrength.strong.rawValue
    @AppStorage("showNotePreview") private var showNotePreview = false
    @AppStorage("showDateModified") private var showDateModified = false
    @AppStorage("dateDisplayStyle") private var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") private var requireModifierForLinkClick = true
    @AppStorage("showEditorTitleHeader") private var showEditorTitleHeader = true
    @AppStorage("showWindowTitle") private var showWindowTitle = true
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
        sortedNotes(store.filtered(query: query))
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === NSApp.windows.first else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === NSApp.windows.first else { return }
            isFullScreen = false
        }
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
        .onChange(of: showWindowTitle) { _, _ in
            applyWindowTitleVisibility()
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
                            NoteRow(note: note, showPreview: showNotePreview, showDateModified: showDateModified, dateDisplayStyle: dateDisplayStyle)
                                .padding(.vertical, listDensity.rowVerticalPadding)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected(note) ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) {
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
            }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && store.exactTitleMatch(for: query) == nil {
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
            TextField("Search or Create Note", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .glassEffect(.regular, in: Capsule())
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
            store.move(note, to: directory)
        }
        multiSelectedIDs.removeAll()
        selectedID = nil
    }

    private func bulkDelete() {
        for note in selectedNotes() {
            store.delete(note)
        }
        multiSelectedIDs.removeAll()
        selectedID = filteredNotes.first?.id
        focusedField = .search
    }

    private func moveNote(_ note: Note, to directory: URL) {
        let moved = store.move(note, to: directory)
        if selectedID == note.id {
            selectedID = moved.id
        }
    }

    private func renameNote(_ note: Note, to newTitle: String) {
        let renamed = store.rename(note, to: newTitle)
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
        // A folder scope shows regardless of "Show app title in window
        // bar" — it's live state the user asked to be able to see, not
        // decoration. Shown *alone*, not appended after "Envy —": AppKit
        // centers the title string as a whole, so prefixing it with a
        // fixed "Envy —" pushed the actually-meaningful part (the scope
        // name) off to the right of true center instead of centering it.
        if let scopeLabel = folderScopeLabel {
            window.title = scopeLabel
        } else {
            window.title = showWindowTitle ? (cachedWindowTitle ?? "Envy") : ""
        }
    }
}

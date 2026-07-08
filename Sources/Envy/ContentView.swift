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
    @StateObject private var store = NoteStore(directories: NotesDirectoryPreference.load())
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
    @AppStorage("hasCreatedWelcomeNote") private var hasCreatedWelcomeNote = false
    @AppStorage("moveFocusToEditorOnEnter") private var moveFocusToEditorOnEnter = true
    @AppStorage("listDensity") private var listDensityRaw = ListDensity.compact.rawValue
    @AppStorage("noteSortField") private var sortFieldRaw = NoteSortField.date.rawValue
    @AppStorage("noteSortAscending") private var sortAscending = false

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

    var body: some View {
        Group {
            switch layoutMode {
            case .horizontal:
                NavigationSplitView {
                    listPane
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                } detail: {
                    editorPane
                }
            case .vertical:
                PersistentVSplitView(storageKey: "verticalSplitFraction", defaultTopFraction: 0.6) {
                    listPane
                } bottom: {
                    editorPane
                }
            }
        }
        .background(backgroundView.ignoresSafeArea())
        .toolbar { toolbarContent }
        .onReceive(NotificationCenter.default.publisher(for: .newNoteRequested)) { _ in
            createBlankNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .summonRequested)) { _ in
            focusedField = .search
        }
        .onAppear {
            createWelcomeNoteIfNeeded()
            selectDefaultIfNeeded()
            focusedField = .search
            applyWindowTitleVisibility()
        }
        .onChange(of: notesDirectoryPathsRaw) { _, newRaw in
            switchNotesDirectories(to: newRaw)
        }
        .onChange(of: showWindowTitle) { _, _ in
            applyWindowTitleVisibility()
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
            searchField
            listSortHeader
            Divider()
            if store.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading notes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)
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
    }

    private var editorPane: some View {
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
                    showTitleHeader: showEditorTitleHeader
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
        .background(alignment: .bottom) {
            // A fade instead of a flat fill so the bar doesn't read as a
            // hard-edged block sitting right under the search capsule. The
            // gradient is taller than the header itself and bottom-aligned,
            // so most of its run bleeds up above the header — a long, slow
            // fade rather than a short one crammed into the header's own
            // ~30pt height — while still landing at full tint right at the
            // divider below.
            LinearGradient(
                colors: [Color.clear, Color(nsColor: .controlBackgroundColor).opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 70)
        }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                createBlankNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }

            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(selectedID == nil)

            Button {
                layoutModeRaw = (layoutMode == .horizontal ? LayoutMode.vertical : .horizontal).rawValue
            } label: {
                Label(
                    "Toggle Layout",
                    systemImage: layoutMode == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2"
                )
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
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

    private func switchNotesDirectories(to raw: String) {
        let directories = NotesDirectoryPreference.decode(raw)
        store.setDirectories(directories)
        query = ""
        selectedID = store.notes.first?.id
        focusedField = .search
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
        window.title = showWindowTitle ? (cachedWindowTitle ?? "Envy") : ""
    }
}

import SwiftUI
import AppKit
import VelocityCore

enum LayoutMode: String {
    case horizontal
    case vertical
}

struct ContentView: View {
    @StateObject private var store = NoteStore(directories: NotesDirectoryPreference.load())
    @State private var query = ""
    @State private var selectedID: String?
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

    private var layoutMode: LayoutMode {
        LayoutMode(rawValue: layoutModeRaw) ?? .horizontal
    }

    private var dateDisplayStyle: DateDisplayStyle {
        DateDisplayStyle(rawValue: dateDisplayStyleRaw) ?? .smart
    }

    private var backgroundBlurStrength: BlurStrength {
        BlurStrength(rawValue: backgroundBlurStrengthRaw) ?? .strong
    }

    private var filteredNotes: [Note] {
        store.filtered(query: query)
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
            List(filteredNotes, selection: $selectedID) { note in
                NoteRow(note: note, showPreview: showNotePreview, showDateModified: showDateModified, dateDisplayStyle: dateDisplayStyle)
                    .contextMenu {
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
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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
        .padding(10)
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

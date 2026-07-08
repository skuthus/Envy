import SwiftUI
import VelocityCore

struct NoteEditorView: View {
    @ObservedObject var store: NoteStore
    let noteID: String
    var focusedField: FocusState<FocusField?>.Binding
    var onNavigate: (String) -> Void
    var onRename: (String) -> Void
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var searchQuery: String
    var showTitleHeader: Bool
    var fontZoom: CGFloat
    var onStatsChange: (Int, Int) -> Void

    @State private var content: String
    @State private var saveTask: Task<Void, Never>?
    @State private var titleText: String
    @FocusState private var isTitleFocused: Bool

    private var note: Note? {
        store.notes.first { $0.id == noteID }
    }

    init(
        store: NoteStore,
        noteID: String,
        focusedField: FocusState<FocusField?>.Binding,
        onNavigate: @escaping (String) -> Void,
        onRename: @escaping (String) -> Void,
        theme: Theme,
        requireModifierForLinkClick: Bool,
        searchQuery: String,
        showTitleHeader: Bool,
        fontZoom: CGFloat,
        onStatsChange: @escaping (Int, Int) -> Void
    ) {
        self.store = store
        self.noteID = noteID
        self.focusedField = focusedField
        self.onNavigate = onNavigate
        self.onRename = onRename
        self.theme = theme
        self.requireModifierForLinkClick = requireModifierForLinkClick
        self.searchQuery = searchQuery
        self.showTitleHeader = showTitleHeader
        self.fontZoom = fontZoom
        self.onStatsChange = onStatsChange
        // Seeded here rather than in .onAppear: with .id(noteID) forcing a
        // fresh instance per note, .onAppear runs AFTER the first body
        // evaluation (and thus after MarkdownTextView's makeNSView already
        // read the default ""), so anything set in .onAppear would arrive
        // too late for the text view to ever pick up.
        let initialNote = store.notes.first { $0.id == noteID }
        _content = State(initialValue: initialNote?.content ?? "")
        _titleText = State(initialValue: initialNote?.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTitleHeader {
                header
                Divider()
            }
            MarkdownTextView(
                text: $content,
                onNavigate: onNavigate,
                theme: theme,
                requireModifierForLinkClick: requireModifierForLinkClick,
                searchQuery: searchQuery,
                fontZoom: fontZoom
            )
            .focusable()
            .focused(focusedField, equals: .editor)
        }
        .onAppear { onStatsChange(wordCount, characterCount) }
        .onChange(of: content) { _, newValue in
            scheduleSave(newValue)
            onStatsChange(wordCount, characterCount)
        }
    }

    private var header: some View {
        HStack {
            TextField("Title", text: $titleText)
                .font(.headline)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($isTitleFocused)
                .onSubmit { commitRename() }
                .onChange(of: isTitleFocused) { _, focused in
                    if !focused { commitRename() }
                }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func commitRename() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note?.title else {
            titleText = note?.title ?? ""
            return
        }
        onRename(trimmed)
    }

    private var wordCount: Int {
        content.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var characterCount: Int {
        content.count
    }

    private func scheduleSave(_ newValue: String) {
        guard let note, newValue != note.content else { return }
        saveTask?.cancel()
        var updated = note
        updated.content = newValue
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.save(updated)
        }
    }
}

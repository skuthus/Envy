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

    @State private var content: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var titleText: String = ""
    @FocusState private var isTitleFocused: Bool

    private var note: Note? {
        store.notes.first { $0.id == noteID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTitleHeader {
                header
                Divider()
            }
            MarkdownTextView(
                text: $content,
                noteID: noteID,
                onNavigate: onNavigate,
                focusedField: focusedField,
                theme: theme,
                requireModifierForLinkClick: requireModifierForLinkClick,
                searchQuery: searchQuery
            )
        }
        .onAppear {
            content = note?.content ?? ""
            titleText = note?.title ?? ""
        }
        .onChange(of: noteID) { _, _ in
            content = note?.content ?? ""
            titleText = note?.title ?? ""
        }
        .onChange(of: content) { _, newValue in scheduleSave(newValue) }
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
            Text("\(wordCount) words, \(characterCount) characters")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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

import SwiftUI
import AppKit
import EnvyCore

/// Live-markdown editing for a template file, embedded directly in the same
/// editor pane a note uses (not a sheet) — reuses the same MarkdownTextView
/// every note uses, but writes straight to the template's own .md file on
/// disk rather than through NoteStore, since a template is deliberately
/// never one of the notes NoteStore tracks.
struct TemplateEditorView: View {
    @Environment(\.interfaceFontScale) private var interfaceFontScale
    @ObservedObject var store: NoteStore
    let template: NoteTemplate
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var fontZoom: CGFloat
    var plainTextMode: Bool
    var noteTitles: [String]
    var focusedField: FocusState<FocusField?>.Binding
    var onDone: () -> Void
    var onCreateNote: () -> Void
    /// Renaming moves the file, so the caller has to re-point at it — a
    /// template's id is its path.
    var onRenamed: (URL) -> Void

    @State private var content: String
    @State private var saveTask: Task<Void, Never>?
    /// The title is a filename, so editing it renames the file — same
    /// click-to-edit interaction as a note's own title bar.
    @State private var titleText: String
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool

    init(
        store: NoteStore,
        template: NoteTemplate,
        theme: Theme,
        requireModifierForLinkClick: Bool,
        fontZoom: CGFloat,
        plainTextMode: Bool,
        noteTitles: [String],
        focusedField: FocusState<FocusField?>.Binding,
        onDone: @escaping () -> Void,
        onCreateNote: @escaping () -> Void,
        onRenamed: @escaping (URL) -> Void
    ) {
        self.store = store
        self.template = template
        self.theme = theme
        self.requireModifierForLinkClick = requireModifierForLinkClick
        self.fontZoom = fontZoom
        self.plainTextMode = plainTextMode
        self.noteTitles = noteTitles
        self.focusedField = focusedField
        self.onDone = onDone
        self.onCreateNote = onCreateNote
        self.onRenamed = onRenamed
        _content = State(initialValue: (try? String(contentsOf: template.url, encoding: .utf8)) ?? "")
        _titleText = State(initialValue: template.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            MarkdownTextView(
                text: $content,
                onNavigate: { _ in },
                theme: theme,
                requireModifierForLinkClick: requireModifierForLinkClick,
                searchQuery: "",
                fontZoom: fontZoom,
                plainTextMode: plainTextMode,
                noteTitles: noteTitles
            )
            .focusable()
            .focused(focusedField, equals: .editor)
        }
        .onChange(of: content) { _, newValue in scheduleSave(newValue) }
        .onDisappear { flushSave() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if isEditingTitle {
                    TextField("Template name", text: $titleText)
                        .font(.system(size: 13 * interfaceFontScale, weight: .semibold))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($isTitleFocused)
                        .onSubmit { commitRename() }
                        .onChange(of: isTitleFocused) { _, focused in
                            guard !focused else { return }
                            commitRename()
                        }
                        .onAppear { isTitleFocused = true }
                } else {
                    Text(titleText)
                        .font(.system(size: 13 * interfaceFontScale, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                        .onTapGesture { isEditingTitle = true }
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            Text("Template")
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
            Button("Create Note from Template") {
                flushSave()
                onCreateNote()
            }
            Button {
                flushSave()
                onDone()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Deselect this template")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Writes pending edits first: the rename moves the file, and a
    /// debounced save landing afterwards would recreate the old path.
    private func commitRename() {
        isEditingTitle = false
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            titleText = template.name
            return
        }
        guard trimmed != template.name else { return }
        flushSave()
        guard let moved = store.renameFile(at: template.url, to: trimmed) else {
            titleText = template.name
            return
        }
        titleText = moved.deletingPathExtension().lastPathComponent
        onRenamed(moved)
    }

    private func scheduleSave(_ newValue: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.suppressReloadForExternalWrite()
            try? newValue.write(to: template.url, atomically: true, encoding: .utf8)
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        store.suppressReloadForExternalWrite()
        try? content.write(to: template.url, atomically: true, encoding: .utf8)
    }
}

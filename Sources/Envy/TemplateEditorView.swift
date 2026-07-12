import SwiftUI
import AppKit
import EnvyCore

/// Live-markdown editing for a template file, embedded directly in the same
/// editor pane a note uses (not a sheet) — reuses the same MarkdownTextView
/// every note uses, but writes straight to the template's own .md file on
/// disk rather than through NoteStore, since a template is deliberately
/// never one of the notes NoteStore tracks.
struct TemplateEditorView: View {
    @ObservedObject var store: NoteStore
    let template: NoteTemplate
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var showTitleHeader: Bool
    var fontZoom: CGFloat
    var plainTextMode: Bool
    var noteTitles: [String]
    var focusedField: FocusState<FocusField?>.Binding
    var onDone: () -> Void

    @State private var content: String
    @State private var saveTask: Task<Void, Never>?

    init(
        store: NoteStore,
        template: NoteTemplate,
        theme: Theme,
        requireModifierForLinkClick: Bool,
        showTitleHeader: Bool,
        fontZoom: CGFloat,
        plainTextMode: Bool,
        noteTitles: [String],
        focusedField: FocusState<FocusField?>.Binding,
        onDone: @escaping () -> Void
    ) {
        self.store = store
        self.template = template
        self.theme = theme
        self.requireModifierForLinkClick = requireModifierForLinkClick
        self.showTitleHeader = showTitleHeader
        self.fontZoom = fontZoom
        self.plainTextMode = plainTextMode
        self.noteTitles = noteTitles
        self.focusedField = focusedField
        self.onDone = onDone
        _content = State(initialValue: (try? String(contentsOf: template.url, encoding: .utf8)) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTitleHeader {
                header
                Divider()
            }
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
            Text(template.name)
                .font(.headline)
            Text("Template")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
            Button {
                flushSave()
                onDone()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop editing this template")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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

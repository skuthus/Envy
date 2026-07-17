import SwiftUI
import AppKit
import EnvyCore

/// The content of an inline embed ("![[Note Title]]") — reuses
/// MarkdownTextView directly, the same reasoning as
/// WikilinkPreviewContentView: one live-editing/auto-save code path for
/// "show another note's content and let me click into it," not a separate
/// read-only renderer that has to be kept in sync with the real one.
///
/// Starts non-editable and flips to editable on first click (via
/// MarkdownTextView's own onRequestEditable — the same mechanism the
/// wikilink preview popover already relies on), so scrolling past an embed
/// while reading the host note can never accidentally start typing into a
/// different file.
///
/// Resolved by title, not a pre-fetched Note — the title is all
/// MarkdownStyler.embedRanges(in:noteTitles:) ever has (a pure
/// text→attributes function with no NoteStore dependency), and
/// re-resolving here on every body evaluation is what makes "the source
/// was renamed" or "the source doesn't exist yet" both just fall out of
/// the normal lookup instead of needing their own separate handling.
struct EmbeddedNoteView: View {
    @ObservedObject var store: NoteStore
    let title: String
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var noteTitles: [String]
    /// True when this embed's title resolves to the very note this
    /// MarkdownTextView chain is itself already showing (currentNoteID) —
    /// rendering a second live, independently-editable copy of the exact
    /// buffer you're already typing in risks two competing debounced saves
    /// silently discarding each other, the same race
    /// WikilinkPreviewController.show(...) already guards against for the
    /// option-click preview. Shows an explanatory message in place of the
    /// editor instead.
    var isCurrentlyOpenElsewhere: Bool
    /// Whether the body (the live embedded editor, or the "already open"/
    /// "not found" message in its place) is hidden, leaving just this
    /// header row — plain ephemeral UI state, not saved anywhere. Owned by
    /// MarkdownTextView.Coordinator rather than as @State here, since the
    /// reserved space in the *host* note's own text (collapsedEmbedHeight
    /// vs. embedHeight) also depends on it, and that's decided in
    /// MarkdownStyler.style(), which runs before this view even exists.
    var isCollapsed: Bool
    var onNavigate: (String) -> Void
    var onToggleCollapse: () -> Void

    @State private var isEditable = false
    @State private var content: String
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSyncedContent: String

    private var note: Note? {
        store.exactTitleMatch(for: title)
    }

    init(
        store: NoteStore,
        title: String,
        theme: Theme,
        requireModifierForLinkClick: Bool,
        noteTitles: [String],
        isCurrentlyOpenElsewhere: Bool,
        isCollapsed: Bool,
        onNavigate: @escaping (String) -> Void,
        onToggleCollapse: @escaping () -> Void
    ) {
        self.store = store
        self.title = title
        self.theme = theme
        self.requireModifierForLinkClick = requireModifierForLinkClick
        self.noteTitles = noteTitles
        self.isCurrentlyOpenElsewhere = isCurrentlyOpenElsewhere
        self.isCollapsed = isCollapsed
        self.onNavigate = onNavigate
        self.onToggleCollapse = onToggleCollapse
        let initial = store.exactTitleMatch(for: title)
        _content = State(initialValue: initial?.content ?? "")
        _lastSyncedContent = State(initialValue: initial?.content ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    onToggleCollapse()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand" : "Collapse")
                Text(note?.title ?? title)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let note else { return }
                        onNavigate(note.title)
                    }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if !isCollapsed {
                Divider()
                if isCurrentlyOpenElsewhere {
                    Spacer(minLength: 0)
                    Text("Already open above")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                } else if note != nil {
                    MarkdownTextView(
                        text: $content,
                        onNavigate: onNavigate,
                        theme: theme,
                        requireModifierForLinkClick: requireModifierForLinkClick,
                        searchQuery: "",
                        isEditable: isEditable,
                        onRequestEditable: { isEditable = true },
                        noteTitles: noteTitles,
                        allowsEmbeds: false,
                        allowsScrollPassthrough: true
                    )
                } else {
                    Spacer(minLength: 0)
                    Text("Note not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer(minLength: 0)
                }
            }
        }
        .background(Color(nsColor: theme.resolvedBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onChange(of: content) { _, newValue in
            guard isEditable, newValue != lastSyncedContent else { return }
            scheduleSave(newValue)
        }
        // The "always current" half of transclusion — if the source note
        // changed elsewhere (another embed of it, an edit made directly, an
        // outside app) while this embed isn't the one being typed into,
        // pull the fresh content in rather than keep showing what it looked
        // like when this view last mounted. Skipped while isEditable to
        // avoid yanking text out from under an in-progress edit, same
        // reasoning NoteEditorView's own external-reload handling relies on.
        .onChange(of: note?.content) { _, newValue in
            guard !isEditable, let newValue, newValue != content else { return }
            content = newValue
            lastSyncedContent = newValue
        }
        // updateEmbedOverlays pools NSHostingView<EmbeddedNoteView> by
        // index and reassigns rootView with a new title as the host text
        // changes — SwiftUI keeps this view's @State alive across that
        // reassignment (same identity, just new input values), so without
        // an explicit reset here `content` would keep showing whatever
        // note the *previous* title resolved to. Reacting to note?.content
        // alone isn't enough: two different notes can happen to share
        // identical content, which wouldn't register as a change there.
        .onChange(of: title) { _, newTitle in
            saveTask?.cancel()
            isEditable = false
            let resolved = store.exactTitleMatch(for: newTitle)
            content = resolved?.content ?? ""
            lastSyncedContent = resolved?.content ?? ""
        }
    }

    private func scheduleSave(_ newValue: String) {
        guard let note else { return }
        saveTask?.cancel()
        var updated = note
        updated.content = newValue
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.save(updated)
            lastSyncedContent = updated.content
        }
    }
}

import SwiftUI
import AppKit
import EnvyCore

struct NoteEditorView: View {
    @ObservedObject var store: NoteStore
    let noteID: String
    var focusedField: FocusState<FocusField?>.Binding
    var onNavigate: (String) -> Void
    var onRename: (String) -> Void
    var onTagSearch: (String) -> Void
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var searchQuery: String
    var showTitleHeader: Bool
    var showTagsInTitleBar: Bool
    var fontZoom: CGFloat
    var plainTextMode: Bool
    /// Passed in (ContentView caches it) rather than derived from `store`
    /// here — building it inline meant an O(n log n) sort plus a title copy
    /// per note inside this body, which re-evaluates on every
    /// keystroke-triggered render.
    var noteTitles: [String]
    var onStatsChange: (Int, Int) -> Void

    @State private var content: String
    @State private var saveTask: Task<Void, Never>?
    @State private var titleText: String
    @FocusState private var isTitleFocused: Bool
    /// The content value this view last knew to be in sync with the store
    /// (either what we saved, or what we last pulled in from an external
    /// change). Comparing `content` against this — rather than directly
    /// against `note?.content` — is what lets us tell "the store just caught
    /// up with what I typed" apart from "someone else changed this note out
    /// from under me while I have unsaved edits pending."
    @State private var lastSyncedContent: String
    /// Bumped only when an external change is actually pushed into `content`,
    /// so MarkdownTextView knows to replace its NSTextView's text instead of
    /// treating `content` as just an echo of the user's own typing.
    @State private var externalReloadToken = 0
    /// The range (within the newly-adopted content) that an external edit
    /// actually changed, waiting to be flashed. Set the moment the change is
    /// detected, but not necessarily shown yet — see the didBecomeActive
    /// handling below for why.
    @State private var pendingHighlightRange: NSRange?
    /// Bumped only once we're sure the user can actually see the flash (the
    /// app is active), so a change that arrives while Envy is backgrounded
    /// doesn't burn its brief highlight before anyone's looking.
    @State private var highlightTrigger = 0

    private var note: Note? {
        store.notes.first { $0.id == noteID }
    }

    init(
        store: NoteStore,
        noteID: String,
        focusedField: FocusState<FocusField?>.Binding,
        onNavigate: @escaping (String) -> Void,
        onRename: @escaping (String) -> Void,
        onTagSearch: @escaping (String) -> Void,
        theme: Theme,
        requireModifierForLinkClick: Bool,
        searchQuery: String,
        showTitleHeader: Bool,
        showTagsInTitleBar: Bool,
        fontZoom: CGFloat,
        plainTextMode: Bool,
        noteTitles: [String],
        onStatsChange: @escaping (Int, Int) -> Void
    ) {
        self.store = store
        self.noteID = noteID
        self.focusedField = focusedField
        self.onNavigate = onNavigate
        self.onRename = onRename
        self.onTagSearch = onTagSearch
        self.theme = theme
        self.requireModifierForLinkClick = requireModifierForLinkClick
        self.searchQuery = searchQuery
        self.showTitleHeader = showTitleHeader
        self.showTagsInTitleBar = showTagsInTitleBar
        self.fontZoom = fontZoom
        self.plainTextMode = plainTextMode
        self.noteTitles = noteTitles
        self.onStatsChange = onStatsChange
        // Seeded here rather than in .onAppear: with .id(noteID) forcing a
        // fresh instance per note, .onAppear runs AFTER the first body
        // evaluation (and thus after MarkdownTextView's makeNSView already
        // read the default ""), so anything set in .onAppear would arrive
        // too late for the text view to ever pick up.
        let initialNote = store.notes.first { $0.id == noteID }
        _content = State(initialValue: initialNote?.content ?? "")
        _lastSyncedContent = State(initialValue: initialNote?.content ?? "")
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
                fontZoom: fontZoom,
                plainTextMode: plainTextMode,
                noteTitles: noteTitles,
                externalReloadToken: externalReloadToken,
                highlightRange: pendingHighlightRange,
                highlightTrigger: highlightTrigger
            )
            .focusable()
            .focused(focusedField, equals: .editor)
        }
        .onAppear {
            onStatsChange(wordCount, characterCount)
        }
        .onChange(of: content) { _, newValue in
            scheduleSave(newValue)
            onStatsChange(wordCount, characterCount)
        }
        // Fires when the note's on-disk content changed outside this view —
        // another app editing the same file, or a folder-level reload. Our
        // own edits also flow through here once the debounced save in
        // scheduleSave lands: usually `content` still equals the saved
        // value (first guard, no-op), and if the user has already typed
        // further inside the delivery gap, lastSyncedContent was updated at
        // save time (see scheduleSave), so the second guard correctly reads
        // the situation as local-edits-in-flight rather than adopting our
        // own echo as if it were an external change.
        .onChange(of: note?.content) { _, newContent in
            guard let newContent, newContent != content else {
                if let newContent { lastSyncedContent = newContent }
                return
            }
            // We have unsaved local edits in flight (content has already
            // diverged from the last value we know the store agreed on) —
            // don't clobber what's being typed. Our own pending save will
            // land shortly and become the new store value.
            guard content == lastSyncedContent else { return }
            pendingHighlightRange = MarkdownStyler.changedRange(from: content, to: newContent)
            content = newContent
            lastSyncedContent = newContent
            externalReloadToken += 1
            // Already looking at Envy right now — flash immediately rather
            // than waiting for an activation that isn't coming.
            if NSApp.isActive {
                fireHighlight()
            }
        }
        // Only fires the flash once the user can actually see it. A change
        // that arrived while Envy was backgrounded already has its range
        // waiting in pendingHighlightRange from the moment it was detected
        // above — this is just the signal that it's now safe to show it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard pendingHighlightRange != nil else { return }
            fireHighlight()
        }
    }

    /// Bumps the trigger MarkdownTextView watches, then clears the pending
    /// range on the next runloop turn — not immediately, since that would
    /// race with this same update delivering the range and the bumped
    /// trigger to MarkdownTextView together. Clearing it here (rather than
    /// leaving it set) is what stops every *later* app activation from
    /// re-firing the same flash for a change that's already been shown once.
    private func fireHighlight() {
        highlightTrigger += 1
        DispatchQueue.main.async {
            pendingHighlightRange = nil
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
                .foregroundStyle(theme.noteTitleBarTextColor?.color ?? Color.primary)
            Spacer()
            if showTagsInTitleBar, let note, !note.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(note.tags.sorted(), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption.bold())
                            .foregroundStyle(Color(nsColor: theme.resolvedTagColor))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: theme.resolvedTagBackgroundColor))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                            .onTapGesture { onTagSearch(tag) }
                    }
                }
                // A long content edit can add/remove tags on every keystroke
                // (each debounced save updates `note`) — animating that
                // would make the title bar visibly jitter while typing.
                .transaction { $0.animation = nil }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            if let color = theme.noteTitleBarBackgroundColor?.color {
                color
            } else {
                Rectangle().fill(.bar)
            }
        }
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
            // Recorded at the moment the store adopts our value — in the
            // same main-actor turn, before any later keystroke can run.
            // The onChange(of: note?.content) echo of this save is
            // delivered by SwiftUI a render pass *later*, and if the user
            // edits again inside that gap (a fast backspace after typing,
            // an immediate re-click of a checkbox), the old comparison
            // there ("store value differs from content, and content still
            // matches the last agreed value") misread our own echo as an
            // external file edit and pushed the just-deleted text back
            // into the editor. With lastSyncedContent already equal to the
            // echo's value by then, that check correctly sees the newer
            // local edit as unsaved work in flight and leaves it alone.
            lastSyncedContent = updated.content
        }
    }
}

import SwiftUI
import AppKit
import EnvyCore

/// Hosted in the resizable panel EnvyApp shows when the menu bar icon is
/// clicked with "Show Pinned Note" selected — a quick-glance/quick-edit view
/// of one note, without opening the full app window. Deliberately reads and
/// saves the file directly (not through NoteStore) rather than standing up
/// a second *live* NoteStore instance just for this one note: NoteStore
/// lives inside ContentView, out of reach of EnvyApp's AppDelegate, and a
/// second ongoing instance watching the same folder would be needless
/// complexity for something this self-contained. Renaming is the one
/// exception — that reuses a short-lived NoteStore purely for its already-
/// correct unique-filename logic (see commitRename() below), not because
/// this view needs an ongoing NoteStore of its own. Any edit made here
/// still lands on disk exactly like a normal save, so the main app (if
/// open) picks it up through its own existing external-change detection,
/// same as an edit from any other app.
struct PinnedNotePopoverView: View {
    var onOpenInApp: () -> Void

    @AppStorage("theme") private var theme = Theme()
    @AppStorage("requireModifierForLinkClick") private var requireModifierForLinkClick = true
    @AppStorage("plainTextMode") private var plainTextMode = false
    /// Deliberately its own setting rather than sharing the main editor's
    /// editorFontZoom — this popup is small and cramped by nature, so it's
    /// reasonable to want it running a bigger zoom than the main window
    /// without that also bumping the main editor's own text size.
    @AppStorage("menuBarPopoverFontZoom") private var fontZoom: Double = 0
    // Named distinctly from menuBarPinnedNotePath (which note the popup
    // shows) — this is a different "pin," about keeping the open popup
    // window itself on top instead of closing on the next outside click.
    // Read directly off the same UserDefaults key by EnvyApp's AppDelegate
    // (windowDidResignKey) to decide whether to actually close the panel.
    @AppStorage("menuBarPopoverPinnedOpen") private var isPinnedOpen = false
    // Same key EnvyApp/GeneralSettingsView/ContentView all read — kept in
    // sync here too so a rename doesn't leave the pin pointing at a file
    // that no longer exists.
    @AppStorage("menuBarPinnedNotePath") private var menuBarPinnedNotePath = ""

    /// Where the note actually lives right now — starts as the URL this
    /// view was created with, but a rename moves the underlying file, so
    /// this needs to be mutable state (not a fixed `let`) for saves made
    /// after a rename to land in the right place.
    @State private var url: URL
    @State private var titleText: String
    @FocusState private var isTitleFocused: Bool

    @State private var content: String
    @State private var saveTask: Task<Void, Never>?
    @State private var loadFailed: Bool
    /// The content value this view last knew to be saved — comparing
    /// against this (not a fixed "did it change since load" flag) means a
    /// save only actually fires for a real edit, not for the state update
    /// that seeds the initial load.
    @State private var lastSyncedContent: String

    init(url: URL, onOpenInApp: @escaping () -> Void) {
        self.onOpenInApp = onOpenInApp
        _url = State(initialValue: url)
        _titleText = State(initialValue: url.deletingPathExtension().lastPathComponent)
        // Seeded here rather than loaded in .onAppear — NoteEditorView hit
        // this same bug once already (see its own init): .onAppear runs
        // after the first body evaluation, by which point
        // MarkdownTextView's makeNSView has already read `content`'s
        // default value and set the real NSTextView's text from it. With
        // content seeded to "" and no later mechanism forcing the text view
        // to reload (MarkdownTextView only re-pushes `text` into the
        // NSTextView when its own externalReloadToken changes, which this
        // view was never bumping), the popover showed permanently blank
        // regardless of the file's real contents — and typing into that
        // blank buffer, then saving, silently overwrote the real note with
        // just what got typed. Reading synchronously here instead means the
        // very first render already has the right text.
        if let loaded = try? String(contentsOf: url, encoding: .utf8) {
            _content = State(initialValue: loaded)
            _lastSyncedContent = State(initialValue: loaded)
            _loadFailed = State(initialValue: false)
        } else {
            _content = State(initialValue: "")
            _lastSyncedContent = State(initialValue: "")
            _loadFailed = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                // No visible controls for this — ⌘+/⌘-/⌘0 already cover it,
                // same shortcuts as the main editor's own zoom. These stay
                // as real (zero-size, invisible) buttons rather than a
                // bare .onKeyPress or similar, since .keyboardShortcut on a
                // Button is what actually registers a menu-bar-level key
                // equivalent that works regardless of which subview
                // currently has first responder focus — exactly what's
                // needed here since MarkdownTextView's own NSTextView is
                // usually what's focused while typing.
                Group {
                    Button("") { fontZoom = max(-6, fontZoom - 1) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("") { fontZoom = 0 }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("") { fontZoom = min(24, fontZoom + 1) }
                        .keyboardShortcut("+", modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                Button {
                    isPinnedOpen.toggle()
                } label: {
                    Image(systemName: isPinnedOpen ? "pin.fill" : "pin")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isPinnedOpen ? Color.accentColor : .primary)
                .help(isPinnedOpen ? "Keeping this window open — click to let it close when you click elsewhere" : "Keep this window open and on top, even when you click elsewhere")
                Button {
                    onOpenInApp()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Envy")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()

            if loadFailed {
                ContentUnavailableView("Note Not Found", systemImage: "doc.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownTextView(
                    text: $content,
                    onNavigate: { _ in onOpenInApp() },
                    theme: theme,
                    requireModifierForLinkClick: requireModifierForLinkClick,
                    searchQuery: "",
                    fontZoom: CGFloat(fontZoom),
                    plainTextMode: plainTextMode
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel's real title bar is hidden (titleVisibility = .hidden,
        // transparent) but its .fullSizeContentView style still leaves
        // SwiftUI reserving a title-bar-height safe-area inset at the top,
        // so this view's own content was rendering pushed down below an
        // invisible gap that had nothing to do with the header's own
        // padding. Ignoring the safe area here lets the header sit flush
        // at the very top instead.
        .ignoresSafeArea(edges: .top)
        .onChange(of: content) { _, newValue in
            guard newValue != lastSyncedContent else { return }
            scheduleSave(newValue)
        }
    }

    /// Renames the underlying file by reusing NoteStore.rename(_:to:) from
    /// a throwaway instance scoped to just this note's own folder — same
    /// unique-filename and file-move logic the main app's own rename uses,
    /// rather than re-implementing collision handling here. Keeps
    /// menuBarPinnedNotePath pointed at the right file afterward — without
    /// that, the pin would silently start referring to a path that no
    /// longer exists the moment the file moved.
    @MainActor
    private func commitRename() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTitle = url.deletingPathExtension().lastPathComponent
        guard !trimmed.isEmpty, trimmed != currentTitle else {
            titleText = currentTitle
            return
        }
        let scratchStore = NoteStore(directories: [url.deletingLastPathComponent()])
        let note = Note(id: url.path, url: url, content: content, modifiedDate: Date())
        let renamed = scratchStore.rename(note, to: trimmed)
        guard renamed.url != url else {
            // Rename failed (e.g. a file-system error, or a name collision
            // rename() itself couldn't resolve) — revert the displayed text
            // rather than leaving it out of sync with the actual filename.
            titleText = currentTitle
            return
        }
        if menuBarPinnedNotePath == url.path {
            menuBarPinnedNotePath = renamed.url.path
        }
        url = renamed.url
        titleText = renamed.title
    }

    private func scheduleSave(_ newValue: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? newValue.write(to: url, atomically: true, encoding: .utf8)
            lastSyncedContent = newValue
        }
    }
}

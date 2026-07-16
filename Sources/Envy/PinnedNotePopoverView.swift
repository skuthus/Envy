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
    /// Whether the title is currently showing as an editable TextField —
    /// otherwise it's the truncated, hover-to-scroll label below. Tapping
    /// the label switches to editing; losing focus switches back.
    @State private var isEditingTitle = false

    @State private var content: String
    @State private var saveTask: Task<Void, Never>?
    @State private var loadFailed: Bool
    /// The content value this view last knew to be saved — comparing
    /// against this (not a fixed "did it change since load" flag) means a
    /// save only actually fires for a real edit, not for the state update
    /// that seeds the initial load.
    @State private var lastSyncedContent: String
    /// Where the cursor was last known to be, restored on load instead of
    /// always landing at the top — this view is fully torn down and
    /// recreated on every reopen (see showPinnedNotePanel in EnvyApp), so
    /// this can't just live in memory the way it would for a view that
    /// stays alive across closes.
    @State private var initialSelectedRange: NSRange?
    /// Feeds the wiki-link ghost-text autocomplete in the embedded editor —
    /// this view deliberately has no live NoteStore (see the type's own doc
    /// comment), so rather than standing one up just for this, it's a plain
    /// one-time directory listing of the pinned note's own sibling `.md`
    /// files, read synchronously at init the same way `content` above is.
    private let noteTitles: [String]

    private static func cursorStorageKey(for url: URL) -> String {
        "pinnedNoteCursorLocation:\(url.path)"
    }

    private static func siblingNoteTitles(of url: URL) -> [String] {
        let directory = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    init(url: URL, onOpenInApp: @escaping () -> Void) {
        self.onOpenInApp = onOpenInApp
        self.noteTitles = Self.siblingNoteTitles(of: url)
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
            let savedLocation = UserDefaults.standard.object(forKey: Self.cursorStorageKey(for: url)) as? Int
            if let savedLocation, savedLocation <= (loaded as NSString).length {
                _initialSelectedRange = State(initialValue: NSRange(location: savedLocation, length: 0))
            } else {
                _initialSelectedRange = State(initialValue: nil)
            }
        } else {
            _content = State(initialValue: "")
            _lastSyncedContent = State(initialValue: "")
            _loadFailed = State(initialValue: true)
            _initialSelectedRange = State(initialValue: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if isEditingTitle {
                    TextField("Title", text: $titleText)
                        .font(.headline)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($isTitleFocused)
                        .onSubmit {
                            commitRename()
                            isEditingTitle = false
                        }
                        .onChange(of: isTitleFocused) { _, focused in
                            guard !focused else { return }
                            commitRename()
                            isEditingTitle = false
                        }
                        .onAppear { isTitleFocused = true }
                } else {
                    // Truncated-with-hover-scroll display rather than just
                    // handing this straight to the TextField's own natural
                    // clipping — the ask was specifically a fixed 25-character
                    // limit at rest (not "however many characters happen to
                    // fit"), with the rest revealed by scrolling on hover
                    // rather than growing the popup or wrapping.
                    HoverScrollingTitleLabel(text: titleText)
                        .contentShape(Rectangle())
                        .onTapGesture { isEditingTitle = true }
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
                    plainTextMode: plainTextMode,
                    noteTitles: noteTitles,
                    initialSelectedRange: initialSelectedRange,
                    onSelectionChange: { range in
                        UserDefaults.standard.set(range.location, forKey: Self.cursorStorageKey(for: url))
                    }
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
        let scratchStore = NoteStore(directory: url.deletingLastPathComponent())
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

/// Shows only the first `visibleCharacterLimit` characters of `text` plus
/// "…" at rest; hovering scrolls the full text across so the rest becomes
/// readable, then resets once the mouse leaves. Styled to match a SwiftUI
/// `.headline` label specifically (both the `.font(.headline)` applied to
/// the visible Text and the NSFont used to measure scroll distance) —
/// not a general-purpose reusable label for arbitrary fonts.
private struct HoverScrollingTitleLabel: View {
    let text: String
    var visibleCharacterLimit: Int = 25

    @State private var isHovering = false
    @State private var scrollOffset: CGFloat = 0

    // Matches the semibold weight/size .headline actually renders at
    // closely enough for a scroll-distance estimate — this doesn't need
    // pixel-perfect precision, just enough that the small "+6" safety
    // margin below reliably clears the last character past the clip edge.
    private static let measuringFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    private var truncated: String {
        guard text.count > visibleCharacterLimit else { return text }
        return String(text.prefix(visibleCharacterLimit)) + "…"
    }

    var body: some View {
        // Pinned to the truncated string's own measured width rather than
        // left to fill whatever leftover space the header HStack hands it
        // (usually wider than 25 characters actually need) — otherwise
        // swapping the displayed Text from `truncated` to the full `text`
        // on hover immediately filled that leftover space with real
        // characters before the scroll animation below even started,
        // instead of revealing them by scrolling.
        //
        // +2 past the raw measurement: measuredWidth uses a plain NSFont
        // approximation of .headline (see measuringFont's own comment on
        // why this can't be exact), and without this margin that estimate
        // occasionally landed a hair narrower than SwiftUI's actual
        // .headline layout — clipped() then sliced off the last character
        // of the title, even well under the 25-character truncation point.
        let boxWidth = Self.measuredWidth(of: truncated) + 2
        GeometryReader { proxy in
            Text(isHovering ? text : truncated)
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: scrollOffset)
                .onChange(of: isHovering) { _, hovering in
                    guard hovering else {
                        withAnimation(.easeOut(duration: 0.2)) { scrollOffset = 0 }
                        return
                    }
                    // A few extra points past the exact measured overflow so
                    // the very last character clears the clipped edge instead
                    // of stopping flush against it.
                    let overflow = Self.measuredWidth(of: text) - proxy.size.width + 6
                    guard overflow > 0 else { return }
                    withAnimation(.linear(duration: Double(overflow) / 40).delay(0.2)) {
                        scrollOffset = -overflow
                    }
                }
        }
        // .headline isn't a fixed point size, but this is close enough for
        // a decorative scroll label; it doesn't need to be exact the way
        // the scroll distance above does.
        .frame(width: boxWidth, height: 18)
        .clipped()
        .onHover { isHovering = $0 }
    }

    private static func measuredWidth(of string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: measuringFont]).width
    }
}

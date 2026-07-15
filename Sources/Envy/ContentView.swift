import SwiftUI
import AppKit
import EnvyCore

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

// ContentView's members deliberately sit at internal (not private) access:
// the type is split across several files (ContentView+ListPane, +EditorPane,
// +Selection, +Actions) purely for navigability, and extensions in other
// files can't see private members. This file holds the state and the
// top-level body; everything else lives with its pane/concern.
struct ContentView: View {
    @Environment(\.openSettings) var openSettings
    @Environment(\.openWindow) var openWindow
    @StateObject var store = NoteStore(directories: NotesDirectoryPreference.loadEnabled())
    @State var query = ""
    @State var selectedID: String?
    /// Extra notes ⌘-selected alongside selectedID, for multi-select bulk
    /// actions (Delete/Move/Open in Finder). selectedID stays the "primary"
    /// selection driving the editor pane and keyboard navigation, unchanged
    /// from before multi-select existed — this is purely additive.
    @State var multiSelectedIDs: Set<String> = []
    /// The fixed starting point for ⇧-click range selection — set by a plain
    /// click, left alone by ⇧-click itself so repeated ⇧-clicks each
    /// recompute the range from the same anchor rather than chaining from
    /// wherever the previous ⇧-click landed (matching Finder).
    @State var selectionAnchorID: String?
    @State var renamingNote: Note?
    @State var renameText = ""
    @State var cachedWindowTitle: String?
    @State var editorWordCount = 0
    @State var editorCharacterCount = 0
    @State var backlinksExpanded = false
    @State var isFullScreen = false
    @State var showLoadingIndicator = false
    @State var loadingIndicatorTask: Task<Void, Never>?
    @State var searchDebounceTask: Task<Void, Never>?
    @FocusState var focusedField: FocusField?
    @AppStorage("layoutMode") var layoutModeRaw = LayoutMode.vertical.rawValue
    @AppStorage("theme") var theme = Theme()
    @AppStorage("backgroundBlurStrength") var backgroundBlurStrengthRaw = BlurStrength.strong.rawValue
    @AppStorage("showNotePreview") var showNotePreview = false
    @AppStorage("showDateModified") var showDateModified = true
    @AppStorage("dateDisplayStyle") var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") var requireModifierForLinkClick = true
    @AppStorage("showEditorTitleHeader") var showEditorTitleHeader = true
    @AppStorage("showTagsInTitleBar") var showTagsInTitleBar = false
    @AppStorage(NotesDirectoryPreference.storageKey) var notesDirectoryPathsRaw = ""
    @AppStorage(NotesDirectoryPreference.disabledStorageKey) var disabledDirectoryPathsRaw = ""
    @AppStorage("hasCreatedWelcomeNote") var hasCreatedWelcomeNote = false
    @AppStorage("lastSeenWhatsNewVersion") var lastSeenWhatsNewVersion = ""
    @AppStorage("moveFocusToEditorOnEnter") var moveFocusToEditorOnEnter = true
    @AppStorage("listDensity") var listDensityRaw = ListDensity.compact.rawValue
    @AppStorage("noteSortField") var sortFieldRaw = NoteSortField.date.rawValue
    @AppStorage("noteSortAscending") var sortAscending = false
    @AppStorage("showFooterClock") var showFooterClock = false
    @AppStorage("showFooterClockDate") var showFooterClockDate = false
    @AppStorage("footerClockDateFormat") var footerClockDateFormatRaw = ClockDateFormat.short.rawValue
    @AppStorage("showFooterClockOnlyWhenFullScreen") var showFooterClockOnlyWhenFullScreen = false
    @AppStorage("editorFontZoom") var editorFontZoom: Double = 0
    @AppStorage("plainTextMode") var plainTextMode = false
    @AppStorage("fadeFocusHighlight") var fadeFocusHighlight = false
    @AppStorage("boldFileListText") var boldFileListText = false
    @AppStorage("showBacklinks") var showBacklinks = true
    @AppStorage("restoreFocusOnSummon") var restoreFocusOnSummon = true
    @AppStorage("templatesScope") var templatesScopeRaw = TemplatesScope.global.rawValue
    @AppStorage("templateDateFormatPattern") var templateDateFormatPattern = TemplateDateFormat.defaultPattern
    @AppStorage("hasSeededSampleTemplates") var hasSeededSampleTemplates = false
    @State var editingTemplate: NoteTemplate?
    @State var highlightedTemplateID: String?
    // Newline-joined note ids (paths), matching the encoding NotesDirectoryPreference
    // already uses for a list of paths in one AppStorage string.
    @AppStorage("pinnedNotePaths") var pinnedNotePathsRaw = ""
    // Read directly off UserDefaults by EnvyApp's AppDelegate too (an
    // NSObject, not a SwiftUI view, so it can't use @AppStorage) when
    // deciding what a menu bar click should do — same key, same value.
    @AppStorage("menuBarPinnedNotePath") var menuBarPinnedNotePath = ""

    var layoutMode: LayoutMode {
        LayoutMode(rawValue: layoutModeRaw) ?? .horizontal
    }

    var sortField: NoteSortField {
        NoteSortField(rawValue: sortFieldRaw) ?? .date
    }

    var dateDisplayStyle: DateDisplayStyle {
        DateDisplayStyle(rawValue: dateDisplayStyleRaw) ?? .smart
    }

    var listDensity: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .compact
    }

    var footerClockDateFormat: ClockDateFormat {
        ClockDateFormat(rawValue: footerClockDateFormatRaw) ?? .short
    }

    var backgroundBlurStrength: BlurStrength {
        BlurStrength(rawValue: backgroundBlurStrengthRaw) ?? .strong
    }

    var templatesScope: TemplatesScope {
        TemplatesScope(rawValue: templatesScopeRaw) ?? .global
    }

    var availableTemplates: [NoteTemplate] {
        store.templates(includeAllFolders: templatesScope == .perFolder)
    }

    /// The text {{date}} in a template (title or body) actually gets
    /// substituted with — computed fresh each use so it's always today.
    var templateDateText: String {
        TemplateDateFormat.string(from: Date(), pattern: templateDateFormatPattern)
    }

    // filteredNotes used to be a plain computed property, re-running
    // store.filtered(query:) (an O(notes) scan) plus a full sort over
    // however many notes matched, from scratch, on *every* SwiftUI
    // re-render of ContentView — not just when query/notes/sort/pins
    // actually changed, but on every unrelated one too (selection,
    // hover, focus, scrolling). With a few thousand notes that turned
    // typing and scrolling both sluggish. Cached here instead, and only
    // recomputed by recomputeFilteredNotes() from the handful of
    // .onChange hooks below that cover everything the pipeline actually
    // depends on.
    @State var filteredNotesCache: [Note] = []

    var filteredNotes: [Note] { filteredNotesCache }

    /// The ghost-text completion and "Press ↩ to create" state for the
    /// current results — computed in the same background pass as the
    /// results themselves. Both used to be O(notes) scans in the search
    /// field's body on every keystroke render.
    @State var suggestionNoteCache: Note?
    @State var queryHasExactTitleMatch = false
    @State private var searchComputeGeneration = 0

    struct SearchComputation: Sendable {
        var notes: [Note]
        var suggestion: Note?
        var hasExactTitleMatch: Bool
    }

    /// The whole search pipeline — filter, rank-sort, pinning, plus the
    /// suggestion/exact-match extras — over an immutable snapshot, so it
    /// can run on a background task. With a large library this is real
    /// work (the first typed character matches nearly everything, so the
    /// early keystrokes are the *most* expensive), and running it on the
    /// main actor — even debounced — stalled the keystrokes queued behind
    /// it. The main thread now only assigns the finished result.
    nonisolated static func computeSearch(
        notes: [Note],
        query: String,
        pinnedIDs: Set<String>,
        sortField: NoteSortField,
        sortAscending: Bool
    ) -> SearchComputation {
        let filtered = NoteStore.filtered(notes, query: query)
        let sorted = sortNotes(filtered, field: sortField, ascending: sortAscending)
        let pinned = NoteStore.applyPinning(sorted, pinnedIDs: pinnedIDs)

        var suggestion: Note?
        if !query.isEmpty {
            let lowered = query.lowercased()
            suggestion = pinned.first { $0.lowercasedTitle.hasPrefix(lowered) && $0.title.count > query.count }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasExact = !trimmed.isEmpty && notes.contains { $0.lowercasedTitle == trimmed }

        return SearchComputation(notes: pinned, suggestion: suggestion, hasExactTitleMatch: hasExact)
    }

    /// Guarded by a generation counter rather than task cancellation alone:
    /// several triggers (typing debounce, sort toggles, pin changes, store
    /// reloads) can each start a computation, and an older one finishing
    /// late must not clobber a newer one's result.
    func recomputeFilteredNotes() async {
        searchComputeGeneration += 1
        let generation = searchComputeGeneration
        let notesSnapshot = store.notes
        let querySnapshot = query
        let pinnedSnapshot = pinnedNoteIDs
        let field = sortField
        let ascending = sortAscending
        let result = await Task.detached(priority: .userInitiated) {
            Self.computeSearch(notes: notesSnapshot, query: querySnapshot, pinnedIDs: pinnedSnapshot, sortField: field, sortAscending: ascending)
        }.value
        guard generation == searchComputeGeneration else { return }
        filteredNotesCache = result.notes
        suggestionNoteCache = result.suggestion
        queryHasExactTitleMatch = result.hasExactTitleMatch
    }

    /// Titles of every note, newest-edited first — feeds the editors'
    /// wiki-link ghost autocomplete. Cached for the same reason as
    /// filteredNotesCache: it was being built inline in the editor pane's
    /// body (an O(n log n) sort plus a title copy per note) on every
    /// keystroke-triggered render. The sort runs off the main thread too —
    /// this recomputes on every store.notes change, which includes the
    /// debounced save fired every 400ms while typing in the editor.
    @State var noteTitlesByRecencyCache: [String] = []
    @State private var noteTitlesGeneration = 0

    func recomputeNoteTitles() {
        noteTitlesGeneration += 1
        let generation = noteTitlesGeneration
        let notesSnapshot = store.notes
        Task { @MainActor in
            let titles = await Task.detached(priority: .utility) {
                notesSnapshot.sorted { $0.modifiedDate > $1.modifiedDate }.map(\.title)
            }.value
            guard generation == noteTitlesGeneration else { return }
            noteTitlesByRecencyCache = titles
        }
    }

    /// The query the editor highlights matches for — trails `query` by the
    /// same 60ms debounce as the filtered list (it's updated in the same
    /// debounce task). Passing the live query instead meant every single
    /// keystroke in the search bar re-styled the entire open note (search
    /// highlighting is document-wide, so it can't use the editor's own
    /// windowed restyle), which was a visible chunk of the typing lag on
    /// large notes.
    @State var editorSearchQuery = ""

    /// Notes whose content links to the open note, newest-edited first.
    /// Used to be a plain computed property on the theory that it'd only
    /// run on note-switch or a store change — but it's referenced 4 times
    /// in the view body (the disclosure toggle, its count, the expanded
    /// list, and the divider gate), and SwiftUI doesn't share one
    /// evaluation of a computed property across multiple references within
    /// the same body pass. With several thousand notes that meant up to 4
    /// redundant O(notes) scan-and-sorts every time the editor pane
    /// re-rendered — the same class of bug filteredNotesCache above fixes
    /// for the search results list, just left unaddressed here. Same fix:
    /// cached in @State, recomputed only when selectedID or store.notes
    /// actually change.
    @State var currentBacklinkNotesCache: [Note] = []
    @State private var backlinksGeneration = 0

    var currentBacklinkNotes: [Note] { currentBacklinkNotesCache }

    /// Off the main thread like the search pipeline — `wikiLinks` is
    /// computed lazily per note, so the very first backlink pass after a
    /// load runs the wiki-link regex over every note's full content, which
    /// on a large library is far too much to do synchronously in a
    /// selection-change handler.
    func recomputeBacklinkNotes() {
        backlinksGeneration += 1
        let generation = backlinksGeneration
        guard showBacklinks, let selectedID,
              let currentTitle = store.notes.first(where: { $0.id == selectedID })?.title
        else {
            currentBacklinkNotesCache = []
            return
        }
        let lowered = currentTitle.lowercased()
        let notesSnapshot = store.notes
        let selected = selectedID
        Task { @MainActor in
            let backlinks = await Task.detached(priority: .utility) {
                notesSnapshot
                    .filter { $0.id != selected && $0.wikiLinks.contains(lowered) }
                    .sorted { $0.modifiedDate > $1.modifiedDate }
            }.value
            guard generation == backlinksGeneration else { return }
            currentBacklinkNotesCache = backlinks
        }
    }

    // Split out of `body` — the full modifier chain in one expression (this
    // plus onAppear/onChange/alert below) got too long for the type checker
    // ("unable to type-check this expression in reasonable time"). Giving
    // this its own `some View`-typed property lets the compiler solve it
    // independently instead of as one combinatorially large expression.
    private var notificationHandledLayout: some View {
        Group {
            switch layoutMode {
            case .horizontal:
                NavigationSplitView {
                    listPane
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                } detail: {
                    editorPane
                }
                // NavigationSplitView auto-adds a leading sidebar-toggle
                // button to the window's toolbar — an unbalanced leading
                // item throws off the title's centering (which is computed
                // relative to the space between leading/trailing toolbar
                // items, not the raw window width).
                .toolbar(removing: .sidebarToggle)
            case .vertical:
                PersistentVSplitView(storageKey: "verticalSplitFraction", defaultTopFraction: 0.6) {
                    listPane
                } bottom: {
                    editorPane
                }
            }
        }
        .background(backgroundView.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .newNoteRequested)) { _ in
            createBlankNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToOmniBarRequested)) { _ in
            focusedField = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .externalNoteOpenRequested)) { notification in
            guard let url = notification.object as? URL else { return }
            editingTemplate = nil
            selectedID = url.path
            query = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFromTemplateRequested)) { _ in
            query = "template:"
            focusedField = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .summonRequested)) { _ in
            // The window is hidden via orderOut (not torn down) between
            // summons, so focusedField already holds whatever was focused
            // before hiding — restoreFocusOnSummon just means "don't
            // override that," nothing extra to track.
            if !restoreFocusOnSummon {
                focusedField = .search
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedRequested)) { _ in
            deleteSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreDeletedNoteRequested)) { _ in
            restoreLastDeleted()
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePinRequested)) { _ in
            guard let selectedID, let note = store.notes.first(where: { $0.id == selectedID }) else { return }
            togglePin(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleLayoutRequested)) { _ in
            layoutModeRaw = (layoutMode == .horizontal ? LayoutMode.vertical : .horizontal).rawValue
        }
        .modifier(EditorViewNotifications(
            zoomIn: { editorFontZoom = min(60, editorFontZoom + 1) },
            zoomOut: { editorFontZoom = max(-8, editorFontZoom - 1) },
            zoomReset: { editorFontZoom = 0 },
            openSettings: { openSettings() },
            nextFolder: { cycleActiveFolder(by: 1) },
            previousFolder: { cycleActiveFolder(by: -1) },
            togglePlainTextMode: { plainTextMode.toggle() },
            toggleBacklinks: { withAnimation(.easeInOut(duration: 0.15)) { backlinksExpanded.toggle() } }
        ))
        .modifier(FocusAndFullScreenNotifications(
            cycleFocus: cycleFocus,
            isFullScreen: $isFullScreen
        ))
    }

    var body: some View {
        notificationHandledLayout
        .onAppear {
            Task { await recomputeFilteredNotes() }
            recomputeBacklinkNotes()
            recomputeNoteTitles()
            isFullScreen = NSApp.windows.first?.styleMask.contains(.fullScreen) ?? false
            // Captured before createWelcomeNoteIfNeeded() flips it to true —
            // that's the signal for "already had notes before this launch,"
            // which is what actually distinguishes an existing user picking
            // up a real update from a brand-new install (whose
            // lastSeenWhatsNewVersion is empty too, but for a different
            // reason: it's simply never been set).
            let wasExistingUser = hasCreatedWelcomeNote
            createWelcomeNoteIfNeeded()
            seedSampleTemplatesIfNeeded()
            if wasExistingUser {
                showWhatsNewIfUpdated()
            } else {
                // The welcome note already introduces everything to a
                // brand-new user — just record today's version as the
                // baseline so a future real update is what triggers this.
                lastSeenWhatsNewVersion = currentAppVersion
            }
            selectDefaultIfNeeded()
            focusedField = .search
            applyWindowTitleVisibility()
        }
        .onChange(of: notesDirectoryPathsRaw) { _, _ in
            switchNotesDirectories()
        }
        .onChange(of: disabledDirectoryPathsRaw) { _, _ in
            switchNotesDirectories()
        }
        .onChange(of: store.notes) { _, _ in
            // Fires once a reload actually finishes (folder switch, note
            // added/removed/renamed elsewhere, etc.) — falls back to the
            // first note only if the current selection no longer exists in
            // the fresh list, rather than assuming it doesn't.
            // Selection reconciliation waits for the recompute to land —
            // it reads filteredNotes, which the await is what refreshes.
            Task {
                await recomputeFilteredNotes()
                reconcileSelection()
            }
            recomputeBacklinkNotes()
            recomputeNoteTitles()
        }
        .onChange(of: showBacklinks) { _, _ in recomputeBacklinkNotes() }
        .onChange(of: sortFieldRaw) { _, _ in Task { await recomputeFilteredNotes() } }
        .onChange(of: sortAscending) { _, _ in Task { await recomputeFilteredNotes() } }
        .onChange(of: pinnedNotePathsRaw) { _, _ in Task { await recomputeFilteredNotes() } }
        .onChange(of: store.isLoading) { _, isLoading in
            // A fade transition alone didn't stop the flash — a reload that
            // finishes in well under the fade's own duration still visibly
            // flickers the indicator in and back out. The actual fix is not
            // showing it at all unless loading has been running long enough
            // to be worth mentioning; local folder scans almost always
            // finish under this delay, so it normally never appears.
            loadingIndicatorTask?.cancel()
            if isLoading {
                loadingIndicatorTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    showLoadingIndicator = true
                }
            } else {
                showLoadingIndicator = false
            }
        }
        .onChange(of: layoutModeRaw) { _, _ in
            // Horizontal and vertical layouts are structurally different
            // top-level views (NavigationSplitView vs PersistentVSplitView)
            // — swapping between them makes SwiftUI reassert the
            // WindowGroup's own declared title ("Envy") on top of whatever
            // we'd set, same as the reassertion noted in EnvyApp.swift.
            // Deferred a tick so this reapplies after that reassertion,
            // not before it.
            DispatchQueue.main.async {
                applyWindowTitleVisibility()
            }
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
}

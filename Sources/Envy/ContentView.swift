import SwiftUI
import AppKit
import EnvyCore

enum LayoutMode: String {
    case horizontal
    case vertical
}

/// A note title mentioned in the current note's own text without being
/// linked yet — Interlinks' "Suggested" section. `range` is that specific
/// occurrence's location in the note's content, the one spot a click
/// wraps in "[[...]]"; title as `id` is safe since suggestedLinkMatches
/// only ever returns one match per title.
struct SuggestedLink: Identifiable {
    let title: String
    let range: NSRange
    var id: String { title }
}

enum NoteSortField: String {
    case name
    case date
    case due

    /// The direction each field starts in when first selected — matches
    /// Notational Velocity's convention (names A→Z, dates newest first).
    /// Due dates default ascending (soonest first) — the most urgent note
    /// belongs at the top, same reasoning as names starting A→Z rather than
    /// Z→A.
    var defaultAscending: Bool {
        switch self {
        case .name: return true
        case .date: return false
        case .due: return true
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
    @StateObject var store = NoteStore(
        directory: IndexPreference.load(),
        includeSubfolders: UserDefaults.standard.bool(forKey: IndexPreference.includeSubfoldersKey)
    )
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
    @State var editorWordCount = 0
    @State var editorCharacterCount = 0
    @State var backlinksExpanded = false
    /// Measured width of the interlinks panel — drives its side-by-side vs
    /// stacked layout (see interlinksExpandedList). 0 until first measured.
    @State var interlinksWidth: CGFloat = 0
    @State var isFullScreen = false
    @State var showLoadingIndicator = false
    @State var loadingIndicatorTask: Task<Void, Never>?
    @State var searchDebounceTask: Task<Void, Never>?
    @State var trashSweepTask: Task<Void, Never>?
    @FocusState var focusedField: FocusField?
    @AppStorage("layoutMode") var layoutModeRaw = LayoutMode.vertical.rawValue
    @AppStorage("newNotesStartInInbox") var newNotesStartInInbox = false
    @AppStorage("showInboxInMainList") var showInboxInMainList = true
    @AppStorage("theme") var theme = Theme()
    /// Non-empty while an adaptive theme is selected. The pair is the source
    /// of truth; `theme` above is the face currently in force, rewritten
    /// whenever the appearance flips so every existing consumer keeps
    /// reading one plain resolved Theme and needs no changes at all.
    @AppStorage("themePair") var themePairRaw = ""
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("backgroundBlurStrength") var backgroundBlurStrengthRaw = BlurStrength.strong.rawValue
    @AppStorage("showNotePreview") var showNotePreview = false
    @AppStorage("showDateModified") var showDateModified = true
    @AppStorage("showDueSort") var showDueSort = true
    @AppStorage("dateDisplayStyle") var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") var requireModifierForLinkClick = true
    @AppStorage("linkPreviewTrigger") var linkPreviewTriggerRaw = LinkPreviewTrigger.optionClick.rawValue
    @AppStorage("showTagsInTitleBar") var showTagsInTitleBar = false
    @AppStorage("showDuePill") var showDuePill = true
    @AppStorage(IndexPreference.storageKey) var indexPathRaw = ""
    @AppStorage(IndexPreference.includeSubfoldersKey) var indexIncludeSubfolders = false
    @AppStorage("hasCreatedWelcomeNote") var hasCreatedWelcomeNote = false
    @AppStorage("lastSeenWhatsNewVersion") var lastSeenWhatsNewVersion = ""
    @AppStorage("moveFocusToEditorOnEnter") var moveFocusToEditorOnEnter = true
    @AppStorage("listDensity") var listDensityRaw = ListDensity.compact.rawValue
    @AppStorage("interfaceTextSize") var interfaceTextSizeRaw = InterfaceTextSize.large.rawValue
    @AppStorage("noteSortField") var sortFieldRaw = NoteSortField.date.rawValue
    @AppStorage("noteSortAscending") var sortAscending = false
    @AppStorage("showFooterClock") var showFooterClock = false
    @AppStorage("showFooterClockDate") var showFooterClockDate = false
    @AppStorage("footerClockDateFormat") var footerClockDateFormatRaw = ClockDateFormat.short.rawValue
    @AppStorage("showFooterClockOnlyWhenFullScreen") var showFooterClockOnlyWhenFullScreen = false
    @AppStorage("editorFontZoom") var editorFontZoom: Double = 0
    @AppStorage("plainTextMode") var plainTextMode = false
    @AppStorage("protectAISignature") var protectAISignature = false
    @AppStorage("fadeFocusHighlight") var fadeFocusHighlight = false
    @AppStorage("boldFileListText") var boldFileListText = false
    @AppStorage("showBacklinks") var showBacklinks = true
    @AppStorage("restoreFocusOnSummon") var restoreFocusOnSummon = true
    @AppStorage("templateDateFormatPattern") var templateDateFormatPattern = TemplateDateFormat.defaultPattern
    @AppStorage("hasSeededSampleTemplates") var hasSeededSampleTemplates = false
    @State var highlightedTemplateID: String?
    /// Same shape as multiSelectedIDs/selectionAnchorID above, just for
    /// template: browsing — highlightedTemplateID is the "primary" end.
    @State var multiSelectedTemplateIDs: Set<String> = []
    @State var templateSelectionAnchorID: String?
    @State var highlightedTrashID: String?
    /// Same shape again, for trash: browsing.
    @State var multiSelectedTrashIDs: Set<String> = []
    @State var trashSelectionAnchorID: String?
    /// Shares WikilinkPreviewController with the editor's own wikilinks —
    /// same panel, same rounded-corner/positioning/dismissal logic, just a
    /// different (button-shaped, not text-range-shaped) anchor. Persists
    /// across renders via @State the same way store/theme do, even though
    /// it isn't itself an ObservableObject — it's a plain reference type
    /// this view just needs to keep alive and call into.
    @State var backlinkPreviewController = WikilinkPreviewController()
    /// One real NSView per currently-rendered backlink row, keyed by note
    /// id — WikilinkAnchorProbe populates this as SwiftUI inserts each row
    /// into the view hierarchy; the controller needs an actual NSView to
    /// anchor the panel to and to compare later clicks against.
    @State var backlinkAnchorViews: [String: NSView] = [:]
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

    /// Falls back to .date rather than reading sortFieldRaw as-is when
    /// due-sort has been turned off in Settings — the stored raw value is
    /// left untouched (so a later re-enable naturally restores whatever the
    /// user last had it sorted by), this just guards every *read* of
    /// sortField so nothing tries to render or sort by a column Settings
    /// says shouldn't be offered anymore.
    var sortField: NoteSortField {
        let field = NoteSortField(rawValue: sortFieldRaw) ?? .date
        return (field == .due && !showDueSort) ? .date : field
    }

    var linkPreviewTrigger: LinkPreviewTrigger {
        LinkPreviewTrigger(rawValue: linkPreviewTriggerRaw) ?? .optionClick
    }

    var dateDisplayStyle: DateDisplayStyle {
        DateDisplayStyle(rawValue: dateDisplayStyleRaw) ?? .smart
    }

    var listDensity: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .compact
    }

    var interfaceTextSize: InterfaceTextSize {
        InterfaceTextSize(rawValue: interfaceTextSizeRaw) ?? .large
    }

    // ContentView+ListPane.swift/ContentView+EditorPane.swift's font() call
    // sites reference this directly rather than through the
    // interfaceFontScale *environment* value below — they're extensions of
    // this same struct, not separate child views, so a plain property read
    // is both simpler and avoids the classic SwiftUI trap of a view reading
    // via @Environment a value it only ever injects for its own children.
    // NoteRow/TemplateEditorView (genuinely separate View structs rendered
    // inside this one) still need the environment value instead, since
    // they have no other way to reach this property.
    var interfaceFontScale: CGFloat {
        interfaceTextSize.scale
    }

    var footerClockDateFormat: ClockDateFormat {
        ClockDateFormat(rawValue: footerClockDateFormatRaw) ?? .short
    }

    var backgroundBlurStrength: BlurStrength {
        BlurStrength(rawValue: backgroundBlurStrengthRaw) ?? .strong
    }

    var availableTemplates: [NoteTemplate] {
        store.templates()
    }

    var availableTrashedNotes: [Note] {
        store.trashedNotes
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
        sortAscending: Bool,
        showInbox: Bool
    ) -> SearchComputation {
        var filtered = NoteStore.filtered(notes, query: query)
        // Hidden only when the query isn't already about the inbox — asking
        // for "inbox:" and being shown nothing because of a setting
        // elsewhere would be its own bug.
        if !showInbox, !query.lowercased().contains("inbox:") {
            filtered = filtered.filter { !NoteStore.isInInboxFolder($0) }
        }
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
        let showInbox = showInboxInMainList
        let result = await Task.detached(priority: .userInitiated) {
            Self.computeSearch(notes: notesSnapshot, query: querySnapshot, pinnedIDs: pinnedSnapshot, sortField: field, sortAscending: ascending, showInbox: showInbox)
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

    /// Every distinct tag used anywhere in The Index, most-used first —
    /// feeds `tag:`/`-tag:` ghost-text completion in the search field, the
    /// same way noteTitlesByRecencyCache feeds note-title completion.
    /// Recomputed on the same store.notes changes, but unlike note titles
    /// this never needs the background search pipeline the results list
    /// itself uses: there are always far fewer distinct tags than notes, so
    /// a synchronous scan here is cheap even on a large library.
    @State var allTagsByFrequencyCache: [String] = []
    @State private var allTagsGeneration = 0

    func recomputeAllTags() {
        allTagsGeneration += 1
        let generation = allTagsGeneration
        let notesSnapshot = store.notes
        Task { @MainActor in
            let tags = await Task.detached(priority: .utility) {
                var frequency: [String: Int] = [:]
                for note in notesSnapshot {
                    for tag in note.tags {
                        frequency[tag, default: 0] += 1
                    }
                }
                return frequency.keys.sorted {
                    frequency[$0]! != frequency[$1]! ? frequency[$0]! > frequency[$1]! : $0 < $1
                }
            }.value
            guard generation == allTagsGeneration else { return }
            allTagsByFrequencyCache = tags
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
    /// Notes this one already links to via "[[...]]" — the forward-
    /// direction counterpart to currentBacklinkNotesCache, shown in
    /// Interlinks' own "Links" section right alongside it.
    @State var currentForwardLinkedNotesCache: [Note] = []
    /// Other notes' titles mentioned in this note's own text but never
    /// actually linked — Interlinks' "Suggested" section. Clicking one
    /// wraps that exact occurrence in "[[...]]"; nothing is ever inserted
    /// automatically just from a title matching somewhere.
    @State var currentSuggestedLinksCache: [SuggestedLink] = []
    @State private var interlinksGeneration = 0

    var currentBacklinkNotes: [Note] { currentBacklinkNotesCache }
    var currentForwardLinkedNotes: [Note] { currentForwardLinkedNotesCache }
    var currentSuggestedLinks: [SuggestedLink] { currentSuggestedLinksCache }

    /// Off the main thread like the search pipeline — `wikiLinks` is
    /// computed lazily per note, so the very first pass after a load runs
    /// the wiki-link regex over every note's full content, which on a
    /// large library is far too much to do synchronously in a selection-
    /// change handler. Backlinks, forward links, and suggested-but-
    /// unlinked matches all come from this one pass since all three are
    /// triggered by exactly the same events (selection change, notes
    /// reload, the Interlinks toggle itself).
    func recomputeInterlinks() {
        interlinksGeneration += 1
        let generation = interlinksGeneration
        guard showBacklinks, let selectedID,
              let currentNote = store.notes.first(where: { $0.id == selectedID })
        else {
            currentBacklinkNotesCache = []
            currentForwardLinkedNotesCache = []
            currentSuggestedLinksCache = []
            return
        }
        let lowered = currentNote.lowercasedTitle
        let content = currentNote.content
        let wikiLinks = currentNote.wikiLinks
        let notesSnapshot = store.notes
        let selected = selectedID
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                let backlinks = notesSnapshot
                    .filter { $0.id != selected && $0.wikiLinks.contains(lowered) }
                    .sorted { $0.modifiedDate > $1.modifiedDate }
                let forward = notesSnapshot
                    .filter { $0.id != selected && wikiLinks.contains($0.lowercasedTitle) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let candidateTitles = notesSnapshot.filter { $0.id != selected }.map(\.title)
                let suggested = MarkdownStyler.suggestedLinkMatches(in: content, candidateTitles: candidateTitles)
                    .map { SuggestedLink(title: $0.title, range: $0.range) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return (backlinks, forward, suggested)
            }.value
            guard generation == interlinksGeneration else { return }
            currentBacklinkNotesCache = result.0
            currentForwardLinkedNotesCache = result.1
            currentSuggestedLinksCache = result.2
        }
    }

    /// Wraps a suggested match's exact occurrence in "[[...]]" and saves —
    /// the only thing that ever mutates a note's text from a suggestion,
    /// and only on this explicit click. Re-resolves the note fresh from
    /// the store rather than trusting a captured copy, since the
    /// suggestion could be a little stale (a background recompute racing
    /// a fast edit) — if the exact substring's moved or changed underneath
    /// it, this just quietly does nothing rather than corrupting the text.
    func acceptSuggestedLink(_ suggestion: SuggestedLink) {
        guard let noteID = selectedID, var note = store.notes.first(where: { $0.id == noteID }) else { return }
        let nsContent = note.content as NSString
        guard suggestion.range.location + suggestion.range.length <= nsContent.length else { return }
        let occurrence = nsContent.substring(with: suggestion.range)
        guard occurrence.caseInsensitiveCompare(suggestion.title) == .orderedSame else { return }
        note.content = nsContent.replacingCharacters(in: suggestion.range, with: "[[\(occurrence)]]")
        store.save(note)
    }

    // Split out of `body` — the full modifier chain in one expression (this
    // plus onAppear/onChange/alert below) got too long for the type checker
    // ("unable to type-check this expression in reasonable time"). Giving
    // this its own `some View`-typed property lets the compiler solve it
    // independently instead of as one combinatorially large expression.
    // Split further out of notificationHandledLayout below for the same
    // type-checker reason its own comment already gives — adding the
    // interfaceFontScale environment() call to that already-long chain
    // tipped it back over the threshold.
    private var layoutSwitch: some View {
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
        // Every chrome font() call site reads this directly (not
        // DynamicTypeSize — see InterfaceTextSize's own doc comment for
        // why), so a single top-level environment value is all that's
        // needed; unlike dynamicTypeSize there's no NavigationSplitView
        // propagation quirk to work around for a plain custom key.
        .environment(\.interfaceFontScale, interfaceTextSize.scale)
    }

    private var notificationHandledLayout: some View {
        layoutSwitch
        .background(backgroundView.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .newNoteRequested)) { _ in
            createBlankNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToOmniBarRequested)) { _ in
            focusedField = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .externalNoteOpenRequested)) { notification in
            guard let url = notification.object as? URL else { return }
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
            togglePlainTextMode: { plainTextMode.toggle() },
            toggleBacklinks: { withAnimation(.easeInOut(duration: 0.15)) { backlinksExpanded.toggle() } }
        ))
        .modifier(FocusAndFullScreenNotifications(
            cycleFocus: cycleFocus,
            isFullScreen: $isFullScreen
        ))
    }

    /// Rewrites the live theme to the face matching the current appearance.
    /// No-op unless an adaptive theme is selected, so a user who picked a
    /// fixed theme (or customised one by hand) is never overridden.
    /// Puts a first-time launch on Envious rather than on bare system colors.
    ///
    /// Gated on the absence of the stored "theme" key, so it only ever fires
    /// for someone who has never picked one — anybody with a theme, custom or
    /// preset, keeps it untouched. It does move a long-time user who never
    /// visited Settings → Theme, which is deliberate: System Default is gone
    /// from the gallery, so leaving them on it would strand them in a state
    /// they can no longer see or re-select.
    private func seedDefaultThemeIfNeeded() {
        guard themePairRaw.isEmpty,
              UserDefaults.standard.object(forKey: "theme") == nil else { return }
        let pair = ThemePair(light: Theme.enviousLight, dark: Theme.enviousDark)
        themePairRaw = pair.rawValue
        theme = pair.face(dark: colorScheme == .dark)
    }

    private func syncAdaptiveTheme() {
        guard let pair = ThemePair(rawValue: themePairRaw) else { return }
        let face = pair.face(dark: colorScheme == .dark)
        if theme != face { theme = face }
    }

    var body: some View {
        notificationHandledLayout
        // An adaptive theme has to be resolved on every appearance change,
        // not only when it's picked. Doing it here rather than inside each
        // resolved* accessor keeps a Theme a plain snapshot of colors — the
        // pairing lives one level up, where the appearance is known.
        .onChange(of: colorScheme) { _, _ in syncAdaptiveTheme() }
        .onAppear {
            seedDefaultThemeIfNeeded()
            syncAdaptiveTheme()
            Task { await recomputeFilteredNotes() }
            recomputeInterlinks()
            recomputeNoteTitles()
            recomputeAllTags()
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

            // A menu-bar summon/hide app can easily run for weeks without a
            // real relaunch, so a launch-only check isn't enough on its own
            // to keep an "every X days/weeks" trash schedule honest — this
            // loop re-checks hourly for as long as the app stays open.
            // Cheap either way: emptyIfDue() is just a UserDefaults date
            // comparison except on the rare tick it's actually due.
            TrashPreference.emptyIfDue(store)
            if trashSweepTask == nil {
                trashSweepTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3600))
                        guard !Task.isCancelled else { return }
                        TrashPreference.emptyIfDue(store)
                    }
                }
            }
        }
        .onChange(of: indexPathRaw) { _, _ in
            switchIndexDirectory()
        }
        .onChange(of: indexIncludeSubfolders) { _, new in
            store.setIncludeSubfolders(new)
        }
        .onChange(of: store.notes) { _, _ in
            // Fires once a reload actually finishes (folder switch, note
            // added/removed/renamed elsewhere, etc.) — falls back to the
            // first note only if the current selection no longer exists at
            // all, rather than assuming it doesn't just because it fell out
            // of the active search filter (reconcileSelectionAfterNotesChange,
            // not reconcileSelection — see its own doc comment for why this
            // site specifically needs the distinction).
            // Selection reconciliation waits for the recompute to land —
            // it reads filteredNotes, which the await is what refreshes.
            Task {
                await recomputeFilteredNotes()
                reconcileSelectionAfterNotesChange()
            }
            recomputeInterlinks()
            recomputeNoteTitles()
            recomputeAllTags()
        }
        .onChange(of: showBacklinks) { _, _ in recomputeInterlinks() }
        .rebuildingListOnChange(self)
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

/// The filtered list is a cache, rebuilt only when something asks it to.
/// Every preference that changes *what the list contains* has to ask, and
/// they're gathered here rather than chained onto the body: six more
/// `.onChange` modifiers inline is enough to push ContentView past the
/// type-checker's expression limit.
private struct RebuildListOnChange: ViewModifier {
    let view: ContentView

    func body(content: Content) -> some View {
        content
            .onChange(of: view.sortFieldRaw) { _, _ in rebuild() }
            // Toggling this off in Settings changes what sortField *resolves
            // to* (falls back to .date) without touching sortFieldRaw itself
            // — needs its own trigger, since the one above only fires when
            // the raw stored value changes, which this doesn't.
            .onChange(of: view.showDueSort) { _, _ in rebuild() }
            .onChange(of: view.sortAscending) { _, _ in rebuild() }
            .onChange(of: view.pinnedNotePathsRaw) { _, _ in rebuild() }
            .onChange(of: view.showInboxInMainList) { _, _ in rebuild() }
    }

    private func rebuild() {
        Task { await view.recomputeFilteredNotes() }
    }
}

extension View {
    func rebuildingListOnChange(_ view: ContentView) -> some View {
        modifier(RebuildListOnChange(view: view))
    }
}

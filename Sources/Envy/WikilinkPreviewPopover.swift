import SwiftUI
import AppKit
import EnvyCore

/// An invisible, zero-content NSView whose only job is to exist as a real
/// AppKit anchor for a SwiftUI row — WikilinkPreviewController.show(in:)
/// needs an actual NSView to compute a screen-space frame from and to
/// compare against later mouseDown events, which a pure SwiftUI Button
/// doesn't expose directly. Dropped in via .background() on a row; reports
/// itself back out through the binding once SwiftUI actually inserts it
/// into the view hierarchy.
struct WikilinkAnchorProbe: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { anchorView = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Reports the NSWindow a SwiftUI view ends up hosted in, once AppKit has
/// inserted it — lets the preview's pin button close its own floating window via
/// performClose (which works even when the window isn't key). Resolves exactly
/// once, in a stored coordinator, so it never re-fires on later SwiftUI updates:
/// pushing the window back into @State on every update (NSWindow isn't
/// Equatable, so SwiftUI can't dedupe it) spins a re-render loop — one per
/// pinned note, each doing O(notes) work — which is what made the list crawl.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard !context.coordinator.resolved, let window = view.window else { return }
            context.coordinator.resolved = true
            onResolve(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.resolved else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.resolved, let window = nsView.window else { return }
            context.coordinator.resolved = true
            onResolve(window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var resolved = false }
}

/// The content of the option-click preview popover: a title header plus
/// the linked note's body, reusing MarkdownTextView directly rather than a
/// separate read-only renderer — the same view just starts non-editable (a
/// plain, non-interactive rendering of the styled text) and flips to
/// editable on first click, so there's exactly one styling code path for
/// both states. Shares the caller's live NoteStore (unlike
/// PinnedNotePopoverView, which deliberately avoids that — this popover
/// only ever exists while the main window/editor and its NoteStore are
/// already alive, so there's no "second ongoing instance watching the same
/// folder" concern to avoid here).
struct WikilinkPreviewContentView: View {
    // Deliberately NOT @ObservedObject: a peek shows one fixed note and doesn't
    // need to redraw on every unrelated store mutation. Observing the whole
    // store meant each open peek re-rendered on every autosave/reload across the
    // vault — with several pinned, that fan-out (each doing an O(notes) lookup)
    // is what made the app drag. It's still used for the note lookup and saving;
    // the view just drives its own redraws from local @State.
    var store: NoteStore
    let noteID: String
    var theme: Theme
    var requireModifierForLinkClick: Bool
    /// Same two Settings toggles the main editor's own title bar
    /// (NoteEditorView.header) respects — the preview's header chips
    /// mirror that header, so they follow the same on/off switches rather
    /// than always showing regardless of what the user configured there.
    var showDuePill: Bool
    var showTagsInTitleBar: Bool
    var noteTitles: [String]
    var onNavigate: (String) -> Void
    var onEditableActivated: () -> Void
    var onPin: () -> Void

    @State private var isEditable: Bool
    @State private var isPinned = false
    @State private var hostWindow: NSWindow?
    @State private var content: String
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSyncedContent: String

    private var note: Note? {
        store.notes.first { $0.id == noteID }
    }

    init(
        store: NoteStore,
        noteID: String,
        theme: Theme,
        requireModifierForLinkClick: Bool,
        showDuePill: Bool,
        showTagsInTitleBar: Bool,
        noteTitles: [String],
        onNavigate: @escaping (String) -> Void,
        onEditableActivated: @escaping () -> Void,
        onPin: @escaping () -> Void
    ) {
        self.store = store
        self.noteID = noteID
        self.theme = theme
        self.requireModifierForLinkClick = requireModifierForLinkClick
        self.showDuePill = showDuePill
        self.showTagsInTitleBar = showTagsInTitleBar
        self.noteTitles = noteTitles
        self.onNavigate = onNavigate
        self.onEditableActivated = onEditableActivated
        self.onPin = onPin
        let initial = store.notes.first { $0.id == noteID }
        _content = State(initialValue: initial?.content ?? "")
        _lastSyncedContent = State(initialValue: initial?.content ?? "")
        _isEditable = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(note?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    // Plain click, not gated behind ⌘ like inline body
                    // links — this is a dedicated "open this note" header,
                    // not body text where an accidental click needs
                    // guarding against.
                    .onTapGesture {
                        guard let note else { return }
                        onNavigate(note.title)
                    }
                Spacer(minLength: 8)
                // Same at-a-glance chips as the main editor's own title
                // bar (NoteEditorView.header) — display only here, not
                // tappable-to-search, since a quick peek isn't really the
                // moment for pivoting into a tag search.
                if showDuePill, let note, let due = note.due {
                    // Same "+N" shape as the tag badge just below — the
                    // pill only ever shows the earliest active due date.
                    let suffix = note.dueDateCount > 1 ? " +\(note.dueDateCount - 1)" : ""
                    Text("Due \(due.formatted(.dateTime.month(.abbreviated).day()))\(suffix)")
                        .font(.caption.bold())
                        .lineLimit(1)
                        .foregroundStyle(Color(nsColor: dueChipColor(for: due)))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: dueChipColor(for: due)).opacity(0.15))
                        .clipShape(Capsule())
                        .layoutPriority(1)
                }
                if showTagsInTitleBar, let note, !note.tags.isEmpty {
                    let sortedTags = note.tags.sorted()
                    Text(sortedTags.count > 1 ? "#\(sortedTags[0]) +\(sortedTags.count - 1)" : "#\(sortedTags[0])")
                        .font(.caption.bold())
                        .lineLimit(1)
                        .foregroundStyle(Color(nsColor: theme.resolvedTagColor))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: theme.resolvedTagBackgroundColor))
                        .clipShape(Capsule())
                        .layoutPriority(1)
                }
                // Pin detaches this peek into its own floating window that stays
                // open and frees the peek slot, so several can sit open at once;
                // it fills to show the pinned state. Click it again to close —
                // routed through the window's own performClose so it works even
                // when the window isn't key (a plain SwiftUI tap there wouldn't).
                Button {
                    if isPinned {
                        // close(), not performClose(nil): performClose only
                        // works on a window whose style mask includes
                        // .closable, which this panel deliberately doesn't
                        // carry a visible close button for — so it was a silent
                        // no-op and the note wouldn't unpin. close() shuts the
                        // window unconditionally and still fires
                        // willCloseNotification, which is what PinnedPeekManager
                        // listens for to drop it from its set.
                        hostWindow?.close()
                    } else {
                        isPinned = true
                        onPin()
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.caption)
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Close this floating note" : "Pin as a floating window")
                .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // The theme's own background, not .bar — .bar is a generic
            // system material independent of the active theme, which read
            // as a visibly different color from the body below (especially
            // obvious on a dark theme, where .bar stays light-ish system
            // chrome while resolvedBackgroundColor is near-black). The
            // whole panel should read as one continuous surface.
            .background(Color(nsColor: theme.resolvedBackgroundColor))
            Divider()
            MarkdownTextView(
                text: $content,
                onNavigate: onNavigate,
                theme: theme,
                requireModifierForLinkClick: requireModifierForLinkClick,
                searchQuery: "",
                isEditable: isEditable,
                onRequestEditable: {
                    isEditable = true
                    onEditableActivated()
                },
                noteTitles: noteTitles
            )
        }
        // Fills the panel rather than pinning a fixed size, so the content
        // grows and shrinks with a drag-resize (the panel is .resizable and
        // carries its own minSize). minWidth/minHeight mirror that floor so the
        // layout never collapses tighter than the window can go.
        .frame(minWidth: 200, maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
        .background(WindowAccessor { hostWindow = $0 })
        // The panel's real title bar is hidden (titleVisibility = .hidden,
        // transparent) but its .fullSizeContentView style still leaves
        // SwiftUI reserving a title-bar-height safe-area inset at the top —
        // same fix as PinnedNotePopoverView's own identical issue. Without
        // this the header renders pushed down below an invisible gap.
        .ignoresSafeArea(edges: .top)
        .onChange(of: content) { _, newValue in
            guard isEditable, newValue != lastSyncedContent else { return }
            scheduleSave(newValue)
        }
    }

    /// Same three-way split as NoteEditorView's own dueChipColor — kept as
    /// its own small copy rather than a shared helper, same reasoning
    /// NoteRow's dateTextColor already duplicates it too: three call sites
    /// each switching on the same NoteStore.dueUrgency isn't worth a shared
    /// abstraction for five lines.
    private func dueChipColor(for due: Date) -> NSColor {
        switch NoteStore.dueUrgency(for: due) {
        case .overdue: theme.resolvedDueOverdueColor
        case .soon: theme.resolvedDueSoonColor
        case .later: theme.resolvedDueColor
        }
    }

    private func scheduleSave(_ newValue: String) {
        guard let note else { return }
        var updated = note
        updated.content = newValue
        saveTask = DebouncedSave.schedule(replacing: saveTask) {
            store.save(updated)
            lastSyncedContent = updated.content
        }
    }
}

/// Where a resized peek's dimensions are remembered, so the next one opens at
/// the size you last dragged it to — the same "one preferred size, last drag
/// wins" persistence the menu-bar pinned note uses (its own separate keys).
private let peekPanelWidthKey = "wikilinkPeekWidth"
private let peekPanelHeightKey = "wikilinkPeekHeight"

/// A borderless panel that's still allowed to become key on click — needed
/// so the embedded text view can actually receive keyboard input once the
/// preview is clicked into edit mode. Plain borderless NSPanels default
/// canBecomeKey to false. It also remembers its own size: a drag-resize
/// (didEndLiveResize, which fires once when the drag finishes rather than
/// continuously mid-drag) writes width/height back to the shared keys so the
/// next peek — pinned or not — opens at that size. Observing its own
/// notification keeps this working after the peek is adopted by
/// PinnedPeekManager, without a delegate that would have to be handed off too.
private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // nonisolated(unsafe): read once from the (nonisolated) deinit to unregister
    // — the panel is torn down on the main thread and nothing else races it.
    nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?

    func persistSizeOnResize() {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees this runs on the main thread; assumeIsolated
            // lets us touch the window's main-actor `frame` without a warning.
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(self.frame.width, forKey: peekPanelWidthKey)
                UserDefaults.standard.set(self.frame.height, forKey: peekPanelHeightKey)
            }
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
}

/// Delivers the click that re-focuses the panel to the control under it too, so
/// a pinned peek's pin button (and clicking into its body) works in a single
/// click even after you've clicked away and the panel is no longer key —
/// otherwise that first click is swallowed just to re-key the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the option-click preview panel's lifecycle. Shows instantly on an
/// explicit option-click — no dwell delay (there's no passive "sweeping the
/// mouse across text" case to guard against) and no appear animation.
///
/// This is a plain NSPanel with an explicitly computed frame, not NSPopover —
/// NSPopover's own automatic above/below repositioning produced a
/// noticeably oversized gap above the anchor in exactly the case it flips to
/// avoid running off-screen, across two separate attempts to fix it by
/// tuning preferredEdge (first a fixed edge, then computing the edge
/// ourselves). Both still went through NSPopover's own internal placement
/// math on top of whatever edge was requested; a panel positioned via a
/// frame this class computes directly, the same way
/// AppDelegate+PinnedNote.swift already positions its own panel, removes
/// that black box entirely — there's nothing left to second-guess the
/// computed position, because AppKit is never asked to place anything
/// itself.
///
/// It's a *hold*, not a toggle: releasing the option key closes it
/// immediately, the same instant the key physically goes up (tracked via a
/// .flagsChanged monitor, not a debounce) — mirroring Quick Look's
/// spacebar-hold convention. That only holds while the preview is still
/// read-only, though; the moment the user clicks in to actually edit, the
/// key-release auto-close stops (isEditableActivated below) and it stays
/// open until an outside click, Escape, or the app losing focus — otherwise
/// there'd be no way to reach the editable state at all, since getting the
/// mouse from the link down into the panel to click almost always means
/// letting go of option first.
///
/// Dismissal is handled entirely through the manual event monitors below
/// (there's no NSPopover .transient behavior to lean on here) — the same
/// monitor distinguishes "this outside click is really a request to
/// navigate" (cmd-clicking the still-open preview's own link) from "this
/// outside click just means dismiss," so cmd-click on an already-previewed
/// link navigates in one click, not two.
@MainActor
final class WikilinkPreviewController: NSObject {
    private var panel: PreviewPanel?
    private var isEditableActivated = false
    /// Peeks the user pinned. Each is promoted out of the single hold-to-peek
    /// `panel` above into its own self-standing floating window (with a native
    /// close button), so any number can sit open at once while the peek slot is
    /// free for the next Option-click. Held only to close them on app-switch.
    private var pinnedPanels: [PreviewPanel] = []
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    /// The previewed anchor's own view/title, captured at show time — used
    /// by the mouse monitor below to recognize "this outside click landed
    /// back on the anchor this panel is previewing." A generic NSView (not
    /// specifically NSTextView) since this controller now serves both the
    /// editor's inline wikilinks (anchor = the shared NSTextView, a small
    /// range within it) and the backlinks list (anchor = one small,
    /// self-contained button view per row) — each caller supplies its own
    /// shouldNavigateOnOutsideClick closure below rather than this class
    /// assuming one specific kind of hit-test.
    private weak var anchorView: NSView?
    private var previewedTitle: String?
    /// Supplied fresh by the caller on every show() — decides whether a
    /// click outside the panel, at a given point (in anchorView's own
    /// coordinate space) with the given modifier flags, should be treated
    /// as "navigate to the preview's note" rather than an ordinary dismiss.
    /// The editor's version re-derives a character index and requires
    /// whatever modifier convention requireModifierForLinkClick specifies;
    /// backlinks' version is a plain bounds check with no modifier
    /// requirement, matching how a backlink already navigates on any plain
    /// click. Kept as a closure rather than hard-coding either shape here.
    private var shouldNavigateOnOutsideClick: ((NSPoint, NSEvent.ModifierFlags) -> Bool)?

    private weak var store: NoteStore?
    private var theme = Theme()
    private var requireModifierForLinkClick = true
    private var showDuePill = true
    private var showTagsInTitleBar = false
    private var noteTitles: [String] = []
    private var currentlyOpenNoteID: String?
    private var onNavigate: ((String) -> Void)?

    private static let panelSize = NSSize(width: 320, height: 240)

    /// The size a new peek opens at: whatever the last drag-resize saved, or
    /// the default until one has been resized. Read fresh each time so a resize
    /// carries to the next peek within the same session too.
    private static var persistedPeekSize: NSSize {
        let w = UserDefaults.standard.double(forKey: peekPanelWidthKey)
        let h = UserDefaults.standard.double(forKey: peekPanelHeightKey)
        return NSSize(
            width: w > 0 ? w : panelSize.width,
            height: h > 0 ? h : panelSize.height
        )
    }

    /// Refreshed on every option-click rather than once at init — the same
    /// Coordinator/controller pair persists across theme changes etc. while
    /// the note stays open.
    func configure(
        store: NoteStore,
        theme: Theme,
        requireModifierForLinkClick: Bool,
        showDuePill: Bool,
        showTagsInTitleBar: Bool,
        noteTitles: [String],
        currentlyOpenNoteID: String?,
        onNavigate: @escaping (String) -> Void
    ) {
        self.store = store
        self.theme = theme
        self.requireModifierForLinkClick = requireModifierForLinkClick
        self.showDuePill = showDuePill
        self.showTagsInTitleBar = showTagsInTitleBar
        self.noteTitles = noteTitles
        self.currentlyOpenNoteID = currentlyOpenNoteID
        self.onNavigate = onNavigate
    }

    /// Always closes whatever might already be showing first — every call
    /// here now comes from a single deliberate option-click (there's no
    /// hover-driven dedup case left to optimize for), so there's no reason
    /// to distinguish "same anchor as last time" from "different anchor"
    /// before deciding to show fresh.
    func show(
        title: String,
        anchorRect: NSRect,
        in view: NSView,
        shouldNavigateOnOutsideClick: @escaping (NSPoint, NSEvent.ModifierFlags) -> Bool
    ) {
        guard !isEditableActivated else { return }
        closePanel()

        guard let store, let note = store.exactTitleMatch(for: title) else { return }

        // Previewing the note you're already looking at would spawn a
        // second, independent edit surface on the same content — type in
        // both within the same save-debounce window and whichever save
        // lands second silently discards the other's edit. The main editor
        // is already right there showing it, so just make sure it's
        // focused instead of showing a redundant read-only copy of
        // something already fully visible and editable.
        if note.id == currentlyOpenNoteID {
            onNavigate?(note.title)
            return
        }

        guard let frame = frame(for: anchorRect, in: view) else { return }

        isEditableActivated = false
        self.anchorView = view
        self.previewedTitle = title
        self.shouldNavigateOnOutsideClick = shouldNavigateOnOutsideClick

        // .titled (not .borderless) is what actually buys the native
        // rounded corners — a borderless panel is a plain rectangle by
        // default; a titled one gets AppKit's standard window corner
        // treatment for free, same as every normal window. The title bar
        // itself is made invisible the exact same way
        // AppDelegate+PinnedNote.swift already does for the pinned-note
        // panel: transparent, hidden title, all three standard buttons
        // hidden — so it reads as a plain rounded card, not a window with
        // chrome, while still getting the rounded corners that come from
        // being a real titled window under the hood.
        let panel = PreviewPanel(
            contentRect: frame,
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 200, height: 150)
        panel.persistSizeOnResize()
        panel.backgroundColor = theme.resolvedBackgroundColor
        let content = WikilinkPreviewContentView(
            store: store,
            noteID: note.id,
            theme: theme,
            requireModifierForLinkClick: requireModifierForLinkClick,
            showDuePill: showDuePill,
            showTagsInTitleBar: showTagsInTitleBar,
            noteTitles: noteTitles,
            onNavigate: { [weak self] navigatedTitle in
                self?.closePanel()
                self?.onNavigate?(navigatedTitle)
            },
            onEditableActivated: { [weak self] in
                self?.isEditableActivated = true
            },
            onPin: { [weak self] in
                self?.pinCurrentPeek()
            }
        )
        panel.contentView = FirstMouseHostingView(rootView: content)
        panel.setFrame(frame, display: true)
        // makeKeyAndOrderFront, not plain orderFront — a non-key window's
        // first click only activates it rather than registering as a real
        // click on its content, which is exactly why the title's
        // tap-to-navigate and the click-to-edit gesture both needed two
        // clicks (the first just made the panel key, the second was the
        // one that actually landed). AppDelegate+PinnedNote.swift's own
        // panel already makes itself key immediately for the same reason;
        // deviating from that specifically to avoid stealing focus from the
        // main editor was the direct cause of this bug.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installMonitors()
    }

    /// Computes the panel's frame directly in screen coordinates — above vs.
    /// below is decided by actually measuring available space, and the
    /// result is clamped to the screen's visible frame the same way
    /// AppDelegate+PinnedNote.swift already clamps its own panel, rather
    /// than trusting any framework-level "keep this on screen" behavior to
    /// get the placement right on its own.
    private func frame(for anchorRect: NSRect, in view: NSView) -> NSRect? {
        guard let window = view.window, let screen = window.screen else { return nil }
        let rectInWindow = view.convert(anchorRect, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        let size = Self.persistedPeekSize
        let gap: CGFloat = 4
        let visible = screen.visibleFrame

        let spaceBelow = rectOnScreen.minY - visible.minY
        let showsBelow = spaceBelow >= size.height + gap
        var origin = NSPoint(
            x: rectOnScreen.minX,
            y: showsBelow ? rectOnScreen.minY - size.height - gap : rectOnScreen.maxY + gap
        )
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    /// Promotes the current hold-to-peek into its own free-standing pinned
    /// window, handed to the app-lifetime PinnedPeekManager so it outlives the
    /// peek slot being reused (and the editor being torn down on a note switch)
    /// — which is what lets several sit open at once. The transient monitors go
    /// with the peek; the pinned window carries a native close button instead.
    private func pinCurrentPeek() {
        guard let pinned = panel else { return }
        panel = nil
        isEditableActivated = false
        anchorView = nil
        previewedTitle = nil
        shouldNavigateOnOutsideClick = nil
        removeMonitors()
        PinnedPeekManager.shared.adopt(pinned)
    }

    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        self.panel = nil
        isEditableActivated = false
        anchorView = nil
        previewedTitle = nil
        shouldNavigateOnOutsideClick = nil
        removeMonitors()
    }

    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleOutsideMouseDown(event) ?? event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        // The peek stays put once shown (dismiss with a click elsewhere, Escape,
        // or by peeking another link) rather than vanishing the instant Option
        // is released — that hold-to-peek behavior made pinning a race, since
        // reaching the pin button almost always meant letting go of Option
        // first, which closed the note out from under the click.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        mouseMonitor = nil
        keyMonitor = nil
        resignActiveObserver = nil
    }

    /// A click inside the panel itself needs to reach it normally (clicking
    /// in to edit, clicking a link inside the previewed note's own body,
    /// the title header's tap-to-navigate) — only a click *outside* the
    /// panel is this controller's concern at all. Among those: a click that
    /// the caller-supplied shouldNavigateOnOutsideClick recognizes as
    /// landing back on the anchor itself means "navigate," handled as a
    /// single atomic close-then-navigate rather than requiring a separate
    /// second click to actually hit the anchor again. Anything else outside
    /// is an ordinary dismiss, with the event still passed through
    /// afterward so normal interaction elsewhere is untouched.
    private func handleOutsideMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let panel, panel.isVisible else { return event }
        if event.window === panel {
            return event
        }
        if let anchorView, let previewedTitle, let shouldNavigateOnOutsideClick, event.window === anchorView.window {
            let point = anchorView.convert(event.locationInWindow, from: nil)
            if shouldNavigateOnOutsideClick(point, event.modifierFlags) {
                closePanel()
                onNavigate?(previewedTitle)
                return nil
            }
        }
        closePanel()
        return event
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let panel, panel.isVisible, event.keyCode == 53 else { return event }
        closePanel()
        return nil
    }
}

/// Owns pinned peek windows for the app's lifetime, so they survive the per-note
/// editor (and its WikilinkPreviewController) being torn down on a note switch,
/// and any number can sit open at once. Each is dismissed by its own pin button
/// (which closes the window). Leaving Envy just *hides* them (so a floating card
/// doesn't hover over other apps); they come back when Envy is active again,
/// kept as long as you like.
@MainActor
final class PinnedPeekManager {
    static let shared = PinnedPeekManager()
    private var panels: [PreviewPanel] = []
    private var resignObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    fileprivate func adopt(_ panel: PreviewPanel) {
        panel.isMovableByWindowBackground = true
        panels.append(panel)
        installObserversIfNeeded()
    }

    private func installObserversIfNeeded() {
        // Drop a window from the set when it actually closes (the pin button
        // routes through performClose, so this catches every dismissal).
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let panel = note.object as? PreviewPanel else { return }
                let id = ObjectIdentifier(panel)
                Task { @MainActor in self?.dropPanel(id) }
            }
        }
        // Leaving Envy hides the floating notes rather than closing them, so
        // they don't hover over other apps; returning brings them back.
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.panels.forEach { $0.orderOut(nil) } }
            }
        }
        if activateObserver == nil {
            activateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.panels.forEach { $0.orderFront(nil) } }
            }
        }
    }

    private func dropPanel(_ id: ObjectIdentifier) {
        panels.removeAll { ObjectIdentifier($0) == id }
        if panels.isEmpty { removeObservers() }
    }

    private func removeObservers() {
        for observer in [resignObserver, activateObserver, closeObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        resignObserver = nil
        activateObserver = nil
        closeObserver = nil
    }
}

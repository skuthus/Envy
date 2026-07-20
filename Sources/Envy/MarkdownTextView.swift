import SwiftUI
import AppKit
import EnvyCore

final class HoverAwareTextView: NSTextView {
    var onHoverPoint: ((NSPoint) -> Void)?
    var onHoverExit: (() -> Void)?
    /// Returns true if the click was handled (e.g. toggled a checkbox) — in
    /// that case the click is consumed rather than passed to normal
    /// cursor-placement/selection handling.
    var onClickPoint: ((NSPoint) -> Bool)?
    /// Whether a given point is over a clickable checkbox or footnote
    /// reference — checked on every mouse move to explicitly set the
    /// pointing-hand cursor. NSTextView manages its own I-beam cursor via a
    /// mechanism that doesn't reliably respect resetCursorRects()/
    /// addCursorRect (tried first; had no effect), so this sets NSCursor
    /// directly instead of relying on that system.
    var isOverClickTarget: ((NSPoint) -> Bool)?
    /// Fired once, the moment a click lands while `isEditable` is false —
    /// used by the wikilink hover preview, which starts non-editable and
    /// switches to a live editor on first click. Left nil (the ordinary
    /// case, isEditable always true) this never fires.
    var onRequestEditable: (() -> Void)?
    /// Returns true if an option-click on a wikilink was handled (opened
    /// the preview popover) — only ever consulted when the option modifier
    /// is actually held, and only meaningful when link previews are in
    /// .optionClick trigger mode; nil/false otherwise. Option was chosen
    /// over control specifically because control-click is macOS's
    /// traditional secondary-click/right-click equivalent — using it here
    /// collided with the standard context menu, where option-click has no
    /// competing system meaning to collide with.
    var onOptionClickPoint: ((NSPoint) -> Bool)?
    private var hoverTrackingArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isEditable {
            isEditable = true
            onRequestEditable?()
            window?.makeFirstResponder(self)
        }
        if event.modifierFlags.contains(.option), onOptionClickPoint?(point) == true { return }
        if onClickPoint?(point) == true { return }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        onHoverPoint?(point)
        if isOverClickTarget?(point) == true {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverExit?()
        NSCursor.iBeam.set()
    }
}

/// The inline ghost-text suggestion shown after an open "[[" — purely a
/// visual overlay, never part of the real text storage, so it needs no
/// cleanup/undo bookkeeping of its own. Overrides hitTest so it never steals
/// clicks meant for the text view underneath it.
private final class WikiLinkGhostLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws a task-list checkbox's ☑/☐ glyph as a floating overlay instead of
/// substituting it onto the real (now-collapsed/invisible) "[" character —
/// see Coordinator.updateCheckboxOverlays() for why. Purely visual, same
/// hitTest-returns-nil treatment as WikiLinkGhostLabel: clicks are handled
/// by hit-testing the checkbox's real position directly, not this view.
private final class CheckboxOverlayLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A plain NSScrollView, except it doesn't start claiming scroll-wheel
/// events the instant the mouse crosses into its bounds — only once the
/// mouse has rested there for dwellThreshold. Before that, scroll events
/// are handed to the nearest enclosing NSScrollView instead. Without this,
/// scrolling through the host note past an embedded note's own box hijacks
/// the scroll the moment the cursor merely passes over it, even though the
/// user's clearly still scrolling the *host* document, not that specific
/// embed. Only used where MarkdownTextView is itself nested inside another
/// scrollable region (see allowsScrollPassthrough) — every other caller
/// (the main editor, the pinned popup, preview popovers) is its own
/// top-level scrollable surface with nothing above it to hand off to.
///
/// Walking `superview` (not the responder chain via `nextResponder`) to
/// find that enclosing scroll view — `superview` is unambiguous even
/// across the SwiftUI hosting bridge in between (an NSHostingView's own
/// content still has to sit somewhere in the real AppKit view hierarchy to
/// render or receive events at all), which the responder chain crossing
/// that same bridge turned out not to be reliably.
final class NestedAwareScrollView: NSScrollView {
    private var mouseEnteredAt: Date?
    private var hoverTrackingArea: NSTrackingArea?
    /// Short enough that deliberately scrolling through an embed still
    /// feels immediate once you've paused on it; long enough that a scroll
    /// gesture already in progress on the host note, whose cursor merely
    /// passes over an embed along the way, doesn't get momentarily
    /// hijacked the instant it crosses the embed's bounds.
    private static let dwellThreshold: TimeInterval = 0.6

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if mouseEnteredAt == nil { mouseEnteredAt = Date() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseEnteredAt = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let dwelled = mouseEnteredAt.map { Date().timeIntervalSince($0) >= Self.dwellThreshold } ?? false
        guard dwelled else {
            forwardToEnclosingScrollView(event)
            return
        }
        super.scrollWheel(with: event)
    }

    private func forwardToEnclosingScrollView(_ event: NSEvent) {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView, scrollView !== self {
                scrollView.scrollWheel(with: event)
                return
            }
            candidate = view.superview
        }
    }
}

/// The pill drawn over a note's "⎈" provenance line while signature
/// protection is on — shows the line's own text as a non-editable capsule.
/// Purely visual; the shouldChangeTextIn veto is what enforces the
/// uneditability. Styled with the theme's marker color, the same quiet
/// palette collapsed markdown markers use.
private struct SignaturePillView: View {
    let text: String
    var theme: Theme
    var onRemove: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(Color(nsColor: theme.resolvedMarkerColor))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(nsColor: theme.resolvedMarkerColor).opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color(nsColor: theme.resolvedMarkerColor).opacity(0.35), lineWidth: 1))
            .help("Marked as AI-authored and protected. Right-click to remove it, or turn off \u{201C}Protect AI signatures\u{201D} in Settings.")
            .contextMenu {
                Button("Remove AI Mark", role: .destructive, action: onRemove)
            }
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var onNavigate: (String) -> Void
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var searchQuery: String
    var fontZoom: CGFloat = 0
    var plainTextMode: Bool = false
    /// False only for the wikilink hover preview's initial, click-to-edit
    /// state — every other caller (the main editor, the pinned popup, the
    /// template editor) leaves this at the default, always-editable.
    var isEditable: Bool = true
    /// Fires once when a click lands while `isEditable` is false — see
    /// HoverAwareTextView.onRequestEditable.
    var onRequestEditable: (() -> Void)? = nil
    /// Shared NoteStore, used only to resolve a hovered wikilink's title to
    /// an actual Note for the preview popover. nil for callers that don't
    /// want link previews at all (the pinned popup and template editor
    /// don't have — or don't want — a live NoteStore to share here; see
    /// PinnedNotePopoverView's own doc comment on why it avoids one).
    var store: NoteStore? = nil
    /// Whether option-clicking a wikilink opens the preview popover —
    /// irrelevant when `store` is nil (that caller doesn't want previews at
    /// all).
    var linkPreviewTrigger: LinkPreviewTrigger = .optionClick
    /// The id of the note this text view is itself showing (NoteEditorView's
    /// own noteID) — lets the preview popover recognize "this link points
    /// right back at the note you're already looking at" and skip showing a
    /// second, independent edit surface on the same content instead of
    /// risking two competing unsaved buffers. nil for callers where this
    /// doesn't apply (store is already nil for those too).
    var currentNoteID: String? = nil
    /// Passed straight through to the preview popover's own header chips —
    /// same two Settings toggles the main editor's title bar itself
    /// respects (NoteEditorView.header), so the preview never shows a chip
    /// the user turned off there.
    var showDuePill: Bool = true
    var showTagsInTitleBar: Bool = false
    /// Existing note titles, offered as an inline ghost-text completion while
    /// typing inside an open "[[" — same prefix-match rule as the search
    /// box's own suggestion. Expected ordered most-recently-modified first,
    /// so a tie between several matching titles favors whichever note was
    /// touched most recently.
    var noteTitles: [String] = []
    /// Bumped by NoteEditorView only when `text` changed because the note was
    /// edited externally (not from this view's own typing), since `text` is
    /// otherwise treated as a lagging echo — see the note on updateNSView.
    var externalReloadToken: Int = 0
    /// The range an external edit actually changed, to briefly flash once
    /// highlightTrigger fires. Read only at the moment the trigger changes,
    /// so it doesn't matter that NoteEditorView clears it back to nil shortly
    /// after — see the note there for why.
    var highlightRange: NSRange?
    /// Bumped by NoteEditorView once it's confirmed the user can actually see
    /// the app (immediately if already active, or on the next
    /// didBecomeActiveNotification otherwise).
    var highlightTrigger: Int = 0
    /// Applied once, right after the fresh NSTextView is created — restores
    /// the cursor (and scrolls it into view) to wherever the caller last
    /// saw it, instead of always landing at the very top. Not re-applied on
    /// later updateNSView calls, only at creation, same as everything else
    /// in makeNSView that only makes sense to do once per note.
    var initialSelectedRange: NSRange?
    /// Fires on every cursor/selection change — used by callers that want
    /// to remember the cursor position across a full teardown/recreation of
    /// this view (e.g. the pinned note popup, which reloads fresh from disk
    /// on every reopen rather than staying alive in the background).
    var onSelectionChange: ((NSRange) -> Void)?
    /// False only for a note already being shown *as* an embed — see
    /// MarkdownStyler.style's own allowsEmbeds parameter for why nesting
    /// stops at one level.
    var allowsEmbeds: Bool = true
    /// True only for a note being shown *as* an embed — see
    /// NestedAwareScrollView's own doc comment for why that's the one
    /// context that needs scroll-passthrough instead of a plain NSScrollView.
    var allowsScrollPassthrough: Bool = false
    /// Set only when this view *is* an embed's content, so it can tell the
    /// host note how much room to reserve. See EmbeddedNoteView.
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// When true, an edit in *this* editor that removes the note's "⎈"
    /// provenance line puts it right back — the opt-in signature-protection
    /// setting. Soft and Envy-only by nature: the file stays plain text and
    /// any other editor can still strip the line. Only the main note editor
    /// sets this; embeds/templates/previews leave it off.
    var protectAISignature: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = HoverAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        // Selection itself is just logical state, safe to set immediately —
        // but scrolling it into view has to wait (see the deferred block
        // near the end of this function): at this point textView has no
        // enclosing NSScrollView yet (constructed just below) and no real
        // frame at all (SwiftUI hasn't inserted the view this function
        // returns into the window yet), so scrollRangeToVisible here would
        // have nothing meaningful to scroll within.
        if let initialSelectedRange, initialSelectedRange.location <= (text as NSString).length {
            textView.setSelectedRange(initialSelectedRange)
        }

        textView.onHoverPoint = { [weak coordinator = context.coordinator] point in
            coordinator?.handleHover(at: point)
        }
        textView.onHoverExit = { [weak coordinator = context.coordinator] in
            coordinator?.clearHover()
        }
        textView.onClickPoint = { [weak coordinator = context.coordinator] point in
            coordinator?.handleClick(at: point) ?? false
        }
        textView.onRequestEditable = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onRequestEditable?()
        }
        textView.onOptionClickPoint = { [weak coordinator = context.coordinator] point in
            coordinator?.handleOptionClick(at: point) ?? false
        }
        textView.isOverClickTarget = { [weak coordinator = context.coordinator] point in
            // Plain-text mode never renders checkboxes/footnotes/due tokens
            // as anything but literal characters, so there's nothing there
            // to click.
            guard let coordinator, coordinator.parent.plainTextMode == false else { return false }
            return coordinator.checkboxHitRects().contains(where: { $0.contains(point) })
                || coordinator.footnoteHitRects().contains(where: { $0.contains(point) })
                || coordinator.dueTokenHitRects().contains(where: { $0.contains(point) })
        }

        let scrollView: NSScrollView = allowsScrollPassthrough ? NestedAwareScrollView() : NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        applyTheme(theme, to: textView, scrollView: scrollView)
        if let textStorage = textView.textStorage {
            if plainTextMode {
                MarkdownStyler.clearFormatting(textStorage: textStorage, text: text, theme: theme, fontSizeAdjustment: fontZoom)
            } else {
                MarkdownStyler.style(textStorage: textStorage, text: text, theme: theme, searchQuery: searchQuery, fontSizeAdjustment: fontZoom, allowsEmbeds: allowsEmbeds, embedHeights: context.coordinator.embedHeights, noteTitles: noteTitles)
            }
        }
        context.coordinator.updateCheckboxOverlays(in: textView)
        context.coordinator.updateEmbedOverlays(in: textView)
        context.coordinator.updateSignaturePill(in: textView)
        // SwiftUI's first call to makeNSView often happens before this view
        // has its real, final width from the surrounding layout (the note
        // list/editor split isn't necessarily settled yet) — the checkbox
        // overlay positions computed just above, from the layout manager's
        // line-wrapping at whatever width existed at that moment, could
        // already be stale by the time the window actually finishes laying
        // out. Nothing in SwiftUI's own diffing notices that (none of
        // theme/searchQuery/fontZoom/text actually changed), so it never
        // calls updateNSView again on its own — this is what made checklists
        // look misaligned until something else (clicking into the editor,
        // which happens to trigger a re-render) recomputed them. Observing
        // the text view's own frame changing directly catches the real
        // layout settling regardless of what causes it.
        textView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak coordinator = context.coordinator, weak textView] _ in
            guard let coordinator, let textView else { return }
            coordinator.updateCheckboxOverlays(in: textView)
            coordinator.updateEmbedOverlays(in: textView)
            coordinator.updateSignaturePill(in: textView)
        }
        // Belt and suspenders alongside ensureLayout() (inside
        // updateCheckboxOverlays itself) and the frame observer above: this
        // repositions the overlays again one runloop turn later, after
        // SwiftUI's own layout pass for this render has fully committed —
        // catching it even in the case where the container's width never
        // actually changes again after this initial call (so the frame
        // observer above would never fire) but was still provisional at the
        // moment this function ran.
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.updateCheckboxOverlays(in: textView)
            coordinator.updateEmbedOverlays(in: textView)
            coordinator.updateSignaturePill(in: textView)
        }
        // Same "wait one runloop turn for real layout/geometry" reasoning as
        // the checkbox overlay positioning above — scrollRangeToVisible
        // needs the scroll view to already know its real size, which isn't
        // true yet at the point makeNSView runs.
        if let initialSelectedRange, initialSelectedRange.location <= (text as NSString).length {
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(initialSelectedRange)
            }
        }
        context.coordinator.lastSearchQuery = searchQuery
        context.coordinator.lastFontZoom = fontZoom
        context.coordinator.lastPlainTextMode = plainTextMode
        context.coordinator.lastExternalReloadToken = externalReloadToken
        context.coordinator.lastHighlightTrigger = highlightTrigger
        return scrollView
    }

    static func currentSelection(of textView: NSTextView) -> NSRange? {
        textView.window?.firstResponder === textView ? textView.selectedRange() : nil
    }

    // Note switches are handled by giving NoteEditorView a `.id(noteID)` in
    // ContentView, which tears down and recreates this whole view (and its
    // Coordinator/NSTextView) per note via makeNSView — so this never needs to
    // reconcile `text` against a different note's content. It only ever needs
    // to react to theme/search-query changes for the note already showing,
    // and it restyles using the view's own live content rather than `text`,
    // since `text` is just an echo of the last edit and can lag textView.string
    // by a render cycle mid-typing. Comparing/pushing from `text` here was the
    // previous bug: a stale value could overwrite what was just typed, which
    // is what caused headings to flicker between their styled and plain form.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        defer { context.coordinator.reportContentHeightIfNeeded(in: textView) }

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        applyTheme(theme, to: textView, scrollView: scrollView)

        // An external change (another app editing this note's file, then
        // NoteEditorView pulling the fresh content in) — replace the text
        // view's content directly rather than waiting for the user to switch
        // notes and back. Guarded by the token rather than a plain `text !=
        // textView.string` check, since that comparison is exactly what the
        // note atop this function warns against reintroducing.
        var justReplacedText = false
        if context.coordinator.lastExternalReloadToken != externalReloadToken {
            context.coordinator.lastExternalReloadToken = externalReloadToken
            let cursor = textView.selectedRange()
            textView.string = text
            let clampedLocation = min(cursor.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
            justReplacedText = true
        }

        if justReplacedText || context.coordinator.lastTheme != theme
            || context.coordinator.lastSearchQuery != searchQuery
            || context.coordinator.lastFontZoom != fontZoom
            || context.coordinator.lastPlainTextMode != plainTextMode
            || context.coordinator.lastProtectAISignature != protectAISignature {
            if let textStorage = textView.textStorage {
                if plainTextMode {
                    MarkdownStyler.clearFormatting(textStorage: textStorage, text: textView.string, theme: theme, fontSizeAdjustment: fontZoom)
                } else {
                    MarkdownStyler.style(
                        textStorage: textStorage,
                        text: textView.string,
                        theme: theme,
                        revealedLinkRange: context.coordinator.hoveredLinkRange,
                        searchQuery: searchQuery,
                        cursorSelection: Self.currentSelection(of: textView),
                        fontSizeAdjustment: fontZoom,
                        allowsEmbeds: allowsEmbeds,
                        embedHeights: context.coordinator.embedHeights,
                        noteTitles: noteTitles
                    )
                }
            }
            context.coordinator.updateCheckboxOverlays(in: textView)
            context.coordinator.updateEmbedOverlays(in: textView)
            context.coordinator.updateSignaturePill(in: textView)
            context.coordinator.lastTheme = theme
            context.coordinator.lastSearchQuery = searchQuery
            context.coordinator.lastFontZoom = fontZoom
            context.coordinator.lastPlainTextMode = plainTextMode
            context.coordinator.lastProtectAISignature = protectAISignature
        }

        if context.coordinator.lastHighlightTrigger != highlightTrigger {
            context.coordinator.lastHighlightTrigger = highlightTrigger
            if let highlightRange, let textStorage = textView.textStorage,
               highlightRange.length > 0,
               highlightRange.location + highlightRange.length <= textStorage.length {
                context.coordinator.flashHighlight(range: highlightRange, in: textView)
            }
        }

        // Focus is handled by .focusable() + .focused(_:equals: .editor) on
        // this view where it's instantiated in NoteEditorView, so it
        // coordinates properly with the search field's own .focused() binding
        // through SwiftUI's own focus engine — a manual makeFirstResponder
        // bridge here was fighting that: SwiftUI kept reasserting .search
        // (the only view it recognized as an actual focus target) since
        // .editor didn't correspond to anything it knew about.
    }

    private func applyTheme(_ theme: Theme, to textView: NSTextView, scrollView: NSScrollView) {
        // Deliberately NOT setting textView.font here. On a non-rich-text view
        // (isRichText = false, set in makeNSView), assigning .font directly
        // resets the font for the *entire* text uniformly — wiping out every
        // per-character font MarkdownStyler applied (headings, bold, italic).
        // This ran on every keystroke (applyTheme is called from updateNSView,
        // which fires on every edit), silently reverting styled text back to
        // plain right after textDidChange had just styled it. The base font
        // for unstyled text is already covered by MarkdownStyler.style's own
        // textStorage.setAttributes(...) call over the full range.

        // Always solid, regardless of the window's own transparency — body text
        // needs a legible, non-blurred backdrop even when the surrounding chrome
        // (sidebar, titlebar) is translucent.
        textView.drawsBackground = true
        textView.backgroundColor = theme.resolvedBackgroundColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.resolvedBackgroundColor
        textView.insertionPointColor = theme.resolvedTextColor
        // NSTextView's own default selection color otherwise wins — a
        // system-derived light blue, regardless of anything else in the
        // theme.
        let selectedTextBackground = theme.resolvedSelectedTextColor
        var selectedTextAttributes: [NSAttributedString.Key: Any] = [.backgroundColor: selectedTextBackground]
        // Checked against the base text color specifically, not every
        // possible per-character color (links, tags, etc.) — selectedTextAttributes
        // is one fixed attribute set applied to whatever's selected, not
        // something that can vary per character the way the static text
        // storage's own attributes can. Covers the common case (selecting
        // plain body text) that a poor selection-color choice would
        // otherwise make invisible; only sets .foregroundColor at all when
        // it's actually needed, so an already-fine pairing still shows
        // each selected character's own real color underneath.
        let perceivedSelectedTextBackground = MarkdownStyler.compositedColor(selectedTextBackground, over: theme.resolvedBackgroundColor)
        let adjustedTextColor = MarkdownStyler.legibleForeground(theme.resolvedTextColor, over: perceivedSelectedTextBackground)
        if adjustedTextColor != theme.resolvedTextColor {
            selectedTextAttributes[.foregroundColor] = adjustedTextColor
        }
        textView.selectedTextAttributes = selectedTextAttributes
        // NSTextView renders `.link`-attributed ranges with its own default color
        // (system blue), ignoring any per-range `.foregroundColor` we set in
        // MarkdownStyler, unless this is overridden explicitly.
        textView.linkTextAttributes = [
            .foregroundColor: theme.resolvedLinkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: HoverAwareTextView?
        var hoveredLinkRange: NSRange?
        let previewController = WikilinkPreviewController()
        var lastTheme: Theme?
        var lastSearchQuery: String = ""
        var lastFontZoom: CGFloat = 0
        var lastPlainTextMode: Bool = false
        var lastProtectAISignature: Bool = false
        var lastExternalReloadToken: Int = 0
        var lastHighlightTrigger: Int = 0
        private var highlightFadeTask: Task<Void, Never>?

        private var cachedText: String = ""
        private var cachedWikiLinkRanges: [NSRange] = []
        private var isHandlingTextChange = false
        /// True only for the brief span of the "Remove AI Mark" edit, so the
        /// signature-protection veto lets that one deliberate removal through.
        private var isRemovingSignature = false
        /// Set by shouldChangeText(in:replacementString:) when the in-flight
        /// edit is a single plain character typed at the cursor (as opposed
        /// to a paste, a deletion, or a programmatic edit) and consumed by
        /// textDidChange right after — the handoff that lets auto-closing
        /// react to "the user just typed this" without needing to diff text
        /// before/after itself.
        private var pendingAutoCloseTrigger: (character: String, location: Int)?
        /// Set by shouldChangeText(in:replacementString:) when the in-flight
        /// edit is a plain single-character backspace, capturing which
        /// character was actually deleted — consumed by textDidChange right
        /// after so a backspace that deletes an opener can also remove its
        /// now-empty closer sitting right at the cursor.
        private var pendingBackspaceTrigger: (deletedCharacter: String, location: Int)?
        /// Lazily-created overlay for the wiki-link ghost suggestion — a
        /// subview of the text view itself so it scrolls along with content,
        /// never touched by restyle() since it's not part of textStorage.
        private var wikiLinkGhostLabel: WikiLinkGhostLabel?
        /// One floating overlay per checkbox currently in the text, pooled
        /// and repositioned in updateCheckboxOverlays() rather than
        /// recreated each time — see that function for why checkboxes are
        /// drawn this way instead of via NSGlyphInfo substitution.
        private var checkboxOverlayLabels: [CheckboxOverlayLabel] = []
        /// One floating overlay per "![[Note Title]]" embed currently in the
        /// text, pooled and repositioned in updateEmbedOverlays() exactly
        /// like checkboxOverlayLabels above — reused by index (not
        /// recreated) so an embed's own in-progress edit or click-to-edit
        /// state survives a restyle triggered by editing the host note
        /// somewhere else, the same reasoning that comment gives for why
        /// checkboxes are pooled instead of rebuilt each time.
        // AnyView, not NSHostingView<EmbeddedNoteView> — wrapping the root
        // view in .id(title) below forces a genuinely fresh @State
        // container when a pooled slot's title changes, rather than
        // relying on reassigning `rootView` to update an already-live
        // EmbeddedNoteView's @State in place (which doesn't reliably
        // re-run its onChange handlers, so a retyped title could keep
        // showing the *previous* title's content).
        private var embedOverlayViews: [NSHostingView<AnyView>] = []
        /// The floating pill drawn over the "⎈" provenance line when
        /// signature protection is on — a single view (one signature per
        /// note), created lazily. Hidden when protection is off or the note
        /// has no signature.
        private var signaturePillView: NSHostingView<SignaturePillView>?
        /// Embed titles collapsed via EmbeddedNoteView's own chevron —
        /// plain in-memory UI state, not saved anywhere (same as
        /// ContentView's own backlinksExpanded), and owned here rather
        /// than as @State inside EmbeddedNoteView itself since it also has
        /// to reach MarkdownStyler.style()'s reservation height, which
        /// runs before any SwiftUI view for the embed even exists yet.
        /// The suggested remainder text currently on screen, and the cursor
        /// location it was computed for. Accepting only applies if the
        /// cursor still matches — Tab/Right-arrow otherwise fall through to
        /// their normal behavior.
        private var wikiLinkGhostRemainder: String?
        private var wikiLinkGhostAnchor: Int?
        // NSObjectProtocol isn't Sendable, which the compiler otherwise flags
        // on the nonisolated deinit below (deinit is always nonisolated, even
        // for a @MainActor class) — safe in practice, matching the same
        // pattern/reasoning as NoteStore's eventStream property.
        nonisolated(unsafe) private var boldObserver: NSObjectProtocol?
        nonisolated(unsafe) private var italicObserver: NSObjectProtocol?
        // Registered once the text view exists, in makeNSView below.
        nonisolated(unsafe) var frameObserver: NSObjectProtocol?

        /// Measured height per embed title (lowercased), feeding the space
        /// the styler reserves. Keyed by title rather than by index so it
        /// survives embeds being added, removed or reordered.
        var embedHeights: [String: CGFloat] = [:]

        /// Last height handed to onContentHeightChange, so an unchanged
        /// layout doesn't re-trigger the host's restyle.
        private var lastReportedContentHeight: CGFloat = 0

        /// Measures the laid-out text and reports it, if it moved enough to
        /// matter. The 1pt threshold isn't cosmetic: the host reacts by
        /// restyling, which lays this out again, so reporting every
        /// sub-pixel wobble would be a loop that never settles.
        @MainActor
        func reportContentHeightIfNeeded(in textView: NSTextView) {
            guard let report = parent.onContentHeightChange,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            let inset = textView.textContainerInset.height * 2
            let height = used + inset
            guard abs(height - lastReportedContentHeight) > 1 else { return }
            lastReportedContentHeight = height
            report(height)
        }

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            super.init()
            // Registered directly on the Coordinator (rather than routed
            // through ContentView) since Cmd+B/Cmd+I need the live NSTextView
            // and its current selection, which only this object has — there's
            // only ever one NoteEditorView/Coordinator alive at a time, torn
            // down and recreated per note via .id(noteID), so this doesn't
            // need to disambiguate between multiple notes.
            boldObserver = NotificationCenter.default.addObserver(forName: .boldSelectionRequested, object: nil, queue: .main) { [weak self] _ in
                self?.toggleBold()
            }
            italicObserver = NotificationCenter.default.addObserver(forName: .italicSelectionRequested, object: nil, queue: .main) { [weak self] _ in
                self?.toggleItalic()
            }
        }

        deinit {
            if let boldObserver { NotificationCenter.default.removeObserver(boldObserver) }
            if let italicObserver { NotificationCenter.default.removeObserver(italicObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        /// Intercepts single-character insertions before they land, purely to
        /// detect two things the post-hoc textDidChange pass can't see on its
        /// own: (1) a managed closer typed right where one already sits, so
        /// it can "type through" it instead of duplicating it, and (2) which
        /// exact character was just typed and where, handed off via
        /// pendingAutoCloseTrigger for the actual auto-close logic in
        /// textDidChange. Anything that isn't a plain single-char insert
        /// (paste, deletion, replacing a selection) is left alone entirely.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Every edit funnels through here — user typing, and every
            // programmatic replaceCharacters site in this file (checkbox
            // toggles, emoji expansion, list renumbering, bold/italic
            // wrapping) explicitly calls shouldChangeText first. Recording
            // the edit's span is what lets windowedRestyleRange cover an
            // edit that lands far from the cursor. Covers both the old text
            // (affected range) and the incoming replacement's extent.
            let replacementLength = (replacementString as NSString?)?.length ?? 0
            noteRestyleInvalidation(NSRange(location: affectedCharRange.location, length: max(affectedCharRange.length, replacementLength)))

            // Typing an opener over a selection wraps it rather than
            // replacing it: select "moon", type "[", get "[moon]" with the
            // word still selected — so a second "[" gives "[[moon]]". Same
            // convention every code editor uses, and the same thing ⌘B/⌘I
            // already do here via toggleEmphasis.
            if !isHandlingTextChange, affectedCharRange.length > 0,
               let typed = replacementString, let closer = Self.closerForOpener[typed] {
                let nsText = textView.string as NSString
                let selected = nsText.substring(with: affectedCharRange)
                let wrapped = typed + selected + closer
                if textView.shouldChangeText(in: affectedCharRange, replacementString: wrapped) {
                    isHandlingTextChange = true
                    textView.textStorage?.replaceCharacters(in: affectedCharRange, with: wrapped)
                    // Reselect the original text, now sitting inside the new
                    // pair, so typing the opener again wraps a second time.
                    textView.setSelectedRange(NSRange(
                        location: affectedCharRange.location + (typed as NSString).length,
                        length: affectedCharRange.length
                    ))
                    isHandlingTextChange = false
                    textView.didChangeText()
                }
                return false
            }
            // Signature protection. Two rejections, no more:
            //   (a) any edit that touches the "⎈" line's own characters, and
            //   (b) an edit ending exactly at the signature that would leave a
            //       non-newline right before it — i.e. pull the ⎈ off the
            //       start of its line, which is how a merge (backspace at the
            //       line start) or an insert-just-before would quietly defeat
            //       the ^⎈ detection and unprotect it.
            // Everything else is allowed — crucially, ⌘A-then-delete: the
            // selection is clamped to end at the signature (see
            // willChangeSelectionFromCharacterRanges), so deleting it clears
            // the whole body and just leaves the signature at the top, still
            // line-anchored. Runs even in plainTextMode. External reloads set
            // textView.string directly and never pass through here, so the
            // connector can still re-stamp freely.
            if parent.protectAISignature, !isHandlingTextChange, !isRemovingSignature,
               let signatureRange = MarkdownStyler.aiSignatureRange(in: textView.string) {
                let signatureEnd = signatureRange.location + signatureRange.length
                let editEnd = affectedCharRange.location + affectedCharRange.length
                let touchesSignature = affectedCharRange.location < signatureEnd && editEnd > signatureRange.location
                var wouldUnanchor = false
                if editEnd == signatureRange.location {
                    let replacement = replacementString ?? ""
                    if !replacement.isEmpty {
                        wouldUnanchor = !replacement.hasSuffix("\n")
                    } else if affectedCharRange.location > 0 {
                        wouldUnanchor = (textView.string as NSString).character(at: affectedCharRange.location - 1) != 10
                    }
                }
                if touchesSignature || wouldUnanchor {
                    pendingAutoCloseTrigger = nil
                    pendingBackspaceTrigger = nil
                    return false
                }
            }
            guard !parent.plainTextMode else {
                pendingAutoCloseTrigger = nil
                pendingBackspaceTrigger = nil
                return true
            }
            let nsText = textView.string as NSString
            if (replacementString?.isEmpty ?? true), affectedCharRange.length == 1 {
                pendingAutoCloseTrigger = nil
                let deletedCharacter = nsText.substring(with: affectedCharRange)
                pendingBackspaceTrigger = (deletedCharacter, affectedCharRange.location)
                return true
            }
            pendingBackspaceTrigger = nil
            guard let replacementString, replacementString.count == 1, affectedCharRange.length == 0 else {
                pendingAutoCloseTrigger = nil
                return true
            }
            if Self.managedCloserCharacters.contains(replacementString),
               affectedCharRange.location < nsText.length,
               nsText.substring(with: NSRange(location: affectedCharRange.location, length: 1)) == replacementString {
                pendingAutoCloseTrigger = nil
                textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                return false
            }
            pendingAutoCloseTrigger = (replacementString, affectedCharRange.location)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isHandlingTextChange = true
            defer { isHandlingTextChange = false }
            // Plain-text mode skips every markdown-aware smart-editing
            // behavior, not just visual styling — emoji expansion and
            // auto-renumbering are still "the app noticing markdown" in a
            // way a plain editor shouldn't do.
            if !parent.plainTextMode {
                if let trigger = pendingAutoCloseTrigger {
                    pendingAutoCloseTrigger = nil
                    autoCloseIfNeeded(typed: trigger.character, insertedAt: trigger.location, in: textView)
                }
                if let trigger = pendingBackspaceTrigger {
                    pendingBackspaceTrigger = nil
                    collapseMatchingCloseIfNeeded(afterDeletingOpener: trigger.deletedCharacter, at: trigger.location, in: textView)
                }
                expandEmojiShortcodeIfNeeded(in: textView)
                expandLigatureIfNeeded(in: textView)
                if parent.allowsEmbeds {
                    ensureEmbedRoomIfNeeded(in: textView)
                }
            }
            parent.text = textView.string
            restyle(textView)
            if !parent.plainTextMode {
                renumberOrderedListIfNeeded(in: textView)
            }
            updateWikiLinkGhostSuggestion(in: textView)
        }

        private static let managedCloserCharacters: Set<String> = ["]", ")", "`", "*", "~"]

        /// The closer each opener wraps a selection with.
        static let closerForOpener: [String: String] = ["[": "]", "(": ")", "`": "`", "*": "*", "~": "~"]

        /// Auto-closes markdown pairs immediately after the character that
        /// opens them: "[[" completes to "[[|]]", a lone backtick or
        /// asterisk gets its mirror right away, "~~" completes once the
        /// second tilde lands (a single "~" means nothing in Envy's
        /// markdown), and "(" auto-closes only right after "]", completing
        /// a "[text](url)" link. Driven entirely by pattern-matching the
        /// text around the cursor after the fact rather than tracking which
        /// characters were auto-inserted, so it stays correct even if the
        /// user deletes or retypes around a pair by hand.
        @MainActor
        private func autoCloseIfNeeded(typed: String, insertedAt location: Int, in textView: NSTextView) {
            let nsText = textView.string as NSString
            let cursor = location + 1

            func char(at index: Int) -> String? {
                guard index >= 0, index < nsText.length else { return nil }
                return nsText.substring(with: NSRange(location: index, length: 1))
            }
            func insert(_ text: String, at insertLocation: Int) {
                let range = NSRange(location: insertLocation, length: 0)
                guard textView.shouldChangeText(in: range, replacementString: text) else { return }
                textView.textStorage?.replaceCharacters(in: range, with: text)
                textView.setSelectedRange(NSRange(location: insertLocation, length: 0))
                textView.didChangeText()
            }
            // Normalizes a just-typed second opener (the "[" in "[[", or the
            // "~" in "~~") against whatever already follows the cursor: a
            // complete closing pair sitting right there is left as-is, a
            // single closer gets upgraded to a full pair, and nothing there
            // gets a fresh pair inserted.
            func closeSecondOpener(with closer: String) {
                let doubled = closer + closer
                if char(at: cursor) == closer && char(at: cursor + 1) == closer { return }
                if char(at: cursor) == closer {
                    // Replace the single existing closer with the full
                    // doubled pair in one edit, rather than inserting
                    // alongside it — inserting just the extra closer
                    // character would be a single-char edit matching that
                    // same closer, which shouldChangeTextIn's "type through
                    // it" skip-over logic would treat as the user retyping
                    // an existing character and swallow entirely.
                    let range = NSRange(location: cursor, length: 1)
                    guard textView.shouldChangeText(in: range, replacementString: doubled) else { return }
                    textView.textStorage?.replaceCharacters(in: range, with: doubled)
                    textView.setSelectedRange(NSRange(location: cursor, length: 0))
                    textView.didChangeText()
                } else {
                    insert(doubled, at: cursor)
                }
            }

            func isWordCharacter(_ text: String?) -> Bool {
                guard let text else { return false }
                return text.rangeOfCharacter(from: .alphanumerics) != nil
            }

            // Nothing auto-closes directly before a word. Typing "[[" to the
            // left of "moon" used to give "[[|]]moon", stranding the word
            // outside the link you were plainly trying to make — and the same
            // for every other pair. Suppressing here leaves "[[|moon", so you
            // can walk to the end of the word and close it, or (better) select
            // the word first and let the wrap above do it in one keystroke.
            //
            // Matches the default in VS Code, Xcode and JetBrains: auto-close
            // only before whitespace, punctuation, or the end of a line.
            if isWordCharacter(char(at: cursor)) { return }

            // And nothing symmetric auto-closes directly *after* a word. For
            // "*", "`" and "~" the same character opens and closes, so one
            // typed right after a word is finishing emphasis, not starting
            // it — CommonMark says as much, since a delimiter preceded by a
            // word and followed by whitespace can only be a closer. Without
            // this, closing "*word" by hand produced "*word*|*".
            //
            // Looks past any run of the same delimiter already sitting there,
            // so the second "*" of a closing "**" is judged against the "d"
            // of "bold" rather than against its own first star — otherwise
            // "**bold**" typed by hand picked up a stray fifth asterisk.
            //
            // "[" and "(" are exempt: those are unambiguously openers no
            // matter what precedes them.
            if typed == "*" || typed == "`" || typed == "~" {
                var index = location - 1
                while char(at: index) == typed { index -= 1 }
                if isWordCharacter(char(at: index)) { return }
            }

            switch typed {
            case "`":
                // Suppress on the 3rd backtick in a row — completing a
                // ```fenced block```, not opening a new inline-code pair.
                guard !(char(at: location - 1) == "`" && char(at: location - 2) == "`") else { return }
                insert("`", at: cursor)

            case "*":
                // Suppress at the start of a line (this "*" is more likely a
                // bullet-list marker than the start of *italic*).
                let lineStart = nsText.lineRange(for: NSRange(location: location, length: 0)).location
                let prefix = nsText.substring(with: NSRange(location: lineStart, length: location - lineStart))
                guard !prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
                // Suppress on the 3rd asterisk in a row — completing
                // ***bold italic***, not opening a new pair.
                guard !(char(at: location - 1) == "*" && char(at: location - 2) == "*") else { return }
                insert("*", at: cursor)

            case "[":
                if char(at: location - 1) == "[" {
                    closeSecondOpener(with: "]")
                } else {
                    // A single "[" is valid on its own, for [text](url).
                    insert("]", at: cursor)
                }

            case "~":
                // A single "~" has no meaning in Envy's markdown, so it's
                // left alone until a second one actually forms "~~".
                guard char(at: location - 1) == "~" else { return }
                closeSecondOpener(with: "~")

            case "(":
                // Only auto-closes right after "]", completing [text](...).
                guard char(at: location - 1) == "]" else { return }
                insert(")", at: cursor)

            default:
                break
            }
        }

        /// Only reacts when the character the user's backspace actually
        /// deleted was itself a "[" — never fires while backspacing through
        /// a link's title text, only once the title is already empty and
        /// the "[[" itself starts getting deleted. When that "[" leaves a
        /// "]" sitting immediately at the cursor (its own now-empty match),
        /// removes that "]" too. Peels one layer per backspace: from an
        /// emptied "[[|]]", the first backspace deletes the inner "[" (via
        /// AppKit's own normal delete) and this removes the inner "]",
        /// landing on "[|]"; the next backspace repeats the same thing for
        /// the outer pair, landing on nothing.
        @MainActor
        private func collapseMatchingCloseIfNeeded(afterDeletingOpener deletedCharacter: String, at location: Int, in textView: NSTextView) {
            guard deletedCharacter == "[" else { return }
            let nsText = textView.string as NSString
            let closeRange = NSRange(location: location, length: 1)
            guard closeRange.location + closeRange.length <= nsText.length,
                  nsText.substring(with: closeRange) == "]"
            else { return }
            guard textView.shouldChangeText(in: closeRange, replacementString: "") else { return }
            textView.textStorage?.replaceCharacters(in: closeRange, with: "")
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.didChangeText()
            hideWikiLinkGhost()
        }

        private static let emojiShortcodeRegex = try! NSRegularExpression(pattern: #":([a-zA-Z0-9_+\-]{1,32}):$"#)

        /// Replaces a just-completed ":shortcode:" ending at the cursor with
        /// its real emoji character — the note's saved content is just the
        /// plain emoji, same as if the user had typed/pasted it directly, no
        /// special syntax kept around to render later.
        @MainActor
        private func expandEmojiShortcodeIfNeeded(in textView: NSTextView) {
            let cursor = textView.selectedRange()
            guard cursor.length == 0 else { return }
            let nsText = textView.string as NSString
            let windowStart = max(0, cursor.location - 40)
            let window = nsText.substring(with: NSRange(location: windowStart, length: cursor.location - windowStart))
            let windowRange = NSRange(location: 0, length: (window as NSString).length)
            guard let match = Self.emojiShortcodeRegex.firstMatch(in: window, range: windowRange) else { return }
            let shortcode = (window as NSString).substring(with: match.range(at: 1)).lowercased()
            guard let emoji = EmojiShortcodes.map[shortcode] else { return }

            let matchRangeInDocument = NSRange(location: windowStart + match.range.location, length: match.range.length)
            guard textView.shouldChangeText(in: matchRangeInDocument, replacementString: emoji) else { return }
            textView.textStorage?.replaceCharacters(in: matchRangeInDocument, with: emoji)
            textView.setSelectedRange(NSRange(location: matchRangeInDocument.location + (emoji as NSString).length, length: 0))
            // didChangeText() (not just replaceCharacters) so this edit
            // properly registers with undo — shouldChangeText(in:) above sets
            // up an editing/undo group that expects a matching "did change"
            // signal to close it out correctly. This re-enters textDidChange
            // once, but the cursor no longer sits right after a ":" the
            // second time, so the regex can't match again — no loop.
            textView.didChangeText()
        }

        /// Replaces a just-completed two-character sequence like "->" with
        /// its arrow the moment the second character lands — see
        /// TextLigatures for the full (deliberately short) list. Skips
        /// anywhere inside a fenced code block or inline code span, where
        /// the same characters are far more likely to be actual code (a
        /// Rust/TypeScript return-type arrow, a SQL JSON path, and so on)
        /// than something meant to become a visual arrow.
        @MainActor
        private func expandLigatureIfNeeded(in textView: NSTextView) {
            let cursor = textView.selectedRange()
            guard cursor.length == 0, cursor.location >= 2 else { return }
            let nsText = textView.string as NSString
            let matchRange = NSRange(location: cursor.location - 2, length: 2)
            let candidate = nsText.substring(with: matchRange)
            guard let replacement = TextLigatures.map[candidate] else { return }
            guard !MarkdownStyler.isInsideCode(at: cursor.location, in: textView.string) else { return }
            guard textView.shouldChangeText(in: matchRange, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: matchRange, with: replacement)
            textView.setSelectedRange(NSRange(location: matchRange.location + (replacement as NSString).length, length: 0))
            // Same didChangeText()-closes-the-undo-group reasoning as
            // expandEmojiShortcodeIfNeeded above — this re-enters
            // textDidChange once, but the two characters right before the
            // cursor are now just the single arrow glyph, which isn't a key
            // in the map, so it can't loop.
            textView.didChangeText()
        }

        /// A resolved "![[Title]]" embed has nowhere to reserve its block
        /// until a genuinely blank line follows it — MarkdownStyler.
        /// embedRanges requires one. Rather than making the user manage
        /// that by hand, insert it automatically the moment the marker
        /// resolves, the same "room just appears" feel Obsidian's own
        /// embeds have, and the same "noticing markdown as you type"
        /// precedent as auto-pairing and list renumbering above.
        @MainActor
        private func ensureEmbedRoomIfNeeded(in textView: NSTextView) {
            guard let insertion = MarkdownStyler.embedRoomInsertion(in: textView.string, noteTitles: parent.noteTitles) else { return }
            let selectionBefore = textView.selectedRange()
            let range = NSRange(location: insertion.at, length: 0)
            guard textView.shouldChangeText(in: range, replacementString: insertion.text) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: insertion.text)
            // The insertion point is always at or after wherever the user
            // was typing (the marker they just finished) — keep the cursor
            // exactly where it was rather than letting it drift into the
            // newly reserved blank block.
            if insertion.at <= selectionBefore.location {
                let shift = (insertion.text as NSString).length
                textView.setSelectedRange(NSRange(location: selectionBefore.location + shift, length: selectionBefore.length))
            } else {
                textView.setSelectedRange(selectionBefore)
            }
            // Re-enters textDidChange once per fix; each pass leaves one
            // fewer marker missing room, so this can't loop.
            textView.didChangeText()
        }

        /// Keeps a numbered list sequential after any edit — not just Return
        /// (which already inserts the right next number), but also deletions,
        /// which otherwise leave gaps or duplicates behind. Confined to the
        /// consecutive numbered-list block touching the cursor's line, and
        /// skips renumbering the cursor's own line so it doesn't fight the
        /// user actively typing a custom number there. Safe to call from
        /// inside textDidChange: it edits via shouldChangeText/didChangeText
        /// like any other programmatic edit, which re-enters this same method,
        /// but the second pass finds nothing left to fix and returns without
        /// editing again, so it can't loop.
        @MainActor
        private func renumberOrderedListIfNeeded(in textView: NSTextView) {
            let nsText = textView.string as NSString
            guard nsText.length > 0 else { return }
            let cursorLoc = min(textView.selectedRange().location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: cursorLoc, length: 0))

            var blockStart = currentLineRange.location
            while blockStart > 0 {
                let priorLineRange = nsText.lineRange(for: NSRange(location: blockStart - 1, length: 0))
                guard MarkdownStyler.isOrderedListLine(nsText.substring(with: priorLineRange)) else { break }
                blockStart = priorLineRange.location
            }

            var lines: [(range: NSRange, text: String)] = []
            var cursor = blockStart
            while cursor < nsText.length {
                let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
                let line = nsText.substring(with: lineRange)
                guard MarkdownStyler.isOrderedListLine(line) else { break }
                lines.append((lineRange, line))
                let next = lineRange.location + lineRange.length
                guard next > cursor else { break }
                cursor = next
            }

            guard lines.count > 1,
                  let first = MarkdownStyler.orderedListNumberInfo(forLine: lines[0].text, lineStart: lines[0].range.location)
            else { return }

            var expected = first.number
            var edits: [(range: NSRange, replacement: String)] = []
            for (range, text) in lines {
                defer { expected += 1 }
                guard let info = MarkdownStyler.orderedListNumberInfo(forLine: text, lineStart: range.location) else { continue }
                // Skip only if the cursor is actually inside the digits
                // themselves (actively typing/editing that number) — not just
                // "cursor is somewhere on this line". Checking the whole line
                // meant a line the cursor merely landed on after a deletion
                // (cursor sits at its very start) got left uncorrected, which
                // is the exact case this pass exists to fix.
                let isEditingNumber = cursorLoc > info.numberRange.location && cursorLoc <= info.numberRange.location + info.numberRange.length
                guard !isEditingNumber, info.number != expected else { continue }
                edits.append((info.numberRange, "\(expected)"))
            }
            guard !edits.isEmpty else { return }

            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { continue }
                textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            textView.didChangeText()
        }

        /// Auto-continues bullet/numbered/task lists on Return: inserts the
        /// same marker (or the incremented number) on the new line, or — if
        /// the current item is empty — clears its marker instead, so pressing
        /// Return on a blank item exits the list rather than adding another
        /// empty one.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if !parent.plainTextMode {
                let isTab = commandSelector == #selector(NSResponder.insertTab(_:))
                let isBacktab = commandSelector == #selector(NSResponder.insertBacktab(_:))
                let isRight = commandSelector == #selector(NSResponder.moveRight(_:))
                // Right-arrow dismisses an active suggestion without touching
                // the typed text or moving the cursor, rather than accepting
                // it — needed whenever the intended title is itself a prefix
                // of an existing one (typing "work" toward a new note while
                // "workout log" already exists). Tab remains the only way to
                // accept.
                if isRight, wikiLinkGhostRemainder != nil {
                    hideWikiLinkGhost()
                    return true
                }
                if isTab, acceptWikiLinkGhostSuggestionIfActive(in: textView) {
                    return true
                }
                // No suggestion to accept — Tab still closes/completes an
                // in-progress wiki-link by jumping past its "]]", rather than
                // inserting a literal tab character into the note.
                if isTab, jumpPastWikiLinkCloseIfInside(in: textView) {
                    return true
                }
                // Neither a ghost suggestion nor an open wiki-link — on a
                // list item (bullet, numbered, or task), Tab/Shift-Tab nest
                // the line a level deeper/shallower instead of inserting a
                // literal tab character. This is what makes a checkbox
                // pressed Return under another one into a sub-task: the new
                // (still-empty) line is already a task-list item the moment
                // it's created, so Tab right after just needs to indent it.
                if isTab, indentListLineIfNeeded(in: textView) {
                    return true
                }
                if isBacktab, outdentListLineIfNeeded(in: textView) {
                    return true
                }
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !parent.plainTextMode else { return false }
            return continueListIfNeeded(in: textView)
        }

        /// One level of list nesting, in spaces rather than a literal tab
        /// character — more portable across other editors/renderers a
        /// plain-text note might end up opened in, where a raw tab's
        /// effective indent width isn't consistently interpreted.
        private static let listIndentUnit = "    "

        @MainActor
        private func indentListLineIfNeeded(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let line = nsText.substring(with: lineRange)
            guard MarkdownStyler.isListLine(line) else { return false }

            let insertion = Self.listIndentUnit
            let insertRange = NSRange(location: lineRange.location, length: 0)
            guard textView.shouldChangeText(in: insertRange, replacementString: insertion) else { return false }
            textView.textStorage?.replaceCharacters(in: insertRange, with: insertion)
            let shift = (insertion as NSString).length
            textView.setSelectedRange(NSRange(location: selectedRange.location + shift, length: selectedRange.length))
            textView.didChangeText()
            return true
        }

        @MainActor
        private func outdentListLineIfNeeded(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let line = nsText.substring(with: lineRange)
            guard MarkdownStyler.isListLine(line) else { return false }

            let leadingWhitespaceCount = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            guard leadingWhitespaceCount > 0 else { return true }  // already at the top level — consume the key anyway rather than falling through to default Shift-Tab handling
            let removeCount = min(leadingWhitespaceCount, (Self.listIndentUnit as NSString).length)
            let removeRange = NSRange(location: lineRange.location, length: removeCount)
            guard textView.shouldChangeText(in: removeRange, replacementString: "") else { return false }
            textView.textStorage?.replaceCharacters(in: removeRange, with: "")
            let newLocation = max(lineRange.location, selectedRange.location - removeCount)
            textView.setSelectedRange(NSRange(location: newLocation, length: max(0, selectedRange.length - removeCount)))
            textView.didChangeText()
            return true
        }

        @MainActor
        private func continueListIfNeeded(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0 else { return false }
            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let line = nsText.substring(with: lineRange)
            guard let continuation = MarkdownStyler.listContinuation(forLine: line) else { return false }

            switch continuation {
            case .exit:
                var clearRange = lineRange
                if line.hasSuffix("\n") { clearRange.length -= 1 }
                guard textView.shouldChangeText(in: clearRange, replacementString: "") else { return false }
                textView.textStorage?.replaceCharacters(in: clearRange, with: "")
                textView.didChangeText()
            case .continue(let marker):
                let insertion = "\n" + marker
                guard textView.shouldChangeText(in: selectedRange, replacementString: insertion) else { return false }
                textView.textStorage?.replaceCharacters(in: selectedRange, with: insertion)
                textView.setSelectedRange(NSRange(location: selectedRange.location + (insertion as NSString).length, length: 0))
                textView.didChangeText()
            }
            return true
        }

        /// Keeps a selection from ever including the protected "⎈" signature
        /// line — the pill stands in for that text, so selecting the hidden
        /// characters underneath it (a drag across the pill, or ⌘A) would be
        /// both pointless and confusing. Clamps any proposed selection so it
        /// stops at the signature's first character; a caret that lands
        /// inside collapses to just before it. Only active while protection
        /// is on and a signature exists — otherwise the proposal is returned
        /// untouched.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue], toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
            guard parent.protectAISignature,
                  let signatureRange = MarkdownStyler.aiSignatureRange(in: textView.string) else {
                return newSelectedCharRanges
            }
            let limit = signatureRange.location
            return newSelectedCharRanges.map { value in
                let range = value.rangeValue
                if range.location >= limit {
                    return NSValue(range: NSRange(location: limit, length: 0))
                }
                if range.location + range.length > limit {
                    return NSValue(range: NSRange(location: range.location, length: limit - range.location))
                }
                return value
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Typing moves the cursor too, which fires this delegate method in
            // addition to textDidChange for the same keystroke. If it ran again
            // here, it would re-enter textStorage edits already in flight from
            // textDidChange's own restyle — skip it, since textDidChange already
            // restyles using the current cursor position.
            guard !isHandlingTextChange, let textView = notification.object as? NSTextView else { return }
            restyle(textView)
            updateWikiLinkGhostSuggestion(in: textView)
            parent.onSelectionChange?(textView.selectedRange())
        }

        /// Re-applies styling using the view's own live content and current
        /// cursor position — the single source of truth for what's actually
        /// on screen, so this is always safe to call from any AppKit-native
        /// delegate callback (never from the SwiftUI-driven updateNSView,
        /// which can see a stale `text` binding — see its own comments).
        @MainActor
        private func restyle(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            if parent.plainTextMode {
                MarkdownStyler.clearFormatting(textStorage: textStorage, text: textView.string, theme: parent.theme, fontSizeAdjustment: parent.fontZoom)
                updateCheckboxOverlays(in: textView)
                updateEmbedOverlays(in: textView)
                updateSignaturePill(in: textView)
                return
            }
            let window = windowedRestyleRange(for: textView)
            MarkdownStyler.style(
                textStorage: textStorage,
                text: textView.string,
                theme: parent.theme,
                revealedLinkRange: hoveredLinkRange,
                searchQuery: parent.searchQuery,
                cursorSelection: MarkdownTextView.currentSelection(of: textView),
                fontSizeAdjustment: parent.fontZoom,
                restyleRange: window,
                allowsEmbeds: parent.allowsEmbeds,
                embedHeights: embedHeights,
                noteTitles: parent.noteTitles
            )
            lastRestyleCursorLocation = textView.selectedRange().location
            pendingRestyleInvalidationRange = nil
            updateCheckboxOverlays(in: textView)
            updateEmbedOverlays(in: textView)
            updateSignaturePill(in: textView)
        }

        /// Everything restyle() runs on is per-keystroke (typing, arrow
        /// keys, checkbox clicks all land here), so on a large note the
        /// full-document pass — ~20 regex scans plus attribute churn over
        /// the whole text, which in turn invalidates the whole document's
        /// layout — was the last real typing-latency scaling risk in the
        /// app. Styling rules are all line-local, so a paragraph-snapped
        /// window around everything that could have changed since the last
        /// pass is exactly as correct as the full pass, except when
        /// something document-global is in play; each of those cases just
        /// declines the window and keeps the previous full-restyle behavior:
        /// - small documents (windowing overhead isn't worth it, and full
        ///   is already imperceptible)
        /// - an active search (matches highlight document-wide)
        /// - any fenced code block (its opening/closing ``` changes what
        ///   everything after it means — the one non-line-local construct)
        private static let windowedRestyleThreshold = 30_000
        private static let windowedRestyleMargin = 2_000

        /// The union of "places other than the cursor whose styling may be
        /// stale" — edit locations captured in shouldChangeTextIn (a
        /// checkbox clicked far from the cursor, a renumbered list), plus
        /// hover reveal/unreveal ranges. Consumed (reset) by each restyle.
        private var pendingRestyleInvalidationRange: NSRange?
        /// Where the cursor was when styling last ran — markers reveal
        /// around the cursor, so the span it *left* needs re-collapsing,
        /// not just the span it entered.
        private var lastRestyleCursorLocation = 0

        func noteRestyleInvalidation(_ range: NSRange) {
            pendingRestyleInvalidationRange = pendingRestyleInvalidationRange.map { NSUnionRange($0, range) } ?? range
        }

        @MainActor
        private func windowedRestyleRange(for textView: NSTextView) -> NSRange? {
            let nsText = textView.string as NSString
            let length = nsText.length
            guard length > Self.windowedRestyleThreshold else { return nil }
            guard parent.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard nsText.range(of: "```").location == NSNotFound else { return nil }
            // Same reasoning as the fence check above — an embed marker
            // reserves a fixed block of vertical space wherever it sits,
            // and updateEmbedOverlays (which positions the floating view
            // into that space) walks MarkdownStyler.embedRanges(in:) over
            // the *whole* current string, not just whatever window style()
            // happened to restyle — so a stale window would leave overlays
            // unpositioned rather than just unstyled text, a worse failure
            // mode than the plain-text case windowing already avoids below.
            guard nsText.range(of: "![[").location == NSNotFound else { return nil }
            // When signature protection is on, updateSignaturePill re-clears
            // the pill's underlying text every restyle; a window that skipped
            // the signature line would leave stale styling there. The line is
            // always at the very end (past any typical edit window), so just
            // decline windowing whenever a protected signature exists.
            if parent.protectAISignature, MarkdownStyler.aiSignatureRange(in: textView.string) != nil {
                return nil
            }

            let cursor = min(textView.selectedRange().location, length)
            var low = min(cursor, min(lastRestyleCursorLocation, length))
            var high = max(cursor, min(lastRestyleCursorLocation, length))
            if let pending = pendingRestyleInvalidationRange {
                low = min(low, pending.location)
                high = max(high, min(pending.location + pending.length, length))
            }
            low = max(0, low - Self.windowedRestyleMargin)
            high = min(length, high + Self.windowedRestyleMargin)
            // Paragraph-snapped so the window's edges are real line
            // boundaries — every pattern in MarkdownStyler is either
            // line-anchored or can't span a newline, so a window that only
            // ever starts/ends at line breaks can't cut a construct in half.
            return nsText.paragraphRange(for: NSRange(location: low, length: high - low))
        }

        /// Repositions/recreates one floating label per checkbox in the
        /// current text, showing ☑ or ☐ over the now-invisible "[" that
        /// MarkdownStyler collapses at each checkbox's position — see the
        /// comment above that collapse() call for why this is a floating
        /// overlay (matching the wiki-link ghost text's own approach)
        /// rather than NSGlyphInfo glyph substitution. Pooled rather than
        /// recreated each call: reused labels are just repositioned/
        /// relabeled, extras beyond the current checkbox count are hidden
        /// rather than removed, so a note that briefly has more checkboxes
        /// than usual doesn't churn view creation on every keystroke.
        @MainActor
        func updateCheckboxOverlays(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            guard !parent.plainTextMode else {
                checkboxOverlayLabels.forEach { $0.isHidden = true }
                return
            }
            let checkboxes = MarkdownStyler.taskCheckboxRanges(in: textView.string)
            // The common case — a note with no checkboxes at all — pays for
            // nothing here beyond the one regex scan above. This runs on
            // every keystroke (restyle calls it), and the forced layout
            // below used to run unconditionally over the whole document,
            // making it the single largest fixed per-keystroke cost.
            guard !checkboxes.isEmpty else {
                checkboxOverlayLabels.forEach { $0.isHidden = true }
                return
            }
            // NSLayoutManager lays out lazily — glyph/line-fragment queries
            // below only reflect layout that's actually been generated yet,
            // which (particularly for the very first note opened after
            // launch) can still be based on a provisional container width
            // from before SwiftUI's surrounding layout has settled. This
            // forces layout to be current before reading any position from
            // it, rather than trusting whatever's already cached — the root
            // cause of checkboxes showing misaligned until something else
            // (like clicking into the editor) happened to trigger a fresh
            // layout pass. Forced only through the last checkbox, though,
            // not the whole container: layout generates front-to-back, so
            // anything past the final checkbox is layout no position query
            // below ever reads.
            let textLength = (textView.string as NSString).length
            let lastCheckboxEnd = checkboxes.map { $0.glyphRange.location + $0.glyphRange.length }.max() ?? textLength
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(lastCheckboxEnd, textLength)))
            while checkboxOverlayLabels.count < checkboxes.count {
                let label = CheckboxOverlayLabel()
                label.isEditable = false
                label.isSelectable = false
                label.isBezeled = false
                label.isBordered = false
                label.drawsBackground = false
                label.lineBreakMode = .byClipping
                label.cell?.usesSingleLineMode = true
                textView.addSubview(label)
                checkboxOverlayLabels.append(label)
            }

            // Matches MarkdownStyler.style()'s own baseFont computation exactly
            // (not textView.font — see the note in applyTheme() above about why
            // that's deliberately never set to the real content font) so the
            // overlay's size lines up with the space MarkdownStyler reserved
            // for it via reserveSpace().
            let unadjustedFont = parent.theme.resolvedFont
            let bodyFont = parent.fontZoom == 0
                ? unadjustedFont
                : NSFontManager.shared.convert(unadjustedFont, toSize: max(6, unadjustedFont.pointSize + parent.fontZoom))
            let symbolFont = MarkdownStyler.checkboxSymbolFont(baseFont: bodyFont)
            let origin = textView.textContainerOrigin
            // .withAlphaComponent(_:), called here outside an actual AppKit
            // drawing pass (this runs from a text-change delegate callback,
            // not -draw(_:)), forces the same premature/wrong-context
            // resolution already hit twice elsewhere in this app (the light
            // mode search bar, inline code background) — it was resolving
            // theme.resolvedMarkerColor as if dark mode were active even
            // with a light effectiveAppearance, making unchecked boxes
            // white-on-white. Deferring into a resolver closure like those
            // other two fixes is what makes it resolve correctly.
            let markerColor = parent.theme.resolvedMarkerColor
            let uncheckedColor = NSColor(name: nil) { _ in markerColor.withAlphaComponent(0.5) }

            for (index, label) in checkboxOverlayLabels.enumerated() {
                guard index < checkboxes.count else {
                    label.isHidden = true
                    continue
                }
                let checkbox = checkboxes[index]
                let glyphRange = layoutManager.glyphRange(forCharacterRange: checkbox.glyphRange, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let xPosition = rect.origin.x + origin.x
                // The overlay's symbol font is larger than body text (same
                // as the old glyph-substitution approach), so it needs
                // vertically centering within the *line's* height, not just
                // aligned to the small "[" character's own (body-sized) box.
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

                label.font = symbolFont
                label.textColor = checkbox.isChecked ? parent.theme.resolvedCheckedCheckboxColor : uncheckedColor
                label.stringValue = checkbox.isChecked ? "☑" : "☐"
                label.sizeToFit()
                let verticalOffset = (lineRect.height - label.frame.height) / 2
                label.frame.origin = NSPoint(x: xPosition, y: lineRect.origin.y + origin.y + verticalOffset)
                label.isHidden = false
            }
        }

        /// Repositions/recreates one floating, live-editable view per
        /// "![[Note Title]]" embed in the current text — same pooled-by-
        /// index approach as updateCheckboxOverlays above. Positioned at
        /// the blank line MarkdownStyler reserves right after each marker
        /// (embed.spacerRange — see embedHeight's own doc comment for why
        /// it's a separate line from the marker rather than the marker's
        /// own line inflated), never the marker's own line, so the visible
        /// "![[Note Title]]" text stays a completely ordinary, uncovered
        /// line the cursor can sit on normally. Needs a live NoteStore to
        /// resolve titles against — nil for the pinned popup and template
        /// editor (see MarkdownTextView.store's own doc comment), so
        /// embeds simply don't expand there rather than trying to share a
        /// second NoteStore instance.
        @MainActor
        func updateEmbedOverlays(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            guard !parent.plainTextMode, parent.allowsEmbeds, let store = parent.store else {
                embedOverlayViews.forEach { $0.isHidden = true }
                return
            }
            let embeds = MarkdownStyler.embedRanges(in: textView.string, noteTitles: parent.noteTitles)
            guard !embeds.isEmpty else {
                embedOverlayViews.forEach { $0.isHidden = true }
                return
            }
            let textLength = (textView.string as NSString).length
            let lastEmbedEnd = embeds.map { $0.spacerRange.location + $0.spacerRange.length }.max() ?? textLength
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(lastEmbedEnd, textLength)))

            while embedOverlayViews.count < embeds.count {
                // Placeholder content — overwritten by the real title/frame
                // in the loop below before this ever actually draws, since
                // every index just added here is by construction < embeds.count.
                let hostingView = NSHostingView(rootView: AnyView(EmbeddedNoteView(
                    store: store,
                    title: "",
                    theme: parent.theme,
                    requireModifierForLinkClick: parent.requireModifierForLinkClick,
                    noteTitles: parent.noteTitles,
                    isCurrentlyOpenElsewhere: false,
                    onNavigate: parent.onNavigate
                ).id("")))
                textView.addSubview(hostingView)
                embedOverlayViews.append(hostingView)
            }

            let origin = textView.textContainerOrigin
            let width = max(textContainer.size.width, 100)

            for (index, hostingView) in embedOverlayViews.enumerated() {
                guard index < embeds.count else {
                    hostingView.isHidden = true
                    continue
                }
                let embed = embeds[index]
                let glyphRange = layoutManager.glyphRange(forCharacterRange: embed.spacerRange, actualCharacterRange: nil)
                // The blank line's own rect *is* the reserved block —
                // there's no text on it to be positioned somewhere other
                // than filling its own full extent, unlike the marker's
                // line (which is why this targets spacerRange, not
                // markerRange).
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                hostingView.frame = NSRect(
                    x: origin.x,
                    y: lineRect.origin.y + origin.y,
                    width: width,
                    height: lineRect.height
                )
                let isCurrentlyOpenElsewhere = parent.currentNoteID != nil
                    && store.exactTitleMatch(for: embed.title)?.id == parent.currentNoteID
                let embedTitle = embed.title
                hostingView.rootView = AnyView(EmbeddedNoteView(
                    store: store,
                    title: embed.title,
                    theme: parent.theme,
                    requireModifierForLinkClick: parent.requireModifierForLinkClick,
                    noteTitles: parent.noteTitles,
                    isCurrentlyOpenElsewhere: isCurrentlyOpenElsewhere,
                    onNavigate: parent.onNavigate,
                    onContentHeightChange: { [weak self] height in
                        self?.updateEmbedHeight(for: embedTitle, to: height, in: textView)
                    }
                ).id(embed.title))
                hostingView.isHidden = false
            }
        }

        /// Records an embed's measured height and, if it changed, restyles
        /// so the reserved space matches. Clamped: too short and the embed
        /// stops reading as one, too tall and a long note pushes the host's
        /// own text off screen.
        @MainActor
        func updateEmbedHeight(for title: String, to height: CGFloat, in textView: NSTextView) {
            let key = title.lowercased()
            let clamped = min(max(height, MarkdownStyler.minimumEmbedHeight), MarkdownStyler.maximumEmbedHeight)
            guard abs((embedHeights[key] ?? 0) - clamped) > 1 else { return }
            embedHeights[key] = clamped
            // Deferred: this arrives from inside the embed's own layout pass,
            // and restyling the host synchronously would mutate text storage
            // while AppKit is still laying out a view that reads from it.
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                self.restyle(textView)
            }
        }

        /// Draws the "⎈" provenance line as a non-editable pill (and hides
        /// its underlying text) when signature protection is on. The veto in
        /// shouldChangeTextIn is what actually makes the range uneditable;
        /// this is the visual half that makes that legible — the line reads
        /// as a distinct object, not plain text the user is mysteriously
        /// unable to edit. No-op (and pill hidden) when protection is off or
        /// the note has no signature.
        @MainActor
        func updateSignaturePill(in textView: NSTextView) {
            guard parent.protectAISignature,
                  let signatureRange = MarkdownStyler.aiSignatureRange(in: textView.string),
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let textStorage = textView.textStorage else {
                signaturePillView?.isHidden = true
                return
            }
            // Hide the raw signature text — the pill stands in for it. Applied
            // after style() each restyle (windowing is disabled while a
            // protected signature exists, so style() always re-touches it).
            textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: signatureRange)
            // Lay out everything up to and including the signature, not just
            // its own line — the pill's y-position depends on how tall the
            // body above it wrapped, and laying out only the signature range
            // leaves that stale (the pill lands overlapping text above until
            // some later relayout). Same reasoning as updateEmbedOverlays.
            let signatureEnd = signatureRange.location + signatureRange.length
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: signatureEnd))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: signatureRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let origin = textView.textContainerOrigin

            let removeAction: () -> Void = { [weak self] in self?.removeSignature() }
            let pill: NSHostingView<SignaturePillView>
            if let existing = signaturePillView {
                pill = existing
            } else {
                pill = NSHostingView(rootView: SignaturePillView(text: "", theme: parent.theme, onRemove: removeAction))
                textView.addSubview(pill)
                signaturePillView = pill
            }
            pill.rootView = SignaturePillView(
                text: (textView.string as NSString).substring(with: signatureRange),
                theme: parent.theme,
                onRemove: removeAction
            )
            let size = pill.fittingSize
            pill.frame = NSRect(
                x: origin.x + lineRect.minX,
                y: origin.y + lineRect.minY + max(0, (lineRect.height - size.height) / 2),
                width: size.width,
                height: size.height
            )
            pill.isHidden = false
        }

        /// The "Remove AI Mark" action on the pill's right-click menu — the
        /// one deliberate, in-app way to strip the provenance line while
        /// protection is on (short of turning the setting off). Removes the
        /// signature and the blank line(s) separating it from the body, and
        /// sets isRemovingSignature so the protection veto lets this single
        /// edit through. Goes via shouldChangeText/didChangeText so it's
        /// undoable like any other edit.
        @MainActor
        private func removeSignature() {
            guard let textView, let signatureRange = MarkdownStyler.aiSignatureRange(in: textView.string) else { return }
            let nsText = textView.string as NSString
            var start = signatureRange.location
            while start > 0, nsText.character(at: start - 1) == 10 { start -= 1 }
            let removeRange = NSRange(location: start, length: signatureRange.location + signatureRange.length - start)
            isRemovingSignature = true
            defer { isRemovingSignature = false }
            guard textView.shouldChangeText(in: removeRange, replacementString: "") else { return }
            textView.textStorage?.replaceCharacters(in: removeRange, with: "")
            textView.didChangeText()
        }

        /// EmbeddedNoteView's own collapse chevron calls this — flips
        /// whether MarkdownStyler.style() reserves the measured height or
        /// the full embedHeight for this specific embed's spacer line, then
        /// restyles and repositions immediately so the visible reserved
        /// block resizes right away instead of waiting for some other,
        /// unrelated edit to trigger the next restyle pass.
        @MainActor

        /// Briefly flags an externally-changed range so the user notices it
        /// without having to spot the diff themselves. Same highlight color
        /// as search matches — one theme-controlled "highlight" concept for
        /// everything in the editor, rather than a second, separately
        /// hardcoded color the user has no way to change. Steps the alpha
        /// down manually rather than a single delayed cut — text attributes
        /// aren't Core Animation properties, so there's nothing to animate
        /// implicitly — then reverts with a normal restyle pass rather than
        /// just stripping the attribute, so a flash landing over (say) a
        /// code span's own background doesn't leave it wrong afterward.
        func flashHighlight(range: NSRange, in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            highlightFadeTask?.cancel()
            let peakAlpha = 0.4
            let highlightColor = parent.theme.resolvedHighlightColor
            textStorage.addAttribute(.backgroundColor, value: highlightColor.withAlphaComponent(peakAlpha), range: range)
            highlightFadeTask = Task { [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let textView else { return }

                let steps = 6
                for step in 1...steps {
                    guard !Task.isCancelled, let textStorage = textView.textStorage,
                          range.location + range.length <= textStorage.length else { break }
                    let alpha = peakAlpha * (1 - Double(step) / Double(steps))
                    textStorage.addAttribute(.backgroundColor, value: highlightColor.withAlphaComponent(alpha), range: range)
                    try? await Task.sleep(for: .milliseconds(35))
                }

                guard !Task.isCancelled, let self else { return }
                self.restyle(textView)
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }

            // No modifier required, unlike other link types — this jumps
            // within the same note rather than navigating away or creating
            // anything, so there's nothing for the modifier requirement to
            // guard against. Same reasoning as checkboxes being plain-click.
            if url.scheme == "envy-footnote" {
                let encoded = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
                let label = encoded.removingPercentEncoding ?? encoded
                jumpToFootnoteDefinition(label: label, in: textView)
                return true
            }

            if url.scheme == "envy-heading" {
                let encoded = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
                let slug = encoded.removingPercentEncoding ?? encoded
                jumpToHeading(slug: slug, in: textView)
                return true
            }

            guard url.scheme == "envy" || url.scheme == "http" || url.scheme == "https" else {
                return false
            }

            // Command means "follow this", unconditionally. Every branch
            // below that swallows a click has to yield to it — the caret is
            // necessarily inside a link the moment you finish typing one, so
            // a rule about the caret's position would otherwise eat the very
            // click that creates the note you just named.
            let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false

            if parent.requireModifierForLinkClick {
                guard commandHeld else {
                    // Handled rather than declined — declining makes NSTextView
                    // fall back to opening the URL itself via NSWorkspace, which
                    // for "envy://" fails loudly (no registered handler) and for
                    // http(s) would bypass this modifier requirement entirely.
                    //
                    // Handled by placing the caret, not by doing nothing: a link
                    // is still text you need to edit, and swallowing the click
                    // left no way to put the cursor inside one.
                    placeCaret(at: charIndex, in: textView)
                    return true
                }
            } else if url.scheme == "envy", !commandHeld,
                      caretIsInsideWikiLink(containing: charIndex, in: textView) {
                // Plain click inside a link the caret already occupies: the
                // user is working on the text, not trying to follow it.
                // Without this there's no way to reposition within a link
                // you've entered, since every click bounces to the target.
                placeCaret(at: charIndex, in: textView)
                return true
            }

            if url.scheme == "envy" {
                let encoded = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
                let title = encoded.removingPercentEncoding ?? encoded
                parent.onNavigate(title)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }

        /// True when the selection is already within the wiki-link span that
        /// contains the clicked character — i.e. the link is revealed because
        /// the user is inside it.
        @MainActor
        private func caretIsInsideWikiLink(containing charIndex: Int, in textView: NSTextView) -> Bool {
            guard let span = MarkdownStyler.wikiLinkFullRanges(in: textView.string)
                .first(where: { NSLocationInRange(charIndex, $0) }) else { return false }
            let selection = textView.selectedRange()
            // Inclusive of both edges: a caret resting immediately after the
            // closing bracket still has the link revealed, so a click inside
            // it should behave the same way.
            return selection.location >= span.location
                && selection.location <= span.location + span.length
        }

        /// Drops the insertion point exactly where the click landed and
        /// restyles, so the link expands around the caret the same way it does
        /// when arrowing into it.
        @MainActor
        private func placeCaret(at charIndex: Int, in textView: NSTextView) {
            textView.setSelectedRange(NSRange(location: charIndex, length: 0))
            restyle(textView)
        }

        /// Scrolls to a footnote's definition and briefly flashes it (the
        /// same highlight AppKit uses for Find results), without touching the
        /// user's actual cursor/selection.
        @MainActor
        private func jumpToFootnoteDefinition(label: String, in textView: NSTextView) {
            guard let range = MarkdownStyler.footnoteDefinitionRange(forLabel: label, in: textView.string) else { return }
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }

        /// Scrolls to a heading matching an in-note `[text](#slug)` anchor
        /// link, same jump-and-flash treatment as a footnote reference.
        @MainActor
        private func jumpToHeading(slug: String, in textView: NSTextView) {
            guard let range = MarkdownStyler.headingRange(forSlug: slug, in: textView.string) else { return }
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }

        // Not @MainActor: these are invoked from a @Sendable NotificationCenter
        // observer closure (registered with queue: .main), where an explicit
        // actor-isolated call would be a hard "sending non-Sendable value"
        // compile error rather than the isolation-mismatch warnings tolerated
        // elsewhere in this file. queue: .main already guarantees these run on
        // the main thread at runtime, same trust placed in applyWindowChrome
        // in EnvyApp.swift for its own unisolated NSWindow property writes.
        private func toggleBold() {
            guard let textView else { return }
            toggleEmphasis(marker: "**", in: textView)
        }

        private func toggleItalic() {
            guard let textView else { return }
            toggleEmphasis(marker: "*", in: textView)
        }

        /// Wraps the current selection in `marker`, or unwraps it if it's
        /// already immediately surrounded by one — a no-op if nothing is
        /// selected, since there's no text to apply emphasis to.
        private func toggleEmphasis(marker: String, in textView: NSTextView) {
            let selRange = textView.selectedRange()
            guard selRange.length > 0 else { return }
            let nsText = textView.string as NSString
            let markerLength = (marker as NSString).length

            // For "*" (italic), a single star only counts as a real italic
            // marker if it isn't actually one half of a "**" (bold) marker —
            // otherwise toggling italic on bold text would eat one star off
            // a "**" pair instead of wrapping/unwrapping italic markers.
            func isLoneStar(at range: NSRange, checkingBefore: Bool) -> Bool {
                guard marker == "*" else { return true }
                let neighbor = checkingBefore ? range.location - 1 : range.location + range.length
                guard neighbor >= 0, neighbor < nsText.length else { return true }
                return nsText.substring(with: NSRange(location: neighbor, length: 1)) != "*"
            }

            let beforeRange = NSRange(location: selRange.location - markerLength, length: markerLength)
            let afterRange = NSRange(location: selRange.location + selRange.length, length: markerLength)
            let hasBefore = beforeRange.location >= 0
                && nsText.substring(with: beforeRange) == marker
                && isLoneStar(at: beforeRange, checkingBefore: true)
            let hasAfter = afterRange.location + afterRange.length <= nsText.length
                && nsText.substring(with: afterRange) == marker
                && isLoneStar(at: afterRange, checkingBefore: false)

            if hasBefore && hasAfter {
                let innerText = nsText.substring(with: selRange)
                let combinedRange = NSRange(location: beforeRange.location, length: markerLength + selRange.length + markerLength)
                guard textView.shouldChangeText(in: combinedRange, replacementString: innerText) else { return }
                textView.textStorage?.replaceCharacters(in: combinedRange, with: innerText)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: beforeRange.location, length: (innerText as NSString).length))
                return
            }

            let selectedText = nsText.substring(with: selRange)
            let wrapped = "\(marker)\(selectedText)\(marker)"
            guard textView.shouldChangeText(in: selRange, replacementString: wrapped) else { return }
            textView.textStorage?.replaceCharacters(in: selRange, with: wrapped)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: selRange.location + markerLength, length: selRange.length))
        }

        /// Full match is "[[Title]]" by construction of the regex that
        /// produced these ranges — stripping the two-character brackets off
        /// each end and trimming is the same title extraction
        /// MarkdownStyler.style's own wikilink loop does with its capture
        /// group, just without a capture group to hand it here.
        private func wikilinkTitle(forFullRange range: NSRange, in text: String) -> String {
            let matched = (text as NSString).substring(with: range)
            return String(matched.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }

        @MainActor
        private func configurePreviewController(store: NoteStore) {
            previewController.configure(
                store: store,
                theme: parent.theme,
                requireModifierForLinkClick: parent.requireModifierForLinkClick,
                showDuePill: parent.showDuePill,
                showTagsInTitleBar: parent.showTagsInTitleBar,
                noteTitles: parent.noteTitles,
                currentlyOpenNoteID: parent.currentNoteID,
                onNavigate: { [weak self] title in self?.parent.onNavigate(title) }
            )
        }

        /// The only trigger for the preview popover — an explicit, deliberate
        /// option-click (see makeNSView's onOptionClickPoint wiring, gated
        /// in HoverAwareTextView.mouseDown behind the option modifier being
        /// held), never hover. An earlier hover-triggered version could leave
        /// a popover open exactly when the user tried a normal ⌘-click
        /// through it, which is what caused a "no application set to open
        /// the URL" failure — option-click has nothing else bound to it, so
        /// it never competes with ⌘-click-to-navigate at all.
        @MainActor
        func handleOptionClick(at point: NSPoint) -> Bool {
            guard parent.linkPreviewTrigger == .optionClick, let store = parent.store, let textView else { return false }
            let charIndex = textView.characterIndexForInsertion(at: point)
            let text = textView.string
            guard let hit = wikiLinkRanges(for: text).first(where: { NSLocationInRange(charIndex, $0) }) else { return false }
            // A "[[Note Title]]" immediately preceded by "!" is an embed
            // marker, not an ordinary link — it's already showing this
            // note's content live, right below it, so popping a second,
            // separate preview of the same note on top of that would just
            // be a redundant, confusing second surface for the same thing.
            let nsText = text as NSString
            if hit.location > 0, nsText.substring(with: NSRange(location: hit.location - 1, length: 1)) == "!" {
                return false
            }
            configurePreviewController(store: store)
            let title = wikilinkTitle(forFullRange: hit, in: text)
            let requireModifier = parent.requireModifierForLinkClick
            previewController.show(
                title: title,
                anchorRect: screenRect(for: hit, in: textView),
                in: textView,
                shouldNavigateOnOutsideClick: { [textView] clickPoint, modifiers in
                    let clickCharIndex = textView.characterIndexForInsertion(at: clickPoint)
                    let modifierSatisfied = !requireModifier || modifiers.contains(.command)
                    return NSLocationInRange(clickCharIndex, hit) && modifierSatisfied
                }
            )
            return true
        }

        /// Purely the bracket-reveal-on-hover effect ("[[" / "]]" becoming
        /// visible while the mouse sits over a wikilink) — unrelated to and
        /// unaffected by the preview popover, which option-click alone
        /// triggers (see handleOptionClick above).
        @MainActor
        func handleHover(at point: NSPoint) {
            guard let textView else { return }
            let charIndex = textView.characterIndexForInsertion(at: point)
            let text = textView.string
            let ranges = wikiLinkRanges(for: text)
            let hit = ranges.first { NSLocationInRange(charIndex, $0) }

            guard hit != hoveredLinkRange else { return }
            // Both the link being revealed and the one being un-revealed
            // can sit far from the cursor — a windowed restyle needs told
            // about them explicitly or their markers would stay stuck.
            if let previous = hoveredLinkRange { noteRestyleInvalidation(previous) }
            if let hit { noteRestyleInvalidation(hit) }
            hoveredLinkRange = hit
            restyle(textView)
        }

        @MainActor
        func clearHover() {
            guard hoveredLinkRange != nil, let textView else { return }
            if let previous = hoveredLinkRange { noteRestyleInvalidation(previous) }
            hoveredLinkRange = nil
            restyle(textView)
        }

        /// The on-screen rect (in `textView`'s own coordinate space, which
        /// is what NSPopover.show(relativeTo:of:) expects) of a character
        /// range — same glyph-bounds-plus-container-origin approach as
        /// checkboxHitRects()/footnoteHitRects() below, just for a wikilink
        /// range instead of a checkbox/footnote glyph.
        @MainActor
        private func screenRect(for range: NSRange, in textView: NSTextView) -> NSRect {
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return .zero }
            let origin = textView.textContainerOrigin
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            return rect
        }

        /// Toggles a task-list checkbox if the click landed on (or near) one.
        /// Hit-tests against the glyph's actual padded on-screen rect rather
        /// than character-index proximity — a single collapsed/substituted
        /// character is a near-unclickable target otherwise. Uses
        /// shouldChangeText/didChangeText (rather than mutating textStorage
        /// directly) so the edit participates in undo and triggers the normal
        /// textDidChange path — same restyle and save flow as typing.
        @MainActor
        func handleClick(at point: NSPoint) -> Bool {
            // Nothing renders as a clickable checkbox/footnote in plain-text
            // mode (see isOverClickTarget in makeNSView), so nothing should
            // be clickable either — otherwise clicking plain "[ ]" text
            // could still silently toggle it.
            guard let textView, !parent.plainTextMode else { return false }

            if let checkbox = checkboxAndRect(at: point)?.checkbox {
                let replacement = checkbox.isChecked ? " " : "x"
                guard textView.shouldChangeText(in: checkbox.toggleRange, replacementString: replacement) else { return false }
                textView.textStorage?.replaceCharacters(in: checkbox.toggleRange, with: replacement)
                textView.didChangeText()
                return true
            }

            if let footnote = footnoteAndRect(at: point)?.footnote {
                jumpToFootnoteDefinition(label: footnote.label, in: textView)
                return true
            }

            if let due = dueTokenAndRect(at: point)?.due {
                let nsText = textView.string as NSString
                if due.isCrossedOut {
                    // Remove exactly the two tildes on each side that made
                    // it isCrossedOut in the first place — replacing the
                    // whole "~~@token~~" span with just the bare token in
                    // one edit, rather than two separate deletions either
                    // side of it.
                    let wrappedRange = NSRange(location: due.range.location - 2, length: due.range.length + 4)
                    let token = nsText.substring(with: due.range)
                    guard textView.shouldChangeText(in: wrappedRange, replacementString: token) else { return false }
                    textView.textStorage?.replaceCharacters(in: wrappedRange, with: token)
                } else {
                    let token = nsText.substring(with: due.range)
                    let wrapped = "~~" + token + "~~"
                    guard textView.shouldChangeText(in: due.range, replacementString: wrapped) else { return false }
                    textView.textStorage?.replaceCharacters(in: due.range, with: wrapped)
                }
                textView.didChangeText()
                return true
            }

            return false
        }

        /// Padded on-screen rect for every checkbox in the current text, used
        /// to show a pointing-hand cursor over them (see resetCursorRects()).
        @MainActor
        func checkboxHitRects() -> [NSRect] {
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return [] }
            let origin = textView.textContainerOrigin
            let padding: CGFloat = 6
            return MarkdownStyler.taskCheckboxRanges(in: textView.string).map { checkbox in
                let glyphRange = layoutManager.glyphRange(forCharacterRange: checkbox.glyphRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                return rect.insetBy(dx: -padding, dy: -padding)
            }
        }

        /// Picks the *closest* checkbox to the click point among all whose
        /// padded rect contains it, rather than the first one found — with
        /// tightly spaced rows (e.g. "compact" list density), adjacent
        /// checkboxes' padded rects can overlap, and always taking the first
        /// match meant a click nearer the row below could still register on
        /// the row above.
        @MainActor
        private func checkboxAndRect(at point: NSPoint) -> (checkbox: (glyphRange: NSRange, toggleRange: NSRange, isChecked: Bool), rect: NSRect)? {
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return nil }
            let origin = textView.textContainerOrigin
            let padding: CGFloat = 6
            var best: (checkbox: (glyphRange: NSRange, toggleRange: NSRange, isChecked: Bool), rect: NSRect, distance: CGFloat)?
            for checkbox in MarkdownStyler.taskCheckboxRanges(in: textView.string) {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: checkbox.glyphRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                let padded = rect.insetBy(dx: -padding, dy: -padding)
                guard padded.contains(point) else { continue }
                let distance = hypot(point.x - rect.midX, point.y - rect.midY)
                if best == nil || distance < best!.distance {
                    best = (checkbox, padded, distance)
                }
            }
            return best.map { ($0.checkbox, $0.rect) }
        }

        /// Padded on-screen rect for every footnote reference, same reasoning
        /// as checkboxHitRects() — the rendered glyph (a small raised number)
        /// is a tiny click target otherwise.
        @MainActor
        func footnoteHitRects() -> [NSRect] {
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return [] }
            let origin = textView.textContainerOrigin
            let padding: CGFloat = 6
            return MarkdownStyler.footnoteReferenceLabels(in: textView.string).map { footnote in
                let glyphRange = layoutManager.glyphRange(forCharacterRange: footnote.labelRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                return rect.insetBy(dx: -padding, dy: -padding)
            }
        }

        /// Closest footnote reference to the click point among all whose
        /// padded rect contains it — same reasoning as checkboxAndRect(at:).
        @MainActor
        private func footnoteAndRect(at point: NSPoint) -> (footnote: (labelRange: NSRange, label: String), rect: NSRect)? {
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return nil }
            let origin = textView.textContainerOrigin
            let padding: CGFloat = 6
            var best: (footnote: (labelRange: NSRange, label: String), rect: NSRect, distance: CGFloat)?
            for footnote in MarkdownStyler.footnoteReferenceLabels(in: textView.string) {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: footnote.labelRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                let padded = rect.insetBy(dx: -padding, dy: -padding)
                guard padded.contains(point) else { continue }
                let distance = hypot(point.x - rect.midX, point.y - rect.midY)
                if best == nil || distance < best!.distance {
                    best = (footnote, padded, distance)
                }
            }
            return best.map { ($0.footnote, $0.rect) }
        }

        /// Padded on-screen rect for every due token, same reasoning as
        /// checkboxHitRects()/footnoteHitRects() — this is a small inline
        /// span, and a click needs some margin around its exact glyphs to
        /// land reliably.
        @MainActor
        func dueTokenHitRects() -> [NSRect] {
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return [] }
            let origin = textView.textContainerOrigin
            let padding: CGFloat = 4
            return MarkdownStyler.dueTokenRanges(in: textView.string).map { due in
                let glyphRange = layoutManager.glyphRange(forCharacterRange: due.range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                return rect.insetBy(dx: -padding, dy: -padding)
            }
        }

        /// Closest due token to the click point among all whose padded rect
        /// contains it — same reasoning as checkboxAndRect(at:)/
        /// footnoteAndRect(at:).
        @MainActor
        private func dueTokenAndRect(at point: NSPoint) -> (due: (range: NSRange, isCrossedOut: Bool), rect: NSRect)? {
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return nil }
            let origin = textView.textContainerOrigin
            let padding: CGFloat = 4
            var best: (due: (range: NSRange, isCrossedOut: Bool), rect: NSRect, distance: CGFloat)?
            for due in MarkdownStyler.dueTokenRanges(in: textView.string) {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: due.range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                let padded = rect.insetBy(dx: -padding, dy: -padding)
                guard padded.contains(point) else { continue }
                let distance = hypot(point.x - rect.midX, point.y - rect.midY)
                if best == nil || distance < best!.distance {
                    best = (due, padded, distance)
                }
            }
            return best.map { ($0.due, $0.rect) }
        }

        @MainActor
        private func wikiLinkRanges(for text: String) -> [NSRange] {
            if text == cachedText { return cachedWikiLinkRanges }
            let ranges = MarkdownStyler.wikiLinkFullRanges(in: text)
            cachedText = text
            cachedWikiLinkRanges = ranges
            return ranges
        }

        /// Shows or hides the wiki-link ghost suggestion based on the current
        /// cursor position: active only with an empty selection sitting
        /// somewhere after an unclosed "[[" on the current line, with at
        /// least one character typed since it. Matching mirrors the search
        /// box's own suggestionNote/suggestionRemainder logic exactly —
        /// case-insensitive prefix match, first hit wins.
        @MainActor
        private func updateWikiLinkGhostSuggestion(in textView: NSTextView) {
            let selection = textView.selectedRange()
            guard !parent.plainTextMode, selection.length == 0 else {
                hideWikiLinkGhost()
                return
            }
            let nsText = textView.string as NSString
            let cursor = selection.location
            let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let searchRange = NSRange(location: lineRange.location, length: cursor - lineRange.location)
            let lastOpen = nsText.range(of: "[[", options: .backwards, range: searchRange)
            guard lastOpen.location != NSNotFound else {
                hideWikiLinkGhost()
                return
            }
            let afterOpen = lastOpen.location + lastOpen.length
            let closedBetween = nsText.range(of: "]]", options: [], range: NSRange(location: afterOpen, length: cursor - afterOpen))
            guard closedBetween.location == NSNotFound else {
                hideWikiLinkGhost()
                return
            }
            let query = nsText.substring(with: NSRange(location: afterOpen, length: cursor - afterOpen))
            guard !query.isEmpty, !query.contains("["), !query.contains("]") else {
                hideWikiLinkGhost()
                return
            }
            // The ghost is drawn as a label floating at the caret, not
            // inserted into the text, so it has nothing to push aside: any
            // characters between the caret and the link's end are still on
            // screen and the suggestion lands on top of them. Fine while the
            // caret is at the end of a link being typed — which is all this
            // ever handled — but editing inside a finished link renders the
            // remainder stacked over the text that's already there.
            let lineEnd = lineRange.location + lineRange.length
            let ahead = NSRange(location: cursor, length: lineEnd - cursor)
            let closeAhead = nsText.range(of: "]]", options: [], range: ahead)
            let trailing = closeAhead.location == NSNotFound
                ? ""  // unterminated link: the caret is at the end of what exists
                : nsText.substring(with: NSRange(location: cursor, length: closeAhead.location - cursor))
            guard trailing.isEmpty else {
                hideWikiLinkGhost()
                return
            }
            let lowered = query.lowercased()
            guard let match = parent.noteTitles.first(where: { $0.lowercased().hasPrefix(lowered) && $0.count > query.count }) else {
                hideWikiLinkGhost()
                return
            }
            let remainder = String(match.dropFirst(query.count))
            showWikiLinkGhost(remainder: remainder, atCursor: cursor, in: textView)
        }

        /// Positions the ghost label right after the last typed character,
        /// using the same glyph-rect math as checkboxHitRects()/
        /// footnoteHitRects() to convert a character range to an on-screen
        /// point.
        @MainActor
        private func showWikiLinkGhost(remainder: String, atCursor cursor: Int, in textView: NSTextView) {
            guard cursor > 0, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
                hideWikiLinkGhost()
                return
            }
            let charRange = NSRange(location: cursor - 1, length: 1)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let origin = textView.textContainerOrigin
            rect.origin.x += origin.x
            rect.origin.y += origin.y

            let label: WikiLinkGhostLabel
            if let existing = wikiLinkGhostLabel {
                label = existing
            } else {
                label = WikiLinkGhostLabel()
                label.isEditable = false
                label.isSelectable = false
                label.isBezeled = false
                label.isBordered = false
                label.drawsBackground = false
                label.lineBreakMode = .byClipping
                label.cell?.usesSingleLineMode = true
                textView.addSubview(label)
                wikiLinkGhostLabel = label
            }
            label.font = textView.font
            label.textColor = parent.theme.resolvedMarkerColor
            label.stringValue = remainder
            label.sizeToFit()
            label.frame.origin = NSPoint(x: rect.maxX, y: rect.minY)
            label.isHidden = false

            // The ghost renders as a floating overlay right where the real
            // "]]" already sits on screen — without this, the two visually
            // collide, the closing brackets bleeding right through the
            // suggestion text. Hiding the brackets' ink (not their layout
            // width, so nothing after them reflows) clears that space; a
            // normal restyle() puts them back the moment the ghost goes away.
            let nsText = textView.string as NSString
            let closeRange = NSRange(location: cursor, length: 2)
            if closeRange.location + closeRange.length <= nsText.length, nsText.substring(with: closeRange) == "]]" {
                textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.clear, range: closeRange)
            }

            wikiLinkGhostRemainder = remainder
            wikiLinkGhostAnchor = cursor
        }

        @MainActor
        private func hideWikiLinkGhost() {
            let hadActiveGhost = wikiLinkGhostRemainder != nil
            wikiLinkGhostLabel?.isHidden = true
            wikiLinkGhostRemainder = nil
            wikiLinkGhostAnchor = nil
            // Restores the real "]]" ink hidden by showWikiLinkGhost() —
            // needed here specifically for the dismiss-via-right-arrow path,
            // which doesn't otherwise trigger a restyle on its own.
            if hadActiveGhost, let textView { restyle(textView) }
        }

        /// Commits the currently-shown ghost suggestion into real text, only
        /// if the cursor hasn't moved since it was computed — Tab/Right-arrow
        /// otherwise fall through to their normal behavior.
        @MainActor
        private func acceptWikiLinkGhostSuggestionIfActive(in textView: NSTextView) -> Bool {
            guard let remainder = wikiLinkGhostRemainder,
                  let anchor = wikiLinkGhostAnchor,
                  textView.selectedRange() == NSRange(location: anchor, length: 0)
            else { return false }
            let range = NSRange(location: anchor, length: 0)
            guard textView.shouldChangeText(in: range, replacementString: remainder) else { return false }
            textView.textStorage?.replaceCharacters(in: range, with: remainder)
            textView.setSelectedRange(NSRange(location: anchor + (remainder as NSString).length, length: 0))
            textView.didChangeText()
            hideWikiLinkGhost()
            return true
        }

        /// Jumps the cursor past the nearest "]]" ahead of it, if the cursor
        /// currently sits inside an unclosed "[[" on the current line — lets
        /// Tab close out a wiki-link with no matching suggestion (an exact
        /// title, a brand-new note title, or just no match at all) the same
        /// way accepting a suggestion does when one is showing.
        @MainActor
        private func jumpPastWikiLinkCloseIfInside(in textView: NSTextView) -> Bool {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let nsText = textView.string as NSString
            let cursor = selection.location
            let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let backSearchRange = NSRange(location: lineRange.location, length: cursor - lineRange.location)
            let lastOpen = nsText.range(of: "[[", options: .backwards, range: backSearchRange)
            guard lastOpen.location != NSNotFound else { return false }
            let afterOpen = lastOpen.location + lastOpen.length
            let closedBeforeCursor = nsText.range(of: "]]", options: [], range: NSRange(location: afterOpen, length: cursor - afterOpen))
            guard closedBeforeCursor.location == NSNotFound else { return false }
            let lineEnd = lineRange.location + lineRange.length
            let close = nsText.range(of: "]]", options: [], range: NSRange(location: cursor, length: lineEnd - cursor))
            guard close.location != NSNotFound else { return false }
            textView.setSelectedRange(NSRange(location: close.location + close.length, length: 0))
            hideWikiLinkGhost()
            return true
        }
    }
}

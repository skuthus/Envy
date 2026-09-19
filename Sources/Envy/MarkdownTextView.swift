import SwiftUI
import AppKit
import VisionKit
import EnvyCore
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var onNavigate: (String) -> Void
    /// Extracts the selected text into a note of its own — the "one idea per
    /// note" split, applied to text already written. Given the selection, the
    /// handler creates the note and returns its final title (which can differ
    /// from the one asked for, if the name collided); this view then replaces
    /// the selection with a link to it. Nil means the note wasn't created, and
    /// the selection is left exactly as it was.
    var onExtractSelection: ((String) -> String?)?
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var searchQuery: String
    var fontZoom: CGFloat = 0
    var plainTextMode: Bool = false
    /// Glassify: the editor body becomes translucent so the window's
    /// behind-window blur (and the desktop through it) reads behind the text,
    /// like a terminal's background-opacity. The theme background is kept as a
    /// low-alpha tint rather than going fully clear so body text stays legible.
    var glassify: Bool = false
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
        // Only the real editing surfaces get a store (the main editor, pinned
        // popup, template editor) — so image drop/paste is naturally confined
        // to them and never fires in a read-only wikilink preview.
        textView.attachmentStore = store
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
            return coordinator.clickTargetRects().contains(where: { $0.contains(point) })
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
                MarkdownStyler.style(textStorage: textStorage, text: text, theme: theme, searchQuery: searchQuery, fontSizeAdjustment: fontZoom, allowsEmbeds: allowsEmbeds, embedHeights: context.coordinator.embedHeights, imageHeights: context.coordinator.imageHeights, noteTitles: noteTitles)
            }
        }
        context.coordinator.updateOverlays(in: textView)
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
            MainActor.assumeIsolated {
                guard let coordinator, let textView else { return }
                coordinator.handleFrameChange(in: textView)
            }
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
            coordinator.updateOverlays(in: textView)
        }
        // Same "wait one runloop turn for real layout/geometry" reasoning as
        // the checkbox overlay positioning above — scrollRangeToVisible
        // needs the scroll view to already know its real size, which isn't
        // true yet at the point makeNSView runs.
        if let initialSelectedRange, initialSelectedRange.location <= (text as NSString).length {
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(initialSelectedRange)
            }
        } else {
            // The updateNSView path covers every later query change and note
            // switch; this is the one case it can't see — a text view created
            // while a search is already active. Skipped entirely when the
            // caller asked for a specific cursor position, since that request
            // is the more specific intent (and no caller that makes it passes
            // a search query anyway).
            context.coordinator.jumpToFirstSearchMatch(query: searchQuery, in: textView)
        }
        context.coordinator.lastSearchQuery = searchQuery
        context.coordinator.lastFontZoom = fontZoom
        context.coordinator.lastPlainTextMode = plainTextMode
        context.coordinator.lastExternalReloadToken = externalReloadToken
        context.coordinator.lastHighlightTrigger = highlightTrigger
        context.coordinator.lastNoteID = currentNoteID
        return scrollView
    }

    static func currentSelection(of textView: NSTextView) -> NSRange? {
        textView.window?.firstResponder === textView ? textView.selectedRange() : nil
    }

    // Note switches REUSE this view (NoteEditorView is no longer .id-keyed per
    // note — recreating the whole NSTextView per click flashed the editor
    // blank): NoteEditorView.switchNote loads the new note's content and bumps
    // externalReloadToken, and the token branch below — seeing currentNoteID
    // differ from the coordinator's lastNoteID — replaces the text and resets
    // undo/scroll/selection in place. Outside that explicit token handshake,
    // this still never reconciles `text` against textView.string: `text` is
    // just an echo of the last edit and can lag textView.string by a render
    // cycle mid-typing. Comparing/pushing from `text` here was the previous
    // bug: a stale value could overwrite what was just typed, which is what
    // caused headings to flicker between their styled and plain form.
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
        var didSwitchNote = false
        if context.coordinator.lastExternalReloadToken != externalReloadToken {
            context.coordinator.lastExternalReloadToken = externalReloadToken
            // A note *switch* (same reused text view now showing a different
            // note) vs. an external edit to the note already open. The switch
            // is what removing the per-note .id() in ContentView routes through
            // here instead of a fresh makeNSView — so it has to reproduce the
            // clean-slate that recreation used to give for free: cursor home,
            // scroll to top, undo history dropped (so ⌘Z can't reach into the
            // previous note), and the per-note overlay height caches cleared.
            let isSwitch = context.coordinator.lastNoteID != currentNoteID
            didSwitchNote = isSwitch
            context.coordinator.lastNoteID = currentNoteID
            let cursor = textView.selectedRange()
            textView.string = text
            if isSwitch {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.undoManager?.removeAllActions()
                context.coordinator.embedHeights.removeAll()
                context.coordinator.imageHeights.removeAll()
                textView.scroll(NSPoint(x: 0, y: 0))
            } else {
                let clampedLocation = min(cursor.location, (text as NSString).length)
                textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
            }
            justReplacedText = true
        }

        let searchQueryChanged = context.coordinator.lastSearchQuery != searchQuery
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
                        imageHeights: context.coordinator.imageHeights,
                        noteTitles: noteTitles
                    )
                }
            }
            context.coordinator.updateOverlays(in: textView)
            context.coordinator.lastTheme = theme
            context.coordinator.lastSearchQuery = searchQuery
            context.coordinator.lastFontZoom = fontZoom
            context.coordinator.lastPlainTextMode = plainTextMode
            context.coordinator.lastProtectAISignature = protectAISignature
        }

        // Search used to highlight every match in the open note and then leave
        // the note exactly where it was — a match hundreds of lines down lit
        // up entirely offscreen, and arrowing through results landed on each
        // note's top (the scroll-to-zero on a switch above) no matter where
        // its match actually was. Bring the first match into view on the two
        // moments the match set can change under the user: the query changing,
        // and switching notes while a search is active. Deliberately not on
        // plain typing in the editor — the query is unchanged there, so this
        // doesn't fire and the caret keeps the scroll position it earns
        // normally.
        if searchQueryChanged || didSwitchNote {
            context.coordinator.jumpToFirstSearchMatch(query: searchQuery, in: textView)
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

        // Normally solid, regardless of the window's own transparency — body
        // text needs a legible, non-blurred backdrop even when the surrounding
        // chrome (sidebar, titlebar) is translucent. Glassify is the deliberate
        // exception: the whole text stack goes fully transparent — text view,
        // scroll view, AND the clip view (whose own opaque fill would otherwise
        // sit behind the text and cancel any translucency out) — so the
        // low-alpha tint SwiftUI paints behind the editor (see
        // ContentView.editorPaneBackground) is what shows, letting the
        // behind-window blur read through the terminal way.
        textView.drawsBackground = !glassify
        textView.backgroundColor = theme.resolvedBackgroundColor
        scrollView.drawsBackground = !glassify
        scrollView.backgroundColor = theme.resolvedBackgroundColor
        scrollView.contentView.drawsBackground = !glassify
        scrollView.contentView.backgroundColor = theme.resolvedBackgroundColor
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
        // Empty, deliberately: NSTextView otherwise paints `.link` ranges with
        // one uniform style (its default blue, or whatever single override is
        // set here), stomping the per-range colors MarkdownStyler applies.
        // The styler sets color + underline on every link span itself — which
        // is what lets an unresolved link render dimmed while resolved ones
        // keep full link color.
        textView.linkTextAttributes = [:]
    }
}


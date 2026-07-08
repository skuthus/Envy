import SwiftUI
import AppKit

final class HoverAwareTextView: NSTextView {
    var onHoverPoint: ((NSPoint) -> Void)?
    var onHoverExit: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

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
        onHoverPoint?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverExit?()
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var onNavigate: (String) -> Void
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var searchQuery: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = HoverAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
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

        textView.onHoverPoint = { [weak coordinator = context.coordinator] point in
            coordinator?.handleHover(at: point)
        }
        textView.onHoverExit = { [weak coordinator = context.coordinator] in
            coordinator?.clearHover()
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        applyTheme(theme, to: textView, scrollView: scrollView)
        if let textStorage = textView.textStorage {
            MarkdownStyler.style(textStorage: textStorage, text: text, theme: theme, searchQuery: searchQuery)
        }
        context.coordinator.lastSearchQuery = searchQuery
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

        applyTheme(theme, to: textView, scrollView: scrollView)

        if context.coordinator.lastTheme != theme || context.coordinator.lastSearchQuery != searchQuery {
            if let textStorage = textView.textStorage {
                MarkdownStyler.style(
                    textStorage: textStorage,
                    text: textView.string,
                    theme: theme,
                    revealedLinkRange: context.coordinator.hoveredLinkRange,
                    searchQuery: searchQuery,
                    cursorSelection: Self.currentSelection(of: textView)
                )
            }
            context.coordinator.lastTheme = theme
            context.coordinator.lastSearchQuery = searchQuery
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
        // NSTextView renders `.link`-attributed ranges with its own default color
        // (system blue), ignoring any per-range `.foregroundColor` we set in
        // MarkdownStyler, unless this is overridden explicitly.
        textView.linkTextAttributes = [
            .foregroundColor: theme.resolvedLinkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: HoverAwareTextView?
        var hoveredLinkRange: NSRange?
        var lastTheme: Theme?
        var lastSearchQuery: String = ""

        private var cachedText: String = ""
        private var cachedWikiLinkRanges: [NSRange] = []
        private var isHandlingTextChange = false

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isHandlingTextChange = true
            defer { isHandlingTextChange = false }
            parent.text = textView.string
            restyle(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Typing moves the cursor too, which fires this delegate method in
            // addition to textDidChange for the same keystroke. If it ran again
            // here, it would re-enter textStorage edits already in flight from
            // textDidChange's own restyle — skip it, since textDidChange already
            // restyles using the current cursor position.
            guard !isHandlingTextChange, let textView = notification.object as? NSTextView else { return }
            restyle(textView)
        }

        /// Re-applies styling using the view's own live content and current
        /// cursor position — the single source of truth for what's actually
        /// on screen, so this is always safe to call from any AppKit-native
        /// delegate callback (never from the SwiftUI-driven updateNSView,
        /// which can see a stale `text` binding — see its own comments).
        @MainActor
        private func restyle(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            MarkdownStyler.style(
                textStorage: textStorage,
                text: textView.string,
                theme: parent.theme,
                revealedLinkRange: hoveredLinkRange,
                searchQuery: parent.searchQuery,
                cursorSelection: MarkdownTextView.currentSelection(of: textView)
            )
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "velocity" else { return false }

            if parent.requireModifierForLinkClick {
                guard let event = NSApp.currentEvent, event.modifierFlags.contains(.command) else {
                    // Handled (as a no-op) rather than declined — declining makes
                    // NSTextView fall back to opening the URL itself via NSWorkspace,
                    // which fails loudly since "velocity://" has no registered handler.
                    return true
                }
            }

            let encoded = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let title = encoded.removingPercentEncoding ?? encoded
            parent.onNavigate(title)
            return true
        }

        @MainActor
        func handleHover(at point: NSPoint) {
            guard let textView else { return }
            let charIndex = textView.characterIndexForInsertion(at: point)
            let text = textView.string
            let ranges = wikiLinkRanges(for: text)
            let hit = ranges.first { NSLocationInRange(charIndex, $0) }

            guard hit != hoveredLinkRange else { return }
            hoveredLinkRange = hit
            restyle(textView)
        }

        @MainActor
        func clearHover() {
            guard hoveredLinkRange != nil, let textView else { return }
            hoveredLinkRange = nil
            restyle(textView)
        }

        @MainActor
        private func wikiLinkRanges(for text: String) -> [NSRange] {
            if text == cachedText { return cachedWikiLinkRanges }
            let ranges = MarkdownStyler.wikiLinkFullRanges(in: text)
            cachedText = text
            cachedWikiLinkRanges = ranges
            return ranges
        }
    }
}

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
    var focusedField: FocusState<FocusField?>.Binding
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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        applyTheme(theme, to: textView, scrollView: scrollView)

        if textView.string != text || context.coordinator.lastTheme != theme || context.coordinator.lastSearchQuery != searchQuery {
            let selectedRange = textView.selectedRange()
            if textView.string != text {
                textView.string = text
                context.coordinator.hoveredLinkRange = nil
            }
            if let textStorage = textView.textStorage {
                MarkdownStyler.style(
                    textStorage: textStorage,
                    text: text,
                    theme: theme,
                    revealedLinkRange: context.coordinator.hoveredLinkRange,
                    searchQuery: searchQuery
                )
            }
            textView.setSelectedRange(selectedRange)
            context.coordinator.lastTheme = theme
            context.coordinator.lastSearchQuery = searchQuery
        }

        if focusedField.wrappedValue == .editor, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func applyTheme(_ theme: Theme, to textView: NSTextView, scrollView: NSScrollView) {
        textView.font = theme.resolvedFont
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

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            parent.text = textView.string
            if let textStorage = textView.textStorage {
                MarkdownStyler.style(
                    textStorage: textStorage,
                    text: textView.string,
                    theme: parent.theme,
                    revealedLinkRange: hoveredLinkRange,
                    searchQuery: parent.searchQuery
                )
            }
            textView.setSelectedRange(selectedRange)
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
            if let textStorage = textView.textStorage {
                MarkdownStyler.style(
                    textStorage: textStorage,
                    text: text,
                    theme: parent.theme,
                    revealedLinkRange: hit,
                    searchQuery: parent.searchQuery
                )
            }
        }

        @MainActor
        func clearHover() {
            guard hoveredLinkRange != nil, let textView, let textStorage = textView.textStorage else { return }
            hoveredLinkRange = nil
            MarkdownStyler.style(
                textStorage: textStorage,
                text: textView.string,
                theme: parent.theme,
                revealedLinkRange: nil,
                searchQuery: parent.searchQuery
            )
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

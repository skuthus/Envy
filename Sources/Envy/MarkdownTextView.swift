import SwiftUI
import AppKit

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
    private var hoverTrackingArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var onNavigate: (String) -> Void
    var theme: Theme
    var requireModifierForLinkClick: Bool
    var searchQuery: String
    var fontZoom: CGFloat = 0

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
        textView.onClickPoint = { [weak coordinator = context.coordinator] point in
            coordinator?.handleClick(at: point) ?? false
        }
        textView.isOverClickTarget = { [weak coordinator = context.coordinator] point in
            guard let coordinator else { return false }
            return coordinator.checkboxHitRects().contains(where: { $0.contains(point) })
                || coordinator.footnoteHitRects().contains(where: { $0.contains(point) })
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        applyTheme(theme, to: textView, scrollView: scrollView)
        if let textStorage = textView.textStorage {
            MarkdownStyler.style(textStorage: textStorage, text: text, theme: theme, searchQuery: searchQuery, fontSizeAdjustment: fontZoom)
        }
        context.coordinator.lastSearchQuery = searchQuery
        context.coordinator.lastFontZoom = fontZoom
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

        if context.coordinator.lastTheme != theme
            || context.coordinator.lastSearchQuery != searchQuery
            || context.coordinator.lastFontZoom != fontZoom {
            if let textStorage = textView.textStorage {
                MarkdownStyler.style(
                    textStorage: textStorage,
                    text: textView.string,
                    theme: theme,
                    revealedLinkRange: context.coordinator.hoveredLinkRange,
                    searchQuery: searchQuery,
                    cursorSelection: Self.currentSelection(of: textView),
                    fontSizeAdjustment: fontZoom
                )
            }
            context.coordinator.lastTheme = theme
            context.coordinator.lastSearchQuery = searchQuery
            context.coordinator.lastFontZoom = fontZoom
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
        var lastFontZoom: CGFloat = 0

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
            expandEmojiShortcodeIfNeeded(in: textView)
            parent.text = textView.string
            restyle(textView)
            renumberOrderedListIfNeeded(in: textView)
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
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return continueListIfNeeded(in: textView)
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
                cursorSelection: MarkdownTextView.currentSelection(of: textView),
                fontSizeAdjustment: parent.fontZoom
            )
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

            guard url.scheme == "velocity" || url.scheme == "http" || url.scheme == "https" else {
                return false
            }

            if parent.requireModifierForLinkClick {
                guard let event = NSApp.currentEvent, event.modifierFlags.contains(.command) else {
                    // Handled (as a no-op) rather than declined — declining makes
                    // NSTextView fall back to opening the URL itself via NSWorkspace,
                    // which for "velocity://" fails loudly (no registered handler)
                    // and for http(s) would bypass this modifier requirement entirely.
                    return true
                }
            }

            if url.scheme == "velocity" {
                let encoded = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
                let title = encoded.removingPercentEncoding ?? encoded
                parent.onNavigate(title)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
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

        /// Toggles a task-list checkbox if the click landed on (or near) one.
        /// Hit-tests against the glyph's actual padded on-screen rect rather
        /// than character-index proximity — a single collapsed/substituted
        /// character is a near-unclickable target otherwise. Uses
        /// shouldChangeText/didChangeText (rather than mutating textStorage
        /// directly) so the edit participates in undo and triggers the normal
        /// textDidChange path — same restyle and save flow as typing.
        @MainActor
        func handleClick(at point: NSPoint) -> Bool {
            guard let textView else { return false }

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

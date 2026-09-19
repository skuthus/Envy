import SwiftUI
import AppKit
import VisionKit
import EnvyCore

final class HoverAwareTextView: NSTextView {
    /// Blockquote spans to draw a left rule beside, and the colour to draw
    /// it in. Set from the coordinator on every restyle.
    ///
    /// Drawn here rather than expressed as a text attribute because there
    /// is no attribute for "a line down the side of these paragraphs" —
    /// NSTextBlock can do borders but drags a whole table layout in with
    /// it. Drawing in the background pass keeps the rule pinned to the real
    /// line rects, so it follows wrapping, zoom and window width for free.
    var blockquoteRanges: [NSRange] = [] {
        didSet { if blockquoteRanges != oldValue { needsDisplay = true } }
    }
    var blockquoteRuleColor: NSColor = .tertiaryLabelColor

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }

        // Domain pills behind collapsed bare URLs. The pill color rides on the
        // .envyURLPill attribute the styler set, so there's no range list to
        // keep in sync — just draw a rounded capsule behind each marked run.
        // Bounded to the dirty rect's characters so a long note doesn't walk
        // its whole attribute table on every redraw.
        if let storage = textStorage, storage.length > 0 {
            let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
            let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
            if visibleChars.length > 0 {
                storage.enumerateAttribute(.envyURLPill, in: visibleChars, options: []) { value, attrRange, _ in
                    guard let tint = value as? NSColor else { return }
                    let font = (storage.attribute(.font, at: attrRange.location, effectiveRange: nil) as? NSFont)
                        ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    var emoji: String?
                    storage.enumerateAttribute(.envyURLEmoji, in: attrRange, options: []) { v, _, stop in
                        if let e = v as? String { emoji = e; stop.pointee = true }
                    }
                    let glyphRange = layoutManager.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
                    layoutManager.enumerateEnclosingRects(
                        forGlyphRange: glyphRange,
                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                        in: textContainer
                    ) { glyphRect, _ in
                        var box = glyphRect
                        box.origin.x += self.textContainerInset.width
                        box.origin.y += self.textContainerInset.height

                        tint.withAlphaComponent(0.16).setFill()
                        let pill = box.insetBy(dx: -4, dy: -1)
                        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()

                        // Emoji fills the reserved slot at the pill's left edge,
                        // drawn slightly below full size so a tall glyph isn't
                        // clipped against the line top.
                        if let emoji {
                            let emojiFont = NSFont.systemFont(ofSize: font.pointSize * MarkdownStyler.pillEmojiScale)
                            let s = emoji as NSString
                            let size = s.size(withAttributes: [.font: emojiFont])
                            s.draw(at: NSPoint(x: box.minX, y: box.midY - size.height / 2),
                                   withAttributes: [.font: emojiFont])
                        }
                        // Arrow fills the reserved trailing slot at the right.
                        let arrow = "↗" as NSString
                        let aSize = arrow.size(withAttributes: [.font: font])
                        arrow.draw(at: NSPoint(x: box.maxX - aSize.width, y: box.midY - aSize.height / 2),
                                   withAttributes: [.font: font, .foregroundColor: tint])
                    }
                }
            }
        }

        guard !blockquoteRanges.isEmpty else { return }
        blockquoteRuleColor.setFill()
        for range in blockquoteRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            bounds.origin.x += textContainerInset.width
            bounds.origin.y += textContainerInset.height
            guard bounds.intersects(rect) else { continue }
            // Sits in the gap the 16pt headIndent already opens up, at the
            // same 2pt weight an embed's rule uses — a quote and a
            // transclusion are the same idea, one static and one live, so
            // they get the same mark. Anchored to the container's left edge,
            // NOT bounds.minX: boundingRect unions whole line fragments for
            // a multi-line quote (minX 0) but hugs the glyphs for a
            // single-line one (minX ≈ the indent), which used to draw the
            // rule straight through the first character.
            let ruleX = textContainerInset.width + textContainer.lineFragmentPadding + 4
            let rule = NSRect(x: ruleX, y: bounds.minY, width: 2, height: bounds.height)
            rule.fill()
        }
    }

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
        // Accept dropped image files and raw image data so a picture can be
        // dragged straight onto a note. No-op where attachmentStore is nil
        // (read-only previews) — the drop handlers bail without it.
        registerForDraggedTypes([.fileURL, .png, .tiff])
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

    // MARK: - Image drop & paste

    /// The vault to file attachments into. Set by the coordinator; nil on
    /// read-only previews, which is what confines image drop/paste to the real
    /// editing surfaces.
    var attachmentStore: NoteStore?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageDragIsAcceptable(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageDragIsAcceptable(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handleImageDrop(sender) || super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if pasteImage() { return }
        super.paste(sender)
    }

    /// True when a drag carries something we'd attach — an image file or raw
    /// image data — so the drag shows the copy cursor over the note.
    private func imageDragIsAcceptable(_ sender: NSDraggingInfo) -> Bool {
        guard attachmentStore != nil, isEditable else { return false }
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { MarkdownStyler.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return true
        }
        return pb.availableType(from: [.png, .tiff]) != nil
    }

    /// Copies a dropped image file (leaving the original where it is) or writes
    /// dropped image data into the vault, then inserts the reference at the
    /// drop point.
    private func handleImageDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let store = attachmentStore, isEditable else { return false }
        let pb = sender.draggingPasteboard
        let stored: String?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first(where: { MarkdownStyler.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            stored = store.copyAttachment(from: file)
        } else {
            stored = CaptureImporter.imageName(from: pb, store: store)
        }
        guard let name = stored else { return false }
        // Land it where the cursor is, not wherever the caret last sat.
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        insertImageReference(name)
        return true
    }

    /// Pastes a screenshot or copied image — image data with no text on the
    /// board. Anything carrying text falls through to the normal text paste, so
    /// this never hijacks a plain paste.
    private func pasteImage() -> Bool {
        guard let store = attachmentStore, isEditable else { return false }
        let pb = NSPasteboard.general
        if let text = pb.string(forType: .string), !text.isEmpty { return false }
        guard let name = CaptureImporter.imageName(from: pb, store: store) else { return false }
        insertImageReference(name)
        return true
    }

    /// Inserts `![[name]]` on its own line with the blank line after that the
    /// block renderer reserves its room on — the same shape a note embed needs.
    func insertImageReference(_ name: String) {
        let selection = selectedRange()
        let ns = string as NSString
        let needsLeadingBreak = selection.location > 0 && ns.character(at: selection.location - 1) != 10
        let insertion = "\(needsLeadingBreak ? "\n" : "")![[\(name)]]\n\n"
        guard shouldChangeText(in: selection, replacementString: insertion) else { return }
        textStorage?.replaceCharacters(in: selection, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        // A freshly embedded image gets OCR'd in the background so it's
        // searchable without waiting for the next full backfill.
        if let store = attachmentStore {
            OCRIndex.shared.index(imageNamed: name, store: store)
        }
    }

    /// Inserts a 2×2 pipe-table skeleton at the caret and selects its first
    /// header cell, so the first thing typed replaces "Column 1". The selection
    /// lands inside the new block, which shows as raw pipes rather than the
    /// rendered grid — exactly right for a header you're about to overtype; it
    /// renders the moment the caret leaves. Padded onto its own lines the same
    /// way an embed reference is, so it always parses as a table block.
    func insertTableSkeleton() {
        let selection = selectedRange()
        let ns = string as NSString
        let atLineStart = selection.location == 0 || ns.character(at: selection.location - 1) == 10
        let followedByText: Bool = {
            let after = selection.location + selection.length
            guard after < ns.length else { return false }
            let lineRange = ns.lineRange(for: NSRange(location: after, length: 0))
            let tail = ns.substring(with: NSRange(location: after, length: lineRange.location + lineRange.length - after))
            return !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()
        let prefix = atLineStart ? "" : "\n\n"
        let suffix = followedByText ? "\n\n" : "\n"
        let insertion = prefix + PipeTable.skeleton + suffix
        guard shouldChangeText(in: selection, replacementString: insertion) else { return }
        textStorage?.replaceCharacters(in: selection, with: insertion)
        didChangeText()
        // The table renders at once as an editable grid (with "Column 1"/
        // "Column 2" placeholder headers to click and rename), so the caret is
        // left just after it rather than inside the pipes.
        let caret = min(selection.location + (insertion as NSString).length, (string as NSString).length)
        setSelectedRange(NSRange(location: caret, length: 0))
        scrollRangeToVisible(NSRange(location: caret, length: 0))
    }

    // MARK: - Continuity Camera (Import from iPhone or iPad)

    /// Declaring this view a valid requestor for an image (or PDF) return type
    /// is what makes AppKit insert the "Import from iPhone or iPad → Take Photo
    /// / Scan Documents" section into the Edit menu and this view's right-click
    /// menu automatically — the same Services-menu machinery, nothing to build
    /// by hand. Gated on an attachment store and an editable surface, so
    /// read-only previews never advertise it.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        // Camera capture can be hard-disabled (Settings → Import); when off, the
        // view stops vouching so AppKit never adds "Import from iPhone or iPad".
        if UserDefaults.standard.object(forKey: "cameraEnabled") as? Bool ?? true,
           attachmentStore != nil, isEditable, sendType == nil,
           let returnType, CaptureImporter.acceptedTypes.contains(returnType.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

// NSTextView already conforms to NSServicesMenuRequestor (for text); these
// override its receiving side to also accept a Continuity Camera capture,
// deferring to super for anything that isn't an image/PDF.
extension HoverAwareTextView {
    /// We only ever receive a capture, never hand a selection out to Continuity
    /// Camera; the text services NSTextView already provides pass through.
    override func writeSelection(to pboard: NSPasteboard,
                                 types: [NSPasteboard.PasteboardType]) -> Bool {
        super.writeSelection(to: pboard, types: types)
    }

    /// Receives a Continuity Camera capture: a photo becomes one embed, a scan
    /// one per page, each inserted in order through the shared CaptureImporter →
    /// `![[name]]` pipeline. A non-image board falls to the text view's own
    /// handling.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let store = attachmentStore, isEditable,
              let payload = CaptureImporter.payload(from: pboard) else {
            return super.readSelection(from: pboard)
        }
        // Read the board now (done, in payload); do the heavy rasterize/crop off
        // the main thread, then insert when it lands.
        Task { @MainActor [weak self] in
            let names = await CaptureImporter.saveImages(payload, into: store)
            guard let self else { return }
            for name in names { self.insertImageReference(name) }
        }
        return true
    }
}

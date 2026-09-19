import SwiftUI
import AppKit
import VisionKit
import EnvyCore

/// A word to light up in an image: `wholeWord` (a closed-quote search) matches
/// the whole word only; otherwise it's a substring, and only the matched span of
/// characters lights up — "super" inside "supernote" — mirroring how body-text
/// search highlighting behaves.
struct ImageHighlightTerm: Equatable {
    let text: String       // lowercased
    let wholeWord: Bool
}

/// Draws translucent search-match rectangles over an image. Sits above the
/// picture and passes every event through, so it only ever paints. Boxes are
/// normalized (0…1, bottom-left origin, matching this unflipped view); they map
/// onto the image's *displayed* rect, which — for a tall image clamped to the
/// max embed height — is proportionally fit and top-left aligned inside the
/// bounds, not the whole bounds (imageScaling .scaleProportionallyUpOrDown +
/// .alignTopLeft). Recomputed at draw time so it tracks resize for free.
private final class ImageHighlightOverlay: NSView {
    var boxes: [CGRect] = [] { didSet { if boxes != oldValue { needsDisplay = true } } }
    var color: NSColor = .systemYellow { didSet { if color != oldValue { needsDisplay = true } } }
    /// The image's own size (for aspect); zero falls back to filling the bounds.
    var imageSize: CGSize = .zero { didSet { if imageSize != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never intercept

    /// Where the image actually paints inside our bounds — proportional fit,
    /// hugging the top-left (matching the image view), so the highlight lands on
    /// the letterboxed picture rather than the empty gap beside it.
    private var contentRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: 0, y: bounds.height - h, width: w, height: h)   // top-left, y-up
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !boxes.isEmpty else { return }
        let content = contentRect
        color.withAlphaComponent(0.4).setFill()
        for box in boxes {
            let rect = NSRect(
                x: content.minX + box.minX * content.width,
                y: content.minY + box.minY * content.height,
                width: box.width * content.width,
                height: box.height * content.height
            ).insetBy(dx: -1, dy: -1)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// The inline block for an image attachment, floated over its reserved space by
/// the coordinator: the picture on top, an optional caption beneath it, and a
/// dashed "missing image" placeholder when the file can't be loaded. A right-
/// click offers size presets, caption/rename edits, and open/reveal — each
/// wired back to rewriting the `![[…]]` token or touching the file.
final class AttachmentView: NSView {
    static let captionHeight: CGFloat = 20
    static let brokenHeight: CGFloat = 64

    var attachmentName: String = ""
    var onResize: ((CGFloat?) -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onTranscribe: (() -> Void)?
    var onRename: ((String) -> Void)?
    /// Jump the editor's cursor into the marker's caption / width slot —
    /// inline editing in the note text itself, replacing the modal prompts
    /// these actions used to raise (see menu(for:) below).
    var onEditCaption: (() -> Void)?
    var onEditWidth: (() -> Void)?

    private let imageView = NSImageView()
    private let captionLabel = NSTextField(labelWithString: "")
    private var isBroken = false

    // MARK: Search-match highlighting (draws over matching words in the image)
    /// The file behind this view, so highlighting can OCR it for word boxes.
    private var attachmentURL: URL?
    /// Search terms to highlight in the image, and the color to use.
    private var highlightTerms: [ImageHighlightTerm] = []
    private var highlightColor: NSColor = .systemYellow
    /// OCR'd words + boxes for the current image, cached so retyping the search
    /// filters without re-recognizing. Keyed by the URL it was recognized from.
    private var recognizedWords: [ImageOCR.OCRWord] = []
    private var recognizedURL: URL?
    /// Drawn above the picture (a plain draw() would paint under the imageView
    /// subview and be hidden). Passes clicks through so it never eats a right-
    /// click or a Live Text drag.
    private let highlightOverlay = ImageHighlightOverlay()

    // MARK: Live Text (drag-select the text on a scan)
    /// VisionKit's Live Text layer. Sized to the image's *displayed* rect (not
    /// the whole view) so its normalized text geometry lands on the picture even
    /// when a tall page is letterboxed — the same content rect #1's highlights use.
    private let liveTextOverlay = ImageAnalysisOverlayView()
    private var liveTextTask: Task<Void, Never>?
    /// Analysis is lazy — kicked off on first hover, not on display — so images
    /// you never point at cost nothing. Reset when the image changes.
    private var liveTextRequested = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTopLeft
        imageView.imageFrameStyle = .none
        imageView.animates = true   // play animated GIFs instead of showing frame one
        addSubview(imageView)
        addSubview(highlightOverlay)   // above the image
        liveTextOverlay.preferredInteractionTypes = .textSelection
        liveTextOverlay.setSupplementaryInterfaceHidden(true, animated: false)  // no Live Text badge
        liveTextOverlay.delegate = self   // merges our context menu into Live Text's
        addSubview(liveTextOverlay)     // topmost, so it catches selection drags
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.isHidden = true
        addSubview(captionLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { liveTextTask?.cancel() }

    var displayImage: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            isBroken = (newValue == nil)
            imageView.isHidden = isBroken
            highlightOverlay.imageSize = newValue?.size ?? .zero
            // New image → drop any prior Live Text; re-armed on next hover.
            liveTextTask?.cancel()
            liveTextOverlay.analysis = nil
            liveTextRequested = false
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        ensureLiveText()   // prime Live Text the moment the pointer arrives
    }

    /// The picture's actual drawn rect inside this view — proportional fit,
    /// hugging the top-left (matching the image view) — so overlays land on the
    /// image rather than the letterbox gap beside a clamped tall page.
    private func displayedImageRect() -> NSRect {
        let frame = imageView.frame
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: frame.minX, y: frame.maxY - h, width: w, height: h)   // top-left, y-up
    }

    /// Requests Live Text analysis once, on first hover, from the shared cache —
    /// so pointing at a scan primes selection, while scans you never touch stay
    /// unanalyzed. Gated on the OCR setting and a real image.
    private func ensureLiveText() {
        guard !liveTextRequested,
              UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true,
              !isBroken, let url = attachmentURL else { return }
        liveTextRequested = true
        liveTextTask = Task { [weak self] in
            let analysis = await OCRIndex.shared.liveTextAnalysis(for: url)
            guard let self, self.attachmentURL == url, let analysis else { return }
            self.liveTextOverlay.analysis = analysis
        }
    }

    /// Points this view at its file and the active search terms; recomputes the
    /// highlighted word boxes when either changes. Called on every restyle, so
    /// it must stay cheap when nothing changed.
    func configureHighlight(url: URL?, terms: [ImageHighlightTerm], color: NSColor) {
        highlightColor = color
        highlightOverlay.color = color
        let changed = url != attachmentURL || terms != highlightTerms
        attachmentURL = url
        highlightTerms = terms
        if changed { refreshHighlights() }
    }

    private func refreshHighlights() {
        guard UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true,
              !highlightTerms.isEmpty, !isBroken, let url = attachmentURL else {
            setHighlightBoxes([]); return
        }
        if recognizedURL == url {          // words already in hand — just re-filter
            computeHighlightBoxes(); return
        }
        // Shared, cached recognition — a note switch back is instant.
        OCRIndex.shared.recognizeWords(for: url) { [weak self] words in
            guard let self, self.attachmentURL == url else { return }
            self.recognizedWords = words
            self.recognizedURL = url
            self.computeHighlightBoxes()
        }
    }

    private func computeHighlightBoxes() {
        // Whole-word boxes: Vision can't localize characters, so a matched word
        // lights up entirely. The quote distinction lives in the *match* — a
        // closed-quote term matches the whole word, an unquoted one a substring.
        let boxes = recognizedWords.compactMap { word -> CGRect? in
            let hit = highlightTerms.contains { term in
                term.wholeWord ? word.text == term.text : word.text.contains(term.text)
            }
            return hit ? word.box : nil
        }
        setHighlightBoxes(boxes)
    }

    private func setHighlightBoxes(_ boxes: [CGRect]) {
        highlightOverlay.boxes = boxes
    }

    var caption: String? {
        didSet {
            captionLabel.stringValue = caption ?? ""
            captionLabel.isHidden = (caption?.isEmpty ?? true)
            needsLayout = true
        }
    }

    /// Vertical space the caption line occupies (0 when there's no caption).
    var captionSpace: CGFloat { (caption?.isEmpty ?? true) ? 0 : Self.captionHeight }

    override func layout() {
        super.layout()
        let cap = captionSpace
        // Not flipped: y grows upward, so the picture sits on top and the
        // caption in the strip beneath it.
        imageView.frame = NSRect(x: 0, y: cap, width: bounds.width, height: max(bounds.height - cap, 0))
        highlightOverlay.frame = imageView.frame
        liveTextOverlay.frame = displayedImageRect()   // hug the picture, not the letterbox
        captionLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: cap)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isBroken else { return }
        let box = NSRect(x: 0, y: captionSpace, width: bounds.width,
                         height: max(bounds.height - captionSpace, 0)).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        path.stroke()
        let text = "\u{26A0}\u{FE0E} Missing image: \(attachmentName)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attrs)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (label, width) in [("Small", CGFloat(240)), ("Medium", CGFloat(400)), ("Large", CGFloat(640))] {
            let item = NSMenuItem(title: label, action: #selector(resizeToPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = width
            menu.addItem(item)
        }
        let original = NSMenuItem(title: "Original size", action: #selector(resizeToOriginal), keyEquivalent: "")
        original.target = self
        menu.addItem(original)
        let custom = NSMenuItem(title: "Custom width\u{2026}", action: #selector(resizeCustom), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        menu.addItem(.separator())
        let captionItem = NSMenuItem(title: "Caption\u{2026}", action: #selector(editCaption), keyEquivalent: "")
        captionItem.target = self
        menu.addItem(captionItem)
        let rename = NSMenuItem(title: "Rename\u{2026}", action: #selector(renameImage), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let open = NSMenuItem(title: "Open in Preview", action: #selector(openImage), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealImage), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        // On-device OCR; only worth offering when the image actually loaded.
        if !isBroken {
            menu.addItem(.separator())
            let copyText = NSMenuItem(title: "Copy Text from Image", action: #selector(copyTextFromImage), keyEquivalent: "")
            copyText.target = self
            menu.addItem(copyText)
            let transcribe = NSMenuItem(title: "Transcribe Text into Note", action: #selector(transcribeIntoNote), keyEquivalent: "")
            transcribe.target = self
            menu.addItem(transcribe)
        }
        return menu
    }

    @objc private func resizeToPreset(_ sender: NSMenuItem) { onResize?(sender.representedObject as? CGFloat) }
    @objc private func resizeToOriginal() { onResize?(nil) }
    @objc private func openImage() { onOpen?() }
    @objc private func revealImage() { onReveal?() }
    @objc private func copyTextFromImage() { onCopyText?() }
    @objc private func transcribeIntoNote() { onTranscribe?() }

    // Caption and width need no dialog at all — both are just text in the
    // marker (`![[name|400|caption]]`), so the menu item drops the cursor
    // straight into the right slot and you type in the note itself. Deferred
    // past the menu-tracking runloop, same as the old prompt was.
    @objc private func editCaption() {
        DispatchQueue.main.async { [weak self] in self?.onEditCaption?() }
    }

    @objc private func resizeCustom() {
        DispatchQueue.main.async { [weak self] in self?.onEditWidth?() }
    }

    /// Rename genuinely needs a commit step — it moves a real file and
    /// rewrites references across the vault, so edited marker text can't be
    /// silently treated as a rename. But it doesn't need to be modal: a small
    /// popover anchored at the image, field pre-focused and pre-selected, so
    /// typing starts immediately. Return commits, Esc or clicking away cancels.
    private var renamePopover: NSPopover?

    @objc private func renameImage() {
        DispatchQueue.main.async { [weak self] in self?.presentRenamePopover() }
    }

    private func presentRenamePopover() {
        renamePopover?.close()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = (attachmentName as NSString).deletingPathExtension
        field.placeholderString = "New name"
        field.target = self
        field.action = #selector(commitRename(_:))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 244, height: 48))
        field.frame = NSRect(x: 12, y: 12, width: 220, height: 24)
        container.addSubview(field)

        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        renamePopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        // First responder only lands once the popover's window exists —
        // making the field key is what selects its text, so typing replaces
        // the old name with zero extra clicks.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }

    @objc private func commitRename(_ sender: NSTextField) {
        let base = sender.stringValue.trimmingCharacters(in: .whitespaces)
        renamePopover?.close()
        renamePopover = nil
        if !base.isEmpty { onRename?(base) }
    }
}

// ImageAnalysisOverlayView is final, so its right-click menu can't be overridden
// by subclassing. Its delegate can amend the menu, though: prepend the
// attachment's own items (resize / caption / rename / transcribe / copy-text) so
// they survive alongside Live Text's Copy / Look Up.
extension AttachmentView: ImageAnalysisOverlayViewDelegate {
    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu,
                     for event: NSEvent, at point: CGPoint) -> NSMenu {
        guard let ours = self.menu(for: event) else { return menu }
        // A menu item can't live in two menus — move ours over, in order, ahead
        // of Live Text's, then a separator between the two groups.
        let ourItems = ours.items
        for (index, item) in ourItems.enumerated() {
            ours.removeItem(item)
            menu.insertItem(item, at: index)
        }
        if !ourItems.isEmpty, menu.numberOfItems > ourItems.count {
            menu.insertItem(.separator(), at: ourItems.count)
        }
        return menu
    }
}

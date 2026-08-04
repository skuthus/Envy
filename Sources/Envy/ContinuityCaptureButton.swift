import SwiftUI
import AppKit
import EnvyCore

/// The camera pill beside the search field: press it, pick Take Photo or Scan
/// Documents from an iPhone, and the capture becomes a brand-new note.
///
/// The SwiftUI capsule (matching the fleeting-note badge) is the look; a
/// transparent AppKit requestor sits on top to do the work. Continuity Camera is
/// only ever wired up through a *text view's contextual menu* — AppKit inserts
/// and enables the live "Import from iPhone or iPad" items there when the view is
/// a valid image requestor (the same path the note editor's right-click uses; a
/// plain NSView with a hand-built menu leaves the item greyed out). So the
/// requestor is an invisible NSTextView, and a left-click replays its
/// contextual-menu path.
struct ContinuityCaptureButton: NSViewRepresentable {
    /// Supplies the current store on demand (it can change with an Index switch).
    var store: () -> NoteStore?
    /// Called on the main actor with the saved attachment filenames of a capture.
    var onCapture: ([String]) -> Void

    func makeNSView(context: Context) -> ContinuityCaptureRequestorView {
        let view = ContinuityCaptureRequestorView()
        view.isEditable = false          // no caret/typing…
        view.isSelectable = true         // …but selectable, so it can be first responder
        view.drawsBackground = false
        view.delegate = view
        view.store = store
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: ContinuityCaptureRequestorView, context: Context) {
        view.store = store
        view.onCapture = onCapture
    }
}

/// Invisible text view that vouches for image/PDF captures and, on click,
/// presents its contextual menu — which AppKit populates with the live Take
/// Photo / Scan Documents entries.
final class ContinuityCaptureRequestorView: NSTextView, NSTextViewDelegate {
    var store: (() -> NoteStore?)?
    var onCapture: (([String]) -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)   // Services validation walks from here
        // Replay the right-click path: NSTextView's contextual-menu machinery is
        // what inserts and enables the Continuity Camera items. Synthesize the
        // secondary click at the same spot rather than hand-building a menu.
        guard let secondary = NSEvent.mouseEvent(
            with: .rightMouseDown, location: event.locationInWindow, modifierFlags: [],
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        rightMouseDown(with: secondary)
    }

    /// Return an empty contextual menu so only the Continuity Camera section
    /// AppKit adds shows — none of NSTextView's own editing items.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        NSMenu(title: menu.title)
    }

    /// Vouch for image and PDF return types — what makes AppKit populate the
    /// import-from-device items with the live Take Photo / Scan Documents entries.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType,
           CaptureImporter.acceptedTypes.contains(returnType.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Receives the capture, saves its images through the shared pipeline, and
    /// hands the filenames back so a note can be built around them.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let store = store?(), let payload = CaptureImporter.payload(from: pboard) else { return false }
        // Heavy processing off the main thread; build the note when it lands.
        Task { @MainActor [weak self] in
            let names = await CaptureImporter.saveImages(payload, into: store)
            guard !names.isEmpty else { return }
            self?.onCapture?(names)
        }
        return true
    }
}

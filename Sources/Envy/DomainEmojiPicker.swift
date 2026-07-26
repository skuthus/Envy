import AppKit

/// Opens the macOS emoji picker (Character Viewer) directly and hands back the
/// chosen emoji — no intermediate dialog or paste field for the user to deal
/// with.
///
/// The Character Viewer has no value-returning API: it inserts into whatever
/// text field is first responder. So this parks an invisible one-line field in
/// the window, focuses it, opens the picker, and reads the emoji back out of it
/// on the next keystroke — then tears the field down and restores the editor's
/// focus. A picker dismissed without a choice is caught by the field losing
/// focus, so nothing is left stranded holding first responder.
@MainActor
final class DomainEmojiPicker: NSObject, NSTextFieldDelegate {
    static let shared = DomainEmojiPicker()

    private weak var editor: NSTextView?
    private var field: NSTextField?
    private var onPick: ((String) -> Void)?
    private var done = false

    func present(in editor: NSTextView, onPick: @escaping (String) -> Void) {
        guard let window = editor.window else { return }
        // A previous, abandoned session shouldn't linger.
        teardown()

        self.editor = editor
        self.onPick = onPick
        self.done = false

        let f = NSTextField(frame: NSRect(x: -200, y: -200, width: 1, height: 1))
        f.delegate = self
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.textColor = .clear
        window.contentView?.addSubview(f)
        window.makeFirstResponder(f)
        field = f

        NSApp.orderFrontCharacterPalette(f)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !done, let emoji = field?.stringValue.first.map(String.init) else { return }
        done = true
        let pick = onPick
        teardown()
        pick?(emoji)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Field lost focus (picker closed, clicked away) with nothing chosen.
        if !done { teardown() }
    }

    private func teardown() {
        field?.removeFromSuperview()
        field = nil
        if let editor { editor.window?.makeFirstResponder(editor) }
        editor = nil
        onPick = nil
    }
}

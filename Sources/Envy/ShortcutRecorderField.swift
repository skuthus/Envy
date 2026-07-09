import SwiftUI
import AppKit

/// A small clickable field that shows the current shortcut and, when
/// clicked, captures the next key combination pressed and writes it back.
struct ShortcutRecorderField: View {
    @Binding var binding: ShortcutBinding
    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording = true
        } label: {
            Text(isRecording ? "Press shortcut…" : binding.spacedDisplayString)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isRecording ? .secondary : .primary)
                .frame(minWidth: 110, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isRecording ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .background(
            ShortcutCaptureRepresentable(isRecording: $isRecording) { character, keyCode, modifiers in
                binding = ShortcutBinding(
                    character: String(character),
                    keyCode: Int(keyCode),
                    modifiers: EventModifiers(modifiers).rawValue
                )
            }
        )
    }
}

/// Bridges to a tiny invisible NSView that becomes first responder while
/// recording, so it can intercept the raw NSEvent (character + keyCode +
/// modifiers) — nothing in SwiftUI's own key-handling API exposes keyCode,
/// which the global summon hotkey (Carbon-based) and the "Center Window"
/// local monitor both need.
private struct ShortcutCaptureRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (Character, UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = { character, keyCode, flags in
            onCapture(character, keyCode, flags)
            isRecording = false
        }
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        if isRecording, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class CaptureView: NSView {
        var onCapture: ((Character, UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Escape cancels without recording anything.
                onCancel?()
                return
            }
            // At least one of Command/Option/Control is required — a bare
            // letter or Shift+letter needs to keep working for normal
            // typing, so those alone can't become a shortcut.
            let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard relevant.contains(.command) || relevant.contains(.option) || relevant.contains(.control) else {
                NSSound.beep()
                return
            }
            guard let character = event.charactersIgnoringModifiers?.first else { return }
            onCapture?(character, event.keyCode, relevant)
        }

        // Clicking away while recording (rather than pressing a key or
        // Escape) should still fall back out of "recording" mode instead of
        // leaving the field stuck showing "Press shortcut…" forever.
        override func resignFirstResponder() -> Bool {
            onCancel?()
            return super.resignFirstResponder()
        }
    }
}

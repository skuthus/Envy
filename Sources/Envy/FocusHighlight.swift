import SwiftUI
import AppKit

/// Draws a stroked border around whichever pane currently has keyboard focus
/// (search box or editor). With "Fade out focus highlight" off, it just
/// tracks focus directly — on while focused, off the moment focus leaves.
/// With it on, the border appears the same way but fades away on its own
/// after a moment, so it reads as a brief "you're here now" cue rather than
/// a persistent outline around wherever the cursor happens to be.
struct FocusHighlight<S: Shape>: ViewModifier {
    let isFocused: Bool
    let fadeOut: Bool
    let color: Color
    let lineWidth: CGFloat
    let shape: S

    @State private var visible = false
    @State private var fadeTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(shape.stroke(color, lineWidth: lineWidth).opacity(visible ? 1 : 0))
            .onChange(of: isFocused) { _, focused in
                fadeTask?.cancel()
                if focused {
                    withAnimation(.easeInOut(duration: 0.15)) { visible = true }
                    if fadeOut {
                        fadeTask = Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { visible = false }
                        }
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { visible = false }
                }
            }
    }
}

extension View {
    func focusHighlight<S: Shape>(isFocused: Bool, fadeOut: Bool, color: Color, lineWidth: CGFloat, shape: S) -> some View {
        modifier(FocusHighlight(isFocused: isFocused, fadeOut: fadeOut, color: color, lineWidth: lineWidth, shape: shape))
    }
}

/// Split out of ContentView's body purely to keep the compiler's type-checking
/// time reasonable — too many chained `.onReceive` modifiers in one expression
/// has repeatedly hit "unable to type-check in reasonable time" as more were
/// added, and splitting into a separate modifier lets the compiler solve this
/// batch independently of the rest. One .onReceive chain covering every
/// editor-view toggle/adjustment notification got long enough to blow that
/// budget once backlinks joined zoom, settings, and plain-text mode.
struct EditorViewNotifications: ViewModifier {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomReset: () -> Void
    let openSettings: () -> Void
    let togglePlainTextMode: () -> Void
    let toggleBacklinks: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .zoomInRequested)) { _ in zoomIn() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOutRequested)) { _ in zoomOut() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomResetRequested)) { _ in zoomReset() }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: .togglePlainTextModeRequested)) { _ in togglePlainTextMode() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleBacklinksRequested)) { _ in toggleBacklinks() }
    }
}

struct FocusAndFullScreenNotifications: ViewModifier {
    let cycleFocus: (Int) -> Void
    @Binding var isFullScreen: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .focusNextAreaRequested)) { _ in
                cycleFocus(1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusPreviousAreaRequested)) { _ in
                cycleFocus(-1)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
                guard (note.object as? NSWindow) === NSApp.windows.first else { return }
                isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                guard (note.object as? NSWindow) === NSApp.windows.first else { return }
                isFullScreen = false
            }
    }
}

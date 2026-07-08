import SwiftUI
import AppKit

/// NSVisualEffectView has no public "blur radius" knob — only a fixed set of
/// system materials with genuinely different blur/tint character. These three
/// stand in for a "strength" control.
enum BlurStrength: String, CaseIterable, Identifiable {
    case off
    case subtle
    case medium
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .medium: "Medium"
        case .strong: "Strong"
        }
    }

    /// nil means "no blur" — there's no NSVisualEffectView material for that,
    /// so callers should fall back to a plain opaque background instead.
    var material: NSVisualEffectView.Material? {
        switch self {
        case .off: nil
        case .subtle: .underWindowBackground
        case .medium: .sidebar
        case .strong: .hudWindow
        }
    }
}

/// A real blurred/frosted backdrop, placed via SwiftUI's own `.background()` so it's
/// guaranteed to render behind the app's content. `containerBackground(_:for: .window)`
/// looks like the "proper" SwiftUI API for this, but on a plain AppKit-backed WindowGroup
/// it renders as a flat, non-blurred fill rather than real vibrancy — this NSVisualEffectView
/// route is what actually produces live backdrop blur.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

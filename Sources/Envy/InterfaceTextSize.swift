import SwiftUI

/// Scales the note list, search bar, sidebar/backlinks, and title bar —
/// everywhere in the main window that isn't the note body itself, which
/// already has its own separate Theme.fontSize/editorFontZoom controls.
///
/// Backed by an explicit point-size multiplier (`scale`, via
/// `interfaceFontScale` below), not DynamicTypeSize — macOS's Font.TextStyle
/// values (.body, .caption, etc.) turned out not to reliably resize with a
/// dynamicTypeSize environment override the way they do on iOS, so every
/// chrome font() call site is an explicit `.system(size:)` multiplied by
/// this instead, the same real-point-size approach Theme.fontSize already
/// uses successfully for the editor.
enum InterfaceTextSize: String, CaseIterable, Identifiable {
    case xSmall
    case small
    case medium
    case large
    case xLarge
    case xxLarge
    case xxxLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .xSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large (Default)"
        case .xLarge: "Extra Large"
        case .xxLarge: "XX Large"
        case .xxxLarge: "XXX Large"
        }
    }

    /// Multiplier against each chrome font's own base point size. 1 at
    /// .large (the default) so nothing changes for anyone who's never
    /// touched the setting.
    var scale: CGFloat {
        switch self {
        case .xSmall: 0.8
        case .small: 0.9
        case .medium: 0.95
        case .large: 1.0
        case .xLarge: 1.15
        case .xxLarge: 1.3
        case .xxxLarge: 1.5
        }
    }
}

private struct InterfaceFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var interfaceFontScale: CGFloat {
        get { self[InterfaceFontScaleKey.self] }
        set { self[InterfaceFontScaleKey.self] = newValue }
    }
}

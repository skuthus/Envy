import Foundation

/// What a plain (left) click on the menu bar eyecon does. Right-click
/// always shows the same small menu (New Note, Settings, Quit) regardless
/// of this setting.
enum MenuBarClickAction: String, CaseIterable, Identifiable {
    case toggleWindow
    case showPinnedNote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggleWindow: "Show or Hide Envy"
        case .showPinnedNote: "Show Pinned Note"
        }
    }
}

import Foundation

/// Where Envy shows up outside its own window — always at least one of the
/// two, so there's always a way to get to it besides the global hotkey.
enum AppVisibility: String, CaseIterable, Identifiable {
    case dockOnly
    case menuBarOnly
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dockOnly: "Dock Only"
        case .menuBarOnly: "Menu Bar Only"
        case .both: "Dock and Menu Bar"
        }
    }

    var showsInMenuBar: Bool { self != .dockOnly }
}

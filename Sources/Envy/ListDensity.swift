import SwiftUI

enum ListDensity: String, CaseIterable, Identifiable {
    case compact
    case cozy
    case comfy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: "Compact"
        case .cozy: "Cozy"
        case .comfy: "Comfy"
        }
    }

    /// Vertical padding around each row's own content. The note list is a
    /// custom ScrollView + LazyVStack (not List) specifically so this has
    /// direct, guaranteed effect — List's underlying NSTableView on macOS
    /// computes row height independently of .listRowInsets/content padding
    /// once laid out, and doesn't reliably re-observe inset-only changes.
    var rowVerticalPadding: CGFloat {
        switch self {
        case .compact: 1
        case .cozy: 5
        case .comfy: 10
        }
    }
}

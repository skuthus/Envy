import Foundation

enum TemplatesScope: String, CaseIterable, Identifiable {
    case global
    case perFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .global: "One shared Templates folder"
        case .perFolder: "Each notes folder has its own Templates folder"
        }
    }
}

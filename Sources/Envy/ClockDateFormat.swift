import Foundation

enum ClockDateFormat: String, CaseIterable, Identifiable {
    case short
    case medium
    case full
    case numeric

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: "Short (Jul 8)"
        case .medium: "Medium (July 8, 2026)"
        case .full: "Full (Tuesday, July 8, 2026)"
        case .numeric: "Numeric (7/8/2026)"
        }
    }

    func format(_ date: Date) -> String {
        switch self {
        case .short:
            return date.formatted(.dateTime.month(.abbreviated).day())
        case .medium:
            return date.formatted(.dateTime.month(.wide).day().year())
        case .full:
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .numeric:
            return date.formatted(.dateTime.month(.defaultDigits).day().year())
        }
    }
}

import Foundation

enum DateDisplayStyle: String, CaseIterable, Identifiable {
    case relative
    case smart
    case dateTime
    case dateOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relative: "Relative (e.g. 2 hours ago)"
        case .smart: "Smart (Today, Yesterday, or date)"
        case .dateTime: "Date & Time"
        case .dateOnly: "Date Only"
        }
    }

    /// Static formatting for all styles. `.relative` is special-cased to a
    /// live-ticking `Text(_:style:.relative)` at the call site instead of this,
    /// since that needs SwiftUI's own auto-refreshing view, not a plain String.
    func format(_ date: Date) -> String {
        switch self {
        case .relative:
            return date.formatted(.relative(presentation: .named))
        case .smart:
            let time = date.formatted(date: .omitted, time: .shortened)
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                return "Today, \(time)"
            } else if calendar.isDateInYesterday(date) {
                return "Yesterday, \(time)"
            } else {
                return date.formatted(date: .abbreviated, time: .omitted)
            }
        case .dateTime:
            return date.formatted(date: .abbreviated, time: .shortened)
        case .dateOnly:
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

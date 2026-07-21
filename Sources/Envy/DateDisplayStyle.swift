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

    /// Same shape as `format(_:)`, but for a due date rather than a real
    /// timestamp. A due date is always a calendar-day value with no
    /// meaningful time-of-day — every "@..." token, whether an explicit
    /// date, a day name, or @today/@tomorrow/@yesterday, resolves to
    /// local midnight (see NoteStore.resolveDueToken) — so a clock time
    /// next to one is never correct, unlike a note's real modifiedDate.
    /// `.smart`'s plain `format(_:)` only special-cased Today/Yesterday
    /// (modifiedDate is never in the future), which is what let a due
    /// date landing on today show as "Today, 12:00 AM" — a literal
    /// midnight formatted as if it meant something. Foundation's own
    /// relative formatter has the same problem from a different angle:
    /// it agrees there's no time for anything more than a day away ("in
    /// 5 days", "5 days ago"), but falls back to hour-based wording
    /// ("10 hours ago") for today/tomorrow specifically, since it
    /// compares exact instants rather than calendar days. Today/Tomorrow/
    /// Yesterday are special-cased explicitly here instead, for every
    /// style, and every style falls back to a plain date (no time) for
    /// anything further out — the only real choice left for a
    /// time-of-day-less value is relative-day wording vs. an absolute
    /// date, which .smart/.dateTime/.dateOnly all agree on once the
    /// near-term special cases are handled.
    func formatDueDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        // Within the coming week, name the day — the friendly label you'd
        // have typed as "@monday", now that the token itself freezes to an
        // absolute date. Applied for every style, the same way Today /
        // Tomorrow / Yesterday already are.
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        if let days = calendar.dateComponents([.day], from: today, to: target).day, (2...6).contains(days) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        switch self {
        case .relative:
            return date.formatted(.relative(presentation: .named))
        case .smart, .dateTime, .dateOnly:
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

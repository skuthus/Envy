import Foundation
import EnvyCore

enum TrashEmptyUnit: String, CaseIterable, Identifiable {
    case days
    case weeks
    case months

    var id: String { rawValue }

    var label: String {
        switch self {
        case .days: "Day(s)"
        case .weeks: "Week(s)"
        case .months: "Month(s)"
        }
    }

    /// The Calendar component to add for this unit, so an interval tracks
    /// real calendar weeks/months (a month means "the same day next month,"
    /// not a fixed count of seconds) rather than an approximation.
    var calendarComponent: Calendar.Component {
        switch self {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        }
    }
}

/// Governs how often notes sitting in The Index's own Trash/ subfolder get
/// swept into the real macOS Trash — see NoteStore.emptyTrash(). Soft-deleted
/// notes (NoteStore.delete(_:)) land in Trash/ first so "restore last
/// deleted" keeps working; this is the second, slower-acting stage behind
/// that, not a replacement for it.
enum TrashPreference {
    static let intervalValueKey = "trashEmptyIntervalValue"
    static let intervalUnitKey = "trashEmptyIntervalUnit"
    static let lastEmptiedKey = "trashLastEmptiedDate"

    static let defaultIntervalValue = 30
    static let defaultIntervalUnit = TrashEmptyUnit.days

    /// Checks whether enough time has passed since the last sweep and, if
    /// so, empties Trash/ into the real macOS Trash and records now as the
    /// new baseline. Cheap to call often — a UserDefaults read and a date
    /// comparison — since the actual file-moving work in emptyTrash() only
    /// happens on the rare occasion it's actually due.
    @MainActor
    static func emptyIfDue(_ store: NoteStore) {
        let value = UserDefaults.standard.object(forKey: intervalValueKey) as? Int ?? defaultIntervalValue
        let unit = TrashEmptyUnit(rawValue: UserDefaults.standard.string(forKey: intervalUnitKey) ?? "") ?? defaultIntervalUnit
        let last = UserDefaults.standard.object(forKey: lastEmptiedKey) as? Date ?? .distantPast
        guard let dueDate = Calendar.current.date(byAdding: unit.calendarComponent, value: value, to: last),
              Date() >= dueDate else { return }
        store.emptyTrash()
        UserDefaults.standard.set(Date(), forKey: lastEmptiedKey)
    }
}

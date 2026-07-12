import Foundation

/// {{date}}'s format, as a raw DateFormatter pattern the user types
/// themselves (macOS's native token syntax — "yyyy-MM-dd", "MMMM d, yyyy",
/// "EEEE" — not strftime's %-codes) rather than a fixed set of presets.
enum TemplateDateFormat {
    static let defaultPattern = "MMMM d, yyyy"

    static func string(from date: Date, pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.dateFormat = trimmed.isEmpty ? defaultPattern : trimmed
        return formatter.string(from: date)
    }
}

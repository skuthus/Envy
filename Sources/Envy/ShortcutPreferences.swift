import Foundation

/// Persists user-customized shortcut bindings as a single JSON-encoded
/// dictionary (action rawValue -> binding) under one AppStorage-friendly
/// String key, rather than one AppStorage entry per action. Actions with no
/// entry simply use their default binding — resetting one is just removing
/// its entry, not writing the default back out.
enum ShortcutPreferences {
    static let storageKey = "customShortcuts"

    static func loadAll(from raw: String) -> [String: ShortcutBinding] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func encode(_ bindings: [String: ShortcutBinding]) -> String {
        guard let data = try? JSONEncoder().encode(bindings),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    static func binding(for action: ShortcutAction, raw: String) -> ShortcutBinding {
        loadAll(from: raw)[action.rawValue] ?? action.defaultBinding
    }
}

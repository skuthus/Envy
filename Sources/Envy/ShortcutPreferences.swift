import Foundation

/// Persists user-customized shortcut bindings as a single JSON-encoded
/// dictionary (action rawValue -> binding) under one AppStorage-friendly
/// String key, rather than one AppStorage entry per action. Actions with no
/// entry simply use their default binding — resetting one is just removing
/// its entry, not writing the default back out.
enum ShortcutPreferences {
    static let storageKey = "customShortcuts"

    /// One-entry memo of the last decode: `binding(for:raw:)` gets called
    /// from keypress monitors and from menu-building view bodies (a dozen-plus
    /// lookups per body pass), always with the same raw string until the user
    /// actually edits a shortcut — so everything after the first lookup is a
    /// string compare instead of a JSON decode. Lock-guarded (same pattern as
    /// NoteDerivedCache) rather than actor-isolated so callers stay free of
    /// isolation requirements; the lock is uncontended in practice.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedRaw: String?
    nonisolated(unsafe) private static var cachedBindings: [String: ShortcutBinding] = [:]

    static func loadAll(from raw: String) -> [String: ShortcutBinding] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if raw == cachedRaw { return cachedBindings }
        let decoded = decodeAll(from: raw)
        cachedRaw = raw
        cachedBindings = decoded
        return decoded
    }

    private static func decodeAll(from raw: String) -> [String: ShortcutBinding] {
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

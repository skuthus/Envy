import SwiftUI
import EnvyCore

/// Per-subfolder colors, stored as one JSON dictionary (folder path -> color)
/// under a single AppStorage key — the same shape TagColorPreferences uses.
///
/// The key is the subfolder's path *relative to the Index root* (e.g.
/// "Projects" or "Projects/Work"), so it survives the Index being moved and
/// distinguishes same-named folders at different depths. Like a tag's color,
/// this is a preference, not note content: a note's category is the folder its
/// file physically sits in (the truth, on disk), and the color is presentation
/// keyed by that folder — nothing is written into any note.
enum FolderColorPreferences {
    static let storageKey = "folderColors"

    /// The swatches offered in the color menu — the app's own palette, so a
    /// colored folder sits in the same family as tags and links.
    static let presets: [(name: String, color: Color)] = [
        ("Red", Color(red: 0xFF/255, green: 0x4B/255, blue: 0x39/255)),
        ("Orange", Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)),
        ("Yellow", Color(red: 0xF5/255, green: 0xD4/255, blue: 0x23/255)),
        ("Green", Color(red: 0x30/255, green: 0xD1/255, blue: 0x58/255)),
        ("Blue", Color(red: 0x5A/255, green: 0x80/255, blue: 0xFF/255)),
        ("Purple", Color(red: 0xB4/255, green: 0x6B/255, blue: 0xFF/255)),
        ("Pink", Color(red: 0xFF/255, green: 0x6F/255, blue: 0xB0/255)),
    ]

    static func loadAll(from raw: String) -> [String: CodableColor] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: CodableColor].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func encode(_ colors: [String: CodableColor]) -> String {
        guard let data = try? JSONEncoder().encode(colors),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    static func color(for folderPath: String, raw: String) -> Color? {
        loadAll(from: raw)[folderPath]?.color
    }

    /// Sets (or, with nil, clears) a folder's color and returns the new raw
    /// string to store back.
    static func setting(_ color: Color?, for folderPath: String, in raw: String) -> String {
        var all = loadAll(from: raw)
        if let color {
            all[folderPath] = CodableColor(nsColor: NSColor(color))
        } else {
            all[folderPath] = nil
        }
        return encode(all)
    }
}

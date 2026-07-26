import SwiftUI

/// Per-tag colors, stored as one JSON dictionary (tag name -> color) under a
/// single AppStorage-friendly String key — the same shape ShortcutPreferences
/// uses.
///
/// This is deliberately a *preference*, not note content. The tag itself lives
/// in the plain-text file and is the truth; its color is presentation, config
/// the way the theme is. Open the vault in another editor and the `#tag` is
/// still there, categorising exactly as before — only the tint, which was never
/// in the file, is absent. That's the line that keeps colored tags from
/// becoming hidden per-note state: a color belongs to a tag name, shared by
/// every note that carries it, never attached to a note behind its back.
enum TagColorPreferences {
    static let storageKey = "tagColors"

    /// The swatches offered first in the right-click menu. Each pairs with an
    /// emoji circle whose hue matches its color: macOS renders emoji in full
    /// color inside a menu, where a tinted SF Symbol is unreliable, so the emoji
    /// is what actually shows the swatch. "+" (Custom Color…) covers the rest.
    /// Reds, greens and blues are the brand colors so a tinted tag sits in the
    /// same palette as everything else.
    static let presets: [(name: String, emoji: String, color: Color)] = [
        ("Red",    "🔴", Color(red: 0xFF/255, green: 0x4B/255, blue: 0x39/255)),
        ("Orange", "🟠", Color(red: 0xF5/255, green: 0xA6/255, blue: 0x23/255)),
        ("Yellow", "🟡", Color(red: 0xF5/255, green: 0xD4/255, blue: 0x23/255)),
        ("Green",  "🟢", Color(red: 0x30/255, green: 0xD1/255, blue: 0x58/255)),
        ("Blue",   "🔵", Color(red: 0x5A/255, green: 0x80/255, blue: 0xFF/255)),
        ("Purple", "🟣", Color(red: 0xB4/255, green: 0x6B/255, blue: 0xFF/255)),
        ("Pink",   "🩷", Color(red: 0xFF/255, green: 0x6F/255, blue: 0xB0/255)),
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

    /// The color for `tag`, or nil when it has none and should render with the
    /// theme's ordinary tag colors.
    static func color(for tag: String, raw: String) -> Color? {
        loadAll(from: raw)[tag]?.color
    }

    /// Sets (or, with nil, clears) a tag's color and returns the new raw string
    /// to write back to the AppStorage binding. Keeping the read-modify-write in
    /// one place means callers never decode, mutate, and re-encode by hand.
    static func setting(_ color: Color?, for tag: String, in raw: String) -> String {
        var all = loadAll(from: raw)
        if let color {
            all[tag] = CodableColor(nsColor: NSColor(color))
        } else {
            all[tag] = nil
        }
        return encode(all)
    }
}

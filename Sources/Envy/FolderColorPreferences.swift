import SwiftUI
import AppKit
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

    /// The swatches offered in the color menu — the same palette (and menu
    /// emoji) as TagColorPreferences, so a colored folder sits in the same
    /// family as tags and links.
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

/// Drives the shared macOS color panel for the folder marker's "Custom
/// Color…" item — TagColorPanel's twin, and the same reasoning: the panel is
/// a single global object outliving any one row view and updates continuously
/// as the user drags, so each change writes straight to UserDefaults against
/// whatever the current stored value is; @AppStorage observers repaint.
@MainActor
enum FolderColorPanel {
    // @MainActor because AppKit's colour-panel target-action always fires on
    // the main thread — a nested class doesn't inherit the enclosing enum's
    // isolation (see TagColorPanel.Target).
    @MainActor private final class Target: NSObject {
        var folderPath: String = ""
        @objc func changed(_ sender: NSColorPanel) {
            let raw = UserDefaults.standard.string(forKey: FolderColorPreferences.storageKey) ?? ""
            let updated = FolderColorPreferences.setting(Color(nsColor: sender.color), for: folderPath, in: raw)
            UserDefaults.standard.set(updated, forKey: FolderColorPreferences.storageKey)
        }
    }
    private static let target = Target()

    static func present(initial: NSColor, for folderPath: String) {
        target.folderPath = folderPath
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        panel.isContinuous = true
        panel.setTarget(target)
        panel.setAction(#selector(Target.changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }
}

/// The right-click recolor menu shared by every folder marker — the list's
/// dot/name chip (NoteRow) and the editor title bar's folder chip
/// (NoteEditorView) — all writing the same preference, so a recolor from
/// any of them repaints the rest live.
struct FolderColorMenu: View {
    let folderName: String
    /// The folder's current resolved color, seeding the custom picker.
    let currentColor: Color?
    /// When set, the menu offers "Rename Folder…", handing the folder back
    /// for the caller to run the vault-wide rename (see
    /// ContentView.commitFolderRename). Left nil where rename doesn't
    /// belong (the list's dots, the title-bar chip), so the item appears
    /// only in the folder browser — mirroring TagChipView's onRename.
    var onRename: ((String) -> Void)? = nil
    @AppStorage(FolderColorPreferences.storageKey) private var folderColorsRaw = ""

    var body: some View {
        ForEach(FolderColorPreferences.presets, id: \.name) { preset in
            Button {
                folderColorsRaw = FolderColorPreferences.setting(preset.color, for: folderName, in: folderColorsRaw)
            } label: {
                Text("\(preset.emoji)  \(preset.name)")
            }
        }

        Button("Custom Color…") {
            FolderColorPanel.present(
                initial: NSColor(currentColor ?? .secondary),
                for: folderName)
        }

        if let onRename {
            Divider()
            Button("Rename Folder…") { onRename(folderName) }
        }

        if FolderColorPreferences.color(for: folderName, raw: folderColorsRaw) != nil {
            Divider()
            Button("Remove Color", role: .destructive) {
                folderColorsRaw = FolderColorPreferences.setting(nil, for: folderName, in: folderColorsRaw)
            }
        }
    }
}

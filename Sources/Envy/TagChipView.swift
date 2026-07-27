import SwiftUI
import AppKit

/// One tag pill in the editor's title bar. Tapping searches for the tag;
/// right-clicking assigns it a color, which every note carrying that tag then
/// shows — the color belongs to the tag name, not to any one note.
struct TagChipView: View {
    let tag: String
    let theme: Theme
    let onTagSearch: (String) -> Void

    @AppStorage(TagColorPreferences.storageKey) private var tagColorsRaw = ""

    private var customColor: Color? {
        TagColorPreferences.color(for: tag, raw: tagColorsRaw)
    }

    var body: some View {
        Text("#\(tag)")
            .font(.caption.bold())
            .foregroundStyle(customColor ?? Color(nsColor: theme.resolvedTagColor))
            // A tinted tag paints its own translucent capsule from its color so
            // it reads as that color without a second theme entry; an untinted
            // one keeps the theme's ordinary tag background unchanged.
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(customColor.map { $0.opacity(0.18) } ?? Color(nsColor: theme.resolvedTagBackgroundColor))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { onTagSearch(tag) }
            .contextMenu {
                ForEach(TagColorPreferences.presets, id: \.name) { preset in
                    Button {
                        tagColorsRaw = TagColorPreferences.setting(preset.color, for: tag, in: tagColorsRaw)
                    } label: {
                        Text("\(preset.emoji)  \(preset.name)")
                    }
                }

                Button("Custom Color…") {
                    TagColorPanel.present(
                        initial: NSColor(customColor ?? Color(nsColor: theme.resolvedTagColor)),
                        for: tag)
                }

                if customColor != nil {
                    Divider()
                    Button("Remove Color", role: .destructive) {
                        tagColorsRaw = TagColorPreferences.setting(nil, for: tag, in: tagColorsRaw)
                    }
                }
            }
    }
}

/// Drives the shared macOS color panel for the "Custom Color…" item.
///
/// Writes straight to UserDefaults rather than capturing a SwiftUI binding: the
/// panel is a single global object outliving any one chip view, and the panel
/// updates continuously as the user drags, so each change has to land on
/// whatever the current stored value is — @AppStorage(storageKey) observers
/// then repaint on their own.
@MainActor
enum TagColorPanel {
    // @MainActor because AppKit's colour-panel target-action always fires on
    // the main thread — a nested class doesn't inherit the enclosing enum's
    // isolation, so without this the @objc handler reads NSColorPanel.color
    // (main-actor-isolated) from a nonisolated context and warns.
    @MainActor private final class Target: NSObject {
        var tag: String = ""
        @objc func changed(_ sender: NSColorPanel) {
            let raw = UserDefaults.standard.string(forKey: TagColorPreferences.storageKey) ?? ""
            let updated = TagColorPreferences.setting(Color(nsColor: sender.color), for: tag, in: raw)
            UserDefaults.standard.set(updated, forKey: TagColorPreferences.storageKey)
        }
    }
    private static let target = Target()

    static func present(initial: NSColor, for tag: String) {
        target.tag = tag
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        panel.isContinuous = true
        panel.setTarget(target)
        panel.setAction(#selector(Target.changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }
}

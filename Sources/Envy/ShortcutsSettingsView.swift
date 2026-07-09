import SwiftUI

struct ShortcutsSettingsView: View {
    @AppStorage(ShortcutPreferences.storageKey) private var customShortcutsRaw = ""

    private func binding(for action: ShortcutAction) -> Binding<ShortcutBinding> {
        Binding(
            get: { ShortcutPreferences.binding(for: action, raw: customShortcutsRaw) },
            set: { newValue in
                var all = ShortcutPreferences.loadAll(from: customShortcutsRaw)
                all[action.rawValue] = newValue
                customShortcutsRaw = ShortcutPreferences.encode(all)
            }
        )
    }

    private func isCustomized(_ action: ShortcutAction) -> Bool {
        ShortcutPreferences.loadAll(from: customShortcutsRaw)[action.rawValue] != nil
    }

    private func reset(_ action: ShortcutAction) {
        var all = ShortcutPreferences.loadAll(from: customShortcutsRaw)
        all.removeValue(forKey: action.rawValue)
        customShortcutsRaw = ShortcutPreferences.encode(all)
    }

    /// The other action already using this exact combination, if any — a
    /// lightweight nudge rather than a hard block, since which one "wins"
    /// in practice depends on context (menu items vs. the global hotkey
    /// don't actually collide with each other, for instance).
    private func conflict(for action: ShortcutAction) -> ShortcutAction? {
        let current = binding(for: action).wrappedValue
        return ShortcutAction.allCases.first {
            $0 != action && ShortcutPreferences.binding(for: $0, raw: customShortcutsRaw) == current
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.label)
                                .font(.body)
                            if let conflict = conflict(for: action) {
                                Text("Also used by \(conflict.label)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        ShortcutRecorderField(binding: binding(for: action))
                        Button("Reset") {
                            reset(action)
                        }
                        .disabled(!isCustomized(action))
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new key combination. Escape cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Reset All to Defaults") {
                customShortcutsRaw = ""
            }
            .disabled(ShortcutPreferences.loadAll(from: customShortcutsRaw).isEmpty)
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

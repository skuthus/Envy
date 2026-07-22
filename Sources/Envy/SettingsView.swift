import SwiftUI

struct SettingsView: View {
    // Persisted so the File-menu "Import from Apple Notes…" command can select
    // the Import tab before opening this window — otherwise the menu item would
    // dump the user on whatever tab happened to be showing.
    @AppStorage("settingsSelectedTab") private var selection = "general"

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("general")
            ThemeSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag("appearance")
            ShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag("shortcuts")
            ImportSettingsView()
                .tabItem {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .tag("import")
        }
    }
}

import SwiftUI

struct AboutView: View {
    @State private var showingMarkupHelp = false
    @State private var showingKeyboardShortcuts = false

    var body: some View {
        VStack(spacing: 10) {
            EnvyLogoView(size: 72)
                .padding(.bottom, 4)

            Text(titleText)
                .font(.title.bold())

            Text("A fast, flat-file note-taking app.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Version 1.12")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 6)

            Text("Made by Skyler Schoos")
                .font(.callout)

            Text("© 2026")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Button("View Markup Commands…") {
                    showingMarkupHelp = true
                }
                Button("View Keyboard Shortcuts…") {
                    showingKeyboardShortcuts = true
                }
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 320)
        .sheet(isPresented: $showingMarkupHelp) {
            MarkupHelpView()
        }
        .sheet(isPresented: $showingKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
    }

    // "E" + green "NV" (matching the logo's iris) + "y".
    private var titleText: AttributedString {
        var attributed = AttributedString("Envy")
        if let range = attributed.range(of: "nv") {
            attributed[range].foregroundColor = EnvyLogoView.irisColor
        }
        return attributed
    }
}

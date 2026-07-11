import SwiftUI

struct AboutView: View {
    @State private var showingMarkupHelp = false
    @State private var showingKeyboardShortcuts = false
    @Environment(\.openURL) private var openURL

    // Reads from the bundle rather than a hardcoded string, so this can't
    // drift out of sync with Info.plist the way the "Version 1.0.0" literal
    // here used to.
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "Version \(version)"
    }

    var body: some View {
        VStack(spacing: 10) {
            EnvyLogoView(size: 72)
                .padding(.bottom, 4)

            Text(titleText)
                .font(.title.bold())

            Text("A flat-file, frictionless note-taking application.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(versionText)
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
                Button("View Changelog…") {
                    openURL(URL(string: "https://envynote.app/changelog.html")!)
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

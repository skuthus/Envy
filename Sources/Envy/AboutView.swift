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
                // Without this, Text truncates with an ellipsis instead of
                // wrapping to a second line in this fixed-width window —
                // same fix as WhatsNewView's own text needed.
                .fixedSize(horizontal: false, vertical: true)

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

    // "E" + red "NV" + "y" — the Notational Velocity lineage carried inside
    // the name, in the same brand red the site's wordmark uses.
    private var titleText: AttributedString {
        var attributed = AttributedString("Envy")
        if let range = attributed.range(of: "nv") {
            attributed[range].foregroundColor = EnvyLogoView.markColor
        }
        return attributed
    }
}

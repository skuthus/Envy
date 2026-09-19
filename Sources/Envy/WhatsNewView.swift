import SwiftUI

/// Shown once, automatically, the first time someone launches Envy after
/// updating — not on a brand-new install, which the welcome note already
/// covers. Lists what changed in this release; the copy is the user's own,
/// deliberately informal, and is not sanitized.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private struct Feature: Identifiable {
        let id = UUID()
        let title: String
        let details: [String]
    }

    private let newFeatures: [Feature] = [
        Feature(title: "Nested folders show properly", details: [
            "debated over this one for a while but its dead useful."
        ]),
        Feature(title: "Make a subfolder while moving a note", details: [
            "if you right click a note in a list, you can navigate notes from there, and make new subfolders."
        ]),
        Feature(title: "Cleaner tag: list (plain text, not green)", details: [
            "I removed colors from tags in the file list to improve readability"
        ])
    ]

    private let bugFixes: [Feature] = [
        Feature(title: "Image embeds no longer count as note links", details: [
            "this is both a security fix and QOL fix."
        ]),
        Feature(title: "Other under the hood improvements.", details: [
            "*closes car hood*"
        ])
    ]

    private func section(_ heading: String, _ items: [Feature]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(.headline)
                .foregroundStyle(EnvyBrand.mark)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.body.bold())
                    ForEach(item.details, id: \.self) { detail in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text(detail)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            EnvyLogoView(size: 56)

            VStack(spacing: 4) {
                Text("What's New in Envy")
                    .font(.title.bold())
                if !versionText.isEmpty {
                    Text("Version \(versionText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("New Features", newFeatures)
                    Divider()
                    section("Bug Fixes", bugFixes)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .background(EnvyBrand.iris.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))

            Button("Continue") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            // This window calls out the current release; anyone who skipped a
            // few versions has no other way to see what changed in between.
            Button("Haven't updated in a while? See what you've missed here!") {
                openURL(URL(string: "https://envynote.app/changelog.html")!)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 440)
    }
}

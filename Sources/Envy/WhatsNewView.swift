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
        Feature(title: "Markdown tables work now!", details: [
            "Right-click → Insert Table. You can also add and delete rows without having to delete a bunch of shit."
        ]),
        Feature(title: "Split editor", details: [
            "Vertical, horizontal, whatever floats your boat, man. Use the View menu or Cmd + \\",
            "You can also swap the split from vertical/horizontal with Opt + Cmd + \\",
            "The split is of course resizable. I would never leave that out."
        ]),
        Feature(title: "Windowless mode", details: [
            "That's right — you can go windowless. It's in the settings. It's super cool."
        ]),
        Feature(title: "Glassify", details: [
            "Why not make everything blurrier? Tim Cook (RIP) would be proud."
        ]),
        Feature(title: "Collapsible note list", details: [
            "Not sure I love this one yet. Trigger it with Ctrl + Cmd + S"
        ]),
        Feature(title: "Unified horizontal layout", details: [
            "I gave in and decided to throw horizontal enjoyers a bone."
        ]),
        Feature(title: "Design polish", details: [
            "I made Claude scrub this thing with a toothbrush."
        ])
    ]

    private let bugFixes = "Too many to count, friend. Hopefully you love it."

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
                VStack(alignment: .leading, spacing: 16) {
                    Text("New Features")
                        .font(.headline)
                        .foregroundStyle(EnvyBrand.mark)

                    ForEach(newFeatures) { feature in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title)
                                .font(.body.bold())
                            ForEach(feature.details, id: \.self) { detail in
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

                    Divider()

                    Text("Bug Fixes")
                        .font(.headline)
                        .foregroundStyle(EnvyBrand.mark)
                    Text(bugFixes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

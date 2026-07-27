import SwiftUI

/// Shown once, automatically, the first time someone launches Envy after
/// updating — not on a brand-new install, which the welcome note already
/// covers. Leads with whichever single feature is worth calling out on its
/// own, rather than a flat list of everything that changed; the rest of the
/// release still gets a line, just a quieter one underneath.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
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

            VStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(EnvyBrand.mark)
                Text("Color Your Folders")
                    .font(.title3.bold())
                Text("Organize by pile, if you like \u{2014} a second axis alongside tags. Turn on \u{201C}Show items in subfolders\u{201D} in Settings, color any folder, and every note inside it shows a dot in that color, so you can see which pile it\u{2019}s in at a glance. Right-click a note \u{203A} Move to \u{2192} to file it into a folder or make a new one on the spot.\n\nTags got color too \u{2014} right-click a tag chip. And this release is faster where it counts: the note list stays snappy past 15,000 notes. Plus \u{2318}\u{2325}N to split a selection into its own note, ==highlight== marking, a stale: search, and clean domain pills for bare links.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Without an explicit width, Text's own frame is only as
                    // wide as its longest wrapped line — multilineTextAlignment
                    // has nothing wider to center within, so it reads as
                    // left-aligned (or clips oddly against the box's padding).
                    // maxWidth: .infinity gives it the full box width to
                    // actually center inside.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(EnvyBrand.iris.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button("Continue") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            // This window only ever calls out the latest version's own
            // highlight — anyone who skipped a few releases has no other way
            // to see what else changed in between.
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

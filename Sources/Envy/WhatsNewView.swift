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
                Image(systemName: "bolt.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(EnvyLogoView.irisColor)
                Text("A Faster Summon")
                    .font(.title3.bold())
                Text("Fixed a delay between summoning Envy and the window actually appearing — a regression from 1.1.2's AeroSpace fixes, which ran several socket round trips before the window could show. That work now happens in the background instead.")
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
            .background(EnvyLogoView.irisColor.opacity(0.1))
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

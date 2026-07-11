import SwiftUI

/// Shown once, automatically, the first time someone launches Envy after
/// updating — not on a brand-new install, which the welcome note already
/// covers. Leads with whichever single feature is worth calling out on its
/// own, rather than a flat list of everything that changed; the rest of the
/// release still gets a line, just a quieter one underneath.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

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
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(EnvyLogoView.irisColor)
                Text("Envy can now update itself")
                    .font(.title3.bold())
                Text("New versions install right from the app — no more downloading a fresh copy from the site. Check anytime from the Envy menu.")
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

            VStack(spacing: 8) {
                whatsNewRow("Backlinks", "See which notes link to the one you're viewing, right in the footer.")
                whatsNewRow("Auto-closing brackets", "[[, **, *, and more close themselves as you type.")
                whatsNewRow("Wiki-link suggestions", "Matching note titles autocomplete inline as you type a [[link.")
            }
            .frame(maxWidth: .infinity)

            Button("Continue") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func whatsNewRow(_ title: String, _ description: String) -> some View {
        var line = AttributedString("\(title) — \(description)")
        if let range = line.range(of: title) {
            line[range].font = .callout.weight(.medium)
        }
        return Text(line)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

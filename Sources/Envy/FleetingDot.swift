import SwiftUI

/// The mark on a fleeting note — one filled dot, in the same amber the due
/// dates use for "soon".
///
/// Amber rather than a new hue on purpose: the palette already says amber
/// means *this wants attention before long*, which is exactly a note waiting
/// to be filed. Red would overstate it (nothing is wrong), green would say
/// it's done, and inventing a sixth colour would mean the app's vocabulary
/// grew for one feature.
///
/// A dot rather than a glyph or a badge because it has to survive at list
/// density without competing with the note's own title — you should notice
/// the row is different without reading anything.
struct FleetingDot: View {
    @Environment(\.interfaceFontScale) private var interfaceFontScale
    var theme: Theme?

    var body: some View {
        Circle()
            .fill(Color(nsColor: theme?.resolvedDueSoonColor ?? .systemYellow))
            .frame(width: 7 * interfaceFontScale, height: 7 * interfaceFontScale)
            .accessibilityLabel("Fleeting note, not yet filed")
    }
}

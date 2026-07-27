import SwiftUI

/// The mark on a fleeting note — an amber exclamation mark, in the same amber
/// the due dates use for "soon".
///
/// Amber rather than a new hue on purpose: the palette already says amber
/// means *this wants attention before long*, which is exactly a note waiting
/// to be filed. Red would overstate it (nothing is wrong), green would say
/// it's done, and inventing a sixth colour would mean the app's vocabulary
/// grew for one feature. An exclamation mark reads as "deal with me" without
/// needing a word, which is the same message.
///
/// A glyph rather than a filled dot because colored-folder dots are filled
/// circles of any hue the user picks — including this amber. Distinguishing by
/// colour alone would collide the moment someone colours a folder amber, so the
/// Inbox differs by *form*: a mark that is plainly not a dot. It still survives
/// at list density without competing with the note's own title — you notice the
/// row differs without reading anything.
struct FleetingDot: View {
    @Environment(\.interfaceFontScale) private var interfaceFontScale
    var theme: Theme?

    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 11 * interfaceFontScale, weight: .black))
            .foregroundStyle(Color(nsColor: theme?.resolvedDueSoonColor ?? .systemYellow))
            .accessibilityLabel("Fleeting note, not yet filed")
    }
}

import Foundation

/// A small, curated set of two-character sequences that expand into a single
/// arrow character the instant the second character is typed — "->" becomes
/// "→", not a ligature-capable font glyph. The saved note just contains the
/// arrow itself, same as emoji shortcodes.
///
/// Deliberately narrow: anything whose meaning is ambiguous outside code
/// (like "<=" — a left-double-arrow to some, "less than or equal" to anyone
/// used to comparisons) or that collides with existing markdown ("--", which
/// a horizontal rule's "---" types straight through) is left out rather than
/// guessed at.
enum TextLigatures {
    static let map: [String: String] = [
        "->": "→",
        "<-": "←",
        "=>": "⇒",
    ]
}

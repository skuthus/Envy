import SwiftUI
import AppKit

struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.deviceRGB) ?? NSColor(red: 0, green: 0, blue: 0, alpha: 1)
        red = Double(converted.redComponent)
        green = Double(converted.greenComponent)
        blue = Double(converted.blueComponent)
        alpha = Double(converted.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var color: Color {
        Color(nsColor: nsColor)
    }
}

/// Every color follows one rule: `nil` means "no override — track the live
/// system default dynamically," and a value means "the user picked this
/// exact color." There is deliberately no other convention. The previous
/// design had three (an `isCustom` flag gating some colors, nil-means-system
/// on others, and a few always-stored), and the seams between them produced
/// two real bugs: a selection color frozen at whatever the system happened
/// to resolve at launch, and System Default themes that stopped tracking
/// Light/Dark switches. A `CodableColor` snapshot of a dynamic system color
/// is always wrong to store — it captures one appearance forever — so the
/// only safe representations are "nothing stored" (resolve the catalog color
/// live at draw time) or "a real user choice" (fixed by definition).
struct Theme: Equatable {
    var fontName: String = "SF Pro Text"
    var fontSize: Double = 13
    var textColor: CodableColor?
    var backgroundColor: CodableColor?
    var markerColor: CodableColor?
    var linkColor: CodableColor?
    var codeBackgroundColor: CodableColor?
    var tagColor: CodableColor?
    var tagBackgroundColor: CodableColor?
    var highlightColor: CodableColor?
    /// The note list's selection highlight.
    var selectionColor: CodableColor?
    /// The editor's own text-selection background (dragging to select text).
    var selectedTextColor: CodableColor?
    var focusHighlightColor: CodableColor?
    var focusHighlightThickness: Double = Theme.defaultFocusHighlightThickness
    /// nil leaves the note list showing the window's own blur/solid backdrop
    /// through, with no fill of its own — not a system color, an absence.
    var fileListBackgroundColor: CodableColor?
    var fileListTextColor: CodableColor?
    var blockquoteColor: CodableColor?
    var completedTaskColor: CodableColor?
    var footnoteColor: CodableColor?
    var checkedCheckboxColor: CodableColor?
    /// nil keeps the note editor's title bar on the system's translucent
    /// .bar material — same absence-not-color convention as the file list.
    var noteTitleBarBackgroundColor: CodableColor?
    var noteTitleBarTextColor: CodableColor?

    // Defaults that involve blending or alpha are wrapped in dynamic
    // resolver closures rather than computed eagerly — calling
    // .blended(withFraction:of:) or .withAlphaComponent(_:) directly on a
    // dynamic color like .textBackgroundColor forces it to resolve to a
    // fixed RGB snapshot immediately, using whatever appearance happens to
    // be "current" at that exact moment, which isn't reliably correct
    // outside an actual AppKit drawing context. A resolver closure is only
    // invoked by AppKit at draw time, with the correct appearance active.
    // (Same fix as ContentView's searchFieldBackground; this bug bit the
    // inline-code background, light-mode search bar, and checkbox colors.)
    private static let defaultCodeBackgroundColor = NSColor(name: nil) { _ in
        NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .clear
    }
    private static let defaultTagBackgroundColor = NSColor(name: nil) { _ in
        NSColor.systemGreen.withAlphaComponent(0.15)
    }
    private static let defaultHighlightColor = NSColor(name: nil) { _ in
        NSColor.systemYellow.withAlphaComponent(0.4)
    }
    private static let defaultAccentTintColor = NSColor(name: nil) { _ in
        NSColor.controlAccentColor.withAlphaComponent(0.25)
    }

    var resolvedFont: NSFont {
        // "SF Pro Text" isn't resolvable through generic family lookup (it has no
        // matching NSFontManager family / PostScript name on its own) — it has to
        // be constructed via the dedicated system-font API.
        let size = CGFloat(fontSize)
        if fontName == "SF Pro Text" {
            return NSFont.systemFont(ofSize: size)
        }
        return NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: size)
            ?? NSFont(name: fontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    var resolvedTextColor: NSColor { textColor?.nsColor ?? .labelColor }
    var resolvedBackgroundColor: NSColor { backgroundColor?.nsColor ?? .textBackgroundColor }
    var resolvedMarkerColor: NSColor { markerColor?.nsColor ?? .tertiaryLabelColor }
    var resolvedLinkColor: NSColor { linkColor?.nsColor ?? .linkColor }
    var resolvedCodeBackgroundColor: NSColor { codeBackgroundColor?.nsColor ?? Self.defaultCodeBackgroundColor }
    var resolvedTagColor: NSColor { tagColor?.nsColor ?? .systemGreen }
    var resolvedTagBackgroundColor: NSColor { tagBackgroundColor?.nsColor ?? Self.defaultTagBackgroundColor }
    var resolvedHighlightColor: NSColor { highlightColor?.nsColor ?? Self.defaultHighlightColor }
    var resolvedSelectionColor: NSColor { selectionColor?.nsColor ?? Self.defaultAccentTintColor }
    var resolvedSelectedTextColor: NSColor { selectedTextColor?.nsColor ?? .selectedTextBackgroundColor }
    var resolvedFocusHighlightColor: NSColor { focusHighlightColor?.nsColor ?? Self.defaultAccentTintColor }
    var resolvedBlockquoteColor: NSColor { blockquoteColor?.nsColor ?? .secondaryLabelColor }
    var resolvedCompletedTaskColor: NSColor { completedTaskColor?.nsColor ?? .secondaryLabelColor }
    var resolvedFootnoteColor: NSColor { footnoteColor?.nsColor ?? .secondaryLabelColor }
    var resolvedCheckedCheckboxColor: NSColor { checkedCheckboxColor?.nsColor ?? .systemGreen }

    static let defaultFocusHighlightThickness: Double = 3
}

extension Theme: RawRepresentable {
    // A type conforming to both Codable and RawRepresentable (String) would recurse:
    // the stdlib's RawRepresentable-based Encodable conformance calls back into
    // `rawValue` to encode `self`. Routing through this plain Codable payload
    // (which isn't itself RawRepresentable) breaks that cycle.
    private struct Payload: Codable {
        // Only ever read, never written anymore — themes saved before the
        // nil-means-system unification carried this flag, and decoding
        // needs it to tell a real color choice apart from a snapshot (see
        // init?(rawValue:) below).
        var isCustom: Bool?
        var fontName: String?
        var fontSize: Double?
        var textColor: CodableColor?
        var backgroundColor: CodableColor?
        var markerColor: CodableColor?
        var linkColor: CodableColor?
        var codeBackgroundColor: CodableColor?
        var highlightColor: CodableColor?
        var selectionColor: CodableColor?
        var focusHighlightColor: CodableColor?
        var focusHighlightThickness: Double?
        var fileListBackgroundColor: CodableColor?
        var fileListTextColor: CodableColor?
        var tagColor: CodableColor?
        var tagBackgroundColor: CodableColor?
        var blockquoteColor: CodableColor?
        var completedTaskColor: CodableColor?
        var footnoteColor: CodableColor?
        var checkedCheckboxColor: CodableColor?
        var noteTitleBarBackgroundColor: CodableColor?
        var noteTitleBarTextColor: CodableColor?
        var selectedTextColor: CodableColor?
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }

        var theme = Theme()

        // Legacy payloads (written when editor colors were gated behind an
        // isCustom flag) always stored *snapshots* of the system colors even
        // when the user never customized anything. isCustom == false means
        // exactly that — those snapshots were never choices, so they map to
        // nil (live system) rather than being adopted as if the user picked
        // them. Anything else (true, or absent on a post-unification save)
        // means the stored colors are real.
        let isLegacySystemDefault = payload.isCustom == false
        if !isLegacySystemDefault {
            theme.fontName = payload.fontName ?? theme.fontName
            theme.fontSize = payload.fontSize ?? theme.fontSize
            theme.textColor = payload.textColor
            theme.backgroundColor = payload.backgroundColor
            theme.markerColor = payload.markerColor
            theme.linkColor = payload.linkColor
            theme.codeBackgroundColor = payload.codeBackgroundColor
            theme.tagColor = payload.tagColor
            theme.tagBackgroundColor = payload.tagBackgroundColor
            theme.blockquoteColor = payload.blockquoteColor
            theme.completedTaskColor = payload.completedTaskColor
            theme.footnoteColor = payload.footnoteColor
            theme.checkedCheckboxColor = payload.checkedCheckboxColor
        }

        // These were never behind the legacy flag — a stored value here was
        // always a real user choice (or a default the old code wrote out
        // eagerly, which renders identically), so adopt them regardless.
        theme.highlightColor = payload.highlightColor
        theme.selectionColor = payload.selectionColor
        theme.selectedTextColor = payload.selectedTextColor
        theme.focusHighlightColor = payload.focusHighlightColor
        theme.focusHighlightThickness = payload.focusHighlightThickness ?? theme.focusHighlightThickness
        theme.fileListBackgroundColor = payload.fileListBackgroundColor
        theme.fileListTextColor = payload.fileListTextColor
        theme.noteTitleBarBackgroundColor = payload.noteTitleBarBackgroundColor
        theme.noteTitleBarTextColor = payload.noteTitleBarTextColor

        self = theme
    }

    var rawValue: String {
        let payload = Payload(
            isCustom: nil,
            fontName: fontName,
            fontSize: fontSize,
            textColor: textColor,
            backgroundColor: backgroundColor,
            markerColor: markerColor,
            linkColor: linkColor,
            codeBackgroundColor: codeBackgroundColor,
            highlightColor: highlightColor,
            selectionColor: selectionColor,
            focusHighlightColor: focusHighlightColor,
            focusHighlightThickness: focusHighlightThickness,
            fileListBackgroundColor: fileListBackgroundColor,
            fileListTextColor: fileListTextColor,
            tagColor: tagColor,
            tagBackgroundColor: tagBackgroundColor,
            blockquoteColor: blockquoteColor,
            completedTaskColor: completedTaskColor,
            footnoteColor: footnoteColor,
            checkedCheckboxColor: checkedCheckboxColor,
            noteTitleBarBackgroundColor: noteTitleBarBackgroundColor,
            noteTitleBarTextColor: noteTitleBarTextColor,
            selectedTextColor: selectedTextColor
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// A theme paired with the name it's saved/known under — Theme itself stays
/// pure "what does this look like," with no notion of its own identity in a
/// gallery, since every existing resolved* property already reads a plain
/// Theme value directly.
struct NamedTheme: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var theme: Theme
}

extension NamedTheme: Codable {
    // Theme itself isn't Codable (see the comment on its RawRepresentable
    // conformance above for why) — it round-trips through its own rawValue
    // string instead, same mechanism @AppStorage already relies on.
    private enum CodingKeys: String, CodingKey {
        case id, name, theme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawTheme = try container.decode(String.self, forKey: .theme)
        theme = Theme(rawValue: rawTheme) ?? Theme()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(theme.rawValue, forKey: .theme)
    }
}

extension Theme {
    /// 0–255 RGB convenience for transcribing published hex palettes
    /// (Dracula, Solarized, etc.) without hand-converting every value to
    /// 0–1 floats.
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, alpha: Double = 1) -> CodableColor {
        CodableColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: alpha)
    }

    /// Built-in, non-editable starter themes — pick one in Settings → Theme
    /// to copy its colors into the live theme, same as applying a saved one.
    static let presets: [NamedTheme] = [
        NamedTheme(name: "Dracula", theme: Theme(
            textColor: rgb(248, 248, 242),
            backgroundColor: rgb(40, 42, 54),
            markerColor: rgb(98, 114, 164),
            linkColor: rgb(139, 233, 253),
            codeBackgroundColor: rgb(68, 71, 90),
            tagColor: rgb(80, 250, 123),
            tagBackgroundColor: rgb(80, 250, 123, alpha: 0.15),
            highlightColor: rgb(241, 250, 140, alpha: 0.4),
            selectionColor: rgb(189, 147, 249, alpha: 0.25),
            focusHighlightColor: rgb(189, 147, 249, alpha: 0.25),
            blockquoteColor: rgb(98, 114, 164),
            completedTaskColor: rgb(98, 114, 164),
            footnoteColor: rgb(98, 114, 164),
            checkedCheckboxColor: rgb(80, 250, 123)
        )),
        NamedTheme(name: "Monokai", theme: Theme(
            textColor: rgb(248, 248, 242),
            backgroundColor: rgb(39, 40, 34),
            markerColor: rgb(117, 113, 94),
            linkColor: rgb(102, 217, 239),
            codeBackgroundColor: rgb(62, 61, 50),
            tagColor: rgb(166, 226, 46),
            tagBackgroundColor: rgb(166, 226, 46, alpha: 0.15),
            highlightColor: rgb(230, 219, 116, alpha: 0.4),
            selectionColor: rgb(174, 129, 255, alpha: 0.25),
            focusHighlightColor: rgb(174, 129, 255, alpha: 0.25),
            blockquoteColor: rgb(117, 113, 94),
            completedTaskColor: rgb(117, 113, 94),
            footnoteColor: rgb(117, 113, 94),
            checkedCheckboxColor: rgb(166, 226, 46)
        )),
        NamedTheme(name: "Tokyo Night", theme: Theme(
            textColor: rgb(192, 202, 245),
            backgroundColor: rgb(26, 27, 38),
            markerColor: rgb(86, 95, 137),
            linkColor: rgb(122, 162, 247),
            codeBackgroundColor: rgb(36, 40, 59),
            tagColor: rgb(158, 206, 106),
            tagBackgroundColor: rgb(158, 206, 106, alpha: 0.15),
            highlightColor: rgb(224, 175, 104, alpha: 0.4),
            selectionColor: rgb(187, 154, 247, alpha: 0.25),
            focusHighlightColor: rgb(187, 154, 247, alpha: 0.25),
            blockquoteColor: rgb(86, 95, 137),
            completedTaskColor: rgb(86, 95, 137),
            footnoteColor: rgb(86, 95, 137),
            checkedCheckboxColor: rgb(158, 206, 106)
        )),
        NamedTheme(name: "Solarized Dark", theme: Theme(
            textColor: rgb(131, 148, 150),
            backgroundColor: rgb(0, 43, 54),
            markerColor: rgb(88, 110, 117),
            linkColor: rgb(38, 139, 210),
            codeBackgroundColor: rgb(7, 54, 66),
            tagColor: rgb(133, 153, 0),
            tagBackgroundColor: rgb(133, 153, 0, alpha: 0.15),
            highlightColor: rgb(181, 137, 0, alpha: 0.4),
            selectionColor: rgb(108, 113, 196, alpha: 0.25),
            focusHighlightColor: rgb(108, 113, 196, alpha: 0.25),
            blockquoteColor: rgb(88, 110, 117),
            completedTaskColor: rgb(88, 110, 117),
            footnoteColor: rgb(88, 110, 117),
            checkedCheckboxColor: rgb(133, 153, 0)
        )),
        NamedTheme(name: "Solarized Light", theme: Theme(
            textColor: rgb(101, 123, 131),
            backgroundColor: rgb(253, 246, 227),
            markerColor: rgb(147, 161, 161),
            linkColor: rgb(38, 139, 210),
            codeBackgroundColor: rgb(238, 232, 213),
            tagColor: rgb(133, 153, 0),
            tagBackgroundColor: rgb(133, 153, 0, alpha: 0.15),
            highlightColor: rgb(181, 137, 0, alpha: 0.4),
            selectionColor: rgb(108, 113, 196, alpha: 0.25),
            focusHighlightColor: rgb(108, 113, 196, alpha: 0.25),
            blockquoteColor: rgb(147, 161, 161),
            completedTaskColor: rgb(147, 161, 161),
            footnoteColor: rgb(147, 161, 161),
            checkedCheckboxColor: rgb(133, 153, 0)
        )),
        // Notational Velocity (2009, Zachary Schneirov) was deliberately
        // unstyled — plain black-on-white text, the system font, no syntax
        // highlighting or colored tags, just the classic Aqua selection
        // blue for the list. These two mirror that: near-monochrome,
        // desaturated accents, nothing bright or decorative. "Dark" is a
        // modern extrapolation — NV predates macOS-wide dark mode — done
        // in the same restrained spirit rather than a real historical mode.
        NamedTheme(name: "Velocity Light", theme: Theme(
            textColor: rgb(26, 26, 26),
            backgroundColor: rgb(255, 255, 255),
            markerColor: rgb(153, 153, 153),
            linkColor: rgb(26, 95, 180),
            codeBackgroundColor: rgb(242, 242, 242),
            tagColor: rgb(90, 90, 90),
            tagBackgroundColor: rgb(210, 210, 210, alpha: 0.4),
            highlightColor: rgb(255, 189, 46, alpha: 0.55),
            selectionColor: rgb(56, 116, 216, alpha: 0.25),
            focusHighlightColor: rgb(150, 150, 150, alpha: 0.25),
            blockquoteColor: rgb(130, 130, 130),
            completedTaskColor: rgb(130, 130, 130),
            footnoteColor: rgb(130, 130, 130),
            checkedCheckboxColor: rgb(90, 140, 90)
        )),
        NamedTheme(name: "Velocity Dark", theme: Theme(
            textColor: rgb(224, 224, 224),
            backgroundColor: rgb(30, 30, 30),
            markerColor: rgb(120, 120, 120),
            linkColor: rgb(90, 160, 250),
            codeBackgroundColor: rgb(42, 42, 42),
            tagColor: rgb(180, 180, 180),
            tagBackgroundColor: rgb(90, 90, 90, alpha: 0.3),
            highlightColor: rgb(255, 189, 46, alpha: 0.55),
            selectionColor: rgb(70, 120, 200, alpha: 0.3),
            focusHighlightColor: rgb(140, 140, 140, alpha: 0.25),
            blockquoteColor: rgb(150, 150, 150),
            completedTaskColor: rgb(150, 150, 150),
            footnoteColor: rgb(150, 150, 150),
            checkedCheckboxColor: rgb(110, 160, 110)
        )),
    ]
}

/// Wrapper so `[NamedTheme]` (the user's saved themes) can round-trip
/// through @AppStorage the same way Theme itself does — @AppStorage only
/// accepts RawRepresentable/primitive types directly, not a bare array of a
/// custom Codable struct.
struct SavedThemesList: RawRepresentable, Equatable {
    var themes: [NamedTheme]

    init(themes: [NamedTheme] = []) {
        self.themes = themes
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([NamedTheme].self, from: data) else { return nil }
        themes = decoded
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(themes),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
}

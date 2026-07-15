import AppKit
import SwiftUI

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

struct Theme: Equatable {
    var isCustom: Bool = false
    var fontName: String = "SF Pro Text"
    var fontSize: Double = 13
    var textColor: CodableColor = CodableColor(nsColor: .labelColor)
    var backgroundColor: CodableColor = CodableColor(nsColor: .textBackgroundColor)
    var markerColor: CodableColor = CodableColor(nsColor: .tertiaryLabelColor)
    var linkColor: CodableColor = CodableColor(nsColor: .linkColor)
    var codeBackgroundColor: CodableColor = CodableColor(
        nsColor: NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .clear
    )
    var tagColor: CodableColor = CodableColor(nsColor: .systemGreen)
    var tagBackgroundColor: CodableColor = CodableColor(nsColor: NSColor.systemGreen.withAlphaComponent(0.15))
    var highlightColor: CodableColor = CodableColor(nsColor: NSColor.systemYellow.withAlphaComponent(0.4))
    var selectionColor: CodableColor = CodableColor(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.25))
    // nil means "no color" — the editor's own text-selection background
    // (dragging to select text) tracks the system's live selection color,
    // same as before this setting existed. Deliberately NOT a baked-in
    // CodableColor(nsColor: .selectedTextBackgroundColor) default: that
    // dynamic catalog color only resolves correctly inside a real AppKit
    // drawing context, and converting it eagerly here — at whatever moment
    // Theme()'s default value happens to first get evaluated — freezes it
    // to whatever that snapshot resolved to for the rest of the session,
    // which broke selection highlighting entirely. Same bug class as the
    // light-mode search bar / inline-code background fixes elsewhere.
    var selectedTextColor: CodableColor?
    var focusHighlightColor: CodableColor = Theme.defaultFocusHighlightColor
    var focusHighlightThickness: Double = Theme.defaultFocusHighlightThickness
    // nil means "no color" — the note list shows the window's own blur/solid
    // backdrop through, same as before this setting existed. Set, it's an
    // opaque fill that applies regardless of the blur strength setting.
    var fileListBackgroundColor: CodableColor?
    // nil means "no color" — the note title uses the system's normal
    // primary text color, same as before this setting existed.
    var fileListTextColor: CodableColor?
    var blockquoteColor: CodableColor = CodableColor(nsColor: .secondaryLabelColor)
    var completedTaskColor: CodableColor = CodableColor(nsColor: .secondaryLabelColor)
    var footnoteColor: CodableColor = CodableColor(nsColor: .secondaryLabelColor)
    var checkedCheckboxColor: CodableColor = CodableColor(nsColor: .systemGreen)
    // nil means "no color" — the note editor's title bar uses the system's
    // own translucent .bar material, same as before this setting existed.
    var noteTitleBarBackgroundColor: CodableColor?
    // nil means "no color" — the note title uses the system's normal
    // primary text color, same as before this setting existed.
    var noteTitleBarTextColor: CodableColor?

    var resolvedFont: NSFont {
        let name = isCustom ? fontName : "SF Pro Text"
        let size = isCustom ? CGFloat(fontSize) : 13

        // "SF Pro Text" isn't resolvable through generic family lookup (it has no
        // matching NSFontManager family / PostScript name on its own) — it has to
        // be constructed via the dedicated system-font API.
        if name == "SF Pro Text" {
            return NSFont.systemFont(ofSize: size)
        }
        return NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
            ?? NSFont(name: name, size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    var resolvedTextColor: NSColor { isCustom ? textColor.nsColor : .labelColor }
    var resolvedBackgroundColor: NSColor { isCustom ? backgroundColor.nsColor : .textBackgroundColor }
    var resolvedMarkerColor: NSColor { isCustom ? markerColor.nsColor : .tertiaryLabelColor }
    var resolvedLinkColor: NSColor { isCustom ? linkColor.nsColor : .linkColor }
    // The non-custom branch is wrapped in a dynamic resolver rather than
    // blending eagerly — calling .blended(withFraction:of:) directly on a
    // dynamic color like .textBackgroundColor forces it to resolve to a
    // fixed RGB snapshot immediately, using whatever appearance happens to
    // be "current" at that exact moment, which isn't reliably correct for
    // a plain computed property evaluated outside an actual AppKit drawing
    // context. This is what colors backtick-wrapped inline code — it was
    // staying dark even in Light mode. A resolver closure is only invoked
    // by AppKit at actual draw time, with the correct appearance already
    // active, so resolving and blending inside it is what actually tracks
    // appearance correctly. Same fix as ContentView's searchFieldBackground.
    private static let defaultCodeBackgroundColor = NSColor(name: nil) { _ in
        NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .clear
    }
    var resolvedCodeBackgroundColor: NSColor {
        isCustom ? codeBackgroundColor.nsColor : Self.defaultCodeBackgroundColor
    }
    var resolvedTagColor: NSColor { isCustom ? tagColor.nsColor : .systemGreen }
    var resolvedTagBackgroundColor: NSColor {
        isCustom ? tagBackgroundColor.nsColor : NSColor.systemGreen.withAlphaComponent(0.15)
    }
    // Not gated by isCustom — search highlighting is independent of the theme toggle.
    var resolvedHighlightColor: NSColor { highlightColor.nsColor }
    // Also independent of isCustom — the note list's selection highlight is
    // its own thing, not part of the editor's custom-theme colors.
    var resolvedSelectionColor: NSColor { selectionColor.nsColor }
    // Also independent of isCustom — same reasoning as selectionColor above.
    var resolvedFocusHighlightColor: NSColor { focusHighlightColor.nsColor }
    // Also independent of isCustom — same reasoning as selectionColor above.
    var resolvedSelectedTextColor: NSColor { selectedTextColor?.nsColor ?? .selectedTextBackgroundColor }
    var resolvedBlockquoteColor: NSColor { isCustom ? blockquoteColor.nsColor : .secondaryLabelColor }
    var resolvedCompletedTaskColor: NSColor { isCustom ? completedTaskColor.nsColor : .secondaryLabelColor }
    var resolvedFootnoteColor: NSColor { isCustom ? footnoteColor.nsColor : .secondaryLabelColor }
    var resolvedCheckedCheckboxColor: NSColor { isCustom ? checkedCheckboxColor.nsColor : .systemGreen }

    static let defaultSelectionColor = CodableColor(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.25))
    static let defaultFocusHighlightColor = CodableColor(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.25))
    static let defaultFocusHighlightThickness: Double = 3
}

extension Theme: RawRepresentable {
    // A type conforming to both Codable and RawRepresentable (String) would recurse:
    // the stdlib's RawRepresentable-based Encodable conformance calls back into
    // `rawValue` to encode `self`. Routing through this plain Codable payload
    // (which isn't itself RawRepresentable) breaks that cycle.
    private struct Payload: Codable {
        var isCustom: Bool
        var fontName: String
        var fontSize: Double
        var textColor: CodableColor
        var backgroundColor: CodableColor
        var markerColor: CodableColor
        var linkColor: CodableColor
        var codeBackgroundColor: CodableColor
        // Optional so JSON saved before this field existed still decodes.
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
        // Each ?? fallback broken out into its own local rather than inline
        // in the self.init(...) call below — with this many defaulted
        // parameters, the type-checker times out trying to solve it all as
        // one expression.
        let highlightColor: CodableColor = payload.highlightColor ?? CodableColor(nsColor: NSColor.systemYellow.withAlphaComponent(0.4))
        let selectionColor: CodableColor = payload.selectionColor ?? Theme.defaultSelectionColor
        let focusHighlightColor: CodableColor = payload.focusHighlightColor ?? Theme.defaultFocusHighlightColor
        let focusHighlightThickness: Double = payload.focusHighlightThickness ?? Theme.defaultFocusHighlightThickness
        let tagColor: CodableColor = payload.tagColor ?? CodableColor(nsColor: .systemGreen)
        let tagBackgroundColor: CodableColor = payload.tagBackgroundColor ?? CodableColor(nsColor: NSColor.systemGreen.withAlphaComponent(0.15))
        let blockquoteColor: CodableColor = payload.blockquoteColor ?? CodableColor(nsColor: .secondaryLabelColor)
        let completedTaskColor: CodableColor = payload.completedTaskColor ?? CodableColor(nsColor: .secondaryLabelColor)
        let footnoteColor: CodableColor = payload.footnoteColor ?? CodableColor(nsColor: .secondaryLabelColor)
        let checkedCheckboxColor: CodableColor = payload.checkedCheckboxColor ?? CodableColor(nsColor: .systemGreen)
        self.init(
            isCustom: payload.isCustom,
            fontName: payload.fontName,
            fontSize: payload.fontSize,
            textColor: payload.textColor,
            backgroundColor: payload.backgroundColor,
            markerColor: payload.markerColor,
            linkColor: payload.linkColor,
            codeBackgroundColor: payload.codeBackgroundColor,
            tagColor: tagColor,
            tagBackgroundColor: tagBackgroundColor,
            highlightColor: highlightColor,
            selectionColor: selectionColor,
            selectedTextColor: payload.selectedTextColor,
            focusHighlightColor: focusHighlightColor,
            focusHighlightThickness: focusHighlightThickness,
            fileListBackgroundColor: payload.fileListBackgroundColor,
            fileListTextColor: payload.fileListTextColor,
            blockquoteColor: blockquoteColor,
            completedTaskColor: completedTaskColor,
            footnoteColor: footnoteColor,
            checkedCheckboxColor: checkedCheckboxColor,
            noteTitleBarBackgroundColor: payload.noteTitleBarBackgroundColor,
            noteTitleBarTextColor: payload.noteTitleBarTextColor
        )
    }

    var rawValue: String {
        let payload = Payload(
            isCustom: isCustom,
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
            isCustom: true,
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
            isCustom: true,
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
            isCustom: true,
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
            isCustom: true,
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
            isCustom: true,
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
            isCustom: true,
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
            isCustom: true,
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

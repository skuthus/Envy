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
    /// Not-yet-due, due-soon (this calendar week), and overdue are three
    /// separate tokens rather than one color with urgency logic layered on
    /// top — same pattern as completedTaskColor being its own dedicated
    /// slot instead of a derived tint of textColor. A user's custom color
    /// choice for each state is always respected exactly; urgency only
    /// decides *which* slot applies, never overrides what's in it.
    var dueColor: CodableColor?
    var dueSoonColor: CodableColor?
    var dueOverdueColor: CodableColor?
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
    var resolvedDueColor: NSColor { dueColor?.nsColor ?? .systemOrange }
    var resolvedDueSoonColor: NSColor { dueSoonColor?.nsColor ?? .systemYellow }
    var resolvedDueOverdueColor: NSColor { dueOverdueColor?.nsColor ?? .systemRed }
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
        var dueColor: CodableColor?
        var dueSoonColor: CodableColor?
        var dueOverdueColor: CodableColor?
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
            theme.dueColor = payload.dueColor
            theme.dueSoonColor = payload.dueSoonColor
            theme.dueOverdueColor = payload.dueOverdueColor
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
            dueColor: dueColor,
            dueSoonColor: dueSoonColor,
            dueOverdueColor: dueOverdueColor,
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
    /// Non-nil makes this an *adaptive* theme: `theme` is its light face and
    /// this is its dark one, and which applies follows the current
    /// appearance. nil is the ordinary case — one fixed set of colors that
    /// looks the same whatever the system is doing.
    var darkTheme: Theme?
}

extension NamedTheme: Codable {
    // Theme itself isn't Codable (see the comment on its RawRepresentable
    // conformance above for why) — it round-trips through its own rawValue
    // string instead, same mechanism @AppStorage already relies on.
    private enum CodingKeys: String, CodingKey {
        case id, name, theme, darkTheme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawTheme = try container.decode(String.self, forKey: .theme)
        theme = Theme(rawValue: rawTheme) ?? Theme()
        // Absent in every theme exported before adaptive pairs existed, so
        // decoding must tolerate it rather than fail the whole import.
        darkTheme = (try container.decodeIfPresent(String.self, forKey: .darkTheme))
            .flatMap(Theme.init(rawValue:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(theme.rawValue, forKey: .theme)
        try container.encodeIfPresent(darkTheme?.rawValue, forKey: .darkTheme)
    }
}

/// The two faces of an adaptive theme, stored as one value so the choice
/// survives a relaunch. Deliberately *not* a property of Theme: a struct
/// can't contain itself, and more importantly every consumer already reads
/// a plain resolved Theme — pairing is a question of which Theme is live,
/// not of what a Theme is.
struct ThemePair: Equatable {
    var light: Theme
    var dark: Theme

    func face(dark isDark: Bool) -> Theme { isDark ? dark : light }
}

extension ThemePair: RawRepresentable {
    private struct Payload: Codable { var light: String; var dark: String }

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let light = Theme(rawValue: payload.light),
              let dark = Theme(rawValue: payload.dark) else { return nil }
        self.init(light: light, dark: dark)
    }

    var rawValue: String {
        let payload = Payload(light: light.rawValue, dark: dark.rawValue)
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
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
        // Adaptive: light and dark faces of one theme, resolved from the
        // current appearance rather than fixed when you pick it. This is what
        // a new install should land on — the house look that still follows
        // the system, instead of a dark app on a light Mac.
        NamedTheme(name: "Envious", theme: enviousLight, darkTheme: enviousDark),
        NamedTheme(name: "Dracula", theme: Theme(
            textColor: rgb(248, 248, 242),
            backgroundColor: rgb(40, 42, 54),
            markerColor: rgb(98, 114, 164),
            linkColor: rgb(139, 233, 253),
            dueColor: rgb(255, 184, 108),
            dueSoonColor: rgb(241, 250, 140),
            dueOverdueColor: rgb(255, 85, 85),
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
            dueColor: rgb(253, 151, 31),
            dueSoonColor: rgb(230, 219, 116),
            dueOverdueColor: rgb(249, 38, 114),
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
            dueColor: rgb(255, 158, 100),
            dueSoonColor: rgb(224, 175, 104),
            dueOverdueColor: rgb(247, 118, 142),
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
            dueColor: rgb(203, 75, 22),
            dueSoonColor: rgb(181, 137, 0),
            dueOverdueColor: rgb(220, 50, 47),
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
            dueColor: rgb(203, 75, 22),
            dueSoonColor: rgb(181, 137, 0),
            dueOverdueColor: rgb(220, 50, 47),
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
            dueColor: rgb(180, 110, 40),
            dueSoonColor: rgb(170, 140, 40),
            dueOverdueColor: rgb(180, 60, 50),
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
            dueColor: rgb(210, 150, 90),
            dueSoonColor: rgb(210, 190, 100),
            dueOverdueColor: rgb(210, 100, 90),
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

extension Theme {
    /// The house palette, decoded from Skyler's own "Envious" export. Held as
    /// named values because they're each referenced twice — once as a fixed
    /// gallery entry, once as a face of the adaptive "Envious" pair — and two
    /// transcriptions of the same palette would eventually disagree.
    ///
    /// Roles, consistent across both faces:
    ///
    ///   blue    wiki-links, and the note list's selected row
    ///   red     the editor's text selection, and overdue
    ///   green   tags and ticked checkboxes
    ///   amber   due-soon, and search matches
    ///
    /// The dark greys are white at graded alpha (0.85 body, 0.55 secondary,
    /// 0.25 markers) rather than fixed RGB. Opaque greys are only correct at
    /// one blur strength; alpha keeps the hierarchy over whatever the window
    /// is actually letting through.
    ///
    /// Note: window translucency is a separate setting, not part of a theme —
    /// set Blur Strength to None for a fully flat look.
    static let enviousDark = Theme(
        textColor: rgb(255, 255, 255, alpha: 0.847),
        backgroundColor: rgb(29, 30, 31),
        markerColor: rgb(255, 255, 255, alpha: 0.247),
        linkColor: rgb(90, 128, 255),
        dueColor: rgb(255, 255, 255),            // not yet urgent — full-strength neutral
        dueSoonColor: rgb(255, 188, 0),
        dueOverdueColor: rgb(255, 75, 57),
        codeBackgroundColor: rgb(55, 55, 55),
        tagColor: rgb(52, 199, 89),
        tagBackgroundColor: rgb(48, 209, 88, alpha: 0.153),
        highlightColor: rgb(255, 188, 0),
        selectionColor: rgb(90, 128, 255),       // note list row
        selectedTextColor: rgb(255, 75, 57),     // editor text selection
        focusHighlightColor: rgb(152, 168, 217, alpha: 0.25),
        focusHighlightThickness: 3,
        fileListBackgroundColor: rgb(29, 30, 31),
        blockquoteColor: rgb(255, 255, 255, alpha: 0.549),
        completedTaskColor: rgb(255, 255, 255, alpha: 0.549),
        footnoteColor: rgb(255, 255, 255, alpha: 0.549),
        checkedCheckboxColor: rgb(52, 199, 89),
        noteTitleBarBackgroundColor: rgb(38, 38, 38)
    )

    /// Same roles, different hues. Every accent above was mixed for a
    /// near-black ground and three fail on paper — the blue and green lose
    /// contrast, the amber vanishes — so each is darkened until it clears.
    ///
    /// The two selections are the real departure. In dark they're opaque and
    /// the light body text reads against them; on paper, dark text on solid
    /// blue or red is unreadable, so both become tints. Same colour, same
    /// meaning, different weight.
    static let enviousLight = Theme(
        textColor: rgb(0, 0, 0, alpha: 0.85),
        backgroundColor: rgb(250, 250, 248),
        markerColor: rgb(0, 0, 0, alpha: 0.30),  // 0.247 disappears on paper
        linkColor: rgb(27, 79, 216),
        dueColor: rgb(0, 0, 0, alpha: 0.85),
        dueSoonColor: rgb(176, 124, 0),          // amber is illegible on paper at full brightness
        dueOverdueColor: rgb(212, 42, 28),
        codeBackgroundColor: rgb(240, 239, 234),
        tagColor: rgb(23, 132, 58),
        tagBackgroundColor: rgb(23, 132, 58, alpha: 0.13),
        highlightColor: rgb(255, 188, 0, alpha: 0.55),
        selectionColor: rgb(27, 79, 216, alpha: 0.18),
        selectedTextColor: rgb(212, 42, 28, alpha: 0.22),
        focusHighlightColor: rgb(96, 122, 176, alpha: 0.30),
        focusHighlightThickness: 3,
        fileListBackgroundColor: rgb(250, 250, 248),
        blockquoteColor: rgb(0, 0, 0, alpha: 0.55),
        completedTaskColor: rgb(0, 0, 0, alpha: 0.55),
        footnoteColor: rgb(0, 0, 0, alpha: 0.55),
        checkedCheckboxColor: rgb(23, 132, 58),
        noteTitleBarBackgroundColor: rgb(240, 239, 234)
    )
}

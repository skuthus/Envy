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
    var highlightColor: CodableColor = CodableColor(nsColor: NSColor.systemYellow.withAlphaComponent(0.4))
    var selectionColor: CodableColor = CodableColor(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.25))
    var focusHighlightColor: CodableColor = Theme.defaultFocusHighlightColor
    var focusHighlightThickness: Double = Theme.defaultFocusHighlightThickness
    // nil means "no color" — the note list shows the window's own blur/solid
    // backdrop through, same as before this setting existed. Set, it's an
    // opaque fill that applies regardless of the blur strength setting.
    var fileListBackgroundColor: CodableColor?
    // nil means "no color" — the note title uses the system's normal
    // primary text color, same as before this setting existed.
    var fileListTextColor: CodableColor?

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
    var resolvedCodeBackgroundColor: NSColor {
        isCustom ? codeBackgroundColor.nsColor : (NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .clear)
    }
    // Not gated by isCustom — search highlighting is independent of the theme toggle.
    var resolvedHighlightColor: NSColor { highlightColor.nsColor }
    // Also independent of isCustom — the note list's selection highlight is
    // its own thing, not part of the editor's custom-theme colors.
    var resolvedSelectionColor: NSColor { selectionColor.nsColor }
    // Also independent of isCustom — same reasoning as selectionColor above.
    var resolvedFocusHighlightColor: NSColor { focusHighlightColor.nsColor }

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
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        self.init(
            isCustom: payload.isCustom,
            fontName: payload.fontName,
            fontSize: payload.fontSize,
            textColor: payload.textColor,
            backgroundColor: payload.backgroundColor,
            markerColor: payload.markerColor,
            linkColor: payload.linkColor,
            codeBackgroundColor: payload.codeBackgroundColor,
            highlightColor: payload.highlightColor ?? CodableColor(nsColor: NSColor.systemYellow.withAlphaComponent(0.4)),
            selectionColor: payload.selectionColor ?? Theme.defaultSelectionColor,
            focusHighlightColor: payload.focusHighlightColor ?? Theme.defaultFocusHighlightColor,
            focusHighlightThickness: payload.focusHighlightThickness ?? Theme.defaultFocusHighlightThickness,
            fileListBackgroundColor: payload.fileListBackgroundColor,
            fileListTextColor: payload.fileListTextColor
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
            fileListTextColor: fileListTextColor
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

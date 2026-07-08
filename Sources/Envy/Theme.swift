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
            highlightColor: payload.highlightColor ?? CodableColor(nsColor: NSColor.systemYellow.withAlphaComponent(0.4))
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
            highlightColor: highlightColor
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

import AppKit

@MainActor
enum MarkdownStyler {
    private static let wikiLinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let headerRegex = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.*)$"#, options: [.anchorsMatchLines])

    static func wikiLinkFullRanges(in text: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return wikiLinkRegex.matches(in: text, range: full).map(\.range)
    }

    static func style(
        textStorage: NSTextStorage,
        text: String,
        theme: Theme,
        revealedLinkRange: NSRange? = nil,
        searchQuery: String = ""
    ) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let baseFont = theme.resolvedFont
        let markerColor = theme.resolvedMarkerColor
        let linkColor = theme.resolvedLinkColor
        let codeBackground = theme.resolvedCodeBackgroundColor
        let monospaceCharWidth = NSAttributedString(string: "[", attributes: [.font: baseFont]).size().width

        textStorage.beginEditing()
        textStorage.setAttributes([.font: baseFont, .foregroundColor: theme.resolvedTextColor], range: full)

        for match in headerRegex.matches(in: text, range: full) {
            let hashRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            let size = max(baseFont.pointSize, baseFont.pointSize + 9 - CGFloat(hashRange.length - 1) * 2)
            let font = NSFontManager.shared.convert(baseFont, toSize: size)
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            textStorage.addAttribute(.font, value: boldFont, range: contentRange)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: hashRange)
        }

        for match in boldRegex.matches(in: text, range: full) {
            applyEmphasis(match: match, textStorage: textStorage, baseFont: baseFont, markerColor: markerColor, bold: true, italic: false)
        }

        for match in italicRegex.matches(in: text, range: full) {
            applyEmphasis(match: match, textStorage: textStorage, baseFont: baseFont, markerColor: markerColor, bold: false, italic: true)
        }

        for match in codeRegex.matches(in: text, range: full) {
            let markerA = NSRange(location: match.range.location, length: 1)
            let markerB = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerA)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerB)
            textStorage.addAttribute(.backgroundColor, value: codeBackground, range: match.range(at: 1))
        }

        for match in wikiLinkRegex.matches(in: text, range: full) {
            let bracketOpen = NSRange(location: match.range.location, length: 2)
            let bracketClose = NSRange(location: match.range.location + match.range.length - 2, length: 2)
            let titleRange = match.range(at: 1)
            let title = (text as NSString).substring(with: titleRange)
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title

            if match.range == revealedLinkRange {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketOpen)
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketClose)
            } else {
                collapse(range: bracketOpen, in: textStorage, kern: -monospaceCharWidth)
                collapse(range: bracketClose, in: textStorage, kern: -monospaceCharWidth)
            }
            textStorage.addAttribute(.foregroundColor, value: linkColor, range: titleRange)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: titleRange)
            if let url = URL(string: "velocity:///\(encoded)") {
                textStorage.addAttribute(.link, value: url, range: titleRange)
            }
        }

        highlightMatches(of: searchQuery, in: text, textStorage: textStorage, color: theme.resolvedHighlightColor)

        textStorage.endEditing()
    }

    private static func highlightMatches(of query: String, in text: String, textStorage: NSTextStorage, color: NSColor) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nsText = text as NSString
        guard nsText.length > 0 else { return }

        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        guard let regex = try? NSRegularExpression(pattern: escaped, options: [.caseInsensitive]) else { return }
        let fullRange = NSRange(location: 0, length: nsText.length)
        for match in regex.matches(in: text, range: fullRange) {
            textStorage.addAttribute(.backgroundColor, value: color, range: match.range)
        }
    }

    /// Makes a fixed-width run of characters visually disappear: transparent ink plus
    /// negative kerning equal to the glyph advance, so the following text slides left
    /// to fill the gap. The characters are still present in the string (cursor/selection/
    /// backspace still step through them one at a time), only their drawn footprint is gone.
    private static func collapse(range: NSRange, in textStorage: NSTextStorage, kern: CGFloat) {
        textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        textStorage.addAttribute(.kern, value: kern, range: range)
    }

    private static func applyEmphasis(
        match: NSTextCheckingResult,
        textStorage: NSTextStorage,
        baseFont: NSFont,
        markerColor: NSColor,
        bold: Bool,
        italic: Bool
    ) {
        let contentRange = match.range(at: 1)
        let leadingMarker = NSRange(location: match.range.location, length: contentRange.location - match.range.location)
        let trailingMarker = NSRange(
            location: contentRange.location + contentRange.length,
            length: match.range.location + match.range.length - (contentRange.location + contentRange.length)
        )
        textStorage.addAttribute(.foregroundColor, value: markerColor, range: leadingMarker)
        textStorage.addAttribute(.foregroundColor, value: markerColor, range: trailingMarker)

        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        let font = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
        textStorage.addAttribute(.font, value: font, range: contentRange)
    }
}

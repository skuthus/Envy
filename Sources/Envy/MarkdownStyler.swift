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
        searchQuery: String = "",
        cursorSelection: NSRange? = nil
    ) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let baseFont = theme.resolvedFont
        let markerColor = theme.resolvedMarkerColor
        let linkColor = theme.resolvedLinkColor
        let codeBackground = theme.resolvedCodeBackgroundColor

        textStorage.beginEditing()
        textStorage.setAttributes([.font: baseFont, .foregroundColor: theme.resolvedTextColor], range: full)

        for match in headerRegex.matches(in: text, range: full) {
            let hashRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            let size = max(baseFont.pointSize, baseFont.pointSize + 9 - CGFloat(hashRange.length - 1) * 2)
            let font = NSFontManager.shared.convert(baseFont, toSize: size)
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            textStorage.addAttribute(.font, value: boldFont, range: contentRange)

            let markerRange = NSRange(location: match.range.location, length: contentRange.location - match.range.location)
            if touches(match.range, cursorSelection) {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: hashRange)
            } else {
                collapse(range: markerRange, in: textStorage, text: text, font: baseFont)
            }
        }

        for match in boldRegex.matches(in: text, range: full) {
            applyEmphasis(match: match, textStorage: textStorage, text: text, baseFont: baseFont, markerColor: markerColor, bold: true, italic: false, revealed: touches(match.range, cursorSelection))
        }

        for match in italicRegex.matches(in: text, range: full) {
            applyEmphasis(match: match, textStorage: textStorage, text: text, baseFont: baseFont, markerColor: markerColor, bold: false, italic: true, revealed: touches(match.range, cursorSelection))
        }

        for match in codeRegex.matches(in: text, range: full) {
            let markerA = NSRange(location: match.range.location, length: 1)
            let markerB = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            textStorage.addAttribute(.backgroundColor, value: codeBackground, range: match.range(at: 1))
            if touches(match.range, cursorSelection) {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerA)
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerB)
            } else {
                collapse(range: markerA, in: textStorage, text: text, font: baseFont)
                collapse(range: markerB, in: textStorage, text: text, font: baseFont)
            }
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
                collapse(range: bracketOpen, in: textStorage, text: text, font: baseFont)
                collapse(range: bracketClose, in: textStorage, text: text, font: baseFont)
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

    /// Whether the cursor (or selection) currently sits inside, or right at the
    /// edge of, `range` — used to decide whether to reveal a span's raw markup
    /// characters or keep them collapsed into their "smart view" appearance.
    private static func touches(_ range: NSRange, _ selection: NSRange?) -> Bool {
        guard let selection else { return false }
        let rangeEnd = range.location + range.length
        let selectionStart = selection.location
        let selectionEnd = selection.location + selection.length
        if selectionStart >= range.location && selectionStart <= rangeEnd { return true }
        if selectionEnd >= range.location && selectionEnd <= rangeEnd { return true }
        return selectionStart <= range.location && selectionEnd >= rangeEnd
    }

    /// Makes a run of characters visually disappear: transparent ink plus negative
    /// kerning equal to each character's own individually measured advance, so
    /// the following text slides left to fill the gap exactly. The characters
    /// are still present in the string (cursor/selection/backspace still step
    /// through them one at a time), only their drawn footprint is gone.
    ///
    /// Each character in the run is measured and cancelled on its own — earlier
    /// versions measured the whole run as one substring and cancelled it via a
    /// single kern on the last character, but multi-character measurement
    /// doesn't equal the sum of each character's own advance (extra bounding-box
    /// padding on the combined measurement), leaving a residual gap that grew
    /// with the run's length — e.g. worse for "## " than "# ".
    private static func collapse(range: NSRange, in textStorage: NSTextStorage, text: String, font: NSFont) {
        guard range.length > 0 else { return }
        let nsText = text as NSString
        textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        for offset in 0..<range.length {
            let charRange = NSRange(location: range.location + offset, length: 1)
            let char = nsText.substring(with: charRange)
            let width = NSAttributedString(string: char, attributes: [.font: font]).size().width
            textStorage.addAttribute(.kern, value: -width, range: charRange)
        }
    }

    private static func applyEmphasis(
        match: NSTextCheckingResult,
        textStorage: NSTextStorage,
        text: String,
        baseFont: NSFont,
        markerColor: NSColor,
        bold: Bool,
        italic: Bool,
        revealed: Bool
    ) {
        let contentRange = match.range(at: 1)
        let leadingMarker = NSRange(location: match.range.location, length: contentRange.location - match.range.location)
        let trailingMarker = NSRange(
            location: contentRange.location + contentRange.length,
            length: match.range.location + match.range.length - (contentRange.location + contentRange.length)
        )
        if revealed {
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: leadingMarker)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: trailingMarker)
        } else {
            collapse(range: leadingMarker, in: textStorage, text: text, font: baseFont)
            collapse(range: trailingMarker, in: textStorage, text: text, font: baseFont)
        }

        // NSFontDescriptor.withSymbolicTraits + NSFont(descriptor:size:) doesn't
        // reliably resolve a bold/italic variant for NSFont.systemFont (the
        // default theme's font) — same family of issue as "SF Pro Text" not
        // resolving via generic family lookup elsewhere in this file.
        // NSFontManager's convert(_:toHaveTrait:), already used for headers,
        // is the reliable path.
        var font = baseFont
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        textStorage.addAttribute(.font, value: font, range: contentRange)
    }
}

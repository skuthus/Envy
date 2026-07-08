import AppKit
import CoreText

@MainActor
enum MarkdownStyler {
    private static let wikiLinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)
    private static let boldItalicRegex = try! NSRegularExpression(pattern: #"\*\*\*([^*\n]+)\*\*\*"#)
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let fencedCodeBlockRegex = try! NSRegularExpression(pattern: #"^```[^\n]*\n([\s\S]*?)\n```[ \t]*$"#, options: [.anchorsMatchLines])
    private static let headerRegex = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.*)$"#, options: [.anchorsMatchLines])
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"^(>[ \t]?)(.*)$"#, options: [.anchorsMatchLines])
    private static let horizontalRuleRegex = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])[ \t]*(?:\1[ \t]*){2,}$"#, options: [.anchorsMatchLines])
    private static let taskListRegex = try! NSRegularExpression(pattern: #"^(\s*[-*+][ \t]+)(\[[ xX]\])([ \t]+.*)$"#, options: [.anchorsMatchLines])
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])([ \t]+.*)$"#, options: [.anchorsMatchLines])
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+[.)])([ \t]+.*)$"#, options: [.anchorsMatchLines])
    // The (?<!!) exclusion still applies even without dedicated image
    // handling — leaves "![alt](url)" alone rather than styling just the
    // "[alt](url)" portion as a link with a stray "!" in front.
    private static let linkRegex = try! NSRegularExpression(pattern: #"(?<!!)\[([^\[\]]+)\]\(([^()\s]+)\)"#)
    private static let autolinkBracketRegex = try! NSRegularExpression(pattern: #"<(https?://[^\s>]+)>"#)
    private static let bareURLRegex = try! NSRegularExpression(pattern: #"(?<![(<])\bhttps?://[^\s<>()]+\b"#)

    static func wikiLinkFullRanges(in text: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return wikiLinkRegex.matches(in: text, range: full).map(\.range)
    }

    /// Each task-list checkbox's "[x]"/"[ ]" range, split into the glyph
    /// range (just "[", where the ☐/☑ substitution actually renders — used
    /// to compute an on-screen hit rect for clicking) and the toggle range
    /// (the inner character, replaced with "x"/" " to flip checked state).
    static func taskCheckboxRanges(in text: String) -> [(glyphRange: NSRange, toggleRange: NSRange, isChecked: Bool)] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return taskListRegex.matches(in: text, range: full).map { match in
            let checkboxRange = match.range(at: 2)
            let glyphRange = NSRange(location: checkboxRange.location, length: 1)
            let toggleRange = NSRange(location: checkboxRange.location + 1, length: 1)
            let checkboxText = (text as NSString).substring(with: checkboxRange)
            return (glyphRange, toggleRange, checkboxText.lowercased() == "[x]")
        }
    }

    enum ListContinuation {
        /// Insert "\n" + this marker text at the cursor to continue the list.
        case `continue`(marker: String)
        /// The current line is an empty list item — clear its marker instead
        /// of continuing the list, so pressing Return exits it.
        case exit
    }

    /// What pressing Return should do given the text of the line the cursor
    /// is currently on, if that line is a list item — bullet, numbered, or
    /// task. Returns nil if the line isn't a list item at all.
    static func listContinuation(forLine line: String) -> ListContinuation? {
        let nsLine = line as NSString
        let full = NSRange(location: 0, length: nsLine.length)

        func isEmpty(_ range: NSRange) -> Bool {
            nsLine.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
        }

        if let match = taskListRegex.firstMatch(in: line, range: full) {
            guard !isEmpty(match.range(at: 3)) else { return .exit }
            let markerPrefix = nsLine.substring(with: match.range(at: 1))
            return .continue(marker: "\(markerPrefix)[ ] ")
        }
        if let match = unorderedListRegex.firstMatch(in: line, range: full) {
            guard !isEmpty(match.range(at: 3)) else { return .exit }
            let indent = nsLine.substring(with: match.range(at: 1))
            let marker = nsLine.substring(with: match.range(at: 2))
            return .continue(marker: "\(indent)\(marker) ")
        }
        if let match = orderedListRegex.firstMatch(in: line, range: full) {
            guard !isEmpty(match.range(at: 3)) else { return .exit }
            let indent = nsLine.substring(with: match.range(at: 1))
            let numberText = nsLine.substring(with: match.range(at: 2))
            let separator = numberText.hasSuffix(")") ? ")" : "."
            guard let number = Int(numberText.dropLast()) else { return nil }
            return .continue(marker: "\(indent)\(number + 1)\(separator) ")
        }
        return nil
    }

    /// Whether `line` is a numbered-list item — used to find the extent of a
    /// numbered-list block around the cursor for renumbering.
    static func isOrderedListLine(_ line: String) -> Bool {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return orderedListRegex.firstMatch(in: line, range: full) != nil
    }

    /// The digits-only range of a numbered-list line's number (absolute,
    /// given `lineStart`), its integer value, and its separator character —
    /// used by the renumbering pass to surgically replace just the digits.
    static func orderedListNumberInfo(forLine line: String, lineStart: Int) -> (numberRange: NSRange, number: Int, separator: String)? {
        let nsLine = line as NSString
        let full = NSRange(location: 0, length: nsLine.length)
        guard let match = orderedListRegex.firstMatch(in: line, range: full) else { return nil }
        let numberText = nsLine.substring(with: match.range(at: 2))
        let separator = numberText.hasSuffix(")") ? ")" : "."
        guard let number = Int(numberText.dropLast()) else { return nil }
        let numberRange = NSRange(location: lineStart + match.range(at: 2).location, length: numberText.count - 1)
        return (numberRange, number, separator)
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
        let listMarkerColor = markerColor.withAlphaComponent(0.5)
        let linkColor = theme.resolvedLinkColor
        let codeBackground = theme.resolvedCodeBackgroundColor
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)

        textStorage.beginEditing()
        textStorage.setAttributes([.font: baseFont, .foregroundColor: theme.resolvedTextColor], range: full)

        // Claimed ranges (fenced code blocks, then inline code spans) are
        // excluded from every other rule below — raw code content shouldn't
        // be reinterpreted as markdown just because it contains "*" or "#".
        var claimed: [NSRange] = []
        func isClaimed(_ range: NSRange) -> Bool {
            claimed.contains { NSIntersectionRange($0, range).length > 0 }
        }

        for match in fencedCodeBlockRegex.matches(in: text, range: full) {
            textStorage.addAttribute(.font, value: monoFont, range: match.range)
            textStorage.addAttribute(.backgroundColor, value: codeBackground, range: match.range)
            claimed.append(match.range)
        }

        for match in codeRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let markerA = NSRange(location: match.range.location, length: 1)
            let markerB = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            textStorage.addAttribute(.font, value: monoFont, range: match.range(at: 1))
            textStorage.addAttribute(.backgroundColor, value: codeBackground, range: match.range(at: 1))
            if touches(match.range, cursorSelection) {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerA)
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerB)
            } else {
                collapse(range: markerA, in: textStorage, text: text, font: baseFont)
                collapse(range: markerB, in: textStorage, text: text, font: baseFont)
            }
            claimed.append(match.range)
        }

        for match in headerRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
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

        for match in blockquoteRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let markerRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            guard contentRange.length > 0 else { continue }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = 16
            paragraphStyle.firstLineHeadIndent = 16
            textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: match.range)

            let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            textStorage.addAttribute(.font, value: italicFont, range: contentRange)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: contentRange)

            if touches(match.range, cursorSelection) {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
            } else {
                collapse(range: markerRange, in: textStorage, text: text, font: baseFont)
            }
        }

        for match in horizontalRuleRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            textStorage.addAttribute(.strikethroughColor, value: markerColor, range: match.range)
            textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: match.range)
        }

        for match in taskListRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let markerRange = match.range(at: 1)
            let checkboxRange = match.range(at: 2)
            let contentRange = match.range(at: 3)
            let checkboxText = (text as NSString).substring(with: checkboxRange)
            let isChecked = checkboxText.lowercased() == "[x]"

            textStorage.addAttribute(.foregroundColor, value: listMarkerColor, range: markerRange)

            // Renders as an actual checkbox glyph substituted onto "[" — the
            // inner character (space or x) and "]" always collapse. Glyph
            // substitution was originally applied to the inner character, but
            // when unchecked that character is a literal space, and AppKit
            // silently skips drawing a substituted glyph on a whitespace
            // character regardless of the override — the checkbox just
            // vanished on uncheck. "[" is never whitespace, so it's reliable —
            // but resolving ☐/☑ (Miscellaneous Symbols block) against the
            // theme's own font silently failed too, since arbitrary fonts
            // (including the default system font) often don't cover that
            // block, and the lookup just falls back to plain "[" with no
            // error. "Apple Symbols" is a bundled system font specifically
            // meant to cover this kind of symbol, independent of body text
            // font choice, so it's used here instead of baseFont.
            let bracketOpen = NSRange(location: checkboxRange.location, length: 1)
            let innerChar = NSRange(location: checkboxRange.location + 1, length: 1)
            let bracketClose = NSRange(location: checkboxRange.location + 2, length: 1)
            let symbolFont = NSFont(name: "Apple Symbols", size: baseFont.pointSize + 5) ?? NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize + 5)
            textStorage.addAttribute(.font, value: symbolFont, range: bracketOpen)
            textStorage.addAttribute(.foregroundColor, value: isChecked ? NSColor.systemGreen : listMarkerColor, range: bracketOpen)
            if let glyphInfo = glyphInfo(forUnicodeChar: isChecked ? "☑" : "☐", font: symbolFont, baseString: "[") {
                textStorage.addAttribute(.glyphInfo, value: glyphInfo, range: bracketOpen)
            }
            // Always collapsed, not gated by touches() like other markers —
            // checkboxes are meant to be clicked, not hand-edited, and
            // revealing "]" whenever the cursor was merely anywhere on the
            // line (touches() checks the whole line's match.range) was
            // distracting.
            collapse(range: innerChar, in: textStorage, text: text, font: baseFont)
            collapse(range: bracketClose, in: textStorage, text: text, font: baseFont)

            if isChecked {
                textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: contentRange)
            }
            claimed.append(match.range(at: 1))
            claimed.append(checkboxRange)
        }

        for match in unorderedListRegex.matches(in: text, range: full) {
            let markerRange = match.range(at: 2)
            guard !isClaimed(markerRange) else { continue }
            textStorage.addAttribute(.foregroundColor, value: listMarkerColor, range: markerRange)
            // Only "*" renders as an actual bullet glyph — "-" and "+" stay as
            // themselves. Substitutes the *displayed glyph*, without touching
            // the actual character — the saved file still has the original
            // marker, cursor/backspace still see it.
            let markerChar = (text as NSString).substring(with: markerRange)
            if markerChar == "*" {
                let bulletFont = NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize + 7)
                if let glyphInfo = NSGlyphInfo(glyphName: "bullet", for: bulletFont, baseString: markerChar) {
                    textStorage.addAttribute(.font, value: bulletFont, range: markerRange)
                    textStorage.addAttribute(.glyphInfo, value: glyphInfo, range: markerRange)
                }
            }
        }

        for match in orderedListRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range(at: 2)) else { continue }
            textStorage.addAttribute(.foregroundColor, value: listMarkerColor, range: match.range(at: 2))
        }

        for match in boldItalicRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            applyEmphasis(match: match, textStorage: textStorage, text: text, baseFont: baseFont, markerColor: markerColor, bold: true, italic: true, revealed: touches(match.range, cursorSelection))
            claimed.append(match.range)
        }

        for match in boldRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            applyEmphasis(match: match, textStorage: textStorage, text: text, baseFont: baseFont, markerColor: markerColor, bold: true, italic: false, revealed: touches(match.range, cursorSelection))
        }

        for match in italicRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            applyEmphasis(match: match, textStorage: textStorage, text: text, baseFont: baseFont, markerColor: markerColor, bold: false, italic: true, revealed: touches(match.range, cursorSelection))
        }

        for match in strikethroughRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let contentRange = match.range(at: 1)
            let leadingMarker = NSRange(location: match.range.location, length: 2)
            let trailingMarker = NSRange(location: match.range.location + match.range.length - 2, length: 2)
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
            if touches(match.range, cursorSelection) {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: leadingMarker)
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: trailingMarker)
            } else {
                collapse(range: leadingMarker, in: textStorage, text: text, font: baseFont)
                collapse(range: trailingMarker, in: textStorage, text: text, font: baseFont)
            }
        }

        for match in linkRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            styleLinkLike(match: match, textStorage: textStorage, text: text, baseFont: baseFont, markerColor: markerColor, linkColor: linkColor, revealed: touches(match.range, cursorSelection))
            claimed.append(match.range)
        }

        for match in autolinkBracketRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let urlRange = match.range(at: 1)
            textStorage.addAttribute(.foregroundColor, value: linkColor, range: urlRange)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: urlRange)
            if let url = URL(string: (text as NSString).substring(with: urlRange)) {
                textStorage.addAttribute(.link, value: url, range: urlRange)
            }
            let bracketA = NSRange(location: match.range.location, length: 1)
            let bracketB = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketA)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketB)
            claimed.append(match.range)
        }

        for match in bareURLRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            textStorage.addAttribute(.foregroundColor, value: linkColor, range: match.range)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            if let url = URL(string: (text as NSString).substring(with: match.range)) {
                textStorage.addAttribute(.link, value: url, range: match.range)
            }
            claimed.append(match.range)
        }

        for match in wikiLinkRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
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

    /// Styling for `[text](url)` links: the visible "text" is colored like a
    /// link, and the surrounding `[`, `]`, `(url)` collapse into smart-view
    /// unless the cursor is inside the span.
    private static func styleLinkLike(
        match: NSTextCheckingResult,
        textStorage: NSTextStorage,
        text: String,
        baseFont: NSFont,
        markerColor: NSColor,
        linkColor: NSColor,
        revealed: Bool
    ) {
        let labelRange = match.range(at: 1)
        let urlRange = match.range(at: 2)
        let bracketOpen = NSRange(location: labelRange.location - 1, length: 1)
        let bracketClose = NSRange(location: labelRange.location + labelRange.length, length: 1)
        let urlWithParens = NSRange(
            location: bracketClose.location + 1,
            length: (urlRange.location + urlRange.length + 1) - (bracketClose.location + 1)
        )

        textStorage.addAttribute(.foregroundColor, value: linkColor, range: labelRange)
        textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: labelRange)
        if let url = URL(string: (text as NSString).substring(with: urlRange)), url.scheme?.hasPrefix("http") == true {
            textStorage.addAttribute(.link, value: url, range: labelRange)
        }

        if revealed {
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketOpen)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketClose)
            textStorage.addAttribute(.foregroundColor, value: markerColor, range: urlWithParens)
        } else {
            collapse(range: bracketOpen, in: textStorage, text: text, font: baseFont)
            collapse(range: bracketClose, in: textStorage, text: text, font: baseFont)
            collapse(range: urlWithParens, in: textStorage, text: text, font: baseFont)
        }
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

    /// Resolves a Unicode character's own glyph in `font` via CoreText and
    /// wraps it as an NSGlyphInfo substitution for `baseString` (the actual
    /// character present at the target range). More robust than
    /// NSGlyphInfo(glyphName:...) for characters without a standardized
    /// PostScript/AGL name, like the checkbox glyphs.
    private static func glyphInfo(forUnicodeChar char: Character, font: NSFont, baseString: String) -> NSGlyphInfo? {
        guard let scalar = char.unicodeScalars.first else { return nil }
        var chars: [UniChar] = [UniChar(scalar.value)]
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyph, 1), glyph != 0 else { return nil }
        return NSGlyphInfo(cgGlyph: glyph, for: font, baseString: baseString)
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

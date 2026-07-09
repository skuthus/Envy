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
    private static let footnoteDefinitionRegex = try! NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:[ \t]*"#, options: [.anchorsMatchLines])
    private static let footnoteReferenceRegex = try! NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#)

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

    /// The range of the "[^label]:" marker for a footnote definition matching
    /// `label`, if one exists — used to scroll a clicked reference to its
    /// definition within the same note.
    static func footnoteDefinitionRange(forLabel label: String, in text: String) -> NSRange? {
        let full = NSRange(location: 0, length: (text as NSString).length)
        for match in footnoteDefinitionRegex.matches(in: text, range: full) {
            if (text as NSString).substring(with: match.range(at: 1)) == label {
                return match.range
            }
        }
        return nil
    }

    /// Every footnote reference's label range and text, excluding a
    /// definition's own "[^label]" (which isn't a reference) — used to
    /// compute a generous on-screen click target, since the rendered glyph
    /// (a small raised number) is otherwise tiny.
    static func footnoteReferenceLabels(in text: String) -> [(labelRange: NSRange, label: String)] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        let definitionRanges = footnoteDefinitionRegex.matches(in: text, range: full).map(\.range)
        func isDefinitionMarker(_ range: NSRange) -> Bool {
            definitionRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        return footnoteReferenceRegex.matches(in: text, range: full).compactMap { match in
            guard !isDefinitionMarker(match.range) else { return nil }
            let labelRange = match.range(at: 1)
            return (labelRange, (text as NSString).substring(with: labelRange))
        }
    }

    /// GitHub-style heading slug: lowercased, with anything that isn't a
    /// letter, digit, space, or hyphen stripped, and whitespace collapsed to
    /// single hyphens — how a `[text](#heading)` in-note anchor is expected
    /// to reference a heading by its rendered text.
    static func headingSlug(for headingText: String) -> String {
        let lowered = headingText.lowercased()
        let filtered = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-"
        }
        let cleaned = String(String.UnicodeScalarView(filtered))
        return cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: "-")
    }

    /// Every heading's slug (with GitHub-style "-1", "-2" suffixes appended
    /// for repeated headings, in document order) paired with the range of
    /// its heading text.
    private static func headingSlugRanges(in text: String) -> [(slug: String, range: NSRange)] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var seenCounts: [String: Int] = [:]
        return headerRegex.matches(in: text, range: full).map { match in
            let contentRange = match.range(at: 2)
            let headingText = (text as NSString).substring(with: contentRange)
            let baseSlug = headingSlug(for: headingText)
            let count = seenCounts[baseSlug, default: 0]
            seenCounts[baseSlug] = count + 1
            let slug = count == 0 ? baseSlug : "\(baseSlug)-\(count)"
            return (slug, contentRange)
        }
    }

    /// The range of the heading whose slug matches `slug` (from a
    /// `[text](#slug)` in-note anchor link), if one exists — used to scroll
    /// a clicked anchor link to its heading within the same note.
    static func headingRange(forSlug slug: String, in text: String) -> NSRange? {
        headingSlugRanges(in: text).first { $0.slug == slug }?.range
    }

    /// Plain-text mode's counterpart to `style(...)` — resets the whole
    /// range to a single uniform font/color and nothing else: no collapsed
    /// markers, no bold/heading/list styling, no glyph substitution, no
    /// `.link` attributes (so clicking never navigates). The note's actual
    /// file content is untouched either way; this only ever affects what's
    /// drawn on screen.
    static func clearFormatting(
        textStorage: NSTextStorage,
        text: String,
        theme: Theme,
        fontSizeAdjustment: CGFloat = 0
    ) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let unadjustedFont = theme.resolvedFont
        let baseFont = fontSizeAdjustment == 0
            ? unadjustedFont
            : NSFontManager.shared.convert(unadjustedFont, toSize: max(6, unadjustedFont.pointSize + fontSizeAdjustment))

        textStorage.beginEditing()
        textStorage.setAttributes([.font: baseFont, .foregroundColor: theme.resolvedTextColor], range: full)
        textStorage.endEditing()
    }

    static func style(
        textStorage: NSTextStorage,
        text: String,
        theme: Theme,
        revealedLinkRange: NSRange? = nil,
        searchQuery: String = "",
        cursorSelection: NSRange? = nil,
        fontSizeAdjustment: CGFloat = 0
    ) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let unadjustedFont = theme.resolvedFont
        // Everything below derives its size from baseFont.pointSize (headings,
        // bold, code, etc.), so nudging it here is enough to zoom the whole
        // note proportionally without touching the user's saved theme size.
        let baseFont = fontSizeAdjustment == 0
            ? unadjustedFont
            : NSFontManager.shared.convert(unadjustedFont, toSize: max(6, unadjustedFont.pointSize + fontSizeAdjustment))
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

        // Footnote definitions ("[^label]: text") are processed before
        // references so their "[^label]:" marker range gets claimed —
        // otherwise the reference regex below would also match it, since a
        // definition's marker is syntactically identical to a reference.
        for match in footnoteDefinitionRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let markerRange = match.range
            let smallFont = NSFontManager.shared.convert(baseFont, toSize: max(baseFont.pointSize - 1, 9))
            let lineRange = (text as NSString).lineRange(for: NSRange(location: markerRange.location, length: 0))
            let contentStart = markerRange.location + markerRange.length
            let contentRange = NSRange(location: contentStart, length: max(0, lineRange.location + lineRange.length - contentStart))
            if contentRange.length > 0 {
                textStorage.addAttribute(.font, value: smallFont, range: contentRange)
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: contentRange)
            }
            if touches(markerRange, cursorSelection) {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
            } else {
                collapse(range: markerRange, in: textStorage, text: text, font: baseFont)
            }
            claimed.append(markerRange)
        }

        // Footnote references ("[^label]") render as a small raised marker
        // (like a real footnote number), with "[^" and "]" collapsed. Always
        // clickable regardless of reveal state, same reasoning as checkboxes:
        // this is meant to be clicked to jump to its definition, not
        // hand-edited in place.
        for match in footnoteReferenceRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let labelRange = match.range(at: 1)
            let openMarker = NSRange(location: match.range.location, length: labelRange.location - match.range.location)
            let closeMarker = NSRange(location: labelRange.location + labelRange.length, length: 1)

            let superscriptFont = NSFontManager.shared.convert(baseFont, toSize: max(baseFont.pointSize - 3, 8))
            textStorage.addAttribute(.font, value: superscriptFont, range: labelRange)
            textStorage.addAttribute(.baselineOffset, value: baseFont.pointSize * 0.35, range: labelRange)
            textStorage.addAttribute(.foregroundColor, value: linkColor, range: labelRange)

            let label = (text as NSString).substring(with: labelRange)
            let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
            if let url = URL(string: "envy-footnote:///\(encoded)") {
                textStorage.addAttribute(.link, value: url, range: labelRange)
            }

            collapse(range: openMarker, in: textStorage, text: text, font: baseFont)
            collapse(range: closeMarker, in: textStorage, text: text, font: baseFont)
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
        if let url = URL(string: (text as NSString).substring(with: urlRange)) {
            if url.scheme?.hasPrefix("http") == true {
                textStorage.addAttribute(.link, value: url, range: labelRange)
            } else if url.scheme == nil, url.host == nil, let fragment = url.fragment {
                // "[text](#heading)" — an in-note anchor rather than a real
                // URL, routed through its own scheme so the click handler can
                // tell it apart from a wiki-link or a web link.
                let encoded = fragment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fragment
                if let headingURL = URL(string: "envy-heading:///\(encoded)") {
                    textStorage.addAttribute(.link, value: headingURL, range: labelRange)
                }
            }
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
        let fullRange = NSRange(location: 0, length: nsText.length)

        func highlightMatches(ofPattern pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for match in regex.matches(in: text, range: fullRange) {
                textStorage.addAttribute(.backgroundColor, value: color, range: match.range)
            }
        }
        func highlightLiteral(_ literal: String) {
            highlightMatches(ofPattern: NSRegularExpression.escapedPattern(for: literal))
        }

        // Tokenized the same way NoteStore.filtered(query:) parses a query —
        // "tag:"/"date:" can appear anywhere among the words, combined with
        // free text, not just as the whole query. Each word highlights
        // independently, since a scattered multi-word AND search has no
        // single contiguous phrase to find in the first place.
        for token in trimmed.split(separator: " ") where !token.isEmpty {
            let lowered = token.lowercased()
            if lowered.hasPrefix("tag:") {
                // "tag:xxx" is a search operator, not literal text to look
                // for, and (matching NoteStore.filtered's substring tag
                // matching) "xxx" doesn't have to be the *whole* tag name —
                // "tag:techn" matches "#technology". Highlight just the
                // matched substring within each qualifying "#tag", not the
                // tag's full extent, consistent with how a plain free-text
                // search only highlights the substring actually searched.
                let tagName = lowered.dropFirst("tag:".count)
                guard !tagName.isEmpty else { continue }
                let tagRegex = try? NSRegularExpression(pattern: "(?<![\\w#])#[A-Za-z0-9_-]+")
                for tagMatch in tagRegex?.matches(in: text, range: fullRange) ?? [] {
                    let tagText = nsText.substring(with: tagMatch.range)
                    guard let subRange = tagText.range(of: tagName, options: .caseInsensitive) else { continue }
                    let nsSubRange = NSRange(subRange, in: tagText)
                    let absoluteRange = NSRange(location: tagMatch.range.location + nsSubRange.location, length: nsSubRange.length)
                    textStorage.addAttribute(.backgroundColor, value: color, range: absoluteRange)
                }
            } else if lowered.hasPrefix("date:") {
                // Nothing literal in the note text corresponds to a date
                // filter — there's nothing to highlight.
                continue
            } else {
                highlightLiteral(String(token))
            }
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

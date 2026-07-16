import AppKit
import EnvyCore

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
    // The "-"/"*"/"+" list marker is optional (group 1 still captures it,
    // and any leading whitespace, when present) — "[ ] Buy milk" on its own
    // line is a checkbox exactly like "- [ ] Buy milk" is, just without the
    // bullet. Still line-anchored, not a mid-sentence match — "Remember [ ]
    // to buy milk" doesn't become one, only "[ ] Remember to buy milk" does.
    private static let taskListRegex = try! NSRegularExpression(pattern: #"^(\s*(?:[-*+][ \t]+)?)(\[[ xX]\])([ \t]+.*)$"#, options: [.anchorsMatchLines])
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
    // Matches Note.tagRegex in EnvyCore exactly (duplicated rather than
    // shared since that one is private to its target) — excludes markdown
    // headings, which require a space after "#", and mid-word/"##" false
    // positives.
    private static let hashtagRegex = try! NSRegularExpression(pattern: #"(?<![\w#])#[A-Za-z0-9_-]+"#)
    // Matches Note.dueRegex in EnvyCore exactly, including restricting the
    // capture to a day name or date-shaped characters (digits, "-", "/")
    // rather than a greedy \S+ — \S+ swallowed trailing punctuation like a
    // comma right after the date with no space, which then failed to parse
    // as a date and silently fell back to the plain (not-yet-due) color
    // regardless of the note's actual urgency, and an unrestricted
    // alternative would also light up ordinary "@mentions" that are
    // neither a day name nor a date. Same duplication reasoning as
    // hashtagRegex above (that one's private to its own target).
    private static let dueRegex = try! NSRegularExpression(
        pattern: #"(?<![\w])@(monday|tuesday|wednesday|thursday|friday|saturday|sunday|[0-9/-]+)(?!\w)"#,
        options: [.caseInsensitive]
    )

    static func wikiLinkFullRanges(in text: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return wikiLinkRegex.matches(in: text, range: full).map(\.range)
    }

    /// The range within `newText` that actually differs from `oldText`, found
    /// via longest-common-prefix/-suffix rather than a full diff algorithm —
    /// cheap, and exactly right for the common case this feeds (a small
    /// external edit to a note), where the change is one localized run of
    /// characters. A near-total rewrite just degenerates to "highlight
    /// everything," which is still a reasonable fallback.
    static func changedRange(from oldText: String, to newText: String) -> NSRange {
        let old = oldText as NSString
        let new = newText as NSString
        let minLength = min(old.length, new.length)

        var prefixLength = 0
        while prefixLength < minLength, old.character(at: prefixLength) == new.character(at: prefixLength) {
            prefixLength += 1
        }

        var suffixLength = 0
        let maxSuffix = minLength - prefixLength
        while suffixLength < maxSuffix,
              old.character(at: old.length - 1 - suffixLength) == new.character(at: new.length - 1 - suffixLength) {
            suffixLength += 1
        }

        let changedLength = max(new.length - prefixLength - suffixLength, 0)
        return NSRange(location: prefixLength, length: changedLength)
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

    /// Whether `line` is any kind of list item (bullet, numbered, or task) —
    /// used to decide whether Tab/Shift-Tab should indent/outdent the whole
    /// line (nesting it a level deeper or shallower) instead of doing
    /// nothing special.
    static func isListLine(_ line: String) -> Bool {
        let full = NSRange(location: 0, length: (line as NSString).length)
        return taskListRegex.firstMatch(in: line, range: full) != nil
            || unorderedListRegex.firstMatch(in: line, range: full) != nil
            || orderedListRegex.firstMatch(in: line, range: full) != nil
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

    /// `restyleRange` restricts every styling pass to that slice of the
    /// document instead of the whole thing — the per-keystroke path on a
    /// large note passes a paragraph-snapped window around the edit, since
    /// every rule below is line-local and re-deriving the other 99% of an
    /// unchanged document on each keystroke is pure waste. The one
    /// document-global construct (a fenced code block, whose opening ```
    /// changes the meaning of everything after it) is the caller's problem:
    /// Coordinator.windowedRestyleRange only ever offers a window when the
    /// note contains no fences at all. nil means style everything.
    static func style(
        textStorage: NSTextStorage,
        text: String,
        theme: Theme,
        revealedLinkRange: NSRange? = nil,
        searchQuery: String = "",
        cursorSelection: NSRange? = nil,
        fontSizeAdjustment: CGFloat = 0,
        restyleRange: NSRange? = nil
    ) {
        let wholeDocument = NSRange(location: 0, length: (text as NSString).length)
        let full = restyleRange.map { NSIntersectionRange($0, wholeDocument) } ?? wholeDocument
        guard full.length > 0 else { return }

        let unadjustedFont = theme.resolvedFont
        // Everything below derives its size from baseFont.pointSize (headings,
        // bold, code, etc.), so nudging it here is enough to zoom the whole
        // note proportionally without touching the user's saved theme size.
        let baseFont = fontSizeAdjustment == 0
            ? unadjustedFont
            : NSFontManager.shared.convert(unadjustedFont, toSize: max(6, unadjustedFont.pointSize + fontSizeAdjustment))
        let markerColor = theme.resolvedMarkerColor
        // .withAlphaComponent(_:) on a dynamic system color (theme.resolvedMarkerColor
        // is .tertiaryLabelColor for the default, non-custom theme) resolves eagerly
        // using whatever appearance happens to be "current" at this exact call site —
        // which isn't reliably correct here — rather than staying dynamic. Same root
        // cause as the light-mode search bar and inline-code background bugs, and the
        // checkbox overlay's own uncheckedColor; same dynamic-resolver-closure fix.
        // Without it, every list bullet (and the "- " before a checkbox) can render
        // as white-on-white in light mode.
        let listMarkerColor = NSColor(name: nil) { _ in markerColor.withAlphaComponent(0.5) }
        let linkColor = theme.resolvedLinkColor
        let codeBackground = theme.resolvedCodeBackgroundColor
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        let tagColor = theme.resolvedTagColor
        let tagBackground = theme.resolvedTagBackgroundColor
        let tagFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        // Hoisted out of the hashtag loop below — same two inputs on every
        // match, so recomputing this per-tag was wasted color-space work on
        // notes with many hashtags.
        let legibleTagForeground = legibleForeground(tagColor, over: compositedColor(tagBackground, over: theme.resolvedBackgroundColor))
        let dueColor = theme.resolvedDueColor
        let dueSoonColor = theme.resolvedDueSoonColor
        let dueOverdueColor = theme.resolvedDueOverdueColor

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

        // Bold + a tinted background chip, same technique as inline code
        // spans above — deliberately not added to `claimed`, since nothing
        // else in this function matches bare "#word" without a following
        // space, so there's nothing for a hashtag to conflict with.
        for match in hashtagRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            textStorage.addAttribute(.font, value: tagFont, range: match.range)
            textStorage.addAttribute(.foregroundColor, value: legibleTagForeground, range: match.range)
            textStorage.addAttribute(.backgroundColor, value: tagBackground, range: match.range)
        }

        // Bold, single-color foreground — no background chip, deliberately
        // styled like a link (one dedicated color) rather than like a tag
        // (color + chip), since this is a single per-note value, not a
        // repeated/multi-valued marker. Color depends on each match's own
        // resolved date (not the note-level `due`, which only ever holds the
        // first token) — overdue/soon/later each get their own theme token,
        // same three-way split dueUrgency itself expresses. An unparseable
        // token still highlights (same graceful-failure spirit as the rest
        // of this file) but falls back to the plain dueColor, since there's
        // no date to classify.
        for match in dueRegex.matches(in: text, range: full) {
            guard !isClaimed(match.range) else { continue }
            let tokenRange = match.range(at: 1)
            let token = (text as NSString).substring(with: tokenRange)
            let color: NSColor
            if let date = NoteStore.resolveDueToken(token) {
                switch NoteStore.dueUrgency(for: date) {
                case .overdue: color = dueOverdueColor
                case .soon: color = dueSoonColor
                case .later: color = dueColor
                }
            } else {
                color = dueColor
            }
            textStorage.addAttribute(.font, value: tagFont, range: match.range)
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
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
            // Was markerColor (tertiaryLabelColor by default) — the same very
            // low-contrast color used to dim collapsed markdown syntax
            // markers, not meant for actual readable content. That made
            // quoted text itself hard to read instead of just italicized,
            // unlike every other element here (headings, bold, etc.), which
            // only ever apply the marker color to the marker's own range,
            // never its content. secondaryLabelColor still reads as quieter
            // than body text without being borderline invisible.
            textStorage.addAttribute(.foregroundColor, value: theme.resolvedBlockquoteColor, range: contentRange)

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
                textStorage.addAttribute(.foregroundColor, value: theme.resolvedFootnoteColor, range: contentRange)
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
            let markerRange = match.range(at: 1)
            let checkboxRange = match.range(at: 2)
            let contentRange = match.range(at: 3)
            // Only the marker + "[x]" itself disqualifies the checkbox — not
            // match.range as a whole, which also spans contentRange. That
            // trailing text is expected to carry its own independent inline
            // styling (code, bold, links, ...); checking the whole line here
            // meant a checked item like "- [x] see `template:`" silently
            // rendered as plain "- [x] ..." text with no checkbox at all,
            // since the inline code span claims part of the line first.
            guard !isClaimed(NSUnionRange(markerRange, checkboxRange)) else { continue }
            let checkboxText = (text as NSString).substring(with: checkboxRange)
            let isChecked = checkboxText.lowercased() == "[x]"

            textStorage.addAttribute(.foregroundColor, value: listMarkerColor, range: markerRange)

            // The whole "[x]"/"[ ]" run is collapsed (hidden, zero visual
            // width — same technique as every other hidden markdown marker
            // in this file) rather than substituting a checkbox glyph onto
            // "[" via NSGlyphInfo, which is what this used to do. That
            // worked most of the time, but AppKit's layout manager can get
            // its internal glyph-generation cache out of sync when a text
            // storage has several occurrences of the same base string ("["
            // here) each substituted to a *different* glyph (☑ vs ☐) and
            // keeps getting edited — it would intermittently stop drawing
            // the substituted glyph for some or all occurrences at once,
            // with no way to force a reliable re-sync. The actual checkbox
            // glyph is now drawn by a floating overlay view instead (see
            // Coordinator.updateCheckboxOverlays() in MarkdownTextView),
            // positioned over this now-invisible "[" — sidestepping glyph
            // substitution, and its fragility, entirely. Always collapsed,
            // not gated by touches() like other markers — checkboxes are
            // meant to be clicked, not hand-edited, and revealing "]"
            // whenever the cursor was merely anywhere on the line
            // (touches() checks the whole line's match.range) was
            // distracting anyway.
            let bracketOpen = NSRange(location: checkboxRange.location, length: 1)
            let innerChar = NSRange(location: checkboxRange.location + 1, length: 1)
            let bracketClose = NSRange(location: checkboxRange.location + 2, length: 1)
            // bracketOpen is padded out to the overlay's width rather than
            // collapsed to zero, like innerChar/bracketClose are — otherwise
            // the text right after "[x] " lays out as if the checkbox took
            // no space at all and ends up drawn underneath the overlay glyph.
            reserveSpace(range: bracketOpen, width: checkboxSymbolWidth(baseFont: baseFont), in: textStorage, text: text, font: baseFont)
            collapse(range: innerChar, in: textStorage, text: text, font: baseFont)
            collapse(range: bracketClose, in: textStorage, text: text, font: baseFont)

            if isChecked {
                textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                textStorage.addAttribute(.foregroundColor, value: theme.resolvedCompletedTaskColor, range: contentRange)
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

            // Revealed on mouse hover (revealedLinkRange) same as before, and
            // now also while the cursor is actually inside the link — a
            // wiki-link being actively typed has no mouse anywhere near it,
            // so without this the brackets would collapse the instant a
            // keystroke restyles the text.
            if match.range == revealedLinkRange || touches(match.range, cursorSelection) {
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketOpen)
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: bracketClose)
            } else {
                collapse(range: bracketOpen, in: textStorage, text: text, font: baseFont)
                collapse(range: bracketClose, in: textStorage, text: text, font: baseFont)
            }
            textStorage.addAttribute(.foregroundColor, value: linkColor, range: titleRange)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: titleRange)
            if let url = URL(string: "envy:///\(encoded)") {
                textStorage.addAttribute(.link, value: url, range: titleRange)
            }
        }

        highlightMatches(of: searchQuery, in: text, textStorage: textStorage, color: theme.resolvedHighlightColor, backdrop: theme.resolvedBackgroundColor)

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

    // WCAG-style relative luminance (0 = black, 1 = white) — used only to
    // decide whether text drawn over a highlight-style background (search
    // matches, tag chips, selected-text background) needs to flip to pure
    // black/white for legibility. Theme colors are fully independent user
    // choices (a highlight color and the text color it sits under aren't
    // picked as a pair), so a combination that reads as invisible is a
    // real, reachable case, not just a hypothetical one. Not private —
    // MarkdownTextView's own selected-text handling reuses it too.
    static func relativeLuminance(of color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? NSColor(white: 0.5, alpha: 1)
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
    }

    /// Flattens a translucent color against an opaque backdrop into the
    /// solid color it actually reads as. Tag/highlight backgrounds are
    /// usually a low-alpha tint (e.g. systemGreen at 15%), not a solid
    /// fill — reading such a color's own RGB components directly (as
    /// `relativeLuminance` does) ignores the alpha and measures it as if
    /// it were fully saturated and opaque, which is far darker than the
    /// pale wash it's actually perceived as once composited over the
    /// editor background. That mismatch was wrongly triggering the
    /// black/white flip below on perfectly legible tag text.
    static func compositedColor(_ color: NSColor, over backdrop: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color }
        guard c.alphaComponent < 1, let b = backdrop.usingColorSpace(.deviceRGB) else { return c }
        let alpha = c.alphaComponent
        let r = c.redComponent * alpha + b.redComponent * (1 - alpha)
        let g = c.greenComponent * alpha + b.greenComponent * (1 - alpha)
        let bl = c.blueComponent * alpha + b.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: bl, alpha: 1)
    }

    /// Returns `foreground` unchanged if it already reads clearly enough
    /// against `background`; otherwise flips to pure black or white,
    /// whichever contrasts more. The 2.2 threshold is deliberately looser
    /// than WCAG's own 4.5:1 AA minimum — this is a last-resort fix for
    /// genuinely poor pairings (highlight ≈ text color), not a general
    /// accessibility pass, so it stays out of the way of combinations that
    /// are merely a little low-contrast by choice.
    static func legibleForeground(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let bg = relativeLuminance(of: background)
        let fg = relativeLuminance(of: foreground)
        let contrast = (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05)
        guard contrast < 2.2 else { return foreground }
        return bg > 0.5 ? .black : .white
    }

    private static func highlightMatches(of query: String, in text: String, textStorage: NSTextStorage, color: NSColor, backdrop: NSColor) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nsText = text as NSString
        guard nsText.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: nsText.length)
        let perceivedColor = compositedColor(color, over: backdrop)

        func highlightMatches(ofPattern pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for match in regex.matches(in: text, range: fullRange) {
                textStorage.addAttribute(.backgroundColor, value: color, range: match.range)
                // Reads whatever foreground color the rest of styling
                // already settled on (this runs last, right before
                // endEditing) so it can tell whether the highlight would
                // make that specific span unreadable — a search match
                // landing on bold text, a link, a tag, or plain body text
                // each already has its own color by this point.
                textStorage.enumerateAttribute(.foregroundColor, in: match.range, options: []) { existing, subrange, _ in
                    let current = (existing as? NSColor) ?? .labelColor
                    let adjusted = legibleForeground(current, over: perceivedColor)
                    if adjusted != current {
                        textStorage.addAttribute(.foregroundColor, value: adjusted, range: subrange)
                    }
                }
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
            } else if lowered.hasPrefix("date:") || lowered.hasPrefix("due:") {
                // Nothing literal in the note text corresponds to a date/due
                // filter — there's nothing to highlight.
                continue
            } else {
                highlightLiteral(String(token))
            }
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

    // Like collapse(), but instead of shrinking the character to zero width,
    // pads it out to exactly `width` — used to reserve room for the
    // checkbox overlay (see Coordinator.updateCheckboxOverlays() in
    // MarkdownTextView) so the following text doesn't lay out as if the
    // hidden "[" were still its own natural (smaller) width and end up
    // drawn underneath the overlay glyph.
    private static func reserveSpace(range: NSRange, width: CGFloat, in textStorage: NSTextStorage, text: String, font: NSFont) {
        guard range.length == 1 else { return }
        let nsText = text as NSString
        textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        let char = nsText.substring(with: range)
        let naturalWidth = NSAttributedString(string: char, attributes: [.font: font]).size().width
        textStorage.addAttribute(.kern, value: width - naturalWidth, range: range)
    }

    // Shared between the checkbox-collapsing above and the checkbox overlay
    // in MarkdownTextView.Coordinator.updateCheckboxOverlays() — both need
    // to agree on the exact same font so the reserved space matches what's
    // actually drawn on top of it.
    static func checkboxSymbolFont(baseFont: NSFont) -> NSFont {
        NSFont(name: "Apple Symbols", size: baseFont.pointSize + 5)
            ?? NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize + 5)
    }

    static func checkboxSymbolWidth(baseFont: NSFont) -> CGFloat {
        let symbolFont = checkboxSymbolFont(baseFont: baseFont)
        let checked = NSAttributedString(string: "☑", attributes: [.font: symbolFont]).size().width
        let unchecked = NSAttributedString(string: "☐", attributes: [.font: symbolFont]).size().width
        return max(checked, unchecked)
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

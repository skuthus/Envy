import Foundation

/// Pure markdown-structure helpers shared by the editor styler and EnvySelfCheck.
/// Rendering/color stays in MarkdownStyler; range/token logic that search and
/// UI both depend on lives here so it can be asserted without the app target.
public enum MarkdownSemantics {
    public static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    public static let fencedCodeBlockRegex = try! NSRegularExpression(
        pattern: #"^```[^\n]*\n([\s\S]*?)\n```[ \t]*$"#, options: [.anchorsMatchLines]
    )
    public static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"^(>[ \t]?)(.*)$"#, options: [.anchorsMatchLines]
    )

    /// Every `[[…]]` span (including those inside `![[…]]` embeds).
    public static func wikiLinkFullRanges(in text: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return NoteMarkup.wikiLinkRegex.matches(in: text, range: full).map(\.range)
    }

    /// Whole AI provenance line range, or nil.
    public static func aiSignatureRange(in text: String) -> NSRange? {
        let ns = text as NSString
        return NoteMarkup.aiSignatureLineRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)
        )?.range
    }

    public static func aiSignatureLine(in text: String) -> String? {
        guard let range = aiSignatureRange(in: text) else { return nil }
        return (text as NSString).substring(with: range)
    }

    /// Consecutive blockquote lines merged into one span each.
    public static func blockquoteBlockRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var blocks: [NSRange] = []
        for match in blockquoteRegex.matches(in: text, range: full) {
            let line = nsText.lineRange(for: match.range)
            if let last = blocks.last, last.location + last.length >= line.location {
                blocks[blocks.count - 1] = NSUnionRange(last, line)
            } else {
                blocks.append(line)
            }
        }
        return blocks
    }

    /// Due token ranges paired with whether they're tightly wrapped in
    /// `~~@token~~` (the click-toggle shape — not "anywhere inside a longer
    /// strikethrough").
    public static func dueTokenRanges(in text: String) -> [(range: NSRange, isCrossedOut: Bool)] {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let tildeLength = 2
        return NoteMarkup.dueRegex.matches(in: text, range: full).map { match in
            let range = match.range
            let hasLeadingTildes = range.location >= tildeLength
                && nsText.substring(with: NSRange(location: range.location - tildeLength, length: tildeLength)) == "~~"
            let trailingStart = range.location + range.length
            let hasTrailingTildes = trailingStart + tildeLength <= nsText.length
                && nsText.substring(with: NSRange(location: trailingStart, length: tildeLength)) == "~~"
            return (range, hasLeadingTildes && hasTrailingTildes)
        }
    }

    /// Whether `location` sits inside inline `` `code` `` or a fenced block.
    public static func isInsideCode(at location: Int, in text: String) -> Bool {
        let nsText = text as NSString
        let clampedLocation = min(location, nsText.length)

        func contains(_ range: NSRange) -> Bool {
            clampedLocation >= range.location && clampedLocation <= NSMaxRange(range)
        }

        let paragraphRange = nsText.paragraphRange(for: NSRange(location: clampedLocation, length: 0))
        let paragraph = nsText.substring(with: paragraphRange)
        let paragraphFull = NSRange(location: 0, length: (paragraph as NSString).length)
        for match in inlineCodeRegex.matches(in: paragraph, range: paragraphFull) {
            let rangeInDocument = NSRange(
                location: paragraphRange.location + match.range.location,
                length: match.range.length
            )
            if contains(rangeInDocument) { return true }
        }

        guard nsText.range(of: "```").location != NSNotFound else { return false }
        let full = NSRange(location: 0, length: nsText.length)
        for match in fencedCodeBlockRegex.matches(in: text, range: full) {
            if contains(match.range) { return true }
        }
        return false
    }

    /// First whole-word, case-insensitive occurrence of each candidate title
    /// that isn't already inside `[[…]]` or code — Interlinks "Suggested".
    public static func suggestedLinkMatches(
        in text: String,
        candidateTitles: [String]
    ) -> [(title: String, range: NSRange)] {
        guard !text.isEmpty, !candidateTitles.isEmpty else { return [] }
        let nsText = text as NSString
        let existingLinkRanges = wikiLinkFullRanges(in: text)

        func isWordCharacter(_ character: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(character) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }

        var results: [(title: String, range: NSRange)] = []
        for rawTitle in candidateTitles {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 {
                let found = nsText.range(of: title, options: [.caseInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                let before = found.location - 1
                let after = found.location + found.length
                let beforeIsWord = before >= 0 && isWordCharacter(nsText.character(at: before))
                let afterIsWord = after < nsText.length && isWordCharacter(nsText.character(at: after))
                let isAlreadyLinked = existingLinkRanges.contains { NSIntersectionRange($0, found).length > 0 }
                if !beforeIsWord, !afterIsWord, !isAlreadyLinked, !isInsideCode(at: found.location, in: text) {
                    results.append((title: title, range: found))
                    break
                }
                let nextStart = found.location + max(found.length, 1)
                guard nextStart < nsText.length else { break }
                searchRange = NSRange(location: nextStart, length: nsText.length - nextStart)
            }
        }
        return results
    }
}

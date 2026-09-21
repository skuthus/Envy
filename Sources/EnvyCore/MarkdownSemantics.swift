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

    private static let alphanumericScalars = CharacterSet.alphanumerics

    /// Case-folds one alphanumeric run the way the case-insensitive search
    /// folds, with a fast path for the ASCII common case (bridging every
    /// short title through ICU folding was the whole per-call cost).
    private static func foldRun(_ run: String) -> String {
        if run.utf8.allSatisfy({ $0 < 128 }) { return run.lowercased() }
        return run.folding(options: .caseInsensitive, locale: nil)
    }

    /// The leading maximal alphanumeric run of `s`, folded; nil if `s` has
    /// no alphanumeric character. Same character class as isWordCharacter
    /// in suggestedLinkMatches, which is what makes the prefilter exact.
    private static func foldedFirstAlphanumericRun(of s: String) -> String? {
        var run = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if alphanumericScalars.contains(scalar) {
                run.append(scalar)
            } else if !run.isEmpty {
                break
            }
        }
        return run.isEmpty ? nil : foldRun(String(run))
    }

    /// Every maximal alphanumeric run in `s`, folded — one tight pass.
    private static func foldedAlphanumericRuns(in s: String) -> Set<String> {
        var runs = Set<String>()
        var run = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if alphanumericScalars.contains(scalar) {
                run.append(scalar)
            } else if !run.isEmpty {
                runs.insert(foldRun(String(run)))
                run.removeAll(keepingCapacity: true)
            }
        }
        if !run.isEmpty { runs.insert(foldRun(String(run))) }
        return runs
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

        // Prefilter: a whole-word match of a title implies the title's leading
        // alphanumeric run appears as a *maximal* alphanumeric run in the
        // note (the boundary rule below is exactly "non-alphanumeric on both
        // sides", and the rest of the title matches literally). So checking
        // that run against the note's set of runs is a strict superset test
        // that can never drop a real match — and it turns the O(titles × note)
        // scan (one ICU search per title in the vault, on every selection
        // change) into one pass over the note plus a handful of real
        // searches. Both sides fold the same way the search does. Measured
        // on a 4,900-note vault: 16 ms → ~2 ms for a typical note.
        let runsInText = foldedAlphanumericRuns(in: text)

        func isWordCharacter(_ character: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(character) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }

        var results: [(title: String, range: NSRange)] = []
        for rawTitle in candidateTitles {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            // A title with no alphanumeric character at all (pure
            // punctuation/emoji) can't be prefiltered; it takes the full search.
            if let run = foldedFirstAlphanumericRun(of: title), !runsInText.contains(run) { continue }
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

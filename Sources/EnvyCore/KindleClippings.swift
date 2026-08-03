import Foundation
import CryptoKit

/// Parses a Kindle's `My Clippings.txt` — the append-only plain-text file
/// every e-ink Kindle keeps of your highlights, typed notes, and bookmarks —
/// into structured records the importer can turn into fleeting notes.
///
/// Format, per record (separated by a line of ten `=`):
///
///     Book Title (Author)
///     - Your Highlight on page 92 | Location 1387-1390 | Added on ...
///     (blank line)
///     the highlighted text
///     ==========
///
/// Parsing keys off structure (the `-` metadata line, the `|` separators,
/// the numbers) rather than English words wherever possible, so a Kindle in
/// another language still yields usable records: an unrecognizable type with
/// body text is treated as a highlight rather than dropped.
public enum KindleClippings {

    public enum RecordType: Equatable, Sendable {
        case highlight
        case note
        case bookmark
    }

    public struct Record: Equatable, Sendable {
        public var book: String
        public var author: String?
        public var type: RecordType
        public var page: Int?
        public var locationStart: Int?
        public var locationEnd: Int?
        public var text: String
        /// A typed note whose location falls inside this highlight's range —
        /// Kindle stores them as separate records; pairing reunites the
        /// commentary with its passage.
        public var attachedNote: String?

        /// Stable identity for the imported-ledger: same book, same place,
        /// same words → same key, across runs and file growth. Deliberately
        /// excludes the attached note, which has its own key — a note typed
        /// *after* a highlight was imported must not make the highlight look
        /// new again.
        public var key: String {
            let position = locationStart.map(String.init) ?? page.map(String.init) ?? "?"
            let basis = "\(type == .note ? "note" : "highlight")|\(book.lowercased())|\(position)|\(text)"
            return SHA256.hash(data: Data(basis.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static let pageRegex = try! NSRegularExpression(pattern: #"page (\d+)"#, options: [.caseInsensitive])
    private static let locationRegex = try! NSRegularExpression(pattern: #"location[s]? (\d+)(?:-(\d+))?"#, options: [.caseInsensitive])

    private static func firstInt(_ regex: NSRegularExpression, group: Int, in text: String) -> Int? {
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return Int(text[range])
    }

    /// Splits `Title (Author)` — the *last* parenthetical is the author, so a
    /// title containing parens of its own survives.
    static func splitTitleLine(_ line: String) -> (book: String, author: String?) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return (trimmed, nil)
        }
        let book = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        let author = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !book.isEmpty else { return (trimmed, nil) }
        return (book, author.isEmpty ? nil : author)
    }

    /// Raw records in file order — bookmarks and empty-bodied records
    /// dropped, no collapse or pairing yet (see refine).
    static func rawRecords(from raw: String) -> [Record] {
        // Kindle writes UTF-8 with a BOM and CRLF line endings.
        let cleaned = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var records: [Record] = []
        for block in cleaned.components(separatedBy: "==========") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let titleIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            guard titleIndex + 1 < lines.count else { continue }
            let metadata = lines[titleIndex + 1].trimmingCharacters(in: .whitespaces)
            guard metadata.hasPrefix("-") else { continue }

            let lowered = metadata.lowercased()
            let type: RecordType
            if lowered.contains("bookmark") {
                type = .bookmark
            } else if lowered.contains("note") {
                type = .note
            } else {
                // "highlight", or a language we don't recognize — a body
                // below decides whether it's worth keeping either way.
                type = .highlight
            }
            if type == .bookmark { continue }

            let text = lines[(titleIndex + 2)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let (book, author) = splitTitleLine(lines[titleIndex])
            records.append(Record(
                book: book,
                author: author,
                type: type,
                page: firstInt(pageRegex, group: 1, in: metadata),
                locationStart: firstInt(locationRegex, group: 1, in: metadata),
                locationEnd: firstInt(locationRegex, group: 2, in: metadata) ?? firstInt(locationRegex, group: 1, in: metadata),
                text: text,
                attachedNote: nil
            ))
        }
        return records
    }

    /// The full parse: raw records, then three refinements. (1) Boundary-nudge
    /// collapse — adjusting a highlight's edges appends a fresh overlapping
    /// record, so among same-book highlights with intersecting location
    /// ranges only the longest text survives. (2) Autosave collapse — the
    /// Kindle saves a typed note's every-few-seconds state as its own record
    /// at the same anchor, so one note becomes a ladder of keystroke snapshots
    /// ("marc", "marc andre", …); same book + same anchor is that one note
    /// being edited, so only the last (most complete) survives. (3) Note
    /// pairing — a typed note whose location falls inside a highlight's range
    /// attaches to it; the rest stay standalone.
    public static func parse(_ raw: String) -> [Record] {
        let all = rawRecords(from: raw)
        var highlights = all.filter { $0.type == .highlight }
        let rawNotes = all.filter { $0.type == .note }

        // (1) Later duplicates replace earlier ones when longer, in place —
        // keeping first-seen order either way.
        var collapsed: [Record] = []
        for record in highlights {
            if let start = record.locationStart, let end = record.locationEnd,
               let existing = collapsed.firstIndex(where: { candidate in
                   candidate.book == record.book
                       && candidate.locationStart != nil && candidate.locationEnd != nil
                       && candidate.locationStart! <= end && candidate.locationEnd! >= start
               }) {
                if record.text.count > collapsed[existing].text.count {
                    collapsed[existing] = record
                }
            } else {
                collapsed.append(record)
            }
        }
        highlights = collapsed

        // (2) A typed note anchors to one spot (a single location, or a page
        // when the book lacks locations); the Kindle can only edit that note
        // in place, appending a new autosave record at the same anchor. So a
        // later record at the same book + anchor supersedes the earlier one,
        // in place, keeping first-seen order — the ladder collapses to its
        // final rung.
        var notes: [Record] = []
        for note in rawNotes {
            let anchor = note.locationStart ?? note.page
            if let anchor,
               let existing = notes.firstIndex(where: {
                   $0.book == note.book && ($0.locationStart ?? $0.page) == anchor
               }) {
                notes[existing] = note
            } else {
                notes.append(note)
            }
        }

        // (3)
        var standaloneNotes: [Record] = []
        for note in notes {
            if let location = note.locationStart,
               let host = highlights.firstIndex(where: { candidate in
                   candidate.book == note.book
                       && candidate.locationStart != nil && candidate.locationEnd != nil
                       && candidate.locationStart! <= location && candidate.locationEnd! >= location
               }) {
                let existing = highlights[host].attachedNote
                highlights[host].attachedNote = existing.map { $0 + "\n" + note.text } ?? note.text
            } else {
                standaloneNotes.append(note)
            }
        }
        return highlights + standaloneNotes
    }

    // MARK: - Note shaping

    /// Which locator, if any, a highlight's title carries after the quote
    /// words — the user's choice (Settings → Import). `page` and `location`
    /// each fall back to the other when the book lacks the preferred one
    /// (a Kindle highlight nearly always has a location, rarely a page), so
    /// the title is never left bare unless `none` is chosen.
    public enum TitleReference: String, CaseIterable, Sendable {
        case page, location, both, none
    }

    /// The "p92" / "loc. 210" / "p92 · loc. 210" fragment for a record under
    /// the chosen reference, or nil when there's nothing to show.
    static func referenceString(for record: Record, reference: TitleReference) -> String? {
        let page = record.page.map { "p\($0)" }
        let location = record.locationStart.map { "loc. \($0)" }
        switch reference {
        case .none: return nil
        case .page: return page ?? location
        case .location: return location ?? page
        case .both:
            let parts = [page, location].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// "first few words of the quote, p92" — the title convention. Up to
    /// `wordLimit` words, capped near 48 characters at a word boundary
    /// (one word minimum, hard-clipped if that single word is itself huge),
    /// then the chosen locator.
    public static func title(for record: Record, reference: TitleReference = .page, wordLimit: Int = 5) -> String {
        var words: [String] = []
        var length = 0
        for word in record.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if words.count >= wordLimit { break }
            if !words.isEmpty && length + word.count + 1 > 48 { break }
            words.append(String(word))
            length += word.count + (words.count > 1 ? 1 : 0)
        }
        var lead = words.joined(separator: " ")
        if lead.count > 48 { lead = String(lead.prefix(48)) }
        if lead.isEmpty { lead = "Kindle highlight" }

        guard let reference = referenceString(for: record, reference: reference) else { return lead }
        return "\(lead), \(reference)"
    }

    /// The fleeting note's body. A highlight is a blockquote with its
    /// attribution (the book as a [[link]], dimmed until a book note exists,
    /// at which point interlink: makes a per-book hub); a typed note is your
    /// own words, so it stays plain. Deliberately no auto-tag — tagging is
    /// the user's call at review time, not the importer's.
    public static func noteBody(for record: Record, includeAuthor: Bool = true, includeLocation: Bool = true) -> String {
        // Link through the same sanitizer note filenames use, so the link's
        // target matches the note you'd create by clicking it — otherwise a
        // book with a colon (most subtitles) links to "Book: Sub" while the
        // created file becomes "Book- Sub", the two never resolve, and the
        // per-book interlink: hub never forms. The book link is always
        // present (it's the hub); the author and location are the user's to
        // omit (Settings → Import).
        var attribution = "[[\(NoteStore.sanitizedBase(for: record.book))]]"
        if includeAuthor, let author = record.author { attribution += ", \(author)" }
        // "p92", matching the title's format (not "p. 92").
        if let page = record.page { attribution += " · p\(page)" }
        if includeLocation, let start = record.locationStart {
            let range = (record.locationEnd.map { $0 != start ? "\(start)-\($0)" : "\(start)" }) ?? "\(start)"
            attribution += " · loc. \(range)"
        }

        if record.type == .note {
            return "\(record.text)\n\n\(attribution)\n"
        }
        let quoted = record.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        var body = "\(quoted)\n"
        if let note = record.attachedNote {
            body += "\n**My note:** \(note)\n"
        }
        body += "\n\(attribution)\n"
        return body
    }
}

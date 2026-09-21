import Foundation

/// One open task line, still stored in its source note.
///
/// The task page is a live view over these lines. It does not copy them
/// into a new file. `marker` is the indent, bullet, and `[ ]` prefix.
/// `body` is the words after that. Writing `marker + body` back over
/// `sourceLine` is the whole edit.
public struct OpenTask: Equatable, Sendable, Identifiable {
    public let id: String
    public let noteID: String
    public let noteTitle: String
    /// Index of this open line among the note's open lines, top to bottom.
    public let ordinal: Int
    /// Which copy this is, when the note has several identical lines.
    public let occurrence: Int
    public let sourceLine: String
    public let marker: String
    public let body: String
    public let due: Date?
    /// When the note that holds this line was last saved. Lines have no
    /// time of their own, so undated lines sort by this, newest first.
    public let edited: Date

    public init(
        id: String,
        noteID: String,
        noteTitle: String,
        ordinal: Int,
        occurrence: Int,
        sourceLine: String,
        marker: String,
        body: String,
        due: Date?,
        edited: Date
    ) {
        self.id = id
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.ordinal = ordinal
        self.occurrence = occurrence
        self.sourceLine = sourceLine
        self.marker = marker
        self.body = body
        self.due = due
        self.edited = edited
    }
}

/// The `tasklist:` page: open task lines pulled out of notes the search already matched.
/// `todo:` stays a note filter. This token only switches the editor to the page.
public enum TaskPage {
    public static let queryToken = "tasklist:"
    /// Same shape the editor treats as a task, limited to an empty box.
    /// A line inside a code fence is skipped later. A checked line does not match.
    private static let openTaskRegex = try! NSRegularExpression(
        pattern: #"^(\s*(?:[-*+][ \t]+)?)(\[ \])([ \t]+.*)$"#,
        options: [.anchorsMatchLines]
    )

    /// True when a query asks for the task page. The switch is `tasklist:`.
    public static func isTaskQuery(_ query: String) -> Bool {
        for group in NoteStore.splitGroups(query) {
            for token in NoteStore.tokenize(group.lowercased()) where token == queryToken {
                return true
            }
        }
        return false
    }

    /// The query with every `tasklist:` token removed, so opening a source note
    /// leaves the other filters (`tag:work tasklist:` becomes `tag:work`).
    public static func queryByDroppingTaskOperator(_ query: String) -> String {
        NoteStore.splitGroups(query).compactMap { group in
            let kept = NoteStore.tokenize(group).filter { $0.lowercased() != queryToken }
            let joined = kept.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }.joined(separator: ", ")
    }

    public static func openTasks(in note: Note) -> [OpenTask] {
        let content = note.content
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        var tasks: [OpenTask] = []
        var seenLine: [String: Int] = [:]
        for match in openTaskRegex.matches(in: content, range: full) {
            if MarkdownSemantics.isInsideCode(at: match.range.location, in: content) { continue }
            let lineRange = ns.lineRange(for: match.range)
            var sourceLine = ns.substring(with: lineRange)
            if sourceLine.hasSuffix("\n") { sourceLine.removeLast() }
            if sourceLine.hasSuffix("\r") { sourceLine.removeLast() }

            let rest = ns.substring(with: match.range(at: 3))
            let leadCount = rest.prefix(while: { $0 == " " || $0 == "\t" }).count
            let lead = String(rest.prefix(leadCount))
            let body = String(rest.dropFirst(leadCount))
            let marker = ns.substring(with: match.range(at: 1)) + "[ ]" + lead
            let occurrence = seenLine[sourceLine, default: 0]
            seenLine[sourceLine, default: 0] += 1
            let ordinal = tasks.count
            tasks.append(OpenTask(
                id: note.id + "\n" + String(ordinal),
                noteID: note.id,
                noteTitle: note.title,
                ordinal: ordinal,
                occurrence: occurrence,
                sourceLine: sourceLine,
                marker: marker,
                body: body,
                due: dueDate(on: sourceLine),
                edited: note.modifiedDate
            ))
        }
        return tasks
    }

    /// Open lines from `notes`, narrowed by the words and `due:` in the query.
    /// `tag:` and `folder:` are already applied by whoever built `notes`.
    /// Dated lines come first, soonest first. Lines with no date come last.
    public static func lines(in notes: [Note], query: String) -> [OpenTask] {
        let groups = lineFilters(in: query).filter(\.includesTasks)
        guard !groups.isEmpty else { return [] }
        let matched = notes.flatMap { openTasks(in: $0) }.filter { task in
            groups.contains { matches($0, task: task) }
        }
        return sorted(matched)
    }

    /// Replace the `occurrence`-th whole line equal to `original`.
    /// Returns nil when that line is no longer there.
    public static func replacingLine(
        occurrence: Int,
        of original: String,
        with newLine: String,
        in content: String
    ) -> String? {
        let ns = content as NSString
        var location = 0
        var seen = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let raw = ns.substring(with: lineRange)
            var stripped = raw
            let ending: String
            if stripped.hasSuffix("\r\n") {
                ending = "\r\n"
                stripped.removeLast(2)
            } else if stripped.hasSuffix("\n") {
                ending = "\n"
                stripped.removeLast()
            } else if stripped.hasSuffix("\r") {
                ending = "\r"
                stripped.removeLast()
            } else {
                ending = ""
            }
            if stripped == original {
                if seen == occurrence {
                    return ns.replacingCharacters(in: lineRange, with: newLine + ending)
                }
                seen += 1
            }
            let next = NSMaxRange(lineRange)
            if next <= location { return nil }
            location = next
        }
        return nil
    }

    /// The same line with its first `[ ]` changed to `[x]`.
    public static func completedLine(_ sourceLine: String) -> String? {
        guard let range = sourceLine.range(of: "[ ]") else { return nil }
        var copy = sourceLine
        copy.replaceSubrange(range, with: "[x]")
        return copy
    }

    private static func dueDate(on line: String) -> Date? {
        for token in MarkdownSemantics.dueTokenRanges(in: line) where !token.isCrossedOut {
            var raw = (line as NSString).substring(with: token.range)
            if raw.hasPrefix("@") { raw.removeFirst() }
            if let date = NoteStore.resolveDueToken(raw) { return date }
        }
        return nil
    }

    private struct LineFilter {
        var includesTasks = false
        var include: [String] = []
        var exclude: [String] = []
        /// nil means this group does not constrain the date.
        /// An empty string means the line must have some date (`due:`).
        var due: String?
    }

    private static func lineFilters(in query: String) -> [LineFilter] {
        NoteStore.splitGroups(query).map { group in
            var filter = LineFilter()
            for token in NoteStore.tokenize(group) {
                let lower = token.lowercased()
                if lower == queryToken {
                    filter.includesTasks = true
                } else if lower.hasPrefix("due:") {
                    filter.due = NoteStore.unquote(String(lower.dropFirst("due:".count)))
                } else if lower.contains(":") {
                    continue
                } else if lower.hasPrefix("-"), lower.count > 1 {
                    filter.exclude.append(NoteStore.unquote(String(lower.dropFirst())))
                } else {
                    filter.include.append(NoteStore.unquote(lower))
                }
            }
            return filter
        }
    }

    private static func matches(_ filter: LineFilter, task: OpenTask) -> Bool {
        let haystack = task.body.lowercased()
        if filter.include.contains(where: { !haystack.contains($0) }) { return false }
        if filter.exclude.contains(where: { haystack.contains($0) }) { return false }
        if let due = filter.due {
            return NoteStore.taskDueMatches(task.due, filter: due)
        }
        return true
    }

    private static func sorted(_ tasks: [OpenTask]) -> [OpenTask] {
        tasks.sorted { a, b in
            switch (a.due, b.due) {
            case let (lhs?, rhs?):
                if lhs != rhs { return lhs < rhs }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            let title = a.noteTitle.localizedCaseInsensitiveCompare(b.noteTitle)
            if title != .orderedSame { return title == .orderedAscending }
            if a.ordinal != b.ordinal { return a.ordinal < b.ordinal }
            return a.noteID < b.noteID
        }
    }
}

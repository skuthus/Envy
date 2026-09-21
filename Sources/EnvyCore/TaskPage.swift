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
    /// Leading indentation of the source line in columns (space = 1, tab = 4),
    /// so a sub-task can be shown nested under its parent.
    public let indent: Int
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
        indent: Int,
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
        self.indent = indent
        self.marker = marker
        self.body = body
        self.due = due
        self.edited = edited
    }
}

/// The `tasks:` page: open task lines pulled out of notes the search already matched.
/// `todo:` stays a note filter. This token only switches the editor to the page.
public enum TaskPage {
    public static let queryToken = "tasks:"
    /// Same shape the editor treats as a task, limited to an empty box.
    /// A line inside a code fence is skipped later. A checked line does not match.
    private static let openTaskRegex = try! NSRegularExpression(
        pattern: #"^(\s*(?:[-*+][ \t]+)?)(\[ \])([ \t]+.*)$"#,
        options: [.anchorsMatchLines]
    )

    /// True when a query asks for the task page. The switch is `tasks:`.
    public static func isTaskQuery(_ query: String) -> Bool {
        for group in NoteStore.splitGroups(query) {
            for token in NoteStore.tokenize(group.lowercased()) where token == queryToken {
                return true
            }
        }
        return false
    }

    /// The query with every `tasks:` token removed, so opening a source note
    /// leaves the other filters (`tag:work tasks:` becomes `tag:work`).
    public static func queryByDroppingTaskOperator(_ query: String) -> String {
        NoteStore.splitGroups(query).compactMap { group in
            let kept = NoteStore.tokenize(group).filter { $0.lowercased() != queryToken }
            let joined = kept.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }.joined(separator: ", ")
    }

    /// Fenced-code ranges for the paragraph holding `location`, reusing a
    /// per-note set computed once — the whole-note fenced scan used to rerun
    /// for every task line, which was O(lines x content) on a note that mixes
    /// many checkboxes with a code block.
    private static func insideInlineCode(_ location: Int, ns: NSString) -> Bool {
        let clamped = min(location, ns.length)
        let paraRange = ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        let para = ns.substring(with: paraRange)
        let paraFull = NSRange(location: 0, length: (para as NSString).length)
        for m in MarkdownSemantics.inlineCodeRegex.matches(in: para, range: paraFull) {
            let doc = NSRange(location: paraRange.location + m.range.location, length: m.range.length)
            if clamped >= doc.location && clamped <= NSMaxRange(doc) { return true }
        }
        return false
    }

    public static func openTasks(in note: Note) -> [OpenTask] {
        let content = note.content
        let ns = content as NSString
        // Fast reject: the overwhelming majority of notes hold no empty
        // checkbox, so skip the regex and code scan entirely for them. This is
        // what keeps a whole-vault `tasks:` scan cheap.
        guard ns.length > 0, ns.range(of: "[ ]").location != NSNotFound else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        // The note's fenced-code ranges, computed once rather than re-scanned
        // per matched line. Empty when the note has no fence at all.
        let fenced: [NSRange] = ns.range(of: "```").location == NSNotFound
            ? []
            : MarkdownSemantics.fencedCodeBlockRegex.matches(in: content, range: full).map(\.range)
        // Inline `code` can only hide a checkbox in a note that has a backtick
        // at all, which most don't — skip the per-line paragraph scan otherwise.
        let hasBacktick = ns.range(of: "`").location != NSNotFound
        var tasks: [OpenTask] = []
        var seenLine: [String: Int] = [:]
        for match in openTaskRegex.matches(in: content, range: full) {
            let loc = match.range.location
            if fenced.contains(where: { loc >= $0.location && loc <= NSMaxRange($0) }) { continue }
            if hasBacktick, insideInlineCode(loc, ns: ns) { continue }
            let lineRange = ns.lineRange(for: match.range)
            var sourceLine = ns.substring(with: lineRange)
            if sourceLine.hasSuffix("\n") { sourceLine.removeLast() }
            if sourceLine.hasSuffix("\r") { sourceLine.removeLast() }

            let group1 = ns.substring(with: match.range(at: 1))
            var indent = 0
            for ch in group1 {
                if ch == " " { indent += 1 }
                else if ch == "\t" { indent += 4 }
                else { break }
            }
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
                indent: indent,
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

    /// The leading whitespace and bullet ("- ", "* ", "+ ", or "") of a task
    /// line, so a new sibling or child can copy them.
    private static func leadAndBullet(of line: String) -> (lead: String, bullet: String) {
        let ns = line as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 32 || c == 9 { i += 1 } else { break }   // space or tab
        }
        let lead = ns.substring(to: i)
        var bullet = ""
        if i < ns.length {
            let c = ns.character(at: i)
            if c == 45 || c == 42 || c == 43 { bullet = String(UnicodeScalar(c)!) + " " }  // - * +
        }
        return (lead, bullet)
    }

    /// The empty child task line to add under `parent`: one 4-space level
    /// deeper (the editor's own list-indent unit), carrying the parent's bullet
    /// style. Body is left empty for the caller to fill in.
    public static func subtaskLine(under parent: String) -> String {
        let p = leadAndBullet(of: parent)
        return p.lead + "    " + p.bullet + "[ ] "
    }

    /// The empty sibling task line to add beside `sibling`: same indentation
    /// and bullet, empty body.
    public static func siblingLine(of sibling: String) -> String {
        let p = leadAndBullet(of: sibling)
        return p.lead + p.bullet + "[ ] "
    }

    /// Insert `newLine` as its own line immediately after the `occurrence`-th
    /// line equal to `original`. Returns nil when that line isn't there.
    public static func insertingLine(
        after original: String,
        occurrence: Int,
        newLine: String,
        in content: String
    ) -> String? {
        let ns = content as NSString
        var location = 0
        var seen = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            var stripped = ns.substring(with: lineRange)
            let ending: String
            if stripped.hasSuffix("\r\n") { ending = "\r\n"; stripped.removeLast(2) }
            else if stripped.hasSuffix("\n") { ending = "\n"; stripped.removeLast() }
            else if stripped.hasSuffix("\r") { ending = "\r"; stripped.removeLast() }
            else { ending = "" }
            if stripped == original {
                if seen == occurrence {
                    let insertAt = NSMaxRange(lineRange)
                    // If the parent is the final line with no newline, terminate
                    // it before adding the child; otherwise slot the child in
                    // right after the parent's own line ending.
                    let insertion = ending.isEmpty ? "\n" + newLine + "\n" : newLine + ending
                    return ns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: insertion)
                }
                seen += 1
            }
            let next = NSMaxRange(lineRange)
            if next <= location { return nil }
            location = next
        }
        return nil
    }

    private static func dueDate(on line: String) -> Date? {
        guard (line as NSString).range(of: "@").location != NSNotFound else { return nil }
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
            // Neither is dated: newest-edited note first, matching the page's
            // own "No date" grouping so the view never has to re-sort the
            // default arrangement it receives.
            if a.edited != b.edited { return a.edited > b.edited }
            if a.noteTitle != b.noteTitle {
                return a.noteTitle.localizedCaseInsensitiveCompare(b.noteTitle) == .orderedAscending
            }
            if a.ordinal != b.ordinal { return a.ordinal < b.ordinal }
            return a.noteID < b.noteID
        }
    }
}

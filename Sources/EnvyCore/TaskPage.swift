import Foundation

/// A note's id as a key that stays cheap at scale. The task page groups,
/// diffs, and refreshes thousands of rows by their note on every change, and
/// String's own hashing and == normalize Unicode first — on long non-ASCII
/// paths (one em dash in a title is enough) that made those passes the page's
/// main cost. This hashes the UTF-8 bytes once, when the note is scanned, and
/// compares by that hash and then the bytes. Byte equality is exact here:
/// every row of a note carries the very same id string.
public struct NoteKey: Hashable, Sendable {
    public let id: String
    private let hash: Int

    public init(_ id: String) {
        var native = id
        var hasher = Hasher()
        native.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        self.id = native
        hash = hasher.finalize()
    }

    public static func == (a: NoteKey, b: NoteKey) -> Bool {
        a.hash == b.hash && a.id.utf8.elementsEqual(b.id.utf8)
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(hash) }
}

/// A task row's identity: its note and its ordinal there, neither of which a
/// check or a text edit changes.
public struct TaskID: Hashable, Sendable {
    public let note: NoteKey
    public let ordinal: Int

    public static func == (a: TaskID, b: TaskID) -> Bool {
        a.ordinal == b.ordinal && a.note == b.note
    }
}

/// One open task line, still stored in its source note.
///
/// The task page is a live view over these lines. It does not copy them
/// into a new file. `marker` is the indent, bullet, and `[ ]` prefix.
/// `body` is the words after that. Writing `marker + body` back over
/// `sourceLine` is the whole edit.
public struct OpenTask: Equatable, Sendable, Identifiable {
    public let id: TaskID
    public let noteID: String
    public let noteTitle: String
    /// Index of this line among all the note's task lines (open and checked),
    /// top to bottom. A check or a text edit doesn't move it, so it anchors
    /// the row's id.
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
    /// Whether this line is a checked task ([x]) rather than an open one ([ ]).
    public let isCompleted: Bool
    /// When the note that holds this line was last saved. Lines have no
    /// time of their own, so undated lines sort by this, newest first.
    public let edited: Date

    public init(
        id: TaskID,
        noteID: String,
        noteTitle: String,
        ordinal: Int,
        occurrence: Int,
        sourceLine: String,
        indent: Int,
        marker: String,
        body: String,
        due: Date?,
        isCompleted: Bool,
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
        self.isCompleted = isCompleted
        self.edited = edited
    }

    public var noteKey: NoteKey { id.note }

    /// Field by field, cheapest first and strings by their bytes: the page
    /// compares its whole list (thousands of rows) on every rescan, and
    /// String's == normalizes Unicode on every non-ASCII compare. `noteID` is
    /// covered by `id`, and `marker`/`body` are cut from `sourceLine`, so equal
    /// source lines mean those are equal too.
    public static func == (a: OpenTask, b: OpenTask) -> Bool {
        a.id == b.id
            && a.isCompleted == b.isCompleted
            && a.occurrence == b.occurrence
            && a.indent == b.indent
            && a.due == b.due
            && a.edited == b.edited
            && a.sourceLine.utf8.elementsEqual(b.sourceLine.utf8)
            && a.noteTitle.utf8.elementsEqual(b.noteTitle.utf8)
    }
}

/// The `tasks:` page: open task lines pulled out of notes the search already matched.
/// `todo:` stays a note filter. This token only switches the editor to the page.
public enum TaskPage {
    public static let queryToken = "tasks:"
    /// Same shape the editor treats as a task, open ([ ]) or checked ([x]/[X]).
    /// A line inside a code fence is skipped later. Indentation is spaces and
    /// tabs only — `\s` would also match line breaks, letting a task under a
    /// blank line start its match on that blank line and carry a leading "\n"
    /// into its source line, which then matches no line of the note and can
    /// never be checked or edited.
    private static let openTaskRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:[-*+][ \t]+)?)(\[[ xX]\])([ \t]+.*)$"#,
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

    /// Every task line in the note — open and checked — in document order.
    private static func scanTasks(in note: Note) -> [OpenTask] {
        let content = note.content
        let ns = content as NSString
        // Fast reject: a note with no checkbox at all skips the regex and code
        // scan entirely — what keeps a whole-vault scan cheap.
        guard ns.length > 0,
              ns.range(of: "[ ]").location != NSNotFound
              || ns.range(of: "[x]").location != NSNotFound
              || ns.range(of: "[X]").location != NSNotFound
        else { return [] }
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
        let key = NoteKey(note.id)
        var title = note.title
        title.makeContiguousUTF8()
        for match in openTaskRegex.matches(in: content, range: full) {
            let loc = match.range.location
            if fenced.contains(where: { loc >= $0.location && loc <= NSMaxRange($0) }) { continue }
            if hasBacktick, insideInlineCode(loc, ns: ns) { continue }
            let lineRange = ns.lineRange(for: match.range)
            var sourceLine = ns.substring(with: lineRange)
            if sourceLine.hasSuffix("\n") { sourceLine.removeLast() }
            if sourceLine.hasSuffix("\r") { sourceLine.removeLast() }
            // Native UTF-8, so the page's byte compares of it stay fast.
            sourceLine.makeContiguousUTF8()

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
            let box = ns.substring(with: match.range(at: 2))
            let marker = ns.substring(with: match.range(at: 1)) + box + lead
            let occurrence = seenLine[sourceLine, default: 0]
            seenLine[sourceLine, default: 0] += 1
            let ordinal = tasks.count
            tasks.append(OpenTask(
                id: TaskID(note: key, ordinal: ordinal),
                noteID: note.id,
                noteTitle: title,
                ordinal: ordinal,
                occurrence: occurrence,
                sourceLine: sourceLine,
                indent: indent,
                marker: marker,
                body: body,
                due: dueDate(on: sourceLine),
                isCompleted: box != "[ ]",
                edited: note.modifiedDate
            ))
        }
        return tasks
    }

    /// `lines` with one note's rows re-read from that note's current text, for
    /// showing a write from the page the instant it lands instead of after the
    /// whole-vault rescan. Rows are matched by id (note + ordinal, which a
    /// check or a text edit never moves), so every row keeps its place in the
    /// list and picks up the note's exact line, box, and occurrence. A row the
    /// note no longer has, or that is now hidden (checked, with completed
    /// off), drops out. Lines from other notes pass through untouched.
    public static func refreshing(_ lines: [OpenTask], from note: Note, includeCompleted: Bool) -> [OpenTask] {
        let fresh = scanTasks(in: note)
        let key = NoteKey(note.id)
        return lines.compactMap { line in
            guard line.noteKey == key else { return line }
            let ordinal = line.id.ordinal
            guard ordinal < fresh.count, includeCompleted || !fresh[ordinal].isCompleted else { return nil }
            return fresh[ordinal]
        }
    }

    /// `fresh` (a rescan) in the order `previous` (what's on screen) already
    /// shows, so a rescan never moves rows under the cursor. A check or an edit
    /// saves the note, and the new edited date alone would float an undated
    /// note's whole section to the top. A row new since `previous` goes just
    /// after the row before it in `fresh` that was already on screen — its own
    /// note's previous line, for a new subtask or an appended task. Rows gone
    /// since drop out.
    public static func stabilized(_ fresh: [OpenTask], toOrderOf previous: [OpenTask]) -> [OpenTask] {
        guard !previous.isEmpty, !fresh.isEmpty else { return fresh }
        var rank: [TaskID: Int] = [:]
        rank.reserveCapacity(previous.count)
        for (i, task) in previous.enumerated() { rank[task.id] = i }
        var key = [Double](repeating: 0, count: fresh.count)
        var previousRank = -1.0
        for i in fresh.indices {
            if let r = rank[fresh[i].id] {
                key[i] = Double(r)
                previousRank = Double(r)
            } else {
                key[i] = previousRank + 0.5
            }
        }
        return fresh.indices
            .sorted { key[$0] != key[$1] ? key[$0] < key[$1] : $0 < $1 }
            .map { fresh[$0] }
    }

    /// Only the open ([ ]) task lines — the default the page shows and what the
    /// "has tasks" checks want.
    public static func openTasks(in note: Note) -> [OpenTask] {
        scanTasks(in: note).filter { !$0.isCompleted }
    }

    /// Open and checked lines both — for the page's "Show completed" mode.
    public static func allTasks(in note: Note) -> [OpenTask] {
        scanTasks(in: note)
    }

    /// The same line with its checkbox flipped: open becomes checked, checked
    /// becomes open. nil when there's no checkbox to flip.
    public static func toggledLine(_ line: String) -> String? {
        if let r = line.range(of: "[ ]") { var c = line; c.replaceSubrange(r, with: "[x]"); return c }
        if let r = line.range(of: "[x]") { var c = line; c.replaceSubrange(r, with: "[ ]"); return c }
        if let r = line.range(of: "[X]") { var c = line; c.replaceSubrange(r, with: "[ ]"); return c }
        return nil
    }

    /// Open lines from `notes`, narrowed by the words and `due:` in the query.
    /// `tag:` and `folder:` are already applied by whoever built `notes`.
    /// Dated lines come first, soonest first. Lines with no date come last.
    public static func lines(in notes: [Note], query: String, includeCompleted: Bool = false) -> [OpenTask] {
        let groups = lineFilters(in: query).filter(\.includesTasks)
        guard !groups.isEmpty else { return [] }
        let matched = notes.flatMap { includeCompleted ? allTasks(in: $0) : openTasks(in: $0) }.filter { task in
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

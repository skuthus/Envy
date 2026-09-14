import Foundation

/// GFM pipe-table support: detect a `| header |` / `| --- |` / `| cell |`
/// block, split its cells, and serialize a table back to pipes.
///
/// Envy never rewrites a table into HTML — the file always holds the pipes.
/// The styler renders a table as a grid when the caret is outside its block and
/// shows the raw pipes when it is inside; this type is the parser plus the pure
/// string transforms both sides share. Everything here is offset-correct against
/// `NSString` (UTF-16), so the ranges it returns line up with the text storage
/// the editor mutates.
///
/// Ported from Envy-Universal's `src/tables.ts`, which is the same feature on a
/// CodeMirror substrate — the grammar is deliberately kept identical so a table
/// authored in one app renders in the other.
public enum TableCellAlign: Sendable, Equatable {
    case left, center, right
}

/// One parsed table: its whole-block character range plus the cell contents.
public struct PipeTableBlock: Sendable, Equatable {
    /// The block's character range, from the header line's start to the start
    /// of the line after the block (or the document end). Whole lines, so the
    /// styler can claim and height-reserve it as one unit — the same shape the
    /// embed spacer line uses.
    public let range: NSRange
    /// Header cells, trimmed.
    public let header: [String]
    /// One alignment per column, read from the delimiter row.
    public let aligns: [TableCellAlign]
    /// Body rows (delimiter rows excluded), each trimmed.
    public let rows: [[String]]
    /// The block's source text, exactly as it sits in the document.
    public let source: String

    public init(range: NSRange, header: [String], aligns: [TableCellAlign], rows: [[String]], source: String) {
        self.range = range
        self.header = header
        self.aligns = aligns
        self.rows = rows
        self.source = source
    }
}

public enum PipeTable {
    private static let pipe: unichar = 124        // |
    private static let backslash: unichar = 92    // \
    private static let backtick: unichar = 96     // `
    private static let openBracket: unichar = 91  // [
    private static let closeBracket: unichar = 93 // ]

    // MARK: - Scanning

    /// The index just past a protected span starting at `i` — the contents of a
    /// `[[wiki|alias]]` or `` `code` `` never count as structural pipes — or `i`
    /// itself when nothing is protected there.
    private static func skipProtected(_ s: NSString, _ i: Int) -> Int {
        let len = s.length
        if s.character(at: i) == openBracket, i + 1 < len, s.character(at: i + 1) == openBracket {
            let rest = NSRange(location: i + 2, length: len - (i + 2))
            let end = s.range(of: "]]", options: [], range: rest)
            if end.location != NSNotFound { return end.location + end.length }
        }
        if s.character(at: i) == backtick {
            let rest = NSRange(location: i + 1, length: len - (i + 1))
            let end = s.range(of: "`", options: [], range: rest)
            if end.location != NSNotFound { return end.location + end.length }
        }
        return i
    }

    /// The UTF-16 offsets of the structural `|` characters on one line — pipes
    /// that split cells, skipping escaped `\|` and pipes inside protected spans.
    public static func structuralPipes(in line: String) -> [Int] {
        let s = line as NSString
        var out: [Int] = []
        var i = 0
        while i < s.length {
            let skip = skipProtected(s, i)
            if skip > i { i = skip; continue }
            let c = s.character(at: i)
            if c == backslash, i + 1 < s.length, s.character(at: i + 1) == pipe {
                i += 2
                continue
            }
            if c == pipe { out.append(i) }
            i += 1
        }
        return out
    }

    /// A line that can belong to a pipe table: starts with `|` (after any
    /// indent) and holds at least two structural pipes, so a lone `|` is not one.
    public static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "|" else { return false }
        return structuralPipes(in: line).count >= 2
    }

    /// The delimiter row: `| --- | :---: | ---: |`.
    public static func isTableSep(_ line: String) -> Bool {
        guard isTableLine(line) else { return false }
        let cells = splitCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return isSeparatorCell(t)
        }
    }

    private static func isSeparatorCell(_ t: String) -> Bool {
        // `:?-{3,}:?` — optional leading/trailing colon, at least three dashes.
        var chars = Array(t)
        guard !chars.isEmpty else { return false }
        if chars.first == ":" { chars.removeFirst() }
        if chars.last == ":" { chars.removeLast() }
        guard chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == "-" }
    }

    /// The cells of a table line, outer pipes stripped. `\|` and pipes inside
    /// `[[wiki|alias]]` or `` `code` `` are not splits. Cells are returned
    /// untrimmed — callers trim where they need to, matching the reference.
    public static func splitCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        let s = trimmed as NSString
        var cells: [String] = []
        var cur = ""
        var i = 0
        while i < s.length {
            let skip = skipProtected(s, i)
            if skip > i {
                cur += s.substring(with: NSRange(location: i, length: skip - i))
                i = skip
                continue
            }
            let c = s.character(at: i)
            if c == backslash, i + 1 < s.length, s.character(at: i + 1) == pipe {
                cur += "|"
                i += 2
                continue
            }
            if c == pipe {
                cells.append(cur)
                cur = ""
                i += 1
                continue
            }
            cur += s.substring(with: NSRange(location: i, length: 1))
            i += 1
        }
        cells.append(cur)
        return cells
    }

    private static func alignOf(_ cell: String) -> TableCellAlign {
        let t = cell.trimmingCharacters(in: .whitespaces)
        let left = t.hasPrefix(":")
        let right = t.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        return .left
    }

    // MARK: - Cell ranges (for Tab / Shift-Tab navigation)

    /// The content range of every cell on one table line, as UTF-16 offsets
    /// *relative to the line's start*, trimmed of surrounding whitespace.
    ///
    /// Only a pipe that begins a cell counts, so the closing pipe never opens a
    /// phantom trailing cell (which is how Tab used to walk off the end of a
    /// row). A line written without its closing pipe (`| a | b`) still ends in a
    /// cell, so the tail past the last pipe counts when it holds anything. An
    /// empty cell's range is a caret one space in from its opening pipe, where
    /// the `| x |` padding convention puts the content.
    public static func cellContentRanges(in line: String) -> [NSRange] {
        let s = line as NSString
        let pipes = structuralPipes(in: line)
        guard !pipes.isEmpty else { return [] }
        var spans: [(Int, Int)] = []
        for i in 0..<(pipes.count - 1) {
            spans.append((pipes[i] + 1, pipes[i + 1]))
        }
        let tail = pipes[pipes.count - 1] + 1
        if tail <= s.length {
            let tailText = s.substring(with: NSRange(location: tail, length: s.length - tail))
            if !tailText.trimmingCharacters(in: .whitespaces).isEmpty {
                spans.append((tail, s.length))
            }
        }
        return spans.map { start, end in
            var from = start
            var to = end
            while from < to, isWhitespace(s.character(at: from)) { from += 1 }
            while to > from, isWhitespace(s.character(at: to - 1)) { to -= 1 }
            if from == to { from = min(start + 1, end); to = from }
            return NSRange(location: from, length: to - from)
        }
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        c == 32 || c == 9 // space or tab
    }

    // MARK: - Serialising back to pipes

    /// Escapes a cell for a pipe row: a structural `|` becomes `\|`, and any
    /// line break collapses to a space (a cell is one line by construction).
    /// A pipe already escaped, or one inside a protected span, is left as-is.
    public static func escapeTableCell(_ cell: String) -> String {
        let pipes = structuralPipes(in: cell)
        let s = cell as NSString
        var out = ""
        var last = 0
        for rel in pipes {
            out += s.substring(with: NSRange(location: last, length: rel - last)) + "\\|"
            last = rel + 1
        }
        out += s.substring(with: NSRange(location: last, length: s.length - last))
        return out.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// One row's source line, with the single-space padding a hand-written table
    /// has: `| a | b |`. Cells are trimmed here, so the padding is ours.
    public static func serializeTableRow(_ cells: [String]) -> String {
        "| " + cells.map { escapeTableCell($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: " | ") + " |"
    }

    private static func separatorCell(_ align: TableCellAlign, width: Int) -> String {
        let colons = align == .center ? 2 : (align == .left ? 0 : 1)
        let dashes = String(repeating: "-", count: max(3, width - colons))
        switch align {
        case .center: return ":\(dashes):"
        case .right: return "\(dashes):"
        case .left: return dashes
        }
    }

    public static func serializeSeparatorRow(_ aligns: [TableCellAlign]) -> String {
        "| " + aligns.map { separatorCell($0, width: 3) }.joined(separator: " | ") + " |"
    }

    /// A whole block's source from its parts. `trailingNewline` mirrors the
    /// block it replaces: a table mid-note ends with one, a table at the very
    /// end of the file does not.
    public static func serializeTable(header: [String], aligns: [TableCellAlign], rows: [[String]], trailingNewline: Bool) -> String {
        var lines = [serializeTableRow(header), serializeSeparatorRow(aligns)]
        for row in rows { lines.append(serializeTableRow(row)) }
        return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    /// A fresh empty row of `cols` cells (never fewer than two), padded the way
    /// a hand-written table pads: `|  |  |`.
    public static func emptyRow(cols: Int) -> String {
        let n = max(2, cols)
        return "| " + Array(repeating: " ", count: n).joined(separator: "| ") + "|"
    }

    /// A fresh 2×2 skeleton: two named columns and one empty row. Its header is
    /// selected on insert so the first thing typed replaces it.
    public static let skeleton = "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |"
    public static let skeletonFirstHeader = "Column 1"

    /// Re-pads a block so the pipes line up: every column as wide as its widest
    /// cell, the delimiter row widened to match while keeping its colons and at
    /// least three dashes. Ragged rows are filled out to the column count.
    /// Cosmetic — the parser does not care — so it runs once on the way out of a
    /// table rather than on every keystroke.
    public static func padTableSource(_ src: String) -> String {
        let trailing = src.hasSuffix("\n") ? "\n" : ""
        let body = trailing.isEmpty ? src : String(src.dropLast())
        let lines = body.components(separatedBy: "\n")
        guard !lines.isEmpty else { return src }
        let indent = String(lines[0].prefix(while: { $0 == " " || $0 == "\t" }))
        let parsed = lines.map { line -> (sep: Bool, cells: [String]) in
            (isTableSep(line), splitCells(line).map { $0.trimmingCharacters(in: .whitespaces) })
        }
        let cols = parsed.map { $0.cells.count }.max() ?? 0
        let sepRow = parsed.first { $0.sep }
        let aligns: [TableCellAlign] = (0..<cols).map { i in
            alignOf(sepRow?.cells[safe: i] ?? "---")
        }
        // `:---` and `---` both mean left; the marker is remembered so it isn't
        // silently normalised away under the cursor.
        let explicitLeft: [Bool] = (0..<cols).map { i in
            aligns[i] == .left && (sepRow?.cells[safe: i]?.hasPrefix(":") ?? false)
        }
        var widths: [Int] = (0..<cols).map { i in
            aligns[i] == .center ? 5 : (aligns[i] == .right || explicitLeft[i] ? 4 : 3)
        }
        for row in parsed where !row.sep {
            for i in 0..<cols {
                let cell = escapeTableCell(row.cells[safe: i] ?? "")
                widths[i] = max(widths[i], cell.count)
            }
        }
        let out = parsed.map { row -> String in
            let cells: [String]
            if row.sep {
                cells = (0..<cols).map { i in
                    explicitLeft[i]
                        ? ":" + String(repeating: "-", count: max(3, widths[i] - 1))
                        : separatorCell(aligns[i], width: widths[i])
                }
            } else {
                cells = (0..<cols).map { i in
                    let cell = escapeTableCell(row.cells[safe: i] ?? "")
                    return cell + String(repeating: " ", count: max(0, widths[i] - cell.count))
                }
            }
            return indent + "| " + cells.joined(separator: " | ") + " |"
        }
        return out.joined(separator: "\n") + trailing
    }

    // MARK: - Structural edits (add / delete row or column)

    /// A structural change to a table, addressed in the same row/column
    /// numbering the rendered grid uses: DOM row 0 is the header, row k is
    /// `rows[k-1]`, and columns are zero-based left to right.
    public enum TableEdit: Sendable, Equatable {
        case insertRowAbove(row: Int)
        case insertRowBelow(row: Int)
        case deleteRow(row: Int)
        case insertColumnLeft(col: Int)
        case insertColumnRight(col: Int)
        case deleteColumn(col: Int)
    }

    /// Applies a structural edit to a table and returns its new, re-padded
    /// source, or nil when the edit doesn't apply (deleting the header row or a
    /// table's only column, inserting above the header). `trailingNewline`
    /// mirrors the block being replaced so the result drops back into the
    /// document without disturbing the line after it.
    public static func apply(_ edit: TableEdit, to block: PipeTableBlock, trailingNewline: Bool) -> String? {
        let cols = max(block.header.count, block.aligns.count, block.rows.map(\.count).max() ?? 0)
        guard cols > 0 else { return nil }
        func fit(_ row: [String]) -> [String] { row + Array(repeating: "", count: max(0, cols - row.count)) }
        var header = fit(block.header)
        var aligns = block.aligns
        while aligns.count < cols { aligns.append(.left) }
        aligns = Array(aligns.prefix(cols))
        var rows = block.rows.map(fit)
        let emptyRow = Array(repeating: "", count: cols)

        switch edit {
        case .insertRowAbove(let row):
            guard row >= 1 else { return nil } // nothing sits above the header
            rows.insert(emptyRow, at: min(row - 1, rows.count))
        case .insertRowBelow(let row):
            guard row >= 0 else { return nil }
            rows.insert(emptyRow, at: min(row, rows.count))
        case .deleteRow(let row):
            guard row >= 1, row - 1 < rows.count else { return nil } // the header stays
            rows.remove(at: row - 1)
        case .insertColumnLeft(let col):
            insertColumn(at: col, &header, &aligns, &rows)
        case .insertColumnRight(let col):
            insertColumn(at: col + 1, &header, &aligns, &rows)
        case .deleteColumn(let col):
            guard cols > 1, col >= 0, col < cols else { return nil }
            header.remove(at: col)
            aligns.remove(at: col)
            rows = rows.map { row in
                var r = row
                if col < r.count { r.remove(at: col) }
                return r
            }
        }
        return padTableSource(serializeTable(header: header, aligns: aligns, rows: rows, trailingNewline: trailingNewline))
    }

    private static func insertColumn(at index: Int, _ header: inout [String], _ aligns: inout [TableCellAlign], _ rows: inout [[String]]) {
        header.insert("", at: min(max(0, index), header.count))
        aligns.insert(.left, at: min(max(0, index), aligns.count))
        rows = rows.map { row in
            var r = row
            r.insert("", at: min(max(0, index), r.count))
            return r
        }
    }

    // MARK: - Block detection

    /// Every pipe-table block in `text`, in document order. A block is a run of
    /// table lines that contains a delimiter row after its header; a table
    /// inside a ``` fence is source, not a table, and is skipped.
    public static func tableBlocks(in text: String) -> [PipeTableBlock] {
        let nsText = text as NSString
        // Cheap reject: no pipe at all means no table. Most notes skip the scan.
        guard nsText.range(of: "|").location != NSNotFound else { return [] }

        // Break the document into whole-line ranges (each includes its own
        // trailing newline), so line N's start is line N-1's end.
        var lineRanges: [NSRange] = []
        var idx = 0
        while idx < nsText.length {
            let r = nsText.lineRange(for: NSRange(location: idx, length: 0))
            lineRanges.append(r)
            idx = r.location + r.length
        }
        guard !lineRanges.isEmpty else { return [] }

        func content(_ i: Int) -> String {
            let r = lineRanges[i]
            let s = nsText.substring(with: r)
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        }

        var out: [PipeTableBlock] = []
        var n = 0
        var inFence = false
        let lastLine = lineRanges.count - 1
        while n <= lastLine {
            let text = content(n)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                n += 1
                continue
            }
            if inFence || !isTableLine(text) {
                n += 1
                continue
            }
            var end = n
            while end < lastLine {
                let next = content(end + 1)
                if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") || !isTableLine(next) { break }
                end += 1
            }
            var sep = -1
            for i in n...end where isTableSep(content(i)) {
                sep = i
                break
            }
            if sep > n {
                let header = splitCells(content(n)).map { $0.trimmingCharacters(in: .whitespaces) }
                let aligns = splitCells(content(sep)).map { alignOf($0) }
                var rows: [[String]] = []
                for i in (sep + 1)...end where i <= end {
                    if isTableSep(content(i)) { continue }
                    rows.append(splitCells(content(i)).map { $0.trimmingCharacters(in: .whitespaces) })
                }
                let from = lineRanges[n].location
                let to = lineRanges[end].location + lineRanges[end].length
                let range = NSRange(location: from, length: to - from)
                out.append(PipeTableBlock(
                    range: range,
                    header: header,
                    aligns: aligns,
                    rows: rows,
                    source: nsText.substring(with: range)
                ))
            }
            n = end + 1
        }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import SwiftUI
import AppKit
import EnvyCore

/// The rendered, *editable* form of a GFM pipe table. A table always shows as a
/// drawn grid — the pipe source is the on-disk format, never something the
/// person edits by hand — and typing happens directly in the cells. The grid
/// owns an editable model while it has focus; it writes the table back to the
/// document (as pipes) when focus leaves it, and structural changes (add/delete
/// row or column, from the right-click menu) write back immediately.
///
/// Its measured height is reported back so MarkdownStyler can reserve exactly
/// that much room across the block's source lines — the same measurement loop
/// EmbeddedNoteView uses.
struct TableWidgetView: View {
    /// The table's current pipe source, the identity the coordinator finds the
    /// block by. The model re-syncs from this when it changes under a grid that
    /// isn't being edited (undo, an external edit, a structural change).
    let source: String
    /// Whether the block ends in a newline, so the rewritten source drops back
    /// into the document without disturbing the line after it.
    let hasTrailingNewline: Bool
    var theme: Theme
    /// The editor's current base point size (theme size + zoom).
    var fontSize: CGFloat
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    /// Writes the table back to the document as pipes.
    var onEdit: (String) -> Void = { _ in }

    @State private var model: EditableTable
    @FocusState private var focused: CellID?
    /// Cancels a pending blur-commit when focus returns to another cell during
    /// Tab/Enter navigation, so moving between cells isn't a write per hop.
    @State private var blurCommit: Task<Void, Never>?

    init(
        source: String,
        hasTrailingNewline: Bool,
        theme: Theme,
        fontSize: CGFloat,
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in },
        onEdit: @escaping (String) -> Void = { _ in }
    ) {
        self.source = source
        self.hasTrailingNewline = hasTrailingNewline
        self.theme = theme
        self.fontSize = fontSize
        self.onContentHeightChange = onContentHeightChange
        self.onEdit = onEdit
        _model = State(initialValue: EditableTable.parse(source))
    }

    private var columnCount: Int { model.columnCount }
    private var rowCount: Int { 1 + model.rows.count }
    private var borderColor: Color { Color(nsColor: theme.resolvedMarkerColor).opacity(0.8) }
    private var textColor: Color { Color(nsColor: theme.resolvedTextColor) }

    // Cells size to their content: each column is as wide as its widest cell,
    // recomputed as the model changes so a column grows while you type — up to a
    // cap, past which the text wraps to another line inside the cell instead.
    private var hPad: CGFloat { fontSize * 0.7 }
    private var vPad: CGFloat { fontSize * 0.45 }
    private var minColumnWidth: CGFloat { fontSize * 3 }
    private var maxColumnWidth: CGFloat { fontSize * 22 }

    var body: some View {
        let widths = columnWidths()
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(row: row, column: column, width: widths[safe: column] ?? minColumnWidth)
                    }
                }
                // The row is as tall as its tallest (wrapped) cell; the cells
                // stretch to fill it so their borders line up.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        // Content-width, pinned to the left of the text column rather than
        // stretched across it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TableHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(TableHeightKey.self) { onContentHeightChange($0) }
        // Re-sync from the document when the source changes under a grid that
        // isn't being edited (undo, an edit elsewhere). While a cell is focused
        // the model is the truth, so an in-flight edit is never clobbered.
        .onChange(of: source) { _, newValue in
            guard focused == nil else { return }
            model = EditableTable.parse(newValue)
        }
        .onChange(of: focused) { _, newValue in
            if newValue == nil {
                scheduleBlurCommit()
            } else {
                blurCommit?.cancel()
                blurCommit = nil
            }
        }
    }

    @ViewBuilder
    private func cell(row: Int, column: Int, width: CGFloat) -> some View {
        let isHeader = row == 0
        let align = model.aligns[safe: column] ?? .left
        // One field type throughout — always multi-line, so a value that
        // reaches the column's width cap wraps onto another line in place, with
        // no swap that would interrupt an in-progress edit. Below the cap the
        // column simply grows; the generous per-cell width slack (see
        // textWidth) keeps the field a step wider than its text so a single
        // keystroke never momentarily overflows and sticks a wrap.
        TextField("", text: binding(row: row, column: column), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .font(.system(size: fontSize).weight(isHeader ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(textColor)
            .multilineTextAlignment(textAlignment(align))
            .focused($focused, equals: CellID(row: row, column: column))
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .frame(width: width, alignment: frameAlignment(align))
            // Fill the row's height (set by its tallest cell) so borders align.
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(Rectangle().stroke(borderColor, lineWidth: 1))
            .contentShape(Rectangle())
            .onKeyPress(phases: .down) { press in handleKey(press, row: row, column: column) }
            .contextMenu { cellMenu(row: row, column: column) }
    }

    /// Each column's width: its widest cell's content (header included) plus
    /// padding, clamped between a floor and a cap. Purely a function of the text
    /// and the font — no dependence on the editor's laid-out width — so it is
    /// correct on the very first render. A cell longer than the cap wraps.
    private func columnWidths() -> [CGFloat] {
        let cols = columnCount
        guard cols > 0 else { return [] }
        var widths = [CGFloat](repeating: minColumnWidth, count: cols)
        for col in 0..<cols {
            widths[col] = max(widths[col], textWidth(model.cell(0, col), bold: true) + hPad * 2)
            for r in 0..<model.rows.count {
                widths[col] = max(widths[col], textWidth(model.cell(r + 1, col), bold: false) + hPad * 2)
            }
            widths[col] = min(widths[col], maxColumnWidth)
        }
        return widths
    }

    private func textWidth(_ text: String, bold: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        // Two characters of slack past the measured text: an empty cell still
        // has room to click into, and — the load-bearing reason — the frame
        // stays wide enough that the next keystroke's optimistic render fits
        // before the width recomputes, so the multi-line field never flickers a
        // wrap that then sticks for the rest of the edit.
        let measured = ((text.isEmpty ? "M" : text) as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured) + ceil(fontSize * 1.6)
    }

    private func binding(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: { model.cell(row, column) },
            set: { model.setCell(row, column, $0) }
        )
    }

    // MARK: - Keyboard navigation

    private func handleKey(_ press: KeyPress, row: Int, column: Int) -> KeyPress.Result {
        switch press.key {
        case .tab:
            move(from: CellID(row: row, column: column), forward: !press.modifiers.contains(.shift))
            return .handled
        case .return:
            moveDown(from: CellID(row: row, column: column))
            return .handled
        default:
            return .ignored
        }
    }

    /// Tab / Shift-Tab through cells in reading order. Off the last cell,
    /// forwards, a fresh row is added and its first cell focused; before the
    /// first cell, backwards, focus simply stays put.
    private func move(from cell: CellID, forward: Bool) {
        let cols = columnCount
        var index = cell.row * cols + cell.column + (forward ? 1 : -1)
        let total = rowCount * cols
        if index < 0 { return }
        if index >= total {
            model.appendRow()
            index = (rowCount - 1) * cols // first cell of the new last row
        }
        focused = CellID(row: index / cols, column: index % cols)
    }

    /// Enter moves to the cell directly below, adding a row when already on the
    /// last one — so filling a column top to bottom needs no reach for the mouse.
    private func moveDown(from cell: CellID) {
        if cell.row + 1 >= rowCount { model.appendRow() }
        focused = CellID(row: cell.row + 1, column: cell.column)
    }

    // MARK: - Structural edits (right-click)

    @ViewBuilder
    private func cellMenu(row: Int, column: Int) -> some View {
        if row > 0 {
            Button("Insert Row Above") { structural(.insertRowAbove(row: row)) }
            Button("Insert Row Below") { structural(.insertRowBelow(row: row)) }
            Button("Delete Row", role: .destructive) { structural(.deleteRow(row: row)) }
            Divider()
        } else {
            Button("Insert Row Below") { structural(.insertRowBelow(row: 0)) }
            Divider()
        }
        Button("Insert Column Left") { structural(.insertColumnLeft(col: column)) }
        Button("Insert Column Right") { structural(.insertColumnRight(col: column)) }
        if columnCount > 1 {
            Button("Delete Column", role: .destructive) { structural(.deleteColumn(col: column)) }
        }
    }

    /// Applies an add/delete via the tested pure operation, then writes the
    /// result straight back — a structural change is a deliberate, discrete act,
    /// so it persists at once rather than waiting for blur.
    private func structural(_ edit: PipeTable.TableEdit) {
        let current = model.serialized(trailingNewline: false)
        guard let block = PipeTable.tableBlocks(in: current).first,
              let rewritten = PipeTable.apply(edit, to: block, trailingNewline: false) else { return }
        model = EditableTable.parse(rewritten)
        commit()
    }

    // MARK: - Committing back to the document

    private func scheduleBlurCommit() {
        blurCommit?.cancel()
        blurCommit = Task { @MainActor in
            // A hop between cells clears focus for an instant before the next
            // cell takes it; a short wait lets that settle so only a genuine
            // blur (focus left the whole grid) commits.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, focused == nil else { return }
            commit()
        }
    }

    private func commit() {
        onEdit(model.serialized(trailingNewline: hasTrailingNewline))
    }

    private func frameAlignment(_ align: TableCellAlign) -> Alignment {
        switch align {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func textAlignment(_ align: TableCellAlign) -> TextAlignment {
        switch align {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

/// A cell address in the rendered grid; row 0 is the header.
private struct CellID: Hashable {
    let row: Int
    let column: Int
}

/// The grid's editable model — the same header/aligns/rows a PipeTableBlock
/// carries, plus the mutations the cells and navigation drive. Serialized back
/// to pipes through the tested PipeTable helpers, so the file always holds a
/// well-formed, padded table.
private struct EditableTable: Equatable {
    var header: [String]
    var aligns: [TableCellAlign]
    var rows: [[String]]

    var columnCount: Int {
        max(header.count, aligns.count, rows.map(\.count).max() ?? 0)
    }

    static func parse(_ source: String) -> EditableTable {
        if let block = PipeTable.tableBlocks(in: source).first {
            return EditableTable(header: block.header, aligns: block.aligns, rows: block.rows)
        }
        return EditableTable(header: ["", ""], aligns: [.left, .left], rows: [["", ""]])
    }

    func cell(_ row: Int, _ column: Int) -> String {
        let cells = row == 0 ? header : (rows[safe: row - 1] ?? [])
        return cells[safe: column] ?? ""
    }

    mutating func setCell(_ row: Int, _ column: Int, _ value: String) {
        let cols = columnCount
        // A single-line cell: a stray newline from an IME or paste would break
        // the row, so it collapses to a space the way the serializer does.
        let clean = value.replacingOccurrences(of: "\n", with: " ")
        if row == 0 {
            fit(&header, to: cols)
            if column < header.count { header[column] = clean }
        } else {
            while rows.count < row { rows.append(Array(repeating: "", count: cols)) }
            fit(&rows[row - 1], to: cols)
            if column < rows[row - 1].count { rows[row - 1][column] = clean }
        }
    }

    mutating func appendRow() {
        rows.append(Array(repeating: "", count: columnCount))
    }

    func serialized(trailingNewline: Bool) -> String {
        PipeTable.padTableSource(
            PipeTable.serializeTable(header: header, aligns: aligns, rows: rows, trailingNewline: trailingNewline)
        )
    }

    private func fit(_ row: inout [String], to count: Int) {
        while row.count < count { row.append("") }
    }
}

private struct TableHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

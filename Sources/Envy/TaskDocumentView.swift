import SwiftUI
import EnvyCore

/// The full-width `tasks:` page — a transcluded view of every open task line
/// across the vault, each row still living in its source note. Checking the
/// box, or editing the words, writes that line straight back.
///
/// Two ways to read the same lines: **By note** groups them under the note
/// they came from (so the spread across the vault is visible, and each header
/// opens that note), and **By due** flattens them into one deadline-sorted
/// list. Both are computed off the incoming lines and cached — never on a
/// redraw.
struct TaskDocumentView: View {
    let lines: [OpenTask]
    let theme: Theme
    /// (noteID, the line as it stands in the note, occurrence, the replacement).
    let onCommit: (String, String, Int, String) -> Void
    /// (noteID, the line as it stands in the note, occurrence).
    let onComplete: (String, String, Int) -> Void
    let onOpenNote: (String, String) -> Void
    let onAddTask: (String) -> Void

    @Environment(\.interfaceFontScale) private var interfaceFontScale
    @State private var newTaskText = ""

    enum Grouping { case byNote, byDue }
    @State private var grouping: Grouping = .byNote
    /// By-due direction. Soonest first until the arrow is clicked.
    @State private var dueAscending = true
    /// Notes whose section is collapsed, in By note.
    @State private var collapsed: Set<String> = []

    /// One note's open lines, in document order. Sections are ordered by the
    /// note's soonest task (undated notes last, newest-edited first).
    private struct Group: Identifiable {
        let id: String
        let title: String
        let firstLine: String
        let tasks: [OpenTask]
    }
    /// Cached arrangements. Recomputed only when the lines or a control
    /// changes, so an ordinary redraw pays nothing.
    @State private var groups: [Group] = []
    @State private var flat: [OpenTask] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                newTaskField
                if lines.isEmpty {
                    emptyState
                } else if grouping == .byNote {
                    ForEach(groups) { group in
                        section(group)
                    }
                } else {
                    ForEach(flat) { task in
                        row(task, showSource: true)
                    }
                }
            }
            .padding(.bottom, Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { rebuild() }
        .onChange(of: lines) { _, _ in rebuild() }
        .onChange(of: grouping) { _, _ in rebuild() }
        .onChange(of: dueAscending) { _, _ in rebuild() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text("Open tasks")
                .font(.system(size: 15 * interfaceFontScale, weight: .bold))
                .foregroundStyle(Color(nsColor: theme.resolvedTextColor))
            Text("\(lines.count)")
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.m)
            modeButton("By note", grouping: .byNote)
            modeButton("By due", grouping: .byDue)
            if grouping == .byDue {
                Button {
                    dueAscending.toggle()
                } label: {
                    Image(systemName: dueAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9 * interfaceFontScale, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(dueAscending ? "Soonest first" : "Latest first")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.s)
    }

    private func modeButton(_ title: String, grouping value: Grouping) -> some View {
        Button { grouping = value } label: {
            Text(title)
                .font(.system(size: 11 * interfaceFontScale, weight: .semibold))
                .foregroundStyle(grouping == value ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.s)
    }

    private var newTaskField: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            TextField("New task", text: $newTaskText)
                .textFieldStyle(.plain)
                .font(.system(size: max(13, theme.resolvedFont.pointSize) * interfaceFontScale))
                .foregroundStyle(Color(nsColor: theme.resolvedTextColor))
                .onSubmit(submitNewTask)
            Text("Adding to Tasks")
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No open tasks",
            systemImage: "checklist",
            description: Text("An open task is a line that starts with an empty checkbox, like - [ ] Call the dentist.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
    }

    private func submitNewTask() {
        let text = newTaskText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onAddTask(text)
        newTaskText = ""
    }

    // MARK: By note

    @ViewBuilder
    private func section(_ group: Group) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        HStack(spacing: Spacing.s) {
            Button {
                if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10 * interfaceFontScale, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)

            Button {
                onOpenNote(group.id, group.firstLine)
            } label: {
                Text(group.title.isEmpty ? "Untitled" : group.title)
                    .font(.system(size: 12 * interfaceFontScale, weight: .semibold))
                    .foregroundStyle(Color(nsColor: theme.resolvedLinkColor))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open \(group.title)")

            Text("\(group.tasks.count)")
                .font(.system(size: 10 * interfaceFontScale))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.xs)

        if !isCollapsed {
            ForEach(group.tasks) { task in
                row(task, showSource: false)
            }
        }
    }

    private func row(_ task: OpenTask, showSource: Bool) -> some View {
        TaskLineRow(
            task: task,
            theme: theme,
            scale: interfaceFontScale,
            indented: !showSource,
            // Only nest under a note header (By note); By due is a flat
            // cross-note triage list where source indentation is meaningless.
            depth: showSource ? 0 : task.indent,
            showSource: showSource,
            onCommit: onCommit,
            onComplete: onComplete,
            onOpenNote: onOpenNote
        )
    }

    // MARK: Arrangement (off the redraw path)

    private func rebuild() {
        if grouping == .byNote {
            // Iterate the already due-sorted lines: the order notes first
            // appear is the order of their soonest task, which is exactly the
            // section order we want. Tasks within a note go back to document
            // order.
            var order: [String] = []
            var byNote: [String: [OpenTask]] = [:]
            var title: [String: String] = [:]
            for task in lines {
                if byNote[task.noteID] == nil {
                    order.append(task.noteID)
                    title[task.noteID] = task.noteTitle
                }
                byNote[task.noteID, default: []].append(task)
            }
            groups = order.map { id in
                let tasks = byNote[id]!.sorted { $0.ordinal < $1.ordinal }
                return Group(id: id, title: title[id] ?? "", firstLine: tasks.first?.sourceLine ?? "", tasks: tasks)
            }
        } else {
            flat = arrangeByDue(lines)
        }
    }

    /// `lines` arrives soonest-first already, so ascending is a no-op.
    private func arrangeByDue(_ lines: [OpenTask]) -> [OpenTask] {
        guard !dueAscending else { return lines }
        return lines.sorted { a, b in
            switch (a.due, b.due) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                if a.edited != b.edited { return a.edited > b.edited }
                if a.ordinal != b.ordinal { return a.ordinal < b.ordinal }
                return a.noteID < b.noteID
            }
        }
    }
}

private struct TaskLineRow: View {
    let task: OpenTask
    let theme: Theme
    let scale: CGFloat
    /// Nudged right under a note header (By note), flush left in the flat
    /// list (By due).
    let indented: Bool
    /// Source-line indentation in columns, rendered as nesting under the note.
    let depth: Int
    /// Show the source-note chip. Off under a header that already names it.
    let showSource: Bool
    let onCommit: (String, String, Int, String) -> Void
    let onComplete: (String, String, Int) -> Void
    let onOpenNote: (String, String) -> Void

    @State private var draft: String
    /// The line as it currently stands in the note, and which copy it is — the
    /// write key. Advanced after each commit so a second edit in the same
    /// session targets the line the first one just wrote, not the original.
    @State private var liveLine: String
    @State private var liveOccurrence: Int
    @State private var editing = false
    @State private var saveTask: Task<Void, Never>?
    /// Set the instant the box is checked so the row leaves at once, rather
    /// than lingering the ~one rescan it takes the data to drop it.
    @State private var done = false
    @FocusState private var focused: Bool

    init(
        task: OpenTask,
        theme: Theme,
        scale: CGFloat,
        indented: Bool,
        depth: Int,
        showSource: Bool,
        onCommit: @escaping (String, String, Int, String) -> Void,
        onComplete: @escaping (String, String, Int) -> Void,
        onOpenNote: @escaping (String, String) -> Void
    ) {
        self.task = task
        self.theme = theme
        self.scale = scale
        self.indented = indented
        self.depth = depth
        self.showSource = showSource
        self.onCommit = onCommit
        self.onComplete = onComplete
        self.onOpenNote = onOpenNote
        _draft = State(initialValue: task.body)
        _liveLine = State(initialValue: task.sourceLine)
        _liveOccurrence = State(initialValue: task.occurrence)
    }

    var body: some View {
        if done {
            EmptyView()
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        // Center, not .firstTextBaseline: the checkbox is a Shape with no text
        // baseline, so baseline alignment pins its bottom edge to the text
        // baseline and it floats high. Rows are single-line, so centering the
        // box against the words is what reads as aligned.
        HStack(alignment: .center, spacing: Spacing.s) {
            Button(action: finish) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.secondary, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .frame(width: 22, height: 18, alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark done")

            Group {
                if editing {
                    TextField("Task", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: max(13, theme.resolvedFont.pointSize) * scale))
                        .foregroundStyle(Color(nsColor: theme.resolvedTextColor))
                        .focused($focused)
                        .onAppear { focused = true }
                        .onSubmit(endEditing)
                } else {
                    Button {
                        editing = true
                    } label: {
                        styledBody
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showSource {
                Button {
                    onOpenNote(task.noteID, liveLine)
                } label: {
                    Text(task.noteTitle.isEmpty ? "note" : task.noteTitle)
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Open \(task.noteTitle)")
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, Spacing.l)
        .padding(.vertical, Spacing.s)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, leadingInset)
        }
        .onChange(of: draft) { _, _ in
            guard editing else { return }
            saveTask = DebouncedSave.schedule(replacing: saveTask) { commitNow() }
        }
        .onChange(of: focused) { _, isFocused in
            if editing, !isFocused { endEditing() }
        }
        .onChange(of: task.body) { _, newBody in
            // The cache rebuilt with a fresh value for this row (same ordinal).
            // Resync only when the user isn't mid-edit, so their typing and the
            // chained write key are never clobbered.
            guard !editing else { return }
            draft = newBody
            liveLine = task.sourceLine
            liveOccurrence = task.occurrence
        }
    }

    /// Save the words, then check the box, so a half-typed edit is not lost.
    private func finish() {
        saveTask?.cancel()
        if editing { commitNow() }
        onComplete(task.noteID, liveLine, liveOccurrence)
        withAnimation(.easeInOut(duration: 0.12)) { done = true }
    }

    private func endEditing() {
        guard editing else { return }
        editing = false
        saveTask?.cancel()
        commitNow()
    }

    private func commitNow() {
        let cleaned = draft.replacingOccurrences(of: "\n", with: " ")
        let newLine = task.marker + cleaned
        guard newLine != liveLine else { return }
        onCommit(task.noteID, liveLine, liveOccurrence, newLine)
        // The note now holds `newLine`, unique among any identical siblings
        // (which still carry the old text), so the next write matches it at 0.
        liveLine = newLine
        liveOccurrence = 0
    }

    /// Base indent (nudged under a note header, flush in the flat list) plus a
    /// step per column of source indentation, capped at six levels so a deeply
    /// nested 4-space list can't push rows off the pane.
    private var leadingInset: CGFloat {
        let base = indented ? Spacing.xl : Spacing.l
        return base + CGFloat(min(depth, 24)) * 7
    }

    /// The task words, with each `@date` bold and colored the way the note editor colors it.
    private var styledBody: Text {
        let body = task.body
        let ns = body as NSString
        let size = max(13, theme.resolvedFont.pointSize) * scale
        let baseFont = Font.system(size: size)
        let dueFont = Font.system(size: size, weight: .bold)
        let baseColor = Color(nsColor: theme.resolvedTextColor)
        let tokens = MarkdownSemantics.dueTokenRanges(in: body).filter { !$0.isCrossedOut }
        guard !tokens.isEmpty else {
            return Text(body).font(baseFont).foregroundColor(baseColor)
        }
        var result = Text("")
        var cursor = 0
        for token in tokens {
            if token.range.location > cursor {
                let plain = ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
                result = result + Text(plain).font(baseFont).foregroundColor(baseColor)
            }
            let raw = ns.substring(with: token.range)
            let inner = token.range.location + 1 < ns.length
                ? ns.substring(with: NSRange(location: token.range.location + 1, length: max(0, token.range.length - 1)))
                : ""
            let color = dueColor(for: inner)
            result = result + Text(raw).font(dueFont).foregroundColor(color)
            cursor = token.range.location + token.range.length
        }
        if cursor < ns.length {
            result = result + Text(ns.substring(from: cursor)).font(baseFont).foregroundColor(baseColor)
        }
        return result
    }

    /// Same three colors the editor uses for a due token: overdue, due this week, and later.
    private func dueColor(for token: String) -> Color {
        let ns: NSColor
        if let date = NoteStore.resolveDueToken(token) {
            switch NoteStore.dueUrgency(for: date) {
            case .overdue: ns = theme.resolvedDueOverdueColor
            case .soon: ns = theme.resolvedDueSoonColor
            case .later: ns = theme.resolvedDueColor
            }
        } else {
            ns = theme.resolvedDueColor
        }
        return Color(nsColor: ns)
    }
}

import SwiftUI
import EnvyCore

/// The `tasklist:` page. Each row is one open line from a real note.
/// Checking the box, or editing the words, writes that line back into the note.
struct TaskDocumentView: View {
    let lines: [OpenTask]
    let theme: Theme
    let onCommit: (String, Int, String) -> Void
    let onComplete: (String, Int) -> Void
    let onOpenNote: (String, String) -> Void
    let onAddTask: (String) -> Void

    @Environment(\.interfaceFontScale) private var interfaceFontScale
    @State private var newTaskText = ""
    /// Due puts dated lines first. No date puts lines with no due date first.
    @State private var undatedFirst = false
    /// Direction of the dated lines. Soonest first until Due is clicked again.
    @State private var dueAscending = true

    var body: some View {
        // Lazy on purpose. A plain stack builds every row before the first
        // one can draw. The test vault has about 6,700 open lines, and
        // building them all at once froze the window. Only the row being
        // edited is a text field. The note list uses the same lazy stack.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                newTaskField
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No open tasks",
                        systemImage: "checklist",
                        description: Text("An open task is a line that starts with an empty checkbox, like - [ ] Call the dentist.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.xxl)
                } else {
                    ForEach(orderedLines) { task in
                        TaskLineRow(
                            task: task,
                            theme: theme,
                            scale: interfaceFontScale,
                            onCommit: onCommit,
                            onComplete: onComplete,
                            onOpenNote: onOpenNote
                        )
                    }
                }
            }
            .padding(.bottom, Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Open tasks")
                .font(.system(size: 15 * interfaceFontScale, weight: .bold))
                .foregroundStyle(Color(nsColor: theme.resolvedTextColor))
            Spacer(minLength: Spacing.m)
            sortButton("Due", undatedFirst: false, showsDirection: !undatedFirst)
            sortButton("No date", undatedFirst: true, showsDirection: false)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.s)
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
        .padding(.bottom, Spacing.m)
    }

    private func submitNewTask() {
        let text = newTaskText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onAddTask(text)
        newTaskText = ""
    }

    private func sortButton(_ title: String, undatedFirst selected: Bool, showsDirection: Bool) -> some View {
        Button {
            if undatedFirst == selected, !selected {
                dueAscending.toggle()
            } else {
                undatedFirst = selected
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if showsDirection {
                    Image(systemName: dueAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9 * interfaceFontScale, weight: .bold))
                }
            }
            .font(.system(size: 11 * interfaceFontScale, weight: .semibold))
            .foregroundStyle(undatedFirst == selected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.s)
    }

    /// Dated lines stay in due order. The chosen button decides which group leads.
    private var orderedLines: [OpenTask] {
        lines.sorted { a, b in
            switch (a.due, b.due) {
            case let (lhs?, rhs?) where lhs != rhs:
                return dueAscending ? lhs < rhs : lhs > rhs
            case (.some, .none):
                return !undatedFirst
            case (.none, .some):
                return undatedFirst
            case (.none, .none):
                if a.edited != b.edited { return a.edited > b.edited }
                if a.ordinal != b.ordinal { return a.ordinal > b.ordinal }
                return a.noteID < b.noteID
            default:
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
    let onCommit: (String, Int, String) -> Void
    let onComplete: (String, Int) -> Void
    let onOpenNote: (String, String) -> Void

    @State private var draft: String
    @State private var editing = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(
        task: OpenTask,
        theme: Theme,
        scale: CGFloat,
        onCommit: @escaping (String, Int, String) -> Void,
        onComplete: @escaping (String, Int) -> Void,
        onOpenNote: @escaping (String, String) -> Void
    ) {
        self.task = task
        self.theme = theme
        self.scale = scale
        self.onCommit = onCommit
        self.onComplete = onComplete
        self.onOpenNote = onOpenNote
        _draft = State(initialValue: task.body)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
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

            Button {
                onOpenNote(task.noteID, task.sourceLine)
            } label: {
                Text("Source →")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open \(task.noteTitle)")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, Spacing.l)
        }
        .onChange(of: draft) { _, _ in
            guard editing else { return }
            saveTask = DebouncedSave.schedule(replacing: saveTask) { commitNow() }
        }
        .onChange(of: focused) { _, isFocused in
            if editing, !isFocused { endEditing() }
        }
        .onChange(of: task.body) { _, newBody in
            guard !editing else { return }
            draft = newBody
        }
    }

    /// Save the words, then check the box, so a half-typed edit is not lost.
    private func finish() {
        saveTask?.cancel()
        if editing { commitNow() }
        onComplete(task.noteID, task.ordinal)
    }

    private func endEditing() {
        guard editing else { return }
        editing = false
        saveTask?.cancel()
        commitNow()
    }

    private func commitNow() {
        onCommit(task.noteID, task.ordinal, draft)
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

import SwiftUI
import UniformTypeIdentifiers
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
    /// Returns which copy of its text the line now is, or nil when the note
    /// didn't take the write.
    let onCommit: (String, String, Int, String) -> Int?
    /// (noteID, the line as it stands in the note, occurrence) — flip its box.
    /// Returns which copy of its text the flipped line is, or nil.
    let onComplete: (String, String, Int) -> Int?
    let onOpenNote: (String, String) -> Void
    /// The New task field's submit — the field isn't shown for one note.
    var onAddTask: (String) -> Void = { _ in }
    /// (noteID, the line to nest under, occurrence).
    let onAddSubtask: (String, String, Int) -> Void
    /// (noteID, the line to sit below, occurrence) — a sibling, not a child.
    let onAddTaskBelow: (String, String, Int) -> Void
    /// A just-created line to open in edit mode when its row appears.
    let focusNoteID: String?
    let focusLine: String?
    let onFocusConsumed: () -> Void
    /// One note's tasks only: render flat in document order (no grouping, no
    /// source chips, no mode toggle) — the per-note pop-out panel.
    var singleNote: Bool = false
    /// The hint beside the "New task" field ("Adding to Tasks" by default).
    var addTaskHint: String = "Adding to Tasks"
    /// Whether checked tasks are shown too (they're scanned upstream only when
    /// this is on). The header's toggle drives it; the container recomputes.
    @Binding var showCompleted: Bool
    /// Single-note mode's bottom "+" — append an empty task to the note and
    /// focus it. Unused elsewhere (they use the top New task field).
    var onAddEmptyTask: () -> Void = {}
    /// (noteID, the empty line, occurrence) — Backspace in a task with no
    /// words. Returns whether the note took it.
    var onDeleteEmpty: (String, String, Int) -> Bool = { _, _, _ in false }
    /// (noteID, the dragged line, its occurrence, the line it was dropped on,
    /// that line's occurrence, below it?) — rearranging within one note.
    /// Returns whether the note took it.
    var onMoveTask: (String, String, Int, String, Int, Bool) -> Bool = { _, _, _, _, _, _ in false }
    /// (noteID, the line, occurrence, outward?) — Tab / Shift-Tab: shift the
    /// task and its subtasks a level in or out. Returns the line as it now
    /// reads and which copy of that text it is, or nil when it can't move.
    var onShiftTask: (String, String, Int, Bool) -> (line: String, occurrence: Int)? = { _, _, _, _ in nil }
    /// Which copy of `focusLine` to open, when the note holds identical lines
    /// (a new empty task beside older empty ones). nil: any copy.
    var focusOccurrence: Int? = nil

    @Environment(\.interfaceFontScale) private var interfaceFontScale
    @State private var newTaskText = ""

    enum Grouping { case byNote, byDue }
    @State private var grouping: Grouping = .byNote
    /// By-due direction. Soonest first until the arrow is clicked.
    @State private var dueAscending = true
    /// Notes whose section is collapsed, in By note.
    @State private var collapsed: Set<NoteKey> = []

    /// One note's open lines, in document order. Sections are ordered by the
    /// note's soonest task (undated notes last, newest-edited first).
    private struct Group: Identifiable {
        let id: NoteKey
        let title: String
        let firstLine: String
        let tasks: [OpenTask]
    }
    /// Cached arrangements. Recomputed only when the lines or a control
    /// changes, so an ordinary redraw pays nothing.
    @State private var groups: [Group] = []
    @State private var flat: [OpenTask] = []
    /// The row being dragged to rearrange, and where it would land.
    @State private var dragging: OpenTask?
    @State private var dropSpot: DropSpot?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !singleNote {
                    header
                    newTaskField
                }
                if lines.isEmpty {
                    if !singleNote { emptyState }
                } else if singleNote {
                    // Document order; subtasks indent by their own depth, no
                    // group header or source chip.
                    ForEach(flat) { task in
                        row(task, showSource: false)
                    }
                } else if grouping == .byNote {
                    ForEach(groups) { group in
                        section(group)
                    }
                } else {
                    ForEach(flat) { task in
                        row(task, showSource: true)
                    }
                }
                if singleNote { addButton }
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
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Spacer(minLength: 0)
            Button { showCompleted.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: showCompleted ? "checkmark.square" : "square")
                        .font(.system(size: 10 * interfaceFontScale, weight: .bold))
                    Text("Completed")
                }
                .font(.system(size: 11 * interfaceFontScale, weight: .semibold))
                .foregroundStyle(showCompleted ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Show completed tasks")
            if !singleNote {
                modeButton("By note", grouping: .byNote)
                dueButton
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
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

    /// Clicking "By due" switches into due order; clicking it again flips the
    /// direction (soonest ↔ latest), so one control both selects and sorts.
    private var dueButton: some View {
        Button {
            if grouping == .byDue { dueAscending.toggle() } else { grouping = .byDue }
        } label: {
            HStack(spacing: 3) {
                Text("By due")
                if grouping == .byDue {
                    Image(systemName: dueAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9 * interfaceFontScale, weight: .bold))
                }
            }
            .font(.system(size: 11 * interfaceFontScale, weight: .semibold))
            .foregroundStyle(grouping == .byDue ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(grouping == .byDue
              ? (dueAscending ? "Soonest first — click to flip" : "Latest first — click to flip")
              : "Sort by due date")
        .padding(.leading, Spacing.s)
    }

    private var newTaskField: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            TextField("New task", text: $newTaskText)
                .textFieldStyle(.plain)
                .font(.system(size: max(13, theme.resolvedFont.pointSize) * interfaceFontScale))
                .foregroundStyle(Color(nsColor: theme.resolvedTextColor))
                .onSubmit(submitNewTask)
            Text(addTaskHint)
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The single-note panel's add control: a plain "+" at the bottom that
    /// appends an empty task and drops into editing it.
    private var addButton: some View {
        Button(action: onAddEmptyTask) {
            Image(systemName: "plus")
                .font(.system(size: 12 * interfaceFontScale, weight: .semibold))
                .foregroundStyle(.secondary)
                // Same leading + 22-wide box as a task row's checkbox, so the
                // "+" sits directly under the checkbox column.
                .frame(width: 22, height: 18, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.xl)
        .padding(.vertical, Spacing.s)
        .help("Add a task")
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
                onOpenNote(group.id.id, group.firstLine)
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
            onOpenNote: onOpenNote,
            onAddSubtask: onAddSubtask,
            onAddTaskBelow: onAddTaskBelow,
            onDeleteEmpty: onDeleteEmpty,
            onShiftTask: onShiftTask,
            autoFocus: task.noteID == focusNoteID && task.sourceLine == focusLine
                && (focusOccurrence == nil || task.occurrence == focusOccurrence),
            onFocusConsumed: onFocusConsumed
        )
        // Rearranging follows the note's own order, so it's offered where rows
        // show in it — a note's section, or the one-note panel — not By due.
        .modifier(Reorderable(task: task, enabled: singleNote || grouping == .byNote,
                              dragging: $dragging, dropSpot: $dropSpot) { dragged, target, below in
            onMoveTask(dragged.noteID, dragged.sourceLine, dragged.occurrence,
                       target.sourceLine, target.occurrence, below)
        })
    }

    // MARK: Arrangement (off the redraw path)

    private func rebuild() {
        if singleNote {
            // One note: its document order. (A rearrange re-reads the note
            // before the rescan lands, and ordinal is the order it wrote.)
            flat = lines.sorted { $0.ordinal < $1.ordinal }
        } else if grouping == .byNote {
            // Iterate the already due-sorted lines: the order notes first
            // appear is the order of their soonest task, which is exactly the
            // section order we want. Tasks within a note go back to document
            // order.
            var order: [NoteKey] = []
            var byNote: [NoteKey: [OpenTask]] = [:]
            var title: [NoteKey: String] = [:]
            for task in lines {
                let key = task.noteKey
                if byNote[key] == nil {
                    order.append(key)
                    title[key] = task.noteTitle
                }
                byNote[key, default: []].append(task)
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
    let onCommit: (String, String, Int, String) -> Int?
    let onComplete: (String, String, Int) -> Int?
    let onOpenNote: (String, String) -> Void
    let onAddSubtask: (String, String, Int) -> Void
    let onAddTaskBelow: (String, String, Int) -> Void
    let onDeleteEmpty: (String, String, Int) -> Bool
    let onShiftTask: (String, String, Int, Bool) -> (line: String, occurrence: Int)?
    /// True for a just-created row that should open in edit mode on appear.
    let autoFocus: Bool
    let onFocusConsumed: () -> Void

    @State private var draft: String
    /// The line as it currently stands in the note, and which copy it is — the
    /// write key. Advanced after each commit so a second edit in the same
    /// session targets the line the first one just wrote, not the original.
    @State private var liveLine: String
    @State private var liveOccurrence: Int
    @State private var editing = false
    @State private var saveTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    /// The edit field's width, to know when its words still fit on one line.
    @State private var fieldWidth: CGFloat = 0
    /// The window this row is edited in — the monitor acts on its keys only.
    @State private var keyWindow: NSWindow?
    @FocusState private var focused: Bool

    init(
        task: OpenTask,
        theme: Theme,
        scale: CGFloat,
        indented: Bool,
        depth: Int,
        showSource: Bool,
        onCommit: @escaping (String, String, Int, String) -> Int?,
        onComplete: @escaping (String, String, Int) -> Int?,
        onOpenNote: @escaping (String, String) -> Void,
        onAddSubtask: @escaping (String, String, Int) -> Void,
        onAddTaskBelow: @escaping (String, String, Int) -> Void,
        onDeleteEmpty: @escaping (String, String, Int) -> Bool,
        onShiftTask: @escaping (String, String, Int, Bool) -> (line: String, occurrence: Int)?,
        autoFocus: Bool,
        onFocusConsumed: @escaping () -> Void
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
        self.onAddSubtask = onAddSubtask
        self.onAddTaskBelow = onAddTaskBelow
        self.onDeleteEmpty = onDeleteEmpty
        self.onShiftTask = onShiftTask
        self.autoFocus = autoFocus
        self.onFocusConsumed = onFocusConsumed
        _draft = State(initialValue: task.body)
        _liveLine = State(initialValue: task.sourceLine)
        _liveOccurrence = State(initialValue: task.occurrence)
    }

    var body: some View {
        rowContent
    }

    private var rowContent: some View {
        // Center, not .firstTextBaseline: the checkbox is a Shape with no text
        // baseline, so baseline alignment pins its bottom edge to the text
        // baseline and it floats high. Rows are single-line, so centering the
        // box against the words is what reads as aligned.
        HStack(alignment: .center, spacing: Spacing.s) {
            Button(action: finish) {
                Group {
                    if task.isCompleted {
                        Image(systemName: "checkmark.square.fill")
                            .font(.system(size: 14 * scale))
                            .foregroundStyle(.secondary)
                    } else {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.secondary, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                }
                .frame(width: 22, height: 18, alignment: .center)
                // Fill the whole 22x18 as the tap target: a stroked (unfilled)
                // checkbox is otherwise only hittable on its 1.5pt border, so
                // clicks in the empty middle did nothing.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark not done" : "Mark done")

            Group {
                if editing {
                    // A due tag shows bold and colored while it's typed, the
                    // way the editor shows it: the field's own text is drawn
                    // clear and the styled words sit on top (the search box's
                    // technique for its operators). Only while the words fit —
                    // an overlay can't follow a field that scrolls sideways.
                    ZStack(alignment: .leading) {
                        TextField("Task", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: fontSize))
                            .foregroundStyle(styleWhileTyping ? Color.clear : Color(nsColor: theme.resolvedTextColor))
                            .focused($focused)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fieldWidth = $0 }
                        if styleWhileTyping {
                            // Same weight as the field underneath: bold is wider,
                            // and the caret belongs to the field's own text, so a
                            // bold date left the caret short of its end.
                            styled(draft, boldDue: false)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                        }
                    }
                    // Next turn, not in onAppear itself: the field isn't in
                    // the window yet there, and while another field holds
                    // the keyboard (the search box, every time the page was
                    // just reached by typing tasks:) that request is dropped
                    // — the field shows but typing goes nowhere.
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onSubmit(submit)
                } else {
                    Button {
                        editing = true
                    } label: {
                        // A placeholder keeps an empty (just-added) task tall
                        // enough to click; contentShape makes the whole width a
                        // hit target. A completed task reads struck-through.
                        (task.isCompleted
                            ? Text(task.body).strikethrough().foregroundColor(.secondary).font(.system(size: max(13, theme.resolvedFont.pointSize) * scale))
                            : (task.body.isEmpty
                                ? Text("New task").foregroundColor(.secondary).font(.system(size: max(13, theme.resolvedFont.pointSize) * scale))
                                : styledBody))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showSource {
                Button {
                    onOpenNote(task.noteID, writeKey.line)
                } label: {
                    // A short fixed chip, not the note title — the title's
                    // length was crowding out the due date at the end of the
                    // task text. The note is still named on hover.
                    Text("note →")
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
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
        .contextMenu {
            Button("Add Task Below") { onAddTaskBelow(task.noteID, writeKey.line, writeKey.occurrence) }
            Button("Add Subtask") { onAddSubtask(task.noteID, writeKey.line, writeKey.occurrence) }
            Divider()
            Button("Open Source Note") { onOpenNote(task.noteID, writeKey.line) }
        }
        // A row just created by the menu drops straight into edit mode — on
        // first appearance, and also when the focus target moves onto a row
        // that's already visible (the "+"/Add Subtask reusing an existing empty
        // task rather than stacking a new one, which wouldn't re-fire onAppear).
        .onAppear { if autoFocus { focusThisRow() } }
        .onChange(of: autoFocus) { _, isTarget in if isTarget { focusThisRow() } }
        // Save as you type (the rest of Envy does). The row id is the
        // note+ordinal, which is stable while editing text — no insert/remove
        // happens mid-edit — so a debounced commit here doesn't drop focus.
        .onChange(of: draft) { _, _ in
            guard editing else { return }
            freezeDueTokenAtCaret()
            saveTask = DebouncedSave.schedule(replacing: saveTask) { commitNow() }
        }
        // Outline keys while this row is editing: Backspace in an empty task
        // removes it, Tab / Shift-Tab nest it or bring it back out.
        .onChange(of: editing) { _, isEditing in
            if isEditing { watchKeys() } else { stopWatchingKeys() }
        }
        .onDisappear { stopWatchingKeys() }
        .onChange(of: focused) { _, isFocused in
            if editing, !isFocused { endEditing() }
        }
        .onChange(of: task) { _, newTask in
            // The list has a fresh value for this row: a check, an edit, a
            // rescan, or the note changing on disk. Resync on any change, not
            // just the words — a check changes only the box, and a key left on
            // the old line makes the next write miss. Never mid-edit, so the
            // typing and its chained key are left alone.
            guard !editing else { return }
            draft = newTask.body
            liveLine = newTask.sourceLine
            liveOccurrence = newTask.occurrence
        }
    }

    /// Drop this row into edit mode. Resync @State to this task first — the row
    /// may have been reused (same ordinal id) from a shifted or differently-
    /// bodied task, so its leftover draft/line must not leak into the edit.
    private func focusThisRow() {
        guard !editing else { return }
        draft = task.body
        liveLine = task.sourceLine
        liveOccurrence = task.occurrence
        editing = true
        onFocusConsumed()
    }

    /// Save the words, then flip the checkbox (the handler toggles [ ]↔[x]), so
    /// a half-typed edit is not lost. Checking an open task while completed are
    /// hidden makes the row leave; otherwise it stays (now checked/unchecked).
    private func finish() {
        saveTask?.cancel()
        if editing { commitNow() }
        let key = writeKey
        guard let occurrence = onComplete(task.noteID, key.line, key.occurrence),
              let toggled = TaskPage.toggledLine(key.line) else { return }
        // Still editing: the list's refresh won't resync a row mid-edit, so
        // carry the flipped box into the chained key ourselves.
        liveLine = toggled
        liveOccurrence = occurrence
    }

    /// A local key monitor rather than onKeyPress: the text field's editor
    /// takes Backspace and Tab before SwiftUI's key handlers ever see them.
    /// Acts only while this row's field has the keyboard. Backspace is taken
    /// only in an empty task; Tab always is, so it never jumps focus out of the
    /// task (a Tab that can't nest does nothing).
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        // Editing starts from a click or a key in this row's window, so it's
        // the key window now. Keys typed in any other window — another panel,
        // a sheet, the editor — pass through untouched.
        keyWindow = NSApp.keyWindow
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard editing, focused, let window = event.window, window === keyWindow else { return event }
            // An input method mid-composition owns Backspace and Tab.
            if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            switch (event.keyCode, modifiers) {
            case (51, []) where draft.isEmpty:
                deleteEmpty()
            case (48, []):
                shift(outward: false)
            case (48, [.shift]):
                shift(outward: true)
            default:
                return event
            }
            return nil
        }
    }

    private func stopWatchingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keyWindow = nil
    }

    /// Tab / Shift-Tab: nest this task (and its subtasks) under the task above,
    /// or bring it back out a level. The pending save lands first; editing
    /// carries on, keyed to the line as it now reads.
    private func shift(outward: Bool) {
        saveTask?.cancel()
        commitNow()
        let key = writeKey
        guard let shifted = onShiftTask(task.noteID, key.line, key.occurrence, outward) else { return }
        liveLine = shifted.line
        liveOccurrence = shifted.occurrence
    }

    /// Return: keep the words and open a new task on the next line, the way
    /// a list works in any editor. Return in an empty task just finishes, so
    /// holding it can't stack up blank lines.
    private func submit() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else {
            endEditing()
            return
        }
        saveTask?.cancel()
        commitNow()
        let key = writeKey
        editing = false
        onAddTaskBelow(task.noteID, key.line, key.occurrence)
    }

    /// The editor's rule for due tags, in a task row: a relative one —
    /// "@today", "@friday" — becomes the date it means the moment it's typed
    /// ("@2026-09-25"), so the task can go overdue instead of rolling forward
    /// forever. Done through the field's own editor, like the note editor
    /// does it, so the caret stays where it was; the edit comes back through
    /// the binding, and the now-absolute date doesn't match again.
    private func freezeDueTokenAtCaret() {
        guard focused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == draft else { return }
        let caret = editor.selectedRange()
        guard caret.length == 0, let freeze = NoteStore.frozenDueToken(in: draft, endingAt: caret.location) else { return }
        editor.insertText(freeze.replacement, replacementRange: freeze.range)
    }

    /// Take this empty task out of its note. The pending save lands first so
    /// the note holds exactly the empty line being removed.
    private func deleteEmpty() {
        saveTask?.cancel()
        commitNow()
        let key = writeKey
        editing = false
        _ = onDeleteEmpty(task.noteID, key.line, key.occurrence)
    }

    private func endEditing() {
        guard editing else { return }
        editing = false
        saveTask?.cancel()
        commitNow()
    }

    private func commitNow() {
        let key = writeKey
        let cleaned = draft.replacingOccurrences(of: "\n", with: " ")
        // The marker as the note holds it (from the key), not the list's copy:
        // right after a Tab or a check, the list's value may not have caught
        // up yet, and writing its old indent or box would undo that change.
        let newLine = (TaskPage.marker(of: key.line) ?? task.marker) + cleaned
        guard newLine != key.line else { return }
        // Advance the key only when the note took the write — a missed write
        // must not leave the row keyed to text the note never had.
        guard let occurrence = onCommit(task.noteID, key.line, key.occurrence, newLine) else { return }
        liveLine = newLine
        liveOccurrence = occurrence
    }

    /// The line as the note holds it now, for the next write. Out of an edit
    /// that's the list's own value: the container re-reads the note after
    /// every write, so it's exact. Mid-edit the list's value can trail the
    /// last keystroke's save, so the row's chained key leads — with the
    /// list's occurrence once it has caught up to the same text.
    private var writeKey: (line: String, occurrence: Int) {
        guard editing else { return (task.sourceLine, task.occurrence) }
        return (liveLine, task.sourceLine == liveLine ? task.occurrence : liveOccurrence)
    }

    /// Base indent (nudged under a note header, flush in the flat list) plus a
    /// step per column of source indentation, capped at six levels so a deeply
    /// nested 4-space list can't push rows off the pane.
    private var leadingInset: CGFloat {
        let base = indented ? Spacing.xl : Spacing.l
        return base + CGFloat(min(depth, 24)) * 7
    }

    /// The task words, with each `@date` bold and colored the way the note editor colors it.
    private var styledBody: Text { styled(task.body) }

    private var fontSize: CGFloat { max(13, theme.resolvedFont.pointSize) * scale }

    /// The words being edited carry a live due tag and still fit the field.
    private var styleWhileTyping: Bool {
        guard editing, draft.contains("@"),
              MarkdownSemantics.dueTokenRanges(in: draft).contains(where: { !$0.isCrossedOut }) else { return false }
        let width = (draft as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return width < fieldWidth - 4
    }

    /// A task's words with each live `@date` colored by urgency — and bold,
    /// except over the edit field, whose caret needs every glyph the width
    /// the field itself lays out.
    private func styled(_ body: String, boldDue: Bool = true) -> Text {
        let ns = body as NSString
        let size = fontSize
        let baseFont = Font.system(size: size)
        let dueFont = boldDue ? Font.system(size: size, weight: .bold) : baseFont
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

/// Where a dragged task row would land: just above or just below `id`.
private struct DropSpot: Equatable {
    let id: TaskID
    let below: Bool
}

/// Drag-to-rearrange for one task row: the row can be picked up, and a task
/// from the same note dropped on it lands above or below it (by which half the
/// pointer is over), shown by an insertion line.
private struct Reorderable: ViewModifier {
    let task: OpenTask
    let enabled: Bool
    @Binding var dragging: OpenTask?
    @Binding var dropSpot: DropSpot?
    let onDrop: (OpenTask, OpenTask, Bool) -> Bool
    @State private var height: CGFloat = 1

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .overlay(alignment: dropSpot?.below == true ? .bottom : .top) {
                    if dropSpot?.id == task.id {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                    }
                }
                .onDrag {
                    dragging = task
                    // An in-app-only type: nothing dragged in from elsewhere
                    // (or from another window's text) can land as a task move.
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.envyTaskRow.identifier,
                                                        visibility: .ownProcess) { done in
                        done(Data(), nil)
                        return nil
                    }
                    return provider
                }
                .onDrop(of: [.envyTaskRow], delegate: RowDrop(target: task, height: height,
                                                       dragging: $dragging, spot: $dropSpot, onDrop: onDrop))
        } else {
            content
        }
    }
}

private struct RowDrop: DropDelegate {
    let target: OpenTask
    let height: CGFloat
    @Binding var dragging: OpenTask?
    @Binding var spot: DropSpot?
    let onDrop: (OpenTask, OpenTask, Bool) -> Bool

    /// The dragged row, when it can land here: same note, not itself.
    private var movable: OpenTask? {
        guard let dragged = dragging, dragged.noteKey == target.noteKey, dragged.id != target.id else { return nil }
        return dragged
    }

    private func below(_ info: DropInfo) -> Bool { info.location.y > height / 2 }

    func validateDrop(info: DropInfo) -> Bool { movable != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard movable != nil else { return DropProposal(operation: .forbidden) }
        let here = DropSpot(id: target.id, below: below(info))
        if spot != here { spot = here }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if spot?.id == target.id { spot = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        spot = nil
        defer { dragging = nil }
        guard let dragged = movable else { return false }
        return onDrop(dragged, target, below(info))
    }
}

private extension UTType {
    /// A task row being dragged to rearrange it — carries nothing, only marks
    /// the drag as ours.
    static let envyTaskRow = UTType(exportedAs: "com.skylerschoos.envy.task-row")
}

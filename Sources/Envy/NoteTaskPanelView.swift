import SwiftUI
import EnvyCore

/// A single note's tasks in a floating pop-out panel — the per-note twin of
/// TaskListPanelView, opened from the note list's "Pin Note Tasks". Shares the
/// main window's live store, shows only this note's open lines (flat, with
/// subtasks nested), and writes edits/additions straight back to this note.
struct NoteTaskPanelView: View {
    @ObservedObject var store: NoteStore
    let noteID: String
    var onOpenNote: (URL) -> Void

    @AppStorage("theme") private var theme = Theme()
    @AppStorage("interfaceTextSize") private var interfaceTextSizeRaw = InterfaceTextSize.large.rawValue

    @State private var lines: [OpenTask] = []
    @AppStorage("taskShowCompleted") private var showCompleted = false
    @State private var generation = 0
    @State private var focusNoteID: String?
    @State private var focusLine: String?
    @State private var focusOccurrence: Int?

    private var scale: CGFloat { (InterfaceTextSize(rawValue: interfaceTextSizeRaw) ?? .large).scale }
    private var noteTitle: String { store.note(withID: noteID)?.title ?? "Note" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Button { onOpenNote(URL(fileURLWithPath: noteID)) } label: {
                    Text(noteTitle)
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(Color(nsColor: theme.resolvedLinkColor))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open \(noteTitle)")
                Spacer(minLength: Spacing.s)
                Button { showCompleted.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showCompleted ? "checkmark.square" : "square")
                            .font(.system(size: 10 * scale, weight: .bold))
                        Text("Completed")
                    }
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(showCompleted ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Show completed tasks")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.s)
            Divider()
            TaskDocumentView(
                lines: lines,
                theme: theme,
                onCommit: { nid, line, occ, newLine in
                    newLine == line ? occ : rewrite(nid, line, occ, to: newLine)
                },
                onComplete: { nid, line, occ in
                    TaskPage.toggledLine(line).flatMap { rewrite(nid, line, occ, to: $0) }
                },
                onOpenNote: { nid, _ in onOpenNote(URL(fileURLWithPath: nid)) },
                onAddSubtask: { nid, line, occ in
                    openNewTask(store.note(withID: nid).flatMap { TaskPage.newSubtask(under: line, occurrence: occ, in: $0.content) },
                                noteID: nid, after: line, occurrence: occ)
                },
                onAddTaskBelow: { nid, line, occ in
                    openNewTask(store.note(withID: nid).flatMap { TaskPage.newTask(after: line, occurrence: occ, in: $0.content) },
                                noteID: nid, after: line, occurrence: occ)
                },
                focusNoteID: focusNoteID,
                focusLine: focusLine,
                onFocusConsumed: { focusNoteID = nil; focusLine = nil; focusOccurrence = nil },
                singleNote: true,
                showCompleted: $showCompleted,
                onAddEmptyTask: {
                    // Reuse an existing empty task rather than stacking blanks;
                    // either way it's the first (only fresh) copy of that line.
                    let empty = "- [ ] "
                    if lineExists(empty) {
                        focusNoteID = noteID; focusLine = empty; focusOccurrence = 0
                    } else if let line = store.appendEmptyTask(toNoteID: noteID) {
                        focusNoteID = noteID; focusLine = line; focusOccurrence = 0
                    }
                },
                onDeleteEmpty: { nid, line, occ in
                    write(nid, restructure: true) { store.deleteEmptyTaskLine(noteID: nid, line: line, occurrence: occ) }
                },
                onMoveTask: { nid, line, occ, target, targetOcc, below in
                    write(nid, restructure: true) {
                        store.moveTaskLine(noteID: nid, line: line, occurrence: occ,
                                           beside: target, targetOccurrence: targetOcc, after: below)
                    }
                },
                onShiftTask: { nid, line, occ, outward in
                    guard let content = store.note(withID: nid)?.content else { return nil }
                    var shifted: String?
                    let ok = write(nid) {
                        shifted = store.shiftTaskLine(noteID: nid, line: line, occurrence: occ, outward: outward)
                        return shifted != nil
                    }
                    guard ok, let shifted,
                          let newOcc = TaskPage.occurrenceAfterRewrite(of: line, occurrence: occ, to: shifted, in: content) else { return nil }
                    return (shifted, newOcc)
                },
                focusOccurrence: focusOccurrence
            )
            .environment(\.interfaceFontScale, scale)
        }
        .background(Color(nsColor: theme.resolvedBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { recompute() }
        .onChange(of: store.notes) { _, _ in recompute() }
        .onChange(of: showCompleted) { _, _ in recompute() }
    }

    private func lineExists(_ line: String) -> Bool {
        guard let note = store.note(withID: noteID) else { return false }
        return TaskPage.openTasks(in: note).contains { $0.sourceLine == line }
    }

    /// Insert an empty task line, show it at once, and drop into exactly
    /// that copy — the note may hold other empty tasks.
    private func openNewTask(_ new: (line: String, occurrence: Int)?, noteID: String, after line: String, occurrence: Int) {
        guard let new, write(noteID, restructure: true, {
            store.insertTaskLine(noteID: noteID, afterLine: line, occurrence: occurrence, newLine: new.line)
        }) else { return }
        focusNoteID = noteID
        focusLine = new.line
        focusOccurrence = new.occurrence
    }

    /// Rewrite one task line in place (an edit or a check) and show it at
    /// once. Returns which copy of its text the line now is, or nil.
    private func rewrite(_ noteID: String, _ line: String, _ occurrence: Int, to newLine: String) -> Int? {
        guard let content = store.note(withID: noteID)?.content,
              let newOccurrence = TaskPage.occurrenceAfterRewrite(of: line, occurrence: occurrence, to: newLine, in: content),
              write(noteID, {
                  store.rewriteTaskLine(noteID: noteID, originalLine: line, occurrence: occurrence, with: newLine)
              }) else { return nil }
        return newOccurrence
    }

    /// One write from the panel, shown the instant it lands: the written
    /// note's rows are re-read from its new text (exact, nothing guessed), and
    /// any rescan already in flight — snapshotted before this write — is
    /// superseded so it can't land stale over it. A missed write shows nothing
    /// and rebuilds instead.
    private func write(_ noteID: String, restructure: Bool = false, _ op: () -> Bool) -> Bool {
        generation += 1
        let before = store.note(withID: noteID)
        guard op(), let note = store.note(withID: noteID) else {
            recompute()
            return false
        }
        lines = restructure
            ? TaskPage.restructured(lines, from: note, before: before, includeCompleted: showCompleted)
            : TaskPage.refreshing(lines, from: note, includeCompleted: showCompleted)
        return true
    }

    /// This note's open tasks, off the main thread for consistency (a single
    /// note is cheap, but this keeps the pattern identical to the vault panel).
    private func recompute() {
        generation += 1
        let g = generation
        let id = noteID
        let snapshot = store.notes
        let incl = showCompleted
        let shown = lines
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> (lines: [OpenTask], unchanged: Bool) in
                guard let note = snapshot.first(where: { $0.id == id }) else { return ([], shown.isEmpty) }
                let fresh = incl ? TaskPage.allTasks(in: note) : TaskPage.openTasks(in: note)
                return (fresh, fresh == shown)
            }.value
            guard g == generation else { return }
            // Already on screen (a write from this panel shows at once).
            if !result.unchanged { lines = result.lines }
        }
    }
}

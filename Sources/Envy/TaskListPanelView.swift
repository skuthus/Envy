import SwiftUI
import EnvyCore

/// The task list inside the miniature menu-bar panel — the same
/// `TaskDocumentView` the main window shows, but driven by the app's shared
/// `NoteStore` (handed in by AppDelegate, so there's no second vault load and
/// it stays in sync) and writing straight back through it.
struct TaskListPanelView: View {
    @ObservedObject var store: NoteStore
    /// Open the note in the main app and close the panel.
    var onOpenNote: (URL) -> Void

    @AppStorage("theme") private var theme = Theme()
    @AppStorage("interfaceTextSize") private var interfaceTextSizeRaw = InterfaceTextSize.large.rawValue

    @State private var lines: [OpenTask] = []
    @AppStorage("taskShowCompleted") private var showCompleted = false
    @State private var generation = 0
    /// The Completed setting the rows on screen were built with; nil until the
    /// first build (or after reopening) — see recompute.
    @State private var shownIncludesCompleted: Bool?
    @State private var focusNoteID: String?
    @State private var focusLine: String?
    @State private var focusOccurrence: Int?

    private var scale: CGFloat { (InterfaceTextSize(rawValue: interfaceTextSizeRaw) ?? .large).scale }

    var body: some View {
        TaskDocumentView(
            lines: lines,
            theme: theme,
            onCommit: { noteID, line, occ, newLine in
                newLine == line ? occ : rewrite(noteID, line, occ, to: newLine)
            },
            onComplete: { noteID, line, occ in
                TaskPage.toggledLine(line).flatMap { rewrite(noteID, line, occ, to: $0) }
            },
            onOpenNote: { noteID, _ in onOpenNote(URL(fileURLWithPath: noteID)) },
            onAddTask: { _ = store.appendTaskLine($0) },
            onAddSubtask: { noteID, line, occ in
                openNewTask(store.note(withID: noteID).flatMap { TaskPage.newSubtask(under: line, occurrence: occ, in: $0.content) },
                            noteID: noteID, after: line, occurrence: occ)
            },
            onAddTaskBelow: { noteID, line, occ in
                openNewTask(store.note(withID: noteID).flatMap { TaskPage.newTask(after: line, occurrence: occ, in: $0.content) },
                            noteID: noteID, after: line, occurrence: occ)
            },
            focusNoteID: focusNoteID,
            focusLine: focusLine,
            onFocusConsumed: { focusNoteID = nil; focusLine = nil; focusOccurrence = nil },
            showCompleted: $showCompleted,
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
        .background(Color(nsColor: theme.resolvedBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            shownIncludesCompleted = nil
            recompute()
        }
        .onChange(of: store.notes) { _, _ in recompute() }
        .onChange(of: showCompleted) { _, _ in recompute() }
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

    /// Off the main thread, exactly like the main window's pipeline — a
    /// whole-vault task scan is ~100ms and must never block the panel.
    private func recompute() {
        generation += 1
        let g = generation
        let snapshot = store.notes
        let incl = showCompleted
        // Same page as on screen: keep its order and skip an identical update
        // (see ContentView.recomputeFilteredNotes).
        let shown = lines
        let samePage = shownIncludesCompleted == incl
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> (lines: [OpenTask], unchanged: Bool) in
                var fresh = TaskPage.lines(in: snapshot, query: "tasks:", includeCompleted: incl)
                if samePage { fresh = TaskPage.stabilized(fresh, toOrderOf: shown) }
                return (fresh, fresh == shown)
            }.value
            guard g == generation else { return }
            if !result.unchanged { lines = result.lines }
            shownIncludesCompleted = incl
        }
    }
}

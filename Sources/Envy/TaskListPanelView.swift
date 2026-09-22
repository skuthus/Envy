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

    private var scale: CGFloat { (InterfaceTextSize(rawValue: interfaceTextSizeRaw) ?? .large).scale }

    var body: some View {
        TaskDocumentView(
            lines: lines,
            theme: theme,
            onCommit: { noteID, line, occ, newLine in
                write(noteID) { store.rewriteTaskLine(noteID: noteID, originalLine: line, occurrence: occ, with: newLine) }
            },
            onComplete: { noteID, line, occ in
                guard let toggled = TaskPage.toggledLine(line) else { return false }
                return write(noteID) { store.rewriteTaskLine(noteID: noteID, originalLine: line, occurrence: occ, with: toggled) }
            },
            onOpenNote: { noteID, _ in onOpenNote(URL(fileURLWithPath: noteID)) },
            onAddTask: { _ = store.appendTaskLine($0) },
            onAddSubtask: { noteID, line, occ in
                let child = TaskPage.subtaskLine(under: line)
                if lineExists(child, in: noteID)
                    || store.insertTaskLine(noteID: noteID, afterLine: line, occurrence: occ, newLine: child) {
                    focusNoteID = noteID; focusLine = child
                }
            },
            onAddTaskBelow: { noteID, line, occ in
                let sibling = TaskPage.siblingLine(of: line)
                if lineExists(sibling, in: noteID)
                    || store.insertTaskLine(noteID: noteID, afterLine: line, occurrence: occ, newLine: sibling) {
                    focusNoteID = noteID; focusLine = sibling
                }
            },
            focusNoteID: focusNoteID,
            focusLine: focusLine,
            onFocusConsumed: { focusNoteID = nil; focusLine = nil },
            showCompleted: $showCompleted
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

    private func lineExists(_ line: String, in noteID: String) -> Bool {
        guard let note = store.note(withID: noteID) else { return false }
        return TaskPage.openTasks(in: note).contains { $0.sourceLine == line }
    }

    /// One write from the panel, shown the instant it lands: the written
    /// note's rows are re-read from its new text (exact, nothing guessed), and
    /// any rescan already in flight — snapshotted before this write — is
    /// superseded so it can't land stale over it. A missed write shows nothing
    /// and rebuilds instead.
    private func write(_ noteID: String, _ op: () -> Bool) -> Bool {
        generation += 1
        guard op(), let note = store.note(withID: noteID) else {
            recompute()
            return false
        }
        lines = TaskPage.refreshing(lines, from: note, includeCompleted: showCompleted)
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

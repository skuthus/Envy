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
    @State private var generation = 0
    @State private var focusNoteID: String?
    @State private var focusLine: String?

    private var scale: CGFloat { (InterfaceTextSize(rawValue: interfaceTextSizeRaw) ?? .large).scale }

    var body: some View {
        TaskDocumentView(
            lines: lines,
            theme: theme,
            onCommit: { noteID, line, occ, newLine in
                store.rewriteTaskLine(noteID: noteID, originalLine: line, occurrence: occ, with: newLine)
            },
            onComplete: { noteID, line, occ in
                if let done = TaskPage.completedLine(line) {
                    store.rewriteTaskLine(noteID: noteID, originalLine: line, occurrence: occ, with: done)
                }
            },
            onOpenNote: { noteID, _ in onOpenNote(URL(fileURLWithPath: noteID)) },
            onAddTask: { _ = store.appendTaskLine($0) },
            onAddSubtask: { noteID, line, occ in
                let child = TaskPage.subtaskLine(under: line)
                if store.insertTaskLine(noteID: noteID, afterLine: line, occurrence: occ, newLine: child) {
                    focusNoteID = noteID; focusLine = child
                }
            },
            onAddTaskBelow: { noteID, line, occ in
                let sibling = TaskPage.siblingLine(of: line)
                if store.insertTaskLine(noteID: noteID, afterLine: line, occurrence: occ, newLine: sibling) {
                    focusNoteID = noteID; focusLine = sibling
                }
            },
            focusNoteID: focusNoteID,
            focusLine: focusLine,
            onFocusConsumed: { focusNoteID = nil; focusLine = nil }
        )
        .environment(\.interfaceFontScale, scale)
        .background(Color(nsColor: theme.resolvedBackgroundColor))
        .onAppear { recompute() }
        .onChange(of: store.notes) { _, _ in recompute() }
    }

    /// Off the main thread, exactly like the main window's pipeline — a
    /// whole-vault task scan is ~100ms and must never block the panel.
    private func recompute() {
        generation += 1
        let g = generation
        let snapshot = store.notes
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                TaskPage.lines(in: snapshot, query: "tasks:")
            }.value
            guard g == generation else { return }
            lines = result
        }
    }
}

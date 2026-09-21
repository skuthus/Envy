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
    @State private var showCompleted = false
    @State private var generation = 0
    @State private var focusNoteID: String?
    @State private var focusLine: String?

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
                    store.rewriteTaskLine(noteID: nid, originalLine: line, occurrence: occ, with: newLine)
                },
                onComplete: { nid, line, occ in
                    if let toggled = TaskPage.toggledLine(line) {
                        store.rewriteTaskLine(noteID: nid, originalLine: line, occurrence: occ, with: toggled)
                    }
                },
                onOpenNote: { nid, _ in onOpenNote(URL(fileURLWithPath: nid)) },
                onAddTask: { _ = store.appendTaskLine(toNoteID: noteID, $0) },
                onAddSubtask: { nid, line, occ in
                    let child = TaskPage.subtaskLine(under: line)
                    if store.insertTaskLine(noteID: nid, afterLine: line, occurrence: occ, newLine: child) {
                        focusNoteID = nid; focusLine = child
                    }
                },
                onAddTaskBelow: { nid, line, occ in
                    let sibling = TaskPage.siblingLine(of: line)
                    if store.insertTaskLine(noteID: nid, afterLine: line, occurrence: occ, newLine: sibling) {
                        focusNoteID = nid; focusLine = sibling
                    }
                },
                focusNoteID: focusNoteID,
                focusLine: focusLine,
                onFocusConsumed: { focusNoteID = nil; focusLine = nil },
                singleNote: true,
                showCompleted: $showCompleted,
                onAddEmptyTask: {
                    if let line = store.appendEmptyTask(toNoteID: noteID) {
                        focusNoteID = noteID
                        focusLine = line
                    }
                }
            )
            .environment(\.interfaceFontScale, scale)
        }
        .background(Color(nsColor: theme.resolvedBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { recompute() }
        .onChange(of: store.notes) { _, _ in recompute() }
        .onChange(of: showCompleted) { _, _ in recompute() }
    }

    /// This note's open tasks, off the main thread for consistency (a single
    /// note is cheap, but this keeps the pattern identical to the vault panel).
    private func recompute() {
        generation += 1
        let g = generation
        let id = noteID
        let snapshot = store.notes
        let incl = showCompleted
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> [OpenTask] in
                guard let note = snapshot.first(where: { $0.id == id }) else { return [] }
                return incl ? TaskPage.allTasks(in: note) : TaskPage.openTasks(in: note)
            }.value
            guard g == generation else { return }
            lines = result
        }
    }
}

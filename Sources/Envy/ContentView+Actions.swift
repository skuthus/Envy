import SwiftUI
import AppKit
import EnvyCore

// Everything that acts on notes and templates: create/rename/delete
// (single and bulk), context menus, template CRUD, switching The Index to
// a different folder, and the first-launch/what's-new flows. Split out of
// ContentView.swift purely for file size/navigability — same type, zero
// behavior change.
extension ContentView {
    // MARK: - Enter & creation

    func handleEnter() {
        if isTemplateQuery {
            actOnHighlightedTemplate()
            return
        }
        // A search operator's "highlighted note" is whatever
        // reconcileSelection() already settled selectedID on as the list
        // narrowed — Enter just moves into it, same as the empty-query case
        // below, rather than falling through to the exact-match/create-new-
        // note logic (which would otherwise create a note literally titled
        // "tag:xyz" or "date:xyz").
        if isSearchOperatorQuery {
            if selectedID != nil, moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }
        if let exact = store.exactTitleMatch(for: query) {
            editingTemplate = nil
            selectedID = exact.id
            if moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if selectedID != nil, moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }

        let newNote = store.create(title: trimmed)
        editingTemplate = nil
        selectedID = newNote.id
        query = ""
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    func createBlankNote() {
        let note = store.create(title: "")
        editingTemplate = nil
        selectedID = note.id
        query = ""
        focusedField = .editor
    }

    func navigateToNote(titled title: String) {
        let target = store.exactTitleMatch(for: title) ?? store.create(title: title)
        editingTemplate = nil
        selectedID = target.id
        query = ""
    }

    /// Clicking a tag chip in the editor's title bar — searches for it like
    /// typing "tag:whatever" would, without disturbing the currently open
    /// note. reconcileSelection() (already run from query's own .onChange)
    /// only clears selectedID if it's no longer in the filtered results;
    /// since this note itself has the tag being searched, it's always still
    /// in that list, so it stays selected with no extra handling needed here.
    func searchByTag(_ tag: String) {
        query = "tag:\(tag)"
        focusedField = .search
    }

    // MARK: - Templates

    /// "template:xyz" creates from whichever template is highlighted (arrow
    /// keys move highlightedTemplateID same as selectedID does for a plain
    /// note search), falling back to the top match if nothing's highlighted
    /// yet — shared by both the search field's Return and the note list's
    /// own Return, so either one acts on the template list the same way.
    func actOnHighlightedTemplate() {
        if let template = matchingTemplatesForQuery.first(where: { $0.id == highlightedTemplateID }) ?? matchingTemplatesForQuery.first {
            createFromTemplate(template, title: template.name)
        } else if let fragment = templateNameFragment?.trimmingCharacters(in: .whitespaces), !fragment.isEmpty {
            createTemplate(named: fragment)
        }
    }

    func createFromTemplate(_ template: NoteTemplate, title: String) {
        let note = store.create(title: title, fromTemplate: template, dateText: templateDateText)
        editingTemplate = nil
        selectedID = note.id
        query = ""
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    /// "template:xyz" with no existing match — same shape as a plain search
    /// offering to create a note from unmatched text, just creating a new
    /// (empty) template and dropping straight into editing it instead.
    /// query resets to the bare "template:" prefix (not ""), so the list
    /// keeps showing templates — including the one just created — rather
    /// than snapping back to the regular note list.
    func createTemplate(named name: String) {
        let template = store.createTemplate(named: name)
        editingTemplate = template
        query = "template:"
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    /// Trashed (not permanently removed) — same recoverable-via-Finder
    /// safety margin as a deleted note gets from NoteStore.delete(_:).
    func deleteTemplate(_ template: NoteTemplate) {
        store.suppressReloadForExternalWrite()
        try? FileManager.default.trashItem(at: template.url, resultingItemURL: nil)
        if editingTemplate?.id == template.id {
            editingTemplate = nil
        }
        if highlightedTemplateID == template.id {
            highlightedTemplateID = nil
        }
    }

    func convertNoteToTemplate(_ note: Note) {
        guard store.convertToTemplate(note) != nil else { return }
        if selectedID == note.id {
            selectedID = nil
        }
        multiSelectedIDs.remove(note.id)
    }

    /// Lands back in sourceDirectory (or defaultDirectory if that folder's
    /// no longer configured) and opens right in the editor as a regular
    /// note — see NoteStore.convertToNote(_:) for the fallback logic.
    func convertTemplateToNote(_ template: NoteTemplate) {
        guard let note = store.convertToNote(template) else { return }
        if editingTemplate?.id == template.id {
            editingTemplate = nil
        }
        if highlightedTemplateID == template.id {
            highlightedTemplateID = nil
        }
        selectedID = note.id
        query = ""
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    /// Seeds Templates/ with a few starter templates the very first time the
    /// app launches — same gated-by-a-persisted-flag pattern as
    /// createWelcomeNoteIfNeeded(), and written directly rather than via
    /// store.create() since templates are never part of the visible notes
    /// list.
    func seedSampleTemplatesIfNeeded() {
        guard !hasSeededSampleTemplates else { return }
        hasSeededSampleTemplates = true

        let templatesDirectory = store.noteDirectory.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        for sample in TemplateContent.samples {
            let url = templatesDirectory.appendingPathComponent("\(sample.name).md")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? sample.body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Delete / restore / move / rename

    func deleteSelected() {
        if fullSelection.count > 1 {
            bulkDelete()
            return
        }
        guard let currentID = selectedID, let note = store.notes.first(where: { $0.id == currentID }) else { return }
        deleteNote(note)
    }

    func deleteNote(_ note: Note) {
        store.delete(note)
        if selectedID == note.id {
            selectedID = filteredNotes.first?.id
        }
        focusedField = .search
    }

    func bulkOpenInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedNotes().map(\.url))
    }

    func bulkDelete() {
        // A single call so the whole selection is recorded as one delete
        // action — restoring afterward brings back every note, not just
        // the last one a loop of individual deletes would have remembered.
        store.delete(selectedNotes())
        multiSelectedIDs.removeAll()
        selectedID = filteredNotes.first?.id
        focusedField = .search
    }

    func restoreLastDeleted() {
        let restored = store.restoreLastDeleted()
        guard let first = restored.first else { return }
        if restored.count == 1 {
            selectedID = first.id
        }
        focusedField = .search
    }

    func renameNote(_ note: Note, to newTitle: String) {
        let renamed = store.rename(note, to: newTitle)
        carryPinnedStatus(from: note.id, to: renamed.id)
        if selectedID == note.id {
            selectedID = renamed.id
        }
    }

    func renameSelectedNote(to newTitle: String) {
        guard let currentID = selectedID, let note = store.notes.first(where: { $0.id == currentID }) else { return }
        renameNote(note, to: newTitle)
    }

    // MARK: - Context menus

    @ViewBuilder
    func singleContextMenuItems(for note: Note) -> some View {
        Button(isPinned(note) ? "Unpin Note" : "Pin Note") {
            togglePin(note)
        }
        Button(isMenuBarPinned(note) ? "Unpin from Menu Bar" : "Pin to Menu Bar") {
            toggleMenuBarPin(note)
        }
        Button("Rename") {
            renameText = note.title
            renamingNote = note
        }
        Button("Open in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([note.url])
        }
        Button("Make This Note a Template") {
            convertNoteToTemplate(note)
        }
        Button("Delete", role: .destructive) {
            deleteNote(note)
        }
    }

    @ViewBuilder
    var bulkContextMenuItems: some View {
        let count = fullSelection.count
        Button("Open \(count) Notes in Finder") {
            bulkOpenInFinder()
        }
        Button("Delete \(count) Notes", role: .destructive) {
            bulkDelete()
        }
    }

    // MARK: - The Index

    /// Re-points the store at whatever folder Settings now has saved —
    /// fires from the `indexPathRaw` AppStorage's own onChange, so this is
    /// the one place a location change picked in Settings actually takes
    /// effect on the live store.
    func switchIndexDirectory() {
        store.setDirectory(IndexPreference.load())
        query = ""
        // Deliberately NOT touching selectedID here: setDirectory() reloads
        // asynchronously, so store.notes at this exact point is still the
        // *previous* folder's notes — picking .first from it here would grab
        // a note that's about to disappear. Keeping the current selection
        // (still valid until the reload actually replaces store.notes) means
        // the editor keeps showing it right up until the swap, instead of a
        // premature flash to "No Note Selected" and back. The onChange(of:
        // store.notes) reconciles it once the new notes actually land.
        focusedField = .search
    }

    /// Blanks the title text rather than toggling titleVisibility — with a
    /// unified/fullSizeContentView toolbar, .hidden makes AppKit recompute the
    /// toolbar's space distribution and the trailing items visibly jump toward
    /// center. Keeping the title slot reserved (just empty) avoids that.
    func applyWindowTitleVisibility() {
        guard let window = NSApp.windows.first else { return }
        if cachedWindowTitle == nil {
            cachedWindowTitle = window.title.isEmpty ? "Envy" : window.title
        }
        window.titleVisibility = .visible
        window.title = cachedWindowTitle ?? "Envy"
    }

    // MARK: - First launch & updates

    /// Seeds the default folder with a welcome note (and a small companion note
    /// it links to) the very first time the app launches, and opens it. Gated by
    /// a persisted flag rather than "notes list is empty" so it only ever fires
    /// once, even if the user later deletes every note.
    func createWelcomeNoteIfNeeded() {
        guard !hasCreatedWelcomeNote else { return }
        hasCreatedWelcomeNote = true

        let linked = store.create(title: WelcomeContent.linkedNoteTitle)
        var linkedWithBody = linked
        linkedWithBody.content = WelcomeContent.linkedNoteBody
        store.save(linkedWithBody)

        let welcome = store.create(title: WelcomeContent.title)
        var welcomeWithBody = welcome
        welcomeWithBody.content = WelcomeContent.welcomeBody
        store.save(welcomeWithBody)

        selectedID = welcome.id
    }

    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    func showWhatsNewIfUpdated() {
        let version = currentAppVersion
        guard !version.isEmpty, version != lastSeenWhatsNewVersion else { return }
        lastSeenWhatsNewVersion = version
        // This fires from the main window's own onAppear, which can race
        // with AppDelegate's launch-time makeKeyAndOrderFront on that same
        // main window (applicationDidFinishLaunching is a separate AppKit
        // callback with no guaranteed ordering against SwiftUI's view
        // lifecycle) — without the delay and explicit refocus below, the
        // new window can end up opened behind the main one instead of
        // in front of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            openWindow(id: "whatsnew")
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "What's New" })?.makeKeyAndOrderFront(nil)
        }
    }
}

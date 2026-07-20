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
        // Browsing trash: never acts on its own — Restore/Delete are always
        // an explicit button (in the preview pane) or right-click away, not
        // a side effect of typing/highlighting/pressing Return.
        if isTrashQuery {
            return
        }
        // inbox: is the one browse operator where Return *writes*. Typing
        // "inbox: call mom" and pressing Return captures it, because the
        // operator that scopes the box is the one that routes writing into
        // it — no second syntax to learn, and the same shape as the ordinary
        // "type a title, press Return" the search box already has. A bare
        // "inbox:" with nothing typed just moves into whatever's waiting.
        if isInboxQuery {
            let fragment = inboxNameFragment?.trimmingCharacters(in: .whitespaces) ?? ""
            if fragment.isEmpty || matchingInboxForQuery.contains(where: { $0.lowercasedTitle == fragment.lowercased() }) {
                // Nothing typed, or an exact match — a note you're looking
                // for, not one you're making. Same rule the main search box
                // follows; selection is the ordinary selectedID.
                if selectedID != nil, moveFocusToEditorOnEnter { focusedField = .editor }
            } else {
                captureToInbox()
            }
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
            selectedID = exact.id
            if moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if selectedID != nil, moveFocusToEditorOnEnter { focusedField = .editor }
            return
        }

        let newNote = createNoteWhereNewNotesGo(titled: trimmed)
        selectedID = newNote.id
        query = queryShowing(newNote)
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    /// Creates a note wherever new notes are supposed to go — Inbox/ when
    /// "New notes start in the Inbox" is on, The Index otherwise.
    ///
    /// The setting turns capture into the default and filing into a
    /// deliberate act, which is the whole slipbox discipline: nothing enters
    /// the permanent collection without someone deciding it should.
    ///
    /// Used by every path that makes a note from nothing, including
    /// following a [[link]] to one that doesn't exist yet. Being linked-to
    /// and being filed are different things: that note is a title with no
    /// body — a promise to write something, which is the most fleeting thing
    /// in the app, not the least. Wiki-links resolve by title across every
    /// note, so one living in Inbox/ is found exactly as before.
    ///
    /// Not used for notes made from a template, which arrive with structure
    /// and content because you chose them deliberately.
    func createNoteWhereNewNotesGo(titled title: String) -> Note {
        newNotesStartInInbox ? store.createInboxNote(titled: title) : store.create(title: title)
    }

    /// The query to leave in the search box after creating `note` — normally
    /// empty, but "inbox:" for a fleeting note while fleeting notes are
    /// hidden from the list.
    ///
    /// Without this, creating into the Inbox with them hidden clears the
    /// query to nothing, the new note isn't in the list that produces, and
    /// reconcileSelection() moves the selection to whatever is first —
    /// so the note you just wrote is neither shown nor focused.
    func queryShowing(_ note: Note) -> String {
        NoteStore.isInInboxFolder(note) && !showInboxInMainList ? "inbox:" : ""
    }

    func createBlankNote() {
        let note = createNoteWhereNewNotesGo(titled: "")
        selectedID = note.id
        query = queryShowing(note)
        focusedField = .editor
    }

    func navigateToNote(titled title: String) {
        let target = store.exactTitleMatch(for: title) ?? createNoteWhereNewNotesGo(titled: title)
        selectedID = target.id
        query = queryShowing(target)

        // Deferred, not assigned inline. NoteEditorView carries .id(selectedID),
        // so changing the selection destroys the editor and builds a new one —
        // and SwiftUI clears focusedField to nil when the view holding focus
        // disappears. Setting it before that happens assigns focus to a view
        // that's already doomed, and the rebuild wipes it.
        //
        // This only bites when you're navigating *from* the editor, which is
        // exactly the wiki-link case: coming from the search box there's no
        // editor focus to lose, so the newly built view picks up .editor on
        // its own. That's why following a link appeared to work — AppKit's
        // first responder lingered on the reused text view even though
        // SwiftUI's own focus state had gone nil.
        DispatchQueue.main.async {
            focusedField = .editor
        }
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
    /// note search) — this is Return's own action, the same one the "Create
    /// Note from Template" button (in the editor pane's header, or the
    /// row's own right-click menu) triggers. Clicking/arrowing to a row
    /// itself only opens it for editing (see matchingTemplateRows); creating
    /// a note is always this separate, deliberate step. Falls back to
    /// creating a brand-new template if there's no match to highlight yet.
    func actOnHighlightedTemplate() {
        if let template = matchingTemplatesForQuery.first(where: { $0.id == highlightedTemplateID }) ?? matchingTemplatesForQuery.first {
            createFromTemplate(template, title: template.name)
        } else if let fragment = templateNameFragment?.trimmingCharacters(in: .whitespaces), !fragment.isEmpty {
            createTemplate(named: fragment)
        }
    }

    func createFromTemplate(_ template: NoteTemplate, title: String) {
        let note = store.create(title: title, fromTemplate: template, dateText: templateDateText)
        selectedID = note.id
        query = ""
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    /// "template:xyz" with no existing match — same shape as a plain search
    /// offering to create a note from unmatched text, just creating a new
    /// (empty) template instead. query resets to the bare "template:" prefix
    /// (not ""), so the list keeps showing templates — including the one
    /// just created, now highlighted — rather than snapping back to the
    /// regular note list. Highlighting it (not a separate "editing" flag) is
    /// what puts it straight into the editable preview pane, ready to type
    /// into immediately.
    func createTemplate(named name: String) {
        let template = store.createTemplate(named: name)
        highlightedTemplateID = template.id
        query = "template:"
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    /// Trashed (not permanently removed) — same recoverable-via-Finder
    /// safety margin as a deleted note gets from NoteStore.delete(_:).
    func deleteTemplate(_ template: NoteTemplate) {
        store.suppressReloadForExternalWrite()
        try? FileManager.default.trashItem(at: template.url, resultingItemURL: nil)
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

    /// Lands back at the top of The Index and opens right in the editor as
    /// a regular note.
    func convertTemplateToNote(_ template: NoteTemplate) {
        guard let note = store.convertToNote(template) else { return }
        if highlightedTemplateID == template.id {
            highlightedTemplateID = nil
        }
        selectedID = note.id
        query = ""
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    // MARK: - Trash

    /// Files a fleeting note into The Index — a plain move out of `Inbox/`.
    /// Stays in inbox: browsing afterwards rather than following the note:
    /// review is a run of decisions, and being thrown elsewhere after each
    /// one would break it every time.
    func submitFromInbox(_ note: Note) {
        let next = matchingInboxForQuery.first { $0.id != note.id }?.id
        store.submitFromInbox(note)
        if selectedID == note.id { selectedID = next }
    }

    /// Discards a fleeting note through the ordinary soft delete, so it
    /// lands in `.trash` and ⌘⇧⌫ still brings it back — a fleeting note is
    /// the easiest kind to throw away by accident.
    func deleteFromInbox(_ note: Note) {
        let next = matchingInboxForQuery.first { $0.id != note.id }?.id
        store.delete(note)
        if selectedID == note.id { selectedID = next }
    }

    /// Captures whatever is typed after `inbox:` as a new fleeting note —
    /// the operator that scopes the box also routes the writing, so there's
    /// no second syntax for capture.
    func captureToInbox() {
        guard let fragment = inboxNameFragment else { return }
        let title = fragment.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let note = store.createInboxNote(titled: title)
        // Deliberately the same order as the ordinary create above —
        // selection, then query, then focus, all in one synchronous pass.
        // Setting the query first (or deferring the selection into a task)
        // both leave SwiftUI applying focus around a selection change it
        // hasn't rendered yet, and the focus is dropped. The debounced
        // reconcileSelection that follows keeps this selection, since a
        // freshly captured note matches "inbox:" by definition.
        selectedID = note.id
        // Back to a bare "inbox:" — you're still in the box, ready for the
        // next thought, rather than leaving the last capture sitting there
        // looking like a filter.
        query = "inbox:"
        if moveFocusToEditorOnEnter { focusedField = .editor }
    }

    /// Restores a trashed note without leaving trash: browsing — the
    /// OmniBar's query is what decides which section is showing, not
    /// anything an action inside that section does, so restoring (like
    /// deleting) never touches `query`. Advances the highlight to whatever's
    /// now first, same as deleteFromTrash() below.
    func restoreFromTrash(_ note: Note) {
        let wasHighlighted = highlightedTrashID == note.id
        guard store.restoreFromTrash(note) != nil else { return }
        if wasHighlighted {
            highlightedTrashID = matchingTrashForQuery.first?.id
        }
    }

    /// Moves a trashed note straight into the real macOS Trash — still
    /// recoverable there afterward, same as what the scheduled sweep does
    /// to the whole .trash/ folder. Advances the highlight to whatever's
    /// now first, same as deleteNote() does for the regular note list,
    /// rather than leaving the preview pane blank after a deliberate delete.
    func deleteFromTrash(_ note: Note) {
        let wasHighlighted = highlightedTrashID == note.id
        store.deleteFromTrash(note)
        if wasHighlighted {
            highlightedTrashID = matchingTrashForQuery.first?.id
        }
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
        Button("Move to Trash", role: .destructive) {
            deleteNote(note)
        }
    }

    @ViewBuilder
    var bulkContextMenuItems: some View {
        let count = fullSelection.count
        Button("Open \(count) Notes in Finder") {
            bulkOpenInFinder()
        }
        Button("Move \(count) Notes to Trash", role: .destructive) {
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

    /// The window carries no title text. The app's own chrome already names
    /// it — the icon in the Dock, the note title in the editor header — so a
    /// literal "Envy" beside the traffic lights is a label for something the
    /// user is already looking at.
    ///
    /// Blanked rather than hidden via titleVisibility: with a unified,
    /// fullSizeContentView toolbar, .hidden makes AppKit recompute the
    /// toolbar's space distribution and the trailing items visibly jump
    /// toward center. Keeping the slot reserved but empty avoids that.
    ///
    /// Re-applied rather than set once, because SwiftUI reasserts the title
    /// declared on WindowGroup after its own deferred window setup.
    func applyWindowTitleVisibility() {
        guard let window = NSApp.windows.first else { return }
        window.titleVisibility = .visible
        window.title = ""
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

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
        // Bare "tag:" browser: Return drills into the highlighted tag (the
        // top/most-used one by default), filling "tag:name" so the list
        // flips to that tag's notes — the picker step complete.
        if isTagBrowseQuery {
            if let name = highlightedTagName ?? browserTagCounts.first?.name {
                searchByTag(name)
            }
            return
        }
        // Bare "folder:" browser: the same drill-in, into the highlighted
        // folder.
        if isFolderBrowseQuery {
            if let name = highlightedFolderName ?? subfolderCache.first {
                searchByFolder(name)
            }
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
        // "Work/Retro notes" creates "Retro notes" inside Work/ — the slash
        // is the folder picker, the way a flat-file omnibar should think. An
        // explicit path also overrides the start-in-Inbox default: naming a
        // destination is the filing decision that setting exists to force.
        if let target = folderTargetedCreation(from: title) {
            let note = store.create(title: target.title, inSubfolder: target.folder)
            // Same surgical cache update a move does, so the new row shows
            // its folder marker immediately without a full recompute.
            noteSubfolderCache[note.id] = target.folder
            if let color = folderColorMap[target.folder] { noteFolderColorCache[note.id] = color }
            return note
        }
        return newNotesStartInInbox ? store.createInboxNote(titled: title) : store.create(title: title)
    }

    /// Builds a note from a Continuity Camera capture (the camera pill beside
    /// search): titled "Note - MMDDYY - HHMMSS", body the captured pages embedded
    /// in order. Lands at the Index root, not the Inbox — reaching for the camera
    /// is itself the deliberate act that filing-to-Inbox otherwise forces. Then
    /// it selects the note and queues OCR for the new images so they're searchable.
    func createNoteFromCapture(imageNames: [String]) {
        guard !imageNames.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMddyy - HHmmss"
        let note = store.create(title: "Note - \(formatter.string(from: Date()))")
        var withImages = note
        // Each embed on its own line with the trailing blank line the block image
        // renderer reserves its room on — the same shape insertImageReference uses.
        withImages.content = imageNames.map { "![[\($0)]]\n\n" }.joined()
        store.save(withImages)
        query = queryShowing(note)
        selectedID = note.id
        if moveFocusToEditorOnEnter { focusedField = .editor }
        for name in imageNames { OCRIndex.shared.index(imageNamed: name, store: store) }
    }

    /// Splits "Folder/Title" into its parts when — and only when — the part
    /// before the last "/" case-insensitively matches an existing subfolder
    /// path (nested included: "Projects/Work/Note"). Deliberately never
    /// creates folders implicitly: a typo'd slash shouldn't quietly
    /// manufacture one, so unmatched slash-text falls through to ordinary
    /// creation (where sanitization turns "/" into "-", as ever). Nil when
    /// subfolder scanning is off — folders don't exist as a concept then.
    func folderTargetedCreation(from raw: String) -> (folder: String, title: String)? {
        guard indexIncludeSubfolders,
              let slash = raw.range(of: "/", options: .backwards) else { return nil }
        let folderPart = String(raw[..<slash.lowerBound]).trimmingCharacters(in: .whitespaces)
        let titlePart = String(raw[slash.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !folderPart.isEmpty, !titlePart.isEmpty,
              let match = subfolderCache.first(where: { $0.caseInsensitiveCompare(folderPart) == .orderedSame })
        else { return nil }
        return (match, titlePart)
    }

    /// Splits the selected text out into a note of its own, returning the title
    /// the editor should link to — the "one idea per note" move applied to
    /// something already written. Nil if the selection had nothing usable in it.
    ///
    /// Honours "New notes start in the Inbox" like every other way a note gets
    /// made — the omnibar, following a `[[link]]`, and now this. An extracted
    /// note is still a new note, and someone who wants everything to land in the
    /// Inbox first almost certainly means this too; splitting it onto its own
    /// switch would make one decision into two.
    ///
    /// The auto-derived title being imperfect is cheap on purpose — renaming a
    /// note rewrites every `[[link]]` aimed at it, so a better name later costs
    /// one rename, and a naming prompt here would interrupt the writing this is
    /// meant to keep flowing.
    func extractSelectionToNote(_ selection: String) -> String? {
        let (title, body) = NoteStore.extractedTitleAndBody(from: selection)
        var note = createNoteWhereNewNotesGo(titled: title)
        if !body.isEmpty {
            note.content = body
            store.save(note)
        }
        return note.title
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

        // Deferred, not assigned inline. The editor is reused across note
        // switches now (no per-note .id), but the same-turn hazard remains:
        // the selection change and this focus assignment land in one SwiftUI
        // update, and assigning focus in the middle of that update can lose to
        // the framework's own focus bookkeeping for the transition. One
        // runloop turn later the switch has settled and .editor sticks.
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
        // Quoted, and quoting means exact (see NoteStore.operatorArgument) —
        // clicking #tag must not also surface #tags, and the browser's count
        // must equal what the click shows.
        query = "tag:\"\(tag)\""
        // Fill the results synchronously so drilling in from the tag browser
        // shows the tag's notes at once, with no flash of the previous list
        // while the debounced search catches up — then settle exactly as the
        // debounced pipeline would, and tell it to stand down (it would only
        // redo this same work 60ms later).
        recomputeFilteredNotesSync()
        settleAfterQueryChange()
        suppressNextQueryDebounce = true
        focusedField = .search
    }

    /// Opens the rename dialog for a tag (from the tag browser's context
    /// menu), seeding the field with its current name.
    func beginTagRename(_ tag: String) {
        tagRenameText = tag
        tagRenameTarget = tag
    }

    /// Commits a tag rename — or, when the new name is an existing tag,
    /// stops to confirm first: that rename is really a *merge* (every #old
    /// becomes #new, and the two are one tag forever after), which deserves
    /// a deliberate yes rather than happening as a side effect of a typo.
    /// No-ops on an empty or unchanged name; NoteStore.renameTag sanitizes
    /// either way.
    func commitTagRename() {
        defer { tagRenameTarget = nil }
        guard let old = tagRenameTarget else { return }
        let new = NoteStore.sanitizedTagName(tagRenameText)
        guard !new.isEmpty, new.lowercased() != old else { return }
        if store.allTagsByFrequency().contains(new.lowercased()) {
            // One tick later, not inline — presenting the merge alert in the
            // same update that dismisses the rename alert can silently drop
            // the presentation.
            Task { @MainActor in pendingTagMerge = (old: old, new: new) }
            return
        }
        performTagRename(from: old, to: new)
    }

    /// The rename itself, after any confirmation. Carries the old tag's
    /// custom color to the new name only when the new name has none — on a
    /// merge the surviving tag keeps its own color (you folded #old *into*
    /// it, it doesn't change identity); either way the old name's color
    /// entry is cleaned up.
    func performTagRename(from old: String, to new: String) {
        // Any editor (main, peek, pop-out, pinned popup) may hold unsaved
        // typing containing the old tag; a debounced save landing after the
        // rewrite would put pre-rename text back. Flush first — notification
        // delivery is synchronous, so everything is committed before the
        // rename below reads the store.
        NotificationCenter.default.post(name: .flushPendingEditsRequested, object: nil)

        // Color entries are keyed by the lowercased tag name (tags are
        // lowercased everywhere), regardless of how the new name was typed.
        let newKey = new.lowercased()
        let raw = UserDefaults.standard.string(forKey: TagColorPreferences.storageKey) ?? ""
        if let color = TagColorPreferences.color(for: old, raw: raw) {
            var updated = raw
            if TagColorPreferences.color(for: newKey, raw: raw) == nil {
                updated = TagColorPreferences.setting(color, for: newKey, in: updated)
            }
            updated = TagColorPreferences.setting(nil, for: old, in: updated)
            UserDefaults.standard.set(updated, forKey: TagColorPreferences.storageKey)
        }
        store.renameTag(from: old, to: new)
        highlightedTagName = newKey
    }

    /// Opens the rename dialog for a folder (from the folder browser's
    /// context menu), seeding the field with its current relative path — so
    /// editing the last segment renames it, and editing an earlier segment
    /// re-files it under a different parent.
    func beginFolderRename(_ folder: String) {
        folderRenameText = folder
        folderRenameTarget = folder
    }

    /// Commits a folder rename: the directory moves (notes' contents are
    /// untouched — wikilinks are title-based), colors re-key for the folder
    /// and every descendant (the thing a Finder rename silently loses), and
    /// the selection/pinned-note paths follow. Refusals (collision,
    /// reserved name) surface as an error alert rather than silence.
    func commitFolderRename() {
        defer { folderRenameTarget = nil }
        guard let old = folderRenameTarget else { return }
        let typed = folderRenameText.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !typed.isEmpty, typed != old else { return }

        // Same pre-flush as a tag rename: an editor open on a note inside
        // this folder may hold typing whose debounced save would otherwise
        // fire against the old path and resurrect the old folder.
        NotificationCenter.default.post(name: .flushPendingEditsRequested, object: nil)

        guard let newPath = store.renameFolder(from: old, to: typed) else {
            // One tick later — presenting this alert in the same update that
            // dismisses the rename alert can silently drop it.
            Task { @MainActor in
                folderRenameError = "Couldn't rename \"\(old)\" to \"\(typed)\". A folder by that name may already exist, or the name is reserved (Templates, Inbox, Trash, Attachments)."
            }
            return
        }

        // Colors are keyed by relative path — re-key the folder and every
        // descendant so nothing loses its color.
        let colors = FolderColorPreferences.loadAll(from: folderColorsRaw)
        var rekeyed: [String: CodableColor] = [:]
        for (key, value) in colors {
            if key == old {
                rekeyed[newPath] = value
            } else if key.hasPrefix(old + "/") {
                rekeyed[newPath + key.dropFirst(old.count)] = value
            } else {
                rekeyed[key] = value
            }
        }
        folderColorsRaw = FolderColorPreferences.encode(rekeyed)

        // Paths stored outside the store follow by prefix swap: the open
        // note's selection, and the menu-bar pinned note (whose stored path
        // is read live, so updating the preference is enough).
        let oldAbs = store.noteDirectory.appendingPathComponent(old, isDirectory: true).path + "/"
        let newAbs = store.noteDirectory.appendingPathComponent(newPath, isDirectory: true).path + "/"
        if let sel = selectedID, sel.hasPrefix(oldAbs) {
            selectedID = newAbs + sel.dropFirst(oldAbs.count)
        }
        let pinned = UserDefaults.standard.string(forKey: "menuBarPinnedNotePath") ?? ""
        if pinned.hasPrefix(oldAbs) {
            UserDefaults.standard.set(newAbs + pinned.dropFirst(oldAbs.count), forKey: "menuBarPinnedNotePath")
        }

        recomputeFolderState()
        highlightedFolderName = newPath
        Task { await recomputeFilteredNotes() }
    }

    /// Clicking a row's folder dot or name chip — the folder twin of
    /// searchByTag above, showing just that folder's notes. Always quoted:
    /// folder names carry spaces far more often than tags do. Matching is
    /// the folder: operator's own (against the whole relative path), so a
    /// parent folder's search includes its nested folders' notes too.
    func searchByFolder(_ folder: String) {
        if folder.contains("\"") {
            // A quote inside the name would break the quoted-exact form's
            // own quoting — fall back to the partial match on the
            // un-quotable text rather than emitting a malformed query.
            query = "folder:" + folder.replacingOccurrences(of: "\"", with: "")
        } else {
            query = "folder:\"\(folder)\""
        }
        // See searchByTag: synchronous so the folder's notes replace the
        // browser without the full list flashing in between, settled once.
        recomputeFilteredNotesSync()
        settleAfterQueryChange()
        suppressNextQueryDebounce = true
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
    func submitFromInbox(_ note: Note, toSubfolder subfolder: String? = nil) {
        let next = matchingInboxForQuery.first { $0.id != note.id }?.id
        store.submitFromInbox(note, toSubfolder: subfolder)
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
        // Browsing templates/trash/tags/folders: a note selection still
        // exists underneath but isn't what's on screen — ⌘⌫ acting on it
        // would silently trash a note the user can't see. Each browse
        // surface has its own explicit delete affordances where deletion
        // makes sense.
        guard !isBrowseQuery else { return }
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

    /// Opens the note in its own resizable floating window (the same standing
    /// panel a pinned wikilink peek uses), so it can sit alongside whatever's in
    /// the main editor. Navigating a link inside it drives the main editor,
    /// matching how the peek behaves.
    func popOutNote(_ note: Note) {
        PinnedPeekManager.shared.openFloating(
            note: note,
            store: store,
            theme: theme,
            requireModifierForLinkClick: requireModifierForLinkClick,
            showDuePill: showDuePill,
            showTagsInTitleBar: showTagsInTitleBar,
            noteTitles: noteTitlesByRecencyCache,
            onNavigate: { navigateToNote(titled: $0) }
        )
    }

    @ViewBuilder
    func singleContextMenuItems(for note: Note) -> some View {
        Button(isPinned(note) ? "Unpin Note" : "Pin Note") {
            togglePin(note)
        }
        Button(isMenuBarPinned(note) ? "Unpin from Menu Bar" : "Pin to Menu Bar") {
            toggleMenuBarPin(note)
        }
        Button("Pop Out") {
            popOutNote(note)
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
        if indexIncludeSubfolders {
            Menu("Move to") {
                let current = noteSubfolderCache[note.id]
                Button {
                    moveNoteToSubfolder(note, nil)
                } label: {
                    Label("The Index", systemImage: "tray")
                }
                .disabled(current == nil)

                if !subfolderCache.isEmpty { Divider() }
                ForEach(subfolderCache, id: \.self) { folder in
                    Button {
                        moveNoteToSubfolder(note, folder)
                    } label: {
                        if let swatch = folderSwatchCache[folder] {
                            Label { Text(folder) } icon: { Image(nsImage: swatch) }
                        } else {
                            Label(folder, systemImage: "folder")
                        }
                    }
                    .disabled(current == folder)
                }

                Divider()
                Button("New Folder…") {
                    newFolderName = ""
                    newFolderNotes = [note]
                }
            }
        }
        Button("Move to Trash", role: .destructive) {
            deleteNote(note)
        }
    }

    /// Creates `newFolderName` and moves every `newFolderNotes` entry into it —
    /// one note from the single-note menu, the whole selection from the bulk
    /// menu. moveNote makes the folder on demand, so this is just a move to a
    /// name that doesn't exist yet. Called from the New Folder alert's Create
    /// button.
    func createFolderAndMove() {
        let pending = newFolderNotes
        guard !pending.isEmpty else { return }
        let name = newFolderName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        newFolderNotes = []
        guard !name.isEmpty else { return }
        for note in pending {
            guard let moved = moveNoteToSubfolder(note, name) else { continue }
            if multiSelectedIDs.remove(note.id) != nil {
                multiSelectedIDs.insert(moved.id)
            }
            if selectionAnchorID == note.id {
                selectionAnchorID = moved.id
            }
        }
    }

    /// Moves a note into a subfolder (nil = the Index root) and carries the
    /// selection with it — the move changes the note's id (its path), so a
    /// selected note would otherwise fall out of the editor.
    @discardableResult
    func moveNoteToSubfolder(_ note: Note, _ subfolder: String?) -> Note? {
        let wasSelected = selectedID == note.id
        guard let moved = store.moveNote(note, toSubfolder: subfolder) else { return nil }
        if wasSelected { selectedID = moved.id }

        // A move changes only this note's folder — not its title, content, date
        // or tags — so the filtered/sorted list is identical except for this one
        // row. Update the caches for just this note (instant) instead of letting
        // the store.notes change trigger a full re-filter/re-sort of the whole
        // vault, which measured ~480ms at 15k notes and is entirely wasted here.
        let trimmed = subfolder?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        let folder: String? = trimmed.isEmpty ? nil : trimmed
        if let idx = filteredNotesCache.firstIndex(where: { $0.id == note.id }) {
            filteredNotesCache[idx] = moved
        }
        noteSubfolderCache[note.id] = nil
        noteFolderColorCache[note.id] = nil
        if let folder {
            noteSubfolderCache[moved.id] = folder
            if let color = folderColorMap[folder] { noteFolderColorCache[moved.id] = color }
            if !subfolderCache.contains(folder) {   // a brand-new folder, added without a walk
                subfolderCache = (subfolderCache + [folder])
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                // Born colored, tag-style (see rebuildFolderColors) — writing
                // the pref triggers the cache rebuild that paints the dot.
                if FolderColorPreferences.color(for: folder, raw: folderColorsRaw) == nil,
                   let preset = FolderColorPreferences.presets.randomElement() {
                    folderColorsRaw = FolderColorPreferences.setting(preset.color, for: folder, in: folderColorsRaw)
                }
            }
        }
        // Everything a move affects is now reconciled, so skip the full-vault
        // recompute the store.notes change below would otherwise kick off.
        skipNotesReconcileOnce = true
        return moved
    }

    /// Moves every selected note into `subfolder` (nil = the Index root),
    /// carrying the multi-selection and anchor across the id changes the
    /// same way moveNoteToSubfolder already carries the primary selection.
    /// A note whose name collides in the destination is skipped (the store
    /// refuses that move to keep wikilinks honest) — the rest still go.
    func bulkMoveToSubfolder(_ subfolder: String?) {
        for note in selectedNotes() {
            guard let moved = moveNoteToSubfolder(note, subfolder) else { continue }
            if multiSelectedIDs.remove(note.id) != nil {
                multiSelectedIDs.insert(moved.id)
            }
            if selectionAnchorID == note.id {
                selectionAnchorID = moved.id
            }
        }
    }

    /// A small filled-circle image for a folder's color, shown beside its name
    /// in the "Move to" menu. Not a template image, so it keeps its own color
    /// in the menu (a tinted SF Symbol wouldn't reliably).
    static func folderSwatch(_ color: Color, diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        NSColor(color).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @ViewBuilder
    var bulkContextMenuItems: some View {
        let count = fullSelection.count
        Button("Open \(count) Notes in Finder") {
            bulkOpenInFinder()
        }
        if indexIncludeSubfolders {
            // The single-note menu's Move to, applied to the whole selection.
            // No per-folder disabling here — a mixed selection has no single
            // "current" folder, and moving a note to where it already sits is
            // a harmless no-op at the store level.
            Menu("Move \(count) Notes to") {
                Button {
                    bulkMoveToSubfolder(nil)
                } label: {
                    Label("The Index", systemImage: "tray")
                }

                if !subfolderCache.isEmpty { Divider() }
                ForEach(subfolderCache, id: \.self) { folder in
                    Button {
                        bulkMoveToSubfolder(folder)
                    } label: {
                        if let swatch = folderSwatchCache[folder] {
                            Label { Text(folder) } icon: { Image(nsImage: swatch) }
                        } else {
                            Label(folder, systemImage: "folder")
                        }
                    }
                }

                Divider()
                Button("New Folder…") {
                    newFolderName = ""
                    newFolderNotes = selectedNotes()
                }
            }
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

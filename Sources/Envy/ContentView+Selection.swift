import SwiftUI
import EnvyCore

// Selection, keyboard navigation, focus cycling, and pinning — the state
// machinery between the list and the editor. Split out of ContentView.swift
// purely for file size/navigability — same type, zero behavior change.
extension ContentView {
    // MARK: - Pinning

    var pinnedNoteIDs: Set<String> {
        Set(pinnedNotePathsRaw.split(separator: "\n").map(String.init))
    }

    func isPinned(_ note: Note) -> Bool {
        pinnedNoteIDs.contains(note.id)
    }

    func togglePin(_ note: Note) {
        var ids = pinnedNoteIDs
        if ids.contains(note.id) {
            ids.remove(note.id)
        } else {
            ids.insert(note.id)
        }
        pinnedNotePathsRaw = ids.joined(separator: "\n")
    }

    /// Called wherever a note's id changes out from under it (rename, move)
    /// so a pin doesn't silently vanish just because the underlying path did.
    func carryPinnedStatus(from oldID: String, to newID: String) {
        guard oldID != newID, pinnedNoteIDs.contains(oldID) else { return }
        var ids = pinnedNoteIDs
        ids.remove(oldID)
        ids.insert(newID)
        pinnedNotePathsRaw = ids.joined(separator: "\n")
        if menuBarPinnedNotePath == oldID {
            menuBarPinnedNotePath = newID
        }
    }

    func isMenuBarPinned(_ note: Note) -> Bool {
        menuBarPinnedNotePath == note.id
    }

    /// Only one note can be pinned to the menu bar at a time — pinning a
    /// second one replaces the first, same "there's only one slot" idea as
    /// AeroSpace's own scratchpad concept, not an ever-growing list like the
    /// regular note-list pinning above.
    func toggleMenuBarPin(_ note: Note) {
        menuBarPinnedNotePath = isMenuBarPinned(note) ? "" : note.id
    }

    // MARK: - Focus

    /// Cycles keyboard focus through search → list → editor (and back around),
    /// wrapping in both directions. When nothing is focused yet, "next" lands
    /// on search and "previous" lands on editor, so either direction always
    /// does something sensible from a cold start.
    func cycleFocus(by direction: Int) {
        let order: [FocusField] = [.search, .list, .editor]
        if let current = focusedField, let currentIndex = order.firstIndex(of: current) {
            let newIndex = (currentIndex + direction + order.count) % order.count
            focusedField = order[newIndex]
        } else {
            focusedField = direction > 0 ? order.first : order.last
        }
    }

    // MARK: - Selection

    /// Shared by both the list's own arrow-key handling and the search
    /// field's (which mirrors it so ↑/↓ work no matter which one has
    /// focus) — a named function here instead of the branching inline in
    /// each `onKeyPress` closure keeps those closures trivial for the type
    /// checker, which otherwise timed out entirely elsewhere in this same
    /// already-large view body.
    func handleListArrowKey(delta: Int, shiftHeld: Bool) {
        if isTemplateQuery {
            if shiftHeld { extendTemplateSelection(delta) } else { moveTemplateSelection(delta) }
        } else if isTrashQuery {
            if shiftHeld { extendTrashSelection(delta) } else { moveTrashSelection(delta) }
        } else if shiftHeld {
            extendSelection(delta)
        } else {
            moveSelection(delta)
        }
    }

    func moveSelection(_ delta: Int) {
        multiSelectedIDs.removeAll()
        // A plain (non-shift) move abandons whatever anchor a previous
        // shift-selection left behind — the next ⇧↑/⇧↓ should start a fresh
        // range from wherever this lands, not resume growing/shrinking the
        // old one. extendSelection() re-seeds this itself the next time
        // it's needed (from whatever selectedID becomes below).
        selectionAnchorID = nil
        let list = filteredNotes
        guard !list.isEmpty else { return }
        if let currentID = selectedID, let idx = list.firstIndex(where: { $0.id == currentID }) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            selectedID = list[newIdx].id
        } else {
            selectedID = delta > 0 ? list.first?.id : list.last?.id
        }
    }

    /// Shift+↑/↓ — Finder's own keyboard multi-select: grows or shrinks the
    /// selection one note at a time from a fixed anchor, exactly like
    /// repeated ⇧-clicks would. selectedID is the moving end (same as
    /// selectRange(to:) already treats it for ⇧-click), so walking it by one
    /// list position and handing that off to selectRange(to:) reuses the
    /// exact same anchor-to-target math instead of duplicating it here.
    ///
    /// The anchor has to be pinned to the *starting* position before that
    /// first walk — selectRange(to:) itself falls back to `selectedID` only
    /// when `selectionAnchorID` is nil, and selectedID becomes the *moving*
    /// end after each call. Without seeding the anchor here first, the second
    /// ⇧↓ in a row would silently re-anchor on the note the first ⇧↓ just
    /// moved to, sliding a fixed-size window down the list instead of
    /// growing it.
    func extendSelection(_ delta: Int) {
        let list = filteredNotes
        guard !list.isEmpty else { return }
        guard let currentID = selectedID, let idx = list.firstIndex(where: { $0.id == currentID }) else {
            selectedID = delta > 0 ? list.first?.id : list.last?.id
            selectionAnchorID = selectedID
            return
        }
        if selectionAnchorID == nil {
            selectionAnchorID = currentID
        }
        let newIdx = max(0, min(list.count - 1, idx + delta))
        selectRange(to: list[newIdx])
    }

    func reconcileSelection() {
        let list = filteredNotes
        if let selectedID, list.contains(where: { $0.id == selectedID }) { return }
        selectedID = list.first?.id
    }

    func moveTemplateSelection(_ delta: Int) {
        multiSelectedTemplateIDs.removeAll()
        templateSelectionAnchorID = nil
        let list = matchingTemplatesForQuery
        guard !list.isEmpty else { return }
        if let currentID = highlightedTemplateID, let idx = list.firstIndex(where: { $0.id == currentID }) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            highlightedTemplateID = list[newIdx].id
        } else {
            highlightedTemplateID = delta > 0 ? list.first?.id : list.last?.id
        }
    }

    /// Shift+↑/↓ for template: browsing — same anchor-pinning shape as
    /// extendSelection(_:) above, and for the same reason: the anchor has
    /// to be seeded from the *starting* highlight before the first walk, or
    /// the second press re-anchors on wherever the first one just moved to.
    func extendTemplateSelection(_ delta: Int) {
        let list = matchingTemplatesForQuery
        guard !list.isEmpty else { return }
        guard let currentID = highlightedTemplateID, let idx = list.firstIndex(where: { $0.id == currentID }) else {
            highlightedTemplateID = delta > 0 ? list.first?.id : list.last?.id
            templateSelectionAnchorID = highlightedTemplateID
            return
        }
        if templateSelectionAnchorID == nil {
            templateSelectionAnchorID = currentID
        }
        let newIdx = max(0, min(list.count - 1, idx + delta))
        selectTemplateRange(to: list[newIdx])
    }

    /// Same shape as reconcileSelection(), but for the highlighted template
    /// — clears it outright once the query stops being a "template:" one,
    /// and re-settles it onto the first match whenever the narrowing
    /// fragment leaves the previously highlighted template out. Also drops
    /// any multi-selected templates (and the anchor) that fell out of the
    /// narrowed list as the fragment kept typing.
    func reconcileTemplateHighlight() {
        guard isTemplateQuery else {
            highlightedTemplateID = nil
            multiSelectedTemplateIDs.removeAll()
            templateSelectionAnchorID = nil
            return
        }
        let list = matchingTemplatesForQuery
        let listIDs = Set(list.map(\.id))
        multiSelectedTemplateIDs.formIntersection(listIDs)
        if let templateSelectionAnchorID, !listIDs.contains(templateSelectionAnchorID) {
            self.templateSelectionAnchorID = nil
        }
        if let highlightedTemplateID, listIDs.contains(highlightedTemplateID) { return }
        highlightedTemplateID = list.first?.id
    }

    var fullTemplateSelection: Set<String> {
        multiSelectedTemplateIDs.union(highlightedTemplateID.map { [$0] } ?? [])
    }

    func isTemplateSelected(_ template: NoteTemplate) -> Bool {
        fullTemplateSelection.contains(template.id)
    }

    func selectSingleTemplate(_ template: NoteTemplate) {
        highlightedTemplateID = template.id
        multiSelectedTemplateIDs.removeAll()
        templateSelectionAnchorID = template.id
    }

    /// ⇧-click range selection for template: browsing — same shape as
    /// selectRange(to:) above.
    func selectTemplateRange(to template: NoteTemplate) {
        let list = matchingTemplatesForQuery
        guard let anchorID = templateSelectionAnchorID ?? highlightedTemplateID,
              let anchorIndex = list.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = list.firstIndex(where: { $0.id == template.id }) else {
            selectSingleTemplate(template)
            return
        }
        let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        highlightedTemplateID = template.id
        multiSelectedTemplateIDs = Set(list[range].map(\.id)).subtracting([template.id])
    }

    /// ⌘-click toggle for template: browsing — same shape as
    /// toggleMultiSelect(_:) above.
    func toggleMultiSelectTemplate(_ template: NoteTemplate) {
        if template.id == highlightedTemplateID {
            if let newPrimary = multiSelectedTemplateIDs.first {
                multiSelectedTemplateIDs.remove(newPrimary)
                highlightedTemplateID = newPrimary
            } else {
                highlightedTemplateID = nil
            }
        } else if multiSelectedTemplateIDs.contains(template.id) {
            multiSelectedTemplateIDs.remove(template.id)
        } else {
            multiSelectedTemplateIDs.insert(template.id)
        }
    }

    func selectedTemplates() -> [NoteTemplate] {
        let ids = fullTemplateSelection
        return availableTemplates.filter { ids.contains($0.id) }
    }

    func moveTrashSelection(_ delta: Int) {
        multiSelectedTrashIDs.removeAll()
        trashSelectionAnchorID = nil
        let list = matchingTrashForQuery
        guard !list.isEmpty else { return }
        if let currentID = highlightedTrashID, let idx = list.firstIndex(where: { $0.id == currentID }) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            highlightedTrashID = list[newIdx].id
        } else {
            highlightedTrashID = delta > 0 ? list.first?.id : list.last?.id
        }
    }

    /// Shift+↑/↓ for trash: browsing — same anchor-pinning shape as
    /// extendSelection(_:)/extendTemplateSelection(_:) above.
    func extendTrashSelection(_ delta: Int) {
        let list = matchingTrashForQuery
        guard !list.isEmpty else { return }
        guard let currentID = highlightedTrashID, let idx = list.firstIndex(where: { $0.id == currentID }) else {
            highlightedTrashID = delta > 0 ? list.first?.id : list.last?.id
            trashSelectionAnchorID = highlightedTrashID
            return
        }
        if trashSelectionAnchorID == nil {
            trashSelectionAnchorID = currentID
        }
        let newIdx = max(0, min(list.count - 1, idx + delta))
        selectTrashRange(to: list[newIdx])
    }

    /// Same shape as reconcileTemplateHighlight(), but for "trash:" browsing.
    func reconcileTrashHighlight() {
        guard isTrashQuery else {
            highlightedTrashID = nil
            multiSelectedTrashIDs.removeAll()
            trashSelectionAnchorID = nil
            return
        }
        let list = matchingTrashForQuery
        let listIDs = Set(list.map(\.id))
        multiSelectedTrashIDs.formIntersection(listIDs)
        if let trashSelectionAnchorID, !listIDs.contains(trashSelectionAnchorID) {
            self.trashSelectionAnchorID = nil
        }
        if let highlightedTrashID, listIDs.contains(highlightedTrashID) { return }
        highlightedTrashID = list.first?.id
    }

    var fullTrashSelection: Set<String> {
        multiSelectedTrashIDs.union(highlightedTrashID.map { [$0] } ?? [])
    }

    func isTrashSelected(_ note: Note) -> Bool {
        fullTrashSelection.contains(note.id)
    }

    func selectSingleTrash(_ note: Note) {
        highlightedTrashID = note.id
        multiSelectedTrashIDs.removeAll()
        trashSelectionAnchorID = note.id
    }

    /// ⇧-click range selection for trash: browsing — same shape as
    /// selectRange(to:) above.
    func selectTrashRange(to note: Note) {
        let list = matchingTrashForQuery
        guard let anchorID = trashSelectionAnchorID ?? highlightedTrashID,
              let anchorIndex = list.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = list.firstIndex(where: { $0.id == note.id }) else {
            selectSingleTrash(note)
            return
        }
        let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        highlightedTrashID = note.id
        multiSelectedTrashIDs = Set(list[range].map(\.id)).subtracting([note.id])
    }

    /// ⌘-click toggle for trash: browsing — same shape as
    /// toggleMultiSelect(_:) above.
    func toggleMultiSelectTrash(_ note: Note) {
        if note.id == highlightedTrashID {
            if let newPrimary = multiSelectedTrashIDs.first {
                multiSelectedTrashIDs.remove(newPrimary)
                highlightedTrashID = newPrimary
            } else {
                highlightedTrashID = nil
            }
        } else if multiSelectedTrashIDs.contains(note.id) {
            multiSelectedTrashIDs.remove(note.id)
        } else {
            multiSelectedTrashIDs.insert(note.id)
        }
    }

    func selectedTrashNotes() -> [Note] {
        let ids = fullTrashSelection
        return availableTrashedNotes.filter { ids.contains($0.id) }
    }

    var fullSelection: Set<String> {
        multiSelectedIDs.union(selectedID.map { [$0] } ?? [])
    }

    func isSelected(_ note: Note) -> Bool {
        fullSelection.contains(note.id)
    }

    func selectSingle(_ note: Note) {
        selectedID = note.id
        multiSelectedIDs.removeAll()
        selectionAnchorID = note.id
    }

    /// ⇧-click range selection — selects every note between the fixed
    /// anchor (see selectionAnchorID) and the clicked note, inclusive, in
    /// the list's current sorted/filtered order. The clicked note becomes
    /// the primary selection driving the editor, matching how ⌘-click
    /// already updates selectedID when it lands on a new note.
    func selectRange(to note: Note) {
        let list = filteredNotes
        guard let anchorID = selectionAnchorID ?? selectedID,
              let anchorIndex = list.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = list.firstIndex(where: { $0.id == note.id }) else {
            selectSingle(note)
            return
        }
        let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selectedID = note.id
        multiSelectedIDs = Set(list[range].map(\.id)).subtracting([note.id])
    }

    /// Toggles a note's membership in the selection. Demoting the current
    /// primary (selectedID) promotes another selected note to take its place
    /// if one exists, since selectedID always drives the editor pane and
    /// must stay in sync with "is anything selected at all".
    func toggleMultiSelect(_ note: Note) {
        if note.id == selectedID {
            if let newPrimary = multiSelectedIDs.first {
                multiSelectedIDs.remove(newPrimary)
                selectedID = newPrimary
            } else {
                selectedID = nil
            }
        } else if multiSelectedIDs.contains(note.id) {
            multiSelectedIDs.remove(note.id)
        } else {
            multiSelectedIDs.insert(note.id)
        }
    }

    func selectDefaultIfNeeded() {
        if selectedID == nil {
            selectedID = store.notes.first?.id
        }
    }

    func selectedNotes() -> [Note] {
        let ids = fullSelection
        return store.notes.filter { ids.contains($0.id) }
    }
}

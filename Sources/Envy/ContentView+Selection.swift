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

    func moveSelection(_ delta: Int) {
        editingTemplate = nil
        multiSelectedIDs.removeAll()
        let list = filteredNotes
        guard !list.isEmpty else { return }
        if let currentID = selectedID, let idx = list.firstIndex(where: { $0.id == currentID }) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            selectedID = list[newIdx].id
        } else {
            selectedID = delta > 0 ? list.first?.id : list.last?.id
        }
    }

    func reconcileSelection() {
        let list = filteredNotes
        if let selectedID, list.contains(where: { $0.id == selectedID }) { return }
        selectedID = list.first?.id
    }

    func moveTemplateSelection(_ delta: Int) {
        let list = matchingTemplatesForQuery
        guard !list.isEmpty else { return }
        if let currentID = highlightedTemplateID, let idx = list.firstIndex(where: { $0.id == currentID }) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            highlightedTemplateID = list[newIdx].id
        } else {
            highlightedTemplateID = delta > 0 ? list.first?.id : list.last?.id
        }
    }

    /// Same shape as reconcileSelection(), but for the highlighted template
    /// — clears it outright once the query stops being a "template:" one,
    /// and re-settles it onto the first match whenever the narrowing
    /// fragment leaves the previously highlighted template out.
    func reconcileTemplateHighlight() {
        guard isTemplateQuery else {
            highlightedTemplateID = nil
            return
        }
        let list = matchingTemplatesForQuery
        if let highlightedTemplateID, list.contains(where: { $0.id == highlightedTemplateID }) { return }
        highlightedTemplateID = list.first?.id
    }

    var fullSelection: Set<String> {
        multiSelectedIDs.union(selectedID.map { [$0] } ?? [])
    }

    func isSelected(_ note: Note) -> Bool {
        fullSelection.contains(note.id)
    }

    func selectSingle(_ note: Note) {
        editingTemplate = nil
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
        editingTemplate = nil
        selectedID = note.id
        multiSelectedIDs = Set(list[range].map(\.id)).subtracting([note.id])
    }

    /// Toggles a note's membership in the selection. Demoting the current
    /// primary (selectedID) promotes another selected note to take its place
    /// if one exists, since selectedID always drives the editor pane and
    /// must stay in sync with "is anything selected at all".
    func toggleMultiSelect(_ note: Note) {
        editingTemplate = nil
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

import SwiftUI
import EnvyCore

/// isPinned() runs once per visible row on every list render, so parsing the
/// newline-joined AppStorage string into a fresh Set on each call scaled the
/// cost with the list for nothing. Memoized against the raw string itself:
/// AppStorage is process-wide, so one cache serves every view instance, and
/// a raw mismatch simply re-parses.
@MainActor
private enum PinnedIDsMemo {
    static var raw: String?
    static var ids: Set<String> = []
}

/// One copy of the Finder-style list-selection machinery, shared by the note
/// list, template: browsing, and trash: browsing — each keeps its own
/// primary/multi/anchor @State trio in ContentView, but the behavior is
/// deliberately identical, so the three families of entry points in the
/// extension below are thin wrappers over this. The primary ID is the
/// "moving end" that drives the detail pane; the anchor is the fixed end a
/// ⇧-range grows from.
@MainActor
private struct ListSelection<Item: Identifiable> where Item.ID == String {
    let list: [Item]
    @Binding var primaryID: String?
    @Binding var multiIDs: Set<String>
    @Binding var anchorID: String?

    func move(_ delta: Int) {
        multiIDs.removeAll()
        // A plain (non-shift) move abandons whatever anchor a previous
        // shift-selection left behind — the next ⇧↑/⇧↓ should start a fresh
        // range from wherever this lands, not resume growing/shrinking the
        // old one. extend() re-seeds this itself the next time it's needed
        // (from whatever primaryID becomes below).
        anchorID = nil
        guard !list.isEmpty else { return }
        if let currentID = primaryID, let idx = list.firstIndex(where: { $0.id == currentID }) {
            let newIdx = max(0, min(list.count - 1, idx + delta))
            primaryID = list[newIdx].id
        } else {
            primaryID = delta > 0 ? list.first?.id : list.last?.id
        }
    }

    /// Shift+↑/↓ — Finder's own keyboard multi-select: grows or shrinks the
    /// selection one item at a time from a fixed anchor, exactly like
    /// repeated ⇧-clicks would. The primary is the moving end (same as
    /// selectRange(to:) already treats it for ⇧-click), so walking it by one
    /// list position and handing that off to selectRange(to:) reuses the
    /// exact same anchor-to-target math instead of duplicating it here.
    ///
    /// The anchor has to be pinned to the *starting* position before that
    /// first walk — selectRange(to:) itself falls back to the primary only
    /// when the anchor is nil, and the primary becomes the *moving* end
    /// after each call. Without seeding the anchor here first, the second
    /// ⇧↓ in a row would silently re-anchor on the item the first ⇧↓ just
    /// moved to, sliding a fixed-size window down the list instead of
    /// growing it.
    func extend(_ delta: Int) {
        guard !list.isEmpty else { return }
        guard let currentID = primaryID, let idx = list.firstIndex(where: { $0.id == currentID }) else {
            primaryID = delta > 0 ? list.first?.id : list.last?.id
            anchorID = primaryID
            return
        }
        if anchorID == nil {
            anchorID = currentID
        }
        let newIdx = max(0, min(list.count - 1, idx + delta))
        selectRange(to: list[newIdx])
    }

    func selectSingle(_ item: Item) {
        primaryID = item.id
        multiIDs.removeAll()
        anchorID = item.id
    }

    /// ⇧-click range selection — selects every item between the fixed
    /// anchor and the clicked item, inclusive, in the list's current
    /// sorted/filtered order. The clicked item becomes the primary
    /// selection driving the detail pane, matching how ⌘-click already
    /// updates the primary when it lands on a new item.
    func selectRange(to item: Item) {
        guard let anchorID = anchorID ?? primaryID,
              let anchorIndex = list.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = list.firstIndex(where: { $0.id == item.id }) else {
            selectSingle(item)
            return
        }
        let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        primaryID = item.id
        multiIDs = Set(list[range].map(\.id)).subtracting([item.id])
    }

    /// Toggles an item's membership in the selection. Demoting the current
    /// primary promotes another selected item to take its place if one
    /// exists, since the primary always drives the detail pane and must
    /// stay in sync with "is anything selected at all".
    func toggleMembership(_ item: Item) {
        if item.id == primaryID {
            if let newPrimary = multiIDs.first {
                multiIDs.remove(newPrimary)
                primaryID = newPrimary
            } else {
                primaryID = nil
            }
        } else if multiIDs.contains(item.id) {
            multiIDs.remove(item.id)
        } else {
            multiIDs.insert(item.id)
        }
    }

    /// Same fallback-to-first-when-gone idea as reconcileSelection() in the
    /// extension below, plus mode-exit cleanup: once `active` goes false
    /// (the query stopped being a "template:"/"trash:" one), the primary,
    /// the multi-selection, and the anchor all clear outright. While the
    /// mode is active, the primary re-settles onto the first match whenever
    /// the narrowing fragment leaves the previously highlighted item out,
    /// and any multi-selected items (and the anchor) that fell out of the
    /// narrowed list as the fragment kept typing are dropped.
    func reconcile(active: Bool) {
        guard active else {
            primaryID = nil
            multiIDs.removeAll()
            anchorID = nil
            return
        }
        let listIDs = Set(list.map(\.id))
        multiIDs.formIntersection(listIDs)
        if let anchorID, !listIDs.contains(anchorID) {
            self.anchorID = nil
        }
        if let primaryID, listIDs.contains(primaryID) { return }
        primaryID = list.first?.id
    }
}

// Selection, keyboard navigation, focus cycling, and pinning — the state
// machinery between the list and the editor. Split out of ContentView.swift
// purely for file size/navigability — same type, zero behavior change.
extension ContentView {
    // MARK: - Pinning

    var pinnedNoteIDs: Set<String> {
        if PinnedIDsMemo.raw != pinnedNotePathsRaw {
            PinnedIDsMemo.raw = pinnedNotePathsRaw
            PinnedIDsMemo.ids = Set(pinnedNotePathsRaw.split(separator: "\n").map(String.init))
        }
        return PinnedIDsMemo.ids
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

    private var noteSelection: ListSelection<Note> {
        ListSelection(list: filteredNotes,
                      primaryID: $selectedID,
                      multiIDs: $multiSelectedIDs,
                      anchorID: $selectionAnchorID)
    }

    private var templateSelection: ListSelection<NoteTemplate> {
        ListSelection(list: matchingTemplatesForQuery,
                      primaryID: $highlightedTemplateID,
                      multiIDs: $multiSelectedTemplateIDs,
                      anchorID: $templateSelectionAnchorID)
    }

    private var trashSelection: ListSelection<Note> {
        ListSelection(list: matchingTrashForQuery,
                      primaryID: $highlightedTrashID,
                      multiIDs: $multiSelectedTrashIDs,
                      anchorID: $trashSelectionAnchorID)
    }

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
        } else if isTagBrowseQuery {
            moveTagHighlight(delta)
        } else if isFolderBrowseQuery {
            moveFolderHighlight(delta)
        } else if shiftHeld {
            extendSelection(delta)
        } else {
            moveSelection(delta)
        }
    }

    /// Moves the highlight in the bare-"tag:" browser, clamped to the ends
    /// (no wrap) like the note list. Falls back to the top when the current
    /// highlight is stale (a tag that no longer exists).
    func moveTagHighlight(_ delta: Int) {
        // browserTagCounts, not store.tagCounts() — the highlight must walk
        // the rows actually displayed (which exclude a hidden Inbox's tags).
        let tags = browserTagCounts
        guard !tags.isEmpty else { return }
        let current = tags.firstIndex { $0.name == highlightedTagName } ?? 0
        highlightedTagName = tags[min(max(current + delta, 0), tags.count - 1)].name
    }

    /// The bare-"folder:" browser's twin of moveTagHighlight.
    func moveFolderHighlight(_ delta: Int) {
        guard !subfolderCache.isEmpty else { return }
        let current = subfolderCache.firstIndex(of: highlightedFolderName ?? "") ?? 0
        highlightedFolderName = subfolderCache[min(max(current + delta, 0), subfolderCache.count - 1)]
    }

    func moveSelection(_ delta: Int) {
        noteSelection.move(delta)
    }

    func extendSelection(_ delta: Int) {
        noteSelection.extend(delta)
    }

    /// Deliberately narrower than ListSelection.reconcile(active:), which
    /// the template/trash reconciles below use: only the primary selection
    /// snaps to the first result when it falls out of the filtered list —
    /// the multi-selection and anchor are left untouched here, preserving
    /// the note list's existing behavior across query edits.
    func reconcileSelection() {
        let list = filteredNotes
        if let selectedID, list.contains(where: { $0.id == selectedID }) { return }
        selectedID = list.first?.id
    }

    /// Same fallback-to-first-when-gone idea as reconcileSelection() above,
    /// but only treats the selection as gone when the note itself no longer
    /// exists in store.notes — not merely when it stopped matching the
    /// active search filter. Used after store.notes itself changes (an edit
    /// lands, a note's added/removed/renamed, a reload finishes), where the
    /// far more common case is the *currently open* note's own edit knocking
    /// it out of a filter like "todo:" (checking off its last unchecked
    /// task, say) — the user is still looking right at it and typing in it,
    /// so it should stay open even though the note list itself no longer
    /// shows it (the editor pane already keys off store.notes for exactly
    /// this reason, see ContentView+EditorPane's own selectedID check).
    ///
    /// reconcileSelection() itself is still what a direct query edit uses —
    /// snapping to the new top result as the user types a new search is the
    /// expected, search-as-you-type behavior there, a genuinely different
    /// situation from a note quietly falling out of a filter it used to
    /// match because of its own content changing.
    func reconcileSelectionAfterNotesChange() {
        if let selectedID, store.notes.contains(where: { $0.id == selectedID }) { return }
        selectedID = filteredNotes.first?.id
    }

    func moveTemplateSelection(_ delta: Int) {
        templateSelection.move(delta)
    }

    func extendTemplateSelection(_ delta: Int) {
        templateSelection.extend(delta)
    }

    /// Clears the highlight/multi-selection/anchor outright once the query
    /// stops being a "template:" one — see ListSelection.reconcile(active:).
    func reconcileTemplateHighlight() {
        templateSelection.reconcile(active: isTemplateQuery)
    }

    var fullTemplateSelection: Set<String> {
        multiSelectedTemplateIDs.union(highlightedTemplateID.map { [$0] } ?? [])
    }

    func isTemplateSelected(_ template: NoteTemplate) -> Bool {
        fullTemplateSelection.contains(template.id)
    }

    func selectSingleTemplate(_ template: NoteTemplate) {
        templateSelection.selectSingle(template)
    }

    func selectTemplateRange(to template: NoteTemplate) {
        templateSelection.selectRange(to: template)
    }

    func toggleMultiSelectTemplate(_ template: NoteTemplate) {
        templateSelection.toggleMembership(template)
    }

    func selectedTemplates() -> [NoteTemplate] {
        let ids = fullTemplateSelection
        return availableTemplates.filter { ids.contains($0.id) }
    }

    func moveTrashSelection(_ delta: Int) {
        trashSelection.move(delta)
    }

    func extendTrashSelection(_ delta: Int) {
        trashSelection.extend(delta)
    }

    /// Clears the highlight/multi-selection/anchor outright once the query
    /// stops being a "trash:" one — see ListSelection.reconcile(active:).
    func reconcileTrashHighlight() {
        trashSelection.reconcile(active: isTrashQuery)
    }

    var fullTrashSelection: Set<String> {
        multiSelectedTrashIDs.union(highlightedTrashID.map { [$0] } ?? [])
    }

    func isTrashSelected(_ note: Note) -> Bool {
        fullTrashSelection.contains(note.id)
    }

    func selectSingleTrash(_ note: Note) {
        trashSelection.selectSingle(note)
    }

    func selectTrashRange(to note: Note) {
        trashSelection.selectRange(to: note)
    }

    func toggleMultiSelectTrash(_ note: Note) {
        trashSelection.toggleMembership(note)
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
        noteSelection.selectSingle(note)
    }

    func selectRange(to note: Note) {
        noteSelection.selectRange(to: note)
    }

    func toggleMultiSelect(_ note: Note) {
        noteSelection.toggleMembership(note)
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

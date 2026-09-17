import SwiftUI

// The editor split: a second editor pane beside (or below) the first, so two
// notes are visible at once without popping one out. `selectedID` stays the
// active pane's note throughout — see the state block in ContentView.swift — so
// everything that reads it (list highlight, footer, interlinks) is unchanged;
// this file is the small amount of logic that manages the second pane.
extension ContentView {
    /// True when a search operator has taken over the editor pane (template,
    /// trash, or a tag/folder browse), where a split doesn't apply.
    var isEditorQueryMode: Bool {
        isTemplateQuery || isTrashQuery || isTagBrowseQuery || isFolderBrowseQuery
    }

    /// Whether the two panes stack (divider horizontal) rather than sit side by
    /// side. "auto" follows the layout: side by side under a wide editor (list
    /// above), stacked beside a tall one (list to the left).
    var splitStacked: Bool {
        switch splitDirectionRaw {
        case "stacked": return true
        case "side": return false
        default: return layoutMode == .horizontal
        }
    }

    /// The note shown in the leading (left/top) pane, and the trailing
    /// (right/bottom) pane. The active pane always holds `selectedID`; which
    /// physical slot that is depends on `activePaneIsTrailing`.
    var leadingPaneID: String? { activePaneIsTrailing ? inactivePaneID : selectedID }
    var trailingPaneID: String? { activePaneIsTrailing ? selectedID : inactivePaneID }

    /// Opens a second pane (or closes it if one is already open). The new pane
    /// opens empty and active, so the next note you open lands there while the
    /// note you were on stays put in the first pane.
    func toggleSplit() {
        if splitEnabled {
            closeSplit()
        } else {
            inactivePaneID = selectedID
            selectedID = nil
            activePaneIsTrailing = true
            splitEnabled = true
            focusedField = .editor
        }
    }

    /// Takes the split down, leaving the active pane's note as the single
    /// selection.
    func closeSplit() {
        splitEnabled = false
        inactivePaneID = nil
        activePaneIsTrailing = false
    }

    /// Flips between side by side and stacked, pinning the choice.
    func flipSplit() {
        splitDirectionRaw = splitStacked ? "side" : "stacked"
    }

    /// Makes the given physical pane the active one. The two notes stay on
    /// screen; only which one is `selectedID` (and so drives the list, footer,
    /// and interlinks) changes.
    func activatePane(trailing: Bool) {
        guard splitEnabled, trailing != activePaneIsTrailing else { return }
        swap(&selectedID, &inactivePaneID)
        activePaneIsTrailing = trailing
    }

    /// Opens a note in the pane beside the current one, splitting first if
    /// needed, and makes that pane active. A note already open in a pane is
    /// just activated rather than opened a second time (no duplicate).
    func openInSplitPane(_ id: String) {
        guard splitEnabled else {
            inactivePaneID = selectedID
            selectedID = (id == selectedID) ? nil : id
            activePaneIsTrailing = true
            splitEnabled = true
            focusedField = .editor
            return
        }
        if id == selectedID { return }                 // already the active pane
        if id == inactivePaneID {                       // already in the other pane
            activatePane(trailing: !activePaneIsTrailing)
            return
        }
        inactivePaneID = id
        activatePane(trailing: !activePaneIsTrailing)
        focusedField = .editor
    }
}

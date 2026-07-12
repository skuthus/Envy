import Foundation

extension Notification.Name {
    static let newNoteRequested = Notification.Name("newNoteRequested")
    static let newFromTemplateRequested = Notification.Name("newFromTemplateRequested")
    static let summonRequested = Notification.Name("summonRequested")
    static let deleteSelectedRequested = Notification.Name("deleteSelectedRequested")
    static let toggleLayoutRequested = Notification.Name("toggleLayoutRequested")
    static let zoomInRequested = Notification.Name("zoomInRequested")
    static let zoomOutRequested = Notification.Name("zoomOutRequested")
    static let zoomResetRequested = Notification.Name("zoomResetRequested")
    static let boldSelectionRequested = Notification.Name("boldSelectionRequested")
    static let italicSelectionRequested = Notification.Name("italicSelectionRequested")
    static let openSettingsRequested = Notification.Name("openSettingsRequested")
    static let nextFolderRequested = Notification.Name("nextFolderRequested")
    static let previousFolderRequested = Notification.Name("previousFolderRequested")
    static let togglePlainTextModeRequested = Notification.Name("togglePlainTextModeRequested")
    static let restoreDeletedNoteRequested = Notification.Name("restoreDeletedNoteRequested")
    static let focusNextAreaRequested = Notification.Name("focusNextAreaRequested")
    static let focusPreviousAreaRequested = Notification.Name("focusPreviousAreaRequested")
    static let togglePinRequested = Notification.Name("togglePinRequested")
    static let toggleBacklinksRequested = Notification.Name("toggleBacklinksRequested")
    /// Posted with a note's file URL as `object` — from the pinned-note menu
    /// bar popover's "open in Envy" button, so the main window opens
    /// straight to that same note instead of whatever was last selected.
    static let externalNoteOpenRequested = Notification.Name("externalNoteOpenRequested")
}

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
}

import Foundation

extension Notification.Name {
    static let newNoteRequested = Notification.Name("newNoteRequested")
    static let summonRequested = Notification.Name("summonRequested")
    static let deleteSelectedRequested = Notification.Name("deleteSelectedRequested")
    static let toggleLayoutRequested = Notification.Name("toggleLayoutRequested")
    static let zoomInRequested = Notification.Name("zoomInRequested")
    static let zoomOutRequested = Notification.Name("zoomOutRequested")
    static let zoomResetRequested = Notification.Name("zoomResetRequested")
    static let boldSelectionRequested = Notification.Name("boldSelectionRequested")
    static let italicSelectionRequested = Notification.Name("italicSelectionRequested")
}

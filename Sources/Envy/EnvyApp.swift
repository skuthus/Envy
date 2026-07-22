import SwiftUI
import AppKit
import Sparkle
import EnvyCore

// The SwiftUI entry point: scenes and the menu bar commands. The AppKit
// side (window lifecycle, hotkeys, status item, pinned-note panel) lives in
// AppDelegate.swift and its extensions.
@main
struct EnvyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    // Reading this makes `body` re-evaluate (and thus re-register every
    // menu shortcut below) whenever the user changes one in Settings.
    @AppStorage(ShortcutPreferences.storageKey) private var customShortcutsRaw = ""

    private func binding(for action: ShortcutAction) -> ShortcutBinding {
        ShortcutPreferences.binding(for: action, raw: customShortcutsRaw)
    }

    /// Runs an Apple Notes import straight from the menu / ⌘⌥I using the
    /// folder saved in Settings — no need to open Settings first. If no outbox
    /// has been chosen yet, sends the user to the Import tab to pick one.
    /// Surfaces only failures (permission, a missing folder): a successful
    /// import shows itself as the notes appearing, and an empty run needs no
    /// interruption.
    private func triggerAppleNotesImport() {
        let defaults = UserDefaults.standard
        let folder = (defaults.string(forKey: "appleNotesOutboxFolder") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else {
            defaults.set("import", forKey: "settingsSelectedTab")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return
        }
        let archiveRaw = (defaults.string(forKey: "appleNotesArchiveFolder") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let archive = archiveRaw.isEmpty ? "Imported" : archiveRaw
        let index = IndexPreference.load()
        // Defaults to Inbox when the key was never set (register-less bool → false),
        // so read it explicitly with a true default to match the Settings picker.
        let toInbox = defaults.object(forKey: "appleNotesImportToInbox") as? Bool ?? true

        Task { @MainActor in
            let importer = AppleNotesImporter.shared
            guard !importer.isRunning else { return }
            await importer.run(folder: folder, archive: archive, indexDirectory: index, toInbox: toInbox)
            if case let .failed(message) = importer.phase {
                let alert = NSAlert()
                alert.messageText = "Apple Notes Import"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    var body: some Scene {
        // Declaring the title here (rather than imperatively via window.title)
        // is what actually sticks — SwiftUI otherwise reasserts its own
        // process-name-derived default title on top of an imperative one after
        // the deferred window-style changes below run.
        WindowGroup("Envy") {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Envy") {
                    openWindow(id: "about")
                }
                Button("Check for Updates…") {
                    Updater.shared.checkForUpdates()
                }
            }
            CommandGroup(replacing: .newItem) {
                // No .keyboardShortcut — ⌘N was pulled in favor of "Jump to
                // OmniBar" (Navigate menu), since the omnibar's own type-a-
                // name-and-hit-Return already creates a note. Still reachable
                // from this File menu item, the status bar's right-click
                // menu, or "New Pinned Note" for anyone who wants a blank
                // note without naming it first.
                Button("New Note") {
                    NotificationCenter.default.post(name: .newNoteRequested, object: nil)
                }

                Button("New Note from Template") {
                    NotificationCenter.default.post(name: .newFromTemplateRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .newFromTemplate).keyEquivalent, modifiers: binding(for: .newFromTemplate).eventModifiers)

                Divider()

                Button("Import from Apple Notes") {
                    triggerAppleNotesImport()
                }
                .keyboardShortcut(binding(for: .importFromAppleNotes).keyEquivalent, modifiers: binding(for: .importFromAppleNotes).eventModifiers)
            }
            CommandGroup(after: .newItem) {
                Button("Delete Note") {
                    NotificationCenter.default.post(name: .deleteSelectedRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .deleteNote).keyEquivalent, modifiers: binding(for: .deleteNote).eventModifiers)

                Button("Restore Deleted Note") {
                    NotificationCenter.default.post(name: .restoreDeletedNoteRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .restoreDeletedNote).keyEquivalent, modifiers: binding(for: .restoreDeletedNote).eventModifiers)

                Button("Pin/Unpin Note") {
                    NotificationCenter.default.post(name: .togglePinRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .togglePin).keyEquivalent, modifiers: binding(for: .togglePin).eventModifiers)
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Layout") {
                    NotificationCenter.default.post(name: .toggleLayoutRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .toggleLayout).keyEquivalent, modifiers: binding(for: .toggleLayout).eventModifiers)

                Button("Toggle Plain-Text Mode") {
                    NotificationCenter.default.post(name: .togglePlainTextModeRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .togglePlainTextMode).keyEquivalent, modifiers: binding(for: .togglePlainTextMode).eventModifiers)

                Button("Toggle Backlinks") {
                    NotificationCenter.default.post(name: .toggleBacklinksRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .toggleBacklinks).keyEquivalent, modifiers: binding(for: .toggleBacklinks).eventModifiers)
            }
            CommandMenu("Font") {
                Button("Bold") {
                    NotificationCenter.default.post(name: .boldSelectionRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .bold).keyEquivalent, modifiers: binding(for: .bold).eventModifiers)

                Button("Italic") {
                    NotificationCenter.default.post(name: .italicSelectionRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .italic).keyEquivalent, modifiers: binding(for: .italic).eventModifiers)

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomInRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .zoomIn).keyEquivalent, modifiers: binding(for: .zoomIn).eventModifiers)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOutRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .zoomOut).keyEquivalent, modifiers: binding(for: .zoomOut).eventModifiers)

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .zoomResetRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .actualSize).keyEquivalent, modifiers: binding(for: .actualSize).eventModifiers)
            }
            CommandMenu("Navigate") {
                Button("Jump to OmniBar") {
                    NotificationCenter.default.post(name: .jumpToOmniBarRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .jumpToOmniBar).keyEquivalent, modifiers: binding(for: .jumpToOmniBar).eventModifiers)

                Divider()

                // No .keyboardShortcut here, deliberately — Option+Up/Down are
                // already claimed by AppKit's own paragraph-navigation text
                // editing (moveToBeginningOfParagraph:/moveToEndOfParagraph:),
                // which wins over a SwiftUI menu shortcut the same way Return's
                // built-in zoom behavior beat Center Window's. The local event
                // monitor in AppDelegate handles the actual key press instead,
                // reading the same customizable binding; the current binding is
                // just spelled out in the title here.
                Button("Focus Next Area  (\(binding(for: .focusNextArea).displayString))") {
                    NotificationCenter.default.post(name: .focusNextAreaRequested, object: nil)
                }

                Button("Focus Previous Area  (\(binding(for: .focusPreviousArea).displayString))") {
                    NotificationCenter.default.post(name: .focusPreviousAreaRequested, object: nil)
                }
            }
            CommandGroup(after: .windowArrangement) {
                // No .keyboardShortcut here — its default (⌘↩) loses to
                // AppKit's own default Return-key handling (which zooms/
                // full-screens the window) more often than it wins, so this
                // deliberately has no real .keyboardShortcut() — the local
                // event monitor in AppDelegate handles the actual key press
                // instead, reading the same customizable binding. The
                // current binding is spelled out in the title itself rather
                // than shown as a real menu key-equivalent, since attaching
                // one here would reintroduce that exact conflict.
                Button("Center Window  (\(binding(for: .centerWindow).displayString))") {
                    NSApp.windows.first?.center()
                }
            }
        }

        Window("About Envy", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("What's New", id: "whatsnew") {
            WhatsNewView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let hotKey = GlobalHotKey()
    private var centerWindowMonitor: Any?
    private var focusAreaMonitor: Any?
    private weak var mainWindow: NSWindow?
    private var keyObserver: Any?
    private var statusItem: NSStatusItem?
    private var shortcutsObserver: Any?
    private var resignActiveObserver: Any?
    private var appliedSummonBinding: ShortcutBinding?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppearanceMode.applyStored()

        let window = NSApp.windows.first
        mainWindow = window
        window?.delegate = self
        window?.makeKeyAndOrderFront(nil)

        // A SwiftUI .commands keyboardShortcut here loses to AppKit's own
        // default Return-key handling (which zooms/full-screens the window)
        // more often than it wins. A local monitor lets us intercept and
        // consume the key combo ourselves, deterministically — matched
        // against the user's customizable binding (Settings → Shortcuts)
        // rather than a hardcoded key, read fresh from UserDefaults on every
        // keypress so a change in Settings takes effect immediately.
        centerWindowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let raw = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) ?? ""
            let binding = ShortcutPreferences.binding(for: .centerWindow, raw: raw)
            let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let matches = event.charactersIgnoringModifiers == binding.character && EventModifiers(relevant) == binding.eventModifiers
            guard matches else { return event }
            NSApp.windows.first?.center()
            return nil
        }

        // Option+Up/Down are already claimed by AppKit's own paragraph-
        // navigation text editing (moveToBeginningOfParagraph:/
        // moveToEndOfParagraph:) inside any text view — same category of
        // conflict as Center Window above, same fix.
        focusAreaMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let raw = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) ?? ""
            let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let nextBinding = ShortcutPreferences.binding(for: .focusNextArea, raw: raw)
            let previousBinding = ShortcutPreferences.binding(for: .focusPreviousArea, raw: raw)
            if event.charactersIgnoringModifiers == nextBinding.character && EventModifiers(relevant) == nextBinding.eventModifiers {
                NotificationCenter.default.post(name: .focusNextAreaRequested, object: nil)
                return nil
            }
            if event.charactersIgnoringModifiers == previousBinding.character && EventModifiers(relevant) == previousBinding.eventModifiers {
                NotificationCenter.default.post(name: .focusPreviousAreaRequested, object: nil)
                return nil
            }
            return event
        }

        // Setting fullSizeContentView in the same tick as launch doesn't reliably
        // take effect — the content view has already been laid out against the
        // window's initial (non-full-size) titlebar assumption, and exactly how
        // long that takes varies (observed: a bare debug binary vs. a real signed
        // .app bundle apply this at different points, leaving the packaged app
        // with an opaque titlebar). Re-applying every time the window becomes key
        // — not just once on a deferred tick — makes this self-healing regardless
        // of that timing.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, window === self.mainWindow else { return }
            Self.applyWindowChrome(to: window)
        }
        if let window {
            Self.applyWindowChrome(to: window)
        }

        hotKey.handler = { [weak self] in
            Task { @MainActor in
                self?.toggleWindow()
            }
        }
        applySummonHotKey()
        // The global hotkey is registered once with whatever keyCode/
        // modifiers were current at launch — re-applied whenever any
        // UserDefaults value changes (cheap: guarded by an equality check
        // against what's already registered) so a change in Settings →
        // Shortcuts takes effect without restarting the app.
        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applySummonHotKey()
        }

        setUpStatusItem()

        // Spotlight/Alfred-style auto-hide, opt-in via Settings → General.
        // didResignActiveNotification only fires when a *different app*
        // becomes active (or the desktop takes focus) — switching between
        // Envy's own windows (Settings, About) keeps Envy active, so this
        // can't accidentally hide the main window out from under those.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hideIfAutoHideEnabled()
        }
    }

    private func hideIfAutoHideEnabled() {
        guard UserDefaults.standard.bool(forKey: "hideOnFocusLoss") else { return }
        NSApp.hide(nil)
    }

    private func applySummonHotKey() {
        let raw = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) ?? ""
        let binding = ShortcutPreferences.binding(for: .summonApp, raw: raw)
        guard binding != appliedSummonBinding else { return }
        appliedSummonBinding = binding
        hotKey.unregister()
        hotKey.register(keyCode: UInt32(binding.keyCode), modifiers: binding.carbonModifiers)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // A template image (not the full-color app icon) so it inverts
            // correctly in dark menu bars and while highlighted, matching
            // every other menu bar icon.
            button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Envy")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Left-click summons/hides the app exactly like the global hotkey;
    /// right-click shows a small menu instead — the two need to be told
    /// apart manually since a status item's .button.action alone doesn't
    /// distinguish which mouse button was used.
    @MainActor
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            toggleWindow()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let newNote = NSMenuItem(title: "New Note", action: #selector(newNoteFromStatusMenu), keyEquivalent: "")
        newNote.target = self
        menu.addItem(newNote)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromStatusMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem(title: "Quit Envy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func newNoteFromStatusMenu() {
        activateAndShowWindow()
        NotificationCenter.default.post(name: .newNoteRequested, object: nil)
    }

    @objc private func openSettingsFromStatusMenu() {
        // The raw showSettingsWindow: selector send (a common trick for
        // triggering SwiftUI's Settings scene from AppKit code) turned out
        // unreliable here — routed through a notification instead, handled
        // by ContentView using the properly supported
        // \.openSettings environment action.
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    private func activateAndShowWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    private static func applyWindowChrome(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        // The title bar is deliberately opaque (not transparent like the
        // rest of the window) so it reads as one solid block together with
        // the search/sort chrome directly below it, rather than fading into
        // the translucent backdrop behind the note list and editor.
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
    }

    @MainActor
    private func toggleWindow() {
        guard let window = NSApp.windows.first else { return }
        if NSApp.isActive && window.isKeyWindow {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .summonRequested, object: nil)
        }
    }

    // The red close button would otherwise let SwiftUI actually destroy the
    // WindowGroup's window — after that, NSApp.windows.first (used to
    // summon it back, both from the global hotkey and the menu bar item)
    // comes back nil or wrong, so clicking either appeared to do nothing.
    // Hiding instead of closing keeps the window alive so it can always be
    // brought back, the same "quit-resistant" behavior the summon hotkey
    // and menu bar item are meant to provide.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

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
            }
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    NotificationCenter.default.post(name: .newNoteRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .newNote).keyEquivalent, modifiers: binding(for: .newNote).eventModifiers)
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
            CommandMenu("Folders") {
                Button("Next Folder") {
                    NotificationCenter.default.post(name: .nextFolderRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .nextFolder).keyEquivalent, modifiers: binding(for: .nextFolder).eventModifiers)

                Button("Previous Folder") {
                    NotificationCenter.default.post(name: .previousFolderRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .previousFolder).keyEquivalent, modifiers: binding(for: .previousFolder).eventModifiers)
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

        Settings {
            SettingsView()
        }
    }
}

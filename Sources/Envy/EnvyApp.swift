import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKey = GlobalHotKey()
    private var centerWindowMonitor: Any?
    private weak var mainWindow: NSWindow?
    private var keyObserver: Any?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppearanceMode.applyStored()

        let window = NSApp.windows.first
        mainWindow = window
        window?.makeKeyAndOrderFront(nil)

        // A SwiftUI .commands keyboardShortcut(.return, modifiers: [.command])
        // here loses to AppKit's own default Return-key handling (which zooms/
        // full-screens the window) more often than it wins. A local monitor lets
        // us intercept and consume the key combo ourselves, deterministically.
        centerWindowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isPlainCommandReturn = event.keyCode == 36
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command]
            guard isPlainCommandReturn else { return event }
            NSApp.windows.first?.center()
            return nil
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
        hotKey.register()

        setUpStatusItem()
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
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
}

@main
struct EnvyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

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
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("Delete Note") {
                    NotificationCenter.default.post(name: .deleteSelectedRequested, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Layout") {
                    NotificationCenter.default.post(name: .toggleLayoutRequested, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("Font") {
                Button("Bold") {
                    NotificationCenter.default.post(name: .boldSelectionRequested, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Italic") {
                    NotificationCenter.default.post(name: .italicSelectionRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomInRequested, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOutRequested, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .zoomResetRequested, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
            CommandGroup(after: .windowArrangement) {
                // No .keyboardShortcut here — ⌘↩ is handled by the local event
                // monitor in AppDelegate instead, since SwiftUI's menu-shortcut
                // registration for this combo loses to AppKit's default Return
                // handling (which zooms/full-screens the window).
                Button("Center Window") {
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

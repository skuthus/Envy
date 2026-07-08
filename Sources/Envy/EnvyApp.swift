import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKey = GlobalHotKey()
    private var centerWindowMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppearanceMode.applyStored()
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }

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
        // window's initial (non-full-size) titlebar assumption. Deferring a tick
        // lets AppKit actually relayout against the new style mask.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        }

        hotKey.handler = { [weak self] in
            Task { @MainActor in
                self?.toggleWindow()
            }
        }
        hotKey.register()
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

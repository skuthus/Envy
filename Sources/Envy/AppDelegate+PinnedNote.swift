import SwiftUI
import AppKit

// The pinned-note panel: the small floating, resizable window a menu bar
// click (or its dedicated hotkey) opens on the pinned note, plus the
// NSWindowDelegate callbacks that manage its lifecycle. Split out of
// EnvyApp.swift purely for file size/navigability — same class, zero
// behavior change.

// Top-level in this file (not statics on the class) because extensions
// can't hold static stored properties.
private let pinnedPanelWidthKey = "menuBarPopoverWidth"
private let pinnedPanelHeightKey = "menuBarPopoverHeight"
private let defaultPinnedPanelSize = NSSize(width: 320, height: 400)

extension AppDelegate {
    // Read straight from UserDefaults rather than @AppStorage — AppDelegate
    // is a plain NSObject, not a SwiftUI view, so @AppStorage has nothing to
    // invalidate/re-render here; a direct read of whatever's current at
    // click time is all this needs.
    var shouldShowPinnedNotePopover: Bool {
        UserDefaults.standard.string(forKey: "menuBarClickAction") == MenuBarClickAction.showPinnedNote.rawValue
    }

    /// nil if nothing's pinned, or if the pinned path no longer exists on
    /// disk (renamed, moved, deleted since being pinned) — falls back to
    /// the normal toggleWindow() behavior in either case rather than
    /// popping up an empty/broken panel.
    var pinnedNoteURL: URL? {
        let path = UserDefaults.standard.string(forKey: "menuBarPinnedNotePath") ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A plain NSPopover doesn't support user drag-to-resize at all — no
    /// resize handle, no edge dragging, that's just not something the class
    /// offers. A borderless, resizable NSPanel does, at the cost of having
    /// to hand-roll what NSPopover gave for free: positioning near the
    /// status item, and dismissing on any outside click (done here via
    /// windowDidResignKey rather than juggling global/local event monitors —
    /// simpler, and resigning key already covers "clicked elsewhere in Envy"
    /// and "clicked another app" uniformly).
    @MainActor
    func togglePinnedNotePanel(for url: URL) {
        if let panel = pinnedNotePanel, panel.isVisible {
            panel.close()
            return
        }
        showPinnedNotePanel(for: url)
    }

    /// Unlike togglePinnedNotePanel above, always shows the panel rather
    /// than closing it if already open for something else — used right
    /// after creating a brand new pinned note (from the status menu), where
    /// the intent is unambiguous: show me what I just made, not toggle
    /// whatever might already be open.
    @MainActor
    func showPinnedNotePanel(for url: URL) {
        pinnedNotePanel?.close()
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }

        let width = UserDefaults.standard.double(forKey: pinnedPanelWidthKey)
        let height = UserDefaults.standard.double(forKey: pinnedPanelHeightKey)
        let size = NSSize(
            width: width > 0 ? width : defaultPinnedPanelSize.width,
            height: height > 0 ? height : defaultPinnedPanelSize.height
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 200, height: 150)
        panel.contentViewController = NSHostingController(rootView: PinnedNotePopoverView(
            url: url,
            onOpenInApp: { [weak self] in
                self?.pinnedNotePanel?.close()
                self?.activateAndShowWindow()
                NotificationCenter.default.post(name: .externalNoteOpenRequested, object: url)
            }
        ))

        // Positioned like the old popover's preferredEdge: .minY — centered
        // under the status item button, clamped so it can't run off the
        // right/left/bottom edge of the screen the button's actually on
        // (menu bar items sit close to the screen edge often enough that
        // this isn't just a theoretical concern).
        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: buttonFrameOnScreen.midX - size.width / 2, y: buttonFrameOnScreen.minY - size.height - 4)
        if let screenFrame = buttonWindow.screen?.visibleFrame {
            origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - size.width)
            origin.y = max(origin.y, screenFrame.minY)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        panel.makeKeyAndOrderFront(nil)
        pinnedNotePanel = panel
        updateStatusItemIcon()
    }

    /// Catches every way the pinned note panel can close — the explicit
    /// toggle-closed path, the outside-click auto-dismiss in
    /// windowDidResignKey, and the "open in app" button's close() — in one
    /// place, rather than remembering to call updateStatusItemIcon()
    /// separately at each call site.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === pinnedNotePanel else { return }
        // Not a plain updateStatusItemIcon() call — windowWillClose fires
        // before the panel actually finishes closing, so its own isVisible
        // still reads true at this exact moment, which meant the squint
        // icon never reverted to closed. Computed directly instead of
        // through the panel's own (still-stale) visibility.
        settleStatusIconAfterPinnedPanelClose()
    }

    /// Auto-dismisses the pinned-note panel on any outside click — the
    /// hand-rolled replacement for NSPopover's own .transient behavior.
    /// Guarded to only act on the panel itself since AppDelegate is also
    /// the main window's delegate, and this method is new (not overriding
    /// anything the main window relied on), but better safe than sorry.
    /// Skipped entirely while the panel's own pin button is on — that's the
    /// whole point of it, staying open (and, via .floating level set when
    /// the panel was created, on top of other windows) instead of closing
    /// the moment focus moves elsewhere. Still closeable any time by
    /// clicking the menu bar icon again, pinned or not.
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === pinnedNotePanel else { return }
        guard !UserDefaults.standard.bool(forKey: "menuBarPopoverPinnedOpen") else { return }
        window.close()
    }

    /// Persists the user's chosen size so the panel reopens at whatever
    /// size they last left it, rather than always resetting back to the
    /// default 320x400. windowDidEndLiveResize (fires once, after a resize
    /// drag finishes) rather than windowDidResize (fires continuously
    /// during the drag) — no reason to hit UserDefaults dozens of times for
    /// one resize gesture.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === pinnedNotePanel else { return }
        UserDefaults.standard.set(window.frame.width, forKey: pinnedPanelWidthKey)
        UserDefaults.standard.set(window.frame.height, forKey: pinnedPanelHeightKey)
    }
}

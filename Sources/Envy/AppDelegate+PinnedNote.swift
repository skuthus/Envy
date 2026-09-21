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
private let pinnedTaskPanelWidthKey = "menuBarTaskPanelWidth"
private let pinnedTaskPanelHeightKey = "menuBarTaskPanelHeight"
private let defaultPinnedTaskPanelSize = NSSize(width: 380, height: 520)

extension AppDelegate {
    /// nil if nothing's pinned, or if the pinned path no longer exists on
    /// disk (renamed, moved, deleted since being pinned) — falls back to
    /// the normal toggleWindow() behavior in either case rather than
    /// popping up an empty/broken panel.
    ///
    /// Read straight from UserDefaults rather than @AppStorage — AppDelegate
    /// is a plain NSObject, not a SwiftUI view, so @AppStorage has nothing to
    /// invalidate/re-render here; a direct read of whatever's current at
    /// click time is all this needs.
    var pinnedNoteURL: URL? {
        let path = UserDefaults.standard.string(forKey: "menuBarPinnedNotePath") ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Clears the menu bar's pinned note — "Unpin Note" in the status
    /// item's right-click menu, or its own dedicated global shortcut
    /// (Settings → Shortcuts). Closes the pinned panel too, if it's open,
    /// since it'd otherwise keep showing a note that's no longer "the"
    /// pinned one. No-op if nothing's currently pinned.
    @MainActor
    func unpinMenuBarNote() {
        guard pinnedNoteURL != nil else { return }
        UserDefaults.standard.set("", forKey: "menuBarPinnedNotePath")
        pinnedNotePanel?.close()
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
        panel.level = .envyFloatingNote
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

    // MARK: - Task pin (unified: the whole-vault task list OR one note's tasks)
    //
    // Exactly one thing is pinned to the eye at a time. The whole-note pin
    // (menuBarPinnedNotePath) and this task pin are mutually exclusive — setting
    // either clears the other — so pinning a note, a note's tasks, or the task
    // list all work identically and never tangle.

    /// "" (nothing), "list" (whole-vault task list), or a note id (that note's
    /// tasks). The single source of truth for the task side of the eye pin.
    var menuBarTaskPin: String {
        get { UserDefaults.standard.string(forKey: "menuBarTaskPin") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarTaskPin") }
    }

    var taskListPinned: Bool { menuBarTaskPin == "list" }
    func isNoteTasksPinned(_ noteID: String) -> Bool { menuBarTaskPin == noteID }

    /// Clears the task pin and closes its panel — both to unpin and to make
    /// room when a whole note is pinned instead.
    @MainActor
    func clearTaskPin() {
        menuBarTaskPin = ""
        pinnedTaskPanel?.close()
    }

    /// Clears the whole-note pin — the task pins call this so the two can't
    /// both be set at once. (unpinMenuBarNote is the user-facing unpin.)
    @MainActor
    func clearNotePinForTaskPin() {
        UserDefaults.standard.set("", forKey: "menuBarPinnedNotePath")
        pinnedNotePanel?.close()
    }

    @MainActor
    func pinTaskList() {
        clearNotePinForTaskPin()
        menuBarTaskPin = "list"
        showTaskPinPanel()
    }

    /// Note-list "Pin/Unpin Note Tasks" — toggles this note's tasks as the eye's
    /// pinned item, exactly the way Pin to Menu Bar toggles the whole note.
    @MainActor
    func togglePinNoteTasks(for noteID: String) {
        if menuBarTaskPin == noteID {
            clearTaskPin()
        } else {
            clearNotePinForTaskPin()
            menuBarTaskPin = noteID
            showTaskPinPanel()
        }
    }

    /// The eye-click handler for a task pin: open the panel, or close it if
    /// already open — the same toggle the pinned note gets.
    @MainActor
    func toggleTaskPinPanel() {
        if let panel = pinnedTaskPanel, panel.isVisible {
            panel.close()
            return
        }
        showTaskPinPanel()
    }

    /// The one task-pin panel, hosting whichever view the pin names — the
    /// whole-vault list or a single note's tasks. Anchored under the eye and
    /// sized from one shared memory, exactly like the pinned-note panel; shares
    /// the main window's live store so there's no second vault load.
    @MainActor
    func showTaskPinPanel() {
        let pin = menuBarTaskPin
        guard !pin.isEmpty else { return }
        pinnedTaskPanel?.close()
        guard let store = contentStore else {
            activateAndShowWindow()
            return
        }
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }

        let width = UserDefaults.standard.double(forKey: pinnedTaskPanelWidthKey)
        let height = UserDefaults.standard.double(forKey: pinnedTaskPanelHeightKey)
        let size = NSSize(
            width: width > 0 ? width : defaultPinnedTaskPanelSize.width,
            height: height > 0 ? height : defaultPinnedTaskPanelSize.height
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
        panel.level = .envyFloatingNote
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 240, height: 180)

        let openInApp: (URL) -> Void = { [weak self] url in
            self?.pinnedTaskPanel?.close()
            self?.activateAndShowWindow()
            NotificationCenter.default.post(name: .externalNoteOpenRequested, object: url)
        }
        let root: AnyView = pin == "list"
            ? AnyView(TaskListPanelView(store: store, onOpenNote: openInApp))
            : AnyView(NoteTaskPanelView(store: store, noteID: pin, onOpenNote: openInApp))
        panel.contentViewController = NSHostingController(rootView: root)

        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: buttonFrameOnScreen.midX - size.width / 2, y: buttonFrameOnScreen.minY - size.height - 4)
        if let screenFrame = buttonWindow.screen?.visibleFrame {
            origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - size.width)
            origin.y = max(origin.y, screenFrame.minY)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        pinnedTaskPanel = panel
        updateStatusItemIcon()
    }

    /// Catches every way a pinned panel closes in one place, so the eye icon
    /// settles without each call site remembering to.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === pinnedNotePanel || window === pinnedTaskPanel else { return }
        // windowWillClose fires before the panel finishes closing, so its own
        // isVisible still reads true here — settle from the main window's state
        // directly instead.
        settleStatusIconAfterPinnedPanelClose()
    }

    /// Auto-dismisses a pinned panel (note or task) on any outside click — the
    /// hand-rolled stand-in for NSPopover's .transient. The note panel honors
    /// its keep-open pin; the task panel always dismisses. Either reopens with
    /// a click on the eye.
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === pinnedTaskPanel {
            window.close()
            return
        }
        guard window === pinnedNotePanel else { return }
        guard !UserDefaults.standard.bool(forKey: "menuBarPopoverPinnedOpen") else { return }
        window.close()
    }

    /// Persists each panel's chosen size so it reopens the size it was left.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === pinnedTaskPanel {
            UserDefaults.standard.set(window.frame.width, forKey: pinnedTaskPanelWidthKey)
            UserDefaults.standard.set(window.frame.height, forKey: pinnedTaskPanelHeightKey)
            return
        }
        guard window === pinnedNotePanel else { return }
        UserDefaults.standard.set(window.frame.width, forKey: pinnedPanelWidthKey)
        UserDefaults.standard.set(window.frame.height, forKey: pinnedPanelHeightKey)
    }
}

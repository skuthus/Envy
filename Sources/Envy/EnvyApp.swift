import SwiftUI
import AppKit
import Sparkle

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
    private var blinkTimer: Timer?
    private var appliedVisibility: AppVisibility?
    private var windowStateObservers: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Applied inline here rather than via applyAppVisibility() below —
        // that helper also creates the status item, which needs mainWindow
        // already assigned and visible to show the correct open/closed eye
        // immediately, and neither is true yet at this point in launch.
        let visibility = currentAppVisibility
        appliedVisibility = visibility
        applyActivationPolicy(for: visibility)
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
            self?.applyAppVisibility()
        }

        if visibility.showsInMenuBar {
            setUpStatusItem()
        }

        // Menu Bar Only mode still needs a real Dock presence (and thus a
        // real menu bar — File/Edit/View/etc. are simply unavailable to a
        // .accessory-policy app, that's Apple's own documented behavior,
        // not a bug) whenever an Envy window is actually open, since so
        // much lives in that menu (Font, Navigate, Folders, Check for
        // Updates...). These two fire for *any* window in the app — main,
        // Settings, About, What's New — not just mainWindow, so opening or
        // closing any of them re-evaluates it.
        windowStateObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyActivationPolicy(for: self.currentAppVisibility)
        })
        windowStateObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Deferred a tick via a near-zero timer (target/selector,
            // matching the blink timer's pattern above) — a nested
            // DispatchQueue.main.async or Task closure capturing self
            // fights Swift 6 strict concurrency across this observer's own
            // @Sendable boundary, but a plain target/selector Timer isn't
            // capturing self into another closure at all. Resigning key
            // can hand key status straight to another still-open Envy
            // window (e.g. dismissing Settings while the main window is
            // still up), and checking immediately would see zero key
            // windows in that gap and spuriously demote to .accessory
            // before the new key window is assigned.
            Timer.scheduledTimer(timeInterval: 0, target: self, selector: #selector(self.reevaluateActivationPolicy), userInfo: nil, repeats: false)
        })

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
        // orderOut on the window itself, not NSApp.hide(nil) — the latter is
        // a full "Hide Application," which ties into Mission Control's
        // per-Space "last active app" bookkeeping. With multiple displays
        // each running their own Space, clicking back into the Space/display
        // this window used to occupy could silently un-hide it again, since
        // macOS treats that as restoring the Space's expected active app.
        // orderOut only affects this window, sidestepping that entirely —
        // the same reasoning windowShouldClose below already relies on.
        mainWindow?.orderOut(nil)
        updateStatusItemIcon()
    }

    private func applySummonHotKey() {
        let raw = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) ?? ""
        let binding = ShortcutPreferences.binding(for: .summonApp, raw: raw)
        guard binding != appliedSummonBinding else { return }
        appliedSummonBinding = binding
        hotKey.unregister()
        hotKey.register(keyCode: UInt32(binding.keyCode), modifiers: binding.carbonModifiers)
    }

    private var currentAppVisibility: AppVisibility {
        let raw = UserDefaults.standard.string(forKey: "appVisibility") ?? ""
        return AppVisibility(rawValue: raw) ?? .both
    }

    /// Re-applies AppVisibility live whenever it changes in Settings —
    /// safe to call any time after launch, since mainWindow already exists
    /// by then (see applicationDidFinishLaunching for why the launch-time
    /// version of this is handled separately, inline). Only the status
    /// item add/remove is gated on the *setting* actually changing —
    /// activation policy is re-derived every time regardless, since for
    /// Menu Bar Only mode it also depends on live window state, which can
    /// change independently of this setting (see applyActivationPolicy).
    private func applyAppVisibility() {
        let visibility = currentAppVisibility
        let visibilityChanged = visibility != appliedVisibility
        appliedVisibility = visibility

        applyActivationPolicy(for: visibility)
        guard visibilityChanged else { return }

        if visibility.showsInMenuBar {
            if statusItem == nil { setUpStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    /// Dock Only and Both are always .regular. Menu Bar Only is normally
    /// .accessory (no Dock icon, no menu bar — Apple's own documented
    /// behavior for that policy), but temporarily promotes to .regular
    /// whenever any Envy window is actually open, so File/Edit/View and
    /// everything else that only lives in the menu bar stays reachable
    /// while you're using the app — dropping back to .accessory once every
    /// window closes. Called both at launch and from the window
    /// key/resign-key observers set up in applicationDidFinishLaunching.
    private func applyActivationPolicy(for visibility: AppVisibility) {
        let desired: NSApplication.ActivationPolicy
        switch visibility {
        case .dockOnly, .both:
            desired = .regular
        case .menuBarOnly:
            desired = NSApp.windows.contains(where: { $0.isVisible }) ? .regular : .accessory
        }
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    @objc private func reevaluateActivationPolicy() {
        applyActivationPolicy(for: currentAppVisibility)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        updateStatusItemIcon()
        scheduleNextBlink()
    }

    // A small easter egg: every so often, at a random interval, flash the
    // menu bar eye shut and back open again — purely cosmetic, doesn't
    // touch mainWindow's actual visibility. Only blinks while the window is
    // genuinely showing; while hidden the eye is already closed, so there's
    // nothing to blink. Reschedules itself after every fire (and every
    // skipped fire while hidden), so it keeps going for the life of the app.
    private func scheduleNextBlink() {
        blinkTimer?.invalidate()
        // Target/selector rather than the closure-based Timer API — the
        // closure form's @Sendable block signature fights Swift 6 strict
        // concurrency when it captures self to hop back onto the main
        // actor. A @MainActor @objc selector sidesteps that entirely, same
        // as statusItemClicked(_:) above.
        blinkTimer = Timer.scheduledTimer(timeInterval: .random(in: 25...75), target: self, selector: #selector(performBlink), userInfo: nil, repeats: false)
    }

    @MainActor
    @objc private func performBlink() {
        defer { scheduleNextBlink() }
        guard mainWindow?.isVisible == true else { return }
        closeEyeBriefly()
        // A real eye occasionally double-blinks — about 1 in 4 here. Timed
        // as its own independent asyncAfter (0.2s close + 0.14s gap) rather
        // than chained off the first blink's completion, since a captured
        // completion closure fights Swift 6 strict concurrency the same way
        // the old closure-based Timer API did above.
        guard Int.random(in: 0..<4) == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            self?.closeEyeBriefly()
        }
    }

    @MainActor
    private func closeEyeBriefly() {
        statusItem?.button?.image = Self.closedEyeImage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateStatusItemIcon()
        }
    }

    // Both states are hand-drawn (not eye.fill/eye.slash.fill) so the open
    // eye's pupil can carry the brand's green iris color, which no SF
    // Symbol rendering mode of eye.fill supports. Both share the exact same
    // lower-rim curve, so the lid appears to close down onto the same line
    // it sits on when open, rather than the two glyphs disagreeing about
    // where the bottom of the eye actually is. Called after every place in
    // this file that changes mainWindow's visibility.
    private func updateStatusItemIcon() {
        let isVisible = mainWindow?.isVisible ?? false
        statusItem?.button?.image = isVisible ? Self.openEyeImage() : Self.closedEyeImage()
    }

    // Resolved against whatever NSAppearance the button is actually drawn
    // in (the menu bar's, not necessarily the app's own light/dark
    // setting) — the same adaptation isTemplate gives a plain monochrome
    // image, needed here too since the pupil below keeps its color instead
    // of being auto-tinted.
    private static let menuBarOutlineColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    private static let eyeLineWidth: CGFloat = 2.0
    // Corner y is the true vertical center of the 18pt-tall canvas (9.0),
    // not the earlier 9.5 — since openEyeImage()'s lens is built by
    // mirroring the lower rim above this same line, that 0.5pt offset was
    // enough to visibly throw the whole icon off-center against the other
    // menu bar items (e.g. the battery icon). closedEyeImage() shares these
    // same constants, so it stays centered on the open eye automatically.
    private static let eyeCornerLeft = NSPoint(x: 2.5, y: 9.0)
    private static let eyeCornerRight = NSPoint(x: 15.5, y: 9.0)
    private static let lowerRimControlLeft = NSPoint(x: 6, y: 4.3)
    private static let lowerRimControlRight = NSPoint(x: 12, y: 4.3)

    // Just the eyelid crease, traced along the exact same line and
    // curvature as openEyeImage()'s lower rim below — an eyelid closes
    // down to meet the lower lid, not the vertical center of the glyph's
    // bounding box. Reads as a shut eyelid rather than a "disabled"
    // slashed eye.
    private static func closedEyeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = eyeLineWidth
            path.move(to: eyeCornerLeft)
            path.curve(to: eyeCornerRight, controlPoint1: lowerRimControlLeft, controlPoint2: lowerRimControlRight)

            menuBarOutlineColor.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    // A lens (upper rim mirrored above the same corner line the lower rim
    // sits on) plus a solid pupil in the brand's iris green
    // (EnvyLogoView.irisColor) — the one deliberately non-monochrome
    // accent on an otherwise adaptive icon.
    private static func openEyeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = eyeLineWidth
            path.move(to: eyeCornerLeft)
            path.curve(to: eyeCornerRight, controlPoint1: lowerRimControlLeft, controlPoint2: lowerRimControlRight)
            let upperControlLeft = NSPoint(x: lowerRimControlLeft.x, y: 2 * eyeCornerLeft.y - lowerRimControlLeft.y)
            let upperControlRight = NSPoint(x: lowerRimControlRight.x, y: 2 * eyeCornerRight.y - lowerRimControlRight.y)
            path.curve(to: eyeCornerLeft, controlPoint1: upperControlRight, controlPoint2: upperControlLeft)

            menuBarOutlineColor.setStroke()
            path.stroke()

            let pupil = NSBezierPath(ovalIn: NSRect(x: 7, y: 6.8, width: 4, height: 4))
            NSColor(red: 0.243, green: 0.667, blue: 0.278, alpha: 1).setFill()
            pupil.fill()
            return true
        }
        image.isTemplate = false
        return image
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
        if let window = NSApp.windows.first {
            AeroSpaceInterop.bringToFocusedWorkspace(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        updateStatusItemIcon()
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
        // window.isVisible rather than NSApp.isActive && window.isKeyWindow —
        // this only needs to know whether the window itself is currently on
        // screen, independent of the app's broader activation state, which
        // matters now that hiding uses orderOut instead of NSApp.hide(nil)
        // (see hideIfAutoHideEnabled for why).
        if window.isVisible {
            window.orderOut(nil)
        } else {
            AeroSpaceInterop.bringToFocusedWorkspace(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .summonRequested, object: nil)
        }
        updateStatusItemIcon()
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
        updateStatusItemIcon()
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
    // startingUpdater: true begins Sparkle's own scheduled background check
    // immediately — harmless for EnvyTest too, since its Info.plist has no
    // SUFeedURL/SUPublicEDKey, so Sparkle has nothing to check against and
    // stays quiet rather than erroring.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    NotificationCenter.default.post(name: .newNoteRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .newNote).keyEquivalent, modifiers: binding(for: .newNote).eventModifiers)

                Button("New Note from Template") {
                    NotificationCenter.default.post(name: .newFromTemplateRequested, object: nil)
                }
                .keyboardShortcut(binding(for: .newFromTemplate).keyEquivalent, modifiers: binding(for: .newFromTemplate).eventModifiers)
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

        Window("What's New", id: "whatsnew") {
            WhatsNewView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}

import SwiftUI
import AppKit
import Sparkle
import EnvyCore

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
    private var appliedPinnedNoteBinding: ShortcutBinding?
    private static let summonHotKeyID: UInt32 = 1
    private static let pinnedNoteHotKeyID: UInt32 = 2
    private var blinkTimer: Timer?
    private var appliedVisibility: AppVisibility?
    private var windowStateObservers: [Any] = []
    private var pinnedNotePanel: NSPanel?

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

        // Assigned once via direct subscript assignment (not passed as a
        // register(...) argument — see GlobalHotKey's own comment on why)
        // and never touched again; only the key combination itself changes
        // when Settings → Shortcuts is edited.
        hotKey.handlers[Self.summonHotKeyID] = { [weak self] in
            Task { @MainActor in
                self?.toggleWindow()
            }
        }
        hotKey.handlers[Self.pinnedNoteHotKeyID] = { [weak self] in
            Task { @MainActor in
                self?.summonPinnedNote()
            }
        }
        applySummonHotKey()
        applyPinnedNoteHotKey()
        // Both global hotkeys are registered once with whatever keyCode/
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
            self?.applyPinnedNoteHotKey()
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
        hotKey.register(id: Self.summonHotKeyID, keyCode: UInt32(binding.keyCode), modifiers: binding.carbonModifiers)
    }

    private func applyPinnedNoteHotKey() {
        let raw = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) ?? ""
        let binding = ShortcutPreferences.binding(for: .showPinnedNote, raw: raw)
        guard binding != appliedPinnedNoteBinding else { return }
        appliedPinnedNoteBinding = binding
        hotKey.register(id: Self.pinnedNoteHotKeyID, keyCode: UInt32(binding.keyCode), modifiers: binding.carbonModifiers)
    }

    /// Always targets the pinned note directly, regardless of what
    /// "Clicking the menu bar icon" is set to in Settings — that setting is
    /// specifically about the icon click, while this is its own dedicated
    /// shortcut. No-op if nothing's currently pinned.
    @MainActor
    private func summonPinnedNote() {
        guard let pinnedNoteURL else { return }
        togglePinnedNotePanel(for: pinnedNoteURL)
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
    // touch mainWindow's/pinnedNotePanel's actual visibility. Only blinks
    // while the eye is genuinely showing something other than closed;
    // while both are hidden the eye is already closed, so there's nothing
    // to blink. Reschedules itself after every fire (and every skipped fire
    // while hidden), so it keeps going for the life of the app.
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
        guard mainWindow?.isVisible == true || pinnedNotePanel?.isVisible == true else { return }
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

    // Eases through the squint frame on the way down and back up, instead
    // of a hard cut straight to/from fully closed — reads as an eyelid
    // actually sliding shut rather than a binary flash. Same total ~0.2s
    // duration as the original two-frame version. Ends by handing off to
    // updateStatusItemIcon() rather than hardcoding a return to open, so it
    // correctly settles back on squint instead of open if the pinned note
    // popup is what's actually showing right now.
    @MainActor
    private func closeEyeBriefly() {
        statusItem?.button?.image = Self.squintEyeImage
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.statusItem?.button?.image = Self.closedEyeImage
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.statusItem?.button?.image = Self.squintEyeImage
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.updateStatusItemIcon()
                }
            }
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
        if mainWindow?.isVisible == true {
            statusItem?.button?.image = Self.openEyeImage
        } else if pinnedNotePanel?.isVisible == true {
            statusItem?.button?.image = Self.squintEyeImage
        } else {
            statusItem?.button?.image = Self.closedEyeImage
        }
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
    private static let pupilRect = NSRect(x: 6.5, y: 6.3, width: 5, height: 5)
    private static let pupilColor = NSColor(red: 0.194, green: 0.534, blue: 0.222, alpha: 1)

    // Just the eyelid crease, traced along the exact same line and
    // curvature as openEyeImage's lower rim below — an eyelid closes down
    // to meet the lower lid, not the vertical center of the glyph's
    // bounding box. Reads as a shut eyelid rather than a "disabled" slashed
    // eye. A `static let`, not a `static func` recomputed on every call —
    // NSImage(size:flipped:drawingHandler:) re-invokes its drawing block on
    // every actual draw regardless of when the NSImage itself was built, so
    // caching the instance loses nothing: menuBarOutlineColor's
    // light/dark-adaptive resolution still happens at real draw time.
    private static let closedEyeImage: NSImage = {
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
    }()

    // A lens (upper rim mirrored above the same corner line the lower rim
    // sits on) plus a solid pupil in the brand's iris green
    // (EnvyLogoView.irisColor) — the one deliberately non-monochrome
    // accent on an otherwise adaptive icon.
    private static let openEyeImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = eyeLineWidth
            path.move(to: eyeCornerLeft)
            path.curve(to: eyeCornerRight, controlPoint1: lowerRimControlLeft, controlPoint2: lowerRimControlRight)
            let upperControlLeft = NSPoint(x: lowerRimControlLeft.x, y: 2 * eyeCornerLeft.y - lowerRimControlLeft.y)
            let upperControlRight = NSPoint(x: lowerRimControlRight.x, y: 2 * eyeCornerRight.y - lowerRimControlRight.y)
            path.curve(to: eyeCornerLeft, controlPoint1: upperControlRight, controlPoint2: upperControlLeft)

            // White "sclera" fill across the whole lens (path already
            // closes back on itself via the two curves above), testing
            // whether that reads more clearly than the pupil floating
            // directly on whatever's behind the menu bar (wallpaper
            // showing through, a busy notch-area background, etc.) — pure
            // visibility experiment, not a settled design choice yet.
            NSColor.white.setFill()
            path.fill()

            menuBarOutlineColor.setStroke()
            path.stroke()

            let pupil = NSBezierPath(ovalIn: pupilRect)
            pupilColor.setFill()
            pupil.fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    // A drooping upper eyelid — much closer to the lower rim than
    // openEyeImage's fully mirrored one — for a sleepy/suspicious squint,
    // shown while the pinned note popup is open instead of the full app
    // window. The pupil is the exact same circle as the fully open eye,
    // just clipped to this shallower lens, so it reads as the same eye
    // partway through closing rather than a differently-sized iris.
    private static let squintEyeImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = eyeLineWidth
            path.move(to: eyeCornerLeft)
            path.curve(to: eyeCornerRight, controlPoint1: lowerRimControlLeft, controlPoint2: lowerRimControlRight)
            let squintUpperControlLeft = NSPoint(x: lowerRimControlLeft.x, y: 9.6)
            let squintUpperControlRight = NSPoint(x: lowerRimControlRight.x, y: 9.6)
            path.curve(to: eyeCornerLeft, controlPoint1: squintUpperControlRight, controlPoint2: squintUpperControlLeft)

            NSColor.white.setFill()
            path.fill()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let pupil = NSBezierPath(ovalIn: pupilRect)
            pupilColor.setFill()
            pupil.fill()
            NSGraphicsContext.restoreGraphicsState()

            menuBarOutlineColor.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }()

    /// Left-click summons/hides the app exactly like the global hotkey (or,
    /// with "Show Pinned Note" selected in Settings and a note actually
    /// pinned, shows that note in a small panel instead); right-click
    /// shows a small menu — the two need to be told apart manually since a
    /// status item's .button.action alone doesn't distinguish which mouse
    /// button was used.
    @MainActor
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else if shouldShowPinnedNotePopover, let pinnedNoteURL {
            togglePinnedNotePanel(for: pinnedNoteURL)
        } else {
            toggleWindow()
        }
    }

    // Read straight from UserDefaults rather than @AppStorage — AppDelegate
    // is a plain NSObject, not a SwiftUI view, so @AppStorage has nothing to
    // invalidate/re-render here; a direct read of whatever's current at
    // click time is all this needs.
    private var shouldShowPinnedNotePopover: Bool {
        UserDefaults.standard.string(forKey: "menuBarClickAction") == MenuBarClickAction.showPinnedNote.rawValue
    }

    /// nil if nothing's pinned, or if the pinned path no longer exists on
    /// disk (renamed, moved, deleted since being pinned) — falls back to
    /// the normal toggleWindow() behavior in either case rather than
    /// popping up an empty/broken panel.
    private var pinnedNoteURL: URL? {
        let path = UserDefaults.standard.string(forKey: "menuBarPinnedNotePath") ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static let pinnedPanelWidthKey = "menuBarPopoverWidth"
    private static let pinnedPanelHeightKey = "menuBarPopoverHeight"
    private static let defaultPinnedPanelSize = NSSize(width: 320, height: 400)

    /// A plain NSPopover doesn't support user drag-to-resize at all — no
    /// resize handle, no edge dragging, that's just not something the class
    /// offers. A borderless, resizable NSPanel does, at the cost of having
    /// to hand-roll what NSPopover gave for free: positioning near the
    /// status item, and dismissing on any outside click (done here via
    /// windowDidResignKey rather than juggling global/local event monitors —
    /// simpler, and resigning key already covers "clicked elsewhere in Envy"
    /// and "clicked another app" uniformly).
    @MainActor
    private func togglePinnedNotePanel(for url: URL) {
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
    private func showPinnedNotePanel(for url: URL) {
        pinnedNotePanel?.close()
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }

        let width = UserDefaults.standard.double(forKey: Self.pinnedPanelWidthKey)
        let height = UserDefaults.standard.double(forKey: Self.pinnedPanelHeightKey)
        let size = NSSize(
            width: width > 0 ? width : Self.defaultPinnedPanelSize.width,
            height: height > 0 ? height : Self.defaultPinnedPanelSize.height
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
        // icon never reverted to closed. Computed directly here instead of
        // through the panel's own (still-stale) visibility.
        statusItem?.button?.image = (mainWindow?.isVisible == true) ? Self.openEyeImage : Self.closedEyeImage
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
        UserDefaults.standard.set(window.frame.width, forKey: Self.pinnedPanelWidthKey)
        UserDefaults.standard.set(window.frame.height, forKey: Self.pinnedPanelHeightKey)
    }

    @MainActor
    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let newNote = NSMenuItem(title: "New Note", action: #selector(newNoteFromStatusMenu), keyEquivalent: "")
        newNote.target = self
        menu.addItem(newNote)

        let newPinnedNote = NSMenuItem(title: "New Pinned Note", action: #selector(newPinnedNoteFromStatusMenu), keyEquivalent: "")
        newPinnedNote.target = self
        menu.addItem(newPinnedNote)

        let templateParent = NSMenuItem(title: "New Pinned Note from Template", action: nil, keyEquivalent: "")
        templateParent.submenu = templateSubmenu()
        menu.addItem(templateParent)

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

    /// A NoteStore scoped to whatever folders are actually configured, used
    /// and discarded within a single menu action — reuses the exact same
    /// unique-filename and template-substitution logic the main app relies
    /// on (rather than re-implementing either here) without needing a
    /// second *live*, ongoing NoteStore instance: its FSEvents watcher tears
    /// itself down via deinit the moment this goes out of scope. Safe to
    /// use immediately after construction (not needing to wait for its own
    /// async initial reload) since both create(title:) and
    /// create(title:fromTemplate:dateText:) check the filesystem directly
    /// for filename uniqueness, not the (possibly still-loading) in-memory
    /// notes array.
    @MainActor
    private func makeScratchNoteStore() -> NoteStore {
        NoteStore(directories: NotesDirectoryPreference.loadEnabled())
    }

    @MainActor
    @objc private func newPinnedNoteFromStatusMenu() {
        let note = makeScratchNoteStore().create(title: "Untitled")
        pinToMenuBarAndShow(note)
    }

    @MainActor
    private func templateSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let includeAllFolders = UserDefaults.standard.string(forKey: "templatesScope") == TemplatesScope.perFolder.rawValue
        let templates = makeScratchNoteStore().templates(includeAllFolders: includeAllFolders)
        if templates.isEmpty {
            let empty = NSMenuItem(title: "No Templates", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for template in templates {
                let item = NSMenuItem(title: template.name, action: #selector(newPinnedNoteFromTemplateMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = template
                submenu.addItem(item)
            }
        }
        return submenu
    }

    @MainActor
    @objc private func newPinnedNoteFromTemplateMenuItem(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? NoteTemplate else { return }
        let pattern = UserDefaults.standard.string(forKey: "templateDateFormatPattern") ?? TemplateDateFormat.defaultPattern
        let dateText = TemplateDateFormat.string(from: Date(), pattern: pattern)
        let note = makeScratchNoteStore().create(title: template.name, fromTemplate: template, dateText: dateText)
        pinToMenuBarAndShow(note)
    }

    /// Shared tail end of both "New Pinned Note" and "…from Template" —
    /// pins the just-created note (replacing whatever was pinned before,
    /// same one-slot behavior as pinning from the note list's own context
    /// menu), switches "Clicking the menu bar icon" over to "Show Pinned
    /// Note" so the note just created is actually reachable that way
    /// afterward, and shows it immediately so there's no extra click
    /// between "make a pinned note" and "start typing in it."
    @MainActor
    private func pinToMenuBarAndShow(_ note: Note) {
        UserDefaults.standard.set(note.id, forKey: "menuBarPinnedNotePath")
        UserDefaults.standard.set(MenuBarClickAction.showPinnedNote.rawValue, forKey: "menuBarClickAction")
        showPinnedNotePanel(for: note.url)
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
        updateStatusItemIcon()
        if let windowNumber = NSApp.windows.first?.windowNumber {
            performAeroSpaceHandoff(forWindowNumber: windowNumber)
        }
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
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .summonRequested, object: nil)
            performAeroSpaceHandoff(forWindowNumber: window.windowNumber)
        }
        updateStatusItemIcon()
    }

    /// Moves/focuses Envy's window onto AeroSpace's currently focused
    /// workspace — a real, blocking socket round trip (see
    /// AeroSpaceInterop's own comments), so this always runs on a
    /// background queue and never blocks the window actually appearing.
    ///
    /// This used to also capture whatever AeroSpace had focused beforehand
    /// and explicitly restore it on hide, to work around Envy's own
    /// AeroSpace focus commands disrupting accordion-mode layouts. That
    /// restore step turned out to cause a worse problem of its own:
    /// re-focusing a minimized window in AeroSpace un-minimizes it, and if
    /// the captured ID went stale, hiding Envy could un-minimize and raise
    /// a completely unrelated window — a jarring, unrelated interruption.
    /// Removed rather than patched further: with Envy configured to
    /// always float (via the user's own aerospace.toml on-window-detected
    /// rule), the original accordion-reshuffling bug this was working
    /// around shouldn't occur in the first place, since a floating window
    /// never enters the tiling container that bug was about.
    private func performAeroSpaceHandoff(forWindowNumber windowNumber: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            AeroSpaceInterop.bringToFocusedWorkspace(windowNumber: windowNumber)
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

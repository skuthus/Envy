import SwiftUI
import AppKit
import EnvyCore

// The app's AppKit backbone: window lifecycle, global hotkeys, summon/hide
// with focus handoff, activation policy, and auto-hide. The menu bar status
// item lives in AppDelegate+MenuBar.swift and the pinned-note panel in
// AppDelegate+PinnedNote.swift; several members here sit at internal (not
// private) access because those same-class extensions live in other files.
//
// @MainActor on the class rather than sprinkled per-method (which is how it
// had grown): everything here touches AppKit, and AppKit delivers every
// delegate callback, menu action, and .main-queue notification on the main
// thread anyway — the blanket isolation just tells the compiler so, and the
// few @Sendable observer closures assert it explicitly with assumeIsolated.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let hotKey = GlobalHotKey()
    private var keyDownMonitor: Any?
    weak var mainWindow: NSWindow?
    private var keyObserver: Any?
    var statusItem: NSStatusItem?
    private var shortcutsObserver: Any?
    private var resignActiveObserver: Any?
    private var appliedSummonBinding: ShortcutBinding?
    private var appliedPinnedNoteBinding: ShortcutBinding?
    private var appliedUnpinNoteBinding: ShortcutBinding?
    private static let summonHotKeyID: UInt32 = 1
    private static let pinnedNoteHotKeyID: UInt32 = 2
    private static let unpinNoteHotKeyID: UInt32 = 3
    var blinkTimer: Timer?
    private var appliedVisibility: AppVisibility?
    private var windowStateObservers: [Any] = []
    var pinnedNotePanel: NSPanel?
    // Whatever app was frontmost right before we summoned Envy over the top
    // of it, so hiding Envy can hand focus straight back to it rather than
    // letting AppKit pick an arbitrary "next" window — see
    // captureFrontmostForRestore() / restorePreviousAppFocus() for why that
    // matters under AeroSpace.
    private var appToRestoreOnHide: NSRunningApplication?

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

        // resolveMainWindow, not a one-shot NSApp.windows.first capture: when
        // Envy launches as a login item during sign-in, SwiftUI often hasn't
        // created the WindowGroup window yet by the time this runs — the old
        // capture left mainWindow nil forever, and every later summon fell
        // back to a raw windows.first that could be the status-bar window or
        // a floating panel, so nothing visibly opened until a full relaunch.
        // Resolution is lazy now (here, in the key observer below, and in
        // every summon path), so the window is adopted whenever it appears.
        let window = resolveMainWindow()
        window?.makeKeyAndOrderFront(nil)

        // A SwiftUI .commands keyboardShortcut here loses to AppKit's own
        // default key handling (Return zooms the window; Option+Up/Down are
        // claimed by paragraph-navigation text editing inside any text view)
        // more often than it wins. One local monitor intercepts and consumes
        // these combos ourselves, deterministically — matched against the
        // user's customizable bindings (Settings → Shortcuts) rather than
        // hardcoded keys, read from UserDefaults on every keypress so a
        // change in Settings takes effect immediately (cheap: the decode is
        // memoized inside ShortcutPreferences, so this is a string compare
        // per keypress, not a JSON parse).
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let raw = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) ?? ""
            let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
            func matches(_ binding: ShortcutBinding) -> Bool {
                event.charactersIgnoringModifiers == binding.character && EventModifiers(relevant) == binding.eventModifiers
            }
            if matches(ShortcutPreferences.binding(for: .centerWindow, raw: raw)) {
                // The key window (the one the user is actually looking at,
                // main or a floating note), not a raw windows.first that
                // could be the status-bar window.
                NSApp.keyWindow?.center()
                return nil
            }
            if matches(ShortcutPreferences.binding(for: .focusNextArea, raw: raw)) {
                NotificationCenter.default.post(name: .focusNextAreaRequested, object: nil)
                return nil
            }
            if matches(ShortcutPreferences.binding(for: .focusPreviousArea, raw: raw)) {
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
            // The .main queue already guarantees the main thread;
            // assumeIsolated tells the compiler what the queue promised.
            // Same pattern for every observer below. The notification's
            // object crosses into the isolated closure as unsafe only
            // because Notification itself isn't Sendable — same guarantee.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let self, let window = object as? NSWindow else { return }
                // Late adoption for the login-item launch: the WindowGroup
                // window that didn't exist at didFinishLaunching announces
                // itself here the first time it becomes key.
                if self.mainWindow == nil, Self.isMainWindowCandidate(window) {
                    self.adoptMainWindow(window)
                    return
                }
                guard window === self.mainWindow else { return }
                Self.applyWindowChrome(to: window)
            }
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
        hotKey.handlers[Self.unpinNoteHotKeyID] = { [weak self] in
            Task { @MainActor in
                self?.unpinMenuBarNote()
            }
        }
        applySummonHotKey()
        applyPinnedNoteHotKey()
        applyUnpinNoteHotKey()
        // All three global hotkeys are registered once with whatever keyCode/
        // modifiers were current at launch — re-applied whenever any
        // UserDefaults value changes (cheap: guarded by an equality check
        // against what's already registered) so a change in Settings →
        // Shortcuts takes effect without restarting the app.
        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySummonHotKey()
                self?.applyPinnedNoteHotKey()
                self?.applyUnpinNoteHotKey()
                self?.applyAppVisibility()
            }
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyActivationPolicy(for: self.currentAppVisibility)
            }
        })
        windowStateObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Deferred a tick via a near-zero timer (target/selector,
            // matching the blink timer's pattern) — a nested
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
            MainActor.assumeIsolated {
                self?.hideIfAutoHideEnabled()
            }
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

    /// One registration rule for all three global hotkeys: read the current
    /// binding, skip if it's what's already registered, re-register otherwise.
    private func applyHotKey(_ action: ShortcutAction, id: UInt32, applied: inout ShortcutBinding?) {
        let raw = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) ?? ""
        let binding = ShortcutPreferences.binding(for: action, raw: raw)
        guard binding != applied else { return }
        applied = binding
        hotKey.register(id: id, keyCode: UInt32(binding.keyCode), modifiers: binding.carbonModifiers)
    }

    private func applySummonHotKey() {
        applyHotKey(.summonApp, id: Self.summonHotKeyID, applied: &appliedSummonBinding)
    }

    private func applyPinnedNoteHotKey() {
        applyHotKey(.showPinnedNote, id: Self.pinnedNoteHotKeyID, applied: &appliedPinnedNoteBinding)
    }

    private func applyUnpinNoteHotKey() {
        applyHotKey(.unpinFromMenuBar, id: Self.unpinNoteHotKeyID, applied: &appliedUnpinNoteBinding)
    }

    /// Always targets the pinned note directly. No-op if nothing's
    /// currently pinned.
    @MainActor
    private func summonPinnedNote() {
        guard let pinnedNoteURL else { return }
        togglePinnedNotePanel(for: pinnedNoteURL)
    }

    var currentAppVisibility: AppVisibility {
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
    func applyActivationPolicy(for visibility: AppVisibility) {
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

    /// Shim for non-isolated callers (menu actions, panel callbacks — all of
    /// which run on the main thread anyway). This used to be a hand-rolled
    /// copy of the summon sequence that had already drifted from it (no
    /// deminiaturize, no .summonRequested post); routing through
    /// summonMainWindow keeps "the single path" claim true.
    @MainActor
    func activateAndShowWindow() {
        summonMainWindow()
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

    /// The WindowGroup window's signature: a real, titled, main-capable
    /// window — which excludes the status-bar item's window (borderless,
    /// can't become main) and every floating peek/pinned NSPanel, exactly
    /// the impostors a raw NSApp.windows.first could hand back.
    @MainActor
    static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain && window.styleMask.contains(.titled)
    }

    /// The main window, resolved late if launch captured nil (login-item
    /// launch at sign-in — see applicationDidFinishLaunching). Adopts the
    /// first qualifying window it finds so delegate wiring and chrome are
    /// never skipped just because the window arrived after launch.
    @MainActor
    @discardableResult
    private func resolveMainWindow() -> NSWindow? {
        if let mainWindow { return mainWindow }
        // Prefer the window actually titled "Envy" — the About and What's New
        // scenes are also titled, main-capable windows, and NSApp.windows
        // order is arbitrary enough (state restoration, scene creation) that
        // "first candidate" could adopt one of them. The WindowGroup declares
        // its title explicitly (see EnvyApp), so the string is dependable even
        // when the title bar itself is hidden.
        let candidates = NSApp.windows.filter(Self.isMainWindowCandidate)
        guard let candidate = candidates.first(where: { $0.title == "Envy" }) ?? candidates.first else { return nil }
        adoptMainWindow(candidate)
        return candidate
    }

    /// One place for everything "this is now the main window" implies, so
    /// launch-time and late adoption can't drift apart.
    @MainActor
    private func adoptMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        Self.applyWindowChrome(to: window)
        updateStatusItemIcon()
    }

    @MainActor
    func toggleWindow() {
        guard let window = resolveMainWindow() else { return }
        // window.isVisible rather than NSApp.isActive && window.isKeyWindow —
        // this only needs to know whether the window itself is currently on
        // screen, independent of the app's broader activation state, which
        // matters now that hiding uses orderOut instead of NSApp.hide(nil)
        // (see hideIfAutoHideEnabled for why).
        if window.isVisible {
            hideMainWindow(window)
        } else {
            summonMainWindow()
        }
    }

    /// The one hide path — the summon hotkey's hide half and the red close
    /// button do the identical focus handoff, so they share it.
    private func hideMainWindow(_ window: NSWindow) {
        // Captured before orderOut: once the window is gone, AppKit may
        // already have flipped frontmost to its own arbitrary pick.
        let wasFrontmost = envyIsFrontmost
        window.orderOut(nil)
        restorePreviousAppFocus(envyWasFrontmost: wasFrontmost)
        updateStatusItemIcon()
    }

    /// The single path that brings the main window back — the summon hot key,
    /// the status item, and a Dock click all funnel through here so they
    /// can't drift apart.
    @MainActor
    func summonMainWindow() {
        guard let window = resolveMainWindow() else { return }
        captureFrontmostForRestore()
        NSApp.activate(ignoringOtherApps: true)
        // A window hidden by orderOut isn't miniaturized, but one the user
        // minimized to the Dock is, and makeKeyAndOrderFront alone won't
        // restore that — it would come back as a Dock tile that never opens.
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Belt and suspenders for macOS's cooperative activation: the
        // activate() above is a *request*, and when the grant lands after
        // makeKeyAndOrderFront the window ends up ordered front only within
        // Envy's own layer — visibly BEHIND the still-active app. That's a
        // race, so it bit intermittently. orderFrontRegardless puts the
        // window above other apps' windows independent of activation state,
        // and the deferred re-assert one turn later catches the case where
        // the first activation request was coalesced away entirely.
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.mainWindow === window, window.isVisible else { return }
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        NotificationCenter.default.post(name: .summonRequested, object: nil)
        performAeroSpaceHandoff(forWindowNumber: window.windowNumber)
        updateStatusItemIcon()
    }

    /// Hiding uses orderOut (see hideIfAutoHideEnabled), so a hidden Envy has
    /// no visible windows at all — which is exactly the state AppKit treats
    /// as "nothing to reopen." Left to its default, SwiftUI's WindowGroup
    /// answers a Dock click by building a *second* window, and since the
    /// summon hot key and auto-hide both act on a window, the two then fight
    /// over every summon. Returning false claims the click and reuses the
    /// window that already exists.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        summonMainWindow()
        return false
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

    /// Records the app that was frontmost the instant before Envy summons
    /// itself over the top of it, so a later hide can return focus there
    /// directly (restorePreviousAppFocus below). Must be called *before*
    /// NSApp.activate — once Envy activates, it's the frontmost app and the
    /// answer is lost. Skips capturing ourselves: summoning while an Envy
    /// window (Settings, About, an already-open main window) is frontmost
    /// should leave whatever we last captured intact, not overwrite it with
    /// Envy — restoring focus *to Envy* on hide would be a no-op at best and
    /// could re-raise a window we just dismissed.
    private func captureFrontmostForRestore() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        appToRestoreOnHide = frontmost
    }

    /// Hands focus back to whatever app was frontmost before the last summon,
    /// consuming the captured value. The real point of this is what it
    /// *prevents*: after Envy's only visible window is ordered out, AppKit
    /// otherwise auto-activates the "next" window in the global window-server
    /// order — and AeroSpace parks windows from other workspaces off-screen
    /// but still *in* that order, so that next pick routinely lands on a
    /// window belonging to a different workspace, which AeroSpace then
    /// reveals (an unrelated window snapping to the front — exactly the bug).
    /// Explicitly reactivating the previous app instead keeps focus on the
    /// current workspace. Deliberately *not* routed through AeroSpace's
    /// socket (unlike the 1.1.2 attempt this replaces): a plain app
    /// activation can't un-minimize a window the way `focus --window-id`
    /// does, and it also fixes the same jump for people running no window
    /// manager at all.
    ///
    /// Callers pass whether Envy actually held focus at hide time (captured
    /// *before* orderOut, since orderOut itself may have already flipped
    /// frontmost to AppKit's arbitrary pick). If the user had already
    /// switched to some other app before hiding, we leave their focus alone.
    private func restorePreviousAppFocus(envyWasFrontmost: Bool) {
        guard let previous = appToRestoreOnHide else { return }
        appToRestoreOnHide = nil
        guard envyWasFrontmost else { return }
        guard previous.processIdentifier != NSRunningApplication.current.processIdentifier,
              !previous.isTerminated else { return }
        _ = previous.activate()
    }

    /// True when Envy is the app that currently holds focus — checked right
    /// before ordering a window out, so the restore only fires when hiding
    /// Envy is actually what's giving up focus.
    private var envyIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier
    }

    // The red close button would otherwise let SwiftUI actually destroy the
    // WindowGroup's window — after that, NSApp.windows.first (used to
    // summon it back, both from the global hotkey and the menu bar item)
    // comes back nil or wrong, so clicking either appeared to do nothing.
    // Hiding instead of closing keeps the window alive so it can always be
    // brought back, the same "quit-resistant" behavior the summon hotkey
    // and menu bar item are meant to provide.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow(sender)
        return false
    }
}

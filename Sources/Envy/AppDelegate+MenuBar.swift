import SwiftUI
import AppKit
import EnvyCore

// The menu bar presence: the status item, its hand-drawn three-state eyecon
// (open/squint/closed, with the blink easter egg), and the right-click menu
// with its new-note/new-pinned-note actions. Split out of EnvyApp.swift
// purely for file size/navigability — same class, zero behavior change.

// Resolved against whatever NSAppearance the button is actually drawn
// in (the menu bar's, not necessarily the app's own light/dark
// setting) — the same adaptation isTemplate gives a plain monochrome
// image, needed here too since the pupil below keeps its color instead
// of being auto-tinted. Top-level in this file (not statics on the class)
// because extensions can't hold static stored properties.
private let menuBarOutlineColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
}

private let eyeLineWidth: CGFloat = 2.0
// Corner y is the true vertical center of the 18pt-tall canvas (9.0),
// not the earlier 9.5 — since openEyeImage's lens is built by
// mirroring the lower rim above this same line, that 0.5pt offset was
// enough to visibly throw the whole icon off-center against the other
// menu bar items (e.g. the battery icon). closedEyeImage shares these
// same constants, so it stays centered on the open eye automatically.
private let eyeCornerLeft = NSPoint(x: 2.5, y: 9.0)
private let eyeCornerRight = NSPoint(x: 15.5, y: 9.0)
private let lowerRimControlLeft = NSPoint(x: 6, y: 4.3)
private let lowerRimControlRight = NSPoint(x: 12, y: 4.3)
private let pupilRect = NSRect(x: 6.5, y: 6.3, width: 5, height: 5)
// Read from the mark rather than transcribed — see EnvyLogoView.
private let pupilColor = EnvyBrand.irisNSColor
// The dark centre, at the mark's own pupil-to-iris ratio (28/70). Two jobs:
// it matches the logo, and it stops the green disc reading as a flat blob at
// 18pt — the eye needs something to look *with*.
private let irisDotRect = pupilRect.insetBy(dx: pupilRect.width * 0.3, dy: pupilRect.height * 0.3)
private let irisDotColor = EnvyBrand.fieldNSColor

/// The three lid positions the status item can show.
private enum EyeState {
    /// Just the eyelid crease, traced along the exact same line and curvature
    /// as the open eye's lower rim — an eyelid closes down to meet the lower
    /// lid, not the vertical center of the glyph's bounding box. Reads as a
    /// shut eye rather than a "disabled" slashed one.
    case closed
    /// The upper rim mirrored above the same corner line the lower rim sits
    /// on, plus the iris and its dark centre.
    case open
    /// A drooping upper lid, much closer to the lower rim, for a sleepy
    /// squint while the pinned-note popup is open instead of the main window.
    /// The iris is the exact same circle as the open eye, just clipped to
    /// this shallower lens, so it reads as the same eye partway through
    /// closing rather than a differently-sized one.
    case squint
}

/// An arc above the eye in the mark's own red, shown when an update is
/// waiting. The brow is the most recognizable part of the app icon, so it
/// reads as this app having something to say — where a generic dot would
/// just be one more badge in a menu bar full of them.
///
/// Sits clear of the lens rather than touching it: red against the green
/// iris is a complementary pair, and they shimmer where they meet.
private func drawUpdateBrow() {
    // Proportioned from the app icon rather than judged by eye. Mapping the
    // icon's 512-unit space onto this 18pt canvas by eye width (13/432 =
    // 0.0301) gives a brow 10.35pt wide, an arc rise of 2.59, and a 1.75
    // stroke — matching the icon's 0.25 rise-to-width ratio exactly, so the
    // curve reads at the same angle.
    //
    // The one deliberate departure is vertical. In the icon the brow clears
    // the eye by 8 units, which is 0.24pt here — and this eye is a stroked
    // outline glyph rather than a filled shape, so its own 2pt rim would
    // swallow a brow set that close. It sits higher instead, keeping the
    // silhouette legible at menu bar size.
    let width: CGFloat = 10.35
    let rise: CGFloat = 2.59
    let centreX: CGFloat = 9.0
    let baseY: CGFloat = 13.9

    let leftX = centreX - width / 2
    let rightX = centreX + width / 2
    // NSBezierPath has no quadratic method, so the icon's single quadratic
    // control is raised to the equivalent cubic pair.
    let controlY = baseY + rise * 2 / 3

    let brow = NSBezierPath()
    brow.lineWidth = 1.75
    brow.lineCapStyle = .round
    brow.move(to: NSPoint(x: leftX, y: baseY))
    brow.curve(
        to: NSPoint(x: rightX, y: baseY),
        controlPoint1: NSPoint(x: leftX + (centreX - leftX) * 2 / 3, y: controlY),
        controlPoint2: NSPoint(x: rightX + (centreX - rightX) * 2 / 3, y: controlY)
    )
    EnvyBrand.markNSColor.setStroke()
    brow.stroke()
}

// One factory rather than three near-identical drawing closures — the brow
// variants would otherwise have doubled an already-duplicated block.
//
// The images are built once and cached, which loses nothing:
// NSImage(size:flipped:drawingHandler:) re-invokes its drawing block on every
// actual draw regardless of when the NSImage was built, so
// menuBarOutlineColor's light/dark-adaptive resolution still happens at real
// draw time.
private func makeEyeImage(_ state: EyeState, brow showsBrow: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = eyeLineWidth
        path.move(to: eyeCornerLeft)
        path.curve(to: eyeCornerRight, controlPoint1: lowerRimControlLeft, controlPoint2: lowerRimControlRight)

        switch state {
        case .closed:
            break
        case .open:
            let upperControlLeft = NSPoint(x: lowerRimControlLeft.x, y: 2 * eyeCornerLeft.y - lowerRimControlLeft.y)
            let upperControlRight = NSPoint(x: lowerRimControlRight.x, y: 2 * eyeCornerRight.y - lowerRimControlRight.y)
            path.curve(to: eyeCornerLeft, controlPoint1: upperControlRight, controlPoint2: upperControlLeft)
        case .squint:
            path.curve(
                to: eyeCornerLeft,
                controlPoint1: NSPoint(x: lowerRimControlRight.x, y: 9.6),
                controlPoint2: NSPoint(x: lowerRimControlLeft.x, y: 9.6)
            )
        }

        if state != .closed {
            // White "sclera" across the whole lens (the path closes back on
            // itself via the two curves above), so the iris doesn't float
            // directly on whatever is behind the menu bar.
            NSColor.white.setFill()
            path.fill()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            pupilColor.setFill()
            NSBezierPath(ovalIn: pupilRect).fill()
            irisDotColor.setFill()
            NSBezierPath(ovalIn: irisDotRect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        menuBarOutlineColor.setStroke()
        path.stroke()

        if showsBrow { drawUpdateBrow() }
        return true
    }
    image.isTemplate = false
    return image
}

/// Mirrors Updater.shared.updatePending for this file, whose icon selection
/// runs nonisolated and so can't read a main-actor singleton. Written only
/// from the main actor, via setMenuBarUpdatePending below.
nonisolated(unsafe) private var updateIsPending = false

/// Called by Updater when Sparkle finds or stops finding an update.
@MainActor
func setMenuBarUpdatePending(_ pending: Bool) {
    updateIsPending = pending
}

/// The only way any code should pick an eye image. Choosing between the
/// plain and brow variants at each call site is what let the indicator vanish
/// during a blink, a pinned-note reveal, and a pinned-note close — three of
/// six assignments simply didn't ask.
private func eyeImage(_ state: EyeState) -> NSImage {
    switch state {
    case .open:   return updateIsPending ? openEyeUpdateImage : openEyeImage
    case .squint: return updateIsPending ? squintEyeUpdateImage : squintEyeImage
    case .closed: return updateIsPending ? closedEyeUpdateImage : closedEyeImage
    }
}

private let closedEyeImage = makeEyeImage(.closed, brow: false)
private let openEyeImage = makeEyeImage(.open, brow: false)
private let squintEyeImage = makeEyeImage(.squint, brow: false)
private let closedEyeUpdateImage = makeEyeImage(.closed, brow: true)
private let openEyeUpdateImage = makeEyeImage(.open, brow: true)
private let squintEyeUpdateImage = makeEyeImage(.squint, brow: true)

extension AppDelegate {
    func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        // QA affordance: the update indicator is otherwise only visible when
        // a real release is waiting, which makes it impossible to look at
        // while designing it. Read once here, so unsetting the key and
        // relaunching clears it.
        //
        //   defaults write com.skylerschoos.envy.test debugForceUpdateBadge -bool YES
        //
        // Safe in production: nothing sets this key, and Sparkle overwrites
        // the flag on its next check either way.
        if UserDefaults.standard.bool(forKey: "debugForceUpdateBadge") {
            updateIsPending = true
        }
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
    func scheduleNextBlink() {
        blinkTimer?.invalidate()
        // Target/selector rather than the closure-based Timer API — the
        // closure form's @Sendable block signature fights Swift 6 strict
        // concurrency when it captures self to hop back onto the main
        // actor. A @MainActor @objc selector sidesteps that entirely, same
        // as statusItemClicked(_:) below.
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
        applyStatusIcon(.squint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.applyStatusIcon(.closed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.applyStatusIcon(.squint)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.updateStatusItemIcon()
                }
            }
        }
    }

    // All three states are hand-drawn (not eye.fill/eye.slash.fill) so the
    // open eye's pupil can carry the brand's green iris color, which no SF
    // Symbol rendering mode of eye.fill supports. All share the exact same
    // lower-rim curve, so the lid appears to close down onto the same line
    // it sits on when open, rather than the glyphs disagreeing about
    // where the bottom of the eye actually is. Called after every place
    // that changes mainWindow's visibility.
    func updateStatusItemIcon() {
        if mainWindow?.isVisible == true {
            applyStatusIcon(.open)
        } else if pinnedNotePanel?.isVisible == true {
            applyStatusIcon(.squint)
        } else {
            applyStatusIcon(.closed)
        }
    }

    /// Sets the image and the tooltip together. Every path that touches the
    /// status item goes through here, including the blink's intermediate
    /// frames — otherwise a frame drawn from a plain image drops the update
    /// indicator for as long as it's on screen.
    fileprivate func applyStatusIcon(_ state: EyeState) {
        statusItem?.button?.image = eyeImage(state)
        // The only affordance explaining the red arc — the icon can't caption
        // itself, and a coloured mark with no explanation is just noise.
        statusItem?.button?.toolTip = updateIsPending ? "Envy update available" : nil
    }

    /// The pinned-note panel's windowWillClose needs the icon settled
    /// without consulting the panel's own visibility (still stale-true at
    /// that moment) — see the caller in AppDelegate+PinnedNote. Lives here
    /// because the eye images are file-scoped to this file.
    func settleStatusIconAfterPinnedPanelClose() {
        applyStatusIcon(mainWindow?.isVisible == true ? .open : .closed)
    }

    /// Left-click opens the pinned note if one's actually pinned, or
    /// summons/hides the app otherwise — no user-facing choice between the
    /// two anymore, since "click summons the app even though I pinned a
    /// note specifically so one click would reach it" was never a
    /// combination anyone wanted. Right-click shows a small menu — the two
    /// need to be told apart manually since a status item's .button.action
    /// alone doesn't distinguish which mouse button was used.
    @MainActor
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else if let pinnedNoteURL {
            togglePinnedNotePanel(for: pinnedNoteURL)
        } else {
            toggleWindow()
        }
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

        let unpinNote = NSMenuItem(title: "Unpin Note", action: #selector(unpinNoteFromStatusMenu), keyEquivalent: "")
        unpinNote.target = self
        unpinNote.isEnabled = pinnedNoteURL != nil
        menu.addItem(unpinNote)

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

    @MainActor
    @objc private func unpinNoteFromStatusMenu() {
        unpinMenuBarNote()
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
        NoteStore(directory: IndexPreference.load())
    }

    @MainActor
    @objc private func newPinnedNoteFromStatusMenu() {
        let note = makeScratchNoteStore().create(title: "Untitled")
        pinToMenuBarAndShow(note)
    }

    @MainActor
    private func templateSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let templates = makeScratchNoteStore().templates()
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
    /// menu) and shows it immediately, so there's no extra click between
    /// "make a pinned note" and "start typing in it."
    @MainActor
    private func pinToMenuBarAndShow(_ note: Note) {
        UserDefaults.standard.set(note.id, forKey: "menuBarPinnedNotePath")
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
}

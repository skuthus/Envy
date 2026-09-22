import AppKit
import ApplicationServices
import CoreServices

// Accessibility, input, and file-watching primitives for driving EnvyTest.
// Everything here acts on EnvyTest only: typing refuses to run unless
// EnvyTest is the frontmost app, and no event ever carries a modifier flag
// (a flagged event left ⌘ logically held system-wide once; Shift is pressed
// and released as a real key instead, and releaseModifiers() runs on exit).

let testBundleID = "com.skylerschoos.envy.test"
/// The build under test — launched by path, never by bundle ID: stale copies
/// of EnvyTest elsewhere on disk share the ID, and Launch Services will
/// happily start one of those instead.
let testAppPath = "/Applications/EnvyTest.app"

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func walk(_ e: AXUIElement, depth: Int = 0, max: Int = 60, _ visit: (AXUIElement, Int) -> Bool) {
    guard depth <= max, visit(e, depth) else { return }
    for c in children(e) { walk(c, depth: depth + 1, max: max, visit) }
}
func describe(_ e: AXUIElement) -> String {
    var parts = [str(e, kAXRoleAttribute) ?? "?"]
    if let d = str(e, kAXDescriptionAttribute), !d.isEmpty { parts.append("desc=\(d)") }
    if let v = attr(e, kAXValueAttribute) { parts.append("value=\(String(describing: v).prefix(40))") }
    return parts.joined(separator: " ")
}
func now() -> Double { Date().timeIntervalSince1970 }
func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

/// Polls until `condition` holds or `timeout` passes; returns whether it held.
@discardableResult
func waitFor(_ timeout: Double, every: Double = 0.02, _ condition: () -> Bool) -> Bool {
    let t0 = now()
    while now() - t0 < timeout {
        if condition() { return true }
        pause(every)
    }
    return condition()
}

/// A task row's checkbox and the words beside it.
struct Box {
    let el: AXUIElement
    let checked: Bool
    let frame: CGRect
    let text: String
}

/// Checkbox buttons ("Mark done"/"Mark not done") in a window, top to
/// bottom, each paired with the text on its line (a button, or the field
/// while that row is being edited).
func boxes(in w: AXUIElement) -> [Box] {
    var found: [(AXUIElement, Bool, CGRect)] = []
    var texts: [(CGRect, String)] = []
    walk(w) { e, _ in
        let role = str(e, kAXRoleAttribute)
        if role == "AXButton", let d = str(e, kAXDescriptionAttribute), d == "Mark done" || d == "Mark not done", let f = frame(e) {
            found.append((e, d == "Mark not done", f))
        }
        if role == "AXStaticText" || role == "AXButton" || role == "AXTextField", let f = frame(e) {
            let t = (attr(e, kAXValueAttribute) as? String) ?? str(e, kAXDescriptionAttribute) ?? ""
            if !t.isEmpty, t != "Mark done", t != "Mark not done" { texts.append((f, t)) }
        }
        return true
    }
    return found.map { e, c, f in
        let t = texts.filter { abs($0.0.midY - f.midY) < 6 && $0.0.minX > f.maxX }.min { $0.0.minX < $1.0.minX }?.1 ?? ""
        return Box(el: e, checked: c, frame: f, text: t)
    }.sorted { $0.frame.minY < $1.frame.minY }
}

/// The first button whose description is `d`.
func button(_ w: AXUIElement, _ d: String) -> AXUIElement? {
    var r: AXUIElement?
    walk(w) { e, _ in
        if r == nil, str(e, kAXRoleAttribute) == "AXButton", str(e, kAXDescriptionAttribute) == d { r = e }
        return r == nil
    }
    return r
}

// MARK: Input

enum Input {
    static let source = CGEventSource(stateID: .hidSystemState)

    static func mouse(_ type: CGEventType, _ p: CGPoint) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.flags = []
        e?.post(tap: .cghidEventTap)
    }

    static func click(_ p: CGPoint) {
        mouse(.mouseMoved, p); pause(0.015)
        mouse(.leftMouseDown, p); pause(0.02)
        mouse(.leftMouseUp, p)
    }

    /// A press-and-drag from one point to another, in steps, with a hover at
    /// the end so a drop target can register.
    static func drag(from a: CGPoint, to b: CGPoint) {
        mouse(.mouseMoved, a); pause(0.08)
        mouse(.leftMouseDown, a); pause(0.15)
        for i in 1...24 {
            let t = CGFloat(i) / 24
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); pause(0.025)
        }
        for _ in 0..<6 { mouse(.leftMouseDragged, b); pause(0.04) }
        mouse(.leftMouseUp, b); pause(0.5)
    }

    static func key(_ code: CGKeyCode) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
            pause(0.03)
        }
        pause(0.03)
    }

    static let returnKey: CGKeyCode = 0x24, tab: CGKeyCode = 0x30, backspace: CGKeyCode = 0x33
    static let right: CGKeyCode = 0x7C, down: CGKeyCode = 0x7D

    /// Shift-Tab with a real Shift press and release around it.
    static func shiftTab() {
        func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            pause(0.03)
        }
        post(0x38, true, .maskShift); post(0x30, true, .maskShift); post(0x30, false, .maskShift); post(0x38, false, [])
        pause(0.03)
    }

    static func type(_ s: String, interval: Double = 0.035) {
        for unit in s.utf16 {
            var c = unit
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e?.post(tap: .cghidEventTap)
            }
            pause(interval)
        }
    }

    static var modifiersClear: Bool {
        CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
    }

    /// Press and release every modifier, then post a clean flags-changed —
    /// clears any logically held modifier however it got stuck.
    static func releaseModifiers() {
        for code: CGKeyCode in [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E] {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                e?.flags = []
                e?.post(tap: .cghidEventTap)
            }
        }
        if let e = CGEvent(source: source) { e.type = .flagsChanged; e.flags = []; e.post(tap: .cghidEventTap) }
    }
}

// MARK: File events

/// Records when files under a folder change, so a test can time
/// click → file written without polling the disk.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var events: [(time: Double, path: String)] = []

    init(_ folder: String) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, n, paths, _, _ in
            let me = Unmanaged<FileWatcher>.fromOpaque(info!).takeUnretainedValue()
            let ps = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.lock.lock(); defer { me.lock.unlock() }
            for i in 0..<min(n, ps.count) where !ps[i].contains(".sb-") { me.events.append((now(), ps[i])) }
        }, &context, [folder] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.0,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        FSEventStreamSetDispatchQueue(stream!, DispatchQueue(label: "preflight.fsevents"))
        FSEventStreamStart(stream!)
    }

    /// The first .md change at or after `t0`, if one arrives within `timeout`.
    func firstChange(after t0: Double, timeout: Double) -> (time: Double, path: String)? {
        var hit: (Double, String)?
        waitFor(timeout, every: 0.002) {
            lock.lock(); defer { lock.unlock() }
            hit = events.first { $0.time >= t0 && $0.path.hasSuffix(".md") }
            return hit != nil
        }
        return hit
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

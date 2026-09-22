import AppKit
import ApplicationServices

// The test runner, EnvyTest control, and the throwaway vault's fixtures.

struct Failure: Error { let message: String }

/// Fails the current test with `message` unless `condition` holds.
func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failure(message: message()) }
}

final class Runner {
    struct Result { let group: String; let name: String; let passed: Bool; let detail: String; let seconds: Double }
    private(set) var results: [Result] = []
    private var group = ""
    private let reportPath: String
    private var watchdog: DispatchWorkItem?

    init(reportPath: String) { self.reportPath = reportPath }

    func section(_ name: String) {
        group = name
        print("\n== \(name)")
    }

    /// Runs one test. `body` returns a short detail line, or throws Failure.
    /// A test that runs past `timeout` ends the whole run (a hang means the
    /// app or an accessibility call stopped answering): the report is
    /// written, modifiers released, and the process exits non-zero.
    func test(_ name: String, timeout: Double = 120, _ body: () throws -> String) {
        // PREFLIGHT_ONLY="a|b" runs just the tests whose names contain a or b
        // (launch always runs) — for iterating on the suite, never for a release.
        if let only = ProcessInfo.processInfo.environment["PREFLIGHT_ONLY"], !only.isEmpty,
           !only.lowercased().split(separator: "|").contains(where: { name.lowercased().contains($0) }),
           !name.hasPrefix("Cold launch") { return }
        let started = now()
        let item = DispatchWorkItem { [self] in
            record(Result(group: group, name: name, passed: false, detail: "TIMED OUT after \(Int(timeout))s", seconds: timeout))
            print("   FAIL  \(name) — timed out after \(Int(timeout))s; stopping the run")
            Input.releaseModifiers()
            writeReport()
            exit(3)
        }
        watchdog = item
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        var passed = true, detail = ""
        do { detail = try body() } catch let f as Failure { passed = false; detail = f.message } catch { passed = false; detail = "\(error)" }
        item.cancel()
        if !Input.modifiersClear {
            Input.releaseModifiers()
            passed = false
            detail += " (a modifier key was left held; released)"
        }
        record(Result(group: group, name: name, passed: passed, detail: detail, seconds: now() - started))
        print("   \(passed ? "ok  " : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private let recordLock = NSLock()
    private func record(_ r: Result) {
        recordLock.lock(); results.append(r); recordLock.unlock()
    }

    var failures: [Result] { results.filter { !$0.passed } }

    func writeReport() {
        recordLock.lock(); defer { recordLock.unlock() }
        var lines = ["# EnvyTest preflight — \(Date())", ""]
        var current = ""
        for r in results {
            if r.group != current { current = r.group; lines.append("## \(current)") }
            lines.append("- \(r.passed ? "PASS" : "FAIL") \(r.name)\(r.detail.isEmpty ? "" : " — \(r.detail)") (\(String(format: "%.1f", r.seconds))s)")
        }
        lines.append("")
        lines.append("\(results.count - failures.count)/\(results.count) passed")
        try? lines.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
    }
}

// MARK: EnvyTest

final class App {
    let el: AXUIElement
    let pid: pid_t

    private init(pid: pid_t) {
        self.pid = pid
        el = AXUIElementCreateApplication(pid)
    }

    /// Quits any running EnvyTest and launches a fresh one, waiting until its
    /// window and search field answer. Returns the app and the launch time.
    static func launch() throws -> (App, Double) {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID) { running.forceTerminate() }
        waitFor(5) { NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID).isEmpty }
        pause(0.5)
        let t0 = now()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", testAppPath]
        try open.run(); open.waitUntilExit()
        var app: App?
        var reopened = false
        let ready = waitFor(40, every: 0.05) {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID).first else { return false }
            if app == nil { app = App(pid: running.processIdentifier) }
            guard let app else { return false }
            // What's New (a new build, or a window restored from an earlier
            // run) can come up in place of the main window: dismiss it the way
            // a person would, then reopen the app as a Dock click does.
            if let whatsNew = (attr(app.el, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { str($0, kAXIdentifierAttribute) == "whatsnew" }),
               let cont = button(whatsNew, "Continue") {
                AXUIElementPerformAction(cont, kAXPressAction as CFString)
                pause(0.8)
            }
            if app.mainWindow() == nil, !reopened, now() - t0 > 6 {
                reopened = true
                let again = Process(); again.executableURL = URL(fileURLWithPath: "/usr/bin/open"); again.arguments = [testAppPath]
                try? again.run(); again.waitUntilExit()
            }
            guard let window = app.mainWindow(), let field = app.searchField(in: window) else { return false }
            return frame(field) != nil
        }
        guard ready, let app else { throw Failure(message: "EnvyTest didn't come up within 40s") }
        let running = NSRunningApplication(processIdentifier: app.pid)?.bundleURL?.resolvingSymlinksInPath().path
        guard running == URL(fileURLWithPath: testAppPath).resolvingSymlinksInPath().path else {
            throw Failure(message: "the running EnvyTest is \(running ?? "unknown"), not the build under test at \(testAppPath)")
        }
        let launched = now() - t0
        pause(2.5)   // the vault finishes loading in the background
        return (app, launched)
    }

    var isRunning: Bool { NSRunningApplication(processIdentifier: pid)?.isTerminated == false }

    func mainWindow() -> AXUIElement? {
        (attr(el, kAXWindowsAttribute) as? [AXUIElement])?.first { (str($0, kAXIdentifierAttribute) ?? "").contains("AppWindow") }
    }

    func panel() -> AXUIElement? {
        (attr(el, kAXWindowsAttribute) as? [AXUIElement])?.first { !(str($0, kAXIdentifierAttribute) ?? "").contains("AppWindow") }
    }

    func searchField(in w: AXUIElement? = nil) -> AXUIElement? {
        guard let w = w ?? mainWindow() else { return nil }
        var r: AXUIElement?
        walk(w, max: 10) { e, _ in
            if r == nil, str(e, kAXRoleAttribute) == "AXTextField" { r = e }
            return r == nil
        }
        return r
    }

    var query: String { searchField().flatMap { attr($0, kAXValueAttribute) as? String } ?? "" }

    /// Brings EnvyTest forward, clicking its window if activation alone
    /// doesn't take. Every typing step checks this first.
    func front() throws {
        NSRunningApplication(processIdentifier: pid)?.activate()
        if !waitFor(1.5, { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }),
           let w = mainWindow(), let f = frame(w) {
            Input.click(CGPoint(x: f.midX, y: f.minY + 12))
        }
        try expect(waitFor(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
                   "EnvyTest isn't the frontmost app — refusing to type into another app")
    }

    /// Sets the query programmatically (setup, not a typing test) and waits
    /// for the page to settle.
    ///
    /// The field is focused first: with the keyboard in a task row or the
    /// editor, a value set on an unfocused field doesn't reach the query.
    func setQuery(_ q: String, settle: Double = 1.5) {
        if let f = searchField() {
            AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            pause(0.15)
            AXUIElementSetAttributeValue(searchField() ?? f, kAXValueAttribute as CFString, q as CFString)
        }
        pause(settle)
    }

    /// Types `q` into the search field for real, starting from empty.
    func typeQuery(_ q: String, interval: Double = 0.035) throws {
        setQuery("", settle: 1.0)
        try front()
        guard let f = searchField(), let fr = frame(f) else { throw Failure(message: "no search field") }
        Input.click(CGPoint(x: fr.maxX - 20, y: fr.midY)); pause(0.4)
        Input.type(q, interval: interval)
    }

    func editor() -> AXUIElement? {
        guard let w = mainWindow() else { return nil }
        var r: AXUIElement?
        walk(w, max: 8) { e, _ in
            if r == nil, str(e, kAXRoleAttribute) == "AXTextArea" { r = e }
            return r == nil
        }
        return r
    }

    var editorText: String { editor().flatMap { attr($0, kAXValueAttribute) as? String } ?? "" }

    func clickStatusItem() {
        guard let bar = attr(el, "AXExtrasMenuBar"), let item = children(bar as! AXUIElement).first, let f = frame(item) else { return }
        Input.click(CGPoint(x: f.midX, y: f.midY))
    }

    /// Presses a menu-bar command (Menu ▸ Item) through accessibility — no
    /// keyboard shortcut, so no modifier keys.
    func pressMenu(_ menu: String, _ item: String) -> Bool {
        guard let bar = attr(el, kAXMenuBarAttribute) else { return false }
        for top in children(bar as! AXUIElement) where str(top, kAXTitleAttribute) == menu {
            for sub in children(top) {
                for entry in children(sub) where str(entry, kAXTitleAttribute) == item {
                    return AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// Opens the pinned pop-out from the menu-bar eye.
    func openPanel() throws -> AXUIElement {
        if let p = panel() { return p }
        clickStatusItem()
        guard waitFor(4, { self.panel() != nil }), let p = panel() else { throw Failure(message: "the pinned pop-out didn't open") }
        pause(1.0)
        return p
    }

    func closePanel() {
        if panel() != nil { clickStatusItem(); waitFor(3) { self.panel() == nil } }
    }

    var residentMB: Int {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    }

    var cpuPercent: Double {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "%cpu=", "-p", "\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

/// `sample`s a process for `seconds` while `during` runs, returning the
/// profile text (empty if sampling failed).
func profile(pid: pid_t, seconds: Int, path: String, during: () throws -> Void) rethrows -> String {
    try? FileManager.default.removeItem(atPath: path)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    p.arguments = ["\(pid)", "\(seconds)", "1", "-mayDie", "-file", path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
    pause(0.3)
    try during()
    p.waitUntilExit()
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// The main thread's share of samples that weren't idle, from a `sample` profile.
func mainThreadBusyShare(_ profile: String) -> Double? {
    let lines = profile.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.range(of: #"^    \d+ Thread_"#, options: .regularExpression) != nil }) else { return nil }
    let end = lines[(start + 1)...].firstIndex { $0.range(of: #"^    \d+ Thread_"#, options: .regularExpression) != nil } ?? lines.count
    guard let total = Int(lines[start].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") , total > 0 else { return nil }
    var idle = 0
    for line in lines[start..<end] {
        if let m = line.range(of: #"(\d+) mach_msg2_trap"#, options: .regularExpression) {
            idle += Int(line[m].split(separator: " ").first ?? "") ?? 0
        }
    }
    return Double(total - idle) / Double(total)
}

// MARK: Vault fixtures

/// The throwaway vault the run works in (a clone; never the real one).
final class Vault {
    let root: String
    init(_ root: String) { self.root = root }

    func path(_ rel: String) -> String { root + "/" + rel }

    func write(_ rel: String, _ content: String, ageHours: Double? = nil) {
        let p = path(rel)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? content.write(toFile: p, atomically: true, encoding: .utf8)
        if let ageHours {
            let when = Date(timeIntervalSinceNow: -ageHours * 3600)
            try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: p)
        }
    }

    func read(_ rel: String) -> String { (try? String(contentsOfFile: path(rel), encoding: .utf8)) ?? "" }

    func taskLines(_ rel: String) -> [String] { read(rel).components(separatedBy: "\n").filter { $0.contains("[ ]") || $0.contains("[x]") } }

    func remove(_ rel: String) { try? FileManager.default.removeItem(atPath: path(rel)) }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }

    /// Relative paths of notes whose file name is `title`.md, anywhere.
    func find(title: String) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
        return e.compactMap { $0 as? String }.filter { ($0 as NSString).lastPathComponent == title + ".md" }
    }

    /// The most used #tag and a subfolder with notes — real vocabulary for
    /// the autofill checks.
    func vocabulary() -> (tag: String?, folder: String?) {
        var counts: [String: Int] = [:]
        var folders: [String: Int] = [:]
        let tagPattern = try! NSRegularExpression(pattern: #"(?:^|\s)#([A-Za-z][A-Za-z0-9_-]{3,})"#)
        if let e = FileManager.default.enumerator(atPath: root) {
            var scanned = 0
            for case let rel as String in e where rel.hasSuffix(".md") && !rel.hasPrefix("pfz") && !rel.hasPrefix("Trash/") {
                let parts = rel.split(separator: "/")
                if parts.count == 2 { folders[String(parts[0]), default: 0] += 1 }
                guard scanned < 1500 else { continue }
                scanned += 1
                let text = read(rel)
                for m in tagPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    counts[(text as NSString).substring(with: m.range(at: 1)).lowercased(), default: 0] += 1
                }
            }
        }
        let folder = folders.filter { $0.value >= 2 && !$0.key.hasPrefix(".") && $0.key.count >= 4 && !$0.key.contains(" ") }
            .max { $0.value < $1.value }?.key
        return (counts.max { $0.value < $1.value }?.key, folder)
    }
}

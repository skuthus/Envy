import AppKit
import ApplicationServices

// The preflight test catalog. Every test drives the real EnvyTest.app with
// real clicks and keystrokes and checks the result where it matters — in the
// note files on disk, not just on screen.

/// Performance budgets. Set from measurements on the 4,900-note test vault
/// (Sept 2026) with headroom; a regression past these fails the run.
enum Budget {
    static let launch = 15.0                // s, cold launch to a usable window
    static let openTasksMedian = 0.40       // s, tasks: entered in the focused search box until rows show (measured ~0.15)
    static let openTasksCold = 1.5          // s, the first time (measured ~0.15–0.45)
    static let checkToFileMedian = 0.12     // s, click → note written (measured ~0.045, ~35ms of it is the synthetic click)
    static let checkToFileP90 = 0.25
    static let mainThreadFreeMedian = 0.25  // s, click → UI thread answering again (measured ~0.085)
    static let noteSwitchMedian = 0.25      // s, click a note → editor shows it (measured ~0.1)
    static let typingMainThreadBusy = 0.70  // share of the main thread while typing in the editor (measured ~0.37)
    static let idleCPU = 2.0                // %, a still app (measured ~0.1)
    static let memoryMB = 600               // RSS after the whole run (measured ~150-210)
}

var app: App!
var vault: Vault!
var runner: Runner!
var scratch = NSTemporaryDirectory()

func median(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.sorted()[xs.count / 2] }
func p90(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.sorted()[min(xs.count - 1, Int(Double(xs.count) * 0.9))] }
func ms(_ s: Double) -> String { String(format: "%.0fms", s * 1000) }

/// Sets the pin in EnvyTest's defaults and relaunches it (the pin is read
/// at launch) — skipped when that pin is already live, so each pop-out test
/// can state its own pin without paying for a relaunch every time.
var currentPin: String?
func relaunch(pin: String? = nil) throws {
    if let pin, pin == currentPin, app?.isRunning == true { app.closePanel(); return }
    if let pin { setDefault("menuBarTaskPin", pin) }
    (app, _) = try App.launch()
    currentPin = pin
}

func setDefault(_ key: String, _ value: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["write", testBundleID, key, value]
    try? p.run(); p.waitUntilExit()
}

/// The surface a test works in: the main window or the pinned pop-out.
func surface(_ panel: Bool) throws -> AXUIElement {
    if panel { return try app.openPanel() }
    guard let w = app.mainWindow() else { throw Failure(message: "no main window") }
    return w
}

/// Makes sure typing will land in EnvyTest. The pop-out can't be activated
/// into (it would close), so there it only checks EnvyTest is frontmost.
func readyToType(_ panel: Bool) throws {
    if panel {
        try expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid, "EnvyTest isn't frontmost — refusing to type")
    } else {
        try app.front()
    }
}

func clickText(_ w: AXUIElement, _ text: String, caretToEnd: Bool = true) throws {
    guard let b = button(w, text), let f = frame(b) else { throw Failure(message: "row '\(text)' isn't on screen") }
    Input.click(CGPoint(x: f.minX + 60, y: f.midY)); pause(0.4)
    if caretToEnd { Input.key(Input.down) }
}

// MARK: Fixtures

enum Fixture {
    static let checks = "pfz/check/PFZ Checks.md"
    static let enter = "pfz/enter/PFZ Enter.md"
    static let tab = "pfz/tab/PFZ Tab.md"
    static let back = "pfz/back/PFZ Back.md"
    static let move = "pfz/move/PFZ Move.md"
    static let moveOther = "pfz/move/PFZ Move Other.md"
    static let dup = "pfz/dup/PFZ Dup.md"
    static let small = "pfz/small/PFZ Small.md"
    static let winX = "pfz/winx/PFZ WinX.md"
    static let winY = "pfz/winy/PFZ WinY.md"
    static let rev = "pfz/rev/PFZ Rev.md"
    static let rev2 = "pfz/rev/PFZ Rev2.md"
    static let autofill = "pfz/autofill/PFZ Autofill Target Note.md"

    static func checksContent() -> String {
        "# PFZ Checks\n\n" + (1...10).map { String(format: "- [ ] pfzq task %02d\n", $0) }.joined()
            + "- [ ] pfzq task dup\n- [ ] pfzq task dup\n    - [ ] pfzq task child\n"
    }
    static let enterContent = "# PFZ Enter\n\n- [ ] en A\n    - [ ] en A1\n- [ ] \n- [ ] en B\n"
    static let tabContent = "# PFZ Tab\n\n- [ ] tb A\n- [ ] tb B\n"
    static let backContent = "# PFZ Back\n\n- [ ] \n- [ ] bk A\n    - [ ] bk A1\n    - [ ] \n- [ ] bk D\n"
    static let moveContent = "# PFZ Move\n\n- [ ] mv A\n    - [ ] mv A1\n    - [ ] mv A2\n- [ ] mv B\n- [ ] mv C\n    - [ ] mv C1\n- [ ] mv D\n"

    /// Everything the run needs, written fresh.
    static func writeAll() {
        vault.write(checks, checksContent())
        vault.write(enter, enterContent)
        vault.write(tab, tabContent)
        vault.write(back, backContent)
        vault.write(move, moveContent)
        vault.write(moveOther, "# PFZ Move Other\n\n- [ ] mv other\n")
        vault.write(dup, "# PFZ Dup\n\n- [ ] milk\n- [ ] egg\n")
        vault.write(small, "# PFZ Small\n\n- [ ] small one\n")
        vault.write(winX, "# PFZ WinX\n\n- [ ] x keep\n- [ ] \n")
        vault.write(winY, "# PFZ WinY\n\n- [ ] y one\n- [ ] y two\n- [ ] \n")
        vault.write(rev, "# PFZ Rev\n\n" + (1...24).map { "Filler paragraph \($0) for spacing.\n\n" }.joined() + "- [ ] rev target\n")
        vault.write(rev2, "# PFZ Rev2\n\nrev other note\n")
        vault.write(autofill, "# PFZ Autofill Target Note\n\n- [ ] af one\n- [ ] af two\n- [ ] af three\n")
        for (i, age) in [1.0, 5, 24, 72].enumerated() {
            vault.write("pfz/order/PFZ Order \(i + 1).md",
                        "# PFZ Order \(i + 1)\n\n" + (1...3).map { "- [ ] pfzord \(i + 1).\($0)\n" }.joined(), ageHours: age)
        }
    }
}

// MARK: Core note flows

func coreTests(_ vocab: (tag: String?, folder: String?)) {
    let id = String(Int(now()) % 100000)
    let created = "PF Created \(id)"

    runner.test("Create a note from the search box") {
        try app.typeQuery(created)
        Input.key(Input.returnKey)
        try expect(waitFor(5) { !vault.find(title: created).isEmpty }, "no file named '\(created).md' appeared")
        return "wrote \(vault.find(title: created).first ?? "")"
    }

    runner.test("Type into the new note — saves to disk") {
        try app.front()
        guard let ed = app.editor(), let f = frame(ed) else { throw Failure(message: "no editor") }
        Input.click(CGPoint(x: f.minX + 60, y: f.maxY - 20)); pause(0.3)
        Input.click(CGPoint(x: f.minX + 60, y: f.maxY - 20)); pause(0.3)
        try readyToType(false)
        Input.type(" preflight body words")
        let rel = vault.find(title: created).first ?? ""
        try expect(waitFor(4) { vault.read(rel).contains("preflight body words") }, "the typed words never reached the file")
        return "saved as typed"
    }

    /// New notes may start in Inbox/, which the main list hides unless the
    /// query asks for the inbox — search it the way a person would.
    func searchQuery() -> String {
        vault.find(title: created).first?.hasPrefix("Inbox/") == true ? "inbox: \(created)" : created
    }
    /// The created note's row in the note list (not the editor's title).
    func listRow() -> CGRect? {
        guard let w = app.mainWindow() else { return nil }
        var list: AXUIElement?
        walk(w, max: 8) { e, _ in if list == nil, str(e, kAXRoleAttribute) == "AXOpaqueProviderGroup" { list = e }; return list == nil }
        guard let list else { return nil }
        return children(list).first { str($0, kAXRoleAttribute) == "AXStaticText" && (attr($0, kAXValueAttribute) as? String) == created }.flatMap(frame)
    }

    runner.test("Search finds it") {
        app.setQuery(searchQuery())
        try expect(waitFor(4) { listRow() != nil }, "'\(created)' isn't in the note list for '\(searchQuery())'")
        return "listed for '\(searchQuery())'"
    }

    runner.test("Delete Note moves it to the Trash") {
        app.setQuery(searchQuery())
        guard waitFor(4, { listRow() != nil }), let row = listRow() else { throw Failure(message: "note not in the list") }
        try app.front()
        Input.click(CGPoint(x: row.minX + 10, y: row.midY))
        // Only delete once the editor shows this very note — never whatever
        // else happens to be selected.
        try expect(waitFor(3) { app.editorText.contains("preflight body words") }, "couldn't select the test note — not deleting anything")
        try expect(app.pressMenu("File", "Delete Note"), "couldn't press File ▸ Delete Note")
        try expect(waitFor(5) { vault.find(title: created).contains { $0.hasPrefix("Trash/") } },
                   "not in Trash/ — found \(vault.find(title: created))")
        return ""
    }

    runner.test("A change from another app right after a save loads") {
        app.setQuery("PFZ Checks")
        try app.front()
        guard let ed = app.editor(), let f = frame(ed) else { throw Failure(message: "no editor") }
        Input.click(CGPoint(x: f.minX + 60, y: f.maxY - 20)); pause(0.3)
        try readyToType(false)
        Input.type("z"); pause(0.55)          // Envy's save lands ~0.4s after the key
        let outside = "PF Outside \(id)"
        vault.write("\(outside).md", "# \(outside)\n\nwritten by another app\n")
        let seen = waitFor(8) {
            app.setQuery(outside, settle: 0.6)
            return app.editorText.hasPrefix("# \(outside)")
        }
        vault.write(Fixture.checks, Fixture.checksContent())
        try expect(seen, "a note written 0.15s after a save never showed up")
        return ""
    }

    runner.test("Switching notes is fast") {
        app.setQuery("")
        guard let w = app.mainWindow() else { throw Failure(message: "no window") }
        var list: AXUIElement?
        walk(w, max: 8) { e, _ in if list == nil, str(e, kAXRoleAttribute) == "AXOpaqueProviderGroup" { list = e }; return list == nil }
        guard let list, let lf = frame(list), let area = frame(children(list).isEmpty ? list : list) else { throw Failure(message: "no note list") }
        var scrollBottom = area.maxY
        walk(w, max: 7) { e, _ in if str(e, kAXRoleAttribute) == "AXScrollArea", let f = frame(e), f.contains(CGPoint(x: lf.midX, y: lf.minY + 2)) { scrollBottom = f.maxY }; return true }
        let titles = children(list).compactMap { e -> CGRect? in
            guard str(e, kAXRoleAttribute) == "AXStaticText", let f = frame(e), f.minX < lf.minX + 20, f.maxY < scrollBottom - 4 else { return nil }
            return f
        }
        try expect(titles.count >= 4, "fewer than 4 notes visible in the list")
        var times: [Double] = []
        for f in titles.prefix(10).dropFirst() {
            let before = String(app.editorText.prefix(200))
            let t0 = now()
            Input.click(CGPoint(x: f.minX + 20, y: f.midY))
            if waitFor(3, every: 0.002, { String(app.editorText.prefix(200)) != before }) { times.append(now() - t0) }
            pause(0.4)
        }
        try expect(times.count >= 3, "clicking notes in the list didn't switch the editor")
        try expect(median(times) < Budget.noteSwitchMedian, "median \(ms(median(times))) over the \(ms(Budget.noteSwitchMedian)) budget")
        return "median \(ms(median(times))) over \(times.count) switches"
    }

    if let tag = vocab.tag {
        runner.test("Autofill: tag:") {
            let typed = "tag:" + tag.prefix(3)
            try app.typeQuery(typed); pause(0.9)
            try expect(ghost(typed)?.lowercased() == "tag:\(tag)", "autofill showed \(ghost(typed) ?? "nothing"), wanted tag:\(tag)")
            Input.key(Input.right); pause(0.5)
            try expect(app.query.lowercased() == "tag:\(tag)", "→ left the query as '\(app.query)'")
            return "tag:\(tag)"
        }
    }
    if let folder = vocab.folder {
        runner.test("Autofill: folder:") {
            let typed = "folder:" + folder.prefix(3)
            try app.typeQuery(typed); pause(0.9)
            let g = ghost(typed)
            try expect(g != nil, "no autofill for \(typed)")
            Input.key(Input.right); pause(0.5)
            try expect(app.query.count > typed.count, "→ didn't accept it")
            return app.query
        }
    }
}

/// The ghost-text completion showing in the search row for `typed`, if any.
func ghost(_ typed: String) -> String? {
    guard let w = app.mainWindow() else { return nil }
    var g: String?
    walk(w, max: 14) { e, _ in
        if str(e, kAXRoleAttribute) == "AXStaticText", let v = attr(e, kAXValueAttribute) as? String, let f = frame(e), f.minY < 130,
           v.count > typed.count, v.lowercased().hasPrefix(typed.lowercased()) { g = v }
        return true
    }
    return g
}

// MARK: The tasks: page

func taskStates(_ rel: String, token: String) -> [Bool] {
    vault.read(rel).components(separatedBy: "\n").filter { $0.contains(token) }.map { $0.contains("[x]") || $0.contains("[X]") }
}
func uiStates(_ w: AXUIElement, token: String) -> [Bool] { boxes(in: w).filter { $0.text.contains(token) }.map(\.checked) }
func pattern(_ s: [Bool]) -> String { s.map { $0 ? "x" : "_" }.joined() }

/// Every click must land in the file and on screen.
func checkboxSteady(_ panel: Bool) throws -> String {
    vault.write(Fixture.checks, Fixture.checksContent()); pause(1.2)
    let w = try surface(panel)
    try readyToType(panel)
    try expect(waitFor(6) { uiStates(w, token: "pfzq").count == 13 }, "the 13 test rows aren't on screen")
    var expected = taskStates(Fixture.checks, token: "pfzq")
    var latencies: [Double] = []
    let order = [0, 0, 1, 2, 1, 2, 3, 3, 4, 5, 6, 7, 8, 9, 9, 8, 12, 12, 0, 0, 0, 0, 10, 11, 11, 10, 11, 10, 10, 11]
    for (n, i) in order.enumerated() {
        let rows = boxes(in: w).filter { $0.text.contains("pfzq") }
        try expect(i < rows.count, "row \(i) vanished")
        expected[i].toggle()
        let t0 = now()
        Input.click(CGPoint(x: rows[i].frame.midX, y: rows[i].frame.midY))
        let ok = waitFor(3) { taskStates(Fixture.checks, token: "pfzq") == expected && uiStates(w, token: "pfzq") == expected }
        try expect(ok, "click \(n + 1) on row \(i): want \(pattern(expected)), file \(pattern(taskStates(Fixture.checks, token: "pfzq"))), screen \(pattern(uiStates(w, token: "pfzq")))")
        latencies.append(now() - t0)
    }
    return "\(order.count) clicks incl. duplicate lines and a subtask; confirmed in \(ms(median(latencies))) median"
}

/// Clicks fired faster than a person — the end state must still be exact.
func checkboxBurst(_ panel: Bool) throws -> String {
    vault.write(Fixture.checks, Fixture.checksContent()); pause(1.2)
    let w = try surface(panel)
    try readyToType(panel)
    try expect(waitFor(6) { uiStates(w, token: "pfzq").count == 13 }, "the 13 test rows aren't on screen")
    var expected = taskStates(Fixture.checks, token: "pfzq")
    for gap in [0.25, 0.15, 0.08] {
        for i in [0, 1, 0, 2, 3, 2, 0, 1] {
            let rows = boxes(in: w).filter { $0.text.contains("pfzq") }
            expected[i].toggle()
            Input.click(CGPoint(x: rows[i].frame.midX, y: rows[i].frame.midY))
            pause(gap)
        }
        let ok = waitFor(4) { taskStates(Fixture.checks, token: "pfzq") == expected && uiStates(w, token: "pfzq") == expected }
        try expect(ok, "after clicks \(Int(gap * 1000))ms apart: want \(pattern(expected)), got file \(pattern(taskStates(Fixture.checks, token: "pfzq")))")
    }
    return "24 clicks at 250/150/80ms apart"
}

/// Typing saves without Enter; checking mid-edit keeps the unsaved words.
func typingAndChecking(_ panel: Bool) throws -> String {
    vault.write(Fixture.checks, Fixture.checksContent()); pause(1.5)
    let w = try surface(panel)
    try readyToType(panel)
    func line() -> String { vault.read(Fixture.checks).components(separatedBy: "\n").first { $0.contains("pfzq task 05") } ?? "(missing)" }
    func want(_ s: String, _ step: String) throws { try expect(waitFor(2) { line() == s }, "\(step): want [\(s)] got [\(line())]") }
    try clickText(w, "pfzq task 05")
    Input.type(" alpha"); try want("- [ ] pfzq task 05 alpha", "saves as typed")
    Input.type(" beta"); try want("- [ ] pfzq task 05 alpha beta", "keeps saving")
    Input.type(" gamma")
    func box() -> Box? { boxes(in: w).first { $0.text.contains("pfzq task 05") } }
    for (n, wantLine) in ["- [x] pfzq task 05 alpha beta gamma", "- [ ] pfzq task 05 alpha beta gamma",
                          "- [x] pfzq task 05 alpha beta gamma", "- [ ] pfzq task 05 alpha beta gamma"].enumerated() {
        guard let b = box() else { throw Failure(message: "row vanished") }
        Input.click(CGPoint(x: b.frame.midX, y: b.frame.midY))
        try want(wantLine, n == 0 ? "check mid-edit keeps the unsaved words" : "toggle \(n + 1)")
        pause(0.3)
    }
    return "saved as typed; check mid-edit + 3 toggles"
}

func enterCases(_ panel: Bool) throws -> String {
    vault.write(Fixture.enter, Fixture.enterContent); pause(1.5)
    if !panel { app.setQuery("folder:pfz/enter tasks:") }
    let w = try surface(panel)
    try readyToType(panel)
    func want(_ lines: [String], _ step: String) throws {
        try expect(waitFor(2) { vault.taskLines(Fixture.enter) == lines }, "\(step): got \(vault.taskLines(Fixture.enter))")
    }
    try clickText(w, "en B"); Input.type(" x"); Input.key(Input.returnKey); pause(0.5); Input.type("en C")
    try want(["- [ ] en A", "    - [ ] en A1", "- [ ] ", "- [ ] en B x", "- [ ] en C"], "Enter opens a task right below")
    Input.key(Input.returnKey); pause(0.5); Input.type("en D")
    try want(["- [ ] en A", "    - [ ] en A1", "- [ ] ", "- [ ] en B x", "- [ ] en C", "- [ ] en D"], "Enter chains")
    Input.key(Input.returnKey); pause(0.5); Input.key(Input.returnKey); pause(0.5)
    try want(["- [ ] en A", "    - [ ] en A1", "- [ ] ", "- [ ] en B x", "- [ ] en C", "- [ ] en D", "- [ ] "], "Enter in an empty task finishes")
    try clickText(w, "en A"); Input.key(Input.returnKey); pause(0.5); Input.type("en A0")
    try want(["- [ ] en A", "    - [ ] en A0", "    - [ ] en A1", "- [ ] ", "- [ ] en B x", "- [ ] en C", "- [ ] en D", "- [ ] "],
             "Enter on a task with subtasks opens a first subtask")
    return "4 cases"
}

func tabCases(_ panel: Bool) throws -> String {
    vault.write(Fixture.tab, Fixture.tabContent); pause(1.5)
    if !panel { app.setQuery("folder:pfz/tab tasks:") }
    let w = try surface(panel)
    try readyToType(panel)
    func want(_ lines: [String], _ step: String) throws {
        try expect(waitFor(2) { vault.taskLines(Fixture.tab) == lines }, "\(step): got \(vault.taskLines(Fixture.tab))")
    }
    try clickText(w, "tb B"); Input.key(Input.returnKey); pause(0.5); Input.key(Input.tab); pause(0.4); Input.type("kid")
    try want(["- [ ] tb A", "- [ ] tb B", "    - [ ] kid"], "Tab nests a new task")
    Input.shiftTab(); pause(0.4); Input.type(" out")
    try want(["- [ ] tb A", "- [ ] tb B", "- [ ] kid out"], "Shift-Tab brings it out")
    try clickText(w, "tb A"); Input.key(Input.tab); pause(0.4); Input.type("Z")
    try want(["- [ ] tb AZ", "- [ ] tb B", "- [ ] kid out"], "Tab on the first task does nothing, focus stays")
    try clickText(w, "tb B"); Input.key(Input.tab); pause(0.4)
    try want(["- [ ] tb AZ", "    - [ ] tb B", "- [ ] kid out"], "Tab nests a task")
    try clickText(w, "kid out"); Input.key(Input.tab); pause(0.4); Input.key(Input.tab); pause(0.4); Input.type("!")
    try want(["- [ ] tb AZ", "    - [ ] tb B", "        - [ ] kid out!"], "two Tabs nest two levels")
    return "6 cases"
}

func backspaceCases(_ panel: Bool) throws -> String {
    vault.write(Fixture.back, Fixture.backContent); pause(1.5)
    if !panel { app.setQuery("folder:pfz/back tasks:") }
    let w = try surface(panel)
    try readyToType(panel)
    func lines() -> [String] { vault.taskLines(Fixture.back) }
    try clickText(w, "New task"); Input.key(Input.backspace)
    try expect(waitFor(2) { lines() == ["- [ ] bk A", "    - [ ] bk A1", "    - [ ] ", "- [ ] bk D"] }, "empty task not removed: \(lines())")
    try clickText(w, "bk D")
    for _ in 0..<3 { Input.key(Input.backspace) }
    try expect(waitFor(2) { lines().contains("- [ ] b") }, "Backspace in words should only delete characters: \(lines())")
    Input.key(Input.backspace)
    try expect(waitFor(2) { lines().contains("- [ ] ") }, "the emptied task should stay until one more Backspace: \(lines())")
    Input.key(Input.backspace)
    try expect(waitFor(2) { !lines().contains("- [ ] ") && !lines().contains("- [ ] b") }, "the emptied task wasn't removed: \(lines())")
    try clickText(w, "New task"); Input.key(Input.backspace)
    try expect(waitFor(2) { lines() == ["- [ ] bk A", "    - [ ] bk A1"] }, "empty subtask not removed: \(lines())")
    return "empty task, emptied task, empty subtask"
}

func dragCases(_ panel: Bool) throws -> String {
    vault.write(Fixture.move, Fixture.moveContent)
    vault.write(Fixture.moveOther, "# PFZ Move Other\n\n- [ ] mv other\n")
    pause(1.5)
    if !panel { app.setQuery("folder:pfz/move tasks:") }
    let w = try surface(panel)
    try readyToType(panel)
    func fileOrder() -> String {
        vault.taskLines(Fixture.move).map { ($0.hasPrefix("    ") ? "  " : "") + $0.components(separatedBy: "] ").last! }.joined(separator: "|")
    }
    func screenOrder() -> String {
        boxes(in: w).filter { $0.text.hasPrefix("mv ") && $0.text != "mv other" }.map(\.text).joined(separator: "|")
    }
    func drag(_ from: String, onto target: String, below: Bool, _ want: String, _ step: String) throws {
        guard let a = button(w, from).flatMap(frame), let b = button(w, target).flatMap(frame) else { throw Failure(message: "\(step): rows not on screen") }
        Input.drag(from: CGPoint(x: a.minX + 30, y: a.midY), to: CGPoint(x: b.minX + 40, y: below ? b.maxY - 2 : b.minY + 2))
        try expect(waitFor(2) { fileOrder() == want }, "\(step): file is \(fileOrder())")
        let screenWant = want.replacingOccurrences(of: "  ", with: "")
        try expect(waitFor(2) { screenOrder() == screenWant }, "\(step): screen shows \(screenOrder())")
    }
    try drag("mv C", onto: "mv A", below: false, "mv C|  mv C1|mv A|  mv A1|  mv A2|mv B|mv D", "C with its subtask above A")
    try drag("mv D", onto: "mv C", below: false, "mv D|mv C|  mv C1|mv A|  mv A1|  mv A2|mv B", "D above C")
    try drag("mv A2", onto: "mv B", below: true, "mv D|mv C|  mv C1|mv A|  mv A1|mv B|mv A2", "a subtask dropped among tasks becomes one")
    try drag("mv B", onto: "mv A1", below: false, "mv D|mv C|  mv C1|mv A|  mv B|  mv A1|mv A2", "a task dropped among subtasks becomes one")
    try drag("mv A", onto: "mv A1", below: true, "mv D|mv C|  mv C1|mv A|  mv B|  mv A1|mv A2", "a task can't drop into its own subtasks")
    if !panel {
        try drag("mv other", onto: "mv D", below: false, "mv D|mv C|  mv C1|mv A|  mv B|  mv A1|mv A2", "a task from another note is refused")
    }
    return panel ? "5 drags" : "6 drags"
}

func duplicateRetypeAndCheck() throws -> String {
    vault.write(Fixture.dup, "# PFZ Dup\n\n- [ ] milk\n- [ ] egg\n"); pause(1.5)
    app.setQuery("folder:pfz/dup tasks:")
    let w = try surface(false)
    try readyToType(false)
    let rows = boxes(in: w).filter { $0.text == "milk" || $0.text == "egg" }
    try expect(rows.count == 2, "rows not on screen")
    try clickText(w, "egg")
    for _ in 0..<3 { Input.key(Input.backspace) }
    Input.type("milk")
    Input.click(CGPoint(x: rows[1].frame.midX, y: rows[1].frame.midY))   // inside the save delay
    try expect(waitFor(2) { vault.taskLines(Fixture.dup) == ["- [ ] milk", "- [x] milk"] },
               "the check landed on the wrong 'milk': \(vault.taskLines(Fixture.dup))")
    return "retyped to a duplicate and checked at once"
}

func plusButton() throws -> String {
    vault.write(Fixture.small, "# PFZ Small\n\n- [ ] small one\n"); pause(1.2)
    let p = try surface(true)
    try readyToType(true)
    for word in ["pa", "pb", "pc", "pd"] {
        var plus: CGRect?
        walk(p) { e, _ in if plus == nil, str(e, kAXRoleAttribute) == "AXButton", str(e, kAXIdentifierAttribute) == "plus" { plus = frame(e) }; return plus == nil }
        guard let plus, let pf = frame(p), pf.contains(CGPoint(x: plus.midX, y: plus.midY)) else { throw Failure(message: "+ isn't visible in the pop-out") }
        Input.click(CGPoint(x: plus.midX, y: plus.midY)); pause(0.5)
        try expect(app.panel() != nil, "the pop-out closed after +")
        Input.type(word)
        try expect(waitFor(2) { vault.taskLines(Fixture.small).contains("- [ ] \(word)") }, "+ then typing '\(word)' didn't add it")
    }
    return "4 presses, each a new task"
}

func crossWindowKeys() throws -> String {
    vault.write(Fixture.winX, "# PFZ WinX\n\n- [ ] x keep\n- [ ] \n")
    vault.write(Fixture.winY, "# PFZ WinY\n\n- [ ] y one\n- [ ] y two\n- [ ] \n")
    pause(1.5)
    app.setQuery("folder:pfz/winx tasks:")
    let main = try surface(false)
    try readyToType(false)
    try clickText(main, "New task", caretToEnd: false)          // left mid-edit in the main window
    let p = try surface(true)
    try clickText(p, "y two", caretToEnd: false); Input.key(Input.tab); pause(0.6)
    try clickText(p, "New task", caretToEnd: false); Input.key(Input.backspace); pause(0.8)
    try expect(vault.taskLines(Fixture.winX) == ["- [ ] x keep", "- [ ] "], "the main window's task was changed: \(vault.taskLines(Fixture.winX))")
    try expect(vault.taskLines(Fixture.winY) == ["- [ ] y one", "    - [ ] y two"], "the pop-out's own tasks: \(vault.taskLines(Fixture.winY))")
    return "Tab and Backspace stayed in the pop-out"
}

func titleAutofill() throws -> String {
    vault.write(Fixture.autofill, "# PFZ Autofill Target Note\n\n- [ ] af one\n- [ ] af two\n- [ ] af three\n"); pause(1.5)
    let typed = "tasks: pfz autofill"
    try app.typeQuery(typed); pause(1.2)
    try expect(app.query == typed, "typing through the switch to tasks: lost characters: '\(app.query)'")
    try expect(ghost(typed) == "tasks: pfz autofill Target Note", "autofill showed \(ghost(typed) ?? "nothing")")
    Input.key(Input.right); pause(1.5)
    try expect(app.query == "tasks: PFZ Autofill Target Note", "→ gave '\(app.query)'")
    let rows = app.mainWindow().map { boxes(in: $0).map(\.text) } ?? []
    try expect(Set(rows) == ["af one", "af two", "af three"], "the page shows \(rows)")
    return "completed, accepted, showed that note's 3 tasks"
}

func typingThroughSwitch(_ tag: String?) throws -> String {
    guard let tag else { return "skipped (no tags in the vault)" }
    let typed = "tasks: tag:" + tag.prefix(3)
    try app.typeQuery(typed); pause(1.0)
    try expect(app.query == typed, "focus dropped at the page switch: field is '\(app.query)'")
    try expect(ghost(typed)?.lowercased() == "tasks: tag:\(tag)", "no tag autofill on the tasks: page (\(ghost(typed) ?? "none"))")
    Input.key(Input.right); pause(0.5)
    try expect(app.query.lowercased() == "tasks: tag:\(tag)", "→ gave '\(app.query)'")
    try app.typeQuery("tasks:"); pause(0.6)
    Input.key(Input.backspace); pause(0.6); Input.type(" x"); pause(0.5)
    try expect(app.query == "tasks x", "backing out of tasks: lost typing: '\(app.query)'")
    return "typed through both switches, autofilled and accepted"
}

func openSourceNote() throws -> String {
    vault.write(Fixture.rev, "# PFZ Rev\n\n" + (1...24).map { "Filler paragraph \($0) for spacing.\n\n" }.joined() + "- [ ] rev target\n")
    pause(1.2)
    try app.typeQuery("folder:pfz/rev tasks: rev"); pause(1.5)
    guard let w = app.mainWindow() else { throw Failure(message: "no window") }
    if let byDue = button(w, "By due").flatMap(frame) { Input.click(CGPoint(x: byDue.midX, y: byDue.midY)); pause(0.8) }
    guard let target = boxes(in: w).first(where: { $0.text.contains("rev target") }) else { throw Failure(message: "task not on screen") }
    var chip: CGRect?
    walk(w) { e, _ in if chip == nil, str(e, kAXRoleAttribute) == "AXButton", let f = frame(e), abs(f.midY - target.frame.midY) < 8, f.minX > target.frame.maxX + 200 { chip = f }; return chip == nil }
    guard let chip else { throw Failure(message: "no 'note →' chip") }
    Input.click(CGPoint(x: chip.midX, y: chip.midY)); pause(1.5)
    func caret() -> Int {
        guard let ed = app.editor(), let v = attr(ed, kAXSelectedTextRangeAttribute) else { return -1 }
        var r = CFRange(); AXValueGetValue(v as! AXValue, .cfRange, &r); return r.location
    }
    let revealed = caret()
    try expect(revealed > 100, "the note didn't open at the task line (caret \(revealed))")
    let focused = attr(app.el, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
    var inSearch = false
    if let focused, let field = app.searchField() { inSearch = CFEqual(focused, field) }
    try expect(!inSearch, "focus was pulled into the search box")
    if let ed = app.editor() {
        var top = CFRange(location: 12, length: 0)
        AXUIElementSetAttributeValue(ed, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &top)!)
    }
    pause(0.4)
    func listTitle(_ t: String) -> CGRect? {
        var r: CGRect?
        walk(w, max: 9) { e, _ in if r == nil, str(e, kAXRoleAttribute) == "AXStaticText", (attr(e, kAXValueAttribute) as? String) == t, let f = frame(e), f.minY < 480 { r = f }; return r == nil }
        return r
    }
    guard let other = listTitle("PFZ Rev2"), let back = listTitle("PFZ Rev") else { throw Failure(message: "the two notes aren't in the list") }
    Input.click(CGPoint(x: other.minX + 10, y: other.midY)); pause(0.9)
    Input.click(CGPoint(x: back.minX + 10, y: back.midY)); pause(1.2)
    try expect(caret() < revealed, "coming back jumped to the task line again (caret \(caret()))")
    return "opened at the line; no focus grab; no re-jump"
}

/// Full vault page: open latency, check latency (click → file), no rows
/// moving under the cursor.
func fullPagePerformance() throws -> String {
    var opens: [Double] = []
    for _ in 0..<6 {
        app.setQuery("", settle: 1.2)
        guard let field = app.searchField() else { throw Failure(message: "no search field") }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pause(0.2)
        let t0 = now()                                   // timed from the query changing, not the setup
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "tasks:" as CFString)
        let shown = waitFor(5, every: 0.002) { app.mainWindow().map { w in
            var found = false
            walk(w, max: 14) { e, _ in if !found, str(e, kAXDescriptionAttribute) == "Mark done" || str(e, kAXDescriptionAttribute) == "Mark not done" { found = true }; return !found }
            return found } ?? false }
        try expect(shown, "tasks: showed no rows within 5s")
        opens.append(now() - t0)
    }
    let cold = opens.max() ?? 0
    try expect(cold < Budget.openTasksCold, "the first open took \(ms(cold)) (budget \(ms(Budget.openTasksCold)))")
    try expect(median(opens) < Budget.openTasksMedian, "opening tasks: took \(ms(median(opens))) median (budget \(ms(Budget.openTasksMedian)))")
    pause(2)
    let (fileTimes, freeTimes, moved) = try clickLatency(panel: false, clicks: 12)
    try expect(moved == 0, "\(moved) row(s) moved under the cursor after a check")
    try expect(median(fileTimes) < Budget.checkToFileMedian && p90(fileTimes) < Budget.checkToFileP90,
               "check → file \(ms(median(fileTimes))) median / \(ms(p90(fileTimes))) p90 (budget \(ms(Budget.checkToFileMedian)) / \(ms(Budget.checkToFileP90)))")
    try expect(median(freeTimes) < Budget.mainThreadFreeMedian, "UI busy \(ms(median(freeTimes))) after a check (budget \(ms(Budget.mainThreadFreeMedian)))")
    return "open \(ms(median(opens))) (first \(ms(cold))); check → file \(ms(median(fileTimes))) median, \(ms(p90(fileTimes))) p90; UI free \(ms(median(freeTimes)))"
}

/// Clicks visible rows round-robin; returns click→file times, click→UI-free
/// times, and how many rows moved afterwards.
func clickLatency(panel: Bool, clicks: Int) throws -> ([Double], [Double], Int) {
    let w = try surface(panel)
    try readyToType(panel)
    guard let wf = frame(w) else { throw Failure(message: "no window frame") }
    let watcher = FileWatcher(vault.root)
    pause(0.3)
    let targets = boxes(in: w).filter { $0.frame.minY > wf.minY + 60 && $0.frame.maxY < wf.maxY - 30 && $0.text.count >= 4 && $0.text != "New task" }.prefix(6).map(\.text)
    try expect(targets.count >= 3, "fewer than 3 clickable rows")
    var fileTimes: [Double] = [], freeTimes: [Double] = [], moved = 0
    for n in 0..<clicks {
        let before = boxes(in: w)
        guard let b = before.first(where: { $0.text == targets[n % targets.count] }) else { moved += 1; continue }
        let layout = before.map { "\($0.text)|\(Int($0.frame.minY))" }
        let t0 = now()
        Input.click(CGPoint(x: b.frame.midX, y: b.frame.midY))
        guard let hit = watcher.firstChange(after: t0, timeout: 3) else { throw Failure(message: "click \(n + 1) on '\(b.text)' never wrote the note") }
        fileTimes.append(hit.time - t0)
        _ = attr(w, kAXTitleAttribute)                      // answered once the UI thread is free
        freeTimes.append(now() - t0)
        pause(0.8)
        let after = boxes(in: w)
        moved += zip(layout, after.map { "\($0.text)|\(Int($0.frame.minY))" }).filter { $0 != $1 }.count > 0 ? 1 : 0
        let flipped = after.first { $0.text == b.text && abs($0.frame.midY - b.frame.midY) < 3 }.map { $0.checked != b.checked } ?? false
        try expect(flipped, "click \(n + 1): the box on '\(b.text)' didn't flip on screen")
    }
    return (fileTimes, freeTimes, moved)
}

/// Checking tasks in older notes must not float their sections to the top
/// while the page is up; coming back re-sorts newest-edited first.
func stableOrder() throws -> String {
    for (i, age) in [1.0, 5, 24, 72].enumerated() {
        vault.write("pfz/order/PFZ Order \(i + 1).md", "# PFZ Order \(i + 1)\n\n" + (1...3).map { "- [ ] pfzord \(i + 1).\($0)\n" }.joined(), ageHours: age)
    }
    pause(1.5)
    app.setQuery("folder:pfz/order tasks:", settle: 2)
    let w = try surface(false)
    try readyToType(false)
    func order() -> [String] { boxes(in: w).filter { $0.text.hasPrefix("pfzord") }.map(\.text) }
    try expect(order().first == "pfzord 1.1" && order().count == 12, "unexpected start order \(order())")
    let start = order()
    for text in ["pfzord 4.1", "pfzord 3.1", "pfzord 4.2"] {
        guard let b = boxes(in: w).first(where: { $0.text == text }) else { throw Failure(message: "\(text) not on screen") }
        Input.click(CGPoint(x: b.frame.midX, y: b.frame.midY)); pause(1.2)
        try expect(order() == start, "rows moved after checking \(text): \(order())")
    }
    app.setQuery("pfzord", settle: 1.2)
    app.setQuery("folder:pfz/order tasks:", settle: 2)
    let firsts = order().enumerated().filter { $0.offset % 3 == 0 }.map { String($0.element.prefix(9)) }
    try expect(firsts.prefix(2).sorted() == ["pfzord 3.", "pfzord 4."], "coming back didn't put the just-edited notes first: \(firsts)")
    return "no movement while up; re-sorted on return"
}

// MARK: Performance and health

func typingLoadAndBackgroundWork() throws -> String {
    try relaunch(pin: "list")
    app.setQuery("PFZ Checks")
    _ = try app.openPanel(); pause(2.0); app.closePanel(); pause(1.5)   // a closed pop-out must go quiet
    try app.front()
    guard let ed = app.editor(), let f = frame(ed) else { throw Failure(message: "no editor") }
    Input.click(CGPoint(x: f.minX + 60, y: f.maxY - 20)); pause(0.4)
    Input.click(CGPoint(x: f.minX + 60, y: f.maxY - 20)); pause(0.3)
    try readyToType(false)
    let before = vault.read(Fixture.checks).count
    let text = profile(pid: app.pid, seconds: 9, path: scratch + "/typing-profile.txt") {
        let end = now() + 7
        var n = 0
        while now() < end { Input.type(String(UnicodeScalar(UInt8(97 + n % 26)))); n += 1; pause(n % 3 == 0 ? 0.9 : 0.1) }
    }
    try expect(vault.read(Fixture.checks).count > before, "the typing never saved (did it land?)")
    try expect(!text.isEmpty, "couldn't profile the app")
    let scans = text.components(separatedBy: "TaskPage.lines").count - 1
    let reloads = text.components(separatedBy: "scanDirectory").count - 1
    let rebuilds = text.components(separatedBy: "rebuildNoteFolderCaches()").count - 1
    try expect(scans == 0, "a whole-vault task scan ran during typing (\(scans) samples) — a closed pop-out or task view is still live")
    try expect(reloads == 0, "the vault reloaded during typing (\(reloads) samples) — own saves aren't recognized")
    try expect(rebuilds == 0, "the folder maps rebuilt during typing (\(rebuilds) samples)")
    let busy = mainThreadBusyShare(text) ?? 1
    try expect(busy < Budget.typingMainThreadBusy, "main thread \(Int(busy * 100))% busy while typing (budget \(Int(Budget.typingMainThreadBusy * 100))%)")
    return "main thread \(Int(busy * 100))% busy; no task scans, reloads, or folder rebuilds"
}

func idleAndMemory() throws -> String {
    pause(3)
    var total = 0.0
    for _ in 0..<5 { total += app.cpuPercent; pause(1) }
    let cpu = total / 5, mb = app.residentMB
    try expect(cpu < Budget.idleCPU, String(format: "idle CPU %.1f%% (budget %.1f%%)", cpu, Budget.idleCPU))
    try expect(mb < Budget.memoryMB, "\(mb) MB resident (budget \(Budget.memoryMB) MB)")
    return String(format: "idle CPU %.1f%%, %d MB", cpu, mb)
}

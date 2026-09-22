import AppKit
import ApplicationServices

// preflight-ui <vault-clone> <report-path> [scratch-dir]
//
// Drives EnvyTest.app end to end against a throwaway vault clone. Run it via
// Scripts/preflight/run.sh, which builds it, prepares the clone, points
// EnvyTest at it, and restores everything afterwards.

setvbuf(stdout, nil, _IOLBF, 0)   // progress shows as it happens, even when piped to a log
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: preflight-ui <vault-clone> <report-path> [scratch-dir]")
    exit(2)
}
vault = Vault(args[1])
runner = Runner(reportPath: args[2])
if args.count >= 4 { scratch = args[3] }

// Hung accessibility calls end in 3s instead of the default minute-plus.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 3)
guard AXIsProcessTrusted() else {
    print("FAIL: this terminal needs Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility)")
    exit(2)
}
signal(SIGINT) { _ in Input.releaseModifiers(); exit(130) }
atexit { Input.releaseModifiers() }

Fixture.writeAll()
let vocab = vault.vocabulary()

runner.section("Launch")
setDefault("menuBarTaskPin", "list")
runner.test("Cold launch to a usable window", timeout: 60) {
    let launched: Double
    (app, launched) = try App.launch()
    try expect(launched < Budget.launch, String(format: "took %.1fs (budget %.0fs)", launched, Budget.launch))
    return String(format: "%.1fs", launched)
}
guard app != nil else { runner.writeReport(); exit(1) }
currentPin = "list"

runner.section("Notes")
coreTests(vocab)

runner.section("tasks: page")
runner.test("Typing through the switch to tasks: keeps focus and autofill") { try typingThroughSwitch(vocab.tag) }
runner.test("Note-title autofill after tasks:") { try titleAutofill() }
runner.test("Checkboxes: every click lands (file + screen)") { app.setQuery("folder:pfz/check tasks:"); return try checkboxSteady(false) }
runner.test("Checkboxes: rapid clicks") { try checkboxBurst(false) }
runner.test("Typing saves as typed; check mid-edit") { app.setQuery("folder:pfz/check tasks:"); return try typingAndChecking(false) }
runner.test("Enter opens a task right below") { try enterCases(false) }
runner.test("Tab / Shift-Tab nest and un-nest") { try tabCases(false) }
runner.test("Backspace deletes empty tasks only") { try backspaceCases(false) }
runner.test("Drag to rearrange within a note") { try dragCases(false) }
runner.test("Retype to a duplicate, check at once") { try duplicateRetypeAndCheck() }
runner.test("Rows stay put while the page is up") { try stableOrder() }
runner.test("Open Source Note") { try openSourceNote() }
runner.test("Full vault page: open and check speed", timeout: 180) { try fullPagePerformance() }

runner.section("Note pop-out")
runner.test("Checkboxes: every click lands") { try relaunch(pin: vault.path(Fixture.checks)); return try checkboxSteady(true) }
runner.test("Checkboxes: rapid clicks") { try relaunch(pin: vault.path(Fixture.checks)); return try checkboxBurst(true) }
runner.test("Typing saves as typed; check mid-edit") { try relaunch(pin: vault.path(Fixture.checks)); return try typingAndChecking(true) }
runner.test("Enter opens a task right below") { try relaunch(pin: vault.path(Fixture.enter)); return try enterCases(true) }
runner.test("Tab / Shift-Tab nest and un-nest") { try relaunch(pin: vault.path(Fixture.tab)); return try tabCases(true) }
runner.test("Backspace deletes empty tasks only") { try relaunch(pin: vault.path(Fixture.back)); return try backspaceCases(true) }
runner.test("Drag to rearrange") { try relaunch(pin: vault.path(Fixture.move)); return try dragCases(true) }
runner.test("+ adds a task each press") { try relaunch(pin: vault.path(Fixture.small)); return try plusButton() }
runner.test("Keys act only in their own window") { try relaunch(pin: vault.path(Fixture.winY)); return try crossWindowKeys() }

runner.section("Task-list pop-out")
runner.test("Check speed at full vault size", timeout: 180) {
    try relaunch(pin: "list")
    let (file, free, _) = try clickLatency(panel: true, clicks: 10)
    try expect(median(file) < Budget.checkToFileMedian && p90(file) < Budget.checkToFileP90,
               "check → file \(ms(median(file))) / \(ms(p90(file))) p90")
    app.closePanel()
    return "check → file \(ms(median(file))) median; UI free \(ms(median(free)))"
}

runner.section("Performance and health")
runner.test("Typing load; nothing running in the background", timeout: 120) { try typingLoadAndBackgroundWork() }
runner.test("Idle CPU and memory") { try idleAndMemory() }
runner.test("EnvyTest still running (no crash)") {
    try expect(app.isRunning, "EnvyTest isn't running")
    return ""
}

runner.writeReport()
let failed = runner.failures
print("\n\(runner.results.count - failed.count)/\(runner.results.count) UI checks passed")
exit(failed.isEmpty ? 0 : 1)

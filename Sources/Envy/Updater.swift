import AppKit
import Foundation
import Sparkle

/// Owns the Sparkle updater so both the app's menu command and Settings can
/// reach the same instance.
///
/// It previously lived as a private property on EnvyApp, which meant nothing
/// could expose Sparkle's own "check automatically" setting. That mattered:
/// with no SUEnableAutomaticChecks in Info.plist, Sparkle asks each user once
/// on first launch, and anyone who dismissed or declined that prompt had
/// automatic checks switched off permanently and no way in the interface to
/// turn them back on. Their only route to an update was Check for Updates…
/// in the menu, which is exactly the symptom users reported.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// True between Sparkle finding a valid update and the app relaunching
    /// into it. Drives the menu bar's brow indicator — see
    /// AppDelegate+MenuBar. Not persisted: it's re-established by the next
    /// check on launch, and a stale badge surviving a restart would outlive
    /// the update it referred to.
    @Published private(set) var updatePending = false

    /// startingUpdater: true begins Sparkle's scheduled background check
    /// immediately — harmless for EnvyTest too, since its Info.plist has no
    /// SUFeedURL/SUPublicEDKey, so Sparkle has nothing to check against and
    /// stays quiet rather than erroring.
    // Built in init rather than as a stored initial value, because it takes
    // `self` as its delegate and self isn't available until after super.init.
    private(set) var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    // MARK: - SPUUpdaterDelegate

    // Fires for scheduled background checks as well as manual ones, so the
    // indicator appears whether or not the user went looking.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in self.setUpdatePending(true) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.setUpdatePending(false) }
    }

    private func setUpdatePending(_ pending: Bool) {
        guard updatePending != pending else { return }
        updatePending = pending
        setMenuBarUpdatePending(pending)
        // The status item draws from cached images, so it has to be told to
        // pick a different one — it won't re-render on its own.
        (NSApp.delegate as? AppDelegate)?.updateStatusItemIcon()
    }

    /// Mirrors Sparkle's own preference. Published manually because the value
    /// lives in Sparkle's defaults, not in a stored property here.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Nil until the first check completes — a fresh install has never
    /// checked, and saying "never" is more honest than showing a placeholder
    /// date.
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

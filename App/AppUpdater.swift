import Foundation
import Observation
#if canImport(Sparkle) && COBBLE_CHROMIUM_CLIENT
import Sparkle
#endif

/// Sparkle owns update state and installation; Cobble only presents its reminder.
@MainActor @Observable
final class AppUpdater: NSObject {
    private(set) var isEnabled = false
    private(set) var canCheck = false
    private(set) var automaticChecks = false
    private(set) var reminder: String?
    private(set) var errorMessage: String?

    static func isEligible(info: [String: Any], environment: [String: String],
                           fullRelease: Bool) -> Bool {
        fullRelease && info["CobbleUpdatesEnabled"] as? Bool == true
            && environment["COBBLE_TESTING"] != "1"
            && environment["COBBLE_DATA_DIRECTORY"] == nil
    }

    #if canImport(Sparkle) && COBBLE_CHROMIUM_CLIENT
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    #endif

    func start() {
        #if canImport(Sparkle) && COBBLE_CHROMIUM_CLIENT && !DEBUG
        guard controller == nil, Self.isEligible(info: Bundle.main.infoDictionary ?? [:],
            environment: ProcessInfo.processInfo.environment, fullRelease: true) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                // Sparkle documents these properties and KVO notifications as main-thread only.
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticChecks = updater.automaticallyChecksForUpdates }
            }
        ]
        do {
            try controller.updater.start()
            isEnabled = true
        } catch {
            errorMessage = error.localizedDescription
            canCheck = false
        }
        #endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
        #if canImport(Sparkle) && COBBLE_CHROMIUM_CLIENT
        guard isEnabled else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle) && COBBLE_CHROMIUM_CLIENT
        guard isEnabled, canCheck else { return }
        controller?.checkForUpdates(nil)
        #endif
    }
}

#if canImport(Sparkle) && COBBLE_CHROMIUM_CLIENT
// Sparkle calls user-driver delegates on the main thread.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Critical updates keep Sparkle's immediate presentation.
        update.isCriticalUpdate
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                    forUpdate update: SUAppcastItem,
                                                    state: SPUUserUpdateState) {
        reminder = state.stage == .notDownloaded
            ? String(localized: "Update available") : String(localized: "Restart to update")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        reminder = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        reminder = nil
    }
}
#endif

import Observation
import Sparkle

/// Wraps Sparkle so SwiftUI can drive "Check for Updates…" and the automatic-check preference.
@MainActor
@Observable
final class UpdaterModel {
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    private(set) var canCheckForUpdates = false

    /// Sparkle persists this itself; the setter forwards to it.
    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller.updater.automaticallyChecksForUpdates }
        set {
            withMutation(keyPath: \.checksAutomatically) { controller.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    /// `startingUpdater` is false for unit tests and the regression harness so they never touch the network.
    init(startingUpdater: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

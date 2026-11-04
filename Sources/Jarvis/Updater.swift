import Foundation
import Sparkle

/// Checks for signed updates, but only in a release build that was given an update feed and a signing key.
/// Development builds have neither, so they never check for anything.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary
        let isConfigured = !(info?["SUFeedURL"] as? String ?? "").isEmpty && !(info?["SUPublicEDKey"] as? String ?? "").isEmpty
        controller = isConfigured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var canCheck: Bool { controller != nil }

    func check() {
        controller?.checkForUpdates(nil)
    }
}

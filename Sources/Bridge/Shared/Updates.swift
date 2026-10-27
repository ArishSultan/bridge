import AppKit
import Observation
import Sparkle
import SwiftUI

/// Updates through Sparkle, for builds from a release: they carry the public key the updates
/// are signed with (`SUPublicEDKey`) and the address of the appcast (`SUFeedURL`). A local build
/// has neither and never looks for updates.
///
/// Bridge checks at launch and then every hour (`SUScheduledCheckInterval`), in the background.
/// A found update doesn't interrupt with a window: it shows as a badge (in the toolbar, the
/// Welcome window and the app menu). Clicking it opens Sparkle's usual flow: download, install,
/// and relaunch when you say so.
@MainActor
@Observable
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    /// The version found and not yet installed, while its badge shows.
    private(set) var pending: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        let signed = (info["SUPublicEDKey"] as? String).map { !$0.isEmpty } ?? false
        guard signed, info["SUFeedURL"] as? String != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.startUpdater()
        // Sparkle checks on its own once an hour has passed; check at every launch too.
        controller.updater.checkForUpdatesInBackground()
    }

    /// Whether this build can update itself.
    var available: Bool { controller != nil }

    /// Check now (the menu item), or go on with the update the badge shows.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Updates found in the background are shown by Bridge (the badge), not as a window.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            // Sparkle shows it itself when the user asked (Check for Updates…); otherwise badge it.
            if !handleShowingUpdate { pending = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pending = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pending = nil }
    }
}

/// "Update to <version>" in a window's toolbar or the Welcome window.
struct UpdateBadge: View {
    private var updates: Updates { .shared }

    var body: some View {
        if let version = updates.pending {
            Button {
                updates.checkForUpdates()
            } label: {
                Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
            }
            .help("Bridge \(version) is available: download and install it, then relaunch")
            .accessibilityLabel("Update available: Bridge \(version)")
        }
    }
}

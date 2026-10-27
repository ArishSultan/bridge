import AppKit
import Sparkle

/// Updates through Sparkle, for builds from a release: they carry the public key the updates
/// are signed with (`SUPublicEDKey`) and the address of the appcast (`SUFeedURL`). A local build
/// has neither and never looks for updates.
@MainActor
final class Updates {
    static let shared = Updates()

    private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let signed = (info["SUPublicEDKey"] as? String).map { !$0.isEmpty } ?? false
        let feed = info["SUFeedURL"] as? String != nil
        controller = signed && feed
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    /// Whether this build can update itself.
    var available: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

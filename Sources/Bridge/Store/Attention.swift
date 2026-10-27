import AppKit
import BridgeCore
import UserNotifications

/// Marks terminals that need a look (the bell rang, a long command or a task finished) while the
/// user was elsewhere: a bell in the sidebar, the Dock badge, and a system notification when the
/// app is in the background.
@MainActor
final class Attention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Attention()

    /// Notifications only work from the app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// A pane needs attention: `body` says why ("“npm test” failed", "needs your attention").
    func raise(_ session: PaneSession, body: String) {
        let store = Store.shared
        guard !isInSight(session) else { return }
        session.needsAttention = true
        updateBadge()
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        guard let center, let project = store.project(session.projectID) else { return }
        let content = UNMutableNotificationContent()
        content.title = project.name
        let label = store.label(of: session.id, in: project) ?? "Terminal"
        content.body = "\(label): \(body)"
        content.userInfo = ["project": Int(session.projectID), "pane": Int(session.id)]
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "\(session.projectID)-\(session.id)", content: content, trigger: nil))
    }

    /// A notification not tied to a pane (a port forward stopped, an SSH session dropped).
    func notify(title: String, body: String, identifier: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func clear(_ session: PaneSession) {
        guard session.needsAttention else { return }
        session.needsAttention = false
        updateBadge()
        center?.removeDeliveredNotifications(withIdentifiers: ["\(session.projectID)-\(session.id)"])
    }

    func updateBadge() {
        let count = Store.shared.sessions.values.filter(\.needsAttention).count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    /// Whether the pane is on screen in the window the user is using.
    private func isInSight(_ session: PaneSession) -> Bool {
        let store = Store.shared
        guard NSApp.isActive,
              let controller = store.controllers[session.projectID],
              controller.window?.isKeyWindow == true,
              let project = store.project(session.projectID),
              let active = project.active
        else { return false }
        return project.view(active)?.panes.contains(session.id) ?? false
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification shows its terminal.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let project = info["project"] as? Int, let pane = info["pane"] as? Int else { return }
        await MainActor.run {
            Store.shared.reveal(project: ID(project), pane: ID(pane))
        }
    }
}

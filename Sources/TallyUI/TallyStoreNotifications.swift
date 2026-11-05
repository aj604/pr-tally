import Foundation
import UserNotifications

/// Delivers milestones as system notifications.
@MainActor
public final class MilestoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = MilestoneNotifier()

    /// Only a bundled app has a notification center; a bare `swift run` executable would crash asking for it.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    public func post(_ milestone: Milestone) {
        guard let center else { return }
        center.delegate = self
        Task {
            // Asks the first time, then answers from what the user chose.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = milestone.title
            content.body = milestone.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Whether the user has turned PR Tally's notifications off in System Settings, so the toggle can say so.
    public func isDenied() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    /// A menu bar app is never really in the foreground; show the banner either way.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

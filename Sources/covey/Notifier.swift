import Foundation
import UserNotifications

/// Presents notifications even while Covey is frontmost: without a delegate
/// macOS silences banners for the foreground app, and a silenced alert is
/// lost for the whole window cycle (the dedup marker is already written).
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// System-notification facade. All the bundle quirks live here:
/// UNUserNotificationCenter traps outside an .app bundle — both in bare
/// `swift build` binaries and in the xctest host (which HAS a bundle
/// identifier, hence the bundleURL extension check).
enum Notifier {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // Retained for the process lifetime: UNUserNotificationCenter.delegate is
    // weak, so an unretained instance would be deallocated immediately.
    private static let presenter = ForegroundPresenter()

    /// Fire-and-forget: a denied permission just means `post` goes nowhere.
    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ alert: LimitAlert) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // No categories or custom actions: the default click activates
        // the app, which is all we need.
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

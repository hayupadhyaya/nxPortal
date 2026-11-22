import Foundation
import PortalHostModel
import UserNotifications

/// `UNUserNotificationCenter` as the Host's `NotificationCentring`; `PairingNotifier` (PortalHostModel) does the queuing, so
/// nothing here is awaited by the model. A refusal or an error posts nothing and fails nothing.
struct SystemNotificationCentre: NotificationCentring {
    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func remove(id: String) async {
        let centre = UNUserNotificationCenter.current()
        centre.removeDeliveredNotifications(withIdentifiers: [id])
        centre.removePendingNotificationRequests(withIdentifiers: [id])
    }
}

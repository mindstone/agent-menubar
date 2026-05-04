import Foundation
import UserNotifications

enum DroidNotifier {
    static func requestAuthorisation() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = urgent ? .defaultCritical : .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

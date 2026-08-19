import Foundation
import UserNotifications

/// Native notifications, with the two actions that actually matter on a
/// notification about an agent: go to it, or acknowledge it.
enum Notifier {
    static let categoryID = "AGENT_INBOX_ITEM"
    static let openAction = "OPEN_SESSION"
    static let readAction = "MARK_READ"

    static func registerCategories() {
        let open = UNNotificationAction(
            identifier: openAction, title: "Open Session", options: [.foreground])
        let read = UNNotificationAction(identifier: readAction, title: "Mark Read", options: [])
        let category = UNNotificationCategory(
            identifier: categoryID, actions: [open, read], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(_ item: InboxItem, soundName: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(item.kind.symbol) \(item.titleLine)"

        var lines: [String] = []
        if let summary = item.summary { lines.append(summary) }
        if let ask = item.ask { lines.append("🗣 \(ask)") }
        if let detail = item.detail { lines.append(detail) }
        if let waiting = item.waitingOn { lines.append("❯ \(waiting)") }
        content.body = lines.joined(separator: "\n")

        content.categoryIdentifier = categoryID
        content.userInfo = ["itemID": item.id]
        // Group by repo so a chatty session collapses instead of stacking.
        content.threadIdentifier = item.repo
        if !soundName.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        }

        let request = UNNotificationRequest(
            identifier: item.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

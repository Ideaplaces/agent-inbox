import Foundation
import UserNotifications

/// The two calls this app makes into `UNUserNotificationCenter`.
///
/// Behind a protocol because the real center cannot be reached from a test at
/// all: `current()` aborts in a process with no app bundle around it. Everything
/// that decides what a banner says is settled before it gets here, so this is
/// the whole seam, and a test can hold the request and read it.
protocol NotificationPosting {
    func add(_ request: UNNotificationRequest)
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

/// The real center, looked up on every call rather than held. Constructing this
/// must stay free of side effects so a default-built model can exist in a test
/// process; only a post touches the system.
struct SystemNotificationCenter: NotificationPosting {
    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request)
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
}

/// Native notifications, with the two actions that actually matter on a
/// notification about an agent: go to it, or acknowledge it.
struct Notifier {
    static let categoryID = "AGENT_INBOX_ITEM"
    static let readAction = "MARK_READ"

    let poster: any NotificationPosting

    init(poster: any NotificationPosting = SystemNotificationCenter()) {
        self.poster = poster
    }

    func registerCategories() {
        let read = UNNotificationAction(identifier: Self.readAction, title: "Mark Read", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [read], intentIdentifiers: [], options: [])
        poster.setCategories([category])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(_ item: InboxItem, soundName: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(item.kind.symbol) \(item.titleLine)"

        var lines: [String] = []
        if let summary = item.summary { lines.append(summary) }
        if let ask = item.ask { lines.append("🗣 \(ask)") }
        if let detail = item.detail { lines.append(detail) }
        if let closing = item.closingWords { lines.append(closing) }
        if let waiting = item.waitingOn { lines.append("❯ \(waiting)") }
        // A banner is plain text, so markers would show as literal ** and `.
        content.body = MarkdownText.plain(lines.joined(separator: "\n"))

        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["itemID": item.id]
        // Group by repo so a chatty session collapses instead of stacking.
        content.threadIdentifier = item.repo
        if !soundName.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        }

        poster.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }
}

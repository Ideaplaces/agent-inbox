import Foundation
import Observation

/// The inbox itself: what arrived, what you have seen, what has aged out.
///
/// Sticky by design. An item stays until you read it or until you have been at
/// the keyboard long enough for it to stop mattering, so stepping away never
/// costs you a notification.
@Observable
@MainActor
final class InboxStore {
    private(set) var items: [InboxItem] = []
    private var storeURL: URL { SenderConfig.directory.appendingPathComponent("items.json") }
    private let presence: Presence

    init(presence: Presence) {
        self.presence = presence
        load()
    }

    var unread: [InboxItem] { items.filter { !$0.isRead } }
    var needsYouCount: Int { unread.filter { $0.kind == .needsYou }.count }
    var finishedCount: Int { unread.filter { $0.kind == .finished }.count }
    var hasUnread: Bool { !unread.isEmpty }

    /// The menubar label. Empty when there is nothing waiting, which is the
    /// point: a quiet inbox should look quiet.
    var badge: String {
        var parts: [String] = []
        if needsYouCount > 0 { parts.append("\(ItemKind.needsYou.symbol)\(needsYouCount)") }
        if finishedCount > 0 { parts.append("\(ItemKind.finished.symbol)\(finishedCount)") }
        return parts.joined(separator: " ")
    }

    @discardableResult
    func add(_ incoming: [InboxItem]) -> [InboxItem] {
        let known = Set(items.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return [] }
        items.append(contentsOf: fresh)
        // Keep the archive bounded; the transport history is the real archive.
        if items.count > 500 { items.removeFirst(items.count - 500) }
        save()
        return fresh
    }

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isRead = true
        save()
    }

    func markAllRead() {
        for index in items.indices { items[index].isRead = true }
        save()
    }

    func clearRead() {
        items.removeAll { $0.isRead }
        save()
    }

    func item(id: String) -> InboxItem? {
        items.first { $0.id == id }
    }

    /// Retire items that have been sitting through `expireMinutes` of you
    /// actually being here. Zero disables expiry entirely.
    func expire(afterMinutes minutes: Int) {
        guard minutes > 0 else { return }
        let cutoff = presence.seconds - minutes * 60
        guard cutoff > 0 else { return }
        let before = items.count
        for index in items.indices where items[index].presenceAtArrival <= cutoff {
            items[index].isRead = true
        }
        // Read items are kept briefly so the "recently finished" list is not
        // empty the moment you look at it, then dropped.
        items.removeAll { $0.isRead && $0.presenceAtArrival <= cutoff - 3600 }
        if items.count != before || items.contains(where: { $0.isRead }) { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([InboxItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: storeURL.path)
    }
}

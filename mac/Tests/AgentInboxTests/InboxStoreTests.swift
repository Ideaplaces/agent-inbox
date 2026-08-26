import XCTest
@testable import AgentInbox

@MainActor
final class InboxStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SenderConfig.directory = tempDir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ id: String, _ kind: ItemKind, presence: Int = 0) -> InboxItem {
        InboxItem(
            id: id, kind: kind, repo: "repo", host: "mac", duration: nil, summary: nil,
            ask: nil, detail: nil, waitingOn: nil, sessionID: nil, cwd: "/tmp",
            receivedAt: Date(), presenceAtArrival: presence)
    }

    func testAddIgnoresMessagesAlreadySeen() {
        let store = InboxStore(presence: Presence())
        XCTAssertEqual(store.add([item("1", .finished), item("2", .needsYou)]).count, 2)
        // A restart re-reads the same window; nothing may be delivered twice.
        XCTAssertEqual(store.add([item("2", .needsYou), item("3", .finished)]).count, 1)
        XCTAssertEqual(store.items.count, 3)
    }

    func testBadgeCountsOnlyUnread() {
        let store = InboxStore(presence: Presence())
        store.add([item("1", .needsYou), item("2", .needsYou), item("3", .finished)])
        XCTAssertEqual(store.badge, "🖐️2 ✅1")

        store.markRead("1")
        XCTAssertEqual(store.badge, "🖐️1 ✅1")

        store.markAllRead()
        XCTAssertEqual(store.badge, "")
        XCTAssertFalse(store.hasUnread)
    }

    func testItemsSurviveARestart() {
        let first = InboxStore(presence: Presence())
        first.add([item("1", .needsYou)])

        let second = InboxStore(presence: Presence())
        XCTAssertEqual(second.unread.map(\.id), ["1"])
    }

    func testExpiryUsesPresenceNotWallClock() {
        let presence = Presence()
        presence.tick(interval: 600, idleThreshold: .max)  // 10 minutes at the keyboard
        let store = InboxStore(presence: presence)
        store.add([item("old", .finished, presence: 0), item("new", .finished, presence: 599)])

        store.expire(afterMinutes: 5)
        // Arrived 10 minutes of presence ago, past the 5 minute window.
        XCTAssertEqual(store.unread.map(\.id), ["new"])
    }

    func testExpiryDisabledKeepsEverything() {
        let presence = Presence()
        presence.tick(interval: 100_000, idleThreshold: .max)
        let store = InboxStore(presence: presence)
        store.add([item("old", .finished, presence: 0)])

        store.expire(afterMinutes: 0)
        XCTAssertEqual(store.unread.count, 1)
    }

    func testPresenceDoesNotAdvanceWhileAway() {
        let presence = Presence()
        let before = presence.seconds
        presence.tick(interval: 15, idleThreshold: 0)  // threshold 0 means always away
        XCTAssertEqual(presence.seconds, before)
    }
}


/// A conversation is one thing, so the inbox shows one row for it.
///
/// Before this, a busy session stacked a row per turn: the badge counted six
/// where one conversation was waiting, and five of the six repeated a state the
/// newest had already moved past.
@MainActor
final class SessionCollapseTests: XCTestCase {
    private func store() -> InboxStore {
        SenderConfig.directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        return InboxStore(presence: Presence())
    }

    private func item(_ id: String, session: String?, kind: ItemKind = .finished) -> InboxItem {
        InboxItem(
            id: id, kind: kind, repo: "r", host: "h", duration: nil,
            summary: nil, ask: nil, detail: nil, waitingOn: nil,
            sessionID: session, cwd: nil, receivedAt: Date(), presenceAtArrival: 0)
    }

    func testANewerItemRetiresTheOlderOnesFromTheSameSession() {
        let store = self.store()
        store.add([item("1", session: "a")])
        store.add([item("2", session: "a")])
        store.add([item("3", session: "a")])
        XCTAssertEqual(store.unread.map(\.id), ["3"])
    }

    func testOtherSessionsAreUntouched() {
        let store = self.store()
        store.add([item("1", session: "a"), item("2", session: "b")])
        store.add([item("3", session: "a")])
        XCTAssertEqual(Set(store.unread.map(\.id)), ["3", "2"])
    }

    func testAStopAndAnIdleArrivingTogetherCollapseToOne() {
        // The two hooks can be polled in the same batch, so the collapse has to
        // work inside one add() and not only across calls.
        let store = self.store()
        store.add([item("1", session: "a"), item("2", session: "a", kind: .needsYou)])
        XCTAssertEqual(store.unread.map(\.id), ["2"])
    }

    func testItemsWithNoSessionAreNeverCollapsedTogether() {
        // No session id means nothing to group by; collapsing them would hide
        // unrelated events behind each other.
        let store = self.store()
        store.add([item("1", session: nil)])
        store.add([item("2", session: nil)])
        XCTAssertEqual(Set(store.unread.map(\.id)), ["1", "2"])
    }

    func testTheBadgeFollowsTheCollapse() {
        let store = self.store()
        store.add([item("1", session: "a", kind: .needsYou)])
        store.add([item("2", session: "a", kind: .needsYou)])
        XCTAssertEqual(store.needsYouCount, 1)
    }
}

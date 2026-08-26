import XCTest
@testable import AgentInbox

/// Control events share a topic with real ones, so the line between them has to
/// hold in both directions: a real message must never be swallowed as an
/// instruction, and an instruction must never be rendered as a row.
final class ControlEventTests: XCTestCase {
    private func message(title: String, body: String) -> TransportMessage {
        TransportMessage(id: "1", title: title, body: body, footer: "", date: Date())
    }

    func testAClearInstructionIsUnderstood() {
        let m = message(title: ControlEvent.title, body: "clear abc-123")
        XCTAssertEqual(ControlEvent.parse(m), .clearSession("abc-123"))
    }

    func testARealEventIsNeverTakenForAnInstruction() {
        // The shape every sender actually produces.
        let m = message(title: "✅ mentorly-backend @ chipdev (5m 0s)", body: "🧵 something")
        XCTAssertFalse(ControlEvent.isControl(m))
        XCTAssertNil(ControlEvent.parse(m))
    }

    func testAnUnknownInstructionIsDroppedRatherThanGuessed() {
        // A future sender may add verbs this version does not know. Dropping
        // beats rendering a row whose title is the sentinel.
        let m = message(title: ControlEvent.title, body: "snooze abc-123")
        XCTAssertTrue(ControlEvent.isControl(m))
        XCTAssertNil(ControlEvent.parse(m))
    }

    func testAMalformedInstructionIsDropped() {
        XCTAssertNil(ControlEvent.parse(message(title: ControlEvent.title, body: "clear")))
        XCTAssertNil(ControlEvent.parse(message(title: ControlEvent.title, body: "clear   ")))
        XCTAssertNil(ControlEvent.parse(message(title: ControlEvent.title, body: "")))
    }

    func testASessionIdContainingSpacesIsKeptWhole() {
        // maxSplits: 1, so only the verb is split off.
        let m = message(title: ControlEvent.title, body: "clear abc 123")
        XCTAssertEqual(ControlEvent.parse(m), .clearSession("abc 123"))
    }
}

/// Typing in a conversation answers its row.
@MainActor
final class MarkSessionReadTests: XCTestCase {
    private func store() -> InboxStore {
        SenderConfig.directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        return InboxStore(presence: Presence())
    }

    private func item(_ id: String, session: String) -> InboxItem {
        InboxItem(
            id: id, kind: .needsYou, repo: "r", host: "h", duration: nil,
            summary: nil, ask: nil, detail: nil, waitingOn: nil,
            sessionID: session, cwd: nil, receivedAt: Date(), presenceAtArrival: 0)
    }

    func testItClearsOnlyThatConversation() {
        let store = self.store()
        store.add([item("1", session: "a"), item("2", session: "b")])
        store.markSessionRead("a")
        XCTAssertEqual(store.unread.map(\.id), ["2"])
    }

    func testAnUnknownSessionChangesNothing() {
        let store = self.store()
        store.add([item("1", session: "a")])
        store.markSessionRead("nobody")
        XCTAssertEqual(store.unread.count, 1)
    }

    func testAnEmptySessionIdIsIgnoredRatherThanMatchingEverything() {
        let store = self.store()
        store.add([item("1", session: "a")])
        store.markSessionRead("")
        XCTAssertEqual(store.unread.count, 1)
    }
}

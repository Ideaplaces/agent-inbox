import XCTest
@testable import AgentInbox

/// One poll can carry an event and the clear that answers it.
///
/// A turn ends and you type into it seconds later, so both are published inside
/// a single poll interval. Applying every control first, which is how this was
/// written, clears a session before its row exists, and the row then stays
/// unread forever. It looked correct in testing only because the two happened to
/// land in separate polls.
@MainActor
final class MessagePipelineOrderingTests: XCTestCase {
    private var pipeline: MessagePipeline!
    private var store: InboxStore!

    override func setUp() {
        super.setUp()
        SenderConfig.directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let presence = Presence()
        store = InboxStore(presence: presence)
        pipeline = MessagePipeline(store: store, presence: presence)
    }

    private func event(_ id: String, session: String) -> TransportMessage {
        TransportMessage(
            id: id, title: "✅ my-app @ box", body: "did a thing",
            footer: "session \(session) · /tmp/my-app", date: Date())
    }

    private func clear(_ id: String, session: String) -> TransportMessage {
        TransportMessage(
            id: id, title: ControlEvent.title, body: "clear \(session)",
            footer: "", date: Date())
    }

    func testAClearAfterAnEventInTheSamePollStillClearsIt() {
        pipeline.apply([event("1", session: "abc12345"), clear("2", session: "abc12345")])
        XCTAssertEqual(store.unread.count, 0, "the row outlived the clear that answered it")
    }

    func testAClearBeforeAnEventDoesNotSwallowTheNewOne() {
        // The reverse order is a different conversation state: you typed, then
        // the agent came back with something. That row must survive.
        pipeline.apply([clear("1", session: "abc12345"), event("2", session: "abc12345")])
        XCTAssertEqual(store.unread.count, 1)
    }

    func testOtherConversationsInTheSamePollAreUnaffected() {
        pipeline.apply([
            event("1", session: "aaaaaaaa"),
            event("2", session: "bbbbbbbb"),
            clear("3", session: "aaaaaaaa"),
        ])
        XCTAssertEqual(store.unread.map(\.sessionID), ["bbbbbbbb"])
    }

    func testNothingIsAnnouncedForAConversationYouAreAlreadyIn() {
        let announced = pipeline.apply([
            event("1", session: "abc12345"), clear("2", session: "abc12345"),
        ])
        XCTAssertTrue(announced.isEmpty, "banner fired for a row that was cleared in the same poll")
    }

    func testAnOrdinaryEventIsStillAnnounced() {
        let announced = pipeline.apply([event("1", session: "abc12345")])
        XCTAssertEqual(announced.count, 1)
    }
}

import XCTest
@testable import AgentInbox

/// The real HTTP client against a fake ntfy on localhost.
///
/// `NtfyStreamParsingTests` pins what one line means and `ReceiverTests` pins
/// what the receiver does with a scripted connection. Neither touches the part
/// in between: URLSession reading a chunked response line by line, the query
/// string a cursor turns into, and how the stream ends when the server hangs
/// up. That part had only ever been checked against a production server, by
/// eye.
@MainActor
final class NtfyTransportTests: XCTestCase {
    private let topic = "t"
    private var server: FakeNtfyServer!
    private var transport: NtfyTransport!
    private var events: [TransportEvent] = []
    private var ended: Result<Void, Error>?
    private var listening: Task<Void, Never>?
    private var receiver: Receiver?

    override func setUp() async throws {
        try await super.setUp()
        server = FakeNtfyServer()
        try await server.start()
        transport = NtfyTransport(server: server.baseURL, topic: topic)
        events = []
        ended = nil
    }

    override func tearDown() {
        listening?.cancel()
        receiver?.stop()
        server.stop()
        super.tearDown()
    }

    /// Read one stream in the background, keeping what it yields and how it
    /// ended, so a test can publish while the connection is open.
    private func listen(cursor: String?) {
        listening = Task { [self] in
            do {
                for try await event in transport.stream(cursor: cursor) { events.append(event) }
                ended = .success(())
            } catch {
                ended = .failure(error)
            }
        }
    }

    private func message(_ event: TransportEvent?) -> (TransportMessage, String?)? {
        guard case .message(let message, let cursor)? = event else { return nil }
        return (message, cursor)
    }

    func testAStreamOpensThenCarriesEachPublishWithItsIDAsTheCursor() async throws {
        listen(cursor: nil)
        await eventually { events.count == 1 }
        guard case .opened? = events.first else { return XCTFail("no open event: \(events)") }
        XCTAssertEqual(server.received.map(\.path), ["/t/json"])
        XCTAssertEqual(server.received.first?.query, ["since": "all"], "no cursor asks for everything")

        let published = server.publish(
            title: "✅ my-app @ box", body: "did a thing\nsession abc12345 · /tmp/my-app", topic: topic)
        await eventually { events.count == 2 }
        let (message, cursor) = try XCTUnwrap(message(events.last))
        XCTAssertEqual(cursor, published.id)
        XCTAssertEqual(message.id, published.id)
        XCTAssertEqual(message.title, "✅ my-app @ box")
        XCTAssertEqual(message.body, "did a thing")
        XCTAssertEqual(message.footer, "session abc12345 · /tmp/my-app")
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: TimeInterval(published.time)))
        XCTAssertNil(ended, "the connection must stay open after a message")
    }

    func testPollReturnsOnlyWhatCameAfterTheCursor() async throws {
        let first = server.publish(title: "a", body: "1", topic: topic)
        let second = server.publish(title: "b", body: "2", topic: topic)
        let third = server.publish(title: "c", body: "3", topic: topic)
        server.publish(title: "elsewhere", body: "4", topic: "other")

        let result = try await transport.poll(cursor: first.id)
        XCTAssertEqual(result.messages.map(\.id), [second.id, third.id])
        XCTAssertEqual(result.cursor, third.id, "the next poll resumes from the last message")
        XCTAssertEqual(server.received.last?.query, ["poll": "1", "since": first.id])

        let quiet = try await transport.poll(cursor: third.id)
        XCTAssertEqual(quiet.messages.count, 0)
        XCTAssertEqual(quiet.cursor, third.id, "an empty poll keeps the cursor it had")
    }

    /// An older sender ends the body with the footer, and the transport peels
    /// it. A current sender puts the contract line after the footer, so
    /// nothing is peeled and the parser reads the JSON off the end of the
    /// body. Both arrangements have to survive the wire.
    func testTheFooterComesOffTheBodyAndTheContractLineStaysIn() async throws {
        server.publish(
            title: "✅ my-app @ box", body: "🧵 subject\n🗣 ask\nsession abc12345 · /tmp/my-app",
            topic: topic)
        let contract = #"{"v":1,"kind":"finished","repo":"my-app","host":"box","duration":"1m 2s","elapsed":62,"summary":"subject","ask":"ask","closing":null,"detail":null,"waitingOn":null,"session":"abc12345","cwd":"/tmp/my-app"}"#
        server.publish(
            title: "✅ my-app @ box (1m 2s)",
            body: "🧵 subject\n🗣 ask\nsession abc12345 · /tmp/my-app\n\(contract)", topic: topic)

        let result = try await transport.poll(cursor: "all")
        XCTAssertEqual(result.messages.count, 2)

        let older = result.messages[0]
        XCTAssertEqual(older.body, "🧵 subject\n🗣 ask")
        XCTAssertEqual(older.footer, "session abc12345 · /tmp/my-app")
        XCTAssertEqual(MessageParser.parseWithOutcome(older, presence: 0).outcome, .fallback)

        let current = result.messages[1]
        XCTAssertEqual(current.footer, "", "the contract line is not a footer")
        XCTAssertEqual(current.body.split(separator: "\n").last.map(String.init), contract)
        let parsed = MessageParser.parseWithOutcome(current, presence: 0)
        XCTAssertEqual(parsed.outcome, .contract)
        XCTAssertEqual(parsed.item?.sessionID, "abc12345")
        XCTAssertEqual(parsed.item?.elapsed, 62)
    }

    func testATokenIsSentWhenConfiguredAndItsAbsenceIsA401() async throws {
        server.token = "secret"
        let authorised = NtfyTransport(server: server.baseURL, topic: topic, token: "secret")
        _ = try await authorised.poll(cursor: "all")
        XCTAssertEqual(server.received.last?.headers["authorization"], "Bearer secret")

        do {
            _ = try await transport.poll(cursor: "all")
            XCTFail("a poll without the token was accepted")
        } catch {
            guard case TransportError.badResponse(let code)? = error as? TransportError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, 401)
        }

        listen(cursor: nil)
        await eventually { ended != nil }
        guard case .failure(let error)? = ended,
              case TransportError.badResponse(let code)? = error as? TransportError
        else { return XCTFail("a stream without the token did not fail: \(String(describing: ended))") }
        XCTAssertEqual(code, 401, "the status has to reach the receiver so it can show it")
        XCTAssertTrue(events.isEmpty)
    }

    /// The server closing a healthy connection is how ntfy behaves on a
    /// restart, and the receiver's answer is to reconnect from its cursor. So
    /// the stream ends, and it ends cleanly: an error here would count as a
    /// failure, go red on the second one, and back off for nothing.
    func testTheServerClosingTheConnectionEndsTheStreamWithoutAnError() async {
        listen(cursor: nil)
        await eventually { events.count == 1 }
        server.dropOpenStreams()
        await eventually { ended != nil }
        guard case .success? = ended else {
            return XCTFail("a closed connection surfaced as an error: \(String(describing: ended))")
        }
    }

    /// The watchdog's whole premise: a connection that is accepted but never
    /// acknowledged yields nothing at all, rather than an error or a
    /// synthesised open, so silence is the signal it gets to act on.
    func testAConnectionThatNeverAcknowledgesYieldsNothing() async {
        server.hangNextStream()
        listen(cursor: nil)
        await eventually(within: .milliseconds(150)) { !events.isEmpty || ended != nil }
        XCTAssertEqual(server.received.map(\.path), ["/t/json"], "the request was made")
        XCTAssertTrue(events.isEmpty, "events on a stream the server never opened: \(events)")
        XCTAssertNil(ended, "the stream ended on its own instead of waiting")
    }

    /// The one test of the real receiver on the real transport: connect,
    /// deliver, lose the connection, reconnect from the last message. The
    /// clock is still a test clock, so the one second reconnect wait is wound
    /// by hand rather than waited out.
    func testTheReceiverReconnectsFromTheLastMessageAfterTheServerCloses() async throws {
        let sleeper = TestSleeper()
        var delivered: [TransportMessage] = []
        let receiver = Receiver(
            channel: { [transport] in Receiver.Channel(transport: transport!, cursorKey: "cursor.test") },
            deliver: { delivered += $0 },
            sleeper: sleeper, defaults: MemoryDefaults())
        self.receiver = receiver
        receiver.start()
        await eventually { receiver.status.isHealthy }

        let published = server.publish(title: "✅ my-app @ box", body: "did a thing", topic: topic)
        await eventually { delivered.count == 1 }
        XCTAssertEqual(delivered.map(\.id), [published.id])

        server.dropOpenStreams()
        await eventually { sleeper.requested.count == 2 }
        XCTAssertEqual(
            sleeper.requested, [Receiver.openAcknowledgementTimeout, .seconds(1)],
            "a closed connection is not a failure, so the wait is the shortest")

        sleeper.advance(by: .seconds(1))
        await eventually { server.received.count == 2 }
        let cursors = server.received.map { $0.query["since"] ?? "" }
        XCTAssertEqual(cursors.count, 2)
        XCTAssertTrue(
            cursors[0].allSatisfy(\.isNumber), "the first connection starts from now: \(cursors[0])")
        XCTAssertEqual(cursors[1], published.id, "the reconnect asks for what came after the last message")
        XCTAssertEqual(delivered.count, 1, "the reconnect must not replay what was delivered")
    }
}

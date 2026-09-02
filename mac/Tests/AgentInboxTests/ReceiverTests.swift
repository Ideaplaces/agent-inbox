import XCTest
@testable import AgentInbox

/// The connection lifecycle, driven end to end with a scripted transport and
/// a clock wound by hand. No network, no real waiting: a walk through the
/// whole backoff ladder to the 60 second cap takes milliseconds.
///
/// `StreamingTests` pins the arithmetic. These pin what the receiver does
/// with it, which is the part that used to be untestable and the part that
/// fails in the wild.
@MainActor
final class ReceiverTests: XCTestCase {
    private var sleeper: TestSleeper!
    private var suite: String!
    private var defaults: UserDefaults!
    private var delivered: [TransportMessage] = []
    private var receiver: Receiver!

    override func setUp() {
        super.setUp()
        sleeper = TestSleeper()
        suite = "receiver-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        delivered = []
    }

    override func tearDown() {
        receiver?.stop()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func start(_ transport: FakeTransport) {
        receiver = Receiver(
            channel: { Receiver.Channel(transport: transport, cursorKey: "cursor.test") },
            deliver: { [self] messages in delivered += messages },
            sleeper: sleeper, defaults: defaults)
        receiver.start()
    }

    private func message(_ id: String) -> TransportEvent {
        .message(
            TransportMessage(
                id: id, title: "✅ my-app @ box", body: "did a thing",
                footer: "session abc12345 · /tmp/my-app", date: Date()),
            cursor: id)
    }

    /// Everything the receiver waited for, minus the watchdog it arms on
    /// every connection, which leaves the reconnect waits in order.
    private var reconnectWaits: [Duration] {
        sleeper.requested.filter { $0 != Receiver.openAcknowledgementTimeout }
    }

    func testAnAcknowledgedStreamDeliversAndShowsConnected() async {
        let transport = FakeTransport(connections: [
            .init(events: [.opened, message("m1")], ending: .hang),
        ])
        start(transport)
        await settle { delivered.count == 1 }

        XCTAssertEqual(delivered.map(\.id), ["m1"])
        XCTAssertEqual(receiver.status, .connected(sleeper.now))
        XCTAssertEqual(transport.streamCursors, ["start"], "first run starts from the initial cursor")
    }

    func testAClosedStreamReconnectsFromTheLastMessageSeen() async {
        let transport = FakeTransport(connections: [
            .init(events: [.opened, message("m1")], ending: .finish),
        ])
        start(transport)
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(
            sleeper.requested, [Receiver.openAcknowledgementTimeout, .seconds(1)],
            "a healthy connection closing is not a failure, so the wait is the shortest")

        sleeper.advance(by: .seconds(1))
        await settle { transport.streamCursors.count == 2 }
        XCTAssertEqual(transport.streamCursors, ["start", "m1"])
        XCTAssertEqual(delivered.count, 1, "the reconnect must not replay what was delivered")
    }

    /// One failure is a blip and stays whatever colour it was. Two in a row
    /// go red, and every wait after that doubles until it caps.
    func testRepeatedFailuresGoRedAndBackOffToTheCap() async {
        let transport = FakeTransport(
            connections: Array(repeating: .init(ending: .fail("boom")), count: 8))
        start(transport)
        await settle { reconnectWaits.count == 1 }
        XCTAssertEqual(receiver.status, .connecting, "one failure is not worth a red dot")

        sleeper.advance(by: reconnectWaits[0])
        await settle { reconnectWaits.count == 2 }
        XCTAssertEqual(receiver.status, .failed("boom"))

        for expected in 3...7 {
            sleeper.advance(by: reconnectWaits[expected - 2])
            await settle { reconnectWaits.count == expected }
        }
        XCTAssertEqual(
            reconnectWaits,
            [2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) },
            "the wait after the nth failure is backoff(n), so the first is two seconds")
        XCTAssertEqual(transport.streamCursors.count, 7, "one connection per wait recorded")
    }

    /// A connection that opens and never says anything is a proxy buffering
    /// the response. The watchdog must end it, not just note it: the old
    /// code flagged the fact and then sat on the silent stream regardless.
    func testTheWatchdogGivesUpOnASilentStreamAndPollsInstead() async {
        let transport = FakeTransport(connections: [.init(events: [], ending: .hang)])
        start(transport)
        await settle { sleeper.requested.count == 1 && transport.streamCursors.count == 1 }
        XCTAssertEqual(sleeper.requested, [Receiver.openAcknowledgementTimeout])

        sleeper.advance(by: Receiver.openAcknowledgementTimeout)
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested.last, .seconds(1), "giving up is not a failure")

        // The poll, then the wait for the next one.
        sleeper.advance(by: .seconds(1))
        await settle { sleeper.requested.count == 3 }
        XCTAssertEqual(transport.pollCursors, ["start"])
        XCTAssertEqual(receiver.status, .connected(sleeper.now))
        XCTAssertEqual(sleeper.requested.last, Receiver.pollInterval)

        // From here on it polls, on the poll interval, and never streams again.
        sleeper.advance(by: Receiver.pollInterval)
        await settle { sleeper.requested.count == 4 }
        sleeper.advance(by: .seconds(1))
        await settle { sleeper.requested.count == 5 }
        XCTAssertEqual(transport.pollCursors, ["start", "polled"], "each poll resumes from the last")
        XCTAssertEqual(transport.streamCursors.count, 1, "streamed again after giving up on streaming")
    }

    func testWakeReconnectsWithoutWaitingOutThePendingBackoff() async {
        let transport = FakeTransport(connections: [.init(ending: .fail("asleep"))])
        start(transport)
        await settle { reconnectWaits.count == 1 }
        XCTAssertEqual(transport.streamCursors.count, 1)
        XCTAssertEqual(sleeper.sleeping, 1, "the backoff should be parked")

        receiver.wake()
        await settle { transport.streamCursors.count == 2 && sleeper.sleeping == 1 }
        XCTAssertEqual(transport.streamCursors.count, 2, "wake did not reconnect")
        XCTAssertEqual(
            sleeper.sleeping, 1,
            "the abandoned backoff must be cancelled, leaving only the new watchdog")
    }

    func testWakeBeforeStartDoesNothing() async {
        let transport = FakeTransport()
        receiver = Receiver(
            channel: { Receiver.Channel(transport: transport, cursorKey: "cursor.test") },
            deliver: { _ in }, sleeper: sleeper, defaults: defaults)
        receiver.wake()
        await settle { !transport.streamCursors.isEmpty }
        XCTAssertEqual(transport.streamCursors, [], "a wake on a stopped receiver connected")
    }

    func testNoChannelMeansNotConfiguredAndNoConnection() async {
        let transport = FakeTransport()
        receiver = Receiver(
            channel: { nil }, deliver: { _ in }, sleeper: sleeper, defaults: defaults)
        receiver.start()
        await settle { !sleeper.requested.isEmpty }
        XCTAssertEqual(receiver.status, .notConfigured)
        XCTAssertEqual(transport.streamCursors, [])
        XCTAssertEqual(sleeper.requested, [.seconds(1)], "still retries, so configuring later is picked up")
    }
}

/// Presence and expiry age the inbox on their own clock, whatever the
/// connection is doing.
@MainActor
final class HousekeepingTests: XCTestCase {
    func testSweepsOnceOnStartAndThenEveryInterval() async {
        let sleeper = TestSleeper()
        var sweeps = 0
        let housekeeping = Housekeeping(sleeper: sleeper) { sweeps += 1 }
        housekeeping.start()
        await settle { sleeper.requested.count == 1 }
        XCTAssertEqual(sweeps, 1)
        XCTAssertEqual(sleeper.requested, [.seconds(Housekeeping.interval)])

        sleeper.advance(by: .seconds(Housekeeping.interval))
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(sweeps, 2)

        housekeeping.stop()
        sleeper.advance(by: .seconds(Housekeeping.interval))
        await settle { sweeps == 3 }
        XCTAssertEqual(sweeps, 2, "swept after stop")
    }
}

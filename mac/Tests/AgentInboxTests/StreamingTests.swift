import XCTest

@testable import AgentInbox

/// The app asked the server 5,760 times a day for something the server would
/// have handed it the moment it existed. Holding the connection open removes
/// the delay, removes the requests, and removes the setting that existed only
/// to choose between them.
///
/// The parts worth pinning are the two that decide whether it recovers: how
/// long it waits before reconnecting, and how it tells a quiet connection from
/// one that is never going to deliver anything.
@MainActor
final class StreamingTests: XCTestCase {
    func testAFirstFailureRetriesAlmostImmediately() {
        XCTAssertEqual(Receiver.backoff(afterFailures: 0), .seconds(1))
    }

    func testWaitingDoublesSoADeadServerIsNotHammered() {
        XCTAssertEqual(Receiver.backoff(afterFailures: 1), .seconds(2))
        XCTAssertEqual(Receiver.backoff(afterFailures: 2), .seconds(4))
        XCTAssertEqual(Receiver.backoff(afterFailures: 3), .seconds(8))
    }

    /// Capped, or a server down overnight would come back to a client that has
    /// talked itself into waiting hours before trying again.
    func testWaitingIsCapped() {
        XCTAssertEqual(Receiver.backoff(afterFailures: 10), .seconds(60))
        XCTAssertEqual(Receiver.backoff(afterFailures: 10_000), .seconds(60))
    }

    /// The watchdog has to outlast a slow connection and still fire long
    /// before a person decides the app is broken.
    func testTheWatchdogWaitsLongEnoughToBeFairAndShortEnoughToMatter() {
        XCTAssertGreaterThanOrEqual(Receiver.openAcknowledgementTimeout, .seconds(5))
        XCTAssertLessThanOrEqual(Receiver.openAcknowledgementTimeout, .seconds(30))
    }

    /// Presence and expiry used to ride the poll timer, so changing how often
    /// the app checked for messages quietly changed how fast the inbox aged.
    /// They have their own clock now, and it has to keep ticking.
    func testHousekeepingStillHasAClockOfItsOwn() {
        XCTAssertGreaterThan(Housekeeping.interval, 0)
    }
}

/// ntfy writes newline-delimited JSON and puts four kinds of thing on the same
/// connection. Three of them are not messages.
@MainActor
final class NtfyStreamParsingTests: XCTestCase {
    private func event(_ json: String) -> TransportEvent? {
        NtfyTransport.testableEvent(from: json)
    }

    func testTheServersAcknowledgementIsRecognised() {
        guard case .opened? = event(#"{"id":"a","time":1,"event":"open","topic":"t"}"#) else {
            return XCTFail("the open event is the whole basis of the watchdog")
        }
    }

    func testKeepalivesAndPollRequestsAreNotMessages() {
        XCTAssertNil(event(#"{"id":"b","time":2,"event":"keepalive","topic":"t"}"#))
        XCTAssertNil(event(#"{"id":"c","time":3,"event":"poll_request","topic":"t"}"#))
    }

    func testAMessageCarriesItsOwnIDAsTheNextCursor() throws {
        let line = #"""
        {"id":"xyz","time":1700000000,"event":"message","topic":"t","title":"✅ repo @ host (1m 0s)","message":"🧵 subject\nsession a1b2c3d4 · /Users/me/repo"}
        """#
        guard case .message(let message, let cursor)? = event(line) else {
            return XCTFail("a message line must parse")
        }
        XCTAssertEqual(cursor, "xyz", "the cursor is what a reconnect asks from")
        XCTAssertEqual(message.id, "xyz")
        XCTAssertEqual(message.body, "🧵 subject")
        XCTAssertEqual(message.footer, "session a1b2c3d4 · /Users/me/repo")
    }

    func testATruncatedLineIsDroppedRatherThanCrashing() {
        XCTAssertNil(event(#"{"id":"d","event":"mess"#))
        XCTAssertNil(event(""))
    }
}

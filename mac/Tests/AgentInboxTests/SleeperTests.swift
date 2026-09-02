import XCTest
@testable import AgentInbox

/// The hand-wound clock the connection tests drive. Two properties matter,
/// and a double that got either wrong would pass tests it should fail: sleeps
/// wake in deadline order, and a cancelled sleep throws instead of parking.
@MainActor
final class SleeperTests: XCTestCase {
    func testSleepsWakeInDeadlineOrderAndNotBefore() async {
        let sleeper = TestSleeper()
        var woke: [String] = []
        let long = Task { @MainActor in
            try? await sleeper.sleep(for: .seconds(10))
            woke.append("long")
        }
        let short = Task { @MainActor in
            try? await sleeper.sleep(for: .seconds(2))
            woke.append("short")
        }
        await settle { sleeper.sleeping == 2 }

        sleeper.advance(by: .seconds(1))
        await settle { !woke.isEmpty }
        XCTAssertEqual(woke, [], "woke before its deadline")

        sleeper.advance(by: .seconds(10))
        await settle { woke.count == 2 }
        XCTAssertEqual(woke, ["short", "long"])
        XCTAssertEqual(sleeper.requested, [.seconds(10), .seconds(2)])
        _ = await (long.value, short.value)
    }

    func testACancelledSleepThrowsLikeTaskSleep() async {
        let sleeper = TestSleeper()
        let task = Task { @MainActor in
            do {
                try await sleeper.sleep(for: .seconds(60))
                return "returned"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other"
            }
        }
        await settle { sleeper.sleeping == 1 }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertEqual(sleeper.sleeping, 0, "a cancelled sleep stayed in the queue")
    }

    func testNowMovesWithTheClock() {
        let start = Date(timeIntervalSince1970: 0)
        let sleeper = TestSleeper(now: start)
        sleeper.advance(by: .seconds(90))
        XCTAssertEqual(sleeper.now, start.addingTimeInterval(90))
    }
}

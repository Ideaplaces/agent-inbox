import XCTest
@testable import AgentInbox

/// `AnalyticsTests` pins what the payload may contain. This pins when it
/// leaves and what the request looks like on the way out, which used to go
/// straight to `URLSession.shared` and could not be looked at.
@MainActor
final class UsageReporterTests: XCTestCase {
    private final class RecordingSender: EventSender {
        private(set) var requests: [URLRequest] = []
        func send(_ request: URLRequest) { requests.append(request) }
    }

    private var isolated: IsolatedSettings!
    private var settings: AppSettings!
    private var sleeper: TestSleeper!
    private var sender: RecordingSender!
    private var reporter: UsageReporter!

    override func setUp() {
        super.setUp()
        isolated = IsolatedSettings("usage")
        settings = isolated.settings()
        sleeper = TestSleeper()
        sender = RecordingSender()
        reporter = UsageReporter(settings: settings, sleeper: sleeper, sender: sender)
    }

    override func tearDown() {
        isolated.remove()
        super.tearDown()
    }

    private func item(_ kind: ItemKind) -> InboxItem {
        InboxItem(id: UUID().uuidString, kind: kind, repo: "my-app", host: "box",
                  receivedAt: sleeper.now, presenceAtArrival: 0)
    }

    private func properties(of request: URLRequest) throws -> [String: Any] {
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        let top = try XCTUnwrap(body)
        XCTAssertEqual(Set(top.keys), ["api_key", "event", "distinct_id", "properties"])
        XCTAssertEqual(top["event"] as? String, Analytics.eventName)
        XCTAssertEqual(top["distinct_id"] as? String, settings.analyticsID)
        return try XCTUnwrap(top["properties"] as? [String: Any])
    }

    func testOptingInSendsOneRequestADayCarryingTheCounts() throws {
        settings.shareUsageData = true
        reporter.count(item(.finished))
        reporter.count(item(.needsYou))
        reporter.count(item(.finished))

        reporter.reportIfADayHasPassed()
        XCTAssertEqual(sender.requests.count, 1, "an install that has never reported reports now")
        let request = sender.requests[0]
        XCTAssertEqual(request.url, Analytics.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let first = try properties(of: request)
        XCTAssertEqual(
            Set(first.keys),
            [
                "app_version", "macos_version",
                "notifications_finished", "notifications_needs_you",
                "watch_mode", "self_hosted", "custom_tags",
                "$geoip_disable",
            ])
        XCTAssertEqual(first["notifications_finished"] as? Int, 2)
        XCTAssertEqual(first["notifications_needs_you"] as? Int, 1)
        XCTAssertEqual(settings.pendingFinished, 0, "sent counts are not sent again")
        XCTAssertEqual(settings.pendingNeedsYou, 0)

        // The same day: nothing, however much arrives.
        reporter.count(item(.finished))
        sleeper.advance(by: .seconds(3 * 3600))
        reporter.reportIfADayHasPassed()
        XCTAssertEqual(sender.requests.count, 1, "a second event on the same day")

        // The next day: exactly one more, carrying only what came since.
        sleeper.advance(by: .seconds(24 * 3600))
        reporter.reportIfADayHasPassed()
        XCTAssertEqual(sender.requests.count, 2)
        let second = try properties(of: sender.requests[1])
        XCTAssertEqual(second["notifications_finished"] as? Int, 1)
        XCTAssertEqual(second["notifications_needs_you"] as? Int, 0)
    }

    /// Off is the default, and off means no request and no tally, so switching
    /// it on later starts from zero rather than from a count kept in secret.
    func testOptedOutSendsNothingAndCountsNothing() {
        XCTAssertFalse(settings.shareUsageData)
        reporter.count(item(.finished))
        reporter.reportIfADayHasPassed()
        sleeper.advance(by: .seconds(48 * 3600))
        reporter.reportIfADayHasPassed()
        XCTAssertEqual(sender.requests, [])
        XCTAssertEqual(settings.pendingFinished, 0)
        XCTAssertNil(settings.analyticsLastSent)
    }
}

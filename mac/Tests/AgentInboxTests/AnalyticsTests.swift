import XCTest

@testable import AgentInbox

/// Usage reporting is the one feature here whose failure mode is not a bug
/// report, it is a breach of trust. These pin the two properties that make it
/// defensible, so that breaking either takes a deliberate edit to a test rather
/// than an absent-minded line in a payload.
final class AnalyticsTests: XCTestCase {
    private func samplePayload() -> [String: Any] {
        Analytics.payload(
            distinctID: "6D1B0E1C-0000-4000-8000-000000000000",
            appVersion: "0.1.26", osVersion: "26.0",
            finished: 41, needsYou: 3,
            watchMode: "all", selfHosted: true, customTags: false)
    }

    /// The list is the contract. A new key has to be added here first, which is
    /// the moment someone has to ask whether it describes a person.
    func testTheEventCarriesTheseKeysAndNoOthers() throws {
        let props = try XCTUnwrap(samplePayload()["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(props.keys),
            [
                "app_version", "macos_version",
                "notifications_finished", "notifications_needs_you",
                "watch_mode", "self_hosted", "custom_tags",
                "$geoip_disable",
            ])
    }

    /// Every value is a number, a bool, or a version string. Nothing in the
    /// event can carry a repo name, a path, a topic or a sentence, because
    /// there is nowhere for one to go.
    func testEveryValueIsACountAFlagOrAVersion() throws {
        let props = try XCTUnwrap(samplePayload()["properties"] as? [String: Any])
        for (key, value) in props {
            switch value {
            case is Int, is Bool:
                continue
            case let text as String:
                // The only strings are a version and a fixed enum.
                XCTAssertTrue(
                    ["app_version", "macos_version", "watch_mode"].contains(key),
                    "\(key) carries free text")
                XCTAssertTrue(
                    text.allSatisfy { $0.isNumber || $0 == "." } || ["all", "tagged"].contains(text),
                    "\(key) is neither a version nor a known mode: \(text)")
            default:
                XCTFail("\(key) is not a count, a flag or a version")
            }
        }
    }

    /// The id is the app's own random one. Anything derived from the machine or
    /// the person would make "anonymous" a lie.
    func testTheEventIsKeyedOnTheRandomIDItIsGiven() throws {
        let id = UUID().uuidString
        let payload = Analytics.payload(
            distinctID: id, appVersion: "1", osVersion: "26.0",
            finished: 0, needsYou: 0, watchMode: "all",
            selfHosted: false, customTags: false)
        XCTAssertEqual(payload["distinct_id"] as? String, id)
    }

    // MARK: - One a day, no more and no fewer

    func testAMachineThatHasNeverReportedReportsNow() {
        XCTAssertTrue(Analytics.shouldSend(last: nil, now: Date()))
    }

    func testASecondPollOnTheSameDaySendsNothing() {
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        let later = morning.addingTimeInterval(3 * 3600)
        XCTAssertFalse(Analytics.shouldSend(last: morning, now: later))
    }

    /// A calendar day rather than 24 hours: a Mac opened at nine every morning
    /// must report every morning, not drift an hour later each day until it
    /// skips one entirely.
    func testTheNextDayReportsEvenIfItIsLessThanTwentyFourHoursLater() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let lateNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 23))!
        let earlyNext = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 8))!
        XCTAssertTrue(Analytics.shouldSend(last: lateNight, now: earlyNext, calendar: calendar))
    }

    /// Nothing is registered as a default for this key, so an install that has
    /// never been asked reads as off.
    func testItIsOffOnAnInstallThatWasNeverAsked() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "analytics-test-\(UUID().uuidString)"))
        XCTAssertFalse(suite.bool(forKey: "shareUsageData"))
    }
}

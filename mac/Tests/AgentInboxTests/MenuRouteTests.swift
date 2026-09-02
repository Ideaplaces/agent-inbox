import XCTest

@testable import AgentInbox

/// Settings used to be a `Settings` scene, which macOS opens in a window
/// wherever it likes. On a Mac driving a full-screen app that is a different
/// Space, so clicking the gear did nothing you could see and the honest
/// conclusion was that the app was broken. It reached a second machine before
/// anyone worked out what had happened.
///
/// The fix is that there is no window: settings are a page in the popover,
/// which opens where the click was. These pin the two things that makes true.
@MainActor
final class MenuRouteTests: XCTestCase {
    private func model() -> AppModel {
        SenderConfig.directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-inbox-route-\(UUID().uuidString)")
        return AppModel()
    }

    func testThePopoverOpensOnTheInbox() {
        XCTAssertEqual(model().menuRoute, .inbox)
    }

    func testSettingsAndBackAreBothReachable() {
        let m = model()
        m.menuRoute = .settings
        XCTAssertEqual(m.menuRoute, .settings)
        m.menuRoute = .inbox
        XCTAssertEqual(m.menuRoute, .inbox)
    }

    /// The settings page gets a taller floor than the list. Both must refuse
    /// to return zero: a zero-height page inside a popover that sizes itself
    /// to its content draws nothing at all, which is the bug that once left
    /// the header and footer visible with the rows silently gone.
    func testNeitherPageCanBeGivenNoHeight() {
        XCTAssertEqual(
            MenuContentView.settingsHeight(forContent: 0),
            MenuContentView.minimumSettingsHeight)
        XCTAssertEqual(
            MenuContentView.listHeight(forContent: 0),
            MenuContentView.minimumListHeight)
        XCTAssertGreaterThan(
            MenuContentView.minimumSettingsHeight, MenuContentView.minimumListHeight)
    }

    func testALongSettingsPageScrollsRatherThanGrowingForever() {
        XCTAssertEqual(
            MenuContentView.settingsHeight(forContent: 4000),
            MenuContentView.maximumListHeight)
    }
}

/// The floor on turn length is the setting that makes the app look broken when
/// nobody knows it is there: a short turn reports nothing, which is
/// indistinguishable from nothing working. Two people hit it, one of them the
/// person who chose the default.
final class MinimumTurnCaptionTests: XCTestCase {
    func testZeroSaysWhatItMeans() {
        XCTAssertEqual(AppSettings.minSecondsCaption(0), "Every turn")
    }

    func testAFloorReadsAsSeconds() {
        XCTAssertEqual(AppSettings.minSecondsCaption(45), "45s")
    }

    /// The stepper's range starts at zero, but a stored negative from an older
    /// config must not print "-5s".
    func testANegativeIsTreatedAsNoFloor() {
        XCTAssertEqual(AppSettings.minSecondsCaption(-5), "Every turn")
    }
}

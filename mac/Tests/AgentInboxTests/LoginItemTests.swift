import XCTest

@testable import AgentInbox

/// `brew install --cask` copies a bundle. It launches nothing and registers
/// nothing, so an install ended with an app that was not running and was not
/// at login, and the first anyone knew of it was a day of missing
/// notifications. First launch now opts you in.
///
/// The rule worth pinning is the other half: an app that re-enabled itself on
/// every launch would be arguing with the person who turned it off.
final class LoginItemTests: XCTestCase {
    func testAFreshInstallOptsYouIn() {
        XCTAssertTrue(LoginItem.shouldEnableOnLaunch(hasDecided: false, isEnabled: false))
    }

    func testTurningItOffStaysOff() {
        XCTAssertFalse(LoginItem.shouldEnableOnLaunch(hasDecided: true, isEnabled: false))
    }

    func testAnAlreadyRegisteredAppIsLeftAlone() {
        XCTAssertFalse(LoginItem.shouldEnableOnLaunch(hasDecided: false, isEnabled: true))
        XCTAssertFalse(LoginItem.shouldEnableOnLaunch(hasDecided: true, isEnabled: true))
    }
}

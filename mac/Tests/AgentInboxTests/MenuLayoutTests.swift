import XCTest
@testable import AgentInbox

/// The menu once rendered its header and footer with nothing between them,
/// while the badge still counted six waiting items. A ScrollView has no
/// intrinsic height, so a frame that only sets a ceiling let the list collapse
/// to zero. These pin the property that was missing: a floor.
@MainActor
final class MenuLayoutTests: XCTestCase {
    func testTheListIsNeverGivenZeroHeight() {
        // Zero is what the first layout pass proposes before anything is
        // measured, and it is what the bug shipped.
        XCTAssertGreaterThan(MenuContentView.listHeight(forContent: 0), 0)
        XCTAssertEqual(
            MenuContentView.listHeight(forContent: 0),
            MenuContentView.minimumListHeight)
    }

    func testAShortListIsNotPaddedBeyondItsContent() {
        let measured = MenuContentView.minimumListHeight + 120
        XCTAssertEqual(MenuContentView.listHeight(forContent: measured), measured)
    }

    func testALongListStopsAtTheCapSoItScrollsInstead() {
        XCTAssertEqual(
            MenuContentView.listHeight(forContent: 5_000),
            MenuContentView.maximumListHeight)
    }

    func testAMeasurementBelowOneRowStillShowsARow() {
        // A partial measurement mid-animation must not shrink the list to a
        // sliver; one row stays visible.
        XCTAssertEqual(
            MenuContentView.listHeight(forContent: 4),
            MenuContentView.minimumListHeight)
    }
}

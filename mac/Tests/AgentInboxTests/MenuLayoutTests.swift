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

    /// The window keeps the tallest height it reached, so the app shrinks it
    /// itself: to the content, with the top edge where it was, since the top
    /// is what hangs under the menubar.
    func testTheWindowShrinksToItsContentFromTheTop() {
        let tall = NSRect(x: 100, y: 200, width: 560, height: 600)
        let fitted = WindowFitter.frame(fitting: 180, current: tall)
        XCTAssertEqual(fitted, NSRect(x: 100, y: 620, width: 560, height: 180))
    }

    func testTheWindowIsLeftAloneWhenItAlreadyFits() {
        let frame = NSRect(x: 100, y: 200, width: 560, height: 180)
        XCTAssertNil(WindowFitter.frame(fitting: 180, current: frame))
        XCTAssertNil(WindowFitter.frame(fitting: 179.5, current: frame), "sub-point noise is not a resize")
        XCTAssertNil(WindowFitter.frame(fitting: 400, current: frame), "growth is SwiftUI's job")
        XCTAssertNil(WindowFitter.frame(fitting: 0, current: frame), "nothing measured yet")
    }
}


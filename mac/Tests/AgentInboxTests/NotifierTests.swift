import UserNotifications
import XCTest
@testable import AgentInbox

/// A message walked from the receiver's hand-off to the banner, through the
/// model's real wiring, with the notification center swapped for one that
/// records. The center itself cannot be constructed in a test process, so
/// until this seam existed nothing about a banner could be asserted.
@MainActor
final class NotifierTests: XCTestCase {
    private var isolated: IsolatedSettings!
    private var model: AppModel!

    override func setUp() {
        super.setUp()
        isolated = IsolatedSettings("notifier")
        model = isolated.model()
    }

    override func tearDown() {
        isolated.remove()
        super.tearDown()
    }

    private func finished(_ id: String, session: String = "abc12345") -> TransportMessage {
        TransportMessage(
            id: id, title: "✅ my-app @ devbox (4m 19s)",
            body: "🧵 Refactor the **checkout** flow\n🗣 handle the `refund` path\n"
                + "💬 Refunds are wired up. … Want me to run it against staging?",
            footer: "session \(session) · /Users/me/my-app", date: Date())
    }

    func testADeliveredFinishedItemPostsOneBanner() throws {
        model.deliver([finished("m1")])

        XCTAssertEqual(isolated.poster.requests.count, 1)
        let request = try XCTUnwrap(isolated.poster.requests.first)
        XCTAssertEqual(request.identifier, "m1")
        XCTAssertEqual(request.content.title, "✅ my-app @ devbox (4m 19s)")
        XCTAssertEqual(
            request.content.body,
            "Refactor the checkout flow\n🗣 handle the refund path\n"
                + "Refunds are wired up. … Want me to run it against staging?",
            "a banner is plain text, so the markdown markers must be gone")
        XCTAssertEqual(request.content.threadIdentifier, "my-app", "grouped by repo")
        XCTAssertEqual(request.content.userInfo["itemID"] as? String, "m1")
        XCTAssertEqual(request.content.categoryIdentifier, Notifier.categoryID)
        XCTAssertNotNil(request.content.sound, "the default install makes a sound")
        XCTAssertNil(request.trigger, "posted now, not scheduled")
    }

    func testAControlEventPostsNothing() {
        model.deliver([
            TransportMessage(
                id: "c1", title: ControlEvent.title, body: "clear abc12345",
                footer: "", date: Date()),
        ])
        XCTAssertEqual(isolated.poster.requests.count, 0)

        // And a clear that answers an item in the same batch silences it too.
        model.deliver([
            finished("m2"),
            TransportMessage(
                id: "c2", title: ControlEvent.title, body: "clear abc12345",
                footer: "", date: Date()),
        ])
        XCTAssertEqual(isolated.poster.requests.count, 0, "a banner for a row that was already cleared")
        XCTAssertEqual(model.store.unread.count, 0)
    }

    func testTheMarkReadActionIsRegisteredUnderTheCategoryEveryBannerCarries() {
        model.notifier.registerCategories()
        let category = isolated.poster.categories.first { $0.identifier == Notifier.categoryID }
        XCTAssertEqual(category?.actions.map(\.identifier), [Notifier.readAction])
    }
}

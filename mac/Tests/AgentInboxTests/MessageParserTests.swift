import XCTest
@testable import AgentInbox

/// The wire format is a contract with `notify.sh`. If these break, the app
/// silently shows blank rows, so they are the first thing to protect.
final class MessageParserTests: XCTestCase {
    func testGeneratedTopicsAreUnguessableAndUnique() {
        let a = AppSettings.randomNtfyTopic()
        let b = AppSettings.randomNtfyTopic()
        XCTAssertNotEqual(a, b, "a fixed topic would put every user on one channel")
        XCTAssertTrue(a.hasPrefix("agent-inbox-"))
        // The topic is the only secret protecting message bodies, so the
        // random tail has to be long: 12 bytes as hex.
        let tail = a.split(separator: "-").last.map(String.init) ?? ""
        XCTAssertEqual(tail.count, 24, "expected 24 hex chars, got \(tail)")
        XCTAssertTrue(tail.allSatisfy { $0.isHexDigit })
        // ntfy topics are used in a URL path.
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, a)
    }


    func testParsesFinishedTitleWithDuration() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("✅ ideaplaces-devops @ mac (4m 19s)"))
        XCTAssertEqual(head.kind, .finished)
        XCTAssertEqual(head.repo, "ideaplaces-devops")
        XCTAssertEqual(head.host, "mac")
        XCTAssertEqual(head.duration, "4m 19s")
    }

    func testParsesNeedsYouTitleWithoutDuration() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("🖐️ my-app @ devbox"))
        XCTAssertEqual(head.kind, .needsYou)
        XCTAssertEqual(head.repo, "my-app")
        XCTAssertEqual(head.host, "devbox")
        XCTAssertNil(head.duration)
    }

    func testAcceptsHandWithoutVariationSelector() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("🖐 my-app @ devbox"))
        XCTAssertEqual(head.kind, .needsYou)
        XCTAssertEqual(head.repo, "my-app")
    }

    func testRejectsTitleWithoutKnownKind() {
        XCTAssertNil(MessageParser.parseTitle("Deploy finished @ mac"))
    }

    func testRepoNamesContainingAtSurviveParsing() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("✅ scope@pkg @ mac (1m 0s)"))
        XCTAssertEqual(head.repo, "scope@pkg")
        XCTAssertEqual(head.host, "mac")
    }

    func testParsesFooter() {
        let foot = MessageParser.parseFooter("session a1b2c3d4 · /Users/me/my-app")
        XCTAssertEqual(foot.session, "a1b2c3d4")
        XCTAssertEqual(foot.cwd, "/Users/me/my-app")
    }

    func testFooterWithoutSessionStillYieldsPath() {
        let foot = MessageParser.parseFooter("/Users/me/my-app")
        XCTAssertNil(foot.session)
        XCTAssertEqual(foot.cwd, "/Users/me/my-app")
    }

    func testParsesFullNotificationMessage() throws {
        let message = TransportMessage(
            id: "42",
            title: "🖐️ checkout @ devbox",
            body: """
            🧵 Refactor the checkout flow to use the new payments SDK
            🗣 ok now handle the refund path too
            Claude needs your permission to use Bash
            ❯ Should I run the migration against staging first?
            """,
            footer: "session a1b2c3d4 · /home/me/checkout",
            date: Date(timeIntervalSince1970: 1_700_000_000))

        let item = try XCTUnwrap(MessageParser.parse(message, presence: 120))
        XCTAssertEqual(item.kind, .needsYou)
        XCTAssertEqual(item.repo, "checkout")
        XCTAssertEqual(item.host, "devbox")
        XCTAssertEqual(item.summary, "Refactor the checkout flow to use the new payments SDK")
        XCTAssertEqual(item.ask, "ok now handle the refund path too")
        XCTAssertEqual(item.detail, "Claude needs your permission to use Bash")
        XCTAssertEqual(item.waitingOn, "Should I run the migration against staging first?")
        XCTAssertEqual(item.cwd, "/home/me/checkout")
        XCTAssertEqual(item.presenceAtArrival, 120)
        // The row shows the newest thing you said, not the oldest.
        XCTAssertEqual(item.subtitle, "ok now handle the refund path too")
    }

    func testUnparseableTitleYieldsNoItem() {
        let message = TransportMessage(
            id: "1", title: "hello", body: "", footer: "", date: Date())
        XCTAssertNil(MessageParser.parse(message, presence: 0))
    }

    func testNtfyBodySplitsTrailingFooterLine() {
        let (body, footer) = NtfyTransport.splitFooter("""
        🧵 doing a thing
        line two
        session abcd1234 · /Users/me/repo
        """)
        XCTAssertEqual(body, "🧵 doing a thing\nline two")
        XCTAssertEqual(footer, "session abcd1234 · /Users/me/repo")
    }

    func testNtfyBodyWithoutFooterIsLeftIntact() {
        let (body, footer) = NtfyTransport.splitFooter("just a body")
        XCTAssertEqual(body, "just a body")
        XCTAssertEqual(footer, "")
    }

}

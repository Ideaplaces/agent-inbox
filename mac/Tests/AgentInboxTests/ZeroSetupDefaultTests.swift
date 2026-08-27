import XCTest
@testable import AgentInbox

/// Installing this should require no account, no server and no decision.
///
/// That property is the reason anyone tries it, and it is the kind that rots
/// quietly: nothing fails loudly when a default moves, the next person just
/// lands on a setup screen instead of a working inbox.
final class ZeroSetupDefaultTests: XCTestCase {
    func testTheDefaultServerIsTheFreePublicOne() {
        // A self-hosted instance is a choice, never the starting point.
        XCTAssertEqual(AppSettings.publicNtfyServer, "https://ntfy.sh")
        XCTAssertEqual(SenderSnapshot(transport: .ntfy).ntfyServer, AppSettings.publicNtfyServer)
    }

    func testTheDefaultNeedsNoToken() {
        // ntfy.sh has no accounts. An empty token means no Authorization header
        // at all, rather than an empty bearer, which a server would reject.
        XCTAssertEqual(SenderSnapshot(transport: .ntfy).ntfyToken, "")
    }

    func testAGeneratedTopicIsTheSecretSoItHasToBeUnguessable() {
        // The topic is the only thing protecting messages on the public server,
        // so it carries real entropy rather than being a readable name.
        let topic = AppSettings.randomNtfyTopic()
        XCTAssertTrue(topic.hasPrefix("agent-inbox-"))
        let random = topic.split(separator: "-").last.map(String.init) ?? ""
        XCTAssertEqual(random.count, 24, "96 bits, hex encoded")
        XCTAssertTrue(random.allSatisfy(\.isHexDigit))
    }

    func testTwoInstallsDoNotShareATopic() {
        let topics = Set((0..<50).map { _ in AppSettings.randomNtfyTopic() })
        XCTAssertEqual(topics.count, 50)
    }

    func testAGeneratedTopicSurvivesBeingPutInAURL() {
        // It is appended straight to the server URL by both the app and
        // notify.sh, so anything needing escaping would break the send.
        let topic = AppSettings.randomNtfyTopic()
        XCTAssertEqual(topic.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), topic)
    }
}

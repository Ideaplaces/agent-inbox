import XCTest
@testable import AgentInbox

/// Agents write markdown. The menu showed `**like this**` with the asterisks
/// still in it, which is how this surfaced.
final class MarkdownTextTests: XCTestCase {
    func testBoldMarkersAreRemovedFromPlainText() {
        XCTAssertEqual(
            MarkdownText.plain("**Open the menu** and tell me"),
            "Open the menu and tell me")
    }

    func testInlineCodeMarkersAreRemoved() {
        XCTAssertEqual(MarkdownText.plain("run `npm test` first"), "run npm test first")
    }

    func testItalicAndBoldTogether() {
        XCTAssertEqual(MarkdownText.plain("*a* and **b**"), "a and b")
    }

    func testALineStartingWithADashStaysALineNotAList() {
        // Block parsing would restructure this. Inline-only keeps the text as
        // written, which is what a message snippet needs.
        let text = "- first\n- second"
        XCTAssertEqual(MarkdownText.plain(text), text)
    }

    func testALineStartingWithAHashIsNotTurnedIntoAHeading() {
        // Tags start with #, so this one matters here more than most.
        XCTAssertEqual(MarkdownText.plain("#notify this one"), "#notify this one")
    }

    func testUnbalancedMarkersKeepTheirText() {
        // Half a bold marker must not swallow the sentence.
        let text = "this is **not closed"
        XCTAssertTrue(MarkdownText.plain(text).contains("not closed"), MarkdownText.plain(text))
    }

    func testPlainTextIsUntouched() {
        let text = "Claude needs your permission to use Bash"
        XCTAssertEqual(MarkdownText.plain(text), text)
    }

    func testNewlinesSurvive() {
        XCTAssertEqual(MarkdownText.plain("one\ntwo"), "one\ntwo")
    }

    func testAttributedKeepsTheSameCharacters() {
        // Whatever the styling, the words a reader sees must not change.
        let raw = "**bold** and `code`"
        XCTAssertEqual(String(MarkdownText.attributed(raw).characters), MarkdownText.plain(raw))
    }

    func testEmptyStringIsSafe() {
        XCTAssertEqual(MarkdownText.plain(""), "")
    }
}

import XCTest
@testable import AgentInbox

/// The pane read as though the watch tags only existed in tagged mode and the
/// mute tag only in every-conversation mode. The sender does not work that way:
/// the mode is the default for a conversation with no tag, and both tags
/// override it in both modes.
final class ReportModeCopyTests: XCTestCase {
    func testEveryModeSaysWhatAnUntaggedConversationDoes() {
        XCTAssertTrue(AppSettings.reportModeCaption(watchMode: "all").contains("reports"))
        XCTAssertTrue(AppSettings.reportModeCaption(watchMode: "tagged").contains("silent"))
    }

    func testBothModesSayTheTagsWinOverTheDefault() {
        for mode in ["all", "tagged"] {
            XCTAssertTrue(
                AppSettings.reportModeCaption(watchMode: mode).contains("only the default"),
                "\(mode) must not present the mode as the whole rule")
        }
    }

    func testEachTagGetsADifferentJobInEachMode() {
        XCTAssertNotEqual(
            AppSettings.watchTagCaption(watchMode: "all"),
            AppSettings.watchTagCaption(watchMode: "tagged"))
        XCTAssertNotEqual(
            AppSettings.muteTagCaption(watchMode: "all"),
            AppSettings.muteTagCaption(watchMode: "tagged"))
    }

    func testNeitherTagIsEverDescribedAsDoingNothing() {
        // Both stay live in both modes. A caption saying otherwise would send
        // someone looking for a bug in notify.sh that is not there.
        let captions = ["all", "tagged"].flatMap {
            [AppSettings.watchTagCaption(watchMode: $0), AppSettings.muteTagCaption(watchMode: $0)]
        }
        for caption in captions {
            XCTAssertFalse(caption.isEmpty)
            XCTAssertFalse(caption.lowercased().contains("ignored"))
            XCTAssertFalse(caption.lowercased().contains("no effect"))
        }
    }
}

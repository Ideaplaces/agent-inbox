import XCTest
@testable import AgentInbox

/// The Transport pane told everyone the topic name was the only thing
/// protecting their messages. On a server that authenticates, that is both
/// wrong and the opposite of reassuring.
final class AccessModelTests: XCTestCase {
    private let selfHosted = "https://ntfy.example.com:8443"

    func testOnThePublicServerTheTopicIsTheSecret() {
        XCTAssertEqual(
            AppSettings.accessModel(server: AppSettings.publicNtfyServer, token: ""),
            .topicIsTheSecret)
    }

    func testASelfHostedServerReachedAnonymouslyIsNoDifferent() {
        XCTAssertEqual(
            AppSettings.accessModel(server: selfHosted, token: ""),
            .topicIsTheSecret)
    }

    func testATokenMovesTheSecretOffTheTopic() {
        XCTAssertEqual(
            AppSettings.accessModel(server: selfHosted, token: "tk_abc"),
            .tokenIsTheSecret)
    }

    func testATokenLeftOverFromAPreviousServerChangesNothingOnNtfySh() {
        // The field is hidden while the server is ntfy.sh, so claiming a token
        // protects them would point at something they cannot see.
        XCTAssertEqual(
            AppSettings.accessModel(server: AppSettings.publicNtfyServer, token: "tk_abc"),
            .topicIsTheSecret)
    }

    func testTheThreeStatesEachGetTheirOwnExplanation() {
        let publicServer = SettingsCopy.topicExplanation(
            server: AppSettings.publicNtfyServer, token: "")
        let anonymous = SettingsCopy.topicExplanation(server: selfHosted, token: "")
        let authenticated = SettingsCopy.topicExplanation(server: selfHosted, token: "tk_abc")

        XCTAssertEqual(Set([publicServer, anonymous, authenticated]).count, 3)
        XCTAssertTrue(publicServer.contains("ntfy.sh"))
        XCTAssertTrue(anonymous.contains("No token"))
        XCTAssertTrue(authenticated.contains("token is the secret"))
    }

    func testTheIntroStopsClaimingNothingHasToBeProvisioned() {
        // True of ntfy.sh, and the first thing a self-hosted server contradicts.
        XCTAssertTrue(
            SettingsCopy.transportIntro(server: AppSettings.publicNtfyServer)
                .contains("No account, no bot"))
        XCTAssertFalse(
            SettingsCopy.transportIntro(server: selfHosted).contains("No account, no bot"))
    }
}

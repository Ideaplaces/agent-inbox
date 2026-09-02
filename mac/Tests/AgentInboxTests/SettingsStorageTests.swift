import XCTest
@testable import AgentInbox

/// Settings used to be twenty-five UserDefaults keys, each written by its own
/// `didSet`. They are one JSON snapshot now. An install upgrading across that
/// line must come up showing exactly what it showed before, and a fresh one
/// must land on the same defaults it always did.
@MainActor
final class SettingsStorageTests: XCTestCase {
    private var scratch: IsolatedSettings!

    override func setUp() {
        super.setUp()
        scratch = IsolatedSettings("storage")
    }

    override func tearDown() {
        scratch.remove()
        super.tearDown()
    }

    func testAFreshInstallGetsTheDocumentedDefaults() {
        let s = scratch.settings()
        XCTAssertEqual(s.transport, .none)
        XCTAssertEqual(s.ntfyServer, "https://ntfy.sh")
        XCTAssertEqual(s.ntfyTopic, "")
        XCTAssertEqual(s.ntfyToken, "")
        XCTAssertEqual(s.expireMinutes, 5)
        XCTAssertEqual(s.idleThreshold, 90)
        XCTAssertEqual(s.minSeconds, 0, "a floor above zero silences the first hello")
        XCTAssertEqual(s.watchMode, "all")
        XCTAssertEqual(s.watchTags, AppSettings.defaultWatchTags)
        XCTAssertEqual(s.muteTag, AppSettings.defaultMuteTag)
        XCTAssertEqual(s.soundName, "Pop")
        XCTAssertEqual(s.hostLabel, Host.current().localizedName ?? "mac")
        XCTAssertFalse(s.hasCompletedOnboarding)
        XCTAssertFalse(s.hasDecidedLoginItem)
        XCTAssertFalse(s.shareUsageData)
        XCTAssertEqual(s.analyticsID, "")
        XCTAssertNil(s.analyticsLastSent)
        XCTAssertEqual(s.pendingFinished, 0)
        XCTAssertEqual(s.pendingNeedsYou, 0)
    }

    func testTheOldFlatKeysAreMigratedOnFirstLoad() {
        let d = scratch.defaults
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        d.set("ntfy", forKey: "transport")
        d.set("https://ntfy.example.com:8443", forKey: "ntfyServer")
        d.set("agent-inbox-you-abc", forKey: "ntfyTopic")
        d.set(0, forKey: "expireMinutes")
        d.set(120, forKey: "idleThreshold")
        d.set("", forKey: "soundName")
        d.set(45, forKey: "minSeconds")
        d.set("tagged", forKey: "watchMode")
        d.set("#ping #follow", forKey: "watchTags")
        d.set("#quiet", forKey: "muteTag")
        d.set("devbox", forKey: "hostLabel")
        d.set(true, forKey: "hasCompletedOnboarding")
        d.set(true, forKey: "hasDecidedLoginItem")
        d.set(true, forKey: "shareUsageData")
        d.set("an-id", forKey: "analyticsID")
        d.set(sent, forKey: "analyticsLastSent")
        d.set(7, forKey: "pendingFinished")
        d.set(3, forKey: "pendingNeedsYou")

        let s = scratch.settings()
        XCTAssertEqual(s.transport, .ntfy)
        XCTAssertEqual(s.ntfyServer, "https://ntfy.example.com:8443")
        XCTAssertEqual(s.ntfyTopic, "agent-inbox-you-abc")
        // Zero is "never", a value someone chose, and must not become the default 5.
        XCTAssertEqual(s.expireMinutes, 0)
        XCTAssertEqual(s.idleThreshold, 120)
        XCTAssertEqual(s.soundName, "", "silent was chosen and is not the same as unset")
        XCTAssertEqual(s.minSeconds, 45)
        XCTAssertEqual(s.watchMode, "tagged")
        XCTAssertEqual(s.watchTags, "#ping #follow")
        XCTAssertEqual(s.muteTag, "#quiet")
        XCTAssertEqual(s.hostLabel, "devbox")
        XCTAssertTrue(s.hasCompletedOnboarding)
        XCTAssertTrue(s.hasDecidedLoginItem)
        XCTAssertTrue(s.shareUsageData)
        XCTAssertEqual(s.analyticsID, "an-id")
        XCTAssertEqual(s.analyticsLastSent, sent)
        XCTAssertEqual(s.pendingFinished, 7)
        XCTAssertEqual(s.pendingNeedsYou, 3)

        // Migrated once: the snapshot is what a second load reads, so a flat
        // key changed afterwards is not seen.
        XCTAssertNotNil(d.data(forKey: AppSettings.storageKey))
        d.set("nobody", forKey: "hostLabel")
        XCTAssertEqual(scratch.settings().hostLabel, "devbox")
    }

    func testAChangeSurvivesARestart() {
        let first = scratch.settings()
        first.expireMinutes = 30
        first.shareUsageData = true
        let id = first.analyticsID
        XCTAssertFalse(id.isEmpty, "switching sharing on mints an id")

        let second = scratch.settings()
        XCTAssertEqual(second.expireMinutes, 30)
        XCTAssertTrue(second.shareUsageData)
        XCTAssertEqual(second.analyticsID, id)
    }

    /// A field added to `SettingsValues` later is absent from every snapshot
    /// already on disk. That must read as the field's default, not as a
    /// decode failure that throws every other setting away with it.
    func testASnapshotMissingAFieldDecodesWithTheDefault() throws {
        let json = Data(#"{"transport":"ntfy","ntfyTopic":"t","expireMinutes":15}"#.utf8)
        let values = try JSONDecoder().decode(SettingsValues.self, from: json)
        XCTAssertEqual(values.transport, .ntfy)
        XCTAssertEqual(values.ntfyTopic, "t")
        XCTAssertEqual(values.expireMinutes, 15)
        XCTAssertEqual(values.idleThreshold, 90)
        XCTAssertEqual(values.watchTags, AppSettings.defaultWatchTags)
    }

    func testTheTokenStaysOutOfTheSnapshot() throws {
        let s = scratch.settings()
        s.ntfyServer = "https://ntfy.example.com:8443"
        s.ntfyToken = "tk_secret"
        let stored = try XCTUnwrap(scratch.defaults.data(forKey: AppSettings.storageKey))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("tk_secret"))
        XCTAssertEqual(scratch.secrets.get("ntfy-token"), "tk_secret")
        XCTAssertEqual(scratch.settings().ntfyToken, "tk_secret")
    }

    /// The shell config is parsed by the hooks on every turn, so it is written
    /// only when something in it changed. A sound is not in it.
    func testOnlyASenderVisibleChangeRewritesTheShellConfig() throws {
        let s = scratch.settings()
        s.transport = .ntfy
        s.ntfyTopic = "t"
        let config = scratch.directory.appendingPathComponent("config")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))

        try FileManager.default.removeItem(at: config)
        s.soundName = "Glass"
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: config.path),
            "a sound change rewrote the sender config")

        s.minSeconds = 10
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("MIN_SECONDS=10"), text)
    }
}

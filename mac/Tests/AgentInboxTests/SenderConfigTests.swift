import XCTest
@testable import AgentInbox

final class SenderConfigTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SenderConfig.directory = tempDir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeConfig(_ text: String) throws {
        try text.write(
            to: tempDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    func testReadsQuotedAndUnquotedValuesAndSkipsComments() throws {
        try writeConfig("""
        # a comment
        MIN_SECONDS=45
        HOST_LABEL="devbox"
        NOTIFY_SOUND=''
        NTFY_SERVER=https://ntfy.example.com
        """)
        let pairs = Dictionary(uniqueKeysWithValues: SenderConfig.readShellConfig())
        XCTAssertEqual(pairs["MIN_SECONDS"], "45")
        XCTAssertEqual(pairs["HOST_LABEL"], "devbox")
        XCTAssertEqual(pairs["NOTIFY_SOUND"], "")
        XCTAssertEqual(pairs["NTFY_SERVER"], "https://ntfy.example.com")
    }

    func testValuesContainingEqualsAreKeptWhole() throws {
        try writeConfig("WEBHOOK=https://example.com/a?b=c")
        let pairs = Dictionary(uniqueKeysWithValues: SenderConfig.readShellConfig())
        XCTAssertEqual(pairs["WEBHOOK"], "https://example.com/a?b=c")
    }

    func testWatchModeIsWrittenSoTheSenderCanSeeIt() throws {
        // The app rewrites this file wholesale, so anything the senders read
        // has to be a field here or it gets erased on the next change.
        SenderConfig.write(SenderSnapshot(transport: .ntfy, ntfyTopic: "t", watchMode: "tagged"))
        let written = try String(
            contentsOf: tempDir.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(written.contains("WATCH_MODE=tagged"), written)
    }

    func testWatchModeRoundTripsFromAShellConfig() throws {
        try writeConfig("WATCH_MODE=tagged\nMIN_SECONDS=30\n")
        let pairs = Dictionary(uniqueKeysWithValues: SenderConfig.readShellConfig())
        XCTAssertEqual(pairs["WATCH_MODE"], "tagged")
    }

    func testTagsAreWrittenQuotedSoAShellCanReadThem() throws {
        SenderConfig.write(SenderSnapshot(
            transport: .ntfy, ntfyTopic: "t",
            watchTags: "#ping #follow", muteTag: "#quiet"))
        let written = try String(
            contentsOf: tempDir.appendingPathComponent("config"), encoding: .utf8)
        // Unquoted these would still parse, but quoting removes any doubt
        // about a value that begins with the shell comment character.
        XCTAssertTrue(written.contains("WATCH_TAGS=\"#ping #follow\""), written)
        XCTAssertTrue(written.contains("MUTE_TAG=\"#quiet\""), written)
    }

    func testTagsRoundTripFromAShellConfig() throws {
        try writeConfig("WATCH_TAGS=\"#ping #follow\"\nMUTE_TAG=\"#quiet\"\n")
        let pairs = Dictionary(uniqueKeysWithValues: SenderConfig.readShellConfig())
        XCTAssertEqual(pairs["WATCH_TAGS"], "#ping #follow")
        XCTAssertEqual(pairs["MUTE_TAG"], "#quiet")
    }

    func testTagNormalizationKeepsPhrasesIntact() {
        // A comma means the tags are phrases, so the spaces inside one are
        // part of the tag. Losing them is what made "watch this" match the
        // word "this" on its own.
        XCTAssertEqual(
            AppSettings.normalizeTags("  watch this ,  notify me  "),
            "watch this, notify me")
        // No comma means the older space separated form.
        XCTAssertEqual(
            AppSettings.normalizeTags("  #ping   #follow "),
            "#ping #follow")
        XCTAssertEqual(AppSettings.normalizeTags("   "), "")
        XCTAssertEqual(AppSettings.normalizeTags("#a, , #b"), "#a, #b")
    }

    func testShippedDefaultsCarryASpokenForm() {
        // Dictation cannot produce a "#", so a default set of typed-only tags
        // would leave a voice user with no way to tag anything.
        XCTAssertTrue(AppSettings.defaultWatchTags.contains("watch this"))
        XCTAssertTrue(AppSettings.defaultMuteTag.contains("stop notifying"))
        XCTAssertTrue(AppSettings.defaultWatchTags.contains("#notify"))
        XCTAssertTrue(AppSettings.defaultMuteTag.contains("#mute"))
    }

    func testHandWrittenConfigIsBackedUpOnceBeforeBeingReplaced() throws {
        try writeConfig("HOST_LABEL=\"mine\"\nCUSTOM=keepme\n")
        let settings = SenderSnapshot(transport: .ntfy, ntfyTopic: "t")
        SenderConfig.write(settings)

        let backup = tempDir.appendingPathComponent("config.bak.agent-inbox")
        let saved = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(saved.contains("CUSTOM=keepme"))

        // A second write must not overwrite the backup with our own output.
        SenderConfig.write(settings)
        let stillSaved = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertEqual(saved, stillSaved)
    }
}


/// The token the sender needs to publish to a self-hosted ntfy.
///
/// It is a credential, so it must not land in `config`, which is written 0644
/// so a sender running as another user can read it. And it has to disappear
/// when it is cleared: `notify.sh` tests the file with `-s`, so a blanked file
/// is harmless, but a stale one left behind after moving back to ntfy.sh would
/// be sent to a server that never asked for it.
@MainActor
final class NtfyTokenConfigTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        SenderConfig.directory = dir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(token: String) {
        SenderConfig.write(
            SenderSnapshot(transport: .ntfy, ntfyTopic: "agent-inbox",
                           ntfyServer: "https://ntfy.example.com:8443", ntfyToken: token))
    }

    private func contents(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheTokenIsWrittenWhereTheSenderLooksForIt() {
        write(token: "tk_abc123")
        XCTAssertEqual(contents("ntfy-token"), "tk_abc123")
        XCTAssertEqual(contents("ntfy-topic"), "agent-inbox")
    }

    func testTheTokenNeverLandsInTheWorldReadableConfig() {
        write(token: "tk_abc123")
        XCTAssertFalse(contents("config")?.contains("tk_abc123") ?? false)
    }

    func testTheTokenFileIsNotWorldReadable() {
        write(token: "tk_abc123")
        let mode = (try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("ntfy-token").path)[.posixPermissions]) as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    func testClearingTheTokenRemovesTheFileRatherThanBlankingIt() {
        write(token: "tk_abc123")
        write(token: "")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("ntfy-token").path))
    }

    func testTheServerStillReachesTheSender() {
        write(token: "tk_abc123")
        XCTAssertTrue(contents("config")?.contains("https://ntfy.example.com:8443") ?? false)
    }
}


/// Switching transport has to leave the disk saying one thing.
///
/// `notify.sh` sends to whatever it finds in `~/.agent-inbox/`, so a file left
/// behind by a transport nobody selected any more is not inert: it keeps
/// publishing. Moving the app from Discord to ntfy left every session going to
/// both for days, and nothing anywhere showed it.
@MainActor
final class TransportFileRetirementTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        SenderConfig.directory = dir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testAnInstallThatUsedDiscordStopsPublishingToIt() throws {
        // The Discord transport is gone, but a machine that used it still has
        // its files on disk, and notify.sh posts to whatever it finds. Removing
        // the transport without clearing them would leave the app quiet about
        // Discord while every session kept sending there.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["webhook-url", "channel-id", "guild-id"] {
            try "leftover".write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(exists("webhook-url"))

        SenderConfig.write(SenderSnapshot(transport: .ntfy, ntfyTopic: "t", ntfyToken: "tk"))
        XCTAssertFalse(exists("webhook-url"), "the sender would still be posting to Discord")
        XCTAssertFalse(exists("channel-id"))
        XCTAssertFalse(exists("guild-id"))
        XCTAssertTrue(exists("ntfy-topic"))
        XCTAssertTrue(exists("ntfy-token"))
    }

    func testChoosingNoTransportLeavesNothingBehindToSendWith() {
        SenderConfig.write(SenderSnapshot(transport: .ntfy, ntfyTopic: "t", ntfyToken: "tk"))
        SenderConfig.write(SenderSnapshot(transport: .none))
        XCTAssertFalse(exists("ntfy-topic"))
        XCTAssertFalse(exists("ntfy-token"))
        XCTAssertFalse(exists("webhook-url"))
    }
}

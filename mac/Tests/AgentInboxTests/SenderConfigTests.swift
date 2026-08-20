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

    func testTagNormalizationTidiesWhatTheUserTyped() {
        // Commas and stray whitespace are what people actually type; the
        // sender splits on spaces, so store what it will split on.
        XCTAssertEqual(
            AppSettings.normalizeTags("  #ping,  #follow   #watch "),
            "#ping #follow #watch")
        XCTAssertEqual(AppSettings.normalizeTags("   "), "")
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

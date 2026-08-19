import XCTest
@testable import AgentInbox

/// `~/.claude/settings.json` is a file the user also edits by hand. Every one
/// of these tests exists because getting it wrong breaks somebody's setup.
final class HookInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var settingsURL: URL!
    private let script = URL(fileURLWithPath: "/Users/me/.agent-inbox/bin/notify.sh")

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsURL = tempDir.appendingPathComponent("settings.json")
        HookInstaller.settingsURL = settingsURL
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String) throws {
        try json.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testInstallsThreeHooksIntoAnEmptyFile() throws {
        try HookInstaller.install(script: script)
        let root = try read()
        XCTAssertEqual(commands(root, "UserPromptSubmit"),
                       ["bash \"\(script.path)\" prompt"])
        XCTAssertEqual(commands(root, "Stop"), ["bash \"\(script.path)\" stop"])
        XCTAssertEqual(commands(root, "Notification"), ["bash \"\(script.path)\" notification"])
        XCTAssertTrue(HookInstaller.isInstalled())
    }

    func testPreservesUnrelatedSettingsAndHooks() throws {
        try write("""
        {
          "model": "opus",
          "hooks": {
            "PostToolUse": [
              {"matcher": "Edit", "hooks": [{"type": "command", "command": "./autopush.sh"}]}
            ]
          }
        }
        """)
        try HookInstaller.install(script: script)
        let root = try read()
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual(commands(root, "PostToolUse"), ["./autopush.sh"])
        XCTAssertEqual(commands(root, "Stop").count, 1)
    }

    func testInstallingTwiceDoesNotDuplicate() throws {
        try HookInstaller.install(script: script)
        try HookInstaller.install(script: script)
        let root = try read()
        XCTAssertEqual(commands(root, "Stop"), ["bash \"\(script.path)\" stop"])
    }

    func testReplacesHooksFromAnOlderShellInstall() throws {
        try write("""
        {
          "hooks": {
            "Stop": [
              {"hooks": [{"type": "command", "command": "bash \\"$HOME/repos/agent-inbox/notify.sh\\" stop"}]}
            ]
          }
        }
        """)
        try HookInstaller.install(script: script)
        let root = try read()
        // Exactly one Stop hook, and it is ours.
        XCTAssertEqual(commands(root, "Stop"), ["bash \"\(script.path)\" stop"])
    }

    func testDetectsForeignHookPaths() throws {
        try write("""
        {
          "hooks": {
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash \\"/other/notify.sh\\" prompt"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "bash \\"/other/notify.sh\\" stop"}]}],
            "Notification": [{"hooks": [{"type": "command", "command": "bash \\"/other/notify.sh\\" notification"}]}]
          }
        }
        """)
        // All three present, so the hooks read as installed even though they
        // belong to a different install. That is what hasForeignHooks catches.
        XCTAssertTrue(HookInstaller.isInstalled())
        XCTAssertEqual(HookInstaller.installedScriptPaths().count, 3)
    }

    func testUninstallRemovesOnlyOurHooks() throws {
        try write("""
        {
          "hooks": {
            "PostToolUse": [{"hooks": [{"type": "command", "command": "./autopush.sh"}]}]
          }
        }
        """)
        try HookInstaller.install(script: script)
        try HookInstaller.uninstall()
        let root = try read()
        XCTAssertFalse(HookInstaller.isInstalled())
        XCTAssertEqual(commands(root, "PostToolUse"), ["./autopush.sh"])
        XCTAssertTrue(commands(root, "Stop").isEmpty)
    }

    func testBacksUpTheExistingFileBeforeWriting() throws {
        try write("{\"model\": \"opus\"}")
        try HookInstaller.install(script: script)
        let backup = tempDir.appendingPathComponent("settings.json.bak.agent-inbox")
        let contents = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(contents.contains("opus"))
        XCTAssertFalse(contents.contains("notify.sh"))
    }

    func testMalformedSettingsFileIsReportedNotOverwritten() throws {
        try write("{ not json")
        XCTAssertThrowsError(try HookInstaller.install(script: script))
        let contents = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertEqual(contents, "{ not json")
    }
}

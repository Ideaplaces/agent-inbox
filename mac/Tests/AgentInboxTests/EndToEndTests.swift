import XCTest
@testable import AgentInbox

/// The whole path with nothing faked in the middle: the real `notify.sh`
/// runs as a Claude Code hook would run it, posts with curl to a fake ntfy on
/// localhost, the real `NtfyTransport` reads it off a held-open stream, and
/// the real pipeline turns it into a row in the store and a banner. Then the
/// sender reports that you typed, and the row goes.
///
/// Two shipped bugs would have failed here and passed everywhere else. The
/// `"$BODY💬"` expansion silently dropped the context lines from every
/// message, and the sender's own tests read the same dry-run output the
/// bug produced. A contract line the app could not read fell back to the
/// emoji heuristics without a word, and the parser tests passed because they
/// were fed a contract written by hand in Swift rather than the one jq writes
/// in bash. Bash assembles and Swift disassembles, and the only test that
/// notices the two disagreeing is one that runs both.
@MainActor
final class EndToEndTests: XCTestCase {
    private let topic = "e2e-topic"
    private let sessionID = "e2e01234-5678-90ab-cdef-000000000000"
    private let closingSentence = "Refunds are wired up and the tests pass on the new path."

    private var server: FakeNtfyServer!
    private var isolated: IsolatedSettings!
    private var model: AppModel!
    private var sandbox: URL!
    private var home: URL { sandbox.appendingPathComponent("home") }
    private var cwd: URL { sandbox.appendingPathComponent("work/refund-service") }
    private var transcript: URL { sandbox.appendingPathComponent("transcript.jsonl") }

    /// The sender at the repo root, two directories above `mac/`.
    private static let notifyScript = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AgentInboxTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("notify.sh")

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(Self.isOnPath("jq"), "notify.sh needs jq")

        server = FakeNtfyServer()
        try await server.start()

        // The app: an isolated model whose transport points at the fake.
        isolated = IsolatedSettings("e2e")
        let settings = isolated.settings()
        settings.ntfyServer = server.baseURL
        settings.ntfyTopic = topic
        settings.transport = .ntfy
        model = AppModel(settings: settings, defaults: isolated.defaults, poster: isolated.poster)

        // The sender's machine: a HOME of its own, configured as install.sh
        // would leave it, a working directory and a transcript.
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-inbox-e2e-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".agent-inbox")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try "NTFY_SERVER=\(server.baseURL)\nHOST_LABEL=devbox\nMIN_SECONDS=0\n"
            .write(to: config.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try topic.write(to: config.appendingPathComponent("ntfy-topic"), atomically: true, encoding: .utf8)
        try """
        {"type":"ai-title","aiTitle":"Wire the checkout refunds"}
        {"type":"user","message":{"role":"user","content":"please wire the refund path"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\(closingSentence)"}]}}

        """.write(to: transcript, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        model?.receiver.stop()
        server?.stop()
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        isolated?.remove()
        super.tearDown()
    }

    private static func isOnPath(_ tool: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
    }

    /// Run the sender the way the hook does: the kind as `$1`, the hook's
    /// JSON on stdin, HOME pointing at the sandbox, and no dry run.
    private func runSender(_ kind: String, prompt: String? = nil) throws {
        var hook = ["session_id": sessionID, "cwd": cwd.path, "transcript_path": transcript.path]
        if let prompt { hook["prompt"] = prompt }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "AGENT_INBOX_DRY_RUN")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.notifyScript.path, kind]
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: hook))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "notify.sh must never fail a session")
    }

    func testAFinishedTurnBecomesARowAndTypingIntoItClearsTheRow() async throws {
        model.receiver.start()
        await eventually { model.receiver.status.isHealthy }
        XCTAssertTrue(model.receiver.status.isHealthy, "the receiver never connected: \(model.receiver.status)")

        // The turn: a prompt so the start time is known, then the stop.
        try runSender("prompt", prompt: "please wire the refund path")
        try runSender("stop")

        await eventually { model.store.unread.count == 1 }
        let item = try XCTUnwrap(model.store.unread.first, "nothing arrived: \(server.received)")
        XCTAssertEqual(item.kind, .finished)
        XCTAssertEqual(item.repo, "refund-service")
        XCTAssertEqual(item.host, "devbox", "HOST_LABEL from the sender's config")
        XCTAssertEqual(item.summary, "Wire the checkout refunds", "the ai-title line")
        XCTAssertEqual(item.ask, "please wire the refund path")
        XCTAssertEqual(item.closing, closingSentence)
        XCTAssertNil(item.detail, "detail is the fallback for a turn with no prose to reduce")
        XCTAssertNil(item.waitingOn)
        XCTAssertEqual(item.sessionID, "e2e01234", "the first eight characters, as the footer carries them")
        XCTAssertEqual(item.cwd, cwd.path)
        let elapsed = try XCTUnwrap(item.elapsed)
        XCTAssertTrue((0...5).contains(elapsed), "two hook runs back to back: \(elapsed)s")
        XCTAssertEqual(item.duration, "0m \(elapsed)s")
        XCTAssertTrue(item.isShortTurn)

        // What went over the wire was a contract the app could read, and it
        // was the contract that produced the row, not the lines above it.
        let post = try XCTUnwrap(server.received.first { $0.method == "POST" })
        XCTAssertEqual(post.path, "/\(topic)")
        XCTAssertEqual(post.headers["title"], "✅ refund-service @ devbox (0m \(elapsed)s)")
        XCTAssertEqual(post.headers["priority"], "default")
        let (body, footer) = NtfyTransport.splitFooter(post.body)
        let parsed = MessageParser.parseWithOutcome(
            TransportMessage(id: "wire", title: post.headers["title"] ?? "", body: body,
                             footer: footer, date: Date()),
            presence: 0)
        XCTAssertEqual(parsed.outcome, .contract)
        XCTAssertEqual(
            body.split(separator: "\n").map(String.init).dropLast(2),
            [
                "🧵 Wire the checkout refunds",
                "🗣 please wire the refund path",
                "💬 \(closingSentence)",
            ],
            "the human lines, all three of them, above the footer and the contract")

        // One banner, for this row.
        XCTAssertEqual(isolated.poster.requests.map(\.identifier), [item.id])
        XCTAssertEqual(isolated.poster.requests.first?.content.title, "✅ refund-service @ devbox (0m \(elapsed)s)")

        // Typing into the conversation: the sender publishes a clear and the
        // row is answered by the fact that you are there.
        try runSender("prompt", prompt: "thanks, now the tests")
        await eventually { model.store.unread.isEmpty }
        XCTAssertEqual(model.store.unread.count, 0, "the control event did not retire the row")
        XCTAssertEqual(model.store.item(id: item.id)?.isRead, true)
        let control = try XCTUnwrap(server.received.last { $0.method == "POST" })
        XCTAssertEqual(control.headers["title"], ControlEvent.title)
        XCTAssertEqual(control.body, "clear e2e01234")
        XCTAssertEqual(isolated.poster.requests.count, 1, "a control event is never a banner")
    }
}

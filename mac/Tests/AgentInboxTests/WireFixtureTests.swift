import XCTest
@testable import AgentInbox

/// The sender's real output, decoded the way the app decodes it.
///
/// `fixtures/wire/*.txt` is what `notify.sh` puts on the wire for a set of
/// hand-made transcripts, written by `fixtures/wire/regenerate.sh` and pinned
/// by `test-notify.sh`, which fails when the sender drifts from the files.
/// Before these, bash and Swift had only ever been checked against each other
/// by a person reading both; a body with its subject line missing parsed fine
/// for a whole release. Every file goes through `Transport.splitFooter`
/// first, because that is what the receiver does before the parser sees a
/// message, and then through `MessageParser.parseWithOutcome`.
final class WireFixtureTests: XCTestCase {
    /// The repo's `fixtures/wire/`, found from this file rather than from the
    /// working directory, which `swift test` sets to `mac/`.
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AgentInboxTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // mac
        .deletingLastPathComponent() // the repo
        .appendingPathComponent("fixtures/wire", isDirectory: true)

    /// Every scenario the generator writes. Listed so a missing file fails
    /// loudly instead of a loop over the directory quietly running fewer.
    static let expected = [
        "finished-basic", "finished-short", "finished-no-start", "finished-code-only",
        "finished-tricky-text", "needsyou-permission", "needsyou-question",
    ]

    struct BadFixture: Error, CustomStringConvertible {
        let description: String
    }

    struct Decoded {
        let name: String
        let title: String
        let outcome: ParseOutcome
        let item: InboxItem?
    }

    /// A fixture is the dry run without its "WOULD SEND" line: `title: ` on
    /// the first line, `body: ` opening the second, and the rest of the body
    /// on the lines after. The generator's printf adds one final newline that
    /// was never part of the body.
    static func read(_ name: String) throws -> (title: String, body: String) {
        let url = fixtures.appendingPathComponent("\(name).txt")
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.hasSuffix("\n") { text.removeLast() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, lines[0].hasPrefix("title: "), lines[1].hasPrefix("body: ") else {
            throw BadFixture(description: "\(name).txt is not in the dry-run shape: \(text.prefix(80))")
        }
        let title = String(lines.removeFirst().dropFirst("title: ".count))
        lines[0] = String(lines[0].dropFirst("body: ".count))
        return (title, lines.joined(separator: "\n"))
    }

    static func decode(_ name: String) throws -> Decoded {
        let (title, wire) = try read(name)
        let (body, footer) = NtfyTransport.splitFooter(wire)
        let message = TransportMessage(
            id: name, title: title, body: body, footer: footer,
            date: Date(timeIntervalSince1970: 1_700_000_000))
        let parsed = MessageParser.parseWithOutcome(message, presence: 0)
        return Decoded(name: name, title: title, outcome: parsed.outcome, item: parsed.item)
    }

    /// `finished-*` and `needsyou-*`; the prefix is the scenario's kind.
    static func kind(fromName name: String) -> ItemKind? {
        if name.hasPrefix("finished-") { return .finished }
        if name.hasPrefix("needsyou-") { return .needsYou }
        return nil
    }

    private func item(_ name: String) throws -> InboxItem {
        let decoded = try Self.decode(name)
        XCTAssertEqual(decoded.outcome, .contract, "\(name).txt: the contract line was not read")
        return try XCTUnwrap(decoded.item, "\(name).txt: parsed to no item")
    }

    // MARK: Every file

    func testTheFixtureDirectoryHoldsEveryScenario() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasSuffix(".txt") }
            .map { String($0.dropLast(".txt".count)) }
            .sorted()
        XCTAssertEqual(names, Self.expected.sorted(),
                       "fixtures/wire/ and WireFixtureTests.expected disagree; update both together")
    }

    func testEveryFixtureDecodesThroughTheContract() throws {
        for name in Self.expected {
            try XCTContext.runActivity(named: "\(name).txt") { _ in
                let decoded = try Self.decode(name)
                XCTAssertEqual(decoded.outcome, .contract, "\(name).txt: the contract line was not read")
                let item = try XCTUnwrap(decoded.item, "\(name).txt: parsed to no item")

                let kind = try XCTUnwrap(Self.kind(fromName: name), "\(name).txt: filename has no kind prefix")
                XCTAssertEqual(item.kind, kind, "\(name).txt: kind")
                XCTAssertEqual(item.repo, "my-app", "\(name).txt: repo")
                XCTAssertEqual(item.host, "devbox", "\(name).txt: host")
                XCTAssertEqual(item.sessionID, "a1b2c3d4", "\(name).txt: session")
                XCTAssertEqual(item.cwd, "/home/me/my-app", "\(name).txt: cwd")

                // The human title and the contract describe the same event.
                let head = try XCTUnwrap(MessageParser.parseTitle(decoded.title), "\(name).txt: title")
                XCTAssertEqual(head.kind, item.kind, "\(name).txt: title kind")
                XCTAssertEqual(head.repo, item.repo, "\(name).txt: title repo")
                XCTAssertEqual(head.host, item.host, "\(name).txt: title host")
                XCTAssertEqual(head.duration, item.duration, "\(name).txt: title duration")

                // Neither the contract line nor the footer may leak into what
                // the row shows.
                for field in [item.detail, item.closing, item.waitingOn, item.summary, item.ask] {
                    guard let field else { continue }
                    XCTAssertFalse(field.contains(WireContract.prefix), "\(name).txt: contract leaked into a field: \(field)")
                    XCTAssertFalse(field.contains("session a1b2c3d4"), "\(name).txt: footer leaked into a field: \(field)")
                }
            }
        }
    }

    // MARK: One per scenario

    func testFinishedBasic() throws {
        let item = try item("finished-basic")
        XCTAssertEqual(item.duration, "4m 12s")
        XCTAssertEqual(item.elapsed, 252)
        XCTAssertEqual(item.summary, "Rework the refund ledger")
        XCTAssertEqual(item.ask, "and the chargeback path")
        XCTAssertEqual(item.closing, "Chargebacks post to the ledger and the backfill finished cleanly. … Ship it when you are ready.")
        XCTAssertNil(item.detail)
        XCTAssertNil(item.waitingOn)
        XCTAssertFalse(item.isShortTurn)
    }

    func testFinishedShort() throws {
        let item = try item("finished-short")
        XCTAssertEqual(item.elapsed, 3)
        XCTAssertEqual(item.duration, "0m 3s")
        XCTAssertTrue(item.isShortTurn, "a three second turn is the row the app offers to hide")
    }

    func testFinishedNoStart() throws {
        let item = try item("finished-no-start")
        XCTAssertNil(item.duration)
        XCTAssertNil(item.elapsed, "no start file means no elapsed, not a guess")
        XCTAssertFalse(item.isShortTurn, "an unknown duration is never called short")
        XCTAssertNil(item.summary, "a one-message session carries its prompt once, as the ask")
        XCTAssertEqual(item.ask, "Why is the enum duplicated across three files?")
    }

    func testFinishedCodeOnly() throws {
        let item = try item("finished-code-only")
        XCTAssertNil(item.closing, "a fenced block is not prose")
        XCTAssertEqual(item.detail, "```\ngit push origin main\n```", "detail carries the raw fallback, newlines intact")
        XCTAssertNil(item.closingWords)
    }

    /// " · /" in the closing makes `splitFooter` peel the contract line, not
    /// the footer. The quote, the backslash and the emoji come through jq on
    /// one side and JSONDecoder on the other and must meet in the middle.
    func testFinishedTrickyText() throws {
        let (_, wire) = try Self.read("finished-tricky-text")
        let (_, footer) = NtfyTransport.splitFooter(wire)
        XCTAssertTrue(footer.hasPrefix(WireContract.prefix),
                      "precondition: the transport peeled the contract line into the footer slot")

        let item = try item("finished-tricky-text")
        XCTAssertEqual(item.closing, "Renamed \"old\" to C:\\tmp\\new · /srv/app and it built 🚀. … Nothing else is outstanding here.")
        XCTAssertEqual(item.duration, "1m 1s")
        XCTAssertEqual(item.elapsed, 61)
    }

    func testNeedsYouPermission() throws {
        let item = try item("needsyou-permission")
        XCTAssertEqual(item.detail, "Claude needs your permission to use Bash")
        XCTAssertEqual(item.waitingOn, "Staging is reachable and the migration plan is three steps. … Running the first step now.")
        XCTAssertNil(item.duration)
        XCTAssertNil(item.elapsed)
        XCTAssertNil(item.closing)
        XCTAssertFalse(item.isShortTurn, "a hand is never a short turn")
    }

    func testNeedsYouQuestion() throws {
        let item = try item("needsyou-question")
        XCTAssertEqual(item.detail, "Claude is waiting for your input")
        XCTAssertEqual(item.waitingOn, "Same car, same seller, and the price dropped again since last week. … Which of those three should I keep?")
        XCTAssertTrue(item.waitingOn?.hasSuffix("?") ?? false, "the idle timer only raises a hand after a question")
    }
}

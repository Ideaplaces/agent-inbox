import XCTest
@testable import AgentInbox

/// The wire format is a contract with `notify.sh`. If these break, the app
/// silently shows blank rows, so they are the first thing to protect.
final class MessageParserTests: XCTestCase {
    func testGeneratedTopicsAreUnguessableAndUnique() {
        let a = AppSettings.randomNtfyTopic()
        let b = AppSettings.randomNtfyTopic()
        XCTAssertNotEqual(a, b, "a fixed topic would put every user on one channel")
        XCTAssertTrue(a.hasPrefix("agent-inbox-"))
        // The topic is the only secret protecting message bodies, so the
        // random tail has to be long: 12 bytes as hex.
        let tail = a.split(separator: "-").last.map(String.init) ?? ""
        XCTAssertEqual(tail.count, 24, "expected 24 hex chars, got \(tail)")
        XCTAssertTrue(tail.allSatisfy { $0.isHexDigit })
        // ntfy topics are used in a URL path.
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, a)
    }


    func testParsesFinishedTitleWithDuration() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("✅ ideaplaces-devops @ mac (4m 19s)"))
        XCTAssertEqual(head.kind, .finished)
        XCTAssertEqual(head.repo, "ideaplaces-devops")
        XCTAssertEqual(head.host, "mac")
        XCTAssertEqual(head.duration, "4m 19s")
    }

    func testParsesNeedsYouTitleWithoutDuration() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("🖐️ my-app @ devbox"))
        XCTAssertEqual(head.kind, .needsYou)
        XCTAssertEqual(head.repo, "my-app")
        XCTAssertEqual(head.host, "devbox")
        XCTAssertNil(head.duration)
    }

    func testAcceptsHandWithoutVariationSelector() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("🖐 my-app @ devbox"))
        XCTAssertEqual(head.kind, .needsYou)
        XCTAssertEqual(head.repo, "my-app")
    }

    func testRejectsTitleWithoutKnownKind() {
        XCTAssertNil(MessageParser.parseTitle("Deploy finished @ mac"))
    }

    func testRepoNamesContainingAtSurviveParsing() throws {
        let head = try XCTUnwrap(MessageParser.parseTitle("✅ scope@pkg @ mac (1m 0s)"))
        XCTAssertEqual(head.repo, "scope@pkg")
        XCTAssertEqual(head.host, "mac")
    }

    func testParsesFooter() {
        let foot = MessageParser.parseFooter("session a1b2c3d4 · /Users/me/my-app")
        XCTAssertEqual(foot.session, "a1b2c3d4")
        XCTAssertEqual(foot.cwd, "/Users/me/my-app")
    }

    func testFooterWithoutSessionStillYieldsPath() {
        let foot = MessageParser.parseFooter("/Users/me/my-app")
        XCTAssertNil(foot.session)
        XCTAssertEqual(foot.cwd, "/Users/me/my-app")
    }

    func testParsesFullNotificationMessage() throws {
        let message = TransportMessage(
            id: "42",
            title: "🖐️ checkout @ devbox",
            body: """
            🧵 Refactor the checkout flow to use the new payments SDK
            🗣 ok now handle the refund path too
            💬 Refunds are wired up end to end. … Want me to run it against staging?
            Claude needs your permission to use Bash
            ❯ Should I run the migration against staging first?
            """,
            footer: "session a1b2c3d4 · /home/me/checkout",
            date: Date(timeIntervalSince1970: 1_700_000_000))

        let item = try XCTUnwrap(MessageParser.parse(message, presence: 120))
        XCTAssertEqual(item.kind, .needsYou)
        XCTAssertEqual(item.repo, "checkout")
        XCTAssertEqual(item.host, "devbox")
        XCTAssertEqual(item.summary, "Refactor the checkout flow to use the new payments SDK")
        XCTAssertEqual(item.ask, "ok now handle the refund path too")
        XCTAssertEqual(item.detail, "Claude needs your permission to use Bash")
        XCTAssertEqual(
            item.closing, "Refunds are wired up end to end. … Want me to run it against staging?")
        XCTAssertEqual(item.waitingOn, "Should I run the migration against staging first?")
        XCTAssertEqual(item.cwd, "/home/me/checkout")
        XCTAssertEqual(item.presenceAtArrival, 120)
        // The row shows the newest thing you said, not the oldest.
        XCTAssertEqual(item.subtitle, "ok now handle the refund path too")
    }

    func testUnparseableTitleYieldsNoItem() {
        let message = TransportMessage(
            id: "1", title: "hello", body: "", footer: "", date: Date())
        XCTAssertNil(MessageParser.parse(message, presence: 0))
    }

    func testNtfyBodySplitsTrailingFooterLine() {
        let (body, footer) = NtfyTransport.splitFooter("""
        🧵 doing a thing
        line two
        session abcd1234 · /Users/me/repo
        """)
        XCTAssertEqual(body, "🧵 doing a thing\nline two")
        XCTAssertEqual(footer, "session abcd1234 · /Users/me/repo")
    }

    func testNtfyBodyWithoutFooterIsLeftIntact() {
        let (body, footer) = NtfyTransport.splitFooter("just a body")
        XCTAssertEqual(body, "just a body")
        XCTAssertEqual(footer, "")
    }

    // MARK: - The contract line

    /// The body as `splitFooter` normally hands it over: the JSON line is last
    /// and does not look like a footer, so the human footer stays in the body
    /// and `footer` is empty.
    private static let humanLines = """
    🧵 Refactor the checkout flow to use the new payments SDK
    🗣 ok now handle the refund path too
    💬 Refunds are wired up end to end. … Want me to run it against staging?
    Claude needs your permission to use Bash
    ❯ Should I run the migration against staging first?
    session a1b2c3d4 · /home/me/checkout
    """

    /// Every value differs from the line above it, so a field that came from
    /// the human lines instead of the JSON fails an assertion rather than
    /// passing by coincidence.
    private static let contractLine =
        #"{"v":1,"kind":"finished","repo":"billing","host":"laptop","duration":"4m 12s","elapsed":252,"# +
        #""summary":"Rework the refund ledger","ask":"and the chargeback path","# +
        #""closing":"Chargebacks post. … Ship it?","detail":"Claude needs your permission to use Edit","# +
        #""waitingOn":"Run the backfill now?","session":"ffff0000","cwd":"/srv/billing"}"#

    private func message(body: String, footer: String = "") -> TransportMessage {
        TransportMessage(
            id: "42", title: "🖐️ checkout @ devbox", body: body, footer: footer,
            date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testContractLineWinsOverEveryHumanLine() throws {
        let parsed = MessageParser.parseWithOutcome(
            message(body: Self.humanLines + "\n" + Self.contractLine), presence: 120)
        XCTAssertEqual(parsed.outcome, .contract)
        let item = try XCTUnwrap(parsed.item)
        XCTAssertEqual(item.kind, .finished)
        XCTAssertEqual(item.repo, "billing")
        XCTAssertEqual(item.host, "laptop")
        XCTAssertEqual(item.duration, "4m 12s")
        XCTAssertEqual(item.elapsed, 252)
        XCTAssertEqual(item.summary, "Rework the refund ledger")
        XCTAssertEqual(item.ask, "and the chargeback path")
        XCTAssertEqual(item.closing, "Chargebacks post. … Ship it?")
        XCTAssertEqual(item.detail, "Claude needs your permission to use Edit")
        XCTAssertEqual(item.waitingOn, "Run the backfill now?")
        XCTAssertEqual(item.sessionID, "ffff0000")
        XCTAssertEqual(item.cwd, "/srv/billing")
        XCTAssertEqual(item.presenceAtArrival, 120)
        XCTAssertEqual(item.receivedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A contract string containing " · /" makes `splitFooter` peel the JSON
    /// line into `footer` and leave the human footer last in the body. The
    /// parser must find the contract there too.
    func testContractLinePeeledIntoFooterIsStillRead() throws {
        let line = Self.contractLine.replacingOccurrences(
            of: "Rework the refund ledger", with: "Rework · /ledger")
        let (body, footer) = NtfyTransport.splitFooter(Self.humanLines + "\n" + line)
        XCTAssertEqual(footer, line, "precondition: the transport peeled the JSON line")

        let parsed = MessageParser.parseWithOutcome(message(body: body, footer: footer), presence: 0)
        XCTAssertEqual(parsed.outcome, .contract)
        let item = try XCTUnwrap(parsed.item)
        XCTAssertEqual(item.summary, "Rework · /ledger")
        XCTAssertEqual(item.repo, "billing")
        XCTAssertEqual(item.sessionID, "ffff0000")
        XCTAssertEqual(item.cwd, "/srv/billing")
        XCTAssertEqual(item.detail, "Claude needs your permission to use Edit")
    }

    /// The same body without the JSON line is what an older sender produces,
    /// and it must parse exactly as `testParsesFullNotificationMessage` does.
    func testBodyWithoutContractLineFallsBackToTheConventions() throws {
        let (body, footer) = NtfyTransport.splitFooter(Self.humanLines)
        let parsed = MessageParser.parseWithOutcome(message(body: body, footer: footer), presence: 120)
        XCTAssertEqual(parsed.outcome, .fallback)
        let item = try XCTUnwrap(parsed.item)
        XCTAssertEqual(item.kind, .needsYou)
        XCTAssertEqual(item.repo, "checkout")
        XCTAssertEqual(item.host, "devbox")
        XCTAssertNil(item.duration)
        XCTAssertNil(item.elapsed)
        XCTAssertEqual(item.summary, "Refactor the checkout flow to use the new payments SDK")
        XCTAssertEqual(item.ask, "ok now handle the refund path too")
        XCTAssertEqual(item.detail, "Claude needs your permission to use Bash")
        XCTAssertEqual(
            item.closing, "Refunds are wired up end to end. … Want me to run it against staging?")
        XCTAssertEqual(item.waitingOn, "Should I run the migration against staging first?")
        XCTAssertEqual(item.sessionID, "a1b2c3d4")
        XCTAssertEqual(item.cwd, "/home/me/checkout")
        XCTAssertEqual(item.subtitle, "ok now handle the refund path too")
    }

    /// A version this app does not speak, and a line cut short in transit.
    /// Both fall back, the JSON lands in no field, and the human footer the
    /// JSON line hid from `splitFooter` still becomes session and cwd.
    func testUnreadableContractLineFallsBackWithoutLeakingIntoDetail() throws {
        let broken = [
            Self.contractLine.replacingOccurrences(of: #"{"v":1,"#, with: #"{"v":2,"#),
            #"{"v":1,"kind":"fin"#,
        ]
        for line in broken {
            let (body, footer) = NtfyTransport.splitFooter(Self.humanLines + "\n" + line)
            XCTAssertEqual(footer, "", "precondition: the JSON line does not look like a footer")

            let parsed = MessageParser.parseWithOutcome(message(body: body, footer: footer), presence: 0)
            XCTAssertEqual(parsed.outcome, .fallback, line)
            let item = try XCTUnwrap(parsed.item, line)
            XCTAssertEqual(item.kind, .needsYou, line)
            XCTAssertEqual(item.repo, "checkout", line)
            XCTAssertEqual(item.detail, "Claude needs your permission to use Bash", line)
            XCTAssertEqual(item.summary, "Refactor the checkout flow to use the new payments SDK", line)
            XCTAssertEqual(item.waitingOn, "Should I run the migration against staging first?", line)
            XCTAssertEqual(item.sessionID, "a1b2c3d4", line)
            XCTAssertEqual(item.cwd, "/home/me/checkout", line)
            for field in [item.summary, item.ask, item.closing, item.detail, item.waitingOn, item.cwd] {
                XCTAssertFalse((field ?? "").contains(#"{"v":"#), "\(line) leaked into \(field ?? "")")
                XCTAssertFalse((field ?? "").contains("session a1b2c3d4"), "footer leaked into \(field ?? "")")
            }
        }
    }

    /// The same unreadable contract, but one that `splitFooter` peeled into
    /// `footer` because it contains " · /". The human footer is then still
    /// last in the body and has to be peeled by the parser.
    func testUnreadableContractInFooterSlotStillYieldsSessionAndCwd() throws {
        let line = #"{"v":2,"kind":"finished","summary":"a · /b"}"#
        let (body, footer) = NtfyTransport.splitFooter(Self.humanLines + "\n" + line)
        XCTAssertEqual(footer, line, "precondition: the transport peeled the JSON line")

        let parsed = MessageParser.parseWithOutcome(message(body: body, footer: footer), presence: 0)
        XCTAssertEqual(parsed.outcome, .fallback)
        let item = try XCTUnwrap(parsed.item)
        XCTAssertEqual(item.sessionID, "a1b2c3d4")
        XCTAssertEqual(item.cwd, "/home/me/checkout")
        XCTAssertEqual(item.detail, "Claude needs your permission to use Bash")
    }

    func testNullContractFieldsDecodeToNil() throws {
        let line = #"{"v":1,"kind":"needsYou","repo":"r","host":"h","duration":null,"elapsed":null,"# +
            #""summary":null,"ask":null,"closing":null,"detail":null,"waitingOn":null,"session":null,"cwd":null}"#
        let parsed = MessageParser.parseWithOutcome(message(body: "🧵 ignored\n" + line), presence: 0)
        XCTAssertEqual(parsed.outcome, .contract)
        let item = try XCTUnwrap(parsed.item)
        XCTAssertEqual(item.kind, .needsYou)
        XCTAssertEqual(item.repo, "r")
        XCTAssertEqual(item.host, "h")
        XCTAssertNil(item.duration)
        XCTAssertNil(item.elapsed)
        XCTAssertNil(item.summary)
        XCTAssertNil(item.ask)
        XCTAssertNil(item.closing)
        XCTAssertNil(item.detail)
        XCTAssertNil(item.waitingOn)
        XCTAssertNil(item.sessionID)
        XCTAssertNil(item.cwd)
    }

    func testElapsedIsDerivedFromDurationWhenTheContractLacksIt() throws {
        let line = #"{"v":1,"kind":"finished","repo":"r","host":"h","duration":"16m 39s","elapsed":null}"#
        let item = try XCTUnwrap(MessageParser.parse(message(body: line), presence: 0))
        XCTAssertEqual(item.duration, "16m 39s")
        XCTAssertEqual(item.elapsed, 999)
    }

    /// An older sender carries the duration only in the title.
    func testElapsedIsDerivedFromTheTitleForAnOlderSender() throws {
        let message = TransportMessage(
            id: "7", title: "✅ ideaplaces-devops @ mac (4m 19s)", body: "🧵 a thing",
            footer: "session a1b2c3d4 · /Users/me/repo", date: Date())
        let parsed = MessageParser.parseWithOutcome(message, presence: 0)
        XCTAssertEqual(parsed.outcome, .fallback)
        let item = try XCTUnwrap(parsed.item)
        XCTAssertEqual(item.duration, "4m 19s")
        XCTAssertEqual(item.elapsed, 259)
    }

    func testSecondsFromDuration() {
        XCTAssertEqual(MessageParser.seconds(fromDuration: "4m 12s"), 252)
        XCTAssertEqual(MessageParser.seconds(fromDuration: "0m 3s"), 3)
        XCTAssertEqual(MessageParser.seconds(fromDuration: "16m 39s"), 999)
        XCTAssertNil(MessageParser.seconds(fromDuration: "unknown"))
        XCTAssertNil(MessageParser.seconds(fromDuration: nil))
    }

    func testWireContractDecodeRejectsWhatItDoesNotSpeak() {
        XCTAssertNotNil(WireContract.decode(Self.contractLine))
        XCTAssertNil(WireContract.decode(#"{"v":2,"kind":"finished"}"#))
        XCTAssertNil(WireContract.decode(#"{"v":1,"kind":"fin"#))
        XCTAssertNil(WireContract.decode(#"{"v":1,"kind":"exploded"}"#), "an unknown kind is not a row")
        XCTAssertNil(WireContract.decode(#"{"kind":"finished","v":1}"#), "the prefix is part of the contract")
        XCTAssertNil(WireContract.decode("session a1b2c3d4 · /Users/me/repo"))
    }

}

/// The subject line reached the app and the menu threw it away.
///
/// `subtitle` is a fallback chain, `ask ?? summary ?? detail`, so an item that
/// carried both a subject and an ask rendered only the ask. Nearly every item
/// carries both, so the subject was invisible in the menu even once the sender
/// was fixed to send it.
final class ItemThreadTests: XCTestCase {
    private func item(
        summary: String?, ask: String?, detail: String? = nil, closing: String? = nil
    ) -> InboxItem {
        InboxItem(
            id: "1", kind: .needsYou, repo: "r", host: "h", duration: nil,
            summary: summary, ask: ask, detail: detail, closing: closing, waitingOn: nil,
            sessionID: nil, cwd: nil, receivedAt: Date(), presenceAtArrival: 0)
    }

    func testTheSubjectSurvivesAlongsideAnAsk() {
        let row = item(summary: "NPS analysis", ask: "push it to main")
        XCTAssertEqual(row.thread, "NPS analysis")
        XCTAssertEqual(row.subtitle, "push it to main")
    }

    func testTheSubjectIsNotRepeatedWhenItIsTheOnlyLine() {
        // summary alone falls through to subtitle, so showing thread too would
        // print the same sentence twice in one row.
        let row = item(summary: "NPS analysis", ask: nil)
        XCTAssertEqual(row.subtitle, "NPS analysis")
        XCTAssertNil(row.thread)
    }

    func testAnItemWithNoSubjectHasNoThreadLine() {
        XCTAssertNil(item(summary: nil, ask: "just this").thread)
        XCTAssertNil(item(summary: "", ask: "just this").thread)
    }

    /// The whole point of the closing line: a finished item always has a
    /// subject and an ask, so anything folded into `subtitle`'s fallback chain
    /// is never drawn. It has to be its own line or it does not exist.
    func testTheClosingWordsSurviveASubjectAndAnAsk() {
        let row = item(
            summary: "NPS analysis", ask: "push it to main",
            closing: "Pushed to main. … CI is green.")
        XCTAssertEqual(row.thread, "NPS analysis")
        XCTAssertEqual(row.subtitle, "push it to main")
        XCTAssertEqual(row.closingWords, "Pushed to main. … CI is green.")
    }

    /// An older sender sends no 💬 line at all, and its items must render
    /// exactly as they did before.
    func testAnItemFromAnOlderSenderHasNoClosingLine() {
        let row = item(summary: "NPS analysis", ask: "push it to main", detail: "some head text")
        XCTAssertNil(row.closingWords)
        XCTAssertEqual(row.subtitle, "push it to main")
    }

    func testAClosingThatOnlyRepeatsTheLineAboveIsDropped() {
        XCTAssertNil(item(summary: nil, ask: "push it", closing: "push it").closingWords)
        XCTAssertNil(item(summary: "s", ask: "a", closing: "").closingWords)
    }
}

/// Every turn reports by default so a new install can see that it works. The
/// row for a very short turn is where the person then learns the floor exists,
/// so the offer has to appear on exactly those rows and no others.
final class ShortTurnTests: XCTestCase {
    private func item(kind: ItemKind, elapsed: Int?) -> InboxItem {
        InboxItem(
            id: "1", kind: kind, repo: "r", host: "h", duration: nil, elapsed: elapsed,
            summary: nil, ask: nil, detail: nil, closing: nil, waitingOn: nil,
            sessionID: nil, cwd: nil, receivedAt: Date(), presenceAtArrival: 0)
    }

    func testAQuickFinishedTurnGetsTheOffer() {
        XCTAssertTrue(item(kind: .finished, elapsed: 3).isShortTurn)
        XCTAssertTrue(item(kind: .finished, elapsed: InboxItem.shortTurnSeconds - 1).isShortTurn)
    }

    func testATurnAtTheThresholdDoesNot() {
        XCTAssertFalse(item(kind: .finished, elapsed: InboxItem.shortTurnSeconds).isShortTurn)
        XCTAssertFalse(item(kind: .finished, elapsed: 999).isShortTurn)
    }

    /// An older sender sends no elapsed time. Unknown is not short.
    func testAnUnknownDurationIsNeverCalledShort() {
        XCTAssertFalse(item(kind: .finished, elapsed: nil).isShortTurn)
    }

    /// The hand is a block, not a turn; its duration means nothing here.
    func testANeedsYouItemIsNeverCalledShort() {
        XCTAssertFalse(item(kind: .needsYou, elapsed: 2).isShortTurn)
    }
}

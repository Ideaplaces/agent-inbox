import Foundation

/// One agent event as it arrives from a transport, before it is understood.
struct TransportMessage {
    let id: String
    let title: String
    let body: String
    let footer: String
    let date: Date
}

enum ItemKind: String, Codable {
    case needsYou
    case finished

    var symbol: String {
        switch self {
        case .needsYou: return "🖐️"
        case .finished: return "✅"
        }
    }

    /// SF Symbol used in the dropdown, where the emoji reads as noise.
    var icon: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .finished: return "checkmark.circle.fill"
        }
    }
}

/// A parsed agent event. A current sender ends the body with one line of
/// JSON, the versioned contract in `WireContract`, and the item is built from
/// that line alone. Everything above it is there for a human reading the raw
/// notification, and for the app when the JSON is missing: an older sender
/// stops at the footer, and then the prefixed lines are what gets parsed, so
/// the shapes below still mirror `notify.sh`:
///
///     🖐️ my-app @ devbox                     <- title
///     🧵 Refactor the checkout flow          <- summary
///     🗣 ok now handle the refund path       <- ask
///     💬 Refunds are wired up. … Want me to  <- closing
///        run it against staging?
///     Claude needs your permission to ...    <- detail
///     ❯ Should I run the migration first?    <- waitingOn
///     session a1b2c3d4 · /Users/me/my-app    <- footer
///     {"v":1,"kind":"needsYou","repo":...}   <- contract, wins when present
struct InboxItem: Codable, Identifiable, Equatable {
    var id: String
    var kind: ItemKind
    var repo: String
    var host: String
    var duration: String?
    /// `duration` in seconds. Sent by a current sender; derived from
    /// `duration` for an older one, which is why both exist. Defaulted so an
    /// `items.json` written before it existed still decodes.
    var elapsed: Int? = nil
    var summary: String?
    var ask: String?
    var detail: String?
    /// How the agent's last message opened and how it closed, already reduced
    /// to two sentences by the sender.
    ///
    /// Optional because an older sender does not send it, in which case the
    /// row falls back to `detail` exactly as it used to.
    var closing: String?
    var waitingOn: String?
    var sessionID: String?
    var cwd: String?
    var receivedAt: Date
    /// Seconds of keyboard presence accumulated when this item arrived. Items
    /// expire against this clock, not wall time, so a coffee break does not
    /// silently drain the inbox.
    var presenceAtArrival: Int
    var isRead: Bool = false

    var titleLine: String {
        var line = "\(repo) @ \(host)"
        if let duration { line += " (\(duration))" }
        return line
    }

    /// What the session is about, shown above the rest of the row.
    ///
    /// Kept separate from `subtitle` rather than folded into it: the two
    /// answer different questions, and a fallback chain silently drops the
    /// subject on every item that also carries an ask, which is nearly all of
    /// them. Suppressed when it would only repeat the line below it.
    var thread: String? {
        guard let summary, !summary.isEmpty, summary != subtitle else { return nil }
        return summary
    }

    /// The one line worth showing under the title when space is tight.
    var subtitle: String? {
        ask ?? summary ?? detail
    }

    /// The agent's own words, shown under everything else.
    ///
    /// Kept out of `subtitle`'s fallback chain on purpose. The chain answers
    /// "what is this conversation", and every finished item already has an
    /// answer to that, so a closing folded into it would never once be drawn.
    /// This is the line that tells two long sessions apart, which is exactly
    /// the case where the subject line has stopped being enough.
    /// Under this many seconds, a finished turn gets a line offering to hide
    /// turns that short. Every turn reports by default so a new install can see
    /// that it works; this is how the person then learns the floor exists,
    /// on the very row that made them wonder.
    static let shortTurnSeconds = 15

    /// A finished turn quick enough to offer hiding. Unknown durations are not
    /// short: an older sender that sends no elapsed time should not be nagged.
    var isShortTurn: Bool {
        guard kind == .finished, let elapsed else { return false }
        return elapsed < Self.shortTurnSeconds
    }

    var closingWords: String? {
        guard let closing, !closing.isEmpty, closing != subtitle else { return nil }
        return closing
    }
}

/// The last line of a current sender's body: one line of compact JSON that
/// carries every field the app shows, already separated. The prefixed lines
/// above it are for people; this is for the parser, so a sender can change
/// how the human lines read without the app losing a field.
///
/// `v` is the version and is checked, not trusted: a line from a version this
/// app does not know is ignored whole, and the human lines are read instead.
/// Every field but `kind` may be null, which decodes to nil.
struct WireContract: Decodable {
    static let version = 1
    static let prefix = "{\"v\":"

    let v: Int
    let kind: ItemKind
    let repo: String?
    let host: String?
    let duration: String?
    let elapsed: Int?
    let summary: String?
    let ask: String?
    let closing: String?
    let detail: String?
    let waitingOn: String?
    let session: String?
    let cwd: String?

    /// nil for anything that is not a contract this app speaks, which is the
    /// signal to fall back rather than an error: the message is still usable.
    static func decode(_ line: String) -> WireContract? {
        guard line.hasPrefix(prefix),
              let contract = try? JSONDecoder().decode(WireContract.self, from: Data(line.utf8)),
              contract.v == version
        else { return nil }
        return contract
    }
}

/// Which half of the parser produced an item.
enum ParseOutcome: Equatable {
    case contract
    case fallback
}

enum MessageParser {
    /// "🖐️ my-app @ devbox (4m 19s)" -> kind, repo, host, duration
    static func parseTitle(_ title: String) -> (kind: ItemKind, repo: String, host: String, duration: String?)? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ItemKind
        var rest: Substring

        if let r = trimmed.range(of: ItemKind.needsYou.symbol), r.lowerBound == trimmed.startIndex {
            kind = .needsYou
            rest = trimmed[r.upperBound...]
        } else if let r = trimmed.range(of: ItemKind.finished.symbol), r.lowerBound == trimmed.startIndex {
            kind = .finished
            rest = trimmed[r.upperBound...]
        } else if trimmed.hasPrefix("🖐") {
            // Some senders emit the hand without the VS16 variation selector.
            kind = .needsYou
            rest = trimmed.dropFirst()
        } else {
            return nil
        }

        var body = rest.trimmingCharacters(in: .whitespaces)
        var duration: String?
        if body.hasSuffix(")"), let open = body.lastIndex(of: "(") {
            duration = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
            body = String(body[..<open]).trimmingCharacters(in: .whitespaces)
        }

        guard let at = body.range(of: " @ ") else {
            return (kind, body, "", duration)
        }
        let repo = String(body[..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
        let host = String(body[at.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (kind, repo, host, duration)
    }

    /// "session a1b2c3d4 · /Users/me/my-app" -> ("a1b2c3d4", "/Users/me/my-app")
    static func parseFooter(_ footer: String) -> (session: String?, cwd: String?) {
        guard let sep = footer.range(of: " · ") else {
            return (nil, footer.hasPrefix("/") ? footer : nil)
        }
        let left = String(footer[..<sep.lowerBound])
        let right = String(footer[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
        let session = left.hasPrefix("session ") ? String(left.dropFirst("session ".count)) : nil
        return (session, right.hasPrefix("/") ? right : nil)
    }

    /// "4m 12s" -> 252. Only the shape `notify.sh` prints, minutes unbounded;
    /// "unknown" and anything else is nil rather than a guess.
    static func seconds(fromDuration duration: String?) -> Int? {
        guard let duration else { return nil }
        let parts = duration.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].hasSuffix("m"), parts[1].hasSuffix("s"),
              let minutes = Int(parts[0].dropLast()), minutes >= 0,
              let seconds = Int(parts[1].dropLast()), seconds >= 0
        else { return nil }
        return minutes * 60 + seconds
    }

    static func parse(_ message: TransportMessage, presence: Int) -> InboxItem? {
        parseWithOutcome(message, presence: presence).item
    }

    /// The contract line when there is one, and the conventions when there is
    /// not. `outcome` says which, so a test can tell "the contract was read"
    /// from "the contract was ignored and the lines above it happened to say
    /// the same thing".
    ///
    /// The contract line can reach here in two places. `Transport.splitFooter`
    /// peels the last line of the body when it looks like a footer, and the
    /// JSON line normally does not, so it stays last in the body and the human
    /// footer stays above it. But a contract string that contains " · /" makes
    /// the JSON line look like a footer, and then it arrives in
    /// `message.footer` with the human footer still last in the body. Both
    /// arrangements are read; nothing about the split is assumed.
    static func parseWithOutcome(
        _ message: TransportMessage, presence: Int
    ) -> (item: InboxItem?, outcome: ParseOutcome) {
        if message.footer.hasPrefix(WireContract.prefix) {
            if let contract = WireContract.decode(message.footer) {
                return (item(from: contract, message: message, presence: presence), .contract)
            }
            // The footer slot holds a contract the app cannot read, so the real
            // footer is still the last line of the body.
            let (body, footer) = peelFooter(message.body)
            return (fallback(message, body: body, footer: footer, presence: presence), .fallback)
        }

        let lines = message.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        if end > 0, lines[end - 1].hasPrefix(WireContract.prefix) {
            if let contract = WireContract.decode(lines[end - 1]) {
                return (item(from: contract, message: message, presence: presence), .contract)
            }
            // A contract from a version this app does not speak, or one cut
            // short in transit. It must not end up in `detail`, and the footer
            // it hid from `splitFooter` must still become session and cwd.
            let rest = lines[..<(end - 1)].joined(separator: "\n")
            let (body, footer) = message.footer.isEmpty ? peelFooter(rest) : (rest, message.footer)
            return (fallback(message, body: body, footer: footer, presence: presence), .fallback)
        }

        return (fallback(message, body: message.body, footer: message.footer, presence: presence), .fallback)
    }

    private static func item(
        from contract: WireContract, message: TransportMessage, presence: Int
    ) -> InboxItem {
        InboxItem(
            id: message.id,
            kind: contract.kind,
            repo: contract.repo ?? "",
            host: contract.host ?? "",
            duration: contract.duration,
            elapsed: contract.elapsed ?? seconds(fromDuration: contract.duration),
            summary: contract.summary,
            ask: contract.ask,
            detail: contract.detail,
            closing: contract.closing,
            waitingOn: contract.waitingOn,
            sessionID: contract.session,
            cwd: contract.cwd,
            receivedAt: message.date,
            presenceAtArrival: presence
        )
    }

    /// The same two tests as `Transport.splitFooter`, for a body the transport
    /// did not split because the contract line was standing in the footer's
    /// place. Kept separate rather than shared so the transport's split, which
    /// every older message depends on, is not touched.
    private static func peelFooter(_ text: String) -> (body: String, footer: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let last = lines.last,
              last.hasPrefix("session ") || last.contains(" · /")
        else { return (text, "") }
        return (lines.dropLast().joined(separator: "\n"), last)
    }

    /// The conventions an older sender relies on: title parsed on " @ " and a
    /// trailing "(...)", body lines by their prefix, footer on " · ".
    private static func fallback(
        _ message: TransportMessage, body: String, footer: String, presence: Int
    ) -> InboxItem? {
        guard let head = parseTitle(message.title) else { return nil }
        let foot = parseFooter(footer)

        var summary: String?
        var ask: String?
        var closing: String?
        var waitingOn: String?
        var detailLines: [String] = []

        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("🧵") {
                summary = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("🗣") {
                ask = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("💬") {
                closing = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("❯") {
                waitingOn = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            } else {
                detailLines.append(line)
            }
        }

        return InboxItem(
            id: message.id,
            kind: head.kind,
            repo: head.repo,
            host: head.host,
            duration: head.duration,
            elapsed: seconds(fromDuration: head.duration),
            summary: summary,
            ask: ask,
            detail: detailLines.isEmpty ? nil : detailLines.joined(separator: "\n"),
            closing: closing,
            waitingOn: waitingOn,
            sessionID: foot.session,
            cwd: foot.cwd,
            receivedAt: message.date,
            presenceAtArrival: presence
        )
    }
}

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

/// A parsed agent event. The senders encode everything in a title line, a body
/// of prefixed lines, and a footer, so the shapes below mirror `notify.sh`:
///
///     🖐️ my-app @ devbox                     <- title
///     🧵 Refactor the checkout flow          <- summary
///     🗣 ok now handle the refund path       <- ask
///     Claude needs your permission to ...    <- detail
///     ❯ Should I run the migration first?    <- waitingOn
///     session a1b2c3d4 · /Users/me/my-app    <- footer
struct InboxItem: Codable, Identifiable, Equatable {
    var id: String
    var kind: ItemKind
    var repo: String
    var host: String
    var duration: String?
    var summary: String?
    var ask: String?
    var detail: String?
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

    /// The one line worth showing under the title when space is tight.
    var subtitle: String? {
        ask ?? summary ?? detail
    }
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

    static func parse(_ message: TransportMessage, presence: Int) -> InboxItem? {
        guard let head = parseTitle(message.title) else { return nil }
        let foot = parseFooter(message.footer)

        var summary: String?
        var ask: String?
        var waitingOn: String?
        var detailLines: [String] = []

        for raw in message.body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("🧵") {
                summary = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("🗣") {
                ask = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
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
            summary: summary,
            ask: ask,
            detail: detailLines.isEmpty ? nil : detailLines.joined(separator: "\n"),
            waitingOn: waitingOn,
            sessionID: foot.session,
            cwd: foot.cwd,
            receivedAt: message.date,
            presenceAtArrival: presence
        )
    }
}

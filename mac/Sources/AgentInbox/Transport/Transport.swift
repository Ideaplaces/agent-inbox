import Foundation

/// A place agent events arrive from. Both implementations are stateless: the
/// cursor is owned by the poller and handed back on every call, so a crash
/// never replays history and never skips an event.
protocol Transport: Sendable {
    /// Messages newer than `cursor`, oldest first, plus the cursor to store.
    func poll(cursor: String?) async throws -> (messages: [TransportMessage], cursor: String?)

    /// A cursor meaning "everything from now on", used on first run so the
    /// inbox does not open full of yesterday's sessions.
    func initialCursor() async throws -> String?
}

enum TransportError: LocalizedError {
    case badResponse(Int)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Transport returned HTTP \(code)"
        case .notConfigured: return "No transport configured"
        }
    }
}

extension Transport {
    /// The senders append the footer as the final line of the body. Split it
    /// back off so the footer's cwd can drive "open this session".
    static func splitFooter(_ text: String) -> (body: String, footer: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let last = lines.last,
              last.hasPrefix("session ") || last.contains(" · /")
        else { return (text, "") }
        return (lines.dropLast().joined(separator: "\n"), last)
    }
}

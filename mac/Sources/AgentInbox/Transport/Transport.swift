import Foundation

/// What arrives on an open connection. `opened` is the server's own
/// acknowledgement, and its absence is the only way to tell a connection that
/// is being buffered somewhere in the middle from one that is simply quiet.
enum TransportEvent {
    case opened
    case message(TransportMessage, cursor: String?)
}

/// A place agent events arrive from. Stateless: the cursor is owned by the
/// poller and handed back on every call, so a crash never replays history and
/// never skips an event, and a reconnect asks for exactly what it missed.
protocol Transport: Sendable {
    /// Messages as they arrive, on a connection held open. Finishes when the
    /// connection drops, which is not an error: the caller reconnects with the
    /// cursor it has and the server sends whatever was missed.
    func stream(cursor: String?) -> AsyncThrowingStream<TransportEvent, Error>

    /// Messages newer than `cursor`, oldest first, plus the cursor to store.
    /// The fallback, for a network that will not carry a held-open connection.
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

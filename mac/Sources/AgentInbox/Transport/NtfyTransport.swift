import Foundation

/// ntfy.sh needs no account and no bot: the topic name is the channel. That
/// makes it the zero-friction default, at the cost of the topic being the
/// only secret protecting the message bodies.
///
/// A self-hosted server can close that gap by requiring a token, and ours does:
/// it runs deny-all, so the topic name grants nothing on its own. The token is
/// optional so the same transport still serves ntfy.sh unchanged.
struct NtfyTransport: Transport {
    let server: String
    let topic: String
    var token: String = ""

    private struct Event: Decodable {
        let id: String
        let time: Int?
        let event: String?
        let title: String?
        let message: String?
    }

    func initialCursor() async throws -> String? {
        String(Int(Date().timeIntervalSince1970))
    }

    /// A session that expects to sit still for hours.
    ///
    /// The request timeout is an idle timeout between packets, not a deadline
    /// for the whole response, and ntfy sends a keepalive about every 45
    /// seconds, which resets it. The resource timeout is a deadline for the
    /// whole response, so on a held-open connection it has to be gone entirely
    /// or the stream dies on a timer for no reason.
    private static let streaming: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// One line of newline-delimited JSON, as an event worth passing on.
    ///
    /// Shared with `poll`, which reads the same format in one go. ntfy also
    /// sends `open`, `keepalive` and `poll_request` on the same connection;
    /// only `open` means anything here, and the rest are dropped.
    private static func event(from line: String) -> TransportEvent? {
        guard let raw = try? JSONDecoder().decode(Event.self, from: Data(line.utf8))
        else { return nil }
        switch raw.event {
        case "open": return .opened
        case "message":
            let (body, footer) = splitFooter(raw.message ?? "")
            return .message(
                TransportMessage(
                    id: raw.id,
                    title: raw.title ?? "Agent Inbox",
                    body: body,
                    footer: footer,
                    date: raw.time.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()),
                cursor: raw.id)
        default: return nil
        }
    }

    /// Reachable from the tests without making the parser part of the type's
    /// surface for everyone else.
    static func testableEvent(from line: String) -> TransportEvent? { event(from: line) }

    /// The same endpoint as `poll`, without `poll=1`, which makes the server
    /// hold the connection open and write each message as it happens instead
    /// of answering once and hanging up.
    func stream(cursor: String?) -> AsyncThrowingStream<TransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let since = cursor ?? "all"
            guard let url = URL(string: "\(server)/\(topic)/json?since=\(since)") else {
                continuation.finish(throwing: TransportError.notConfigured)
                return
            }
            let work = Task {
                do {
                    let (bytes, response) = try await Self.streaming.bytes(
                        for: request(url, timeout: 120))
                    guard let http = response as? HTTPURLResponse else {
                        throw TransportError.badResponse(0)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw TransportError.badResponse(http.statusCode)
                    }
                    for try await line in bytes.lines {
                        if let event = Self.event(from: line) { continuation.yield(event) }
                    }
                    // The server closed. Not an error: the caller reconnects
                    // and asks for everything since the cursor it holds.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    func poll(cursor: String?) async throws -> (messages: [TransportMessage], cursor: String?) {
        let since = cursor ?? String(Int(Date().timeIntervalSince1970))
        guard let url = URL(string: "\(server)/\(topic)/json?poll=1&since=\(since)") else {
            throw TransportError.notConfigured
        }
        let (data, response) = try await URLSession.shared.data(
            for: request(url, timeout: 20))
        guard let http = response as? HTTPURLResponse else { throw TransportError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.badResponse(http.statusCode)
        }

        // The poll endpoint streams newline-delimited JSON, not a JSON array.
        let decoder = JSONDecoder()
        let events = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> Event? in
                try? decoder.decode(Event.self, from: Data(line.utf8))
            }
            .filter { $0.event == "message" }

        guard !events.isEmpty else { return ([], since) }

        let messages: [TransportMessage] = events.map { event in
            let (body, footer) = Self.splitFooter(event.message ?? "")
            return TransportMessage(
                id: event.id,
                title: event.title ?? "Agent Inbox",
                body: body,
                footer: footer,
                date: event.time.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            )
        }
        return (messages, events.last?.id ?? since)
    }
}

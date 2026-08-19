import Foundation

/// ntfy.sh needs no account and no bot: the topic name is the channel. That
/// makes it the zero-friction default, at the cost of the topic being the
/// only secret protecting the message bodies.
struct NtfyTransport: Transport {
    let server: String
    let topic: String

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

    func poll(cursor: String?) async throws -> (messages: [TransportMessage], cursor: String?) {
        let since = cursor ?? String(Int(Date().timeIntervalSince1970))
        guard let url = URL(string: "\(server)/\(topic)/json?poll=1&since=\(since)") else {
            throw TransportError.notConfigured
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
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

import Foundation

/// Reads a private Discord channel through the bot API. The channel history
/// doubles as a browsable archive, which is why it survived the rewrite.
struct DiscordTransport: Transport {
    let token: String
    let channelID: String

    private func request(_ query: String) async throws -> Data {
        var components = URLComponents(
            string: "https://discord.com/api/v10/channels/\(channelID)/messages")!
        components.query = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.badResponse(http.statusCode)
        }
        return data
    }

    private struct Message: Decodable {
        struct Embed: Decodable {
            struct Footer: Decodable { let text: String? }
            let title: String?
            let description: String?
            let footer: Footer?
        }
        let id: String
        let content: String?
        let timestamp: String?
        let embeds: [Embed]?
    }

    func initialCursor() async throws -> String? {
        let data = try await request("limit=1")
        return try JSONDecoder().decode([Message].self, from: data).first?.id
    }

    func poll(cursor: String?) async throws -> (messages: [TransportMessage], cursor: String?) {
        guard let cursor else {
            return ([], try await initialCursor())
        }
        let data = try await request("after=\(cursor)&limit=25")
        let decoded = try JSONDecoder().decode([Message].self, from: data)
        guard !decoded.isEmpty else { return ([], cursor) }

        // Discord returns newest first; the inbox wants oldest first.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let messages: [TransportMessage] = decoded.reversed().map { message in
            let embed = message.embeds?.first
            let date = message.timestamp.flatMap { formatter.date(from: $0) } ?? Date()
            return TransportMessage(
                id: message.id,
                title: embed?.title ?? message.content ?? "Agent Inbox",
                body: embed?.description ?? "",
                footer: embed?.footer?.text ?? "",
                date: date
            )
        }
        return (messages, decoded.first?.id ?? cursor)
    }
}

import Foundation
import Network

/// Enough of ntfy to stand in for it on 127.0.0.1.
///
/// `FakeTransport` scripts what the receiver sees, which is the right level
/// for the connection lifecycle and the wrong one for `NtfyTransport`: the
/// real client's NDJSON parsing, its `since=` cursors and what it does when a
/// held-open response ends were verified by hand against the maintainer's
/// server and nowhere else. This speaks the three requests the app and
/// `notify.sh` make, over a real socket, so the real client and the real
/// sender can be tested without a network.
///
/// Speaks HTTP/1.1 by hand rather than through a framework because the
/// interesting part is the shape of the response: a stream is a chunked body
/// that is never finished, and every published message is one chunk. Nothing
/// off the shelf gives the test control over when the terminating chunk goes.
///
/// - `GET /<topic>/json?since=<cursor>` answers with an `open` event and the
///   backlog, then holds the connection and writes each later publish as it
///   happens.
/// - `GET /<topic>/json?poll=1&since=<cursor>` answers with the backlog and
///   closes.
/// - `POST /<topic>` (or `PUT`) stores the body as a message, with `Title:`
///   and `Priority:` read off the headers the way `notify.sh` sends them, and
///   fans it out to every open stream on that topic.
///
/// A cursor is `all`, a unix time (messages at or after it), or a message id
/// (messages after it; an unknown id returns the whole topic, since a
/// duplicate is the safer failure). Ids are letters only so one can never be
/// mistaken for a time. With `token` set, every request without a matching
/// bearer header gets a 401.
final class FakeNtfyServer: @unchecked Sendable {
    struct Received: Equatable {
        let method: String
        let path: String
        let query: [String: String]
        /// Header names lowercased, so a test does not care how curl cases them.
        let headers: [String: String]
        let body: String
    }

    struct Message: Encodable {
        let id: String
        let time: Int
        let event = "message"
        let topic: String
        let title: String?
        let message: String
        let priority: Int
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fake-ntfy")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var streams: [(topic: String, connection: NWConnection)] = []
    private var messages: [Message] = []
    private var hangNext = false
    private var log: [Received] = []
    private(set) var port: UInt16 = 0

    /// When set, every request has to carry `Authorization: Bearer <token>`.
    var token: String?

    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Every request handled so far, in arrival order.
    var received: [Received] { lock.withLock { log } }

    /// Bind an ephemeral port and return once it is accepting connections.
    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    // Cleared before resuming: the handler fires for every
                    // later state too, and a continuation resumes once.
                    listener.stateUpdateHandler = nil
                    self?.lock.withLock { self?.port = listener.port?.rawValue ?? 0 }
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let open: [NWConnection] = lock.withLock {
            defer {
                connections.removeAll()
                streams.removeAll()
            }
            return connections
        }
        for connection in open { connection.cancel() }
        listener?.cancel()
        listener = nil
    }

    /// Publish from the server side, as another sender would have.
    @discardableResult
    func publish(title: String?, body: String, topic: String, priority: Int = 3) -> Message {
        store(topic: topic, title: title, body: body, priority: priority)
    }

    /// End every open stream the way ntfy ends one on purpose: the
    /// terminating chunk, then the socket. The client sees a complete response
    /// rather than an error, which is the "the server closed, reconnect"
    /// contract `NtfyTransport` promises its caller.
    func dropOpenStreams() {
        let open = lock.withLock { () -> [(topic: String, connection: NWConnection)] in
            defer { streams.removeAll() }
            return streams
        }
        for stream in open {
            stream.connection.send(
                content: Data("0\r\n\r\n".utf8),
                completion: .contentProcessed { _ in stream.connection.cancel() })
        }
    }

    /// The next stream request gets its response headers and then nothing:
    /// no `open`, no messages. What a buffering proxy looks like from the
    /// client, and what the receiver's watchdog exists to detect.
    func hangNextStream() {
        lock.withLock { hangNext = true }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    /// Accumulate until a whole request, body included, has arrived.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request.parse(buffer) {
                self.handle(request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        lock.withLock {
            log.append(Received(
                method: request.method, path: request.path, query: request.query,
                headers: request.headers, body: String(decoding: request.body, as: UTF8.self)))
        }
        if let token, request.headers["authorization"] != "Bearer \(token)" {
            respond(connection, status: "401 Unauthorized",
                    body: #"{"code":40101,"http":401,"error":"unauthorized"}"#)
            return
        }
        let segments = request.path.split(separator: "/").map(String.init)
        if request.method == "GET", segments.count == 2, segments[1] == "json" {
            if request.query["poll"] == "1" {
                let backlog = lock.withLock { self.backlog(since: request.query["since"], topic: segments[0]) }
                respond(connection, status: "200 OK", contentType: "application/x-ndjson",
                        body: backlog.map(Self.line).joined())
            } else {
                openStream(connection, topic: segments[0], since: request.query["since"])
            }
        } else if request.method == "POST" || request.method == "PUT", segments.count == 1 {
            let message = store(
                topic: segments[0], title: request.headers["title"],
                body: String(decoding: request.body, as: UTF8.self),
                priority: Self.priority(request.headers["priority"]))
            respond(connection, status: "200 OK", body: Self.line(message))
        } else {
            respond(connection, status: "404 Not Found",
                    body: #"{"code":40401,"http":404,"error":"page not found"}"#)
        }
    }

    /// Headers, the `open` event, then the backlog, all under the lock so a
    /// publish landing at the same moment cannot slip in ahead of history.
    private func openStream(_ connection: NWConnection, topic: String, since: String?) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n"
            + "Transfer-Encoding: chunked\r\nCache-Control: no-cache\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        lock.withLock {
            defer { hangNext = false }
            guard !hangNext else { return }
            streams.append((topic, connection))
            let open = #"{"id":"\#(Self.randomID())","time":\#(Self.now),"event":"open","topic":"\#(topic)"}"#
            Self.writeChunk(open + "\n", to: connection)
            for message in backlog(since: since, topic: topic) {
                Self.writeChunk(Self.line(message), to: connection)
            }
        }
    }

    private func store(topic: String, title: String?, body: String, priority: Int) -> Message {
        let message = Message(
            id: Self.randomID(), time: Self.now, topic: topic,
            title: title, message: body, priority: priority)
        lock.withLock {
            messages.append(message)
            for stream in streams where stream.topic == topic {
                Self.writeChunk(Self.line(message), to: stream.connection)
            }
        }
        return message
    }

    /// Caller holds the lock.
    private func backlog(since cursor: String?, topic: String) -> [Message] {
        let mine = messages.filter { $0.topic == topic }
        guard let cursor else { return [] }
        if cursor == "all" { return mine }
        if let time = Int(cursor) { return mine.filter { $0.time >= time } }
        guard let index = mine.firstIndex(where: { $0.id == cursor }) else { return mine }
        return Array(mine[(index + 1)...])
    }

    private func respond(
        _ connection: NWConnection, status: String,
        contentType: String = "application/json", body: String
    ) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + payload,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Wire format

    private static var now: Int { Int(Date().timeIntervalSince1970) }

    private static func randomID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String((0..<12).map { _ in letters.randomElement()! })
    }

    private static func priority(_ header: String?) -> Int {
        switch header?.lowercased() {
        case "1", "min": return 1
        case "2", "low": return 2
        case "4", "high": return 4
        case "5", "max", "urgent": return 5
        default: return 3
        }
    }

    /// One message as ntfy writes it: compact JSON, newline terminated.
    private static func line(_ message: Message) -> String {
        String(decoding: (try? JSONEncoder().encode(message)) ?? Data(), as: UTF8.self) + "\n"
    }

    private static func writeChunk(_ text: String, to connection: NWConnection) {
        let payload = Data(text.utf8)
        var chunk = Data("\(String(payload.count, radix: 16))\r\n".utf8)
        chunk.append(payload)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .idempotent)
    }

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        /// nil until the head and `Content-Length` bytes of body are all here.
        static func parse(_ buffer: Data) -> Request? {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            var lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= length else { return nil }

            let target = requestLine[1].split(separator: "?", maxSplits: 1)
            var query: [String: String] = [:]
            if target.count == 2 {
                for pair in target[1].split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    query[parts[0]] = parts.count == 2 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
                }
            }
            return Request(
                method: String(requestLine[0]), path: String(target[0]), query: query,
                headers: headers, body: Data(body.prefix(length)))
        }
    }
}

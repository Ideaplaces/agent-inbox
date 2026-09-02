import Foundation
@testable import AgentInbox

/// A transport that plays a script instead of talking to a server.
///
/// Each `stream` call consumes the next scripted connection: its events are
/// delivered at once, then the connection finishes, throws, or hangs the way
/// a real held-open one does. Once the script runs out every further
/// connection hangs, which is the quiet-server case and the safest default.
/// Every cursor the receiver asks with is recorded, since that is the part a
/// reconnect gets wrong when it gets anything wrong.
final class FakeTransport: Transport, @unchecked Sendable {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    enum Ending {
        case finish
        case fail(String)
        case hang
    }

    struct Connection {
        var events: [TransportEvent] = []
        var ending: Ending = .hang
    }

    private let lock = NSLock()
    private var connections: [Connection]
    private var streams: [String?] = []
    private var polls: [String?] = []

    var initial: String? = "start"
    var pollReply: (messages: [TransportMessage], cursor: String?) = ([], "polled")

    init(connections: [Connection] = []) {
        self.connections = connections
    }

    /// The cursor each `stream` call was given, in order.
    var streamCursors: [String?] { lock.withLock { streams } }
    /// The cursor each `poll` call was given, in order.
    var pollCursors: [String?] { lock.withLock { polls } }

    func initialCursor() async throws -> String? { initial }

    func stream(cursor: String?) -> AsyncThrowingStream<TransportEvent, Error> {
        let connection = lock.withLock { () -> Connection in
            streams.append(cursor)
            return connections.isEmpty ? Connection() : connections.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in connection.events { continuation.yield(event) }
            switch connection.ending {
            case .finish: continuation.finish()
            case .fail(let reason): continuation.finish(throwing: Failure(reason: reason))
            case .hang: break
            }
        }
    }

    func poll(cursor: String?) async throws -> (messages: [TransportMessage], cursor: String?) {
        lock.withLock { polls.append(cursor) }
        return pollReply
    }
}

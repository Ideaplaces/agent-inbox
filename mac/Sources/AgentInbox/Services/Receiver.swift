import Foundation
import Observation

/// Holds one connection to the transport open and hands over what arrives.
///
/// That is the whole job. What a message means, whether it deserves a
/// banner, when the inbox ages and what gets counted belong to other types.
/// This is the part that has to survive a laptop lid, a proxy that buffers
/// and a server that is down for the night, and it is exercised with a
/// scripted transport and a hand-wound clock, which only works because it
/// does nothing else.
///
/// Cursors are persisted per channel, so switching servers or topics starts
/// clean instead of replaying somebody else's history, and a restart never
/// double-delivers what you already saw.
@Observable
@MainActor
final class Receiver {
    enum Status: Equatable {
        case notConfigured
        case connecting
        case connected(Date)
        case failed(String)

        var isHealthy: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// Where to connect and which cursor to resume from.
    ///
    /// Asked for again before every connection, so a settings change takes
    /// effect at the next restart with nothing told about it. Changing the
    /// server or topic changes the key, which retires the old cursor.
    struct Channel {
        let transport: any Transport
        let cursorKey: String
    }

    private(set) var status: Status = .notConfigured

    private let channel: @MainActor () -> Channel?
    private let deliver: @MainActor ([TransportMessage]) -> Void
    private let sleeper: any Sleeper
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// Flipped once a connection is opened but never acknowledged, which is
    /// what a proxy that buffers responses looks like from here.
    private var streamingWorks = true
    /// Whether the current connection has received the server's `open`.
    /// State rather than a local so the watchdog can read it from its own task.
    private var acknowledged = false
    private var cursorKey = "cursor.none"

    /// ntfy answers a new connection with an `open` event immediately. If one
    /// does not arrive, something between here and the server is holding the
    /// response until it is complete, which for a connection that never
    /// completes means silence forever. That is the failure worth detecting:
    /// it looks exactly like nothing happening.
    static let openAcknowledgementTimeout = Duration.seconds(10)

    /// How long to wait between polls once streaming has been given up on.
    static let pollInterval = Duration.seconds(15)

    /// How long to wait before reconnecting. Doubling, capped, so a server
    /// that is down is not hammered and a blip costs a second.
    static func backoff(afterFailures failures: Int) -> Duration {
        .seconds(min(60, 1 << min(failures, 6)))
    }

    /// `deliver` gets every batch in wire order and decides what it means.
    /// Real time unless a test hands in a clock it can wind.
    init(
        channel: @escaping @MainActor () -> Channel?,
        deliver: @escaping @MainActor ([TransportMessage]) -> Void,
        sleeper: any Sleeper = RealSleeper(),
        defaults: UserDefaults = .standard
    ) {
        self.channel = channel
        self.deliver = deliver
        self.sleeper = sleeper
        self.defaults = defaults
    }

    func start() {
        stop()
        consecutiveFailures = 0
        streamingWorks = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.receive()
                guard !Task.isCancelled else { return }
                try? await self.sleeper.sleep(
                    for: Self.backoff(afterFailures: self.consecutiveFailures))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// A Mac that has been asleep has a dead connection and does not know it.
    /// Reconnecting immediately is the difference between messages waiting for
    /// you when you open the lid and messages arriving up to a minute later.
    func wake() {
        guard task != nil else { return }
        restart()
    }

    /// Re-read configuration and resume. Called whenever settings change.
    func restart() {
        stop()
        start()
    }

    private var cursor: String? {
        get { defaults.string(forKey: cursorKey) }
        set { defaults.set(newValue, forKey: cursorKey) }
    }

    /// One connection's worth of work: open it, deliver what comes, and
    /// return when it ends. The caller reconnects.
    private func receive() async {
        guard let channel = channel() else {
            status = .notConfigured
            return
        }
        cursorKey = channel.cursorKey
        if case .notConfigured = status { status = .connecting }

        do {
            if cursor == nil {
                // First run on this channel: start from now, not from history,
                // so the inbox does not open full of yesterday's sessions.
                cursor = try await channel.transport.initialCursor()
            }

            if streamingWorks {
                try await listen(to: channel.transport)
            } else {
                try await pollOnce(channel.transport)
                try await sleeper.sleep(for: Self.pollInterval)
            }
            consecutiveFailures = 0
        } catch is CancellationError {
            return
        } catch {
            consecutiveFailures += 1
            // One blip on a laptop that just woke is not worth a red dot.
            if consecutiveFailures >= 2 {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private enum Outcome {
        case watchdogFired
        case streamEnded
    }

    /// Sit on an open connection until it ends.
    ///
    /// The watchdog is the point: a connection that opens and then says
    /// nothing at all is indistinguishable from a quiet one, except that ntfy
    /// always acknowledges immediately. No acknowledgement means something in
    /// the middle is buffering the response, and a buffered stream never
    /// arrives, so fall back to asking repeatedly rather than waiting forever
    /// for a message that is already sitting in somebody's proxy.
    ///
    /// The two run as siblings in a group so that the watchdog can end the
    /// connection, not just flag it. Flagging alone left the receiver sitting
    /// on the silent stream until the transport's own idle timeout gave up,
    /// two minutes later, and only then did the fallback begin.
    private func listen(to transport: any Transport) async throws {
        acknowledged = false
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { @MainActor [sleeper] in
                try await sleeper.sleep(for: Self.openAcknowledgementTimeout)
                return .watchdogFired
            }
            group.addTask { @MainActor in
                for try await event in transport.stream(cursor: self.cursor) {
                    self.handle(event)
                }
                return .streamEnded
            }
            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                switch outcome {
                case .watchdogFired where !acknowledged:
                    streamingWorks = false
                    return
                case .watchdogFired:
                    // Acknowledged in time. The connection carries on.
                    continue
                case .streamEnded:
                    return
                }
            }
        }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .opened:
            acknowledged = true
            consecutiveFailures = 0
            status = .connected(sleeper.now)
        case .message(let message, let next):
            cursor = next ?? cursor
            status = .connected(sleeper.now)
            deliver([message])
        }
    }

    private func pollOnce(_ transport: any Transport) async throws {
        let result = try await transport.poll(cursor: cursor)
        cursor = result.cursor
        status = .connected(sleeper.now)
        deliver(result.messages)
    }
}

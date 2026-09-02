import Foundation
import Observation

/// Drives the transport on a timer and feeds everything else.
///
/// Cursors are persisted per channel, so switching transports or topics starts
/// clean instead of replaying somebody else's history, and a restart never
/// double-delivers what you already saw.
@Observable
@MainActor
final class Poller {
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

    private(set) var status: Status = .notConfigured

    private let settings: AppSettings
    private let store: InboxStore
    private let presence: Presence
    private let sleeper: any Sleeper
    private var task: Task<Void, Never>?
    private var housekeeping: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// Flipped once a connection is opened but never acknowledged, which is
    /// what a proxy that buffers responses looks like from here.
    private var streamingWorks = true
    /// Whether the current connection has received the server's `open`.
    /// State rather than a local so the watchdog can read it from its own task.
    private var acknowledged = false

    /// Presence and expiry run on their own clock now that messages arrive on
    /// their own. They used to ride the poll timer, which is why a change to
    /// the poll interval quietly changed how fast the inbox aged.
    static let housekeepingInterval = 15

    /// ntfy answers a new connection with an `open` event immediately. If one
    /// does not arrive, something between here and the server is holding the
    /// response until it is complete, which for a connection that never
    /// completes means silence forever. That is the failure worth detecting:
    /// it looks exactly like nothing happening.
    static let openAcknowledgementTimeout = Duration.seconds(10)

    /// How long to wait before reconnecting. Doubling, capped, so a server
    /// that is down is not hammered and a blip costs a second.
    static func backoff(afterFailures failures: Int) -> Duration {
        .seconds(min(60, 1 << min(failures, 6)))
    }

    /// Real time unless a test hands in a clock it can wind.
    init(
        settings: AppSettings, store: InboxStore, presence: Presence,
        sleeper: any Sleeper = RealSleeper()
    ) {
        self.settings = settings
        self.store = store
        self.presence = presence
        self.sleeper = sleeper
    }

    /// Fold one poll's messages into the store, in arrival order, and return
    /// the ones worth announcing.
    ///
    /// Order is the whole point. Control events are instructions rather than
    /// entries: applied, never shown, and an unrecognised one dropped rather
    /// than drawn as a row with a sentinel for a title. But they cannot all be
    /// applied up front. A turn that ends and is then typed into publishes an
    /// event and its clear seconds apart, so both land in one poll; clearing
    /// first would run against a store that does not hold the row yet, and the
    /// row would then never leave.
    ///
    /// Pending items are therefore flushed before each control, which makes the
    /// sequence inside a poll mean what it did on the wire.
    ///
    /// Nothing is announced for a conversation you are already in: the clear
    /// said you are there, so a banner for it would be about something you are
    /// looking at.
    @discardableResult
    func apply(_ messages: [TransportMessage]) -> [InboxItem] {
        var pending: [TransportMessage] = []
        var arrived: [InboxItem] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            arrived += store.add(
                pending.compactMap { MessageParser.parse($0, presence: presence.seconds) })
            pending.removeAll()
        }

        for message in messages {
            guard ControlEvent.isControl(message) else {
                pending.append(message)
                continue
            }
            flushPending()
            if case .clearSession(let session)? = ControlEvent.parse(message) {
                store.markSessionRead(session)
            }
        }
        flushPending()
        return arrived.filter { store.item(id: $0.id)?.isRead == false }
    }

    /// Identifies the channel a cursor belongs to. Changing topic or channel
    /// changes the key, which retires the old cursor automatically.
    private var cursorKey: String {
        switch settings.transport {
        case .none: return "cursor.none"
        case .ntfy: return "cursor.ntfy.\(settings.ntfyServer)/\(settings.ntfyTopic)"
        }
    }

    private var cursor: String? {
        get { UserDefaults.standard.string(forKey: cursorKey) }
        set { UserDefaults.standard.set(newValue, forKey: cursorKey) }
    }

    private var transport: Transport? {
        switch settings.transport {
        case .none:
            return nil
        case .ntfy:
            guard !settings.ntfyTopic.isEmpty else { return nil }
            return NtfyTransport(
                server: settings.ntfyServer, topic: settings.ntfyTopic,
                token: settings.ntfyToken)
        }
    }

    func start() {
        stop()
        consecutiveFailures = 0
        streamingWorks = true

        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.presence.tick(
                    interval: Self.housekeepingInterval,
                    idleThreshold: self.settings.idleThreshold)
                self.store.expire(afterMinutes: self.settings.expireMinutes)
                try? await self.sleeper.sleep(for: .seconds(Self.housekeepingInterval))
            }
        }

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
        housekeeping?.cancel()
        housekeeping = nil
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

    /// One connection's worth of work: open it, deliver what comes, and
    /// return when it ends. The caller reconnects.
    private func receive() async {
        guard let transport else {
            status = .notConfigured
            return
        }
        if case .notConfigured = status { status = .connecting }

        do {
            if cursor == nil {
                // First run on this channel: start from now, not from history,
                // so the inbox does not open full of yesterday's sessions.
                cursor = try await transport.initialCursor()
            }

            if streamingWorks {
                try await listen(to: transport)
            } else {
                try await pollOnce(transport)
                try await sleeper.sleep(for: .seconds(Self.housekeepingInterval))
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

    /// Sit on an open connection until it ends.
    ///
    /// The watchdog is the point: a connection that opens and then says
    /// nothing at all is indistinguishable from a quiet one, except that ntfy
    /// always acknowledges immediately. No acknowledgement means something in
    /// the middle is buffering the response, and a buffered stream never
    /// arrives, so fall back to asking repeatedly rather than waiting forever
    /// for a message that is already sitting in somebody's proxy.
    private func listen(to transport: any Transport) async throws {
        acknowledged = false
        let watchdog = Task { [weak self] in
            try? await self?.sleeper.sleep(for: Self.openAcknowledgementTimeout)
            guard let self, !Task.isCancelled, !self.acknowledged else { return }
            self.streamingWorks = false
        }
        defer { watchdog.cancel() }

        for try await event in transport.stream(cursor: cursor) {
            switch event {
            case .opened:
                acknowledged = true
                watchdog.cancel()
                consecutiveFailures = 0
                status = .connected(sleeper.now)
            case .message(let message, let next):
                cursor = next ?? cursor
                status = .connected(sleeper.now)
                deliver([message])
            }
            if !streamingWorks { return }
        }
    }

    private func pollOnce(_ transport: any Transport) async throws {
        let result = try await transport.poll(cursor: cursor)
        cursor = result.cursor
        status = .connected(sleeper.now)
        deliver(result.messages)
    }

    private func deliver(_ messages: [TransportMessage]) {
        for item in apply(messages) {
            Notifier.post(item, soundName: settings.soundName)
            countForUsage(item)
        }
        reportUsageIfADayHasPassed()
    }

    /// Tally one arrival. Kind only, and only in memory on this Mac until a
    /// day's worth is sent as a single number.
    private func countForUsage(_ item: InboxItem) {
        guard settings.shareUsageData else { return }
        switch item.kind {
        case .finished: settings.pendingFinished += 1
        case .needsYou: settings.pendingNeedsYou += 1
        }
    }

    /// One event a day, carrying the counts, and only when switched on.
    ///
    /// Driven off the poll rather than a timer of its own: the poll is already
    /// the app's heartbeat, and a Mac that is asleep or offline should report
    /// when it wakes rather than on a schedule that ran without it.
    private func reportUsageIfADayHasPassed() {
        guard settings.shareUsageData, !settings.analyticsID.isEmpty else { return }
        let now = sleeper.now
        guard Analytics.shouldSend(last: settings.analyticsLastSent, now: now) else { return }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        Analytics.send(Analytics.payload(
            distinctID: settings.analyticsID,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            osVersion: "\(os.majorVersion).\(os.minorVersion)",
            finished: settings.pendingFinished,
            needsYou: settings.pendingNeedsYou,
            watchMode: settings.watchMode,
            selfHosted: settings.ntfyServer != AppSettings.publicNtfyServer,
            customTags: settings.watchTags != AppSettings.defaultWatchTags))

        settings.analyticsLastSent = now
        settings.pendingFinished = 0
        settings.pendingNeedsYou = 0
    }

    /// Send one event through the real pipeline so the user can see it work.
    func sendTestEvent() async -> String? {
        let script = SenderConfig.notifyScript
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return "notify.sh is not installed yet. Set up this Mac first."
        }
        let payload = """
        {"session_id":"agent-inbox-test","cwd":"\(FileManager.default.currentDirectoryPath)",\
        "message":"Test notification from Agent Inbox"}
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "notification"]
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
                ? nil
                : "notify.sh exited with status \(process.terminationStatus)"
        } catch {
            return error.localizedDescription
        }
    }
}

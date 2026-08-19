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
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(settings: AppSettings, store: InboxStore, presence: Presence) {
        self.settings = settings
        self.store = store
        self.presence = presence
    }

    /// Identifies the channel a cursor belongs to. Changing topic or channel
    /// changes the key, which retires the old cursor automatically.
    private var cursorKey: String {
        switch settings.transport {
        case .none: return "cursor.none"
        case .ntfy: return "cursor.ntfy.\(settings.ntfyServer)/\(settings.ntfyTopic)"
        case .discord: return "cursor.discord.\(settings.discordChannelID)"
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
            return NtfyTransport(server: settings.ntfyServer, topic: settings.ntfyTopic)
        case .discord:
            guard !settings.discordBotToken.isEmpty, !settings.discordChannelID.isEmpty else {
                return nil
            }
            return DiscordTransport(
                token: settings.discordBotToken, channelID: settings.discordChannelID)
        }
    }

    func start() {
        task?.cancel()
        consecutiveFailures = 0
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = max(5, self.settings.pollSeconds)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Re-read configuration and resume. Called whenever settings change.
    func restart() {
        stop()
        start()
    }

    private func tick() async {
        presence.tick(interval: max(5, settings.pollSeconds), idleThreshold: settings.idleThreshold)
        store.expire(afterMinutes: settings.expireMinutes)

        guard let transport else {
            status = .notConfigured
            return
        }
        if case .notConfigured = status { status = .connecting }

        do {
            if cursor == nil {
                // First run on this channel: start from now, not from history.
                cursor = try await transport.initialCursor()
                status = .connected(Date())
                consecutiveFailures = 0
                return
            }

            let result = try await transport.poll(cursor: cursor)
            cursor = result.cursor
            consecutiveFailures = 0
            status = .connected(Date())

            let parsed = result.messages.compactMap {
                MessageParser.parse($0, presence: presence.seconds)
            }
            let fresh = store.add(parsed)
            for item in fresh {
                Notifier.post(item, soundName: settings.soundName)
            }
        } catch {
            consecutiveFailures += 1
            // One blip on a laptop that just woke is not worth a red dot.
            if consecutiveFailures >= 2 {
                status = .failed(error.localizedDescription)
            }
        }
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

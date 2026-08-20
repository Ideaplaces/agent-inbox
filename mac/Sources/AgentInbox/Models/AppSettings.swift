import Foundation
import Observation
import Security
#if canImport(AppKit)
import AppKit
#endif

enum TransportKind: String, CaseIterable, Identifiable {
    case none
    case ntfy
    case discord

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Not configured"
        case .ntfy: return "ntfy"
        case .discord: return "Discord"
        }
    }
}

/// Everything the app and the shell senders need to agree on.
///
/// Values the sender hooks read stay mirrored into `~/.agent-inbox/` so a
/// machine that still runs the bash scripts keeps working, and so the app can
/// adopt an existing bash install without asking the user to retype anything.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    /// Set while reading existing on-disk state. Every setter mirrors to
    /// `~/.agent-inbox/`, so without this, adopting a shell install would
    /// overwrite the very file it is about to read.
    private var isAdopting = false

    var transport: TransportKind {
        didSet { defaults.set(transport.rawValue, forKey: "transport"); sync() }
    }
    var ntfyServer: String {
        didSet { defaults.set(ntfyServer, forKey: "ntfyServer"); sync() }
    }
    var ntfyTopic: String {
        didSet { defaults.set(ntfyTopic, forKey: "ntfyTopic"); sync() }
    }
    var discordChannelID: String {
        didSet { defaults.set(discordChannelID, forKey: "discordChannelID"); sync() }
    }
    var discordGuildID: String {
        didSet { defaults.set(discordGuildID, forKey: "discordGuildID"); sync() }
    }
    var discordBotToken: String {
        didSet { Keychain.set(discordBotToken, for: "discord-bot-token") }
    }
    var discordWebhookURL: String {
        didSet { Keychain.set(discordWebhookURL, for: "discord-webhook-url"); sync() }
    }

    var pollSeconds: Int {
        didSet { defaults.set(pollSeconds, forKey: "pollSeconds") }
    }
    var expireMinutes: Int {
        didSet { defaults.set(expireMinutes, forKey: "expireMinutes") }
    }
    var idleThreshold: Int {
        didSet { defaults.set(idleThreshold, forKey: "idleThreshold") }
    }
    var soundName: String {
        didSet { defaults.set(soundName, forKey: "soundName") }
    }
    /// Sender-side: turns shorter than this never reach the inbox.
    var minSeconds: Int {
        didSet { defaults.set(minSeconds, forKey: "minSeconds"); sync() }
    }
    /// Sender-side: the machine name shown in every message. On a remote box
    /// this must equal its SSH host alias so the inbox can open it.
    var hostLabel: String {
        didSet { defaults.set(hostLabel, forKey: "hostLabel"); sync() }
    }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    private init() {
        defaults.register(defaults: [
            "ntfyServer": "https://ntfy.sh",
            "pollSeconds": 15,
            "expireMinutes": 5,
            "idleThreshold": 90,
            "minSeconds": 45,
            "soundName": "",
        ])
        transport = TransportKind(rawValue: defaults.string(forKey: "transport") ?? "") ?? .none
        // ntfy is the default because it needs no account, no bot, and no
        // channel to provision: the topic name is the whole channel. Discord
        // is the deliberate choice you make when you want a durable archive.
        ntfyServer = defaults.string(forKey: "ntfyServer") ?? "https://ntfy.sh"
        ntfyTopic = defaults.string(forKey: "ntfyTopic") ?? ""
        discordChannelID = defaults.string(forKey: "discordChannelID") ?? ""
        discordGuildID = defaults.string(forKey: "discordGuildID") ?? ""
        discordBotToken = Keychain.get("discord-bot-token") ?? ""
        discordWebhookURL = Keychain.get("discord-webhook-url") ?? ""
        pollSeconds = defaults.integer(forKey: "pollSeconds")
        expireMinutes = defaults.integer(forKey: "expireMinutes")
        idleThreshold = defaults.integer(forKey: "idleThreshold")
        soundName = defaults.string(forKey: "soundName") ?? ""
        minSeconds = defaults.integer(forKey: "minSeconds")
        hostLabel = defaults.string(forKey: "hostLabel") ?? Host.current().localizedName ?? "mac"
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    /// The topic is the only secret protecting message bodies, so it has to be
    /// long enough that guessing it is not a threat model.
    nonisolated static func randomNtfyTopic() -> String {
        let user = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber }
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "agent-inbox-\(user.isEmpty ? "user" : user)-\(hex)"
    }

    var isConfigured: Bool {
        switch transport {
        case .none: return false
        case .ntfy: return !ntfyTopic.isEmpty
        case .discord: return !discordBotToken.isEmpty && !discordChannelID.isEmpty
        }
    }

    /// Where the transport's own history lives, for "open the channel".
    var historyURL: URL? {
        switch transport {
        case .none:
            return nil
        case .ntfy:
            return URL(string: "\(ntfyServer)/\(ntfyTopic)")
        case .discord:
            if !discordGuildID.isEmpty {
                return URL(string: "discord://-/channels/\(discordGuildID)/\(discordChannelID)")
            }
            return URL(string: "https://discord.com/channels/@me/\(discordChannelID)")
        }
    }

    /// Mirror the sender-visible settings into `~/.agent-inbox/`, so hooks
    /// installed by this app and hooks installed by the bash script behave the
    /// same and read the same values.
    func sync() {
        guard !isAdopting else { return }
        SenderConfig.write(senderSnapshot)
    }

    var senderSnapshot: SenderSnapshot {
        SenderSnapshot(
            transport: transport,
            ntfyTopic: ntfyTopic,
            ntfyServer: ntfyServer,
            discordWebhookURL: discordWebhookURL,
            discordChannelID: discordChannelID,
            discordGuildID: discordGuildID,
            minSeconds: minSeconds,
            hostLabel: hostLabel)
    }

    /// Take over an existing bash install without making the user retype it.
    ///
    /// Everything is read into memory first: the setters mirror back to the
    /// same directory, so touching one value before reading the rest would
    /// destroy the source.
    func adoptExistingShellInstall() {
        guard transport == .none else { return }

        let token = SenderConfig.readFile("bot-token")
        let channel = SenderConfig.readFile("channel-id")
        let guild = SenderConfig.readFile("guild-id")
        let webhook = SenderConfig.readFile("webhook-url")
        let topic = SenderConfig.readFile("ntfy-topic")
        let shellConfig = SenderConfig.readShellConfig()

        isAdopting = true
        defer {
            isAdopting = false
            sync()
        }

        for (key, value) in shellConfig {
            switch key {
            case "POLL_SECONDS": pollSeconds = Int(value) ?? pollSeconds
            case "EXPIRE_MINUTES": expireMinutes = Int(value) ?? expireMinutes
            case "IDLE_THRESHOLD": idleThreshold = Int(value) ?? idleThreshold
            case "MIN_SECONDS": minSeconds = Int(value) ?? minSeconds
            case "NOTIFY_SOUND": soundName = value
            case "HOST_LABEL": if !value.isEmpty { hostLabel = value }
            case "NTFY_SERVER": if !value.isEmpty { ntfyServer = value }
            default: break
            }
        }

        if let token, let channel, !token.isEmpty, !channel.isEmpty {
            discordBotToken = token
            discordChannelID = channel
            discordGuildID = guild ?? ""
            discordWebhookURL = webhook ?? ""
            transport = .discord
        } else if let topic, !topic.isEmpty {
            ntfyTopic = topic
            transport = .ntfy
        }
    }
}

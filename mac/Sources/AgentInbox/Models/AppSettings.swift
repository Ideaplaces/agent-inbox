import Foundation
import Observation
import Security
#if canImport(AppKit)
import AppKit
#endif

enum TransportKind: String, CaseIterable, Identifiable {
    case none
    case ntfy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Not configured"
        case .ntfy: return "ntfy"
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
    /// Bearer token for a self-hosted ntfy. Empty for ntfy.sh, which has no
    /// accounts. In the Keychain rather than UserDefaults because it is a
    /// credential, and mirrored to the sender's own file by `sync()`.
    var ntfyToken: String {
        didSet { Keychain.set(ntfyToken, for: "ntfy-token"); sync() }
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
    /// Sender-side: "all" reports every conversation and lets #mute silence
    /// one; "tagged" stays quiet until a conversation is tagged. Owned here
    /// because the app rewrites the sender config wholesale, so a key it does
    /// not know about would be erased on the next change.
    var watchMode: String {
        didSet { defaults.set(watchMode, forKey: "watchMode"); sync() }
    }
    /// Sender-side: the tags that turn a conversation on, space separated.
    var watchTags: String {
        didSet { defaults.set(watchTags, forKey: "watchTags"); sync() }
    }
    /// Sender-side: the tag that silences a conversation.
    var muteTag: String {
        didSet { defaults.set(muteTag, forKey: "muteTag"); sync() }
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
            "ntfyServer": AppSettings.publicNtfyServer,
            "pollSeconds": 15,
            "expireMinutes": 5,
            "idleThreshold": 90,
            "minSeconds": 45,
            "watchMode": "all",
            "watchTags": AppSettings.defaultWatchTags,
            "muteTag": AppSettings.defaultMuteTag,
            "soundName": "",
        ])
        transport = TransportKind(rawValue: defaults.string(forKey: "transport") ?? "") ?? .none
        // ntfy is the default because it needs no account, no bot, and no
        // channel to provision: the topic name is the whole channel. Discord
        // is the deliberate choice you make when you want a durable archive.
        ntfyServer = defaults.string(forKey: "ntfyServer") ?? Self.publicNtfyServer
        ntfyTopic = defaults.string(forKey: "ntfyTopic") ?? ""
        ntfyToken = Keychain.get("ntfy-token") ?? ""
        pollSeconds = defaults.integer(forKey: "pollSeconds")
        expireMinutes = defaults.integer(forKey: "expireMinutes")
        idleThreshold = defaults.integer(forKey: "idleThreshold")
        soundName = defaults.string(forKey: "soundName") ?? ""
        minSeconds = defaults.integer(forKey: "minSeconds")
        watchMode = defaults.string(forKey: "watchMode") ?? "all"
        watchTags = defaults.string(forKey: "watchTags") ?? AppSettings.defaultWatchTags
        muteTag = defaults.string(forKey: "muteTag") ?? AppSettings.defaultMuteTag
        hostLabel = defaults.string(forKey: "hostLabel") ?? Host.current().localizedName ?? "mac"
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    // Spoken forms ship alongside the typed ones because dictation cannot
    // produce a "#": across 37,000 dictations, "hashtag notify" never once
    // became "#notify". Saying "watch this" has to be enough.
    static let defaultWatchTags = "#notify, #inbox, #watch, #agent-inbox, watch this, notify me"
    static let defaultMuteTag = "#mute, stop notifying"

    /// Tidied into what the sender will actually split on.
    ///
    /// A comma anywhere means the tags are phrases, so only commas separate
    /// them and the spaces inside a tag are kept. Without one, whitespace
    /// separates, which is the older "#a #b" form.
    static func normalizeTags(_ raw: String) -> String {
        let parts: [String] = raw.contains(",")
            ? raw.split(separator: ",").map(String.init)
            : raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: raw.contains(",") ? ", " : " ")
    }

    /// The topic is the only secret protecting message bodies, so it has to be
    /// long enough that guessing it is not a threat model.
    /// The free public ntfy, and the reason this installs without an account.
    ///
    /// Spelled once because three separate things key off it: the default a
    /// fresh install lands on, the placeholder in setup, and whether the token
    /// field is shown at all. When they were three string literals, changing
    /// the default would have left the token field hidden on a server that
    /// needs one, and the failure is a silent 403 with an empty inbox.
    nonisolated static let publicNtfyServer = "https://ntfy.sh"

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
        }
    }

    /// Where the transport's own history lives, for "open the channel".
    var historyURL: URL? {
        switch transport {
        case .none:
            return nil
        case .ntfy:
            return URL(string: "\(ntfyServer)/\(ntfyTopic)")
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
            ntfyToken: ntfyToken,
            minSeconds: minSeconds,
            hostLabel: hostLabel,
            watchMode: watchMode,
            watchTags: watchTags,
            muteTag: muteTag)
    }

    /// Take over an existing bash install without making the user retype it.
    ///
    /// Everything is read into memory first: the setters mirror back to the
    /// same directory, so touching one value before reading the rest would
    /// destroy the source.
    func adoptExistingShellInstall() {
        guard transport == .none else { return }

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
            case "WATCH_MODE": if value == "all" || value == "tagged" { watchMode = value }
            case "WATCH_TAGS": if !value.isEmpty { watchTags = value }
            case "MUTE_TAG": if !value.isEmpty { muteTag = value }
            case "NTFY_SERVER": if !value.isEmpty { ntfyServer = value }
            default: break
            }
        }

        // A machine that used to send to Discord adopts as unconfigured rather
        // than half-configured, and setup generates it a topic. Its old files
        // are cleared by the writer, so it stops publishing to a channel this
        // app can no longer read.
        if let topic, !topic.isEmpty {
            ntfyTopic = topic
            transport = .ntfy
        }
    }
}

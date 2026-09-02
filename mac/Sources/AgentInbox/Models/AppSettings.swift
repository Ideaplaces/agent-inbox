import Foundation
import Observation
import Security
#if canImport(AppKit)
import AppKit
#endif

enum TransportKind: String, CaseIterable, Identifiable, Codable {
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
///
/// The settings themselves are one `SettingsValues`, stored whole. The named
/// properties below are windows onto it, kept so a view can still bind to
/// `$settings.ntfyTopic` and so a call site reads as it always did.
@Observable
final class AppSettings {
    /// The one key everything is under. The flat per-setting keys an older
    /// build wrote are read once, by `SettingsValues.init(flatKeysIn:)`, on
    /// the first launch that finds this key absent.
    static let storageKey = "settings"

    private let defaults: UserDefaults
    private let secrets: any SecretStore

    /// Every setting except the token. One write per change, and the shell
    /// config is rewritten only when something the senders read has changed:
    /// picking a different sound must not touch a file the hooks parse.
    var values: SettingsValues {
        didSet {
            guard values != oldValue else { return }
            persist()
            if values.senderSnapshot(token: ntfyToken) != oldValue.senderSnapshot(token: ntfyToken) {
                sync()
            }
        }
    }

    /// Bearer token for a self-hosted ntfy. Empty for ntfy.sh, which has no
    /// accounts. In the Keychain rather than UserDefaults because it is a
    /// credential, and mirrored to the sender's own file by `sync()`.
    var ntfyToken: String {
        didSet { secrets.set(ntfyToken, for: "ntfy-token"); sync() }
    }

    var transport: TransportKind {
        get { values.transport }
        set { values.transport = newValue }
    }
    var ntfyServer: String {
        get { values.ntfyServer }
        set { values.ntfyServer = newValue }
    }
    var ntfyTopic: String {
        get { values.ntfyTopic }
        set { values.ntfyTopic = newValue }
    }
    var expireMinutes: Int {
        get { values.expireMinutes }
        set { values.expireMinutes = newValue }
    }
    var idleThreshold: Int {
        get { values.idleThreshold }
        set { values.idleThreshold = newValue }
    }
    var soundName: String {
        get { values.soundName }
        set { values.soundName = newValue }
    }
    /// Sender-side: "all" reports every conversation and lets #mute silence
    /// one; "tagged" stays quiet until a conversation is tagged. Owned here
    /// because the app rewrites the sender config wholesale, so a key it does
    /// not know about would be erased on the next change.
    var watchMode: String {
        get { values.watchMode }
        set { values.watchMode = newValue }
    }
    /// Sender-side: the tags that turn a conversation on, space separated.
    var watchTags: String {
        get { values.watchTags }
        set { values.watchTags = newValue }
    }
    /// Sender-side: the tag that silences a conversation.
    var muteTag: String {
        get { values.muteTag }
        set { values.muteTag = newValue }
    }
    /// Sender-side: turns shorter than this never reach the inbox.
    var minSeconds: Int {
        get { values.minSeconds }
        set { values.minSeconds = newValue }
    }
    /// Sender-side: the machine name shown in every message. On a remote box
    /// this must equal its SSH host alias so the inbox can open it.
    var hostLabel: String {
        get { values.hostLabel }
        set { values.hostLabel = newValue }
    }
    var hasCompletedOnboarding: Bool {
        get { values.hasCompletedOnboarding }
        set { values.hasCompletedOnboarding = newValue }
    }
    /// Whether anyone has yet said whether this app opens at login.
    ///
    /// First launch turns it on for you, so the answer to "why did it stop
    /// notifying me" is never "it was not running". That is a default, not a
    /// policy: the moment a person or a script decides either way, the
    /// decision is recorded here and no later launch overrides it.
    var hasDecidedLoginItem: Bool {
        get { values.hasDecidedLoginItem }
        set { values.hasDecidedLoginItem = newValue }
    }
    /// Anonymous usage counts, off until you say otherwise.
    ///
    /// Not mirrored into `~/.agent-inbox/`, unlike most of this file. The bash
    /// senders report nothing and never will: `notify.sh` runs as a hook on
    /// every turn on every machine and must never block a session, which rules
    /// out putting a network call to an analytics endpoint in that path. The
    /// app already sees every message, so it can count them without the
    /// senders knowing anything about it.
    var shareUsageData: Bool {
        get { values.shareUsageData }
        set {
            var next = values
            next.shareUsageData = newValue
            // A fresh id each time it is switched on, so turning it off and on
            // again is a new anonymous install rather than a resumed identity.
            if newValue { next.analyticsID = UUID().uuidString }
            values = next
        }
    }
    /// A random id, made when usage sharing is turned on. Not derived from
    /// anything about the machine or the person, and thrown away when sharing
    /// goes off.
    var analyticsID: String {
        get { values.analyticsID }
        set { values.analyticsID = newValue }
    }
    var analyticsLastSent: Date? {
        get { values.analyticsLastSent }
        set { values.analyticsLastSent = newValue }
    }
    /// Counted locally between sends, so one event a day can carry the total
    /// and no event has to be sent per notification.
    var pendingFinished: Int {
        get { values.pendingFinished }
        set { values.pendingFinished = newValue }
    }
    var pendingNeedsYou: Int {
        get { values.pendingNeedsYou }
        set { values.pendingNeedsYou = newValue }
    }

    /// The snapshot if there is one, else whatever the flat keys say, which
    /// on a fresh install is the defaults. A migrated or fresh value is
    /// written back at once, so the flat keys are never consulted again.
    init(defaults: UserDefaults = .standard, secrets: any SecretStore = LoginKeychain()) {
        self.defaults = defaults
        self.secrets = secrets
        let stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(SettingsValues.self, from: $0) }
        values = stored ?? SettingsValues(flatKeysIn: defaults)
        ntfyToken = secrets.get("ntfy-token") ?? ""
        if stored == nil { persist() }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(values), forKey: Self.storageKey)
    }

    /// Force the write to disk. Only for a process that is about to `exit`,
    /// which is what the command-line flags do.
    func flush() {
        defaults.synchronize()
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

    /// The banner sound a fresh install gets.
    ///
    /// A notification you have to be looking at is half a notification, and the
    /// whole point is to be told while you are doing something else. Silent was
    /// the old default and meant most people never heard a single one.
    ///
    /// Named without an extension, which is what resolves against the system
    /// sounds in /System/Library/Sounds. Set it to "" for silence.
    nonisolated static let defaultSoundName = "Pop"

    /// The free public ntfy, and the reason this installs without an account.
    ///
    /// Spelled once because three separate things key off it: the default a
    /// fresh install lands on, the placeholder in setup, and whether the token
    /// field is shown at all. When they were three string literals, changing
    /// the default would have left the token field hidden on a server that
    /// needs one, and the failure is a silent 403 with an empty inbox.
    nonisolated static let publicNtfyServer = "https://ntfy.sh"

    /// What actually protects the messages, which is not the same answer on
    /// every server and is the thing this pane used to get wrong.
    ///
    /// On ntfy.sh a topic needs no account: the name *is* the channel, so the
    /// name is also the password. A self-hosted server can require a token, and
    /// once one is set the server decides who gets in and the topic is only a
    /// name. Reached without a token, a self-hosted server is back to the first
    /// case.
    enum AccessModel {
        case topicIsTheSecret
        case tokenIsTheSecret
    }

    nonisolated static func accessModel(server: String, token: String) -> AccessModel {
        // The token field is hidden while the server is ntfy.sh, so a value
        // left behind by a previous server must not change what is claimed
        // here. Emptiness is tested the way NtfyTransport tests it, so the pane
        // and the request agree on whether a token is being sent.
        guard server != publicNtfyServer, !token.isEmpty else { return .topicIsTheSecret }
        return .tokenIsTheSecret
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
        SenderConfig.write(senderSnapshot)
    }

    var senderSnapshot: SenderSnapshot {
        values.senderSnapshot(token: ntfyToken)
    }

    /// Take over an existing bash install without making the user retype it.
    ///
    /// Everything is read into memory first and applied as one assignment at
    /// the end. Assigning `values` mirrors back to the same directory, so a
    /// write before the reads were finished would destroy the source.
    func adoptExistingShellInstall() {
        guard transport == .none else { return }

        let topic = SenderConfig.readFile("ntfy-topic")
        let shellConfig = SenderConfig.readShellConfig()

        var next = values
        for (key, value) in shellConfig {
            switch key {
            case "EXPIRE_MINUTES": next.expireMinutes = Int(value) ?? next.expireMinutes
            case "IDLE_THRESHOLD": next.idleThreshold = Int(value) ?? next.idleThreshold
            case "MIN_SECONDS": next.minSeconds = Int(value) ?? next.minSeconds
            case "NOTIFY_SOUND": next.soundName = value
            case "HOST_LABEL": if !value.isEmpty { next.hostLabel = value }
            case "WATCH_MODE": if value == "all" || value == "tagged" { next.watchMode = value }
            case "WATCH_TAGS": if !value.isEmpty { next.watchTags = value }
            case "MUTE_TAG": if !value.isEmpty { next.muteTag = value }
            case "NTFY_SERVER": if !value.isEmpty { next.ntfyServer = value }
            default: break
            }
        }

        // A machine that used to send to Discord adopts as unconfigured rather
        // than half-configured, and setup generates it a topic. Its old files
        // are cleared by the writer, so it stops publishing to a channel this
        // app can no longer read.
        if let topic, !topic.isEmpty {
            next.ntfyTopic = topic
            next.transport = .ntfy
        }

        // One assignment, so the mirror is written once and only if something
        // the senders read actually changed. The launch path calls `sync()`
        // right after this regardless.
        values = next
    }
}

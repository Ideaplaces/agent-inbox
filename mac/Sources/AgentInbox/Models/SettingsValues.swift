import Foundation

/// Every setting, as one value.
///
/// Persisted whole, as JSON under a single UserDefaults key, rather than as
/// one key per setting. Twenty-five properties each with their own `didSet`
/// meant twenty-five places where a write could be forgotten, and no way to
/// ask "did anything the senders care about change" without listing them all
/// again. One struct, one write, and a comparison against the previous value
/// answers that question.
///
/// The defaults here are the defaults a fresh install gets. They used to be
/// registered into UserDefaults; now the struct carries them, so a missing
/// value is the default by construction and not by a lookup that had to be
/// remembered.
///
/// The ntfy token is not here on purpose. It is a credential and lives in the
/// Keychain; see `AppSettings.ntfyToken`.
struct SettingsValues: Codable, Equatable {
    var transport: TransportKind = .none
    // ntfy is the default because it needs no account, no bot, and no
    // channel to provision: the topic name is the whole channel.
    var ntfyServer = AppSettings.publicNtfyServer
    var ntfyTopic = ""
    var expireMinutes = 5
    var idleThreshold = 90
    var soundName = AppSettings.defaultSoundName
    /// Zero: every turn reports. Someone who just installed says "hello" to
    /// an agent to see whether this works, and a 45-second floor turns that
    /// first test into silence. The floor is a visible setting now, so anyone
    /// who finds every turn too chatty raises it.
    var minSeconds = 0
    var watchMode = "all"
    var watchTags = AppSettings.defaultWatchTags
    var muteTag = AppSettings.defaultMuteTag
    var hostLabel = SettingsValues.thisMachine
    var hasCompletedOnboarding = false
    var hasDecidedLoginItem = false
    var shareUsageData = false
    var analyticsID = ""
    var analyticsLastSent: Date?
    var pendingFinished = 0
    var pendingNeedsYou = 0

    static var thisMachine: String { Host.current().localizedName ?? "mac" }

    init() {}

    /// Field by field, each falling back to its default, so a snapshot written
    /// by an older build that did not know a field still decodes. Synthesized
    /// decoding would throw on the first missing key and the whole snapshot,
    /// every setting in it, would be thrown away with it.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decodeIfPresent(TransportKind.self, forKey: .transport) ?? transport
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? ntfyServer
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? ntfyTopic
        expireMinutes = try c.decodeIfPresent(Int.self, forKey: .expireMinutes) ?? expireMinutes
        idleThreshold = try c.decodeIfPresent(Int.self, forKey: .idleThreshold) ?? idleThreshold
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? soundName
        minSeconds = try c.decodeIfPresent(Int.self, forKey: .minSeconds) ?? minSeconds
        watchMode = try c.decodeIfPresent(String.self, forKey: .watchMode) ?? watchMode
        watchTags = try c.decodeIfPresent(String.self, forKey: .watchTags) ?? watchTags
        muteTag = try c.decodeIfPresent(String.self, forKey: .muteTag) ?? muteTag
        hostLabel = try c.decodeIfPresent(String.self, forKey: .hostLabel) ?? hostLabel
        hasCompletedOnboarding =
            try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? hasCompletedOnboarding
        hasDecidedLoginItem =
            try c.decodeIfPresent(Bool.self, forKey: .hasDecidedLoginItem) ?? hasDecidedLoginItem
        shareUsageData = try c.decodeIfPresent(Bool.self, forKey: .shareUsageData) ?? shareUsageData
        analyticsID = try c.decodeIfPresent(String.self, forKey: .analyticsID) ?? analyticsID
        analyticsLastSent = try c.decodeIfPresent(Date.self, forKey: .analyticsLastSent)
        pendingFinished = try c.decodeIfPresent(Int.self, forKey: .pendingFinished) ?? pendingFinished
        pendingNeedsYou = try c.decodeIfPresent(Int.self, forKey: .pendingNeedsYou) ?? pendingNeedsYou
    }

    /// The values an install from before the snapshot existed left behind,
    /// one UserDefaults key per setting. Read once, on the first launch that
    /// finds no snapshot, and never again.
    ///
    /// Each read falls back the way the old initialiser did after registering
    /// its defaults, so the migrated values are exactly what that build was
    /// showing. `integer(forKey:)` is avoided: it returns 0 for a missing key,
    /// which is the wrong answer for a setting whose default is 5.
    init(flatKeysIn defaults: UserDefaults) {
        transport = TransportKind(rawValue: defaults.string(forKey: "transport") ?? "") ?? .none
        ntfyServer = defaults.string(forKey: "ntfyServer") ?? ntfyServer
        ntfyTopic = defaults.string(forKey: "ntfyTopic") ?? ntfyTopic
        expireMinutes = defaults.object(forKey: "expireMinutes") as? Int ?? expireMinutes
        idleThreshold = defaults.object(forKey: "idleThreshold") as? Int ?? idleThreshold
        soundName = defaults.string(forKey: "soundName") ?? soundName
        minSeconds = defaults.object(forKey: "minSeconds") as? Int ?? minSeconds
        watchMode = defaults.string(forKey: "watchMode") ?? watchMode
        watchTags = defaults.string(forKey: "watchTags") ?? watchTags
        muteTag = defaults.string(forKey: "muteTag") ?? muteTag
        hostLabel = defaults.string(forKey: "hostLabel") ?? hostLabel
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        hasDecidedLoginItem = defaults.bool(forKey: "hasDecidedLoginItem")
        shareUsageData = defaults.bool(forKey: "shareUsageData")
        analyticsID = defaults.string(forKey: "analyticsID") ?? analyticsID
        analyticsLastSent = defaults.object(forKey: "analyticsLastSent") as? Date
        pendingFinished = defaults.object(forKey: "pendingFinished") as? Int ?? pendingFinished
        pendingNeedsYou = defaults.object(forKey: "pendingNeedsYou") as? Int ?? pendingNeedsYou
    }

    /// The part of this the bash senders read. The token comes from outside
    /// because it is not stored here.
    func senderSnapshot(token: String) -> SenderSnapshot {
        SenderSnapshot(
            transport: transport,
            ntfyTopic: ntfyTopic,
            ntfyServer: ntfyServer,
            ntfyToken: token,
            minSeconds: minSeconds,
            hostLabel: hostLabel,
            watchMode: watchMode,
            watchTags: watchTags,
            muteTag: muteTag)
    }
}

import Foundation

/// Exactly what the shell senders need to know. Passing this rather than the
/// whole settings object keeps the mirror free of the Keychain and UserDefaults.
struct SenderSnapshot {
    var transport: TransportKind
    var ntfyTopic: String = ""
    var ntfyServer: String = "https://ntfy.sh"
    var ntfyToken: String = ""
    var discordWebhookURL: String = ""
    var discordChannelID: String = ""
    var discordGuildID: String = ""
    var minSeconds: Int = 45
    var hostLabel: String = "mac"
    var watchMode: String = "all"
    var watchTags: String = "#notify, #inbox, #watch, #agent-inbox, watch this, notify me"
    var muteTag: String = "#mute, stop notifying"
}

/// `~/.agent-inbox/` is the contract between this app and the shell senders.
///
/// The app owns its own settings in UserDefaults and the Keychain, but the
/// hooks that fire inside Claude Code are still bash, and they read this
/// directory. Every user-visible setting that a sender needs is mirrored here.
enum SenderConfig {
    /// Overridable so tests can run against a temporary directory instead of
    /// the real one. Nothing else should write to it.
    static var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-inbox")

    static var notifyScript: URL { directory.appendingPathComponent("bin/notify.sh") }

    /// Marks a config file this app wrote. Its absence means the file came
    /// from the shell installer or the user's own hand, and must be backed up
    /// before it is replaced.
    private static let marker = "# Written by Agent Inbox.app."

    /// The `KEY=value` pairs from a shell-written `config`. It is bash, but the
    /// keys that matter are plain assignments.
    static func readShellConfig() -> [(String, String)] {
        guard let text = readFile("config") else { return [] }
        return text.split(separator: "\n").compactMap { line -> (String, String)? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (
                parts[0].trimmingCharacters(in: .whitespaces),
                parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            )
        }
    }

    static func readFile(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func write(_ contents: String, to name: String, mode: NSNumber = 0o600) {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Keep one copy of whatever was here before this app first wrote it.
    private static func backupExistingConfigOnce() {
        let url = directory.appendingPathComponent("config")
        let backup = directory.appendingPathComponent("config.bak.agent-inbox")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              !existing.hasPrefix(marker) else { return }
        try? fm.copyItem(at: url, to: backup)
    }

    /// Mirror the settings the bash senders read. Written on every change, so
    /// the app and the scripts can never disagree about where events go.
    static func write(_ settings: SenderSnapshot) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backupExistingConfigOnce()

        switch settings.transport {
        case .ntfy:
            write(settings.ntfyTopic, to: "ntfy-topic")
            // Its own file, not a line in `config`: config is written 0644 so
            // a sender running as another user can read it, and this is a
            // credential. Removed rather than blanked when there is none, so a
            // move from a self-hosted server back to ntfy.sh does not leave a
            // stale token on disk.
            let tokenFile = directory.appendingPathComponent("ntfy-token")
            if settings.ntfyToken.isEmpty {
                try? FileManager.default.removeItem(at: tokenFile)
            } else {
                write(settings.ntfyToken, to: "ntfy-token")
            }
        case .discord:
            if !settings.discordWebhookURL.isEmpty {
                write(settings.discordWebhookURL, to: "webhook-url")
            }
            write(settings.discordChannelID, to: "channel-id", mode: 0o644)
            if !settings.discordGuildID.isEmpty {
                write(settings.discordGuildID, to: "guild-id", mode: 0o644)
            }
        case .none:
            break
        }

        // Only the keys a sender reads. The watcher keys are gone: the app is
        // the watcher now, and it reads UserDefaults.
        var lines = [
            "\(marker) Sender-side settings for notify.sh.",
            "MIN_SECONDS=\(settings.minSeconds)",
            "WATCH_MODE=\(settings.watchMode)",
            // Quoted: the values start with # and are read by a shell.
            "WATCH_TAGS=\"\(settings.watchTags)\"",
            "MUTE_TAG=\"\(settings.muteTag)\"",
            "HOST_LABEL=\"\(settings.hostLabel)\"",
        ]
        if settings.transport == .ntfy, settings.ntfyServer != "https://ntfy.sh" {
            lines.append("NTFY_SERVER=\"\(settings.ntfyServer)\"")
        }
        write(lines.joined(separator: "\n") + "\n", to: "config", mode: 0o644)
    }

    /// Copy the bundled `notify.sh` to a stable path outside the app bundle.
    ///
    /// Hooks must survive the app being moved, updated, or quit, so they point
    /// at `~/.agent-inbox/bin/notify.sh` rather than into `/Applications`.
    @discardableResult
    static func installNotifyScript() -> Bool {
        guard let bundled = Bundle.main.url(forResource: "notify", withExtension: "sh") else {
            return false
        }
        let target = notifyScript
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: bundled, to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: target.path)
            return true
        } catch {
            return false
        }
    }
}

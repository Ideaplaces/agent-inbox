import Foundation
@testable import AgentInbox

/// Secrets that live and die with the process, so no test touches the login
/// keychain the test process shares with the installed app.
final class MemorySecrets: SecretStore {
    private var storage: [String: String] = [:]

    init() {}

    func get(_ account: String) -> String? { storage[account] }
    func set(_ value: String?, for account: String) {
        if let value, !value.isEmpty { storage[account] = value } else { storage[account] = nil }
    }
}

/// A UserDefaults suite of its own, and the scratch directory that stands in
/// for `~/.agent-inbox`, for one test.
///
/// A named suite is a real file under ~/Library/Preferences the moment
/// something is written to it, so `remove()` has to run from `tearDown`. And
/// `removePersistentDomain` empties the domain without deleting the file, so
/// the file is removed by hand too or every run leaves one behind.
/// Nothing here is reached through a global: the suite goes into
/// `AppSettings(defaults:)` and the directory into `SenderConfig.directory`,
/// which is the one static left, because the files under it are the contract
/// with the bash senders and are read by path.
@MainActor
final class IsolatedSettings {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let secrets = MemorySecrets()

    init(_ label: String = "test") {
        suiteName = "agent-inbox-\(label)-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(suiteName)
        SenderConfig.directory = directory
    }

    func settings() -> AppSettings {
        AppSettings(defaults: defaults, secrets: secrets)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: directory)
    }
}

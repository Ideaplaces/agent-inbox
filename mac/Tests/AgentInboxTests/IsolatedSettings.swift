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

/// UserDefaults that never reach disk.
///
/// A named suite is the obvious alternative and it leaks: `UserDefaults(
/// suiteName:)` is a real plist under ~/Library/Preferences the moment
/// anything is written, and `removePersistentDomain` empties it without
/// deleting it. cfprefsd writes the empty file back on its own schedule, after
/// the process has exited, so deleting it from `tearDown` does not stick
/// either. Every typed accessor on UserDefaults goes through
/// `object(forKey:)` and every typed setter through `set(_:forKey:)`, so
/// overriding those two and `removeObject` is the whole job.
final class MemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { storage[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { storage[defaultName] = value } else { storage[defaultName] = nil }
    }
    override func removeObject(forKey defaultName: String) { storage[defaultName] = nil }
    override func synchronize() -> Bool { true }
}

/// Everything an `AppSettings` or an `AppModel` needs in order to read and
/// write nothing real: in-memory defaults, in-memory secrets, and a scratch
/// directory in place of `~/.agent-inbox`.
///
/// The first two are handed in. The directory is the one static left,
/// `SenderConfig.directory`, because the files under it are the contract with
/// the bash senders and are found by path; `remove()` belongs in `tearDown`.
@MainActor
final class IsolatedSettings {
    let defaults = MemoryDefaults()
    let secrets = MemorySecrets()
    let directory: URL

    init(_ label: String = "test") {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-inbox-\(label)-\(UUID().uuidString)")
        SenderConfig.directory = directory
    }

    func settings() -> AppSettings {
        AppSettings(defaults: defaults, secrets: secrets)
    }

    func model() -> AppModel {
        AppModel(settings: settings(), defaults: defaults)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

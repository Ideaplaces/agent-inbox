import Foundation

/// Installs the three Claude Code hooks into `~/.claude/settings.json`.
///
/// This is the difference between "clone a repo and run two scripts" and
/// "click a button", so it is written to be safe on a file the user owns:
/// it backs up first, preserves every unrelated key, and is idempotent.
enum HookInstaller {
    /// Overridable so tests never touch the real Claude Code settings.
    static var settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private static let events = [
        ("UserPromptSubmit", "prompt"),
        ("Stop", "stop"),
        ("Notification", "notification"),
    ]

    static func command(for kind: String, script: URL) -> String {
        "bash \"\(script.path)\" \(kind)"
    }

    /// True when all three hooks point at a notify.sh, whichever install put
    /// them there. Used to show the real state rather than a guess.
    static func isInstalled() -> Bool {
        guard let hooks = loadHooks() else { return false }
        return events.allSatisfy { event, kind in
            (hooks[event] as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { hook in
                    let cmd = hook["command"] as? String ?? ""
                    return cmd.contains("notify.sh") && cmd.hasSuffix(" \(kind)")
                }
            }
        }
    }

    /// Which notify.sh the installed hooks currently run, if any. A path other
    /// than ours means an older shell install is still wired up.
    static func installedScriptPaths() -> Set<String> {
        guard let hooks = loadHooks() else { return [] }
        var paths: Set<String> = []
        for (event, _) in events {
            for entry in hooks[event] as? [[String: Any]] ?? [] {
                for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                    let cmd = hook["command"] as? String ?? ""
                    guard cmd.contains("notify.sh") else { continue }
                    paths.insert(cmd)
                }
            }
        }
        return paths
    }

    private static func loadHooks() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["hooks"] as? [String: Any] ?? [:]
    }

    enum InstallError: LocalizedError {
        case unreadable(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Could not read \(path)"
            case .unwritable(let path): return "Could not write \(path)"
            }
        }
    }

    /// Point the three hooks at `script`, dropping any previous agent-inbox
    /// hook so a machine upgraded from the shell install does not double-post.
    static func install(script: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            guard let data = try? Data(contentsOf: settingsURL) else {
                throw InstallError.unreadable(settingsURL.path)
            }
            if !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError.unreadable(settingsURL.path)
                }
                root = parsed
            }
            // Back up before touching a file the user also edits by hand.
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.bak.agent-inbox")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: settingsURL, to: backup)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, kind) in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Drop every existing agent-inbox entry for this event, ours or an
            // older install's, then add exactly one.
            entries = entries.compactMap { entry -> [String: Any]? in
                guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
                inner.removeAll { ($0["command"] as? String ?? "").contains("notify.sh") }
                if inner.isEmpty { return nil }
                var copy = entry
                copy["hooks"] = inner
                return copy
            }
            entries.append([
                "hooks": [["type": "command", "command": command(for: kind, script: script)]]
            ])
            hooks[event] = entries
        }
        root["hooks"] = hooks

        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        do {
            try out.write(to: settingsURL, options: .atomic)
        } catch {
            throw InstallError.unwritable(settingsURL.path)
        }
    }

    /// Remove every agent-inbox hook, leaving the rest of the file intact.
    static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else { return }

        for (event, _) in events {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries = entries.compactMap { entry -> [String: Any]? in
                guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
                inner.removeAll { ($0["command"] as? String ?? "").contains("notify.sh") }
                if inner.isEmpty { return nil }
                var copy = entry
                copy["hooks"] = inner
                return copy
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        root["hooks"] = hooks

        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }
}

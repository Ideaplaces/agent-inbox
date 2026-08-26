import AppKit
import Foundation
import Observation
import UserNotifications

/// Everything with a lifetime longer than a view, in one place.
@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings.shared
    let presence: Presence
    let store: InboxStore
    let poller: Poller
    let updater = Updater()

    /// Shown in the menu when a background action has something to say.
    var transientMessage: String?

    private init() {
        let presence = Presence()
        self.presence = presence
        self.store = InboxStore(presence: presence)
        self.poller = Poller(settings: settings, store: store, presence: presence)
    }

    func start() {
        // Take over a previous bash install silently. Someone upgrading should
        // find the app already configured, not an empty setup screen.
        settings.adoptExistingShellInstall()
        // Nothing to adopt means a fresh install. Land on ntfy with a topic
        // already generated, so setup is three clicks and no decision. A
        // half-configured ntfy (topic but no transport) is not possible.
        if settings.transport == .none {
            if settings.ntfyTopic.isEmpty {
                settings.ntfyTopic = AppSettings.randomNtfyTopic()
            }
            settings.transport = .ntfy
        }
        SenderConfig.installNotifyScript()
        settings.sync()
        poller.start()
    }

    var hooksInstalled: Bool { HookInstaller.isInstalled() }

    /// True when hooks exist but point at a notify.sh this app does not manage,
    /// which is how a half-migrated machine looks.
    var hasForeignHooks: Bool {
        let ours = HookInstaller.command(for: "", script: SenderConfig.notifyScript)
            .trimmingCharacters(in: .whitespaces)
        return HookInstaller.installedScriptPaths().contains { !$0.hasPrefix(ours) }
    }

    func installHooks() {
        guard SenderConfig.installNotifyScript() else {
            transientMessage = "Could not unpack notify.sh from the app bundle."
            return
        }
        do {
            try HookInstaller.install(script: SenderConfig.notifyScript)
            settings.sync()
            transientMessage = "This Mac is set up. Restart running Claude Code sessions."
        } catch {
            transientMessage = error.localizedDescription
        }
    }

    func removeHooks() {
        do {
            try HookInstaller.uninstall()
            transientMessage = "Hooks removed from ~/.claude/settings.json."
        } catch {
            transientMessage = error.localizedDescription
        }
    }

    func openHistory() {
        guard let url = settings.historyURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// The command to paste on any other machine that runs Claude Code.
    var remoteInstallCommand: String {
        let base = "curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/install-remote.sh | bash -s --"
        switch settings.transport {
        case .ntfy:
            return "\(base) --ntfy \(settings.ntfyTopic)"
        case .discord:
            let url = settings.discordWebhookURL.isEmpty
                ? "<discord-webhook-url>" : settings.discordWebhookURL
            return "\(base) --discord-webhook '\(url)'"
        case .none:
            return "\(base) --ntfy <topic>"
        }
    }
}

/// Notification actions and app lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Scriptable install steps, so setting a machine up does not require
        // clicking through the UI. Each one runs and exits.
        let arguments = CommandLine.arguments
        if arguments.contains("--register-login-item") || arguments.contains("--unregister-login-item") {
            let enable = arguments.contains("--register-login-item")
            do {
                try LoginItem.set(enable)
                print("login item \(enable ? "registered" : "unregistered")")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        // Configure the transport without the UI, so a provisioning script can
        // do in one command what the setup window does in several fields.
        if arguments.contains("--configure") {
            let settings = AppSettings.shared
            func value(_ flag: String) -> String? {
                guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count
                else { return nil }
                return arguments[i + 1]
            }
            func fail(_ message: String) -> Never {
                FileHandle.standardError.write(Data("\(message)\n".utf8))
                exit(1)
            }

            switch value("--transport") {
            case "ntfy":
                guard let topic = value("--topic"), !topic.isEmpty else {
                    fail("--transport ntfy requires --topic")
                }
                settings.ntfyTopic = topic
                if let server = value("--server"), !server.isEmpty {
                    settings.ntfyServer = server
                }
                // Optional: ntfy.sh has no accounts, a self-hosted server may
                // require one. Provisioning a machine has to be one command, so
                // this cannot be UI-only.
                if let token = value("--token") {
                    settings.ntfyToken = token
                }
                settings.transport = .ntfy
                print("configured ntfy topic")
            case "discord":
                guard let token = value("--bot-token"), !token.isEmpty,
                      let channel = value("--channel-id"), !channel.isEmpty else {
                    fail("--transport discord requires --bot-token and --channel-id")
                }
                settings.discordBotToken = token
                settings.discordChannelID = channel
                settings.discordGuildID = value("--guild-id") ?? ""
                settings.discordWebhookURL = value("--webhook") ?? ""
                settings.transport = .discord
                print("configured Discord channel \(channel)")
            default:
                fail("--configure requires --transport ntfy|discord")
            }

            if let label = value("--host-label"), !label.isEmpty {
                settings.hostLabel = label
            }
            // This process is about to exit, so the defaults must be on disk.
            UserDefaults.standard.synchronize()
            settings.hasCompletedOnboarding = true
            UserDefaults.standard.synchronize()
            exit(0)
        }

        if arguments.contains("--install-hooks") {
            SenderConfig.installNotifyScript()
            do {
                try HookInstaller.install(script: SenderConfig.notifyScript)
                print("hooks installed into \(HookInstaller.settingsURL.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
        Task { @MainActor in
            AppModel.shared.start()
            _ = await Notifier.requestAuthorization()
            // A menubar app is easy to miss on first launch, so show the
            // setup window until it has been completed once.
            if !AppModel.shared.settings.hasCompletedOnboarding {
                WelcomeWindowController.shared.show()
            }
        }
    }

    /// Show the banner even when the app is frontmost. The inbox is the point.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.content.userInfo["itemID"] as? String
        await MainActor.run {
            let model = AppModel.shared
            guard let id, let item = model.store.item(id: id) else { return }
            // Every route is the same: acknowledge it. There is nothing to
            // open, so a click on the banner just clears the item.
            switch response.actionIdentifier {
            case Notifier.readAction, UNNotificationDefaultActionIdentifier:
                model.store.markRead(item.id)
            default:
                break
            }
        }
    }
}

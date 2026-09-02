import AppKit
import Foundation
import Observation
import UserNotifications

enum MenuRoute {
    case inbox
    case settings
}

/// Everything with a lifetime longer than a view, in one place.
@Observable
@MainActor
final class AppModel {
    let settings: AppSettings
    let presence: Presence
    let store: InboxStore
    let receiver: Receiver
    let housekeeping: Housekeeping
    let updater = Updater()
    /// The first-run window. Owned here rather than by a global because it
    /// hosts a view that needs this model, and there is no other model.
    @ObservationIgnored private let welcomeWindow = WelcomeWindowController()

    /// Shown in the menu when a background action has something to say.
    var transientMessage: String?

    /// Which page the popover is showing. Settings live in here rather than in
    /// a window of their own, so opening them cannot land on another Space.
    var menuRoute: MenuRoute = .inbox

    /// There is one of these in the app, made by `AgentInboxApp`, and as many
    /// as a test wants.
    ///
    /// Nothing here reaches for a global. The settings come in, and so does
    /// the UserDefaults the receiver keeps its cursors in, so a test that
    /// hands over its own suite reads and writes nothing real. The one thing
    /// still found by path is `SenderConfig.directory`, because the files
    /// under it are the contract with the bash senders; point it at a scratch
    /// directory first.
    ///
    /// The receiving path is wired here and nowhere else: the receiver hands
    /// each batch to the pipeline, every row the pipeline announces gets a
    /// banner and a tally, and housekeeping runs on its own clock beside it.
    init(settings: AppSettings = AppSettings(), defaults: UserDefaults = .standard) {
        self.settings = settings
        let presence = Presence()
        let store = InboxStore(presence: presence)
        let pipeline = MessagePipeline(store: store, presence: presence)
        let usage = UsageReporter(settings: settings)
        self.presence = presence
        self.store = store
        self.receiver = Receiver(
            channel: { Self.channel(for: settings) },
            deliver: { messages in
                for item in pipeline.apply(messages) {
                    Notifier.post(item, soundName: settings.soundName)
                    usage.count(item)
                }
                usage.reportIfADayHasPassed()
            },
            defaults: defaults)
        self.housekeeping = Housekeeping(presence: presence, store: store, settings: settings)
    }

    /// The transport the settings describe, or nil when there is nothing to
    /// connect to yet. Read again before every connection, so a change to the
    /// server or topic takes effect at the next restart.
    private static func channel(for settings: AppSettings) -> Receiver.Channel? {
        switch settings.transport {
        case .none:
            return nil
        case .ntfy:
            guard !settings.ntfyTopic.isEmpty else { return nil }
            return Receiver.Channel(
                transport: NtfyTransport(
                    server: settings.ntfyServer, topic: settings.ntfyTopic,
                    token: settings.ntfyToken),
                cursorKey: "cursor.ntfy.\(settings.ntfyServer)/\(settings.ntfyTopic)")
        }
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
        housekeeping.start()
        receiver.start()

        // A Mac that slept has a dead connection and no way to know it. Waiting
        // for the next write to fail would cost a minute of silence right when
        // someone opens the lid to see what happened overnight.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.receiver.wake() }
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

    func showWelcome() {
        welcomeWindow.show(model: self)
    }

    func closeWelcome() {
        welcomeWindow.close()
    }

    /// The command to paste on any other machine that runs Claude Code.
    var remoteInstallCommand: String {
        let base = "curl -fsSL https://raw.githubusercontent.com/Ideaplaces/agent-inbox/main/install-remote.sh | bash -s --"
        switch settings.transport {
        case .ntfy:
            return "\(base) --ntfy \(settings.ntfyTopic)"
        case .none:
            return "\(base) --ntfy <topic>"
        }
    }
}

/// Notification actions and app lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Handed over by `AgentInboxApp.init`, which runs before this delegate
    /// hears about the launch, so by `applicationDidFinishLaunching` it is
    /// always set. An optional rather than a `let` because the adaptor, not
    /// the app, constructs this object, and it takes no arguments.
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else {
            preconditionFailure("AgentInboxApp did not hand the model to its delegate")
        }
        let settings = model.settings
        // Scriptable install steps, so setting a machine up does not require
        // clicking through the UI. Each one runs and exits.
        let arguments = CommandLine.arguments
        if arguments.contains("--register-login-item") || arguments.contains("--unregister-login-item") {
            let enable = arguments.contains("--register-login-item")
            do {
                try LoginItem.set(enable)
                // A script saying either way is a decision, so the next launch
                // does not quietly re-enable what it just turned off.
                settings.hasDecidedLoginItem = true
                settings.flush()
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
            default:
                fail("--configure requires --transport ntfy")
            }

            if let label = value("--host-label"), !label.isEmpty {
                settings.hostLabel = label
            }
            settings.hasCompletedOnboarding = true
            // This process is about to exit, so the defaults must be on disk.
            settings.flush()
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
            model.start()
            // Before anything else it might ask for: an inbox that is not
            // running has nothing to notify you about.
            LoginItem.enableOnFirstLaunch(settings)
            _ = await Notifier.requestAuthorization()
            // A menubar app is easy to miss on first launch, so show the
            // setup window until it has been completed once.
            if !settings.hasCompletedOnboarding {
                model.showWelcome()
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
            guard let model, let id, let item = model.store.item(id: id) else { return }
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

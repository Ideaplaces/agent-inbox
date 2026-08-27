import AppKit
import SwiftUI

/// First run, in one window: pick where events travel, wire up this Mac, and
/// get the one line to paste on every other machine. Nothing to clone, no
/// scripts to find, no dotfile to edit.
@MainActor
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        @Bindable var settings = model.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headline

                step(1, "Choose how events reach this Mac") {
                    TransportPicker()
                }

                step(2, "Set up this Mac") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Adds three hooks to ~/.claude/settings.json so every Claude Code session on this machine reports in. Your existing settings are backed up first.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button(model.hooksInstalled ? "Reinstall Hooks" : "Set Up This Mac") {
                                model.installHooks()
                            }
                            .buttonStyle(.borderedProminent)
                            if model.hooksInstalled {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                step(3, "Set up your other machines") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run this on any other machine where Claude Code runs, including a dev box over SSH.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 8) {
                            Text(model.remoteInstallCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    model.remoteInstallCommand, forType: .string)
                                copied = true
                            }
                            .controlSize(.small)
                        }
                        Text("On a remote machine set HOST_LABEL to its SSH host alias, so clicking an item here opens it over Remote-SSH.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                step(4, "Stay running") {
                    Toggle("Open Agent Inbox at login", isOn: $launchAtLogin)
                        .font(.system(size: 12))
                        .onChange(of: launchAtLogin) { _, value in
                            try? LoginItem.set(value)
                            launchAtLogin = LoginItem.isEnabled
                        }
                }

                Divider()

                HStack {
                    if let message = model.transientMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Send Test Event") {
                        Task {
                            if let error = await model.poller.sendTestEvent() {
                                model.transientMessage = error
                            } else {
                                model.transientMessage = "Test event sent. Watch the menubar."
                            }
                        }
                    }
                    Button("Done") {
                        model.settings.hasCompletedOnboarding = true
                        model.poller.restart()
                        WelcomeWindowController.shared.close()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.settings.isConfigured)
                }
            }
            .padding(28)
        }
        .frame(width: 560, height: 620)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent Inbox")
                .font(.system(size: 22, weight: .semibold))
            Text("Every Claude Code session that finishes or needs you, in your menubar, across all your machines.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step<Content: View>(
        _ number: Int, _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content()
            }
        }
    }
}

/// Shared by onboarding and Settings so there is exactly one place that knows
/// what a transport needs.
@MainActor
struct TransportPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $settings.transport) {
                Text("ntfy").tag(TransportKind.ntfy)
                Text("Discord").tag(TransportKind.discord)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: settings.transport) { _, _ in model.poller.restart() }

            Text(settings.transport == .discord
                 ? "A private channel keeps a browsable history you can scroll back through, at the cost of a bot and a webhook to set up."
                 : "Recommended. No account, no bot, nothing to provision. Messages are cached for about 12 hours, so the menubar is your history rather than the feed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch settings.transport {
            case .ntfy, .none:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("topic", text: $settings.ntfyTopic)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Generate") {
                            settings.ntfyTopic = AppSettings.randomNtfyTopic()
                            settings.transport = .ntfy
                            model.poller.restart()
                        }
                        .controlSize(.small)
                    }
                    Text("The topic name is the whole secret: anyone who knows it can read your messages. Generate a long one and keep it private.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Server") {
                        TextField(AppSettings.publicNtfyServer, text: $settings.ntfyServer)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    .font(.system(size: 11))
                    // Only meaningful on a self-hosted server. ntfy.sh has no
                    // accounts, so showing this against the default would
                    // invite people to fill in a field that does nothing.
                    if settings.ntfyServer != AppSettings.publicNtfyServer {
                        LabeledContent("Token") {
                            SecureField("optional", text: $settings.ntfyToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        .font(.system(size: 11))
                    }
                }
            case .discord:
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Bot token") {
                        SecureField("", text: $settings.discordBotToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Channel ID") {
                        TextField("", text: $settings.discordChannelID)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Server ID") {
                        TextField("optional", text: $settings.discordGuildID)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Webhook URL") {
                        SecureField("used by senders", text: $settings.discordWebhookURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("The bot token is only needed here, to read messages back. Sending machines use the webhook URL.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .onChange(of: settings.discordChannelID) { _, _ in model.poller.restart() }
            }
        }
    }

}

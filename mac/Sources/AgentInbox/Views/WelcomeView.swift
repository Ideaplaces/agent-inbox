import AppKit
import SwiftUI

/// First run, in one window: pick where events travel, wire up this Mac, and
/// get the one line to paste on every other machine. Nothing to clone, no
/// scripts to find, no dotfile to edit.
@MainActor
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

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
                        RemoteInstallCommand()
                        Text("On a remote machine set HOST_LABEL to its SSH host alias, so clicking an item here opens it over Remote-SSH.")
                            .note(.tertiary)
                    }
                }

                step(4, "Stay running") {
                    LoginItemToggle()
                        .font(.system(size: 12))
                    // Asked here rather than only in Settings, because a choice
                    // nobody is shown is not a choice they made. Unticked, and
                    // it stays unticked if this window is closed.
                    UsageSharingToggle()
                        .font(.system(size: 12))
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

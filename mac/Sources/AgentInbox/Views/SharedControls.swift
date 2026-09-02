import AppKit
import SwiftUI

/// The small grey line of explanation under a control.
///
/// Spelled out by hand at eighteen call sites before this existed, which is why
/// some of them wrapped and some truncated: `fixedSize` was remembered about
/// half the time. One modifier, so a note either reads correctly everywhere or
/// nowhere.
extension View {
    func note() -> some View { note(.secondary) }

    func note<S: ShapeStyle>(_ tint: S) -> some View {
        font(.system(size: 10))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Controls that the setup window and the settings page both show.
///
/// They live here, together, because for a while they did not: each screen
/// rolled its own copy of the same toggle, and a person reading one file could
/// not see the other. That is how the turn-length floor came to have two
/// controls writing one value, and how the setup window's usage toggle came to
/// answer from a stale snapshot while the settings pane answered from the
/// setting. Neither was a hard bug. Both were invisible.
///
/// The rule this file exists to enforce: a control that appears on two screens
/// is one type with two call sites, never two implementations.

/// Launch at login.
struct LoginItemToggle: View {
    @Environment(AppModel.self) private var model
    @State private var isOn = LoginItem.isEnabled

    var body: some View {
        Toggle("Open at login", isOn: $isOn)
            .onChange(of: isOn) { _, value in
                try? LoginItem.set(value)
                // Read back rather than trust the write. Registration can fail,
                // and a switch showing what you asked for instead of what
                // happened is worse than one that snaps back.
                isOn = LoginItem.isEnabled
                model.settings.hasDecidedLoginItem = true
            }
    }
}

/// Anonymous usage counts, and the sentence saying what that means.
struct UsageSharingToggle: View {
    @Environment(AppModel.self) private var model
    /// The setup window has room for the explanation; a settings row has it
    /// underneath either way.
    var showsNote = true

    static let explanation =
        "Off by default. One event a day: how many notifications arrived, and which versions you run. Never any message text, repo name, path, host name or topic."

    var body: some View {
        @Bindable var settings = model.settings

        // Bound to the setting, not to a copy of it taken when the view was
        // built. A snapshot in `@State` is exactly how the setup window came to
        // show yesterday's answer when it was opened again.
        Toggle("Share anonymous usage data", isOn: $settings.shareUsageData)
        if showsNote {
            Text(Self.explanation).note(.tertiary)
        }
    }
}

/// The one line to paste on every other machine, and a button to take it.
struct RemoteInstallCommand: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(model.remoteInstallCommand)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.remoteInstallCommand, forType: .string)
                copied = true
            }
            .controlSize(.small)
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
            Text(AppSettings.transportIntro(server: settings.ntfyServer))
                .note()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("topic", text: $settings.ntfyTopic)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Generate") {
                        settings.ntfyTopic = AppSettings.randomNtfyTopic()
                        settings.transport = .ntfy
                        model.receiver.restart()
                    }
                    .controlSize(.small)
                }
                Text(AppSettings.topicExplanation(
                    server: settings.ntfyServer, token: settings.ntfyToken))
                    .note(.tertiary)
                LabeledContent("Server") {
                    // Hidden, because LabeledContent is already drawing the
                    // label: a TextField's first argument is its label, not a
                    // placeholder, so leaving it visible prints the default
                    // next to the field as if it were a second value.
                    TextField("", text: $settings.ntfyServer,
                              prompt: Text(AppSettings.publicNtfyServer))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                .font(.system(size: 11))
                // Only meaningful on a self-hosted server. ntfy.sh has no
                // accounts, so showing this against the default would
                // invite people to fill in a field that does nothing.
                if settings.ntfyServer != AppSettings.publicNtfyServer {
                    LabeledContent("Token") {
                        SecureField("", text: $settings.ntfyToken,
                                    prompt: Text("optional"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

}

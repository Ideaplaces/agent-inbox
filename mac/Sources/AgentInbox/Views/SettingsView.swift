import AppKit
import SwiftUI

/// The settings, as a page inside the menubar popover.
///
/// Not a window. A separate Settings window opens wherever macOS decides,
/// which on a Mac driving a full-screen app is another Space: the click does
/// nothing you can see, and the honest conclusion a person draws is that the
/// app is broken. That happened on the second Mac this was ever installed on.
/// A page in the popover opens where the click was, every time.
@MainActor
struct SettingsPanes: View {
    @Environment(AppModel.self) private var model
    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case transport = "Transport"
        case machines = "Machines"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            switch pane {
            case .general: GeneralSettings()
            case .transport: TransportSettings()
            case .machines: MachineSettings()
            }
        }
    }
}

@MainActor
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    private static let sounds = [
        "", "Glass", "Ping", "Pop", "Blow", "Bottle", "Funk", "Hero", "Morse", "Purr", "Submarine",
    ]

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                LoginItemToggle()
                UsageSharingToggle()
                Picker("Sound", selection: $settings.soundName) {
                    ForEach(Self.sounds, id: \.self) { name in
                        Text(name.isEmpty ? "Silent" : name).tag(name)
                    }
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically",
                       isOn: Binding(
                        get: { model.updater.automaticallyChecks },
                        set: { model.updater.automaticallyChecks = $0 }))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(model.updater.currentVersion)")
                        if let last = model.updater.lastCheck {
                            Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                                .note()
                        }
                    }
                    Spacer()
                    Button("Check Now") { model.updater.checkForUpdates() }
                        .disabled(!model.updater.canCheck)
                }
            }

            Section("Inbox") {
                LabeledContent("Clear items after") {
                    HStack {
                        Stepper(
                            value: $settings.expireMinutes, in: 0...120,
                            label: {
                                Text(settings.expireMinutes == 0
                                     ? "Never"
                                     : "\(settings.expireMinutes) min at the keyboard")
                            })
                    }
                }
                Text("Items age against time you actually spend at this Mac, so a break never drains the inbox behind your back.")
                    .note()
                LabeledContent("Count as away after") {
                    Stepper(value: $settings.idleThreshold, in: 30...600, step: 30) {
                        Text("\(settings.idleThreshold)s idle")
                    }
                }
            }

            Section("Conversations") {
                // First in the section on purpose. This is the setting that
                // makes the app look broken when nobody knows it exists: a
                // short turn reports nothing, which is indistinguishable from
                // nothing working. Reported by two people, one of them the
                // person who wrote the default.
                LabeledContent("Report turns longer than") {
                    Stepper(value: $settings.minSeconds, in: 0...300, step: 5) {
                        Text(SettingsCopy.minSecondsCaption(settings.minSeconds))
                    }
                }
                Text("A quick back-and-forth is not worth interrupting yourself over, so turns shorter than this are dropped. Set it to zero and every turn reports, however short.")
                    .note()
                Text("This Mac only. Every machine keeps its own config, so set it again on a dev box you report from.")
                    .note(.tertiary)

                Picker("Report", selection: $settings.watchMode) {
                    Text("Every conversation").tag("all")
                    Text("Only tagged conversations").tag("tagged")
                }
                Text(SettingsCopy.reportModeCaption(watchMode: settings.watchMode))
                    .note()

                // A TextField's first argument is its label, not a
                // placeholder. Inside LabeledContent that label is drawn a
                // second time, next to the field, so the pane showed the
                // default tags beside the tags you had actually typed and read
                // as the value appearing twice. The defaults belong in the
                // prompt, which shows only while the field is empty.
                LabeledContent("Watch tags") {
                    TextField("", text: $settings.watchTags,
                              prompt: Text(AppSettings.defaultWatchTags))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { settings.watchTags = AppSettings.normalizeTags(settings.watchTags) }
                }
                Text(SettingsCopy.watchTagCaption(watchMode: settings.watchMode))
                    .note()
                LabeledContent("Mute tag") {
                    TextField("", text: $settings.muteTag,
                              prompt: Text(AppSettings.defaultMuteTag))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { settings.muteTag = AppSettings.normalizeTags(settings.muteTag) }
                }
                Text(SettingsCopy.muteTagCaption(watchMode: settings.watchMode))
                    .note()
                HStack {
                    Text("Typed or said anywhere in a message. Separate several with commas, which lets a tag be a phrase like \"watch this\" for dictation. Case does not matter.")
                        .note()
                    Spacer()
                    Button("Reset") {
                        settings.watchTags = AppSettings.defaultWatchTags
                        settings.muteTag = AppSettings.defaultMuteTag
                    }
                    .controlSize(.small)
                }
                Text("This Mac only. Every machine keeps its own config, so set these again on a dev box you report from.")
                    .note(.tertiary)
            }

        }
        .formStyle(.grouped)
    }
}

@MainActor
struct TransportSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                TransportPicker()
            }
            Section {
                HStack {
                    statusLabel
                    Spacer()
                    if model.settings.historyURL != nil {
                        Button("Open History") { model.openHistory() }
                    }
                    Button("Reconnect") { model.receiver.restart() }
                }
            }
            Section {
                Text("Message bodies carry snippets of your prompts and Claude's replies, plus repo names and paths. Keep the channel private.")
                    .note()
            }
        }
        .formStyle(.grouped)
    }

    private var statusLabel: some View {
        // One Label, styled by the status, so the branches share a type.
        let (text, icon, tint): (String, String, Color) = {
            switch model.receiver.status {
            case .connected(let date):
                let time = date.formatted(date: .omitted, time: .standard)
                return ("Connected, last check \(time)", "checkmark.circle.fill", .green)
            case .connecting:
                return ("Connecting", "clock", .secondary)
            case .notConfigured:
                return ("Not configured", "exclamationmark.circle", .secondary)
            case .failed(let reason):
                return (reason, "xmark.octagon.fill", .red)
            }
        }()
        return Label(text, systemImage: icon).foregroundStyle(tint)
    }
}

@MainActor
struct MachineSettings: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("This Mac") {
                LabeledContent("Shown as") {
                    // Hidden, because LabeledContent already draws the label.
                    // The third site of the same mistake: a TextField's first
                    // argument is its label, not a placeholder, so this one was
                    // printing "host label" next to the machine's actual name
                    // as though it were part of the value.
                    TextField("", text: $settings.hostLabel,
                              prompt: Text(Host.current().localizedName ?? "this Mac"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    if model.hooksInstalled {
                        Label("Hooks installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Hooks not installed", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(model.hooksInstalled ? "Reinstall" : "Install") { model.installHooks() }
                    Button("Remove") { model.removeHooks() }
                        .disabled(!model.hooksInstalled)
                }
                if model.hasForeignHooks {
                    Text("Some hooks still point at an older shell install. Reinstall to route everything through this app.")
                        .note(.orange)
                }
            }

            Section("Other machines") {
                RemoteInstallCommand()
            }

            Section {
                HStack {
                    Button("Send Test Event") {
                        Task {
                            if let error = await model.sendTestEvent() {
                                model.transientMessage = error
                            } else {
                                model.transientMessage = "Test event sent."
                            }
                        }
                    }
                    Spacer()
                    if let message = model.transientMessage {
                        Text(message).note()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TransportSettings()
                .tabItem { Label("Transport", systemImage: "antenna.radiowaves.left.and.right") }
            MachineSettings()
                .tabItem { Label("Machines", systemImage: "desktopcomputer") }
        }
        .frame(width: 520)
    }
}

@MainActor
private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled

    private static let sounds = [
        "", "Glass", "Ping", "Pop", "Blow", "Bottle", "Funk", "Hero", "Morse", "Purr", "Submarine",
    ]

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        try? LoginItem.set(value)
                        launchAtLogin = LoginItem.isEnabled
                    }
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
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                LabeledContent("Count as away after") {
                    Stepper(value: $settings.idleThreshold, in: 30...600, step: 30) {
                        Text("\(settings.idleThreshold)s idle")
                    }
                }
            }

            Section("Polling") {
                LabeledContent("Check every") {
                    Stepper(value: $settings.pollSeconds, in: 5...120, step: 5) {
                        Text("\(settings.pollSeconds)s")
                    }
                    .onChange(of: settings.pollSeconds) { _, _ in model.poller.restart() }
                }
                LabeledContent("Ignore turns under") {
                    Stepper(value: $settings.minSeconds, in: 0...600, step: 15) {
                        Text("\(settings.minSeconds)s")
                    }
                }
                Text("Short back-and-forth turns never reach the inbox. This is applied by the sender, on every machine that reads your config.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct TransportSettings: View {
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
                    Button("Reconnect") { model.poller.restart() }
                }
            }
            Section {
                Text("Message bodies carry snippets of your prompts and Claude's replies, plus repo names and paths. Keep the channel private.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusLabel: some View {
        // One Label, styled by the status, so the branches share a type.
        let (text, icon, tint): (String, String, Color) = {
            switch model.poller.status {
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
private struct MachineSettings: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("This Mac") {
                LabeledContent("Shown as") {
                    TextField("host label", text: $settings.hostLabel)
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
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            Section("Other machines") {
                Text(model.remoteInstallCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(copied ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.remoteInstallCommand, forType: .string)
                        copied = true
                    }
                }
            }

            Section {
                HStack {
                    Button("Send Test Event") {
                        Task {
                            if let error = await model.poller.sendTestEvent() {
                                model.transientMessage = error
                            } else {
                                model.transientMessage = "Test event sent."
                            }
                        }
                    }
                    Spacer()
                    if let message = model.transientMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

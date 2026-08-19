import SwiftUI

@main
struct AgentInboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView().environment(model)
        } label: {
            // A quiet inbox shows a quiet icon; a busy one shows the counts.
            let badge = model.store.badge
            if badge.isEmpty {
                Image(systemName: "tray")
            } else {
                Text(badge)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

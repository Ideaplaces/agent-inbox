import SwiftUI

@main
@MainActor
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
        // No `Settings` scene on purpose. Its window opens wherever macOS
        // decides, which on a Mac driving a full-screen app is a different
        // Space, so the click appears to do nothing. Settings are a page
        // inside the popover instead, which opens where the click was.
    }
}

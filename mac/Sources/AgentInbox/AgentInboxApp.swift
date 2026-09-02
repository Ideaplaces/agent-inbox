import SwiftUI

@main
@MainActor
struct AgentInboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    /// The app's one model is made here and handed to the delegate, which is
    /// where the launch work happens. The adaptor has already constructed the
    /// delegate by the time this runs, and `applicationDidFinishLaunching`
    /// fires later, so the delegate never sees a nil model. The alternative
    /// is a global, which is what this replaces: a test could not build a
    /// model of its own without also being handed the real settings.
    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        delegate.model = model
    }

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

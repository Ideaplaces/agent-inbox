import AppKit

/// Raising the Settings window, which SwiftUI will not do for a menubar app.
///
/// `LSUIElement` makes this an accessory application: it never becomes the
/// active app on its own, and clicking inside a `MenuBarExtra` does not activate
/// it either. `SettingsLink` opens the `Settings` scene regardless, so the
/// window is created, ordered in, and then left sitting behind whatever the user
/// was actually looking at. It reads as the click doing nothing. Reopening from
/// the menu does not help, because the window already exists.
///
/// The window belongs to SwiftUI, so the only handle on it is the identifier
/// SwiftUI gives it. Activating the app and ordering that window front is what
/// `WelcomeWindowController` already does for its own AppKit window; this is the
/// same two lines for the one window we do not create ourselves.
@MainActor
enum SettingsWindowFocus {
    /// SwiftUI's identifier for the `Settings` scene window.
    static let identifier = "com_apple_SwiftUI_Settings_window"

    /// Retries because the click has not opened the window yet. `SettingsLink`
    /// creates it as part of handling the same event, so the first look can come
    /// up empty; a window that never appears simply stops the polling.
    private static let attemptDelays: [Double] = [0, 0.05, 0.15, 0.3]

    static func raise() {
        NSApp.activate(ignoringOtherApps: true)
        for delay in attemptDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = find(in: NSApp.windows) else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    static func find(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == identifier }
    }
}

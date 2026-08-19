import AppKit
import SwiftUI

/// A menubar app has no Dock icon and no main window, so a first-run window has
/// to be opened deliberately. SwiftUI's `Window` scene cannot be shown from
/// outside a view, so the welcome window is plain AppKit hosting a SwiftUI view.
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: WelcomeView().environment(AppModel.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Agent Inbox"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

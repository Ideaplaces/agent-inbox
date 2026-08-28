import AppKit
import XCTest
@testable import AgentInbox

/// The Settings window opened behind the frontmost app and looked like a click
/// that did nothing. An accessory app is never activated by its menubar extra,
/// so the window has to be found and raised by identifier.
@MainActor
final class SettingsWindowFocusTests: XCTestCase {
    private func window(identifier: String?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled], backing: .buffered, defer: true)
        if let identifier { window.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return window
    }

    func testItFindsTheSwiftUISettingsWindow() {
        let settings = window(identifier: SettingsWindowFocus.identifier)
        let windows = [window(identifier: nil), window(identifier: "other"), settings]
        XCTAssertIdentical(SettingsWindowFocus.find(in: windows), settings)
    }

    func testItIgnoresEveryOtherWindow() {
        // The welcome window and the menubar extra's own window are both open
        // at this point; raising either one is the wrong behavior.
        let windows = [window(identifier: nil), window(identifier: "AgentInboxWelcome")]
        XCTAssertNil(SettingsWindowFocus.find(in: windows))
    }

    func testTheIdentifierIsTheOneSwiftUIAssigns() {
        // Hard-coded because SwiftUI exposes no constant for it. If a macOS
        // release renames it, this is the line that has to change.
        XCTAssertEqual(SettingsWindowFocus.identifier, "com_apple_SwiftUI_Settings_window")
    }
}

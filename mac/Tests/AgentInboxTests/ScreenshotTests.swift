import AppKit
import SwiftUI
import XCTest
@testable import AgentInbox

/// Regenerates the screenshots in `docs/` from the shipping views.
///
///     AGENT_INBOX_WRITE_SCREENSHOTS=1 swift test --filter Screenshot
///
/// Off by default, so an ordinary `swift test` and CI write nothing.
///
/// Hand-taken screenshots rot the first time the UI moves and nobody notices.
/// That is what happened to the last one: pulled from the README for being
/// wrong, then never replaced, leaving a menubar app with no picture in its
/// README at all. These come from the real views with fixed sample data, so
/// regenerating them all is one command.
///
/// **Rendered through `CALayer.render(in:)`, not `ImageRenderer`.** ImageRenderer
/// runs a single layout pass and cannot draw scroll content or controls: it
/// produces a header, an empty box where the list should be, and yellow
/// "unsupported" blocks where the buttons are. Hosting the view in an offscreen
/// window and rendering its layer goes through the same AppKit path the app
/// does, so what lands in the file is what ships. It needs no screen recording
/// permission and nobody to click anything.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["AGENT_INBOX_WRITE_SCREENSHOTS"] == "1"
    }

    /// Where the images go: `docs/` at the repo root, four levels up from this
    /// file, unless the drift check points somewhere disposable.
    private var docs: URL {
        if let dir = ProcessInfo.processInfo.environment["AGENT_INBOX_SCREENSHOT_DIR"] {
            return URL(fileURLWithPath: dir)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentInboxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs")
    }

    /// Everything that could make two runs differ, pinned. A screenshot that
    /// changes when nothing changed is a drift check that cries wolf, and one
    /// that carries the maintainer's machine name is a README that leaks it.
    private static let timeZone = TimeZone(identifier: "America/Toronto")!
    private static let locale = Locale(identifier: "en_US")

    /// Host `view` in an offscreen window and write its layer to `docs/<name>.png`.
    private func capture(_ view: some View, width: CGFloat, height: CGFloat? = nil,
                         named name: String) throws {
        _ = NSApplication.shared
        // The background has to be drawn here. In the app the window's material
        // provides it, and a hosting view has none, so the capture comes out on
        // white. That is not cosmetic: with a dark appearance the default text
        // colour is white, so every unstyled label renders white on white and
        // the result looks like the text failed to draw. Only explicitly
        // coloured text survives, which is a very convincing wrong diagnosis.
        let host = NSHostingView(
            rootView: AnyView(
                view.background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.timeZone, Self.timeZone)
                    .environment(\.locale, Self.locale)))
        let fitted = height ?? host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: width, height: fitted)

        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        // Far offscreen: it must be in a window to lay out and draw, but it
        // should never appear on anyone's display while this runs.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        // Key, not merely ordered in. A text field's placeholder is drawn by its
        // cell, and in a window that never becomes key the cell draws it
        // unclipped at the view's origin, so every placeholder appears beside
        // its box as though the value had been printed twice.
        window.makeKeyAndOrderFront(nil)
        // Let SwiftUI settle. The list's height comes from a measurement that
        // lands on the pass after the one that asked for it, so capturing
        // immediately renders an empty box where the rows belong.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()

        // cacheDisplay, not layer.render(in:). A text field is backed by an
        // AppKit control whose text ends up both in the layer contents and in
        // an unclipped sublayer, so rendering the layer tree draws every field's
        // value twice: once inside the box and once spilling out beside it.
        // cacheDisplay goes through the ordinary draw path, which clips.
        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "no bitmap rep for the view")
        host.cacheDisplay(in: host.bounds, to: rep)

        let png = try XCTUnwrap(
            rep.representation(using: .png, properties: [:]), "could not encode a png")

        let out = docs.appendingPathComponent("\(name).png")
        try png.write(to: out)
        print("wrote \(out.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        window.orderOut(nil)
    }

    /// Every model built during the run, removed together at the end.
    private var scratches: [IsolatedSettings] = []

    override func tearDown() {
        for scratch in scratches { scratch.remove() }
        scratches = []
        super.tearDown()
    }

    /// A model that reads and writes nothing real: its own defaults suite,
    /// in-memory secrets, and a scratch directory in place of ~/.agent-inbox.
    private func model(withItems items: [InboxItem]) -> AppModel {
        let scratch = IsolatedSettings("shot")
        scratches.append(scratch)
        let model = scratch.model()
        model.settings.transport = .ntfy
        model.settings.ntfyTopic = "agent-inbox-you-2f8a1c94b7e0"
        // Not Host.current(): that is this Mac's name, and it went into a
        // public README once.
        model.settings.hostLabel = "laptop"
        // A set-up Mac, in the scratch settings file: hooks present, all ours.
        model.installHooks()
        model.transientMessage = nil
        // The suite is fresh, so the server is the default and the Transport
        // pane draws ntfy.sh, on which the token row is not rendered at all.
        // Before the suite was isolated this test once committed a stray
        // "DIAGNOSTIC.example.com" into docs/ from whatever the test process's
        // defaults last held, and the token came from the login keychain the
        // test process shares with the installed app. Neither can happen now:
        // the token store is memory, and the keychain is never touched.
        if !items.isEmpty { model.store.add(items) }
        return model
    }

    /// Two conversations on two machines, each with a subject line, and text
    /// long enough to wrap. None of it is real.
    private var sampleItems: [InboxItem] {
        [
            InboxItem(
                id: "1", kind: .finished, repo: "marketing-site", host: "laptop",
                duration: "4m 12s", elapsed: 252,
                summary: "Rewrite the pricing page copy",
                ask: "make the middle tier the obvious pick",
                detail: nil,
                closing: "Pricing page rewritten, and the comparison table now marks the middle tier as recommended. … Left the annual toggle alone, since you did not ask for it.",
                waitingOn: nil, sessionID: "e5f6a7b8", cwd: "/Users/you/marketing-site",
                receivedAt: Date(timeIntervalSince1970: 1_700_000_600), presenceAtArrival: 0),
            // A turn short enough that the row offers to hide turns like it.
            InboxItem(
                id: "3", kind: .finished, repo: "docs-site", host: "laptop",
                duration: "0m 4s", elapsed: 4,
                summary: "Fix the broken anchor links",
                ask: "are you still there?",
                detail: nil, closing: "Still here. Nothing left to do on the anchors.",
                waitingOn: nil, sessionID: "c9d0e1f2", cwd: "/Users/you/docs-site",
                receivedAt: Date(timeIntervalSince1970: 1_700_000_300), presenceAtArrival: 0),
            InboxItem(
                id: "2", kind: .needsYou, repo: "checkout-api", host: "devbox",
                duration: nil,
                summary: "Refactor the checkout flow onto the new payments SDK",
                ask: "ok now handle the refund path too",
                detail: "Claude needs your permission to use Bash",
                closing: nil,
                waitingOn: "The refund path is wired up and tested. … Should I run the migration against staging first?",
                sessionID: "a1b2c3d4", cwd: "/srv/checkout-api",
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000), presenceAtArrival: 0),
        ]
    }

    func testWriteScreenshots() throws {
        try XCTSkipUnless(
            enabled,
            "set AGENT_INBOX_WRITE_SCREENSHOTS=1 to regenerate the images in docs/")

        try capture(
            MenuContentView().environment(model(withItems: sampleItems)),
            width: 560, named: "menubar-inbox")

        try capture(
            MenuContentView().environment(model(withItems: [])),
            width: 560, named: "menubar-empty")

        // Settings as a person reaches them: a page inside the popover, with
        // the back chevron and the segmented tabs, one capture per pane. Sized
        // to the view's own fitting height, exactly as the popover sizes
        // itself; forcing a taller frame makes the scroll view fill the slack
        // by scrolling, and the capture comes out mid-page with the header
        // and the tabs cut off.
        for pane in SettingsPanes.Pane.allCases {
            let m = model(withItems: [])
            m.menuRoute = .settings(pane)
            try capture(
                MenuContentView().environment(m),
                width: 560, named: "menu-settings-\(pane.rawValue.lowercased())")
        }

        try capture(
            WelcomeView().environment(model(withItems: [])),
            width: 560, named: "welcome")
    }
}

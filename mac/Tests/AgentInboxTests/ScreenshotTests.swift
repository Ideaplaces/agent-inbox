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

    /// `docs/` at the repo root, four levels up from this file.
    private var docs: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentInboxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs")
    }

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
            rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor))))
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
        window.orderFrontRegardless()
        // Let SwiftUI settle. The list's height comes from a measurement that
        // lands on the pass after the one that asked for it, so a single pass
        // renders it empty.
        host.wantsLayer = true
        // Let SwiftUI settle. Two things need the extra passes: the list's
        // height comes from a measurement that lands after the pass that asked
        // for it, and text arrives in sublayers committed a beat later than the
        // icons around it. Capture too early and the result looks like a font
        // problem, with every glyph missing and the chrome intact.
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        let layer = try XCTUnwrap(host.layer, "no layer to render")
        let scale = 2
        let pixels = (w: Int(host.bounds.width) * scale, h: Int(host.bounds.height) * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: pixels.w, height: pixels.h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))

        // CGContext draws from the bottom left, AppKit lays out from the top
        // left, so without the flip every screenshot comes out upside down.
        context.translateBy(x: 0, y: CGFloat(pixels.h))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        layer.render(in: context)

        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let out = docs.appendingPathComponent("\(name).png")
        try png.write(to: out)
        print("wrote \(out.lastPathComponent) \(pixels.w)x\(pixels.h)")
        window.orderOut(nil)
    }

    /// A model with a scratch directory, so nothing real is read or written.
    private func model(withItems items: [InboxItem]) -> AppModel {
        SenderConfig.directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-inbox-shot-\(UUID().uuidString)")
        let model = AppModel()
        model.settings.transport = .ntfy
        model.settings.ntfyTopic = "agent-inbox-you-2f8a1c94b7e0"
        if !items.isEmpty { model.store.add(items) }
        return model
    }

    /// Two conversations on two machines, each with a subject line, and text
    /// long enough to wrap. None of it is real.
    private var sampleItems: [InboxItem] {
        [
            InboxItem(
                id: "1", kind: .finished, repo: "marketing-site", host: "laptop",
                duration: "4m 12s",
                summary: "Rewrite the pricing page copy",
                ask: "make the middle tier the obvious pick",
                detail: "Pricing page rewritten, and the comparison table now marks the middle tier as recommended.",
                waitingOn: nil, sessionID: "e5f6a7b8", cwd: "/Users/you/marketing-site",
                receivedAt: Date(timeIntervalSince1970: 1_700_000_600), presenceAtArrival: 0),
            InboxItem(
                id: "2", kind: .needsYou, repo: "checkout-api", host: "devbox",
                duration: nil,
                summary: "Refactor the checkout flow onto the new payments SDK",
                ask: "ok now handle the refund path too",
                detail: "Claude needs your permission to use Bash",
                waitingOn: "Should I run the migration against staging first?",
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

        try capture(
            SettingsView().environment(model(withItems: [])),
            width: 520, named: "settings")

        try capture(
            WelcomeView().environment(model(withItems: [])),
            width: 560, named: "welcome")
    }
}

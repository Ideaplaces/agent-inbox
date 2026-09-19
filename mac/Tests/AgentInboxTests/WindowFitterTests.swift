import AppKit
import XCTest

@testable import AgentInbox

/// 0.1.34 shipped a fitter that was meant to shrink the menubar window and
/// did not, because it only ran when the measured height changed. The menu
/// opens at the stale height of its last session with content that has not
/// changed, so nothing called it. These reproduce that: a window on screen,
/// taller than its content, and a height that never changes.
@MainActor
final class WindowFitterTests: XCTestCase {
    private var window: NSWindow!
    private var fitter: FittingView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 560, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        fitter = FittingView(frame: .zero)
        fitter.contentHeight = 180
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        fitter = nil
        super.tearDown()
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testAWindowAlreadyTooTallIsFittedWhenTheMenuOpensWithNoHeightChange() {
        window.contentView?.addSubview(fitter)
        // Let the fit queued by joining the window run while the window is
        // still off screen, where it does nothing. Without this the queued fit
        // lands after orderFront and the test passes with the observers
        // removed, which is to say it tested nothing.
        settle()
        let top = window.frame.maxY
        window.orderFrontRegardless()
        settle()
        XCTAssertEqual(window.frame.height, 700, "nothing has asked for a fit yet")
        // What MenuBarExtra does on every open, with nothing re-measured.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        settle()
        XCTAssertEqual(window.frame.height, 180, "the stale height survived the menu opening")
        XCTAssertEqual(window.frame.maxY, top, "the top edge is what hangs under the menubar")
    }

    /// The first open: the measurement lands before the window is on screen.
    /// The old fitter's only call was skipped here and never retried.
    func testAMeasurementThatArrivedBeforeTheWindowWasVisibleIsNotLost() {
        window.contentView?.addSubview(fitter)
        fitter.fit()
        settle()
        XCTAssertEqual(window.frame.height, 700, "a window that is not on screen is left alone")

        window.orderFrontRegardless()
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        settle()
        XCTAssertEqual(window.frame.height, 180)
    }

    func testAWindowThatFitsIsNotTouched() {
        fitter.contentHeight = 700
        window.contentView?.addSubview(fitter)
        window.orderFrontRegardless()
        let before = window.frame
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        settle()
        XCTAssertEqual(window.frame, before)
    }
}

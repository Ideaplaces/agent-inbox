import AppKit
import SwiftUI

/// Shrinks the menubar window to its content.
///
/// A `MenuBarExtra` window grows with its content and never shrinks again: it
/// keeps the tallest height the list reached this session, and when the list
/// is back to one row SwiftUI centres that row in the leftover space. The menu
/// then floats a few hundred points below the bar with dead margin above and
/// below, which reads as a padding bug and is not one. 0.1.8 showed it, was
/// put down to the SDK the build linked against, and 0.1.33 showed it again on
/// a current SDK the moment its taller rows made the shrink bigger.
///
/// So the app does the shrinking. Sat in the background of the menu's root
/// stack, this sees the window the stack is hosted in and, whenever the
/// measured content is shorter than the window, sets the window's frame to
/// the content with the top edge where it was, since the top is what hangs
/// under the menubar. Growth is left to SwiftUI, which handles it.
struct WindowFitter: NSViewRepresentable {
    /// The measured height of the whole menu.
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> FittingView {
        FittingView(frame: .zero)
    }

    func updateNSView(_ view: FittingView, context: Context) {
        view.contentHeight = contentHeight
        view.fit()
    }

    /// The frame the window should take for content `height` tall, or nil
    /// when nothing needs to move. Only a window taller than its content is
    /// changed, and only by enough to matter: a fraction of a point is layout
    /// noise, and resizing on it would fight SwiftUI every pass.
    static func frame(fitting height: CGFloat, current: NSRect) -> NSRect? {
        guard height > 0, current.height - height > 1 else { return nil }
        return NSRect(
            x: current.minX, y: current.maxY - height,
            width: current.width, height: height)
    }
}


/// The view that does the fitting, and knows when to.
///
/// The first version fitted only when the measured height changed, from
/// inside `updateNSView`, and skipped a window that was not visible yet. Both
/// are the common case, not the edge: the menu opens at the stale height of
/// its last session with content that has not changed since, so nothing
/// called it, and on a first open the measurement lands before the window is
/// on screen, so the one call it got was the one it skipped. 0.1.34 shipped
/// with that and floated exactly as before.
///
/// So this also fits whenever its window becomes key or changes occlusion,
/// which is every time the menu opens, with whatever height was measured last.
final class FittingView: NSView {
    var contentHeight: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            })
        }
        fit()
    }

    /// Deferred, because this is reached from inside a layout pass and a
    /// window must not be resized in the middle of one. Only a window on
    /// screen: one already ordered out has nothing to fit, and a late resize
    /// of it changes which window is key (the screenshot suite found that).
    func fit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible,
                  let frame = WindowFitter.frame(
                      fitting: self.contentHeight, current: window.frame)
            else { return }
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

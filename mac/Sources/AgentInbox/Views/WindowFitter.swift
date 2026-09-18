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

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Deferred: this runs inside a layout pass, and the window must not be
        // resized in the middle of one.
        let height = contentHeight
        DispatchQueue.main.async {
            guard let window = view.window,
                  let frame = Self.frame(fitting: height, current: window.frame)
            else { return }
            window.setFrame(frame, display: true, animate: false)
        }
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

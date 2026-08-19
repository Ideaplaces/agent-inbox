import CoreGraphics
import Foundation

/// Time you have actually spent at this Mac.
///
/// Inbox items age against this clock instead of wall time. While you work the
/// list drains so it stays short; while you are away it stops draining, so a
/// coffee-break backlog is still there when you get back.
final class Presence {
    private var stateURL: URL { SenderConfig.directory.appendingPathComponent("presence") }
    private(set) var seconds: Int

    init() {
        let url = SenderConfig.directory.appendingPathComponent("presence")
        let saved = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        seconds = Int(saved ?? "") ?? 0
    }

    /// Seconds since the last keyboard, mouse, or trackpad event.
    var idleSeconds: Int {
        let anyInput = CGEventType(rawValue: ~0)!
        return Int(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput))
    }

    /// Advance the clock by one poll interval, but only if you were here for it.
    func tick(interval: Int, idleThreshold: Int) {
        guard idleSeconds < idleThreshold else { return }
        seconds += interval
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(seconds).write(to: stateURL, atomically: true, encoding: .utf8)
    }
}

import Foundation

/// The only way the connection code waits or asks what time it is.
///
/// Every reconnect, every watchdog and every "a day has passed" check used to
/// call `Task.sleep` and `Date()` directly, which made the parts most likely
/// to fail in the wild the ones no test could reach: a test of a 60 second
/// backoff would take 60 seconds. Routing all of it through one small seam
/// lets a test wind the clock by hand and lets the app keep using the real
/// one without knowing the difference.
protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
    var now: Date { get }
}

/// Real time. The default everywhere a `Sleeper` is asked for.
struct RealSleeper: Sleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    var now: Date { Date() }
}

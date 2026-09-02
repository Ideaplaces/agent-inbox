import Foundation

/// Presence and expiry, on a clock of their own.
///
/// They used to ride the poll timer, which is why a change to the poll
/// interval quietly changed how fast the inbox aged. Now that messages arrive
/// on a held-open connection there is no poll timer to ride, and nothing
/// about how the connection is doing should decide when the inbox ages.
@MainActor
final class Housekeeping {
    static let interval = 15

    private let sleeper: any Sleeper
    private let sweep: @MainActor () -> Void
    private var task: Task<Void, Never>?

    /// The sweep is a closure so a test can count calls without a real
    /// `Presence`, whose idle clock reads the machine's actual input devices.
    init(sleeper: any Sleeper = RealSleeper(), sweep: @escaping @MainActor () -> Void) {
        self.sleeper = sleeper
        self.sweep = sweep
    }

    /// The real sweep: advance the presence clock if you are here, then
    /// retire what has sat through enough of your time.
    convenience init(
        presence: Presence, store: InboxStore, settings: AppSettings,
        sleeper: any Sleeper = RealSleeper()
    ) {
        self.init(sleeper: sleeper) {
            presence.tick(interval: Self.interval, idleThreshold: settings.idleThreshold)
            store.expire(afterMinutes: settings.expireMinutes)
        }
    }

    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sweep()
                try? await self.sleeper.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

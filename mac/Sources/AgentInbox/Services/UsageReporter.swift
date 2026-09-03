import Foundation

/// Tallies arrivals and sends the daily count. See `Analytics` for what is
/// sent and why so little.
@MainActor
final class UsageReporter {
    private let settings: AppSettings
    private let sleeper: any Sleeper
    private let sender: any EventSender

    init(
        settings: AppSettings, sleeper: any Sleeper = RealSleeper(),
        sender: any EventSender = URLSessionEventSender()
    ) {
        self.settings = settings
        self.sleeper = sleeper
        self.sender = sender
    }

    /// Tally one arrival. Kind only, and only in memory on this Mac until a
    /// day's worth is sent as a single number.
    func count(_ item: InboxItem) {
        guard settings.shareUsageData else { return }
        switch item.kind {
        case .finished: settings.pendingFinished += 1
        case .needsYou: settings.pendingNeedsYou += 1
        }
    }

    /// One event a day, carrying the counts, and only when switched on.
    ///
    /// Driven off arrivals rather than a timer of its own: the connection is
    /// already the app's heartbeat, and a Mac that is asleep or offline should
    /// report when it wakes rather than on a schedule that ran without it.
    func reportIfADayHasPassed() {
        guard settings.shareUsageData, !settings.analyticsID.isEmpty else { return }
        let now = sleeper.now
        guard Analytics.shouldSend(last: settings.analyticsLastSent, now: now) else { return }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let payload = Analytics.payload(
            distinctID: settings.analyticsID,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            osVersion: "\(os.majorVersion).\(os.minorVersion)",
            finished: settings.pendingFinished,
            needsYou: settings.pendingNeedsYou,
            watchMode: settings.watchMode,
            selfHosted: settings.ntfyServer != AppSettings.publicNtfyServer,
            customTags: settings.watchTags != AppSettings.defaultWatchTags)
        if let request = Analytics.request(for: payload) { sender.send(request) }

        settings.analyticsLastSent = now
        settings.pendingFinished = 0
        settings.pendingNeedsYou = 0
    }
}

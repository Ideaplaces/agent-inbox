import Foundation

/// Anonymous usage counts, off unless you turn them on.
///
/// The point is to answer two questions nobody can answer from GitHub's
/// download numbers: how many installs are still alive, and how much work this
/// thing actually reports. Nothing else is worth the trouble of asking for.
///
/// Three decisions make this defensible, and all three are load bearing:
///
/// - **Off by default.** Every project that got burned over telemetry shipped
///   it on. This app carries snippets of people's prompts around, so it is the
///   last one that should also phone home uninvited.
/// - **One event a day, carrying counts.** A message-shaped event per
///   notification would mean a network call every time an agent finishes, and a
///   timeline of when someone works. A daily total answers the same question
///   and describes nobody's day.
/// - **No free text, ever.** Everything sent is a number, a bool or a fixed
///   enum, which is a property the tests can actually check. Repo names,
///   directory paths, host labels, session ids, topics, tokens and message
///   text are not "excluded", they are never assembled in the first place.
enum Analytics {
    /// A public project key, the kind that ships inside client apps. It can
    /// only write events. Querying needs the personal key, which is in the
    /// vault and not here.
    static let projectKey = "phc_REr8yvSNak9ePrzkQmEJlC1JSMxZLME1QhXntAplPh7"
    static let endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    static let eventName = "agent_inbox_daily"

    /// Has a day rolled over since the last send?
    ///
    /// A calendar day rather than 24 hours, so a machine used every morning
    /// reports every morning instead of drifting later and eventually skipping
    /// one. Separated out because it is the whole schedule, and a schedule that
    /// is wrong either spams or goes silent.
    static func shouldSend(last: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let last else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    /// The event, built from counts and flags alone.
    ///
    /// `settings` is read for shape, never for content: whether a token exists,
    /// not the token; whether the server is the public one, not which server.
    static func payload(
        distinctID: String,
        appVersion: String,
        osVersion: String,
        finished: Int,
        needsYou: Int,
        watchMode: String,
        selfHosted: Bool,
        customTags: Bool
    ) -> [String: Any] {
        [
            "api_key": projectKey,
            "event": eventName,
            "distinct_id": distinctID,
            "properties": [
                "app_version": appVersion,
                "macos_version": osVersion,
                "notifications_finished": finished,
                "notifications_needs_you": needsYou,
                "watch_mode": watchMode,
                "self_hosted": selfHosted,
                "custom_tags": customTags,
                // Belt and braces next to the project's own "discard client IP"
                // setting, which is the control that actually decides this.
                "$geoip_disable": true,
            ],
        ]
    }

    /// Post it, and never let it matter. An analytics endpoint having a bad day
    /// is not a reason for anything here to behave differently.
    static func send(_ payload: [String: Any], session: URLSession = .shared) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10
        session.dataTask(with: request).resume()
    }
}

import Foundation

/// The sentences the settings and setup screens print under their controls.
///
/// Kept apart from `AppSettings`, which stores values, so a change of wording
/// never touches the file that decides what gets written to disk, and so the
/// tests that pin what these sentences must and must not say read as tests of
/// copy rather than of storage.
enum SettingsCopy {
    /// How the shortest-reportable-turn setting reads in the UI.
    ///
    /// Zero has to say "every turn" rather than "0s", because 0s is the one
    /// value people will not believe means what it means. The floor exists
    /// because a quick back-and-forth is not worth a notification, but nobody
    /// discovers that by watching a short turn produce nothing: it looks
    /// exactly like the app being broken, which is how it was first reported.
    static func minSecondsCaption(_ seconds: Int) -> String {
        seconds <= 0 ? "Every turn" : "\(seconds)s"
    }

    /// What the report mode actually decides, which is narrower than either
    /// label suggests.
    ///
    /// It is the default for a conversation nobody has tagged, and nothing
    /// more: `notify.sh` records a watch tag as "on" and a mute tag as "off"
    /// against the session, and only falls back to the mode when neither has
    /// been seen. Both fields therefore stay live in both modes, so a pane that
    /// greyed one out would be stating something the sender does not do. What
    /// changes is which one you reach for, and that is what these say.
    static func reportModeCaption(watchMode: String) -> String {
        watchMode == "tagged"
            ? "A conversation you have not tagged stays silent. This is only the default: "
                + "either tag overrides it, and the most recent one wins."
            : "A conversation you have not tagged reports. This is only the default: either "
                + "tag overrides it, and the most recent one wins."
    }

    static func watchTagCaption(watchMode: String) -> String {
        watchMode == "tagged"
            ? "The only thing that makes a conversation report."
            : "Turns a conversation back on after you muted it."
    }

    static func muteTagCaption(watchMode: String) -> String {
        watchMode == "tagged"
            ? "Silences a conversation you had tagged to watch."
            : "Silences one conversation."
    }

    /// The sentence under the topic field. Three states, because "keep the
    /// topic secret" is wrong advice on a server that authenticates and
    /// useless advice on one that then refuses you.
    static func topicExplanation(server: String, token: String) -> String {
        switch AppSettings.accessModel(server: server, token: token) {
        case .tokenIsTheSecret:
            return "The token is the secret here, not the topic. The server checks it on every "
                + "read and every publish, so where it denies anonymous access the topic name "
                + "grants nothing on its own. It is kept in the Keychain, and mirrored to "
                + "~/.agent-inbox/ntfy-token so the senders on this Mac can read it."
        case .topicIsTheSecret where server != AppSettings.publicNtfyServer:
            return "No token, so this server is being asked anonymously and the topic name is "
                + "still the whole secret. If the server does not allow anonymous access, "
                + "nothing arrives: the status below turns red with the HTTP code after two "
                + "failed polls."
        case .topicIsTheSecret:
            return "The topic name is the whole secret. ntfy.sh puts no gate in front of it, so "
                + "anyone who learns the name reads every message and can publish to it. That "
                + "is why the generated one carries 96 bits of randomness instead of a name you "
                + "would choose. Keep it private."
        }
    }

    /// The line above the topic field. "Nothing to provision" is true of
    /// ntfy.sh and is the first thing a self-hosted server contradicts.
    static func transportIntro(server: String) -> String {
        server == AppSettings.publicNtfyServer
            ? "No account, no bot, nothing to provision. A topic name is the whole channel, "
                + "and one has already been generated for you."
            : "Pointing at your own ntfy. The topic still names the channel; what that server "
                + "requires is what decides who can reach it."
    }
}

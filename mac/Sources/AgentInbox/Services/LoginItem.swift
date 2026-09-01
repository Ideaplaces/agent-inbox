import Foundation
import ServiceManagement

/// Launch at login, done with the modern API so it appears under
/// System Settings > General > Login Items with the app's own name.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether a launch should turn this on without being asked.
    ///
    /// A menubar app nobody launched is not an inbox, and `brew install`
    /// only copies a bundle: it starts nothing and registers nothing. So the
    /// first launch opts you in, and every later one leaves the answer alone.
    ///
    /// Split out from the launch path so the rule that matters can be
    /// asserted: a person who turns this off must stay turned off. Re-enabling
    /// it on the next launch would be the app arguing with them.
    static func shouldEnableOnLaunch(hasDecided: Bool, isEnabled: Bool) -> Bool {
        !hasDecided && !isEnabled
    }

    /// Apply that rule, and record the answer either way.
    @MainActor
    static func enableOnFirstLaunch(_ settings: AppSettings = .shared) {
        guard shouldEnableOnLaunch(
            hasDecided: settings.hasDecidedLoginItem, isEnabled: isEnabled)
        else {
            settings.hasDecidedLoginItem = true
            return
        }
        try? set(true)
        settings.hasDecidedLoginItem = true
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

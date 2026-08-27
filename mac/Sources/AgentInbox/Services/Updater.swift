import Foundation
import Observation
import Sparkle

/// In-app updates.
///
/// A menubar app is easy to forget is running, so "download the new DMG" is a
/// step nobody takes. Sparkle checks the appcast, verifies the EdDSA signature
/// against the public key baked into Info.plist, and installs.
///
/// Homebrew users are covered by `brew upgrade`, but most people will not have
/// installed that way.
@Observable
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController

    /// Mirrors the updater so a menu item can disable itself while a check is
    /// already running.
    private(set) var canCheck = true

    init() {
        // startingUpdater: true schedules the background checks described by
        // SUScheduledCheckInterval in Info.plist.
        //
        // Never under XCTest. Sparkle needs a real app bundle, so inside a test
        // host it fails and puts "Unable to Check For Updates ... verify you
        // have the latest version of xctest" on screen, which is both alarming
        // and unrelated to whatever is being tested.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: !underTest, updaterDelegate: nil, userDriverDelegate: nil)
        observeCanCheck()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? {
        controller.updater.lastUpdateCheckDate
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle exposes this as KVO, not as a publisher.
    private func observeCanCheck() {
        canCheck = controller.updater.canCheckForUpdates
        // The weak capture belongs to the Task, not the observation closure:
        // capturing it outside makes `self` a captured var that older
        // toolchains refuse to read from concurrent code.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in self?.canCheck = value }
        }
    }

    private var observation: NSKeyValueObservation?
}

import XCTest

@testable import AgentInbox

/// One setting, one control.
///
/// The turn-length floor shipped with two: an "Ignore turns under" stepper
/// under Polling that had been there all along, and a "Report turns longer
/// than" stepper added under Conversations by someone who did not notice.
/// They wrote the same value, so they moved together, and the pane read as two
/// settings that were mysteriously linked. Nothing failed, no test broke, and
/// the only way it surfaced was a person looking at the screen and asking what
/// the difference was.
///
/// This reads the settings pane's own source and counts the bindings, because
/// the defect is a duplicate control rather than wrong behaviour, and there is
/// nothing else about it to assert.
final class SettingsBindingTests: XCTestCase {
    func testNoSettingIsBoundToTwoControls() throws {
        let source = try String(contentsOf: settingsViewSource(), encoding: .utf8)

        var counts: [String: Int] = [:]
        var rest = Substring(source)
        while let marker = rest.range(of: "$settings.") {
            let after = rest[marker.upperBound...]
            let name = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            if !name.isEmpty { counts[name, default: 0] += 1 }
            rest = after
        }

        XCTAssertFalse(counts.isEmpty, "found no bindings, so this test is checking nothing")
        let duplicated = counts.filter { $0.value > 1 }.keys.sorted()
        XCTAssertEqual(
            duplicated, [],
            "these settings have more than one control writing them: \(duplicated)")
    }

    /// `#filePath` is this file inside the checkout, so the sources are two
    /// directories over from the tests. Resolved rather than hardcoded, so
    /// moving the package does not quietly disable the check.
    private func settingsViewSource() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()  // AgentInboxTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
        let source = root
            .appendingPathComponent("Sources/AgentInbox/Views/SettingsView.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "settings pane source not found at \(source.path)")
        return source
    }
}

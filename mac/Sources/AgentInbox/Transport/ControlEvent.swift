import Foundation

/// A message that tells the inbox to do something rather than appearing in it.
///
/// Typing in a conversation is proof you have seen it, so the row waiting for
/// you there is answered and should go. The sender knows you typed; only the
/// app knows what is on screen, so the fact has to travel between them, and the
/// transport is the only thing they share.
///
/// It rides the same topic as everything else and is told apart by an exact
/// title. A real event's title is "<symbol> <repo> @ <host>", so nothing
/// legitimate can collide with the sentinel, and an unrecognised control event
/// is dropped rather than shown: a future instruction this version does not
/// understand must not surface as a garbled row.
enum ControlEvent: Equatable {
    case clearSession(String)

    static let title = "agent-inbox:control"

    static func isControl(_ message: TransportMessage) -> Bool {
        message.title.trimmingCharacters(in: .whitespaces) == title
    }

    /// Parsed from the body, `clear <sessionID>`. Returns nil for anything this
    /// version does not recognise, which the caller drops.
    static func parse(_ message: TransportMessage) -> ControlEvent? {
        guard isControl(message) else { return nil }
        let parts = message.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "clear":
            let session = String(parts[1]).trimmingCharacters(in: .whitespaces)
            return session.isEmpty ? nil : .clearSession(session)
        default:
            return nil
        }
    }
}

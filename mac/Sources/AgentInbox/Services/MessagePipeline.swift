import Foundation

/// Turns what the transport delivered into rows in the store, in wire order.
///
/// Nothing here knows how the messages arrived or what happens to the rows
/// afterwards. It is the one piece of the receiving path that is pure
/// ordering logic, which is why it lives on its own: the tests that pin the
/// interleaving of events and control messages need nothing but a store.
@MainActor
struct MessagePipeline {
    let store: InboxStore
    let presence: Presence

    /// Fold one batch of messages into the store, in arrival order, and
    /// return the ones worth announcing.
    ///
    /// Order is the whole point. Control events are instructions rather than
    /// entries: applied, never shown, and an unrecognised one dropped rather
    /// than drawn as a row with a sentinel for a title. But they cannot all be
    /// applied up front. A turn that ends and is then typed into publishes an
    /// event and its clear seconds apart, so both land in one batch; clearing
    /// first would run against a store that does not hold the row yet, and the
    /// row would then never leave.
    ///
    /// Pending items are therefore flushed before each control, which makes the
    /// sequence inside a batch mean what it did on the wire.
    ///
    /// Nothing is announced for a conversation you are already in: the clear
    /// said you are there, so a banner for it would be about something you are
    /// looking at.
    @discardableResult
    func apply(_ messages: [TransportMessage]) -> [InboxItem] {
        var pending: [TransportMessage] = []
        var arrived: [InboxItem] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            arrived += store.add(
                pending.compactMap { MessageParser.parse($0, presence: presence.seconds) })
            pending.removeAll()
        }

        for message in messages {
            guard ControlEvent.isControl(message) else {
                pending.append(message)
                continue
            }
            flushPending()
            if case .clearSession(let session)? = ControlEvent.parse(message) {
                store.markSessionRead(session)
            }
        }
        flushPending()
        return arrived.filter { store.item(id: $0.id)?.isRead == false }
    }
}

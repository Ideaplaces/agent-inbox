import Foundation
@testable import AgentInbox

/// A clock the test winds by hand.
///
/// Every sleep parks until the test advances past its deadline, so a suite
/// that walks a 60 second backoff still finishes in milliseconds. Cancelling
/// the task that is sleeping throws `CancellationError`, exactly as
/// `Task.sleep` does, because that is what the receiver's loops rely on to
/// stop: a double that swallowed cancellation would leave every old task
/// parked forever and the tests would still go green.
final class TestSleeper: Sleeper, @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var pending: [Pending] = []
    private var log: [Duration] = []

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = now
    }

    var now: Date { lock.withLock { current } }

    /// Every sleep asked for, in order, whether or not it completed.
    var requested: [Duration] { lock.withLock { log } }

    /// How many tasks are parked right now.
    var sleeping: Int { lock.withLock { pending.count } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                // The cancellation check and the enqueue share the lock with
                // the handler below, so a cancel that lands between them
                // cannot leave a continuation nobody will ever resume.
                lock.withLock {
                    log.append(duration)
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        pending.append(Pending(
                            id: id, deadline: current + duration.seconds,
                            continuation: continuation))
                    }
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> Pending? in
                guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
                return pending.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Move the clock forward and wake every sleep whose deadline has passed,
    /// earliest first. The woken tasks are only scheduled here; the caller
    /// yields to let them run.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Pending] in
            current += duration.seconds
            let ready = pending.filter { $0.deadline <= current }
            pending.removeAll { $0.deadline <= current }
            return ready.sorted { $0.deadline < $1.deadline }
        }
        for sleep in due { sleep.continuation.resume() }
    }
}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Yield to the main actor until `condition` holds.
///
/// Waking a sleep or scripting a stream only schedules work; nothing runs
/// until the test gives up the main actor. Yielding in a bounded loop lets
/// that work happen without a real clock anywhere: when the condition is
/// never going to hold the loop ends in a few milliseconds and the assertion
/// that follows reports it.
@MainActor
func settle(until condition: @MainActor () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
}

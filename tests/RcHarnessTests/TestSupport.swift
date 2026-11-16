import Foundation
@testable import RcHarness

/// Wait for playback completions already submitted to the main queue, without
/// advancing timers or relying on the machine's scheduling speed.
@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// Deterministic scheduler for controllers that take a
/// `RemoteVoiceSessionController.Scheduler`; time only moves via `advance`.
final class TestClock {
    private var now: TimeInterval = 0
    var time: TimeInterval { now }
    private var tasks: [(TimeInterval, DispatchWorkItem, () -> Void)] = []

    func schedule(after delay: TimeInterval, operation: @escaping () -> Void) -> DispatchWorkItem {
        // The work item is a cancellation token; run callbacks directly so a
        // callback can cancel itself without entering libdispatch's block runtime.
        let work = DispatchWorkItem(block: {})
        tasks.append((now + delay, work, operation))
        return work
    }

    func advance(_ duration: TimeInterval) {
        let end = now + duration
        while let task = tasks.filter({ $0.0 <= end + 0.000001 }).min(by: { $0.0 < $1.0 }) {
            tasks.removeAll { $0.1 === task.1 }
            now = task.0
            if !task.1.isCancelled { task.2() }
        }
        now = end
    }
}

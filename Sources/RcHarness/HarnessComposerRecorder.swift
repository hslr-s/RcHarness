import Foundation

/// Watches the system-wide Accessibility focus while the user clicks the
/// composer they want to record. It only stores AX metadata, never text.
@MainActor
final class HarnessComposerRecorder {
    typealias SnapshotProvider = @MainActor () -> HarnessComposerTarget?
    typealias Scheduler = RemoteVoiceSessionController.Scheduler

    private let snapshot: SnapshotProvider
    private let schedule: Scheduler
    private let pollInterval: TimeInterval
    private let now: () -> TimeInterval
    private var task: DispatchWorkItem?
    private var completion: ((HarnessComposerTarget?) -> Void)?
    private var deadline: TimeInterval = 0

    init(snapshot: @escaping SnapshotProvider = HarnessComposerFocus.focusedDescriptor,
         schedule: @escaping Scheduler = RemoteVoiceSessionController.mainQueue,
         pollInterval: TimeInterval = 0.15,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.snapshot = snapshot
        self.schedule = schedule
        self.pollInterval = pollInterval
        self.now = now
    }

    func start(timeout: TimeInterval = 8, completion: @escaping (HarnessComposerTarget?) -> Void) {
        cancel()
        self.completion = completion
        deadline = now() + timeout
        poll()
    }

    func cancel() {
        task?.cancel()
        task = nil
        completion = nil
    }

    private func poll() {
        if let target = snapshot() {
            finish(target)
            return
        }
        guard now() < deadline else {
            finish(nil)
            return
        }
        task = schedule(pollInterval) { [weak self] in self?.poll() }
    }

    private func finish(_ target: HarnessComposerTarget?) {
        task?.cancel()
        task = nil
        let completion = self.completion
        self.completion = nil
        completion?(target)
    }
}

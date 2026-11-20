import Foundation

/// Captures each gesture's mappings at the first press so an edit cannot leave a key held.
@MainActor
final class RemoteGestureController {
    private final class Session {
        let single: ButtonMapping
        let double: ButtonMapping
        let long: ButtonMapping
        let immediate: Bool
        var held = true
        var second = false
        var longFired = false
        var work: DispatchWorkItem?
        var repeatWork: DispatchWorkItem?
        var opensSwitcher: Bool {
            [single, double, long].contains { $0.action == .openHarnessSwitcher }
        }
        init(_ input: ControllerInput, _ mapping: RemoteMapping) {
            single = mapping[input, .single]
            double = mapping[input, .double]
            long = mapping[input, .long]
            immediate = double.action == .disabled && long.action == .disabled
        }
    }
    /// Defaults double as the TestClock reference used by gesture tests.
    static let defaultDoubleTapWindow: TimeInterval = 0.2
    static let defaultLongPressDelay: TimeInterval = 0.55
    static let doubleTapWindowRange: ClosedRange<TimeInterval> = 0.1...0.4
    static let longPressDelayRange: ClosedRange<TimeInterval> = 0.4...1.0
    static func clampDoubleTapWindow(_ value: TimeInterval) -> TimeInterval {
        min(doubleTapWindowRange.upperBound, max(doubleTapWindowRange.lowerBound, value))
    }
    static func clampLongPressDelay(_ value: TimeInterval) -> TimeInterval {
        min(longPressDelayRange.upperBound, max(longPressDelayRange.lowerBound, value))
    }
    static func repeats(_ mapping: ButtonMapping) -> Bool {
        mapping.action == .rapidDelete || (mapping.repeatWhileHeld && mapping.action.supportsRepeatWhileHeld)
    }
    static let doubleTapWindow = defaultDoubleTapWindow
    static let longPressDelay = defaultLongPressDelay
    static let rapidDeleteDelay: TimeInterval = 0.35
    static let rapidDeleteInterval: TimeInterval = 0.06
    private let schedule: RemoteVoiceSessionController.Scheduler
    private(set) var configuredDoubleTapWindow: TimeInterval = RemoteGestureController.defaultDoubleTapWindow
    private(set) var configuredLongPressDelay: TimeInterval = RemoteGestureController.defaultLongPressDelay
    private var sessions: [ControllerInput: Session] = [:]
    private var operationMode: ControllerOperationMode = .mapping
    // Modal actions need the originating input even after a delayed gesture.
    var onOutput: ((ButtonMapping, Bool, ControllerInput) -> Void)?

    init(schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue) {
        self.schedule = schedule
    }

    func setTiming(doubleTapWindow: TimeInterval, longPressDelay: TimeInterval) {
        configuredDoubleTapWindow = doubleTapWindow
        configuredLongPressDelay = longPressDelay
    }

    func setOperationMode(_ mode: ControllerOperationMode) {
        cancel()
        operationMode = mode
    }

    func handle(_ input: ControllerInput, pressed: Bool, mapping: RemoteMapping) {
        guard operationMode == .mapping else { return }
        if pressed {
            if let old = sessions[input] {
                guard !old.held else {
                    if old.opensSwitcher {
                        Log.switcher.notice("Gesture ignored repeated-down input=\(input.rawValue, privacy: .public)")
                    }
                    return
                }
                old.work?.cancel()
                old.held = true
                old.second = true
                scheduleLongPress(old, input: input)
                return
            }
            let session = Session(input, mapping)
            sessions[input] = session
            if session.immediate {
                if Self.repeats(session.single) {
                    tap(session.single, input: input, trigger: .single, session: session)
                    scheduleRepeat(session, input: input, mapping: session.single, after: Self.rapidDeleteDelay)
                } else {
                    logResolution(session.single, input: input, trigger: .single, session: session)
                    onOutput?(session.single, true, input)
                }
            } else { scheduleLongPress(session, input: input) }
        } else {
            guard let session = sessions[input], session.held else { return }
            session.held = false
            session.work?.cancel()
            session.repeatWork?.cancel()
            if session.immediate {
                if !Self.repeats(session.single) { onOutput?(session.single, false, input) }
                sessions[input] = nil
            }
            else if session.longFired { sessions[input] = nil }
            else if session.second { tap(session.double, input: input, trigger: .double, session: session); sessions[input] = nil }
            else if session.double.action != .disabled {
                session.work = schedule(configuredDoubleTapWindow) { [weak self, weak session] in
                    guard let self, let session, self.sessions[input] === session, !session.held else { return }
                    self.sessions[input] = nil
                    self.tap(session.single, input: input, trigger: .single, session: session)
                }
            } else { tap(session.single, input: input, trigger: .single, session: session); sessions[input] = nil }
        }
    }
    private func scheduleLongPress(_ session: Session, input: ControllerInput) {
        // An explicit long-press binding takes precedence over repeating the single action.
        let mapping = session.long.action == .disabled && Self.repeats(session.single)
            ? session.single : session.long
        guard mapping.action != .disabled else { return }
        session.work = schedule(configuredLongPressDelay) { [weak self, weak session] in
            guard let self, let session, self.sessions[input] === session, session.held else { return }
            session.longFired = true
            self.tap(mapping, input: input, trigger: .long, session: session)
            if Self.repeats(mapping) {
                self.scheduleRepeat(session, input: input, mapping: mapping, after: Self.rapidDeleteInterval)
            }
        }
    }
    private func scheduleRepeat(_ session: Session, input: ControllerInput, mapping: ButtonMapping, after delay: TimeInterval) {
        session.repeatWork = schedule(delay) { [weak self, weak session] in
            guard let self, let session, self.sessions[input] === session, session.held else { return }
            self.onOutput?(mapping, true, input)
            self.onOutput?(mapping, false, input)
            self.scheduleRepeat(session, input: input, mapping: mapping, after: Self.rapidDeleteInterval)
        }
    }
    func cancel() {
        let old = sessions
        sessions.removeAll()
        for (input, session) in old {
            if session.opensSwitcher {
                Log.switcher.notice("Gesture cancelled input=\(input.rawValue, privacy: .public) held=\(session.held) second=\(session.second) long_fired=\(session.longFired)")
            }
            session.work?.cancel()
            session.repeatWork?.cancel()
            if session.immediate && session.held && !Self.repeats(session.single) { onOutput?(session.single, false, input) }
        }
    }
    func cancel(_ input: ControllerInput) {
        guard let session = sessions.removeValue(forKey: input) else { return }
        session.work?.cancel()
        session.repeatWork?.cancel()
        if session.immediate && session.held && !Self.repeats(session.single) { onOutput?(session.single, false, input) }
    }
    private func tap(_ mapping: ButtonMapping, input: ControllerInput, trigger: ButtonTrigger, session: Session) {
        logResolution(mapping, input: input, trigger: trigger, session: session)
        onOutput?(mapping, true, input)
        onOutput?(mapping, false, input)
    }

    private func logResolution(_ mapping: ButtonMapping, input: ControllerInput, trigger: ButtonTrigger, session: Session) {
        guard session.opensSwitcher else { return }
        Log.switcher.notice("Gesture resolved input=\(input.rawValue, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) action=\(mapping.action.rawValue, privacy: .public)")
    }
}

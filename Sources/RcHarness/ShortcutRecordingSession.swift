import AppKit
import CoreGraphics

@MainActor
final class ShortcutRecordingSession {
    enum Mode {
        /// Single pass: one or more modifiers plus a key, captured on full release.
        case full
        /// Capture one or more modifier keys only; ordinary keys are ignored.
        case modifiers
        /// Capture one ordinary key only; modifiers are ignored.
        case key
    }

    private static let modifierKeys: [(code: UInt16, flag: CGEventFlags, label: String)] = [
        (VirtualKey.function, .maskSecondaryFn, "Fn / 地球键"),
        (54, .maskCommand, "右侧 Command"), (55, .maskCommand, "左侧 Command"),
        (58, .maskAlternate, "左侧 Option"), (61, .maskAlternate, "右侧 Option"),
        (56, .maskShift, "左侧 Shift"), (60, .maskShift, "右侧 Shift"),
        (59, .maskControl, "左侧 Control"), (62, .maskControl, "右侧 Control")
    ]
    private static let modifiers: CGEventFlags = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]
    private static let keyNames: [UInt16: String] = [
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Esc",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑"
    ]

    static func isModifierKeyCode(_ code: UInt16) -> Bool {
        modifierKeys.contains { $0.code == code }
    }

    static func modifierFlag(for code: UInt16) -> CGEventFlags? {
        modifierKeys.first { $0.code == code }?.flag
    }

    static func modifierGlyphs(_ flags: CGEventFlags) -> String {
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        if flags.contains(.maskSecondaryFn) { text += "Fn" }
        return text
    }

    static func keyName(from event: CGEvent, code: UInt16) -> String {
        if let name = keyNames[code] { return name }
        return NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased() ?? "Key \(code)"
    }

    /// Split a stored shortcut into the two parts used by guided recording.
    /// A stored single modifier stays in the modifier slot with no main key.
    static func split(_ value: RecordedShortcut?) -> (modifier: RecordedShortcut?, key: RecordedShortcut?) {
        guard let value else { return (nil, nil) }
        if isModifierKeyCode(value.keyCode) {
            return (value, nil)
        }
        let flags = CGEventFlags(rawValue: value.modifiers)
        let modifier: RecordedShortcut? = flags.isEmpty ? nil : RecordedShortcut(
            keyCode: 0, modifiers: value.modifiers, label: modifierGlyphs(flags))
        var label = value.label
        for prefix in ["⌃", "⌥", "⇧", "⌘", "Fn + "] {
            if label.hasPrefix(prefix) { label.removeFirst(prefix.count) }
        }
        return (modifier, RecordedShortcut(keyCode: value.keyCode, modifiers: 0, label: label))
    }

    /// Assemble the two recorded parts into one shortcut. `recordedShortcut`
    /// always posts modifiers and key together, so this also works for
    /// system-reserved combinations that cannot be captured in one pass.
    static func assembled(modifier: RecordedShortcut?, key: RecordedShortcut?) -> RecordedShortcut? {
        guard let key else { return modifier }
        let flags = CGEventFlags(rawValue: modifier?.modifiers ?? 0)
        return RecordedShortcut(keyCode: key.keyCode, modifiers: flags.rawValue,
                                label: modifierGlyphs(flags) + key.label)
    }

    var onCapture: ((RecordedShortcut) -> Void)?
    private(set) var isRecording = false
    private let mode: Mode
    private var pendingModifier: RecordedShortcut?
    private var pendingShortcut: RecordedShortcut?
    private var heldKeys: Set<UInt16> = []
    private var heldModifiers: Set<UInt16> = []
    private var accumulatedModifiers: CGEventFlags = []
    private var functionHeld = false

    init(mode: Mode = .full) { self.mode = mode }

    func start() {
        stop()
        isRecording = true
    }

    func stop() {
        isRecording = false
        pendingModifier = nil
        pendingShortcut = nil
        heldKeys.removeAll()
        heldModifiers.removeAll()
        accumulatedModifiers = []
        functionHeld = false
    }

    /// Receives only events delivered to the focused AppKit recording field.
    @discardableResult
    func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        guard isRecording else { return false }
        guard type == .flagsChanged || type == .keyDown || type == .keyUp else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var flags = event.flags.intersection(Self.modifiers)
        switch mode {
        case .full: return handleFull(type: type, event: event, code: code, flags: &flags)
        case .modifiers: return handleModifiers(type: type, event: event, code: code, flags: flags)
        case .key: return handleKey(type: type, event: event, code: code)
        }
    }

    private func isPressed(code: UInt16, key: (code: UInt16, flag: CGEventFlags, label: String),
                           event: CGEvent, flags: CGEventFlags) -> Bool {
        let sideKeys = VoiceShortcutKey.allCases.filter { $0.flags.contains(key.flag) }
        let sideMask = sideKeys.reduce(CGEventFlags()) { $0.union($1.flags.subtracting(Self.modifiers)) }
        let side = sideKeys.first { $0.keyCode == code }?.flags.subtracting(Self.modifiers) ?? []
        return side.isEmpty || event.flags.intersection(sideMask).isEmpty
            ? flags.contains(key.flag) : !event.flags.intersection(side).isEmpty
    }

    private func capture(_ shortcut: RecordedShortcut) {
        stop()
        onCapture?(shortcut)
    }

    // MARK: - Full shortcut (legacy single-pass recording)

    private func handleFull(type: CGEventType, event: CGEvent, code: UInt16,
                            flags: inout CGEventFlags) -> Bool {
        if type == .flagsChanged, code == VirtualKey.function {
            functionHeld = flags.contains(.maskSecondaryFn)
        }
        // AppKit also marks F/navigation keys as "function" keys. That flag
        // alone does not imply a physical Fn press requiring a later release.
        if type != .flagsChanged, !functionHeld,
           let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.unicodeScalars.first,
           (0xF700...0xF8FF).contains(character.value) {
            flags.remove(.maskSecondaryFn)
        }
        switch type {
        case .flagsChanged:
            if pendingShortcut == nil, let key = Self.modifierKeys.first(where: { $0.code == code }) {
                let pressed = isPressed(code: code, key: key, event: event, flags: flags)
                if pressed { heldModifiers.insert(code) } else { heldModifiers.remove(code) }
                if pressed {
                    pendingModifier = heldModifiers.count == 1 && flags.rawValue.nonzeroBitCount == 1
                        ? RecordedShortcut(keyCode: code, modifiers: key.flag.rawValue, label: key.label) : nil
                } else if flags.isEmpty, pendingModifier?.keyCode == code {
                    pendingShortcut = pendingModifier
                    pendingModifier = nil
                }
            }
        case .keyDown:
            heldKeys.insert(code)
            pendingModifier = nil
            if pendingShortcut == nil, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                var label = ""
                if flags.contains(.maskControl) { label += "⌃" }
                if flags.contains(.maskAlternate) { label += "⌥" }
                if flags.contains(.maskShift) { label += "⇧" }
                if flags.contains(.maskCommand) { label += "⌘" }
                if flags.contains(.maskSecondaryFn) { label += "Fn + " }
                label += Self.keyName(from: event, code: code)
                pendingShortcut = RecordedShortcut(keyCode: code, modifiers: flags.rawValue, label: label)
            }
        case .keyUp:
            heldKeys.remove(code)
        default: break
        }
        // Consume both edges, including releases of modifiers in a combination.
        if let shortcut = pendingShortcut, heldKeys.isEmpty, flags.isEmpty {
            capture(shortcut)
        }
        return true
    }

    // MARK: - Split recording

    private func handleModifiers(type: CGEventType, event: CGEvent, code: UInt16, flags: CGEventFlags) -> Bool {
        guard type == .flagsChanged else { return true }
        if let key = Self.modifierKeys.first(where: { $0.code == code }) {
            if isPressed(code: code, key: key, event: event, flags: flags) {
                heldModifiers.insert(code)
                accumulatedModifiers.formUnion(key.flag)
            } else {
                heldModifiers.remove(code)
            }
        }
        if flags.isEmpty, heldModifiers.isEmpty, !accumulatedModifiers.isEmpty {
            capture(RecordedShortcut(keyCode: 0, modifiers: accumulatedModifiers.rawValue,
                                     label: Self.modifierGlyphs(accumulatedModifiers)))
        }
        return true
    }

    private func handleKey(type: CGEventType, event: CGEvent, code: UInt16) -> Bool {
        switch type {
        case .flagsChanged:
            return true
        case .keyDown:
            guard !Self.isModifierKeyCode(code),
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
            heldKeys.insert(code)
            if pendingShortcut == nil {
                pendingShortcut = RecordedShortcut(keyCode: code, modifiers: 0,
                                                   label: Self.keyName(from: event, code: code))
            }
        case .keyUp:
            heldKeys.remove(code)
        default: break
        }
        if let shortcut = pendingShortcut, heldKeys.isEmpty {
            capture(shortcut)
        }
        return true
    }
}

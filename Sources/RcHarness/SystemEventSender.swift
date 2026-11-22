import AppKit
import CoreGraphics
import Foundation

/// macOS virtual key codes (HIToolbox kVK_*) used by the built-in actions.
enum VirtualKey {
    static let returnKey: CGKeyCode = 0x24
    static let tab: CGKeyCode = 0x30
    static let delete: CGKeyCode = 0x33
    static let escape: CGKeyCode = 0x35
    static let upArrow: CGKeyCode = 0x7E
    static let downArrow: CGKeyCode = 0x7D
    static let leftArrow: CGKeyCode = 0x7B
    static let rightArrow: CGKeyCode = 0x7C
    static let rightCommand: CGKeyCode = 0x36
    static let command: CGKeyCode = 0x37
    static let function: CGKeyCode = 0x3F
    static let option: CGKeyCode = 0x3A
    static let rightOption: CGKeyCode = 0x3D
    static let c: CGKeyCode = 0x08
    static let v: CGKeyCode = 0x09
    static let leftBracket: CGKeyCode = 0x21
    static let rightBracket: CGKeyCode = 0x1E
}

/// NX_KEYTYPE_* codes for system-defined media key events.
private enum MediaKey {
    static let soundUp = 0
    static let soundDown = 1
    static let mute = 7
    static let play = 16
    static let next = 17
    static let previous = 18
}

/// Device-dependent flags from IOLLEvent.h. Shortcut listeners may use these
/// bits to distinguish both the side and the down/up edge of a modifier.
private enum ModifierDeviceFlag {
    static let leftCommand = CGEventFlags(rawValue: 0x08) // NX_DEVICELCMDKEYMASK
    static let rightCommand = CGEventFlags(rawValue: 0x10) // NX_DEVICERCMDKEYMASK
    static let leftOption = CGEventFlags(rawValue: 0x20) // NX_DEVICELALTKEYMASK
    static let rightOption = CGEventFlags(rawValue: 0x40) // NX_DEVICERALTKEYMASK
}

/// Every synthesized event goes through `postEvent`, so tests can observe all
/// output without posting into the real session.
final class SystemEventSender {
    private static let modifierKeyCodes: Set<CGKeyCode> = [
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    ]
    private struct HeldKey: Hashable {
        let keyCode: CGKeyCode
        let flags: UInt64
        let usesFunctionSource: Bool
    }

    // Posting at cghidEventTap does not change a nil source's state table.
    // Keep Fn in the HID table, as on the physical Fn/Globe keyboard path.
    private let functionKeySource = CGEventSource(stateID: .hidSystemState)
    private let cursorLocation: () -> CGPoint
    private let postEvent: (CGEvent) -> Void
    private let movePointer: (CGPoint) -> Void
    private let openApplication: (URL) -> Void
    private let desktopController: any DesktopController
    private var heldKeys: [HeldKey: Int] = [:]
    private var keyUsesFunctionSource: [CGKeyCode: Bool] = [:]
    private var heldMouseButtons: [UInt32: Int] = [:]
    private var heldMediaKeys: [Int: Int] = [:]
    private let monotonicTime: () -> CFTimeInterval

    /// Consecutive pointer steps ramp up linearly while a direction is held.
    private struct PointerRepeat {
        var action: RemoteAction
        var startedAt: CFTimeInterval
        var lastStepAt: CFTimeInterval
    }
    private var pointerRepeat: PointerRepeat?
    static let pointerBaseStep: CGFloat = 10
    static let pointerMaxStep: CGFloat = 80
    static let pointerAccelerationPerSecond: CGFloat = 20
    /// Hold longer than this before the step size starts growing, so a quick
    /// tap is always exactly one base step.
    static let pointerHoldDelay: CFTimeInterval = 0.18
    /// A gap above this ends the run (a new press restarts the ramp).
    static let pointerRepeatGap: CFTimeInterval = 0.08

    private var heldModifiers: CGEventFlags {
        heldKeys.keys.reduce(CGEventFlags()) { $0.union(CGEventFlags(rawValue: $1.flags)) }
    }

    init(
        cursorLocation: @escaping () -> CGPoint = {
            // NSEvent.mouseLocation is Cocoa global (origin bottom-left, y up);
            // CGEvent uses the primary screen's top-left origin, y down.
            let cocoa = NSEvent.mouseLocation
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
        },
        postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        movePointer: ((CGPoint) -> Void)? = nil,
        openApplication: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        desktopController: any DesktopController = SystemDesktopController.shared,
        monotonicTime: @escaping () -> CFTimeInterval = CFAbsoluteTimeGetCurrent
    ) {
        self.cursorLocation = cursorLocation
        self.postEvent = postEvent
        self.movePointer = movePointer ?? { point in
            // CGWarpMouseCursorPosition moves the cursor but emits no mouse
            // event, so apps never update hover state. A real mouseMoved event
            // keeps hover, tooltips and cursor feedback in sync. Going through
            // postEvent also keeps all synthesized output observable in tests.
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            postEvent(event)
        }
        self.openApplication = openApplication
        self.desktopController = desktopController
        self.monotonicTime = monotonicTime
    }

    func send(_ mapping: ButtonMapping, pressed: Bool) {
        switch mapping.action {
        case .enter: heldKey(VirtualKey.returnKey, flags: [], pressed: pressed)
        case .backspace, .rapidDelete: heldKey(VirtualKey.delete, flags: [], pressed: pressed)
        case .escape: heldKey(VirtualKey.escape, flags: [], pressed: pressed)
        case .arrowUp: heldKey(VirtualKey.upArrow, flags: [], pressed: pressed)
        case .arrowDown: heldKey(VirtualKey.downArrow, flags: [], pressed: pressed)
        case .arrowLeft: heldKey(VirtualKey.leftArrow, flags: [], pressed: pressed)
        case .arrowRight: heldKey(VirtualKey.rightArrow, flags: [], pressed: pressed)
        case .rightCommand: heldKey(VirtualKey.rightCommand, flags: [.maskCommand, ModifierDeviceFlag.rightCommand], pressed: pressed)
        case .leftCommand: heldKey(VirtualKey.command, flags: [.maskCommand, ModifierDeviceFlag.leftCommand], pressed: pressed)
        case .fn:
            guard let functionKeySource else {
                Log.hid.error("Cannot create HID event source for Fn")
                return
            }
            heldKey(VirtualKey.function, flags: .maskSecondaryFn, pressed: pressed, source: functionKeySource)
        case .leftOption: heldKey(VirtualKey.option, flags: [.maskAlternate, ModifierDeviceFlag.leftOption], pressed: pressed)
        case .rightOption: heldKey(VirtualKey.rightOption, flags: [.maskAlternate, ModifierDeviceFlag.rightOption], pressed: pressed)
        case .copy: heldKey(VirtualKey.c, flags: .maskCommand, pressed: pressed)
        case .paste: heldKey(VirtualKey.v, flags: .maskCommand, pressed: pressed)
        case .browserBack: heldKey(VirtualKey.leftBracket, flags: .maskCommand, pressed: pressed)
        case .browserForward: heldKey(VirtualKey.rightBracket, flags: .maskCommand, pressed: pressed)
        case .showAllWindows:
            guard pressed else { return }
            shortcutEvent(RecordedShortcut(keyCode: VirtualKey.upArrow,
                modifiers: CGEventFlags.maskControl.rawValue, label: "Control + ↑"))
        case .showDesktop:
            guard pressed, desktopController.isSupported else { return }
            desktopController.toggle()
        case .mouseLeft: mouse(.left, pressed: pressed)
        case .mouseRight: mouse(.right, pressed: pressed)
        case .pointerUp: movePointerStep(mapping.action, dx: 0, dy: -1, pressed: pressed)
        case .pointerDown: movePointerStep(mapping.action, dx: 0, dy: 1, pressed: pressed)
        case .pointerLeft: movePointerStep(mapping.action, dx: -1, dy: 0, pressed: pressed)
        case .pointerRight: movePointerStep(mapping.action, dx: 1, dy: 0, pressed: pressed)
        case .scrollUp: scroll(4, pressed: pressed)
        case .scrollDown: scroll(-4, pressed: pressed)
        case .recordedShortcut:
            if pressed, let shortcut = mapping.shortcut { shortcutEvent(shortcut) }
        case .openApplication:
            if pressed, let path = mapping.applicationPath { openApplication(URL(fileURLWithPath: path)) }
        case .volumeUp: mediaKey(MediaKey.soundUp, pressed: pressed)
        case .volumeDown: mediaKey(MediaKey.soundDown, pressed: pressed)
        case .mute: mediaKey(MediaKey.mute, pressed: pressed)
        case .playPause: mediaKey(MediaKey.play, pressed: pressed)
        case .previousTrack: mediaKey(MediaKey.previous, pressed: pressed)
        case .nextTrack: mediaKey(MediaKey.next, pressed: pressed)
        case .phrase, .macro, .switchToNativeMode, .switchToMouseMode, .openHarnessSwitcher, .openPhrases, .openVirtualPad, .switchApplications,
             .focusApplication, .focusChatGPT, .focusClaude, .focusCursor, .focusDeepSeek, .focusWorkBuddy, .focusOpenCode, .showShortcutHelp, .disabled: break
        }
    }

    func typeText(_ text: String) {
        var chunks: [[UInt16]] = [[]]
        // Never split a UTF-16 surrogate pair across two Unicode events.
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunks[chunks.count - 1].count + units.count > 20 { chunks.append([]) }
            chunks[chunks.count - 1].append(contentsOf: units)
        }
        for chunk in chunks where !chunk.isEmpty {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                postEvent(event)
            }
        }
    }

    private func mediaKey(_ code: Int, pressed: Bool) {
        let count = heldMediaKeys[code, default: 0]
        if pressed {
            heldMediaKeys[code] = count + 1
            guard count == 0 else { return }
        } else {
            guard count > 0 else { return }
            if count == 1 { heldMediaKeys.removeValue(forKey: code) }
            else { heldMediaKeys[code] = count - 1; return }
        }
        let flags = pressed ? 0xA00 : 0xB00
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | flags, data2: -1)
        if let event = event?.cgEvent { postEvent(event) }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = [], pressed: Bool, source: CGEventSource? = nil) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed)
        var eventFlags = flags.union(heldModifiers)
        switch code {
        case VirtualKey.upArrow, VirtualKey.downArrow, VirtualKey.leftArrow, VirtualKey.rightArrow:
            // Native arrow events carry both flags even when Fn is not held.
            // Mission Control and Spaces require them for shortcut matching.
            // Apply them only to this event so they cannot become held modifiers.
            eventFlags.formUnion([.maskSecondaryFn, .maskNumericPad])
        default: break
        }
        event?.flags = eventFlags
        if let event { postEvent(event) }
    }

    private func mouse(_ button: CGMouseButton, pressed: Bool) {
        let count = heldMouseButtons[button.rawValue, default: 0]
        if pressed {
            heldMouseButtons[button.rawValue] = count + 1
            guard count == 0 else { return }
        } else {
            guard count > 0 else { return }
            if count == 1 { heldMouseButtons.removeValue(forKey: button.rawValue) }
            else { heldMouseButtons[button.rawValue] = count - 1; return }
        }
        let type: CGEventType
        switch (button, pressed) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        default: return
        }
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursorLocation(), mouseButton: button) {
            event.flags = heldModifiers
            postEvent(event)
        }
    }

    /// Repeated steps in the same direction grow linearly from the base step
    /// until the cap. Releasing or changing direction starts a fresh ramp.
    private func movePointerStep(_ action: RemoteAction, dx: CGFloat, dy: CGFloat, pressed: Bool) {
        guard pressed else { return }
        let now = monotonicTime()
        let step: CGFloat
        if let active = pointerRepeat, active.action == action,
           now >= active.lastStepAt, now - active.lastStepAt <= Self.pointerRepeatGap {
            let held = max(0, now - active.startedAt - Self.pointerHoldDelay)
            step = min(Self.pointerMaxStep,
                       Self.pointerBaseStep + CGFloat(held) * Self.pointerAccelerationPerSecond)
            pointerRepeat = PointerRepeat(action: action, startedAt: active.startedAt, lastStepAt: now)
        } else {
            step = Self.pointerBaseStep
            pointerRepeat = PointerRepeat(action: action, startedAt: now, lastStepAt: now)
        }
        move(dx * step, dy * step, pressed: true)
    }

    private func move(_ x: CGFloat, _ y: CGFloat, pressed: Bool) {
        guard pressed else { return }
        let current = cursorLocation()
        movePointer(CGPoint(x: current.x + x, y: current.y + y))
    }

    private func scroll(_ value: Int32, pressed: Bool) {
        guard pressed, let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: value, wheel2: 0, wheel3: 0) else { return }
        postEvent(event)
    }

    private func shortcutEvent(_ shortcut: RecordedShortcut) {
        if let usesFunctionSource = keyUsesFunctionSource[shortcut.keyCode],
           !Self.modifierKeyCodes.contains(shortcut.keyCode) {
            // A one-shot action still needs a down when its key is already
            // held. Do not send an up or acquire persistent modifiers: the
            // existing owners retain the key and its original event source.
            key(shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers), pressed: true,
                source: usesFunctionSource ? functionKeySource : nil)
            return
        }
        sendShortcut(shortcut, pressed: true)
        sendShortcut(shortcut, pressed: false)
    }

    /// Voice holds need independent key edges; ordinary recorded macros still
    /// tap by calling both edges together above.
    func sendShortcut(_ shortcut: RecordedShortcut, pressed: Bool) {
        if let codes = shortcut.modifierKeyCodes {
            guard let choice = VoiceShortcutChoice.matching(shortcut, mode: .tap) else { return }
            let usesFunction = codes.contains(VirtualKey.function)
            if usesFunction && functionKeySource == nil { return }
            var flags = CGEventFlags()
            let keys = choice.keys.map { key -> (VoiceShortcutKey, CGEventFlags) in
                flags.formUnion(key.flags)
                return (key, flags)
            }
            for (key, flags) in pressed ? keys : Array(keys.reversed()) {
                heldKey(key.keyCode, flags: flags, pressed: pressed, source: usesFunction ? functionKeySource : nil)
            }
            return
        }
        let isFunction = shortcut.keyCode == VirtualKey.function
        let usesFunction = isFunction || CGEventFlags(rawValue: shortcut.modifiers).contains(.maskSecondaryFn)
        if usesFunction {
            guard let functionKeySource else { return }
            let downFlags = isFunction ? CGEventFlags(rawValue: shortcut.modifiers).union(.maskSecondaryFn) : CGEventFlags(rawValue: shortcut.modifiers)
            heldKey(shortcut.keyCode, flags: downFlags, pressed: pressed, source: functionKeySource)
        } else {
            heldKey(shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers), pressed: pressed)
        }
    }

    private func heldKey(_ code: CGKeyCode, flags: CGEventFlags, pressed: Bool,
                         source: CGEventSource? = nil) {
        let identity = HeldKey(keyCode: code, flags: flags.rawValue, usesFunctionSource: source != nil)
        if pressed {
            let count = heldKeys[identity, default: 0]
            let wasHeld = heldKeys.keys.contains { $0.keyCode == code }
            heldKeys[identity] = count + 1
            if wasHeld {
                // Sharing a modifier or the exact same held mapping must not
                // retrigger it. A different nonmodifier chord has its own down,
                // while all owners still share the final up.
                if count == 0, !Self.modifierKeyCodes.contains(code) {
                    key(code, flags: flags, pressed: true,
                        source: keyUsesFunctionSource[code] == true ? functionKeySource : nil)
                }
                return
            }
            keyUsesFunctionSource[code] = source != nil
            key(code, flags: flags, pressed: true, source: source)
        } else {
            guard let count = heldKeys[identity], count > 0 else { return }
            if count == 1 { heldKeys.removeValue(forKey: identity) }
            else { heldKeys[identity] = count - 1; return }
            guard !heldKeys.keys.contains(where: { $0.keyCode == code }) else { return }
            let usesFunctionSource = keyUsesFunctionSource.removeValue(forKey: code) ?? false
            key(code, flags: [], pressed: false, source: usesFunctionSource ? functionKeySource : nil)
        }
    }
}

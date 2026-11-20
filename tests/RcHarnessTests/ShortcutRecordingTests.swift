import AppKit
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class ShortcutRecordingTests: XCTestCase {
    @discardableResult
    private func send(_ session: ShortcutRecordingSession, _ type: CGEventType, code: UInt16 = 63,
                      flags: CGEventFlags = [], repeatKey: Bool = false) throws -> Bool {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown))
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return session.handle(type, event: event)
    }

    func testSingleModifiersCaptureOnReleaseWithoutStartingGlobalProtection() throws {
        for key in VoiceShortcutKey.allCases {
            let session = ShortcutRecordingSession()
            var captured: [RecordedShortcut] = []
            session.onCapture = { captured.append($0) }
            session.start()
            XCTAssertTrue(try send(session, .flagsChanged, code: key.keyCode, flags: key.flags))
            XCTAssertTrue(captured.isEmpty)
            try send(session, .flagsChanged, code: key.keyCode)
            XCTAssertEqual(captured.first?.keyCode, key.keyCode)
            XCTAssertEqual(captured.count, 1)
            XCTAssertFalse(session.isRecording)
            XCTAssertFalse(try send(session, .flagsChanged, code: key.keyCode))
        }
    }

    func testOrdinaryCommandShortcutWaitsForAllReleasesAndIgnoresRepeat() throws {
        let session = ShortcutRecordingSession()
        var captured: [RecordedShortcut] = []
        session.onCapture = { captured.append($0) }
        session.start()
        try send(session, .flagsChanged, code: 55, flags: .maskCommand)
        try send(session, .keyDown, code: 40, flags: .maskCommand)
        try send(session, .keyDown, code: 40, flags: .maskCommand, repeatKey: true)
        try send(session, .keyUp, code: 40, flags: .maskCommand)
        XCTAssertTrue(captured.isEmpty)
        try send(session, .flagsChanged, code: 55)
        XCTAssertEqual(captured, [.init(keyCode: 40, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘K")])
    }

    func testOrdinaryFnSpaceCanStillBeRecorded() throws {
        let session = ShortcutRecordingSession()
        var captured: RecordedShortcut?
        session.onCapture = { captured = $0 }
        session.start()
        try send(session, .flagsChanged, flags: .maskSecondaryFn)
        try send(session, .keyDown, code: 49, flags: .maskSecondaryFn)
        try send(session, .flagsChanged)
        XCTAssertNil(captured)
        try send(session, .keyUp, code: 49)
        XCTAssertEqual(captured, .init(keyCode: 49, modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn + Space"))
    }

    func testTwoSidesOfSameModifierDoNotCaptureAnAccidentalSingle() throws {
        for codes in [(55, 54), (58, 61), (59, 62)] {
            let left = VoiceShortcutKey.allCases.first { $0.keyCode == codes.0 }!
            let right = VoiceShortcutKey.allCases.first { $0.keyCode == codes.1 }!
            let session = ShortcutRecordingSession()
            var captured: [RecordedShortcut] = []
            session.onCapture = { captured.append($0) }
            session.start()
            try send(session, .flagsChanged, code: left.keyCode, flags: left.flags)
            try send(session, .flagsChanged, code: right.keyCode, flags: left.flags.union(right.flags))
            try send(session, .flagsChanged, code: left.keyCode, flags: right.flags)
            try send(session, .flagsChanged, code: right.keyCode)
            XCTAssertTrue(captured.isEmpty)
            session.stop()
        }
    }

    func testFunctionFlagOnNavigationAndFunctionKeysDoesNotWaitForUnpressedFn() throws {
        for code: UInt16 in [123, 122] {
            let session = ShortcutRecordingSession()
            var captured: [RecordedShortcut] = []
            session.onCapture = { captured.append($0) }
            session.start()
            try send(session, .keyDown, code: code, flags: .maskSecondaryFn)
            try send(session, .keyUp, code: code, flags: .maskSecondaryFn)
            XCTAssertEqual(captured.count, 1)
            XCTAssertFalse(session.isRecording)
        }
    }

    func testCancelAndRestartDiscardPartialShortcut() throws {
        let session = ShortcutRecordingSession()
        var captured: [RecordedShortcut] = []
        session.onCapture = { captured.append($0) }
        session.start()
        try send(session, .flagsChanged, flags: .maskSecondaryFn)
        session.stop()
        XCTAssertFalse(try send(session, .flagsChanged))
        session.start()
        try send(session, .flagsChanged, code: 60, flags: .maskShift)
        try send(session, .flagsChanged, code: 60)
        XCTAssertEqual(captured.first?.keyCode, 60)
        XCTAssertEqual(captured.count, 1)
    }

    func testModifierOnlyModeCapturesMultipleModifiersOnFullReleaseAndIgnoresOrdinaryKeys() throws {
        let session = ShortcutRecordingSession(mode: .modifiers)
        var captured: [RecordedShortcut] = []
        session.onCapture = { captured.append($0) }
        session.start()
        try send(session, .flagsChanged, code: 59, flags: .maskControl)
        try send(session, .flagsChanged, code: 60, flags: [.maskControl, .maskShift])
        try send(session, .keyDown, code: 40, flags: [.maskControl, .maskShift])
        try send(session, .keyUp, code: 40, flags: [.maskControl, .maskShift])
        XCTAssertTrue(captured.isEmpty)
        try send(session, .flagsChanged, code: 60, flags: .maskControl)
        try send(session, .flagsChanged, code: 59)
        let expected = CGEventFlags.maskControl.union(.maskShift)
        XCTAssertEqual(captured, [.init(keyCode: 0, modifiers: expected.rawValue, label: "⌃⇧")])
        XCTAssertFalse(session.isRecording)
    }

    func testKeyOnlyModeIgnoresModifiersAndAutorepeatThenCapturesNavigationKey() throws {
        let session = ShortcutRecordingSession(mode: .key)
        var captured: [RecordedShortcut] = []
        session.onCapture = { captured.append($0) }
        session.start()
        try send(session, .flagsChanged, code: 59, flags: .maskControl)
        try send(session, .keyDown, code: 123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
        try send(session, .keyDown, code: 123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad], repeatKey: true)
        try send(session, .keyUp, code: 123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
        XCTAssertEqual(captured, [.init(keyCode: 123, modifiers: 0, label: "←")])
        XCTAssertFalse(session.isRecording)
    }

    func testKeyOnlyModeDoesNotCaptureModifierKeyItself() throws {
        let session = ShortcutRecordingSession(mode: .key)
        var captured: [RecordedShortcut] = []
        session.onCapture = { captured.append($0) }
        session.start()
        try send(session, .flagsChanged, code: 55, flags: .maskCommand)
        try send(session, .flagsChanged, code: 55)
        XCTAssertTrue(captured.isEmpty)
        XCTAssertTrue(session.isRecording)
        session.stop()
    }

    func testSplitAndAssembleRoundTripLegacyShortcut() throws {
        let legacy = RecordedShortcut(keyCode: 40, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘K")
        let parts = ShortcutRecordingSession.split(legacy)
        XCTAssertEqual(parts.modifier?.modifiers, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(parts.key?.keyCode, 40)
        XCTAssertEqual(parts.key?.label, "K")
        XCTAssertEqual(ShortcutRecordingSession.assembled(modifier: parts.modifier, key: parts.key), legacy)
    }

    func testSplitKeepsSingleModifierAndAssemblyNeedsMainKey() throws {
        let single = RecordedShortcut(keyCode: 55, modifiers: CGEventFlags.maskCommand.rawValue, label: "左侧 Command")
        let parts = ShortcutRecordingSession.split(single)
        XCTAssertEqual(parts.modifier, single)
        XCTAssertNil(parts.key)
        XCTAssertEqual(ShortcutRecordingSession.assembled(modifier: parts.modifier, key: nil), single)
        XCTAssertNil(ShortcutRecordingSession.assembled(modifier: nil, key: nil))

        let modifier = RecordedShortcut(keyCode: 0,
                                        modifiers: CGEventFlags.maskControl.rawValue, label: "⌃")
        let key = RecordedShortcut(keyCode: 123, modifiers: 0, label: "←")
        XCTAssertEqual(ShortcutRecordingSession.assembled(modifier: modifier, key: key),
                       RecordedShortcut(keyCode: 123, modifiers: CGEventFlags.maskControl.rawValue, label: "⌃←"))
    }

    func testFieldFocusLossRemovalAndDismantlingStopLocalRecording() throws {
        let session = ShortcutRecordingSession()
        let field = ShortcutCapture.CaptureField(session: session)
        var cancellations = 0
        field.onCancel = { cancellations += 1 }
        session.onCapture = { _ in XCTFail("Focus loss must discard a partial recording") }
        session.start()
        try send(session, .flagsChanged, flags: .maskSecondaryFn)
        XCTAssertTrue(field.resignFirstResponder())
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(session.isRecording)
        session.start()
        ShortcutCapture.dismantleNSView(field, coordinator: ())
        XCTAssertFalse(session.isRecording)
        session.start()
        field.viewDidMoveToWindow()
        XCTAssertFalse(session.isRecording)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        XCTAssertFalse(field.performKeyEquivalent(with: event))
    }
}

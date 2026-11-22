import XCTest
@testable import RcHarness

@MainActor
final class MouseModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.MouseModeTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testMouseSchemeIsSeededOnceWithPointerGestures() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let mouse = try XCTUnwrap(model.mouseProfile)
        XCTAssertEqual(mouse.id, SavedKeyProfile.mouseID)
        XCTAssertEqual(mouse.name, "鼠标模式方案")
        XCTAssertEqual(mouse.mapping[.buttonA, .single].action, .mouseLeft)
        XCTAssertEqual(mouse.mapping[.buttonA, .long].action, .mouseRight)
        XCTAssertEqual(mouse.mapping[.buttonA, .double].action, .disabled)
        XCTAssertEqual(mouse.mapping[.dpadUp, .single].action, .pointerUp)
        XCTAssertTrue(mouse.mapping[.dpadUp, .single].repeatWhileHeld)
        XCTAssertEqual(mouse.mapping[.dpadLeft, .single].action, .pointerLeft)
        XCTAssertEqual(mouse.mapping[.rightShoulder, .single].action, .scrollUp)
        XCTAssertEqual(mouse.mapping[.rightShoulder, .double].action, .volumeUp)
        XCTAssertEqual(mouse.mapping[.leftShoulder, .single].action, .scrollDown)
        XCTAssertEqual(mouse.mapping[.leftShoulder, .double].action, .volumeDown)
        XCTAssertEqual(mouse.mapping[.home].action, model.defaultMapping[.home].action)
        XCTAssertEqual(model.profiles.filter { $0.id == SavedKeyProfile.mouseID }.count, 1)

        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.mouseProfile, mouse)
    }

    func testMouseSchemeEditsStayIndependentFromTheDefaultScheme() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let originalDefault = model.defaultMapping
        model.activateProfile(SavedKeyProfile.mouseID)
        model.update(ButtonMapping(action: .enter), for: .buttonA, trigger: .single)
        XCTAssertEqual(model.mouseProfile?.mapping[.buttonA, .single].action, .enter)
        XCTAssertEqual(model.defaultMapping, originalDefault)
        XCTAssertFalse(model.canDeleteProfile(SavedKeyProfile.mouseID))
        XCTAssertFalse(model.renameProfile(SavedKeyProfile.mouseID, name: "另一个名字"))
    }

    func testApplicationSwitchNeverReplacesTheSchemeWhileMouseModeIsActive() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.saveProfile(name: "工作")
        let selected = try XCTUnwrap(model.selectedProfileID)
        model.operationMode = .mouse
        model.matchApplication(nil, bundleIdentifier: "com.openai.chatgpt")
        XCTAssertEqual(model.selectedProfileID, selected)
        model.operationMode = .mapping
        model.matchApplication(nil, bundleIdentifier: nil)
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
    }

    func testMouseModeResolvesPointerClickScrollAndVolumeGestures() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let mapping = model.effectiveMouseMapping
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        gestures.setTiming(doubleTapWindow: model.doubleTapWindow, longPressDelay: model.longPressDelay)
        gestures.setOperationMode(.mouse)
        var actions: [RemoteAction] = []
        gestures.onOutput = { value, pressed, _ in if pressed { actions.append(value.action) } }

        gestures.handle(.buttonA, pressed: true, mapping: mapping)
        gestures.handle(.buttonA, pressed: false, mapping: mapping)
        XCTAssertEqual(actions, [.mouseLeft])

        gestures.handle(.buttonA, pressed: true, mapping: mapping)
        clock.advance(0.6)
        XCTAssertEqual(actions, [.mouseLeft, .mouseRight])
        gestures.handle(.buttonA, pressed: false, mapping: mapping)

        gestures.handle(.dpadUp, pressed: true, mapping: mapping)
        gestures.handle(.dpadUp, pressed: false, mapping: mapping)
        XCTAssertEqual(actions.last, .pointerUp)

        gestures.handle(.rightShoulder, pressed: true, mapping: mapping)
        gestures.handle(.rightShoulder, pressed: false, mapping: mapping)
        gestures.handle(.rightShoulder, pressed: true, mapping: mapping)
        gestures.handle(.rightShoulder, pressed: false, mapping: mapping)
        XCTAssertEqual(actions.last, .volumeUp)

        gestures.handle(.leftShoulder, pressed: true, mapping: mapping)
        gestures.handle(.leftShoulder, pressed: false, mapping: mapping)
        gestures.handle(.leftShoulder, pressed: true, mapping: mapping)
        gestures.handle(.leftShoulder, pressed: false, mapping: mapping)
        XCTAssertEqual(actions.last, .volumeDown)

        gestures.setOperationMode(.native)
        gestures.handle(.buttonA, pressed: true, mapping: mapping)
        gestures.handle(.buttonA, pressed: false, mapping: mapping)
        XCTAssertEqual(actions.last, .volumeDown)
    }

    func testResetMouseSchemeRestoresPointerGestures() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.activateProfile(SavedKeyProfile.mouseID)
        model.update(ButtonMapping(action: .disabled), for: .buttonA, trigger: .single)
        XCTAssertEqual(model.mouseProfile?.mapping[.buttonA, .single].action, .disabled)
        model.resetMapping()
        XCTAssertEqual(model.mouseProfile?.mapping[.buttonA, .single].action, .mouseLeft)
        XCTAssertEqual(model.mouseProfile?.mapping[.dpadUp, .single].action, .pointerUp)
        XCTAssertEqual(model.mouseProfile?.mapping[.rightShoulder, .double].action, .volumeUp)
    }

    func testPointerStepsAccelerateLinearlyWhileHeld() {
        var now: CFTimeInterval = 100
        var positions: [CGPoint] = []
        let sender = SystemEventSender(cursorLocation: { .zero },
                                       postEvent: { _ in },
                                       movePointer: { positions.append($0) },
                                       monotonicTime: { now })
        let up = ButtonMapping(action: .pointerUp, repeatWhileHeld: true)
        var expectedY: [CGFloat] = []
        for frame in 0..<80 {
            now = 100 + CFTimeInterval(frame) * 0.016
            let held = max(0, now - 100 - SystemEventSender.pointerHoldDelay)
            let step = min(SystemEventSender.pointerMaxStep,
                           SystemEventSender.pointerBaseStep + CGFloat(held) * SystemEventSender.pointerAccelerationPerSecond)
            expectedY.append(-step)
            sender.send(up, pressed: true)
        }
        now += 1
        sender.send(up, pressed: true)
        expectedY.append(-SystemEventSender.pointerBaseStep)
        sender.send(ButtonMapping(action: .pointerLeft), pressed: true)
        expectedY.append(0)
        XCTAssertEqual(positions.count, expectedY.count)
        for (index, step) in zip(positions.map(\.y), expectedY).enumerated() {
            XCTAssertEqual(step.0, step.1, accuracy: 0.001, "step \(index)")
        }
        XCTAssertEqual(positions.last?.x, -SystemEventSender.pointerBaseStep)
    }

    func testPointerMovePostsRealMouseMovedEventForHover() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(cursorLocation: { CGPoint(x: 100, y: 200) },
                                       postEvent: { events.append($0) },
                                       monotonicTime: { 0 })
        sender.send(ButtonMapping(action: .pointerRight), pressed: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .mouseMoved)
        XCTAssertEqual(events.first?.location.x, 110)
        XCTAssertEqual(events.first?.location.y, 200)
    }

    func testPointerRepeatSurvivesBriefRemoteAutoRepeatGap() {
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var actions: [RemoteAction] = []
        gestures.onOutput = { mapping, pressed, _ in if pressed { actions.append(mapping.action) } }
        var fullMapping = RemoteMapping(buttons: [:])
        fullMapping[.dpadUp] = ButtonMapping(action: .pointerUp, repeatWhileHeld: true)
        let mapping = fullMapping
        gestures.handle(.dpadUp, pressed: true, mapping: mapping)
        clock.advance(0.3)
        let beforeRelease = actions.count
        XCTAssertGreaterThan(beforeRelease, 1)
        gestures.handle(.dpadUp, pressed: false, mapping: mapping)
        clock.advance(0.05)
        gestures.handle(.dpadUp, pressed: true, mapping: mapping)
        clock.advance(0.05)
        XCTAssertGreaterThan(actions.count, beforeRelease)
        // One repeat timer only: a 16ms frame must not produce two movements.
        let afterResume = actions.count
        clock.advance(0.016)
        XCTAssertEqual(actions.count - afterResume, 1)
        gestures.handle(.dpadUp, pressed: false, mapping: mapping)
        clock.advance(0.1)
        let afterStop = actions.count
        clock.advance(0.2)
        XCTAssertEqual(actions.count, afterStop)
    }

    func testDoubleTapToggleNeverFallsBackToTheSingleModalAction() {
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var resolved: [ButtonTrigger] = []
        var actions: [RemoteAction] = []
        gestures.onResolved = { _, trigger in resolved.append(trigger) }
        gestures.onOutput = { mapping, pressed, _ in if pressed { actions.append(mapping.action) } }
        var mapping = RemoteMapping(buttons: [:])
        mapping[.power, .single] = ButtonMapping(action: .openHarnessSwitcher)
        mapping[.power, .double] = ButtonMapping(action: .switchToMouseMode)
        mapping[.power, .long] = ButtonMapping(action: .switchToMouseMode)

        for _ in 0..<2 {
            gestures.handle(.power, pressed: true, mapping: mapping)
            gestures.handle(.power, pressed: false, mapping: mapping)
            gestures.handle(.power, pressed: true, mapping: mapping)
            gestures.handle(.power, pressed: false, mapping: mapping)
        }
        XCTAssertEqual(resolved, [.double, .double])
        XCTAssertEqual(actions, [.switchToMouseMode, .switchToMouseMode])
        XCTAssertFalse(actions.contains(.openHarnessSwitcher))
    }

    func testSwitchActionIsDecodableAndForbiddenInsideMacros() throws {
        let action = try XCTUnwrap(RemoteAction(rawValue: "toggleMouseMode"))
        XCTAssertEqual(action, .switchToMouseMode)
        XCTAssertEqual(action.label, "切换到鼠标模式")
        let macro = SavedMacro(name: "测试", steps: [
            MacroStep(mapping: ButtonMapping(action: .switchToMouseMode))
        ])
        XCTAssertThrowsError(try MacroExecutionPlan(macro, macros: []))
    }

    func testMouseModeMenuBarIconIsADistinctPersistentMarker() throws {
        let normal = MenuBarIcon.make()
        let mouse = MenuBarIcon.makeMouseMode()
        XCTAssertEqual(mouse.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(normal.isTemplate)
        XCTAssertFalse(mouse.isTemplate, "Mouse mode must stay visible as a colored marker")
        let normalData = try XCTUnwrap(normal.tiffRepresentation)
        let mouseData = try XCTUnwrap(mouse.tiffRepresentation)
        XCTAssertNotEqual(normalData, mouseData)
    }

    func testMouseModeRingFollowsCursorWithoutStealingClicks() throws {
        let ring = MouseModeRingController()
        ring.show()
        defer { ring.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { window in
            window.isKind(of: NSPanel.self) && window.frame.size.width == 44
        })
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.ignoresMouseEvents, "Ring must not steal clicks from full-screen apps")
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
        let cursor = NSEvent.mouseLocation
        XCTAssertEqual(panel.frame.midX, cursor.x, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, cursor.y, accuracy: 1)
    }
}

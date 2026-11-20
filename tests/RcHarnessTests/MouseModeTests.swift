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
        for step in 0..<10 {
            expectedY.append(-min(SystemEventSender.pointerMaxStep,
                                  SystemEventSender.pointerBaseStep + CGFloat(step) * 0.1 * SystemEventSender.pointerAccelerationPerSecond))
            sender.send(up, pressed: true)
            now += 0.1
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
}

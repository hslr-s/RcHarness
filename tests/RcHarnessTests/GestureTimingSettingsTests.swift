import XCTest
@testable import RcHarness

@MainActor
final class GestureTimingSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.GestureTimingTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsClampAndPersist() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.doubleTapWindow, RemoteGestureController.defaultDoubleTapWindow)
        XCTAssertEqual(model.longPressDelay, RemoteGestureController.defaultLongPressDelay)

        model.doubleTapWindow = 0.15
        model.longPressDelay = 0.8
        XCTAssertEqual(defaults.double(forKey: SettingsKeys.doubleTapWindow), 0.15)
        XCTAssertEqual(defaults.double(forKey: SettingsKeys.longPressDelay), 0.8)

        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.doubleTapWindow, 0.15)
        XCTAssertEqual(restored.longPressDelay, 0.8)
    }

    func testOutOfRangeAndNonFiniteValuesFallBackSafely() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.doubleTapWindow = 9
        XCTAssertEqual(model.doubleTapWindow, RemoteGestureController.doubleTapWindowRange.upperBound)
        model.doubleTapWindow = 0.01
        XCTAssertEqual(model.doubleTapWindow, RemoteGestureController.doubleTapWindowRange.lowerBound)
        model.doubleTapWindow = .nan
        XCTAssertEqual(model.doubleTapWindow, RemoteGestureController.defaultDoubleTapWindow)

        model.longPressDelay = -1
        XCTAssertEqual(model.longPressDelay, RemoteGestureController.longPressDelayRange.lowerBound)
        model.longPressDelay = .infinity
        XCTAssertEqual(model.longPressDelay, RemoteGestureController.defaultLongPressDelay)
    }

    func testChangeCallbackFiresForEachAppliedValue() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var changes = 0
        model.onGestureTimingChange = { changes += 1 }
        model.doubleTapWindow = 0.25
        model.longPressDelay = 0.7
        XCTAssertEqual(changes, 2)
    }

    func testConfiguredDoubleTapWindowDrivesSingleClickTiming() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.doubleTapWindow = 0.3

        var mapping = RemoteMapping(buttons: [:])
        mapping[.dpadUp, .single] = ButtonMapping(action: .arrowUp)
        mapping[.dpadUp, .double] = ButtonMapping(action: .arrowDown)

        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        gestures.setTiming(doubleTapWindow: model.doubleTapWindow, longPressDelay: model.longPressDelay)
        var actions: [RemoteAction] = []
        gestures.onOutput = { value, pressed, _ in if pressed { actions.append(value.action) } }

        gestures.handle(.dpadUp, pressed: true, mapping: mapping)
        gestures.handle(.dpadUp, pressed: false, mapping: mapping)
        clock.advance(0.2)
        XCTAssertTrue(actions.isEmpty)
        clock.advance(0.1)
        XCTAssertEqual(actions, [.arrowUp])
    }

    func testConfiguredLongPressDelayDrivesLongPressTiming() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.longPressDelay = 0.8

        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        gestures.setTiming(doubleTapWindow: model.doubleTapWindow, longPressDelay: model.longPressDelay)
        var actions: [RemoteAction] = []
        gestures.onOutput = { value, pressed, _ in if pressed { actions.append(value.action) } }

        gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
        clock.advance(0.55)
        XCTAssertTrue(actions.isEmpty)
        clock.advance(0.25)
        XCTAssertEqual(actions, [.switchToNativeMode])
        gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
    }

    func testConfiguredDoubleTapWindowDrivesPhrasePicker() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.doubleTapWindow = 0.3

        let clock = TestClock()
        let picker = PhrasePickerModel(schedule: clock.schedule)
        picker.setDoubleTapWindow(model.doubleTapWindow)
        let phrase = SavedPhrase(title: "测试", text: "内容1", englishText: "内容2")
        var assignments = PhraseAssignments()
        assignments[.dpadUp] = phrase.id
        picker.present(phrases: [phrase], assignments: assignments)
        var outputs: [String] = []
        picker.onOutput = { outputs.append($0) }

        picker.handle(.dpadUp, pressed: true)
        picker.handle(.dpadUp, pressed: false)
        clock.advance(0.2)
        XCTAssertTrue(outputs.isEmpty)
        clock.advance(0.1)
        XCTAssertEqual(outputs, ["内容1"])
    }
}

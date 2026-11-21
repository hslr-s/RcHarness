import XCTest
@testable import RcHarness

final class RepeatWhileHeldTests: XCTestCase {
    func testLegacyMappingWithoutRepeatFieldDecodesAsFalse() throws {
        let mapping = try JSONDecoder().decode(ButtonMapping.self, from: Data(#"{"action":"arrowUp"}"#.utf8))
        XCTAssertEqual(mapping.action, .arrowUp)
        XCTAssertFalse(mapping.repeatWhileHeld)
    }

    func testRepeatFlagRoundTrips() throws {
        let mapping = ButtonMapping(action: .scrollDown, repeatWhileHeld: true)
        let decoded = try JSONDecoder().decode(ButtonMapping.self, from: try JSONEncoder().encode(mapping))
        XCTAssertEqual(decoded.action, .scrollDown)
        XCTAssertTrue(decoded.repeatWhileHeld)
    }

    func testSupportedActions() {
        XCTAssertTrue(RemoteAction.arrowUp.supportsRepeatWhileHeld)
        XCTAssertTrue(RemoteAction.pointerLeft.supportsRepeatWhileHeld)
        XCTAssertTrue(RemoteAction.scrollDown.supportsRepeatWhileHeld)
        XCTAssertFalse(RemoteAction.rapidDelete.supportsRepeatWhileHeld)
        XCTAssertFalse(RemoteAction.enter.supportsRepeatWhileHeld)
        XCTAssertFalse(RemoteAction.openHarnessSwitcher.supportsRepeatWhileHeld)
    }

    @MainActor
    func testRepeatWhileHeldFiresAfterDelayAndStopsOnRelease() {
        var mapping = RemoteMapping(buttons: [:])
        mapping[.dpadUp, .single] = ButtonMapping(action: .arrowUp, repeatWhileHeld: true)

        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var edges: [(RemoteAction, Bool)] = []
        gestures.onOutput = { value, pressed, _ in edges.append((value.action, pressed)) }

        gestures.handle(.dpadUp, pressed: true, mapping: mapping)
        XCTAssertEqual(edges.map(\.0), [.arrowUp, .arrowUp])
        XCTAssertEqual(edges.map(\.1), [true, false])

        clock.advance(RemoteGestureController.rapidDeleteDelay - 0.01)
        XCTAssertEqual(edges.count, 2)
        clock.advance(0.01)
        XCTAssertEqual(edges.count, 4)
        clock.advance(RemoteGestureController.rapidDeleteInterval * 2)
        XCTAssertEqual(edges.count, 8)

        gestures.handle(.dpadUp, pressed: false, mapping: mapping)
        clock.advance(1)
        XCTAssertEqual(edges.count, 8)
    }

    @MainActor
    func testRepeatUsesSingleBindingWhenNoLongBinding() {
        var mapping = RemoteMapping(buttons: [:])
        mapping[.dpadUp, .single] = ButtonMapping(action: .arrowUp, repeatWhileHeld: true)
        mapping[.dpadUp, .double] = ButtonMapping(action: .arrowDown)

        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var edges: [(RemoteAction, Bool)] = []
        gestures.onOutput = { value, pressed, _ in edges.append((value.action, pressed)) }

        gestures.handle(.dpadUp, pressed: true, mapping: mapping)
        XCTAssertTrue(edges.isEmpty)
        clock.advance(RemoteGestureController.longPressDelay)
        XCTAssertEqual(edges.map(\.0), [.arrowUp, .arrowUp])
        clock.advance(RemoteGestureController.rapidDeleteInterval)
        XCTAssertEqual(edges.count, 4)
    }

    @MainActor
    func testCancelStopsRepeatWithoutExtraRelease() {
        XCTAssertFalse(RemoteGestureController.repeats(ButtonMapping(action: .enter, repeatWhileHeld: true)))
        XCTAssertTrue(RemoteGestureController.repeats(ButtonMapping(action: .arrowUp, repeatWhileHeld: true)))

        var mapping = RemoteMapping(buttons: [:])
        mapping[.dpadUp, .single] = ButtonMapping(action: .scrollUp, repeatWhileHeld: true)

        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var edges: [(RemoteAction, Bool)] = []
        gestures.onOutput = { value, pressed, _ in edges.append((value.action, pressed)) }

        gestures.handle(.dpadUp, pressed: true, mapping: mapping)
        gestures.cancel()
        clock.advance(1)
        XCTAssertEqual(edges.count, 2)
    }
}

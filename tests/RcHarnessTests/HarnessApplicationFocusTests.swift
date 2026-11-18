import XCTest
@testable import RcHarness

@MainActor
final class HarnessApplicationFocusTests: XCTestCase {
    func testMissingApplicationDoesNothing() {
        var focused = false
        var launched = false
        HarnessApplicationFocus.perform(installedURL: nil, runningProcessID: nil,
                                        focusRunning: { _ in focused = true },
                                        launch: { _, _ in launched = true })
        XCTAssertFalse(focused)
        XCTAssertFalse(launched)
    }

    func testRunningApplicationIsFocusedWithoutLaunching() {
        var focusedProcessID: Int32?
        var launched = false
        HarnessApplicationFocus.perform(installedURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                                        runningProcessID: 42,
                                        focusRunning: { focusedProcessID = $0 },
                                        launch: { _, _ in launched = true })
        XCTAssertEqual(focusedProcessID, 42)
        XCTAssertFalse(launched)
    }

    func testInstalledApplicationIsLaunchedAndThenFocused() {
        let url = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        var launchedURL: URL?
        var focusedProcessID: Int32?
        HarnessApplicationFocus.perform(installedURL: url, runningProcessID: nil,
                                        focusRunning: { focusedProcessID = $0 },
                                        launch: { requestedURL, completion in
            launchedURL = requestedURL
            completion(84)
        })
        XCTAssertEqual(launchedURL, url)
        XCTAssertEqual(focusedProcessID, 84)
    }

    func testComposerFocusWaitsForForegroundAndAnEditor() {
        let clock = TestClock()
        var state = HarnessComposerFocus.AppState.waiting
        var editorReady = false
        var attempts: [Int32] = []
        let focus = HarnessComposerFocus(state: { _ in state }, focusComposer: { processID, target in
            XCTAssertEqual(target, .cursor)
            attempts.append(processID)
            return editorReady
        }, schedule: clock.schedule)

        focus.start(processID: 42, target: .cursor)
        XCTAssertTrue(attempts.isEmpty)
        state = .frontmost
        clock.advance(0.25)
        XCTAssertEqual(attempts, [42])
        editorReady = true
        clock.advance(0.25)
        clock.advance(5)
        XCTAssertEqual(attempts, [42, 42])
    }

    func testComposerFocusStopsAfterSwitchingAway() {
        let clock = TestClock()
        var state = HarnessComposerFocus.AppState.frontmost
        var attempts = 0
        let focus = HarnessComposerFocus(state: { _ in state }, focusComposer: { _, _ in
            attempts += 1
            return false
        }, schedule: clock.schedule)

        focus.start(processID: 42, target: .chatGPT)
        state = .waiting
        clock.advance(0.25)
        state = .frontmost
        clock.advance(5)
        XCTAssertEqual(attempts, 1)
    }

    func testEachFocusActionRoutesToItsBuiltInHarnessAfterDecoding() throws {
        let ids = ["chatgpt", "claude", "cursor", "deepseek", "workbuddy", "opencode"]
        XCTAssertEqual(RemoteAction.harnessFocusActions.count, ids.count)
        for (action, id) in zip(RemoteAction.harnessFocusActions, ids) {
            let saved = try JSONEncoder().encode(ButtonMapping(action: action))
            let mapping = try JSONDecoder().decode(ButtonMapping.self, from: saved)
            let harness = try XCTUnwrap(HarnessConfiguration.defaults.first { $0.id == id })
            XCTAssertEqual(mapping.action.harnessFocusTarget?.rawValue, harness.id)
            XCTAssertEqual(mapping.action.label, "打开聚焦" + harness.name)
        }
    }
}

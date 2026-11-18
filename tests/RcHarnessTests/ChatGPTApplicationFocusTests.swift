import XCTest
@testable import RcHarness

@MainActor
final class ChatGPTApplicationFocusTests: XCTestCase {
    func testMissingApplicationDoesNothing() {
        var focused = false
        var launched = false
        ChatGPTApplicationFocus.perform(installedURL: nil, runningProcessID: nil,
                                        focusRunning: { _ in focused = true },
                                        launch: { _, _ in launched = true })
        XCTAssertFalse(focused)
        XCTAssertFalse(launched)
    }

    func testRunningApplicationIsFocusedWithoutLaunching() {
        var focusedProcessID: Int32?
        var launched = false
        ChatGPTApplicationFocus.perform(installedURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
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
        ChatGPTApplicationFocus.perform(installedURL: url, runningProcessID: nil,
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
        var state = ChatGPTComposerFocus.AppState.waiting
        var editorReady = false
        var attempts: [Int32] = []
        let focus = ChatGPTComposerFocus(state: { _ in state }, focusComposer: {
            attempts.append($0)
            return editorReady
        }, schedule: clock.schedule)

        focus.start(processID: 42)
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
        var state = ChatGPTComposerFocus.AppState.frontmost
        var attempts = 0
        let focus = ChatGPTComposerFocus(state: { _ in state }, focusComposer: { _ in
            attempts += 1
            return false
        }, schedule: clock.schedule)

        focus.start(processID: 42)
        state = .waiting
        clock.advance(0.25)
        state = .frontmost
        clock.advance(5)
        XCTAssertEqual(attempts, 1)
    }
}

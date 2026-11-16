import Foundation
import XCTest

final class TestClockTests: XCTestCase {
    func testCallbackCanCancelItselfAndScheduleAnotherCallback() {
        let clock = TestClock()
        var events: [String] = []
        let cancelled = clock.schedule(after: 0.5) { events.append("cancelled") }
        cancelled.cancel()
        var work: DispatchWorkItem?
        work = clock.schedule(after: 1) {
            work?.cancel()
            events.append("first")
            _ = clock.schedule(after: 0) { events.append("next") }
        }

        clock.advance(1)

        XCTAssertEqual(events, ["first", "next"])
        XCTAssertEqual(clock.time, 1)
        work = nil
    }
}

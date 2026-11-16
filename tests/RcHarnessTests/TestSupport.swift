import AppKit
import Foundation
import XCTest
@testable import RcHarness

/// Wait for playback completions already submitted to the main queue, without
/// advancing timers or relying on the machine's scheduling speed.
@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// Deterministic scheduler for controllers that take a
/// `RemoteVoiceSessionController.Scheduler`; time only moves via `advance`.
final class TestClock {
    private var now: TimeInterval = 0
    var time: TimeInterval { now }
    private var tasks: [(TimeInterval, DispatchWorkItem)] = []

    func schedule(after delay: TimeInterval, operation: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: operation)
        tasks.append((now + delay, work))
        return work
    }

    func advance(_ duration: TimeInterval) {
        let end = now + duration
        while let task = tasks.filter({ $0.0 <= end + 0.000001 }).min(by: { $0.0 < $1.0 }) {
            tasks.removeAll { $0.1 === task.1 }
            now = task.0
            if !task.1.isCancelled { task.1.perform() }
        }
        now = end
    }
}

/// Click only inside the test window; native button cells use their action
/// path because older AppKit waits synchronously for mouseUp during mouseDown.
@MainActor
func clickInTestWindow(_ point: NSPoint, in view: NSView) throws {
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    let targetWindow = try XCTUnwrap(view.window)
    let content = try XCTUnwrap(targetWindow.contentView)
    let location = view.convert(point, to: nil)
    _ = try XCTUnwrap(content.visibleRect.contains(content.convert(location, from: nil)) ? location : nil,
                      "Click \(location) must remain inside the test window content \(content.frame)")
    let hitView = content.hitTest(view.convert(point, to: content.superview))
    var hit = hitView
    while let current = hit {
        // Native controls own a synchronous mouse tracking loop on
        // older AppKit. Use their normal action path without waiting
        // for events from the real desktop session.
        if let control = current as? NSControl, control.cell is NSButtonCell {
            control.performClick(nil)
            return
        }
        hit = current.superview
    }
    // Only fall back to native bounds when the hosting root owns the hit.
    // Custom pointer views must keep priority over buttons underneath them.
    if hitView === content,
       let control = descendants(content).compactMap({ $0 as? NSControl }).filter({
        $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty
            && $0.convert($0.bounds, to: nil).contains(location)
    }).min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
        control.performClick(nil)
        return
    }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: targetWindow.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
    }
}

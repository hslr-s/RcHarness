import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class MacrosLayoutTests: XCTestCase {
    func testNewMacroScrollsIntoViewAndOpensItsEditor() async throws {
        let suite = "RcHarness.MacrosCreationLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let host = NSHostingView(rootView: MacrosPage(model: model, actionFilter: .constant(.all)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        await flushUI()
        let count = model.macros.count
        // The trailing header button in the fixed-width library pane.
        let point = NSPoint(x: 260, y: host.isFlipped ? 28 : host.bounds.height - 28)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        await flushUI()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.macros.count, count + 1)
        let created = try XCTUnwrap(model.macros.last)
        let nameField = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "组合动作名称"
        })
        XCTAssertEqual(nameField.stringValue, created.name)
        let list = try XCTUnwrap(scrollViews(in: host).min {
            $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
        })
        XCTAssertGreaterThan(list.contentView.bounds.minY, 0,
                             "Creating a macro must scroll past the offscreen preset rows")
        let document = try XCTUnwrap(list.documentView)
        XCTAssertEqual(list.contentView.bounds.maxY, document.bounds.maxY, accuracy: 2,
                       "The new last row must be visible after lazy layout settles")
    }

    func testMacroPageNavigationBenchmark() throws {
        guard let output = ProcessInfo.processInfo.environment["RC_HARNESS_MACROS_BENCHMARK"] else {
            throw XCTSkip("Set RC_HARNESS_MACROS_BENCHMARK to record page navigation timings")
        }
        let suite = "RcHarness.MacrosNavigation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let environment = ProcessInfo.processInfo.environment
        let stepCount = Int(environment["RC_HARNESS_MACROS_BENCHMARK_STEPS"] ?? "1") ?? 1
        guard (0...100).contains(stepCount) else { throw XCTSkip("Benchmark step count must be between 0 and 100") }
        if let macro = model.macros.first, stepCount != macro.steps.count {
            model.updateMacroSteps((0..<stepCount).map { _ in
                MacroStep(mapping: macro.steps.first?.mapping ?? ButtonMapping(action: .enter))
            }, for: macro.id)
            model.flushPendingWrites()
        }
        model.page = .about
        let host = NSHostingView(rootView: RemoteDashboardView(model: model))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsStyle.minimumWindowSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        var milliseconds: [Double] = []
        for _ in 0..<5 {
            model.page = .about
            host.layoutSubtreeIfNeeded()
            let start = ContinuousClock.now
            model.page = .macros
            host.layoutSubtreeIfNeeded()
            let elapsed = start.duration(to: .now).components
            milliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        let median = milliseconds.sorted()[milliseconds.count / 2]
        let data = try JSONSerialization.data(withJSONObject: ["macroCount": model.macros.count, "steps": stepCount, "medianMS": median,
                                                               "milliseconds": milliseconds], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        let budget = Double(environment["RC_HARNESS_MACROS_BENCHMARK_MAX_MS"] ?? "100") ?? 100
        XCTAssertLessThan(median, budget, "Switching to the macro library exceeded the explicit benchmark budget")
    }

    func testLongMacroListScrollsWithoutMovingTheEditor() throws {
        let suite = "RcHarness.MacrosLayoutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let macro = try XCTUnwrap(model.macros.first)
        model.updateMacroSteps((0..<12).map { _ in MacroStep() }, for: macro.id)
        model.page = .macros
        let hostingView = NSHostingView(rootView: RemoteDashboardView(model: model))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsStyle.minimumWindowSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()

        let panes = scrollViews(in: hostingView).filter {
            $0.convert($0.bounds, to: hostingView).minX > SettingsStyle.sidebarWidth
        }.sorted { $0.convert($0.bounds, to: hostingView).minX < $1.convert($1.bounds, to: hostingView).minX }
        XCTAssertEqual(panes.count, 2, "The macro list and editor must have independent scroll areas")
        guard panes.count == 2 else { return }
        let list = panes[0]
        let editor = panes[1]
        let document = try XCTUnwrap(list.documentView)
        XCTAssertGreaterThan(document.bounds.height, list.contentView.bounds.height)
        let editorFrame = editor.convert(editor.bounds, to: hostingView)
        XCTAssertLessThanOrEqual(editorFrame.maxY, hostingView.bounds.maxY)
        XCTAssertGreaterThanOrEqual(editorFrame.minY, hostingView.bounds.minY)

        list.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - list.contentView.bounds.height))
        list.reflectScrolledClipView(list.contentView)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(list.contentView.bounds.minY, 0)
        XCTAssertEqual(editor.convert(editor.bounds, to: hostingView), editorFrame,
                       "Scrolling to the last macro must keep the editor visible")

        let editorDocument = try XCTUnwrap(editor.documentView)
        XCTAssertGreaterThan(editorDocument.bounds.height, editor.contentView.bounds.height)
        let listPosition = list.contentView.bounds.origin
        editor.contentView.scroll(to: CGPoint(x: 0, y: editorDocument.bounds.height - editor.contentView.bounds.height))
        editor.reflectScrolledClipView(editor.contentView)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.contentView.bounds.minY, 0)
        XCTAssertEqual(list.contentView.bounds.origin, listPosition,
                       "Scrolling a long action must not move the macro list")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func flushUI() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

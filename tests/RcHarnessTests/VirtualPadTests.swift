import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

final class VirtualPadTests: XCTestCase {
    @MainActor
    func testDefaultSchemeCoversAllFiveKeys() {
        XCTAssertEqual(VirtualKeyScheme.defaults.count, 1)
        let scheme = VirtualKeyScheme.defaults[0]
        XCTAssertEqual(VirtualKeyScheme.inputs.count, 5)
        for input in VirtualKeyScheme.inputs {
            XCTAssertTrue(ButtonTrigger.allCases.contains { scheme[input, $0].action != .disabled },
                          "\(input.label) should have at least one default action")
        }
    }

    @MainActor
    func testDefaultSchemeUsesMediaBindings() {
        let scheme = VirtualKeyScheme.defaults[0]
        XCTAssertEqual(scheme[.dpadUp, .single].action, .volumeUp)
        XCTAssertEqual(scheme[.dpadDown, .single].action, .volumeDown)
        XCTAssertEqual(scheme[.dpadLeft, .single].action, .previousTrack)
        XCTAssertEqual(scheme[.dpadRight, .single].action, .nextTrack)
        XCTAssertEqual(scheme[.buttonA, .single].action, .playPause)
    }

    @MainActor
    func testExistingDefaultSchemeUpgradesToMediaBindings() throws {
        let suite = "VirtualPadMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var oldScheme = VirtualKeyScheme.defaults[0]
        oldScheme[.dpadLeft, .single] = ButtonMapping(action: .playPause)
        oldScheme[.dpadRight, .single] = ButtonMapping(action: .browserBack)
        oldScheme[.buttonA, .single] = ButtonMapping(action: .enter)
        SettingsStorage.save([oldScheme], SettingsKeys.Stored.virtualKeySchemes, defaults: defaults)
        defaults.set(true, forKey: SettingsKeys.virtualKeySchemesInitialized)

        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.virtualKeySchemes.first?[.dpadLeft, .single].action, .previousTrack)
        XCTAssertEqual(model.virtualKeySchemes.first?[.dpadRight, .single].action, .nextTrack)
        XCTAssertEqual(model.virtualKeySchemes.first?[.buttonA, .single].action, .playPause)
        XCTAssertEqual(defaults.integer(forKey: SettingsKeys.virtualKeySchemesVersion), 2)
    }

    @MainActor
    func testPreviousAndNextTrackPostSystemMediaKeys() {
        for (action, keyCode) in [(RemoteAction.previousTrack, 18), (.nextTrack, 17)] {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.send(ButtonMapping(action: action), pressed: true)
            sender.send(ButtonMapping(action: action), pressed: false)
            XCTAssertEqual(events.count, 2, action.label)
            let codes = events.compactMap { NSEvent(cgEvent: $0) }.map { $0.data1 >> 16 }
            XCTAssertEqual(codes, [keyCode, keyCode], action.label)
        }
    }

    @MainActor
    func testSchemeRoundTripsJSONIncludingCloseOption() throws {
        var scheme = VirtualKeyScheme(name: "自定义", closeAfterAction: false)
        scheme[.dpadUp, .long] = ButtonMapping(action: .enter)
        let decoded = try JSONDecoder().decode(VirtualKeyScheme.self, from: JSONEncoder().encode(scheme))
        XCTAssertEqual(decoded, scheme)
        XCTAssertFalse(decoded.closeAfterAction)
        XCTAssertEqual(decoded[.dpadUp, .long].action, .enter)
    }

    @MainActor
    func testSingleDoubleAndLongResolveDifferentActions() {
        let clock = TestClock()
        let model = VirtualPadPickerModel(schedule: clock.schedule)
        var scheme = VirtualKeyScheme(name: "手势", closeAfterAction: false)
        scheme[.dpadUp, .single] = ButtonMapping(action: .volumeUp)
        scheme[.dpadUp, .double] = ButtonMapping(action: .volumeDown)
        scheme[.dpadUp, .long] = ButtonMapping(action: .mute)
        var actions: [(String, Bool)] = []
        model.onAction = { mapping, pressed, _ in actions.append((mapping.action.rawValue, pressed)) }
        model.present(scheme: scheme, titleFor: { $0.action.label })

        model.handle(.dpadUp, pressed: true)
        model.handle(.dpadUp, pressed: false)
        XCTAssertTrue(actions.isEmpty, "single tap waits for the double-tap window")
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions.map(\.0), ["volumeUp", "volumeUp"])
        XCTAssertEqual(actions.map(\.1), [true, false])

        actions.removeAll()
        model.handle(.dpadUp, pressed: true)
        model.handle(.dpadUp, pressed: false)
        clock.advance(0.1)
        model.handle(.dpadUp, pressed: true)
        model.handle(.dpadUp, pressed: false)
        XCTAssertEqual(actions.map(\.0), ["volumeDown", "volumeDown"])

        actions.removeAll()
        model.handle(.dpadUp, pressed: true)
        clock.advance(RemoteGestureController.longPressDelay)
        XCTAssertEqual(actions.map(\.0), ["mute", "mute"])
        model.handle(.dpadUp, pressed: false)
        XCTAssertTrue(model.isPresented, "closeAfterAction is off")
    }

    @MainActor
    func testCloseAfterActionAndAnyOtherKeyDismiss() {
        let clock = TestClock()
        for closeAfterAction in [true, false] {
            let model = VirtualPadPickerModel(schedule: clock.schedule)
            var scheme = VirtualKeyScheme(name: "关闭测试", closeAfterAction: closeAfterAction,
                                          mapping: RemoteMapping(buttons: [:]))
            scheme[.buttonA, .single] = ButtonMapping(action: .enter)
            var actions: [String] = []
            model.onAction = { mapping, _, _ in actions.append(mapping.action.rawValue) }
            model.present(scheme: scheme, titleFor: { $0.action.label })
            XCTAssertNotNil(model.titles[.buttonA], "titles: \(model.titles)")
            XCTAssertTrue(model.handle(.buttonA, pressed: true), "press must be consumed")
            model.handle(.buttonA, pressed: false)
            XCTAssertEqual(actions, ["enter", "enter"], "press and release both forward to dispatch")
            XCTAssertEqual(model.isPresented, !closeAfterAction)

            if !closeAfterAction {
                XCTAssertTrue(model.handle(.buttonB, pressed: true))
                XCTAssertFalse(model.isPresented, "any key outside the pad dismisses it")
                XCTAssertEqual(actions, ["enter", "enter"])
            }
        }
    }

    @MainActor
    func testNestedSchemeKeepsReleaseAndStaysOpen() {
        let clock = TestClock()
        let model = VirtualPadPickerModel(schedule: clock.schedule)
        var inner = VirtualKeyScheme(name: "内层", closeAfterAction: true,
                                     mapping: RemoteMapping(buttons: [:]))
        inner[.buttonA, .single] = ButtonMapping(action: .enter)
        var outer = VirtualKeyScheme(name: "外层", closeAfterAction: true,
                                     mapping: RemoteMapping(buttons: [:]))
        outer[.buttonA, .single] = ButtonMapping(action: .openVirtualPad,
                                                 referenceID: inner.id.uuidString)

        var events: [String] = []
        var edges: [Bool] = []
        model.onAction = { [weak model] mapping, pressed, _ in
            events.append(mapping.action.rawValue)
            edges.append(pressed)
            guard let model, pressed, mapping.action == .openVirtualPad else { return }
            model.present(scheme: inner, titleFor: { $0.action.label })
        }
        model.present(scheme: outer, titleFor: { $0.action.label })
        model.handle(.buttonA, pressed: true)
        model.handle(.buttonA, pressed: false)

        XCTAssertEqual(events, ["openVirtualPad", "openVirtualPad"])
        XCTAssertEqual(edges, [true, false], "the nested present must not swallow the release")
        XCTAssertTrue(model.isPresented, "nested scheme must not be auto-closed by the outer action")
        XCTAssertEqual(model.schemeName, "内层")
    }

    @MainActor
    func testInterleavedKeysKeepTheirOwnCloseGeneration() {
        let clock = TestClock()
        let model = VirtualPadPickerModel(schedule: clock.schedule)
        var inner = VirtualKeyScheme(name: "内层", closeAfterAction: true,
                                     mapping: RemoteMapping(buttons: [:]))
        inner[.buttonA, .single] = ButtonMapping(action: .enter)
        var outer = VirtualKeyScheme(name: "外层", closeAfterAction: true,
                                     mapping: RemoteMapping(buttons: [:]))
        outer[.buttonA, .single] = ButtonMapping(action: .openVirtualPad,
                                                 referenceID: inner.id.uuidString)
        outer[.dpadUp, .single] = ButtonMapping(action: .volumeUp)

        model.onAction = { [weak model] mapping, pressed, _ in
            guard let model, pressed, mapping.action == .openVirtualPad else { return }
            model.present(scheme: inner, titleFor: { $0.action.label })
        }
        model.present(scheme: outer, titleFor: { $0.action.label })

        model.handle(.buttonA, pressed: true)   // presents inner
        model.handle(.dpadUp, pressed: true)    // a second key starts in inner
        model.handle(.buttonA, pressed: false)  // belongs to outer, must not close inner
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.schemeName, "内层")
        model.handle(.dpadUp, pressed: false)   // belongs to inner, closes it
        XCTAssertFalse(model.isPresented)
    }

    @MainActor
    func testOpeningPressCannotSelectAVirtualKey() {
        let clock = TestClock()
        let model = VirtualPadPickerModel(schedule: clock.schedule)
        var scheme = VirtualKeyScheme(name: "打开键", closeAfterAction: false)
        scheme[.dpadUp, .single] = ButtonMapping(action: .volumeUp)
        var actions: [String] = []
        model.onAction = { mapping, _, _ in actions.append(mapping.action.rawValue) }
        // The physical button that opened the pad is still held at present time.
        model.handle(.dpadUp, pressed: true)
        model.present(scheme: scheme, titleFor: { $0.action.label })
        model.handle(.dpadUp, pressed: false)
        clock.advance(1)
        XCTAssertTrue(actions.isEmpty)
        // A fresh press still works.
        model.handle(.dpadUp, pressed: true)
        model.handle(.dpadUp, pressed: false)
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions, ["volumeUp", "volumeUp"])
    }

    @MainActor
    func testSchemesPersistRoundTripAndDeleteKeepsReferencesForUndo() throws {
        let suite = "VirtualPadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.virtualKeySchemes.count, 1)

        var scheme = model.virtualKeySchemes[0]
        scheme.name = "媒体中心"
        scheme.closeAfterAction = false
        model.virtualKeySchemes[0] = scheme
        model.flushPendingWrites()
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).virtualKeySchemes,
                       model.virtualKeySchemes)

        let backup = try JSONDecoder().decode(SettingsBackup.self,
                                              from: JSONEncoder().encode(model.configurationBackup()))
        XCTAssertEqual(backup.virtualKeySchemes?.count, 1)

        model.update(ButtonMapping(action: .openVirtualPad, referenceID: scheme.id.uuidString),
                     for: .buttonY, trigger: .single)
        XCTAssertEqual(model.deletionImpact(for: .virtualKeyScheme(scheme.id)).directMappings, 1)
        XCTAssertTrue(model.deleteConfigurationObject(.virtualKeyScheme(scheme.id)))
        XCTAssertTrue(model.virtualKeySchemes.isEmpty)
        XCTAssertEqual(model.effectiveMapping[.buttonY, .single].referenceID, scheme.id.uuidString)
        XCTAssertGreaterThanOrEqual(model.danglingReferenceCount(), 1)
        model.undoDeletion()
        XCTAssertEqual(model.virtualKeySchemes.count, 1)
        XCTAssertEqual(model.effectiveMapping[.buttonY, .single].referenceID, scheme.id.uuidString)
    }

    @MainActor
    func testDanglingReferenceCountIncludesVirtualSchemes() throws {
        let suite = "VirtualPadDangling." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var backup = model.configurationBackup()
        backup.virtualKeySchemes = []
        let remoteID = try XCTUnwrap(backup.remoteKeyConfigurations?.keys.first)
        var configuration = try XCTUnwrap(backup.remoteKeyConfigurations?[remoteID])
        var profile = configuration.profiles[0]
        profile.mapping[.buttonY, .single] = ButtonMapping(action: .openVirtualPad,
                                                           referenceID: UUID().uuidString)
        configuration.profiles[0] = profile
        backup.remoteKeyConfigurations?[remoteID] = configuration
        XCTAssertEqual(PreparedConfiguration.danglingReferenceCount(in: backup), 1)
    }

    @MainActor
    func testDeletionImpactKeepsVirtualSchemeUsesDistinct() throws {
        let suite = "VirtualPadImpact." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let target = model.virtualKeySchemes[0]
        var first = VirtualKeyScheme(name: "方案一", mapping: RemoteMapping(buttons: [:]))
        first[.buttonA, .single] = ButtonMapping(action: .openVirtualPad, referenceID: target.id.uuidString)
        var second = VirtualKeyScheme(name: "方案二", mapping: RemoteMapping(buttons: [:]))
        second[.buttonA, .single] = ButtonMapping(action: .openVirtualPad, referenceID: target.id.uuidString)
        model.virtualKeySchemes = [target, first, second]

        let impact = model.deletionImpact(for: .virtualKeyScheme(target.id))
        let virtualUses = impact.mappings.filter(\.isVirtualScheme)
        XCTAssertEqual(virtualUses.count, 2)
        XCTAssertEqual(Set(virtualUses.map(\.id)).count, 2, "each scheme needs a unique ForEach id")
        XCTAssertEqual(impact.remoteCount, 0, "virtual schemes are not remote models")
        XCTAssertEqual(impact.virtualSchemeCount, 2)
    }

    func testOpenVirtualPadCannotRunAsMacro() throws {
        let mapping = ButtonMapping(action: .openVirtualPad, referenceID: UUID().uuidString)
        XCTAssertEqual(try JSONDecoder().decode(ButtonMapping.self, from: JSONEncoder().encode(mapping)), mapping)
        let macro = SavedMacro(name: "打开虚拟按键", steps: [MacroStep(mapping: mapping)])
        XCTAssertThrowsError(try MacroExecutionPlan(macro, macros: [macro])) {
            XCTAssertEqual($0 as? MacroExecutionError, .unsupportedAction)
        }
    }

    @MainActor
    func testPickerSnapshotForVisualReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["RC_HARNESS_VIRTUAL_PAD_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = VirtualPadPickerModel()
        var scheme = VirtualKeyScheme(name: "媒体控制", closeAfterAction: true)
        scheme[.dpadUp, .single] = ButtonMapping(action: .volumeUp)
        scheme[.dpadUp, .double] = ButtonMapping(action: .mute)
        scheme[.dpadDown, .single] = ButtonMapping(action: .volumeDown)
        scheme[.dpadLeft, .single] = ButtonMapping(action: .previousTrack)
        scheme[.dpadRight, .single] = ButtonMapping(action: .nextTrack)
        scheme[.buttonA, .single] = ButtonMapping(action: .playPause)
        model.present(scheme: scheme, titleFor: { $0.action.label })
        let host = NSHostingView(rootView: VirtualPadPickerView(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: VirtualPadPickerView.panelSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("virtual-pad-picker.png"))
    }
}

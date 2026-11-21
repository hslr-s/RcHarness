import AppKit
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class ShortcutHelpTests: XCTestCase {
    func testActionHasStableRawValueAndLabel() throws {
        XCTAssertEqual(RemoteAction.showShortcutHelp.rawValue, "showShortcutHelp")
        XCTAssertEqual(RemoteAction.showShortcutHelp.label, "显示快捷键速查")
        let decoded = try JSONDecoder().decode(RemoteAction.self, from: Data("\"showShortcutHelp\"".utf8))
        XCTAssertEqual(decoded, .showShortcutHelp)
    }

    func testAnyKeyDismissesPresentedPanel() throws {
        let displays = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        try XCTSkipIf(displays.isEmpty || displays.allSatisfy { CGDisplayIsAsleep($0) != 0 },
                      "Panel focus requires an awake display")

        let controller = ShortcutHelpController()
        defer { controller.dismiss() }
        controller.show(mapping: .defaults, profile: RemoteProfiles.googleG9N9N, mode: .mapping,
                        schemeName: "默认方案", globalInputs: [], titleFor: { $0.action.label })
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(controller.renderView?.window?.isVisible == true)

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "a", charactersIgnoringModifiers: "a",
                                                  isARepeat: false, keyCode: 0))
        controller.renderView?.window?.keyDown(with: event)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.renderView?.window?.isVisible == true)
    }
}

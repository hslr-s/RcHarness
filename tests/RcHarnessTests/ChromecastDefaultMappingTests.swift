import XCTest
@testable import RcHarness

@MainActor
final class ChromecastDefaultMappingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.ChromecastDefaultMappingTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultAndChatGPTSchemesMatchScreenshotAndResetWithoutChangingGlobals() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults,
                                         remoteProfile: RemoteProfiles.googleG9N9N)
        let chatgpt = try XCTUnwrap(model.harnesses.first { $0.id == "chatgpt" }?.profileID)
        let expected: [(ControllerInput, RemoteAction, RemoteAction, RemoteAction)] = [
            (.dpadUp, .arrowUp, .macro, .disabled),
            (.dpadRight, .arrowRight, .macro, .disabled),
            (.dpadDown, .arrowDown, .macro, .disabled),
            (.dpadLeft, .arrowLeft, .macro, .disabled),
            (.buttonA, .enter, .macro, .openPhrases),
            (.buttonB, .backspace, .disabled, .rapidDelete),
            (.home, .showDesktop, .escape, .disabled),
            (.rightShoulder, .volumeUp, .macro, .disabled),
            (.leftShoulder, .volumeDown, .macro, .disabled),
            (.youtube, .macro, .macro, .disabled),
            (.mute, .disabled, .macro, .disabled),
            (.netflix, .disabled, .macro, .disabled),
            (.power, .openHarnessSwitcher, .disabled, .switchToNativeMode),
            (.inputSource, .switchApplications, .showAllWindows, .showDesktop),
        ]
        let macros: [(ControllerInput, ButtonTrigger, String)] = [
            (.dpadUp, .double, "ChatGPT-转到最近聊天1"),
            (.dpadRight, .double, "ChatGPT-转到最近聊天2"),
            (.dpadDown, .double, "ChatGPT-转到最近聊天3"),
            (.dpadLeft, .double, "ChatGPT-转到最近聊天4"),
            (.rightShoulder, .double, "ChatGPT-转到最近聊天5"),
            (.leftShoulder, .double, "ChatGPT-转到最近聊天6"),
            (.buttonA, .double, "ChatGPT-新建会话"),
            (.youtube, .single, "ChatGPT-切换会话与标签页"),
            (.youtube, .double, "ChatGPT-新建独立会话"),
            (.mute, .double, "ChatGPT-上一个会话"),
            (.netflix, .double, "ChatGPT-下一个会话"),
        ]
        let globals = model.globalButtons
        let original = model.mapping
        for id in [SavedKeyProfile.defaultID, chatgpt] {
            model.activateProfile(id)
            XCTAssertEqual(model.mapping, original)
            for (input, single, double, long) in expected {
                XCTAssertEqual(model.effectiveMapping[input, .single].action, single, input.rawValue)
                XCTAssertEqual(model.effectiveMapping[input, .double].action, double, input.rawValue)
                XCTAssertEqual(model.effectiveMapping[input, .long].action, long, input.rawValue)
            }
            for (input, trigger, name) in macros {
                let preset = try XCTUnwrap(model.macros.first { $0.name == name })
                XCTAssertEqual(model.effectiveMapping[input, trigger].referenceID, preset.id.uuidString)
                XCTAssertNoThrow(try MacroExecutionPlan(preset, macros: model.macros))
            }
            model.update(ButtonMapping(action: .copy), for: .dpadUp, trigger: .single)
            model.resetMapping()
            XCTAssertEqual(model.mapping, original)
            XCTAssertEqual(model.globalButtons, globals)
        }
        XCTAssertEqual(model.globalButtons.buttons.compactMap(\.input), [.power, .home, .inputSource])
        XCTAssertEqual(model.voiceMode, .tap)
        XCTAssertEqual(model.voiceTapShortcut.modifierKeyCodes, [VirtualKey.function, 55])
        XCTAssertEqual(model.effectiveMapping[.options].shortcut, model.voiceTapShortcut)
        XCTAssertEqual(model.danglingReferenceCount(), 0)
    }

    func testDeletedOrRenamedChatGPTMacrosRemainRespectedWhenGeneratingGoogleDefaults() throws {
        var macros = DefaultMacros.chatgpt
        let next = try XCTUnwrap(macros.firstIndex { $0.name == "ChatGPT-下一个会话" })
        macros[next].name = "我重命名的动作"
        let id = macros[next].id
        macros.removeAll { $0.name == "ChatGPT-新建独立会话" }
        let mapping = RemoteMapping.chromecastDefaults(macros: macros)
        XCTAssertEqual(mapping[.netflix, .double].referenceID, id.uuidString)
        XCTAssertEqual(mapping[.youtube, .double].action, .disabled)
    }

    func testSavedEditsSurviveRestartImportAndSwitchingRemote() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults,
                                         remoteProfile: RemoteProfiles.googleG9N9N)
        model.update(ButtonMapping(action: .paste), for: .home, trigger: .single)
        model.update(ButtonMapping(action: .copy), for: .power, trigger: .double)
        model.voiceMode = .hold
        let profiles = model.profiles
        let globals = model.globalButtons
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(backup)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        restored.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        XCTAssertEqual(restored.voiceMode, .hold)
        XCTAssertEqual(restored.effectiveMapping[.power, .double].action, .disabled)
        restored.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(restored.profiles, profiles)
        XCTAssertEqual(restored.globalButtons, globals)
        XCTAssertEqual(restored.effectiveMapping[.home].action, .paste)
    }
}

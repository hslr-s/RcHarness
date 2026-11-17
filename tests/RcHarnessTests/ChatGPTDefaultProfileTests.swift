import XCTest
@testable import RcHarness

@MainActor
final class ChatGPTDefaultProfileTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "RcHarness.ChatGPTDefaultProfileTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLegacyRenamePreservesBindingsActionsAndSelectionAcrossRemotesAndRestart() throws {
        var macro = DefaultMacros.chatgpt[0]
        macro.name = "Codex-我的动作"
        macro.tagIDs = ["codex", "cursor"]
        macro.steps[0].mapping = ButtonMapping(action: .copy)
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .macro, referenceID: macro.id.uuidString)
        let profile = SavedKeyProfile(name: "Codex 按键方案", mapping: mapping)
        let harness = HarnessConfiguration(id: "codex", name: "Codex", bundleIdentifier: "com.openai.codex",
            applicationPath: "/Applications/ChatGPT.app", profileID: profile.id, didInitializeDefaultProfile: true)
        let configuration = RemoteKeyConfiguration(profiles: [profile], harnessProfileIDs: ["codex": profile.id],
            initializedHarnessIDs: ["codex"], globalButtons: GlobalButtonSettings(),
            selectedProfileID: profile.id, selectedHarnessID: "codex")
        SettingsStorage.save([harness], SettingsKeys.Stored.harnesses, defaults: defaults)
        SettingsStorage.save([macro], SettingsKeys.Stored.macros, defaults: defaults)
        SettingsStorage.save([RemoteProfiles.xiaomiRC003.id: configuration, RemoteProfiles.googleG9N9N.id: configuration],
            SettingsKeys.Stored.remoteKeyConfigurations, defaults: defaults)
        defaults.set(DefaultMacros.version, forKey: SettingsKeys.macroPresetsVersion)

        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in [RemoteProfiles.xiaomiRC003, RemoteProfiles.googleG9N9N] {
            model.selectRemoteProfile(remote.id)
            XCTAssertEqual(model.selectedHarnessID, "chatgpt")
            XCTAssertEqual(model.selectedProfileID, profile.id)
            XCTAssertEqual(model.mapping, mapping)
            XCTAssertEqual(model.profiles.first { $0.id == profile.id }?.name, "ChatGPT 按键方案")
            let current = try XCTUnwrap(model.harnesses.first { $0.id == "chatgpt" })
            XCTAssertEqual(current.name, "ChatGPT")
            XCTAssertEqual(current.applicationPath, harness.applicationPath)
            XCTAssertTrue(current.matches(applicationPath: nil, bundleIdentifier: "com.openai.codex"))
            XCTAssertFalse(model.harnesses.contains { $0.id == "codex" })
        }
        XCTAssertEqual(model.macros.count, 1)
        XCTAssertEqual(model.macros.first?.name, "ChatGPT-我的动作")
        XCTAssertEqual(model.macros.first?.tagIDs, ["chatgpt", "cursor"])
        XCTAssertEqual(model.macros.first?.steps, macro.steps)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
        XCTAssertEqual(restored.harnesses, model.harnesses)
        XCTAssertEqual(restored.selectedHarnessID, "chatgpt")
    }

    func testLegacyImportPreservesDisabledHarnessAndIntentionalUnbinding() throws {
        let profile = SavedKeyProfile(name: "Codex 按键方案", mapping: .defaults)
        let harness = HarnessConfiguration(id: "codex", name: "Codex", bundleIdentifier: "com.openai.codex",
            isEnabled: false, didInitializeDefaultProfile: true)
        let configuration = RemoteKeyConfiguration(profiles: [profile], harnessProfileIDs: [:],
            initializedHarnessIDs: ["codex"], globalButtons: GlobalButtonSettings(), selectedProfileID: profile.id)
        var backup = SettingsBackup(mapping: .defaults, profiles: [profile], macros: [], phrases: [], harnesses: [harness])
        backup.remoteKeyConfigurations = [RemoteProfiles.xiaomiRC003.id: configuration]
        backup.macroPresetsVersion = DefaultMacros.version
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(backup)
        let current = try XCTUnwrap(model.harnesses.first { $0.id == "chatgpt" })
        XCTAssertFalse(current.isEnabled)
        XCTAssertNil(current.profileID)
        XCTAssertTrue(current.didInitializeDefaultProfile)
        XCTAssertEqual(model.profiles.first { $0.id == profile.id }?.name, "ChatGPT 按键方案")
        XCTAssertFalse(model.canDeleteProfile(profile.id))
        XCTAssertTrue(model.macros.isEmpty)
    }

    func testFreshXiaomiDefaultAndChatGPTProfilesMatchScreenshot() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003] {
            model.selectRemoteProfile(remote.id)
            let harness = try XCTUnwrap(model.harnesses.first { $0.id == "chatgpt" })
            let profile = try XCTUnwrap(model.profiles.first { $0.id == harness.profileID })
            XCTAssertEqual(profile.name, "ChatGPT 按键方案")
            XCTAssertTrue(harness.didInitializeDefaultProfile)
            XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
            XCTAssertEqual(model.defaultMapping, profile.mapping)
            for id in [SavedKeyProfile.defaultID, profile.id] {
                model.activateProfile(id)
                let actions: [(ControllerInput, RemoteAction, RemoteAction, RemoteAction)] = [
                    (.dpadUp, .arrowUp, .macro, .disabled), (.dpadRight, .arrowRight, .macro, .disabled),
                    (.dpadDown, .arrowDown, .macro, .disabled), (.dpadLeft, .arrowLeft, .macro, .disabled),
                    (.buttonA, .enter, .macro, .openPhrases), (.buttonB, .backspace, .disabled, .rapidDelete),
                    (.home, .showDesktop, .escape, .disabled), (.menu, .macro, .macro, .disabled),
                    (.rightShoulder, .volumeUp, .macro, .disabled), (.leftShoulder, .volumeDown, .macro, .disabled),
                    (.power, .openHarnessSwitcher, .disabled, .switchToNativeMode),
                    (.buttonY, .switchApplications, .showAllWindows, .showDesktop),
                ]
                for (input, single, double, long) in actions {
                    XCTAssertEqual(model.effectiveMapping[input].action, single, input.rawValue)
                    XCTAssertEqual(model.effectiveMapping[input, .double].action, double, input.rawValue)
                    XCTAssertEqual(model.effectiveMapping[input, .long].action, long, input.rawValue)
                }
                let recentInputs: [ControllerInput] = [.dpadUp, .dpadRight, .dpadDown, .dpadLeft, .rightShoulder, .leftShoulder]
                for (offset, input) in recentInputs.enumerated() {
                    let button = model.mapping[input, .double]
                    let macro = try XCTUnwrap(model.macros.first { $0.id.uuidString == button.referenceID })
                    XCTAssertEqual(macro.name, "ChatGPT-转到最近聊天\(offset + 1)")
                    let plan = try MacroExecutionPlan(macro, macros: model.macros)
                    XCTAssertEqual(plan.events.count, 1)
                    XCTAssertEqual(plan.events.first?.mapping.shortcut?.label, "⌥⌘\(offset + 1)")
                }
                XCTAssertEqual(model.mappingTitle(model.mapping[.buttonA, .double]), "ChatGPT-新建会话")
                XCTAssertEqual(model.mappingTitle(model.mapping[.menu]), "ChatGPT-切换会话与标签页")
                XCTAssertEqual(model.mappingTitle(model.mapping[.menu, .double]), "ChatGPT-新建独立会话")
                XCTAssertEqual(model.voiceMode, .hold)
                XCTAssertEqual(model.voiceHoldShortcut, .voiceHoldDefault)
                XCTAssertEqual(model.effectiveMapping[.options], model.globalButtons.voice)
                XCTAssertEqual(model.danglingReferenceCount(), 0)
            }
        }
    }

    func testChatGPTUpgradePreservesExistingBindingMappingSelectionAndGlobals() throws {
        var mapping = RemoteMapping.defaults
        mapping[.dpadLeft] = ButtonMapping(action: .paste)
        mapping[.buttonA, .double] = ButtonMapping(action: .copy)
        let profile = SavedKeyProfile(name: "ChatGPT 按键方案", mapping: mapping)
        var harness = try XCTUnwrap(HarnessConfiguration.defaults.first { $0.id == "chatgpt" })
        harness.profileID = profile.id
        var globals = GlobalButtonSettings().normalized()
        globals.voice = ButtonMapping(action: .fn)
        SettingsStorage.save([profile], SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save([harness], SettingsKeys.Stored.harnesses, defaults: defaults)
        SettingsStorage.save(globals, SettingsKeys.Stored.globalButtons, defaults: defaults)
        defaults.set(profile.id.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.profiles.first { $0.id == profile.id }, profile)
        XCTAssertEqual(model.harnesses.first?.profileID, profile.id)
        XCTAssertEqual(model.harnesses.first?.didInitializeDefaultProfile, true)
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(model.globalButtons, globals)
        try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: [profile], macros: [], phrases: [], harnesses: [harness], globalButtons: globals))
        XCTAssertEqual(model.profiles.first { $0.id == profile.id }, profile)
        XCTAssertEqual(model.harnesses.first?.profileID, profile.id)
        XCTAssertEqual(model.globalButtons, globals)
    }

    func testUnboundChatGPTInitializationKeepsConflictingProfileAndDoesNotRepeat() throws {
        let existing = SavedKeyProfile(name: "ChatGPT 按键方案", mapping: .defaults)
        var harness = try XCTUnwrap(HarnessConfiguration.defaults.first { $0.id == "chatgpt" })
        harness.isEnabled = false
        SettingsStorage.save([existing], SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save([harness], SettingsKeys.Stored.harnesses, defaults: defaults)
        defaults.set(existing.id.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let generatedID = try XCTUnwrap(model.harnesses.first?.profileID)
        let generated = try XCTUnwrap(model.profiles.first { $0.id == generatedID })
        XCTAssertEqual(generated.name, "ChatGPT 按键方案 2")
        XCTAssertEqual(model.mappingTitle(generated.mapping[.dpadUp, .double]), "ChatGPT-转到最近聊天1")
        XCTAssertEqual(model.profiles.first { $0.id == existing.id }, existing)
        XCTAssertEqual(model.selectedProfileID, existing.id)
        XCTAssertEqual(model.harnesses.first?.isEnabled, false)
        model.activateProfile(generatedID)
        model.update(ButtonMapping(action: .paste), for: .dpadRight, trigger: .single)
        model.resetMapping()
        XCTAssertEqual(model.mapping[.dpadRight].action, .arrowRight)
        XCTAssertEqual(model.mappingTitle(model.mapping[.dpadUp, .double]), "ChatGPT-转到最近聊天1")
        model.update(ButtonMapping(action: .copy), for: .dpadUp, trigger: .double)
        model.bindProfile(nil, to: harness.id)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.profiles, model.profiles)
        XCTAssertNil(restored.harnesses.first?.profileID)
        try restored.applyConfiguration(backup)
        XCTAssertEqual(restored.profiles, model.profiles)
        XCTAssertNil(restored.harnesses.first?.profileID)
        XCTAssertEqual(restored.profiles.first { $0.id == generatedID }?.mapping[.dpadUp, .double].action, .copy)
    }

    func testResetChatGPTUsesExistingMacroIDsAndPreservesGlobalsAndDeletedMacros() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profileID = try XCTUnwrap(model.harnesses.first { $0.id == "chatgpt" }?.profileID)
        let newChat = try XCTUnwrap(model.macros.first { $0.name == "ChatGPT-新建会话" })
        XCTAssertTrue(model.renameMacro(newChat.id, name: "我的新会话"))
        let firstChat = try XCTUnwrap(model.macros.first { $0.name == "ChatGPT-转到最近聊天1" })
        model.deleteMacro(firstChat.id)
        let replacementID = model.addMacro()
        XCTAssertTrue(model.renameMacro(replacementID, name: "chatgpt-转到最近聊天1"))
        let lastChat = try XCTUnwrap(model.macros.first { $0.name == "ChatGPT-转到最近聊天6" })
        model.deleteMacro(lastChat.id)
        model.bindProfile(nil, to: "chatgpt")
        model.activateProfile(profileID)
        model.update(ButtonMapping(action: .paste), for: .dpadRight, trigger: .single)
        model.update(ButtonMapping(action: .disabled), for: .menu, trigger: .single)
        model.update(ButtonMapping(action: .showAllWindows), for: .buttonY, trigger: .single)
        model.update(ButtonMapping(action: .fn), for: .options, trigger: .single)
        let globals = model.globalButtons
        let macros = model.macros
        model.resetMapping()
        XCTAssertEqual(model.mapping[.dpadRight].action, .arrowRight)
        XCTAssertEqual(model.mappingTitle(model.mapping[.menu]), "ChatGPT-切换会话与标签页")
        XCTAssertEqual(model.mapping[.buttonY].action, .disabled)
        XCTAssertEqual(model.effectiveMapping[.buttonY].action, .showAllWindows)
        XCTAssertEqual(model.mapping[.buttonA, .double].referenceID, newChat.id.uuidString)
        XCTAssertEqual(model.mapping[.dpadUp, .double].referenceID, replacementID.uuidString)
        XCTAssertEqual(model.mapping[.leftShoulder, .double].action, .disabled)
        XCTAssertEqual(model.macros, macros)
        XCTAssertEqual(model.globalButtons, globals)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        // The untouched default scheme still retains both deleted macro IDs.
        XCTAssertEqual(model.danglingReferenceCount(), 2)
        model.activateProfile(nil)
        model.resetMapping()
        XCTAssertEqual(model.mapping, .defaults(for: model.remoteProfile, macros: model.macros))
        XCTAssertEqual(model.danglingReferenceCount(), 0)
        XCTAssertEqual(model.globalButtons, globals)
    }
}

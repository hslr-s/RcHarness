import XCTest
@testable import RcHarness

@MainActor
final class HarnessComposerFocusMigrationTests: XCTestCase {
    func testComposerScoringPrefersConversationOverSearchAndRejectsSensitiveFields() {
        let composer = HarnessComposerTarget(
            role: "AXTextArea", identifier: "message-input", placeholder: "发送消息",
            context: "composer", normalizedFrame: HarnessNormalizedFrame(x: 0.1, y: 0.7, width: 0.8, height: 0.15))
        let search = HarnessComposerTarget(
            role: "AXTextField", identifier: "search", placeholder: "搜索",
            normalizedFrame: HarnessNormalizedFrame(x: 0.1, y: 0.05, width: 0.8, height: 0.08))
        let composerScore = HarnessComposerCandidate.score(composer, windowFrame: nil)
        let searchScore = HarnessComposerCandidate.score(search, windowFrame: nil)
        XCTAssertNotNil(composerScore)
        XCTAssertNotNil(searchScore)
        XCTAssertGreaterThan(composerScore ?? 0, searchScore ?? 0)

        let password = HarnessComposerTarget(role: "AXTextField", identifier: "password")
        let addressBar = HarnessComposerTarget(role: "AXTextField", identifier: "address bar", placeholder: "搜索或输入网址")
        let commandPalette = HarnessComposerTarget(role: "AXTextArea", context: "command palette")
        XCTAssertNil(HarnessComposerCandidate.score(password, windowFrame: nil))
        XCTAssertNil(HarnessComposerCandidate.score(addressBar, windowFrame: nil))
        XCTAssertNil(HarnessComposerCandidate.score(commandPalette, windowFrame: nil))
        XCTAssertEqual(HarnessComposerCandidate.bestIndex(in: [search, composer], windowFrame: nil), 1)
    }

    func testRecordedTargetSurvivesFrameChangesButNotIdentityChanges() {
        let recorded = HarnessComposerTarget(
            role: "AXTextArea", identifier: "composer-input", title: "消息", windowTitle: "会话")
        var candidate = recorded
        candidate.windowTitle = "新会话"
        candidate.normalizedFrame = HarnessNormalizedFrame(x: 0.2, y: 0.8, width: 0.6, height: 0.1)
        XCTAssertTrue(HarnessComposerCandidate.matches(recorded: recorded, candidate: candidate))

        candidate.identifier = "search-field"
        XCTAssertFalse(HarnessComposerCandidate.matches(recorded: recorded, candidate: candidate))

        candidate = recorded
        candidate.placeholder = "密码"
        XCTAssertFalse(HarnessComposerCandidate.matches(recorded: recorded, candidate: candidate))
    }

    func testFocusConfigurationReachesTheRetryHandler() {
        let clock = TestClock()
        let target = HarnessComposerTarget(role: "AXTextArea", identifier: "composer-input")
        var received: HarnessFocusConfiguration?
        let focus = HarnessComposerFocus(state: { _ in .frontmost },
                                         focusComposer: { _, _, configuration in
            received = configuration
            return true
        }, schedule: clock.schedule)
        focus.start(processID: 42, target: .custom,
                    configuration: HarnessFocusConfiguration(strategy: .recorded, recorded: target))
        XCTAssertEqual(received?.strategy, .recorded)
        XCTAssertEqual(received?.recorded, target)
    }

    func testRecorderCapturesTheFirstValidFocusAndRespectsTimeout() {
        let clock = TestClock()
        let target = HarnessComposerTarget(role: "AXTextArea", identifier: "composer-input")
        var snapshots: [HarnessComposerTarget?] = [nil, nil, target]
        var result: HarnessComposerTarget?
        var completed = false
        let recorder = HarnessComposerRecorder(snapshot: { snapshots.isEmpty ? nil : snapshots.removeFirst() },
                                               schedule: clock.schedule, now: { clock.time })
        recorder.start(timeout: 5) { captured in
            result = captured
            completed = true
        }
        XCTAssertFalse(completed)
        clock.advance(0.3)
        XCTAssertTrue(completed)
        XCTAssertEqual(result, target)

        var timedOut: HarnessComposerTarget?
        var timeoutCompleted = false
        let idle = HarnessComposerRecorder(snapshot: { nil }, schedule: clock.schedule, now: { clock.time })
        idle.start(timeout: 2) { timedOut = $0; timeoutCompleted = true }
        clock.advance(1.9)
        XCTAssertFalse(timeoutCompleted)
        clock.advance(0.2)
        XCTAssertTrue(timeoutCompleted)
        XCTAssertNil(timedOut)
    }

    func testFocusRequestGateInvalidatesEarlierRequests() {
        let gate = HarnessFocusRequestGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testFocusApplicationActionAndHarnessFocusSettingsSurviveCoding() throws {
        let mapping = ButtonMapping(action: .focusApplication, shortcut: nil, applicationPath: "/Applications/Demo.app")
        let decoded = try JSONDecoder().decode(ButtonMapping.self,
                                               from: JSONEncoder().encode(mapping))
        XCTAssertEqual(decoded.action, .focusApplication)
        XCTAssertEqual(decoded.applicationPath, mapping.applicationPath)
        XCTAssertEqual(decoded.action.label, "打开聚焦所选应用")

        var harness = HarnessConfiguration.defaults[0]
        harness.focusStrategy = .recorded
        harness.composerTarget = HarnessComposerTarget(role: "AXTextArea", identifier: "composer-input")
        let restored = try JSONDecoder().decode(HarnessConfiguration.self,
                                                from: JSONEncoder().encode(harness))
        XCTAssertEqual(restored.focusStrategy, .recorded)
        XCTAssertEqual(restored.composerTarget, harness.composerTarget)

        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(HarnessConfiguration.defaults[0])) as? [String: Any])
        XCTAssertNil(legacy["focusStrategy"])
        XCTAssertNil(legacy["composerTarget"])
    }

    func testBackupImportExportPreservesFocusSettingsAndFocusApplicationBinding() throws {
        let suite = "RcHarness.FocusMigration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let harnessID = try XCTUnwrap(model.harnesses.first?.id)
        let target = HarnessComposerTarget(role: "AXTextArea", identifier: "composer-input", windowTitle: "会话")
        model.setHarnessFocusStrategy(harnessID, strategy: .recorded)
        model.setHarnessComposerTarget(harnessID, target: target)
        model.update(ButtonMapping(action: .focusApplication, shortcut: nil,
                                   applicationPath: "/Applications/Demo.app"),
                     for: .buttonA, trigger: .single)

        let stored = try XCTUnwrap(SettingsStorage.load([HarnessConfiguration].self,
                                                        SettingsKeys.Stored.harnesses, defaults: defaults))
        XCTAssertEqual(stored.first(where: { $0.id == harnessID })?.focusStrategy, .recorded)
        XCTAssertEqual(stored.first(where: { $0.id == harnessID })?.composerTarget, target)

        let backup = try JSONDecoder().decode(SettingsBackup.self,
                                              from: JSONEncoder().encode(model.configurationBackup()))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try restored.applyConfiguration(backup)
        XCTAssertEqual(restored.harnesses.first(where: { $0.id == harnessID })?.focusStrategy, .recorded)
        XCTAssertEqual(restored.harnesses.first(where: { $0.id == harnessID })?.composerTarget, target)
        let binding = restored.profiles.first(where: { $0.id == restored.selectedProfileID })?.mapping[.buttonA]
        XCTAssertEqual(binding?.action, .focusApplication)
        XCTAssertEqual(binding?.applicationPath, "/Applications/Demo.app")
    }
}

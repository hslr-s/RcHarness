import AppKit
import SwiftUI

enum VoiceInputTool: String, CaseIterable, Identifiable {
    case weChat, doubao

    var id: String { rawValue }
    var title: String { self == .weChat ? "微信输入法设置" : "豆包输入法设置" }
    var bundleIdentifier: String {
        self == .weChat ? "com.tencent.inputmethod.wetype" : "com.bytedance.inputmethod.doubaoime"
    }
    var applicationName: String { self == .weChat ? "WeType.app" : "DoubaoIme.app" }
    var settingsBundleIdentifier: String {
        self == .weChat ? "com.tencent.WeTypeSettings" : "com.bytedance.inputmethod.doubaoime.settings"
    }
    var settingsPaths: [String] {
        self == .weChat ? ["Contents/MacOS/WeTypeSettings.app"] : [
            "Contents/Applications/DoubaoImeSettings.app", "Contents/DoubaoImeSettings.app",
        ]
    }
    var arguments: [String] { self == .weChat ? ["--ShowVoiceInputShortcut"] : ["--openTab", "voice"] }

    // Launch arguments alone are ignored when a settings app is already running.
    var notificationName: Notification.Name {
        Notification.Name(self == .weChat ? "WeType2Settings_channel" : "DoubaoImeSettings.navigateToTab")
    }
    var notificationObject: String? { self == .weChat ? "ShowVoiceInputShortcut" : nil }
    var notificationUserInfo: [String: String]? { self == .doubao ? ["tab": "voice"] : nil }
}

struct InstalledVoiceInputTool: Identifiable, Equatable {
    let tool: VoiceInputTool
    let settingsURL: URL
    var id: VoiceInputTool { tool }
}

@MainActor
enum VoiceInputToolSettings {
    static func installed(
        fileManager: FileManager = .default,
        directories: [URL]? = nil,
        applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> [InstalledVoiceInputTool] {
        let roots = directories ?? [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods"),
            URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
        ]
        return VoiceInputTool.allCases.compactMap { tool in
            var candidates = roots.map { $0.appendingPathComponent(tool.applicationName, isDirectory: true) }
            if let registered = applicationURL(tool.bundleIdentifier) { candidates.append(registered) }
            for candidate in candidates {
                guard Bundle(url: candidate)?.bundleIdentifier == tool.bundleIdentifier else { continue }
                for path in tool.settingsPaths {
                    let settingsURL = candidate.appendingPathComponent(path, isDirectory: true)
                    guard let bundle = Bundle(url: settingsURL),
                          bundle.bundleIdentifier == tool.settingsBundleIdentifier,
                          let executable = bundle.executableURL,
                          fileManager.isExecutableFile(atPath: executable.path) else { continue }
                    return InstalledVoiceInputTool(tool: tool, settingsURL: settingsURL)
                }
            }
            return nil
        }
    }

    static func open(_ installed: InstalledVoiceInputTool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = installed.tool.arguments
        configuration.activates = true
        // Reuse the settings process; new instances produce duplicate windows.
        _ = try await NSWorkspace.shared.openApplication(at: installed.settingsURL, configuration: configuration)
        let tool = installed.tool
        DistributedNotificationCenter.default().postNotificationName(
            tool.notificationName, object: tool.notificationObject,
            userInfo: tool.notificationUserInfo, deliverImmediately: true
        )
    }
}

@MainActor
struct VoiceInputToolSettingsButtons: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var installed: [InstalledVoiceInputTool] = []
    @State private var opening: Set<VoiceInputTool> = []
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
            if let failure {
                Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder private var buttons: some View {
        Button("打开键盘设置") { openSystemSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
        ForEach(installed) { inputTool in
            Button(inputTool.tool.title) {
                opening.insert(inputTool.tool)
                failure = nil
                Task { @MainActor in
                    defer { opening.remove(inputTool.tool) }
                    do { try await VoiceInputToolSettings.open(inputTool) }
                    catch {
                        Log.settings.error("Could not open voice input settings: \(error.localizedDescription, privacy: .public)")
                        failure = "无法打开\(inputTool.tool.title)，请从输入法菜单打开语音输入设置。"
                        refresh()
                    }
                }
            }
            .disabled(opening.contains(inputTool.tool))
            .help("打开语音输入设置中的快捷键区域")
            .accessibilityHint("打开语音输入设置中的快捷键区域")
        }
    }

    private func refresh() { installed = VoiceInputToolSettings.installed() }
}

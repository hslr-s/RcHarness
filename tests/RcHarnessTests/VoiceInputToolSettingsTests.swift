import Foundation
import XCTest
@testable import RcHarness

@MainActor
final class VoiceInputToolSettingsTests: XCTestCase {
    func testOnlyInstalledToolsWithUsableSettingsAreShown() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(detect([root]).isEmpty)

        let weChat = try install(.weChat, in: root)
        XCTAssertEqual(detect([root]).map(\.tool), [.weChat])
        let doubao = try install(.doubao, in: root)
        XCTAssertEqual(detect([root]).map(\.tool), [.weChat, .doubao])

        try FileManager.default.removeItem(at: weChat.appendingPathComponent("Contents/MacOS/Settings"))
        XCTAssertEqual(detect([root]).map(\.tool), [.doubao])
        try FileManager.default.removeItem(at: doubao)
        XCTAssertTrue(detect([root]).isEmpty)
    }

    func testUserInstallTakesPrecedenceAndRegisteredInstallIsDeduplicated() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user")
        let system = root.appendingPathComponent("system")
        let selected = try install(.weChat, in: user)
        _ = try install(.weChat, in: system)
        let result = VoiceInputToolSettings.installed(directories: [user, system], applicationURL: { _ in
            user.appendingPathComponent(VoiceInputTool.weChat.applicationName)
        })
        XCTAssertEqual(result, [InstalledVoiceInputTool(tool: .weChat, settingsURL: selected)])
    }

    func testRenamedRegisteredInstallIsFoundButUnrelatedBundlesAreIgnored() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try install(.doubao, in: root)
        let original = root.appendingPathComponent(VoiceInputTool.doubao.applicationName)
        let renamed = root.appendingPathComponent("My Input Method.app")
        try FileManager.default.moveItem(at: original, to: renamed)
        XCTAssertTrue(detect([root]).isEmpty)
        let result = VoiceInputToolSettings.installed(directories: [], applicationURL: { identifier in
            identifier == VoiceInputTool.doubao.bundleIdentifier ? renamed : nil
        })
        XCTAssertEqual(result.map(\.tool), [.doubao])
        XCTAssertEqual(result.first?.settingsURL.lastPathComponent, settings.lastPathComponent)

        _ = try install(.weChat, in: root, bundleIdentifier: "example.unrelated")
        XCTAssertTrue(detect([root]).isEmpty)
    }

    private func detect(_ roots: [URL]) -> [InstalledVoiceInputTool] {
        VoiceInputToolSettings.installed(directories: roots, applicationURL: { _ in nil })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func install(_ tool: VoiceInputTool, in root: URL, bundleIdentifier: String? = nil) throws -> URL {
        let application = root.appendingPathComponent(tool.applicationName, isDirectory: true)
        let settings = application.appendingPathComponent(tool.settingsPaths[0], isDirectory: true)
        try writeBundle(application, identifier: bundleIdentifier ?? tool.bundleIdentifier)
        try writeBundle(settings, identifier: tool.settingsBundleIdentifier)
        return settings
    }

    private func writeBundle(_ url: URL, identifier: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Settings")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "Settings", "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps an enabled switch visibly on even when its window is inactive.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitchBody(configuration: configuration)
    }
}

private struct SettingsSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            LabeledContent {
                // Let the native switch supply metrics for the current control size.
                // Opacity keeps it laid out; hidden() would use fallback metrics.
                Toggle("", isOn: .constant(configuration.isOn))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(controlSize)
                    .disabled(true)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .overlay {
                        Capsule()
                            .fill(configuration.isOn ? onColor : SettingsStyle.switchOff)
                            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                                Circle()
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                                    .padding(2)
                            }
                            .opacity(isEnabled ? 1 : 0.5)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isOn)
                    }
            } label: {
                configuration.label
            }
            .fixedSize()
        }
        .buttonStyle(SettingsSwitchButtonStyle())
        .focusable(isEnabled)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard isEnabled else { return .ignored }
            configuration.isOn.toggle()
            return .handled
        }
        .accessibilityRepresentation {
            Toggle(configuration).toggleStyle(.switch)
        }
    }

    private var onColor: Color {
        activeState == .key ? SettingsStyle.switchOn : SettingsStyle.inactiveSwitchOn
    }
}

/// The switch supplies its own state feedback; pressing must not dim its label.
private struct SettingsSwitchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
    }
}

struct SettingsPanel<Content: View>: View {
    let title: String
    let symbol: String?
    let contentPadding: EdgeInsets
    @ViewBuilder var content: Content
    init(_ title: String = "", symbol: String? = nil,
         contentPadding: EdgeInsets = SettingsStyle.panelInsets,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.contentPadding = contentPadding; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
            if !title.isEmpty {
                HStack(spacing: SettingsStyle.Spacing.inline) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    Text(title).font(SettingsStyle.Typography.panelTitle)
                }
            }
            content
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: SettingsStyle.panelRadius).strokeBorder(Color.primary.opacity(0.07)) }
    }
}

struct SettingsStatus: View {
    let title: String
    var color: Color = .secondary
    var fixedWidth: CGFloat?

    init(title: String, color: Color = .secondary, fixedWidth: CGFloat? = nil) {
        self.title = title
        self.color = color
        self.fixedWidth = fixedWidth
    }

    var body: some View {
        label
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: Capsule())
    }

    @ViewBuilder
    private var label: some View {
        if let fixedWidth {
            Text(title).font(SettingsStyle.Typography.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(width: fixedWidth)
        } else {
            Text(title).font(SettingsStyle.Typography.caption.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .fixedSize()
        }
    }
}

struct SettingsEmpty: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: SettingsStyle.Spacing.inline) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.tertiary).padding(.bottom, 5)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 35)
    }
}

struct SettingsPreference<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: SettingsStyle.Spacing.controls) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty { Text(detail).font(SettingsStyle.Typography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 18)
            control
        }.padding(.vertical, 6)
    }
}

func openSystemSettings(_ url: String) {
    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
}

func batterySymbol(for level: Float) -> String {
    switch level {
    case 0.875...: return "battery.100percent"
    case 0.625...: return "battery.75percent"
    case 0.375...: return "battery.50percent"
    case 0.125...: return "battery.25percent"
    default: return "battery.0percent"
    }
}

enum AppInfo {
    /// Single source of truth: the bundle's Info.plist (set by build_app.sh).
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }
    static let repository = URL(string: "https://github.com/tokenzz-vip/RcHarness")!
    static let website = URL(string: "https://rcharness.tokenzz.vip")!
    static let history = URL(string: "https://github.com/tokenzz-vip/RcHarness/releases")!
}

/// File and application pickers. Kept in the view layer so the model only
/// receives the chosen URL.
enum FilePanels {
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseConfigurationDestination() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RcHarness-settings.json"
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseConfigurationSource() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
enum SettingsDialogs {
    static func presentCentered(_ alert: NSAlert, relativeTo parent: NSWindow? = nil) -> NSApplication.ModalResponse {
        let parent = parent ?? NSApp.windows.first {
            $0.isVisible && !$0.isMiniaturized && $0.windowController is DashboardWindowController
        }
        NSApp.activate(ignoringOtherApps: true)
        if let parent {
            alert.layout()
            let size = alert.window.frame.size
            alert.window.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2,
                                               y: parent.frame.midY - size.height / 2))
            // runModal repositions alerts that are not yet visible to the screen center.
            alert.window.orderFront(nil)
        }
        return alert.runModal()
    }

    /// Both the menu bar and mapping page use the same confirmation. Capture
    /// the target before the modal run loop, which can deliver profile changes.
    static func resetMapping(_ model: RemoteDashboardModel,
                             present: @MainActor (NSAlert) -> NSApplication.ModalResponse = {
                                 presentCentered($0)
                             }) {
        let remoteID = model.remoteProfile.id
        guard let profileID = model.selectedProfileID else { return }
        let harnesses = model.boundHarnesses(for: profileID)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "恢复「\(model.activeMappingName)」的默认映射？"
        alert.informativeText = "将覆盖此方案的自定义按键映射，且无法撤销。全局按键和语音快捷键保持不变。"
        if !harnesses.isEmpty {
            alert.informativeText += "\n此方案已绑定：\(harnesses.map(\.name).joined(separator: "、"))。恢复后对这些 Harness 同时生效。"
        }
        alert.addButton(withTitle: "取消")
        let resetButton = alert.addButton(withTitle: "恢复当前方案")
        resetButton.hasDestructiveAction = true
        guard present(alert) == .alertSecondButtonReturn else { return }
        guard model.remoteProfile.id == remoteID, model.selectedProfileID == profileID else {
            model.postNotice("当前遥控器或按键方案已切换，未恢复默认映射", level: .warning)
            return
        }
        model.resetMapping()
    }
}

/// Remote artwork that follows pressed keys. Observes only the live status so
/// presses do not re-render the surrounding page.
struct LiveRemoteArtwork: View {
    @ObservedObject var live: RemoteLiveStatus
    var highlightedInput: ControllerInput? = nil
    var onHoverInput: ((ControllerInput?) -> Void)? = nil
    var onSelectInput: ((ControllerInput) -> Void)? = nil
    var focusedInput: FocusState<ControllerInput?>.Binding? = nil
    var profile: RemoteProfile = RemoteProfiles.xiaomiRC003
    var body: some View {
        RemoteArtworkView(
            pressedInputs: live.pressedInputs, connected: true, highlightedInput: highlightedInput,
            onHoverInput: onHoverInput, onSelectInput: onSelectInput, focusedInput: focusedInput, profile: profile
        )
    }
}

struct LivePressIndicator: View {
    @ObservedObject var live: RemoteLiveStatus
    let input: ControllerInput
    var body: some View {
        if live.pressedInputs.contains(input) { Circle().fill(Color.green).frame(width: 6, height: 6) }
    }
}

struct ShortcutBindingEditor: View {
    private enum RecordingStyle: String, CaseIterable, Identifiable {
        case split = "分步录制"
        case combined = "一次录制"
        var id: String { rawValue }
    }

    @Binding var shortcut: RecordedShortcut?
    @Binding var capturing: Bool

    @State private var style: RecordingStyle = .combined
    @State private var modifier: RecordedShortcut?
    @State private var key: RecordedShortcut?
    @State private var capturingModifier = false
    @State private var capturingKey = false

    init(shortcut: Binding<RecordedShortcut?>, capturing: Binding<Bool>) {
        _shortcut = shortcut
        _capturing = capturing
        let parts = ShortcutRecordingSession.split(shortcut.wrappedValue)
        _modifier = State(initialValue: parts.modifier)
        _key = State(initialValue: parts.key)
    }

    init(shortcut: Binding<RecordedShortcut>, capturing: Binding<Bool>) {
        let optional = Binding<RecordedShortcut?>(
            get: { shortcut.wrappedValue },
            set: { if let value = $0 { shortcut.wrappedValue = value } }
        )
        self.init(shortcut: optional, capturing: capturing)
    }

    private func assemble() {
        shortcut = ShortcutRecordingSession.assembled(modifier: modifier, key: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
            if style == .combined {
                HStack {
                    Text(shortcut?.label ?? "尚未设置快捷键").font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Picker("录制方式", selection: $style) {
                        ForEach(RecordingStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: style) {
                        capturing = false
                        capturingModifier = false
                        capturingKey = false
                    }
                    Button(capturing ? "取消录制" : "录制快捷键") { capturing.toggle() }
                }
                if capturing {
                    Text("按下并松开完整快捷键（可包含多个修饰键）；离开窗口将取消。")
                        .font(.caption).foregroundStyle(Color.accentColor).fixedSize(horizontal: false, vertical: true)
                    ShortcutCapture(mode: .full, onCapture: {
                        shortcut = $0
                        capturing = false
                    }, onCancel: { capturing = false }).frame(height: 1)
                }
            } else {
                HStack {
                    Text("修饰键").font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("录制方式", selection: $style) {
                        ForEach(RecordingStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: style) {
                        capturing = false
                        capturingModifier = false
                        capturingKey = false
                    }
                    Button(capturingModifier ? "取消录制" : (modifier == nil ? "录制修饰键" : "重新录制")) {
                        capturingKey = false
                        capturingModifier.toggle()
                        capturing = capturingModifier
                    }
                }
                HStack {
                    Text(modifier?.label ?? "未设置（可一次录制 ⌃⇧⌥⌘ 中多个键）")
                        .font(.system(size: 13, design: .monospaced))
                    Spacer()
                    if modifier != nil {
                        Button("清除") { modifier = nil; assemble() }
                    }
                }
                if capturingModifier {
                    Text("按下并松开一个或多个修饰键；离开窗口将取消。")
                        .font(.caption).foregroundStyle(Color.accentColor).fixedSize(horizontal: false, vertical: true)
                    ShortcutCapture(mode: .modifiers, onCapture: {
                        modifier = $0
                        capturingModifier = false
                        capturing = false
                        assemble()
                    }, onCancel: {
                        capturingModifier = false
                        capturing = false
                    }).frame(height: 1)
                }

                Divider().padding(.vertical, 2)

                HStack {
                    Text("主键").font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(capturingKey ? "取消录制" : (key == nil ? "录制主键" : "重新录制")) {
                        capturingModifier = false
                        capturingKey.toggle()
                        capturing = capturingKey
                    }
                }
                HStack {
                    Text(key?.label ?? "未设置（如 ←、K、空格）")
                        .font(.system(size: 13, design: .monospaced))
                    Spacer()
                    if key != nil {
                        Button("清除") { key = nil; assemble() }
                    }
                }
                if capturingKey {
                    Text("按下并松开一个普通键；修饰键请在上面单独录制。")
                        .font(.caption).foregroundStyle(Color.accentColor).fixedSize(horizontal: false, vertical: true)
                    ShortcutCapture(mode: .key, onCapture: {
                        key = $0
                        capturingKey = false
                        capturing = false
                        assemble()
                    }, onCancel: {
                        capturingKey = false
                        capturing = false
                    }).frame(height: 1)
                }

                if let shortcut {
                    HStack(spacing: SettingsStyle.Spacing.inline) {
                        Text("组合结果").font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                        Text(shortcut.label).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                }
            }

        }
        .onChange(of: shortcut) {
            guard let newValue = shortcut else {
                if modifier != nil || key != nil { modifier = nil; key = nil }
                return
            }
            guard newValue != ShortcutRecordingSession.assembled(modifier: modifier, key: key) else { return }
            let parts = ShortcutRecordingSession.split(newValue)
            modifier = parts.modifier
            key = parts.key
        }
    }
}

@MainActor
struct ShortcutCapture: NSViewRepresentable {
    var mode: ShortcutRecordingSession.Mode = .full
    var onCapture: (RecordedShortcut) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureField {
        let view = CaptureField(session: ShortcutRecordingSession(mode: mode))
        updateCallbacks(view)
        return view
    }

    func updateNSView(_ view: CaptureField, context: Context) { updateCallbacks(view) }

    private func updateCallbacks(_ view: CaptureField) {
        // Deliver outside the AppKit event / view update stack. A removed recording
        // field must not overwrite a newer recording's state with a late result.
        view.session.onCapture = { [weak view] shortcut in
            view?.deliverIfAttached { onCapture(shortcut) }
        }
        view.onCancel = { [weak view] in
            view?.deliverIfAttached { onCancel() }
        }
    }

    static func dismantleNSView(_ view: CaptureField, coordinator: ()) { view.stopRecording() }

    @MainActor
    final class CaptureField: NSView {
        let session: ShortcutRecordingSession
        var onCancel: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var generation = 0
        override var acceptsFirstResponder: Bool { true }

        init(session: ShortcutRecordingSession) {
            self.session = session
            super.init(frame: .zero)
        }

        override init(frame: NSRect) {
            session = ShortcutRecordingSession()
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopRecording()
            guard let window else { return }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                                   (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelRecording() }
                })
            }
            let generation = generation
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, self.generation == generation else { return }
                guard window.isKeyWindow, NSApp.isActive, window.makeFirstResponder(self) else {
                    self.cancelRecording()
                    return
                }
                self.session.start()
            }
        }

        override func keyDown(with event: NSEvent) { receive(event) }
        override func keyUp(with event: NSEvent) { receive(event) }
        override func flagsChanged(with event: NSEvent) { receive(event) }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, session.isRecording, event.type == .keyDown else { return false }
            return receive(event)
        }

        @discardableResult
        private func receive(_ event: NSEvent) -> Bool {
            guard window?.firstResponder === self, let cgEvent = event.cgEvent else { return false }
            return session.handle(cgEvent.type, event: cgEvent)
        }

        override func resignFirstResponder() -> Bool {
            cancelRecording()
            return super.resignFirstResponder()
        }

        func stopRecording() {
            generation += 1
            session.stop()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        func deliverIfAttached(_ action: @escaping () -> Void) {
            let generation = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.generation == generation else { return }
                action()
            }
        }

        private func cancelRecording() {
            stopRecording()
            onCancel?()
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

import AppKit
import SwiftUI

/// Floating, read-only copy of the mapping canvas. It shows the mapping that
/// is currently in effect (including mouse mode and global buttons) and is
/// dismissed by any remote button or keyboard key.
@MainActor
final class ShortcutHelpController {
    static let defaultPanelSize = NSSize(width: 1120, height: 660)

    private var panel: ShortcutHelpPanel?
    private var hosting: NSHostingView<ShortcutHelpView>?
    private(set) var isPresented = false

    func show(mapping: RemoteMapping,
              profile: RemoteProfile,
              mode: ControllerOperationMode,
              schemeName: String,
              globalInputs: Set<ControllerInput>,
              titleFor: @escaping (ButtonMapping) -> String) {
        let view = ShortcutHelpView(mapping: mapping, profile: profile, mode: mode,
                                    schemeName: schemeName, globalInputs: globalInputs, titleFor: titleFor)
        if panel == nil {
            let panel = ShortcutHelpPanel(contentRect: NSRect(origin: .zero, size: Self.defaultPanelSize),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.onAnyKey = { [weak self] in self?.dismiss() }

            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.masksToBounds = true

            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            panel.contentView = effect
            self.panel = panel
            self.hosting = hosting
        } else {
            hosting?.rootView = view
        }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: max(720, min(Self.defaultPanelSize.width, frame.width - 48)),
                          height: max(420, min(Self.defaultPanelSize.height, frame.height - 48)))
        panel?.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        panel?.invalidateShadow()
        isPresented = true
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        panel?.orderOut(nil)
    }

    var renderView: NSView? { panel?.contentView }
}

@MainActor
struct ShortcutHelpView: View {
    let mapping: RemoteMapping
    let profile: RemoteProfile
    let mode: ControllerOperationMode
    let schemeName: String
    let globalInputs: Set<ControllerInput>
    let titleFor: (ButtonMapping) -> String
    @Environment(\.colorScheme) private var colorScheme

    private var modeTitle: String {
        switch mode {
        case .mapping: "映射模式"
        case .mouse: "鼠标模式"
        case .native: "原生模式"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("快捷键速查 · \(modeTitle) · \(schemeName)", systemImage: "keyboard")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("按任意键关闭")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            GeometryReader { proxy in
                let layout = MappingLayout(size: proxy.size, profile: profile)
                let columnWidth = (proxy.size.width - layout.centerColumnWidth) / 2
                ZStack {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: layout.cardSpacing) {
                            ForEach(layout.leftInputs, id: \.self) { helpCard($0, layout: layout) }
                        }
                        .frame(width: columnWidth)
                        VStack(spacing: SettingsStyle.Spacing.controls) {
                            RemoteArtworkView(pressedInputs: [], connected: true, profile: profile)
                                .frame(width: layout.remoteWidth, height: layout.remoteHeight)
                            Text(profile.model)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: layout.centerColumnWidth)
                        .padding(.top, layout.remoteTop)
                        VStack(spacing: layout.cardSpacing) {
                            ForEach(layout.rightInputs, id: \.self) { helpCard($0, layout: layout) }
                        }
                        .frame(width: columnWidth)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    MappingConnectors(layout: layout, emphasizedInputs: [], pressedInputs: [])
                }
            }
        }
        .padding(SettingsStyle.pagePadding)
    }

    private func helpCard(_ input: ControllerInput, layout: MappingLayout) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsStyle.controlRadius)
        return Group {
            if input == .options { voiceHelpCard(input, layout: layout) }
            else { mappingHelpCard(input, layout: layout) }
        }
        .background(SettingsStyle.subtle, in: shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.07)).allowsHitTesting(false) }
    }

    private func voiceHelpCard(_ input: ControllerInput, layout: MappingLayout) -> some View {
        let shortcut = titleFor(mapping[.options])
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(input.label, systemImage: "mic")
                    .font(.system(size: max(11, 12 * layout.contentScale), weight: .semibold))
                Spacer()
                globalScopeLabel
            }
            Text(shortcut)
                .font(.system(size: max(11, 11 * layout.contentScale)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8 * layout.contentScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.cardHeight)
    }

    private func mappingHelpCard(_ input: ControllerInput, layout: MappingLayout) -> some View {
        VStack(alignment: .leading, spacing: 2 * layout.contentScale) {
            HStack(spacing: 6) {
                Image(systemName: input.symbol)
                Text(input.label).fontWeight(.semibold)
                Spacer()
                if globalInputs.contains(input) { globalScopeLabel }
            }
            .font(.system(size: max(11, 11 * layout.contentScale)))
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                ForEach(input.supportedTriggers) { trigger in
                    let value = mapping[input, trigger]
                    let configured = value.action != .disabled
                    VStack(alignment: .leading, spacing: 0) {
                        Text(trigger.title)
                            .font(.system(size: max(10, 9 * layout.contentScale)))
                            .foregroundStyle(SettingsStyle.mappingTriggerLabel(in: colorScheme))
                        Text(configured ? helpTitle(value) : "– 未设置")
                            .font(.system(size: max(11, 11 * layout.contentScale),
                                          weight: configured ? .semibold : .regular))
                            .foregroundStyle(configured ? Color.primary : SettingsStyle.mappingTriggerLabel(in: colorScheme))
                            .minimumScaleFactor(0.92)
                        if let detail = helpDetail(value.action) {
                            Text(detail)
                                .font(.system(size: max(10, 9 * layout.contentScale),
                                              design: value.action == .rapidDelete ? .default : .monospaced))
                                .foregroundStyle(SettingsStyle.mappingTriggerLabel(in: colorScheme))
                        }
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background {
                        if configured {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08))
                                .padding(.horizontal, 2)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if trigger != .single {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: 1)
                                .padding(.vertical, 3)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8 * layout.contentScale)
        .padding(.vertical, 3 * layout.contentScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.cardHeight)
    }

    private var globalScopeLabel: some View {
        Text("全局")
            .font(SettingsStyle.Typography.caption)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private func helpTitle(_ value: ButtonMapping) -> String {
        switch value.action {
        case .openHarnessSwitcher: "Harness 列表"
        case .showDesktop: "显示桌面"
        case .switchToNativeMode: "原生模式"
        case .rapidDelete: "快速删除"
        case .showAllWindows: "查看所有窗口"
        case .switchApplications: "切换应用"
        default: titleFor(value)
        }
    }

    private func helpDetail(_ action: RemoteAction) -> String? {
        switch action {
        case .rapidDelete: "按住连续退格"
        case .showAllWindows: "⌃ ↑"
        case .switchApplications: "⌘ Tab"
        default: nil
        }
    }
}

@MainActor
private final class ShortcutHelpPanel: NSPanel {
    var onAnyKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { onAnyKey?() }
    override func cancelOperation(_ sender: Any?) { onAnyKey?() }
    override func resignKey() {
        super.resignKey()
        onAnyKey?()
    }
}

import AppKit
import Foundation

/// Brief, nonactivating HUD shown at the screen center when mouse mode starts
/// or ends. It never takes focus, so it cannot steal a click from the user.
@MainActor
final class ModeNoticeController {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String) {
        dismissTask?.cancel()
        if panel == nil { makePanel() }
        guard let panel, let label else { return }
        label.stringValue = message
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: 260, height: 76)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2,
                              y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 260, height: 76)),
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
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16)
        ])
        panel.contentView = effect
        self.panel = panel
        self.label = label
    }
}

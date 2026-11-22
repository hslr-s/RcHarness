import AppKit
import Foundation

/// A translucent ring that follows the system cursor while mouse mode is
/// active. Unlike a fixed badge it never sits on top of a UI control the user
/// wants to click, and it ignores mouse events so it cannot steal a click.
@MainActor
final class MouseModeRingController {
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastPoint: NSPoint?

    func show() {
        if panel == nil { makePanel() }
        guard let panel else { return }
        lastPoint = nil
        updatePosition()
        panel.orderFrontRegardless()
        startTracking()
    }

    func hide() {
        stopTracking()
        lastPoint = nil
        panel?.orderOut(nil)
    }

    private func startTracking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
    }

    private func updatePosition() {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        guard point != lastPoint else { return }
        lastPoint = point
        let size = panel.frame.size
        panel.setFrame(NSRect(x: point.x - size.width / 2,
                              y: point.y - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    private func makePanel() {
        let diameter: CGFloat = 44
        let panel = NSPanel(contentRect: NSRect(origin: .zero,
                                               size: NSSize(width: diameter, height: diameter)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = MouseModeRingView(frame: NSRect(origin: .zero,
                                                            size: NSSize(width: diameter, height: diameter)))
        self.panel = panel
    }
}

/// Draws a soft orange ring with a dark outer stroke so it stays visible on
/// both light and dark backgrounds without obscuring what's underneath.
private final class MouseModeRingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outer = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSColor.black.withAlphaComponent(0.28).setStroke()
        outer.lineWidth = 5
        outer.stroke()

        let inner = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.08, alpha: 0.95).setStroke()
        inner.lineWidth = 2.4
        inner.stroke()
    }
}

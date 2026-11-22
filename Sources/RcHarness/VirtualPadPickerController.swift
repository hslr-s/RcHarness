import AppKit
import SwiftUI

/// Owns the virtual-pad panel and the remote input needed while it is visible.
@MainActor
final class VirtualPadPickerController {
    let model = VirtualPadPickerModel()
    private var panel: VirtualPadPickerPanel?

    init(onAction: @escaping (ButtonMapping, Bool, ControllerInput) -> Void) {
        model.onAction = onAction
        model.onDismiss = { [weak self] in self?.panel?.orderOut(nil) }
    }

    func setTiming(doubleTapWindow: TimeInterval, longPressDelay: TimeInterval) {
        model.setTiming(doubleTapWindow: doubleTapWindow, longPressDelay: longPressDelay)
    }

    func show(scheme: VirtualKeyScheme, titleFor: @escaping (ButtonMapping) -> String) {
        model.present(scheme: scheme, titleFor: titleFor)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = VirtualPadPickerView.panelSize
        if panel == nil {
            let panel = VirtualPadPickerPanel(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.onCancel = { [weak self] in self?.model.dismiss() }
            panel.contentView = NSHostingView(rootView: VirtualPadPickerView(model: model))
            self.panel = panel
        }
        panel?.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    var renderView: NSView? { panel?.contentView }
}

/// Routes input to the five virtual keys, then forwards the resolved action to
/// the normal dispatch. Keys outside the pad dismiss it instead of acting.
@MainActor
final class VirtualPadPickerModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var schemeName = ""
    @Published private(set) var titles: [ControllerInput: String] = [:]
    @Published private(set) var message = "单击 / 双击 / 长按执行对应动作"
    var onAction: ((ButtonMapping, Bool, ControllerInput) -> Void)?
    var onDismiss: (() -> Void)?

    private let schedule: RemoteVoiceSessionController.Scheduler
    private var scheme: VirtualKeyScheme?
    private var heldInputs: Set<ControllerInput> = []
    private var consumedInputs: Set<ControllerInput> = []
    private var trackedInputs: Set<ControllerInput> = []
    /// A nested `.openVirtualPad` presents a new scheme while an action runs.
    /// Per-key generations keep one key's auto-close from affecting another's.
    private var presentationGeneration: UInt64 = 0
    private var actionStartGenerations: [ControllerInput: UInt64] = [:]

    private lazy var gestures: RemoteGestureController = {
        let controller = RemoteGestureController(schedule: schedule)
        controller.onOutput = { [weak self] mapping, pressed, input in
            guard let self else { return }
            if pressed { self.actionStartGenerations[input] = self.presentationGeneration }
            self.onAction?(mapping, pressed, input)
            guard !pressed else { return }
            let started = self.actionStartGenerations.removeValue(forKey: input)
            if started == self.presentationGeneration, self.scheme?.closeAfterAction == true { self.dismiss() }
        }
        return controller
    }()

    init(schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue) {
        self.schedule = schedule
    }

    func setTiming(doubleTapWindow: TimeInterval, longPressDelay: TimeInterval) {
        gestures.setTiming(doubleTapWindow: doubleTapWindow, longPressDelay: longPressDelay)
    }

    func present(scheme: VirtualKeyScheme, titleFor: @escaping (ButtonMapping) -> String) {
        dismiss()
        presentationGeneration &+= 1
        self.scheme = scheme
        titles = Dictionary(uniqueKeysWithValues: VirtualKeyScheme.inputs.compactMap { input in
            scheme.title(for: input, titleFor: titleFor).map { (input, $0) }
        })
        schemeName = scheme.displayName
        message = titles.isEmpty ? "这套方案还没有分配动作" : "单击 / 双击 / 长按执行对应动作"
        // Swallow only the physical press that opened the pad; a virtual key
        // being tracked must still receive its release after a nested present.
        consumedInputs.formUnion(heldInputs.subtracting(trackedInputs))
        isPresented = true
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        onDismiss?()
    }

    func reset() {
        dismiss()
        heldInputs.removeAll()
        consumedInputs.removeAll()
        trackedInputs.removeAll()
        actionStartGenerations.removeAll()
        gestures.cancel()
        scheme = nil
    }

    func cancel(_ input: ControllerInput) {
        heldInputs.remove(input)
        consumedInputs.remove(input)
        trackedInputs.remove(input)
        actionStartGenerations.removeValue(forKey: input)
        gestures.cancel(input)
    }

    /// Observe every edge while presented, and keep tracking a virtual key until
    /// its release so the normal dispatch never sees a half-handled gesture.
    @discardableResult
    func handle(_ input: ControllerInput, pressed: Bool) -> Bool {
        if pressed { heldInputs.insert(input) } else { heldInputs.remove(input) }

        if consumedInputs.contains(input) {
            if !pressed { consumedInputs.remove(input) }
            return true
        }
        if trackedInputs.contains(input) {
            gestures.handle(input, pressed: pressed, mapping: scheme?.mapping ?? RemoteMapping(buttons: [:]))
            if !pressed { trackedInputs.remove(input) }
            return true
        }
        guard isPresented else { return false }
        guard VirtualKeyScheme.inputs.contains(input), let scheme else {
            if pressed {
                consumedInputs.insert(input)
                dismiss()
            }
            return true
        }
        trackedInputs.insert(input)
        gestures.handle(input, pressed: pressed, mapping: scheme.mapping)
        return true
    }
}

@MainActor
struct VirtualPadPickerView: View {
    static let panelSize = NSSize(width: 296, height: 340)
    @ObservedObject var model: VirtualPadPickerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(model.schemeName.isEmpty ? "虚拟按键" : model.schemeName)
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Button { model.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("关闭虚拟按键（其他任意按键 / esc）")
                .accessibilityLabel("关闭虚拟按键")
            }
            .frame(height: 24)
            PhrasePadView(title: { model.titles[$0] ?? "未分配" },
                          isAssigned: { model.titles[$0] != nil }, showsAssignmentMarks: false,
                          diameter: 244) { input in
                _ = model.handle(input, pressed: true)
                _ = model.handle(input, pressed: false)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 2) {
                Text(model.message).foregroundStyle(.secondary)
                Text("其他任意按键 / esc 关闭")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11)).lineLimit(1).frame(height: 32)
        }
        .padding(12)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)) }
    }
}

@MainActor
private final class VirtualPadPickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == VirtualKey.escape { onCancel?() }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func resignKey() {
        super.resignKey()
        onCancel?()
    }
}

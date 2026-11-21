import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class HarnessComposerFocus {
    enum AppState { case waiting, frontmost, exited }
    typealias FocusHandler = (Int32, HarnessFocusTarget, HarnessFocusConfiguration) -> Bool

    private let state: (Int32) -> AppState
    private let focusComposer: FocusHandler
    private let schedule: RemoteVoiceSessionController.Scheduler
    private var configuration = HarnessFocusConfiguration()
    private var pending: DispatchWorkItem?

    init() {
        state = { processID in
            guard let application = NSRunningApplication(processIdentifier: processID),
                  !application.isTerminated else { return .exited }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == processID ? .frontmost : .waiting
        }
        focusComposer = Self.focusInCurrentWindow
        schedule = RemoteVoiceSessionController.mainQueue
    }

    convenience init(state: @escaping (Int32) -> AppState,
                     focusComposer: @escaping (Int32, HarnessFocusTarget) -> Bool,
                     schedule: @escaping RemoteVoiceSessionController.Scheduler) {
        self.init(state: state, focusComposer: { processID, target, _ in focusComposer(processID, target) },
                  schedule: schedule)
    }

    init(state: @escaping (Int32) -> AppState,
         focusComposer: @escaping FocusHandler,
         schedule: @escaping RemoteVoiceSessionController.Scheduler) {
        self.state = state
        self.focusComposer = focusComposer
        self.schedule = schedule
    }

    func start(processID: Int32, target: HarnessFocusTarget,
               configuration: HarnessFocusConfiguration = HarnessFocusConfiguration()) {
        cancel()
        self.configuration = configuration
        attempt(processID: processID, target: target, remaining: 20, wasFrontmost: false)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func attempt(processID: Int32, target: HarnessFocusTarget, remaining: Int, wasFrontmost: Bool) {
        pending = nil
        let current = state(processID)
        guard current != .exited, current == .frontmost || !wasFrontmost else { return }
        if current == .frontmost, focusComposer(processID, target, configuration) { return }
        guard remaining > 1 else { return }
        // The activated window and its web content can appear on different turns.
        pending = schedule(0.25) { [weak self] in
            self?.attempt(processID: processID, target: target, remaining: remaining - 1,
                          wasFrontmost: wasFrontmost || current == .frontmost)
        }
    }

    private struct Candidate {
        let element: AXUIElement
        let descriptor: HarnessComposerTarget
    }

    private static func focusInCurrentWindow(processID: Int32, target: HarnessFocusTarget,
                                              configuration: HarnessFocusConfiguration) -> Bool {
        guard configuration.strategy != .none else { return false }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.1)
        if target != .chatGPT { enableAccessibilityTree(application) }

        if let focused = element(application, kAXFocusedUIElementAttribute),
           isSafeComposer(focused, target: target, configuration: configuration) {
            return true
        }

        var builtInMatches: [AXUIElement] = []
        var candidates: [Candidate] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        for window in applicationWindows(application) {
            let windowTitle = string(window, kAXTitleAttribute)
            let windowFrame = frame(window)
            var stack = [window]
            var visited = 0
            while let node = stack.popLast(), visited < 1_500,
                  ProcessInfo.processInfo.systemUptime < deadline {
                visited += 1
                if isComposer(node, target: target) { builtInMatches.append(node) }
                if let descriptor = composerDescriptor(node, windowTitle: windowTitle, windowFrame: windowFrame) {
                    candidates.append(Candidate(element: node, descriptor: descriptor))
                }
                stack.append(contentsOf: elements(node, kAXChildrenAttribute))
            }
        }

        func focus(_ element: AXUIElement) -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return false }
            guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
            return attribute(element, kAXFocusedAttribute) as? Bool == true
        }

        if builtInMatches.contains(where: focus) { return true }
        switch configuration.strategy {
        case .none:
            return false
        case .recorded:
            guard let recorded = configuration.recorded else { return false }
            if candidates.contains(where: { candidate in
                HarnessComposerCandidate.matches(recorded: recorded, candidate: candidate.descriptor)
                    && focus(candidate.element)
            }) { return true }
            // An app update can invalidate a recorded AX identity. Fall back to
            // the same heuristic used by automatic focus instead of doing nothing.
            fallthrough
        case .automatic:
            let descriptors = candidates.map(\.descriptor)
            guard let index = HarnessComposerCandidate.bestIndex(in: descriptors, windowFrame: nil) else { return false }
            return focus(candidates[index].element)
        }
    }

    /// Reads the current system-wide focused text field; used by input-box recording.
    static func focusedDescriptor() -> HarnessComposerTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = element(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focused, &processIdentifier) == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.1)
        let window = element(focused, kAXWindowAttribute)
        return composerDescriptor(focused,
                                  windowTitle: window.flatMap { string($0, kAXTitleAttribute) } ?? "",
                                  windowFrame: window.flatMap(frame))
    }

    private static func isSafeComposer(_ node: AXUIElement, target: HarnessFocusTarget,
                                        configuration: HarnessFocusConfiguration) -> Bool {
        if isComposer(node, target: target) { return true }
        guard let descriptor = composerDescriptor(node, windowTitle: "", windowFrame: nil) else { return false }
        switch configuration.strategy {
        case .none: return false
        case .recorded:
            return configuration.recorded.map {
                HarnessComposerCandidate.matches(recorded: $0, candidate: descriptor)
            } ?? false
        case .automatic:
            // A search box that happens to be focused is not proof that the
            // conversation composer is ready; keep scanning in that case.
            return false
        }
    }

    private static func enableAccessibilityTree(_ application: AXUIElement) {
        if AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success { return }
        _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static func applicationWindows(_ application: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for window in ([element(application, kAXFocusedWindowAttribute), element(application, kAXMainWindowAttribute)].compactMap { $0 }
                       + elements(application, kAXWindowsAttribute)) {
            if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
        }
        return windows
    }

    private static func composerDescriptor(_ node: AXUIElement, windowTitle: String,
                                            windowFrame: CGRect?) -> HarnessComposerTarget? {
        let role = string(node, kAXRoleAttribute)
        guard HarnessComposerCandidate.editableRoles.contains(role),
              attribute(node, kAXEnabledAttribute) as? Bool != false,
              attribute(node, "AXProtectedContent" as String) as? Bool != true else { return nil }
        let target = HarnessComposerTarget(
            role: role,
            identifier: string(node, kAXIdentifierAttribute),
            title: string(node, kAXTitleAttribute),
            description: string(node, kAXDescriptionAttribute),
            help: string(node, kAXHelpAttribute),
            placeholder: string(node, kAXPlaceholderValueAttribute),
            context: ancestorContext(node),
            windowTitle: windowTitle,
            normalizedFrame: normalizedFrame(frame(node), in: windowFrame)
        )
        guard !target.isSensitive else { return nil }
        return target
    }

    private static func ancestorContext(_ node: AXUIElement) -> String {
        var parts: [String] = []
        var current = node
        for _ in 0..<4 {
            guard let parent = element(current, kAXParentAttribute) else { break }
            parts.append(contentsOf: stringList(parent, "AXDOMClassList"))
            let semantic = [string(parent, kAXIdentifierAttribute), string(parent, kAXTitleAttribute)]
            parts.append(contentsOf: semantic.filter { !$0.isEmpty })
            current = parent
        }
        return String(parts.joined(separator: " ").prefix(256))
    }

    private static func normalizedFrame(_ value: CGRect?, in window: CGRect?) -> HarnessNormalizedFrame? {
        guard let value, let window, window.width > 0, window.height > 0 else { return nil }
        return HarnessNormalizedFrame(
            x: (value.minX - window.minX) / window.width,
            y: (value.minY - window.minY) / window.height,
            width: value.width / window.width,
            height: value.height / window.height
        )
    }

    private static func isComposer(_ node: AXUIElement, target: HarnessFocusTarget) -> Bool {
        guard string(node, kAXRoleAttribute) == kAXTextAreaRole else { return false }
        let classes = stringList(node, "AXDOMClassList")
        switch target {
        case .chatGPT:
            return classes.contains("ProseMirror") && hasAncestor(node, depth: 1) {
                $0 == "ComposerLayoutBody" || $0.hasPrefix("ComposerLayoutBody-")
            }
        case .claude:
            return classes.contains("ProseMirror") && (
                string(node, kAXDescriptionAttribute) == "Prompt"
                    || hasAncestor(node, depth: 6) { $0 == "rounded-composer" }
            )
        case .cursor:
            return classes.contains("ui-prompt-input-editor__input")
        case .deepSeek:
            return hasAncestor(node, depth: 4) { $0.hasSuffix("_composerSeat") }
        case .workBuddy:
            return hasAncestor(node, depth: 3) { $0 == "cr-input-container" }
        case .openCode:
            return hasAncestor(node, depth: 3) { $0 == "group/composer" }
        case .custom:
            return false
        }
    }

    private static func hasAncestor(_ node: AXUIElement, depth: Int, matching: (String) -> Bool) -> Bool {
        var current = node
        for _ in 0..<depth {
            guard let parent = element(current, kAXParentAttribute) else { return false }
            if stringList(parent, "AXDOMClassList").contains(where: matching) { return true }
            current = parent
        }
        return false
    }

    private static func stringList(_ node: AXUIElement, _ name: String) -> [String] {
        attribute(node, name) as? [String] ?? []
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String {
        attribute(node, name) as? String ?? ""
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ node: AXUIElement, _ name: String) -> [AXUIElement] {
        attribute(node, name) as? [AXUIElement] ?? []
    }

    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let pointValue = attribute(node, kAXPositionAttribute),
              CFGetTypeID(pointValue) == AXValueGetTypeID(),
              let sizeValue = attribute(node, kAXSizeAttribute),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pointValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }
}

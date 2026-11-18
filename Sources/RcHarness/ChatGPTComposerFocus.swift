import AppKit
import ApplicationServices

@MainActor
final class ChatGPTComposerFocus {
    enum AppState { case waiting, frontmost, exited }

    private let state: (Int32) -> AppState
    private let focusComposer: (Int32) -> Bool
    private let schedule: RemoteVoiceSessionController.Scheduler
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

    init(state: @escaping (Int32) -> AppState, focusComposer: @escaping (Int32) -> Bool,
         schedule: @escaping RemoteVoiceSessionController.Scheduler) {
        self.state = state
        self.focusComposer = focusComposer
        self.schedule = schedule
    }

    func start(processID: Int32) {
        cancel()
        attempt(processID: processID, remaining: 20, wasFrontmost: false)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func attempt(processID: Int32, remaining: Int, wasFrontmost: Bool) {
        pending = nil
        let current = state(processID)
        guard current != .exited, current == .frontmost || !wasFrontmost else { return }
        if current == .frontmost, focusComposer(processID) { return }
        guard remaining > 1 else { return }
        // The activated window and its web content can appear on different turns.
        pending = schedule(0.25) { [weak self] in
            self?.attempt(processID: processID, remaining: remaining - 1,
                          wasFrontmost: wasFrontmost || current == .frontmost)
        }
    }

    private static func focusInCurrentWindow(processID: Int32) -> Bool {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.1)
        if let focused = element(application, kAXFocusedUIElementAttribute), isComposer(focused) { return true }
        guard let window = element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute) else {
            return false
        }

        // Visit the bottom of the conversation before walking its transcript.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var nodes = [window]
        for _ in 0..<1_500 {
            guard ProcessInfo.processInfo.systemUptime < deadline, let node = nodes.popLast() else { return false }
            if isComposer(node) {
                guard attribute(node, kAXEnabledAttribute) as? Bool != false,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return false }
                let result = AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return result == .success && attribute(node, kAXFocusedAttribute) as? Bool == true
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                nodes.append(contentsOf: children)
            }
        }
        return false
    }

    private static func isComposer(_ node: AXUIElement) -> Bool {
        guard attribute(node, kAXRoleAttribute) as? String == kAXTextAreaRole,
              (attribute(node, "AXDOMClassList") as? [String])?.contains("ProseMirror") == true,
              let parent = element(node, kAXParentAttribute) else { return false }
        // The conversation composer has a dedicated container. Other text areas
        // can belong to search, settings or an editor elsewhere in the window.
        return (attribute(parent, "AXDOMClassList") as? [String])?
            .contains { $0 == "ComposerLayoutBody" || $0.hasPrefix("ComposerLayoutBody-") } == true
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }
}

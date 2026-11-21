import CoreGraphics
import Foundation

struct HarnessNormalizedFrame: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum HarnessFocusStrategy: String, Codable, CaseIterable, Identifiable {
    case automatic
    case recorded
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "自动识别"
        case .recorded: "使用记录的输入框"
        case .none: "只打开应用"
        }
    }
}

/// The portable description of a composer. It contains no AX element reference
/// so it can be persisted, exported and scored in unit tests.
struct HarnessComposerTarget: Codable, Equatable, Hashable {
    var role: String
    var identifier: String
    var title: String
    var description: String
    var help: String
    var placeholder: String
    var context: String
    var windowTitle: String
    var normalizedFrame: HarnessNormalizedFrame?

    init(role: String = "", identifier: String = "", title: String = "", description: String = "",
         help: String = "", placeholder: String = "", context: String = "", windowTitle: String = "",
         normalizedFrame: HarnessNormalizedFrame? = nil) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.description = description
        self.help = help
        self.placeholder = placeholder
        self.context = context
        self.windowTitle = windowTitle
        self.normalizedFrame = normalizedFrame
    }

    var semanticText: String {
        [identifier, title, description, help, placeholder, context, windowTitle]
            .joined(separator: " ")
    }

    var isEditable: Bool { HarnessComposerCandidate.editableRoles.contains(role) }

    var isSensitive: Bool { HarnessComposerCandidate.isSensitive(semanticText) }
}

struct HarnessFocusConfiguration: Equatable {
    var strategy: HarnessFocusStrategy = .automatic
    var recorded: HarnessComposerTarget? = nil
}

/// Ported from SayAll's composer scoring: a search field may be a legitimate
/// target, but password/token/address-bar-like fields never are.
enum HarnessComposerCandidate {
    static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    private static let sensitiveTerms = [
        "password", "passcode", "secret", "api key", "apikey", "token", "credit card",
        "密码", "口令", "密钥", "令牌", "银行卡",
    ]

    private static let excludedTerms = [
        "title", "rename", "api key", "apikey", "token", "password", "secret",
        "command palette", "address bar", "approval", "permission", "code editor", "monaco",
        "标题", "重命名", "密钥", "令牌", "密码", "审批", "权限", "代码编辑器",
    ]

    private static let strongTerms = [
        "composer", "prompt-editor", "prompt_editor", "chat-input", "chat_input",
        "message-input", "message_input", "prompt input", "message input",
        "消息输入", "输入消息", "发送消息",
    ]

    private static let supportingTerms = [
        "message", "prompt", "reply", "ask claude", "ask anything", "chat", "提问", "回复",
    ]

    private static let allowedTerms = [
        "search", "find", "filter", "settings", "preferences", "terminal", "console", "shell", "xterm",
        "搜索", "查找", "筛选", "设置", "偏好", "终端", "控制台",
    ]

    static func isSensitive(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return sensitiveTerms.contains { lowercased.contains($0) }
    }

    static func score(_ candidate: HarnessComposerTarget, windowFrame: CGRect?) -> Int? {
        guard candidate.isEditable, !candidate.isSensitive else { return nil }
        let text = candidate.semanticText.lowercased()
        guard !excludedTerms.contains(where: text.contains) else { return nil }

        let hasStrong = strongTerms.contains(where: text.contains)
        let hasSupporting = supportingTerms.contains(where: text.contains)
        let hasAllowed = allowedTerms.contains(where: text.contains)
        guard candidate.role == "AXTextArea" || hasStrong || hasSupporting || hasAllowed else { return nil }

        var score = candidate.role == "AXTextArea" ? 50 : 0
        if hasStrong { score += 120 }
        else if hasSupporting { score += 70 }
        else if hasAllowed { score += 80 }

        if let frame = candidate.normalizedFrame {
            if frame.width >= 0.6 { score += 25 }
            if (0.03...0.7).contains(frame.height) { score += 10 }
            if frame.y > 0.4 { score += 15 }
        }
        if windowFrame == nil { score -= 1 }
        return score
    }

    static func bestIndex(in candidates: [HarnessComposerTarget], windowFrame: CGRect?) -> Int? {
        var best: (index: Int, score: Int)?
        for (index, candidate) in candidates.enumerated() {
            guard let value = score(candidate, windowFrame: windowFrame) else { continue }
            if best.map({ value > $0.score }) ?? true { best = (index, value) }
        }
        return best?.index
    }

    /// A recorded target wins when its semantic identity is still present.
    /// Window titles and frames may change, so they are hints, not hard gates.
    static func matches(recorded: HarnessComposerTarget, candidate: HarnessComposerTarget) -> Bool {
        guard candidate.isEditable, !candidate.isSensitive else { return false }
        if !recorded.role.isEmpty, recorded.role != candidate.role { return false }
        let recordedIdentity = identityTokens(of: recorded)
        if recordedIdentity.isEmpty {
            if recorded.windowTitle.isEmpty || candidate.windowTitle.isEmpty { return true }
            return recorded.windowTitle.localizedCaseInsensitiveCompare(candidate.windowTitle) == .orderedSame
        }
        let candidateIdentity = identityTokens(of: candidate)
        return recordedIdentity.allSatisfy { token in
            candidateIdentity.contains { $0.contains(token) || token.contains($0) }
        }
    }

    private static func identityTokens(of target: HarnessComposerTarget) -> [String] {
        [target.identifier, target.title, target.placeholder, target.context, target.description]
            .flatMap { $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 2 }
    }
}

import Foundation

struct MacroTag: Codable, Identifiable, Equatable {
    let id: String
    let name: String

    static let general = Self(id: "general", name: "通用")
    /// Built-in labels are independent of configured or active Harnesses.
    static let all = [general] + HarnessConfiguration.defaults.map { Self(id: $0.id, name: $0.name) }

    static func validatedName(_ name: String, in catalog: [Self], excluding id: String? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacroTagError.emptyName }
        guard !catalog.contains(where: {
            $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }) else { throw MacroTagError.duplicateName }
        return trimmed
    }

    static func validatedCustomTags(_ tags: [Self]) throws -> [Self] {
        var catalog = all
        var ids = Set(catalog.map(\.id))
        for tag in tags {
            guard !tag.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  HarnessConfiguration.migratingRenamedID(tag.id) == tag.id,
                  ids.insert(tag.id).inserted else { throw SettingsBackupError.invalidFormat }
            catalog.append(Self(id: tag.id, name: try validatedName(tag.name, in: catalog)))
        }
        return Array(catalog.dropFirst(all.count))
    }
}

enum MacroTagError: LocalizedError {
    case emptyName
    case duplicateName
    case builtIn
    case missing

    var errorDescription: String? {
        switch self {
        case .emptyName: "请输入标签名称。"
        case .duplicateName: "已存在同名标签，请使用其他名称。"
        case .builtIn: "内置标签为只读。"
        case .missing: "此标签已删除。"
        }
    }
}

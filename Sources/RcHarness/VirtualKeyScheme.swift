import Foundation

/// One named set of five virtual keys. Each key keeps the same single/double/long
/// gesture model as a physical remote button, so any remote action can be used.
struct VirtualKeyScheme: Codable, Identifiable, Equatable {
    static let inputs: [ControllerInput] = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight, .buttonA]

    var id = UUID()
    var name: String
    /// Close the modal pad once a virtual key resolves its action.
    var closeAfterAction: Bool
    var mapping: RemoteMapping

    init(id: UUID = UUID(), name: String = "新方案", closeAfterAction: Bool = true,
         mapping: RemoteMapping = .virtualPadDefaults) {
        self.id = id
        self.name = name
        self.closeAfterAction = closeAfterAction
        self.mapping = mapping
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, closeAfterAction, mapping
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "新方案"
        closeAfterAction = try values.decodeIfPresent(Bool.self, forKey: .closeAfterAction) ?? true
        mapping = try values.decodeIfPresent(RemoteMapping.self, forKey: .mapping) ?? .virtualPadDefaults
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名方案" : name
    }

    subscript(_ input: ControllerInput, _ trigger: ButtonTrigger) -> ButtonMapping {
        get {
            guard Self.inputs.contains(input) else { return ButtonMapping(action: .disabled) }
            return mapping[input, trigger]
        }
        set {
            guard Self.inputs.contains(input) else { return }
            mapping[input, trigger] = newValue
        }
    }

    /// The label shown on the compact pad: prefer single, then the first usable trigger.
    func title(for input: ControllerInput, titleFor: (ButtonMapping) -> String) -> String? {
        for trigger in ButtonTrigger.allCases {
            let value = self[input, trigger]
            if value.action != .disabled { return titleFor(value) }
        }
        return nil
    }

    static let defaults: [VirtualKeyScheme] = [
        VirtualKeyScheme(id: UUID(uuidString: "5E1F7C20-8A3B-4D6E-9F12-0B7C4A8E2D31")!,
                         name: "媒体控制", closeAfterAction: true, mapping: .virtualPadDefaults)
    ]
}

extension RemoteMapping {
    /// Out-of-the-box bindings for the first virtual scheme.
    static let virtualPadDefaults: RemoteMapping = {
        var result = RemoteMapping(buttons: [:])
        result[.dpadUp, .single] = ButtonMapping(action: .volumeUp)
        result[.dpadUp, .double] = ButtonMapping(action: .mute)
        result[.dpadDown, .single] = ButtonMapping(action: .volumeDown)
        result[.dpadDown, .double] = ButtonMapping(action: .mute)
        result[.dpadLeft, .single] = ButtonMapping(action: .previousTrack)
        result[.dpadRight, .single] = ButtonMapping(action: .nextTrack)
        result[.dpadRight, .double] = ButtonMapping(action: .browserForward)
        result[.buttonA, .single] = ButtonMapping(action: .playPause)
        result[.buttonA, .double] = ButtonMapping(action: .escape)
        return result
    }()
}

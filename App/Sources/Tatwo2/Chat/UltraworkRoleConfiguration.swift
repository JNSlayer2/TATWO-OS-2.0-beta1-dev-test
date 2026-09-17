import Foundation

struct UltraworkRoleConfiguration: Codable, Equatable {
    var primaryModelID: String
    var auxiliaryModelIDs: [String]

    /// 與憲法 §4 一致，改表先改憲法。模型 ID 沿用路由命名；
    /// gpt-6-astra = GPT-6，grok-build = Grok 4.6。審查使用與主導不同家的 GPT-6。
    static let constitutionSection4 = (
        lead: "fable-5.1",
        loops: "gpt-6-astra",
        refinement: "opus-5",
        mechanic: "grok-build",
        reviewer: "gpt-6-astra"
    )

    static let defaultValue = UltraworkRoleConfiguration(
        primaryModelID: constitutionSection4.lead,
        auxiliaryModelIDs: [
            constitutionSection4.loops,
            constitutionSection4.refinement,
            constitutionSection4.mechanic,
            constitutionSection4.reviewer,
        ])

    static func auxiliaryCount(for level: ChatCollaborationLevel) -> Int {
        switch level {
        case .off, .s:
            return 0
        case .m:
            return 1
        case .l:
            return 2
        case .xl:
            return 3
        case .xxl:
            return 4
        }
    }

    mutating func setPrimary(_ modelID: String) {
        primaryModelID = modelID
    }

    mutating func setAuxiliary(_ modelID: String, at index: Int) {
        guard index >= 0 else { return }
        while auxiliaryModelIDs.count <= index {
            auxiliaryModelIDs.append(Self.defaultValue.auxiliaryModelIDs[
                min(auxiliaryModelIDs.count, Self.defaultValue.auxiliaryModelIDs.count - 1)
            ])
        }
        auxiliaryModelIDs[index] = modelID
    }

    func auxiliaryModelID(at index: Int) -> String {
        guard index >= 0 else { return Self.defaultValue.auxiliaryModelIDs[0] }
        if auxiliaryModelIDs.indices.contains(index) {
            return auxiliaryModelIDs[index]
        }
        return Self.defaultValue.auxiliaryModelIDs[
            min(index, Self.defaultValue.auxiliaryModelIDs.count - 1)
        ]
    }
}

struct UltraworkRoleConfigurationStore {
    static let appWideKey = "tatwo.ultrawork.last-role-configuration.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> UltraworkRoleConfiguration {
        guard let data = defaults.data(forKey: Self.appWideKey),
              let value = try? JSONDecoder().decode(
                UltraworkRoleConfiguration.self,
                from: data)
        else {
            return .defaultValue
        }
        return value
    }

    func save(_ configuration: UltraworkRoleConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.appWideKey)
    }
}

enum UltraworkRoleSlot: Hashable {
    case primary
    case auxiliary(Int)

    var label: String {
        switch self {
        case .primary:
            return "主"
        case let .auxiliary(index):
            return "輔\(index + 1)"
        }
    }
}

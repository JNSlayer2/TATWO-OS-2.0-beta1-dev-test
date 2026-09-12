import Foundation

public struct TatwoPluginRegistryPartition: Equatable, Sendable {
    public let mcp: [PluginRegistryEntry]
    public let skills: [PluginRegistryEntry]
    public let other: [PluginRegistryEntry]

    public init(
        mcp: [PluginRegistryEntry],
        skills: [PluginRegistryEntry],
        other: [PluginRegistryEntry]
    ) {
        self.mcp = mcp
        self.skills = skills
        self.other = other
    }

    public static func make(_ entries: [PluginRegistryEntry]) -> TatwoPluginRegistryPartition {
        var mcp: [PluginRegistryEntry] = []
        var skills: [PluginRegistryEntry] = []
        var other: [PluginRegistryEntry] = []
        for entry in entries {
            switch entry.kind {
            case .mcp:
                mcp.append(entry)
            case .skill:
                skills.append(entry)
            default:
                other.append(entry)
            }
        }
        return TatwoPluginRegistryPartition(mcp: mcp, skills: skills, other: other)
    }
}

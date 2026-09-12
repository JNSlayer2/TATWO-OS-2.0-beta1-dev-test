import Foundation

/// network is persisted for the App; it is not a network enforcement mechanism.
struct BotPermissions: Codable, Equatable {
    var approval: String = "ask"
    var mcp: [String] = []
    var folders: [String] = []
    var network: Bool = false

    func resolve(registeredMCP: [String]) -> (enabledMCP: [String], approval: TatwoPermissionPreset, folders: [String]) {
        let preset: TatwoPermissionPreset
        switch approval {
        case "auto": preset = .approveForMe
        case "full": preset = .fullAccess
        default: preset = .askFirst
        }
        return (mcp.filter { registeredMCP.contains($0) }, preset, folders)
    }

    /// Component-boundary check, including symlink resolution. Not an OS sandbox.
    func allows(path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return folders.contains { folder in
            let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
            return candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }
}

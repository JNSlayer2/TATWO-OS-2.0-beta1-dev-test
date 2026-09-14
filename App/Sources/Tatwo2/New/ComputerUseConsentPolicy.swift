/// App-owned permission resolution; MCP arguments never select a policy.
enum TatwoAgentConsentPolicy: Equatable {
    case autoAllow(clearOnHumanInput: Bool)
    case askOncePerSession

    static func resolve(user: TatwoPermissionPreset?, bot: TatwoPermissionPreset?, readOnly: Bool) -> Self {
        guard !readOnly else { return .askOncePerSession }
        let effective = bot == .configFile ? user : (bot ?? user)
        switch effective {
        case .fullAccess: return .autoAllow(clearOnHumanInput: false)
        case .approveForMe: return .autoAllow(clearOnHumanInput: true)
        default: return .askOncePerSession
        }
    }

    var clearOnHumanInput: Bool {
        switch self {
        case .autoAllow(let clear): return clear
        case .askOncePerSession: return true
        }
    }
}

// W44 compatibility: both lanes resolve the same app-owned caller policy.
typealias ComputerUseConsentPolicy = TatwoAgentConsentPolicy

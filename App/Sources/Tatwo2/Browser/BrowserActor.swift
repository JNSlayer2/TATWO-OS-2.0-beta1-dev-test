import Foundation

enum BrowserActor: Equatable, Sendable {
    case human
    case agent(callerID: UUID, preset: TatwoPermissionPreset?)

    // Legacy entry points fail closed; only a human surface opts in.
    static let strict = BrowserActor.agent(callerID: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), preset: nil)
}

struct BrowserSecuritySettings: Codable, Equatable, Sendable {
    var blocksThirdPartyCookies = true
    var adBlock = true

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TATWO OS/Browser/security.json")
    }
    static func load(from url: URL = fileURL) -> Self {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(to url: URL = Self.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

struct BrowserActorPolicy: Equatable, Sendable {
    enum PopupBehavior: Equatable, Sendable { case openAsTab, block }
    enum SensitivePermissionBehavior: Equatable, Sendable { case askViaIsland, deny }
    enum PrivateNetworkBehavior: Equatable, Sendable { case askOncePerHost, block }
    var allowsDownloads: Bool
    var popupBehavior: PopupBehavior
    var sensitivePermissions: SensitivePermissionBehavior
    var privateNetwork: PrivateNetworkBehavior
    var passwordManager: Bool
    var autofill: Bool
    var blocksThirdPartyCookies: Bool
    var adBlock: Bool

    static func resolve(actor: BrowserActor, settings: BrowserSecuritySettings) -> Self {
        let human = actor == .human
        if human { BrowserPolicyLog.shared.record(decision: "actor.human.downloadsAndPopupsAllowed.permissionsAndPrivateNetworkAsk", actor: "human") }
        return Self(allowsDownloads: human, popupBehavior: human ? .openAsTab : .block,
                    sensitivePermissions: human ? .askViaIsland : .deny,
                    privateNetwork: human ? .askOncePerHost : .block,
                    passwordManager: human, autofill: human,
                    blocksThirdPartyCookies: !human || settings.blocksThirdPartyCookies,
                    adBlock: settings.adBlock)
    }
}

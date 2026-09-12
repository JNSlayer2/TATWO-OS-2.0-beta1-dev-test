import Foundation

/// R3 暫用的設備讀取形狀；R1 合流後以配對房間的正式資料型別為準。
struct RemoteDeviceRef: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let host: String
    let user: String
    let sshPort: Int
    let publicKeyFingerprint: String?
    let addedAt: String?
    let lastSeenAt: String?
    let workdirMap: [String: String]

    var sshTarget: String { "\(user)@\(host)" }

    func sidecarPath(for kind: ClaudeSidecar.Kind) -> String {
        "~/.tatwo2/engines/\(kind.rawValue)-sidecar/sidecar.mjs"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, user, sshPort, publicKeyFingerprint, addedAt, lastSeenAt, workdirMap
    }

    init(
        id: String,
        name: String,
        host: String,
        user: String,
        sshPort: Int = 22,
        publicKeyFingerprint: String? = nil,
        addedAt: String? = nil,
        lastSeenAt: String? = nil,
        workdirMap: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.publicKeyFingerprint = publicKeyFingerprint
        self.addedAt = addedAt
        self.lastSeenAt = lastSeenAt
        self.workdirMap = workdirMap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        user = try c.decode(String.self, forKey: .user)
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        publicKeyFingerprint = try c.decodeIfPresent(String.self, forKey: .publicKeyFingerprint)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        lastSeenAt = try c.decodeIfPresent(String.self, forKey: .lastSeenAt)
        workdirMap = try c.decodeIfPresent([String: String].self, forKey: .workdirMap) ?? [:]
    }
}

enum RemoteDeviceLookupError: Error, CustomStringConvertible {
    case unreadable(String)
    case deviceNotFound(String)

    var description: String {
        switch self {
        case .unreadable(let detail): return "讀不到設備清單：\(detail)"
        case .deviceNotFound(let id): return "找不到設備：\(id)"
        }
    }
}

struct RemoteDeviceLookup {
    let url: URL

    init(root: URL? = nil) {
        let base: URL
        if let root {
            base = root
        } else if let override = ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        }
        url = base.appendingPathComponent("devices.json")
    }

    func devices() throws -> [RemoteDeviceRef] {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([RemoteDeviceRef].self, from: data)
        } catch {
            throw RemoteDeviceLookupError.unreadable(error.localizedDescription)
        }
    }

    func device(id: String) throws -> RemoteDeviceRef {
        guard let ref = try devices().first(where: { $0.id == id }) else {
            throw RemoteDeviceLookupError.deviceNotFound(id)
        }
        return ref
    }
}

/// OpenSSH 會把 target 後面的 argv 重新接成一條遠端 shell command；動態值必須自行 quote。
func remoteShellQuote(_ value: String, expandHome: Bool = false) -> String {
    if expandHome, value.hasPrefix("~/"),
       value.dropFirst(2).allSatisfy({ $0.isLetter || $0.isNumber || "/._-".contains($0) }) {
        return value
    }
    if !value.isEmpty,
       value.allSatisfy({ $0.isLetter || $0.isNumber || "/._:@%+=,-".contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

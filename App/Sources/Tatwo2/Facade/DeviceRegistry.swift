import CryptoKit
import Darwin
import Foundation

/// An address is a route, never a device identity or a source of trust.
struct DeviceEndpoint: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case lan, tunnel, alias }
    var kind: Kind
    var host: String = ""
    var port: Int = 22
    var alias: String? = nil

    var label: String { kind == .alias ? "alias:" + (alias ?? "") : "\(host):\(port)" }
    var isValid: Bool {
        func safe(_ text: String) -> Bool {
            !text.isEmpty && !text.hasPrefix("-") && text.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:").contains($0)
            }
        }
        return kind == .alias ? safe(alias ?? "") && !(alias ?? "").contains(":")
            : safe(host) && (1...65535).contains(port)
    }

    static func parse(_ input: String, kind: Kind = .lan) throws -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = Self(kind: kind)
        if text.hasPrefix("alias:") {
            value = Self(kind: .alias, alias: String(text.dropFirst(6)))
        } else if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
            value.host = String(text[text.index(after: text.startIndex)..<end])
            let suffix = String(text[text.index(after: end)...])
            guard suffix.isEmpty || (suffix.hasPrefix(":") && Int(suffix.dropFirst()) != nil) else {
                throw DeviceRegistry.RegistryError.invalidEndpoint
            }
            value.port = suffix.isEmpty ? 22 : Int(suffix.dropFirst())!
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw DeviceRegistry.RegistryError.invalidEndpoint }
            value.host = String(parts[0])
            if parts.count == 2 { value.port = Int(parts[1]) ?? 0 }
        }
        guard value.isValid else { throw DeviceRegistry.RegistryError.invalidEndpoint }
        return value
    }
}

extension DeviceEndpoint {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
                  host: try c.decodeIfPresent(String.self, forKey: .host) ?? "",
                  port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 22,
                  alias: try c.decodeIfPresent(String.self, forKey: .alias))
        guard isValid else { throw DeviceRegistry.RegistryError.invalidEndpoint }
    }
}

/// 一把指紋是怎麼來的、什麼時候記的。只是佐證紀錄，不參與任何信任判斷。
struct DeviceFingerprintProvenance: Codable, Equatable, Sendable {
    /// pairing／known_hosts／rpc_proof／legacy_authorized_keys／legacy_known_hosts
    var source: String
    var recordedAt: Date
}

struct DeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var host: String
    var user: String
    var sshPort: Int
    var publicKeyFingerprint: String
    var addedAt: Date
    var lastSeenAt: Date
    var workdirMap: [String: String]
    var lanHost: String? = nil
    // Missing legacy fields mean unknown, never primary / epoch zero.
    var role: DeviceRole? = nil
    var epoch: Int? = nil
    var endpoints: [DeviceEndpoint]
    var retiredEndpoints: [DeviceEndpoint] = []
    var lastEndpoint: DeviceEndpoint? = nil
    // 對方有兩把不同用途的公鑰：主機金鑰（建隧道要 pin 的）與客戶端金鑰（驗 RPC 簽章的）。
    // 舊欄 `publicKeyFingerprint` 依配對方向只會存到其中一把，所以分成兩欄。
    var hostKeyFingerprint: String? = nil
    var clientKeyFingerprint: String? = nil
    var hostKeyFingerprintSource: DeviceFingerprintProvenance? = nil
    var clientKeyFingerprintSource: DeviceFingerprintProvenance? = nil
    /// 舊紀錄推定不出方向：兩把皆空，等下次配對或成功連線補齊。
    var needsFingerprintRepair: Bool = false

    /// 隧道只認主機金鑰。分流過的紀錄缺 host 就是缺，絕不拿客戶端金鑰頂替；
    /// 完全沒分流過的舊紀錄沿用舊欄（跟分流前同一個值、同樣的比對），不放寬也不收緊。
    var pinnedHostKeyFingerprint: String? {
        if let hostKeyFingerprint { return hostKeyFingerprint }
        guard clientKeyFingerprint == nil, !publicKeyFingerprint.isEmpty else { return nil }
        return publicKeyFingerprint
    }

    /// RPC 簽章只認客戶端金鑰，同上規則。
    var pinnedClientKeyFingerprint: String? {
        if let clientKeyFingerprint { return clientKeyFingerprint }
        guard hostKeyFingerprint == nil, !publicKeyFingerprint.isEmpty else { return nil }
        return publicKeyFingerprint
    }

    var orderedEndpoints: [DeviceEndpoint] {
        [.lan, .tunnel, .alias].flatMap { kind in
            endpoints.filter { $0.kind == kind && $0.isValid && !retiredEndpoints.contains($0) }
        }
    }

    init(id: String, name: String, host: String, user: String, sshPort: Int,
         publicKeyFingerprint: String, addedAt: Date, lastSeenAt: Date,
         workdirMap: [String: String], lanHost: String? = nil, role: DeviceRole? = nil,
         epoch: Int? = nil, endpoints: [DeviceEndpoint]? = nil,
         retiredEndpoints: [DeviceEndpoint] = [], lastEndpoint: DeviceEndpoint? = nil,
         hostKeyFingerprint: String? = nil, clientKeyFingerprint: String? = nil,
         hostKeyFingerprintSource: DeviceFingerprintProvenance? = nil,
         clientKeyFingerprintSource: DeviceFingerprintProvenance? = nil,
         needsFingerprintRepair: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.user = user; self.sshPort = sshPort
        self.publicKeyFingerprint = publicKeyFingerprint; self.addedAt = addedAt
        self.lastSeenAt = lastSeenAt; self.workdirMap = workdirMap; self.lanHost = lanHost
        self.role = role; self.epoch = epoch
        self.endpoints = endpoints ?? [.init(kind: .lan, host: host, port: sshPort)]
        self.retiredEndpoints = retiredEndpoints; self.lastEndpoint = lastEndpoint
        self.hostKeyFingerprint = hostKeyFingerprint; self.clientKeyFingerprint = clientKeyFingerprint
        self.hostKeyFingerprintSource = hostKeyFingerprintSource
        self.clientKeyFingerprintSource = clientKeyFingerprintSource
        self.needsFingerprintRepair = needsFingerprintRepair
        syncLegacyAddress()
    }

    mutating func syncLegacyAddress() {
        if let first = endpoints.first(where: { $0.kind == .lan && !retiredEndpoints.contains($0) }) {
            host = first.host; sshPort = first.port
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, user, sshPort, publicKeyFingerprint, addedAt, lastSeenAt, workdirMap
        case lanHost, role, epoch, endpoints, retiredEndpoints, lastEndpoint
        case hostKeyFingerprint, clientKeyFingerprint
        case hostKeyFingerprintSource, clientKeyFingerprintSource, needsFingerprintRepair
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
            host: try c.decode(String.self, forKey: .host), user: try c.decode(String.self, forKey: .user),
            sshPort: try c.decode(Int.self, forKey: .sshPort),
            publicKeyFingerprint: try c.decode(String.self, forKey: .publicKeyFingerprint),
            addedAt: try c.decode(Date.self, forKey: .addedAt), lastSeenAt: try c.decode(Date.self, forKey: .lastSeenAt),
            workdirMap: try c.decode([String: String].self, forKey: .workdirMap),
            lanHost: try c.decodeIfPresent(String.self, forKey: .lanHost),
            role: try c.decodeIfPresent(DeviceRole.self, forKey: .role), epoch: try c.decodeIfPresent(Int.self, forKey: .epoch),
            endpoints: try c.decodeIfPresent([DeviceEndpoint].self, forKey: .endpoints),
            retiredEndpoints: try c.decodeIfPresent([DeviceEndpoint].self, forKey: .retiredEndpoints) ?? [],
            lastEndpoint: try c.decodeIfPresent(DeviceEndpoint.self, forKey: .lastEndpoint),
            hostKeyFingerprint: try c.decodeIfPresent(String.self, forKey: .hostKeyFingerprint),
            clientKeyFingerprint: try c.decodeIfPresent(String.self, forKey: .clientKeyFingerprint),
            hostKeyFingerprintSource: try c.decodeIfPresent(
                DeviceFingerprintProvenance.self, forKey: .hostKeyFingerprintSource),
            clientKeyFingerprintSource: try c.decodeIfPresent(
                DeviceFingerprintProvenance.self, forKey: .clientKeyFingerprintSource),
            needsFingerprintRepair: try c.decodeIfPresent(Bool.self, forKey: .needsFingerprintRepair) ?? false)
    }
}

/// `live/devices.json` 是 2.0 遠端設備的唯一薄登記表；SSH authorized_keys 才是信任真值。
final class DeviceRegistry: @unchecked Sendable {
    enum RegistryError: Error, LocalizedError {
        case invalidEndpoint
        case invalidDeviceID
        case invalidPublicKey
        case deviceNotFound
        case pairingIdentityConflict
        case fingerprintConflict

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "invalid_device_endpoint"
            case .invalidDeviceID: "invalid_device_id"
            case .invalidPublicKey: "invalid_public_key"
            case .deviceNotFound: "device_not_found"
            case .pairingIdentityConflict: "pairing_identity_conflict"
            case .fingerprintConflict: "device_fingerprint_conflict"
            }
        }
    }

    let root: URL
    let url: URL
    let authorizedKeysURL: URL
    /// 只讀，用來判斷舊紀錄那把指紋是主機金鑰還是客戶端金鑰；不寫入、不新增信任。
    let knownHostsURL: URL
    // UI edits and successful background links create separate registry instances.
    // Serialize their read-modify-write cycles so a touch cannot erase an endpoint edit.
    private static let storageLock = NSLock()
    private var lock: NSLock { Self.storageLock }

    init(
        root: URL? = nil,
        authorizedKeysURL: URL? = nil,
        knownHostsURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.root = root
            ?? environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        self.url = self.root.appendingPathComponent("devices.json")
        self.authorizedKeysURL = authorizedKeysURL
            ?? environment["TATWO2_AUTHORIZED_KEYS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/authorized_keys")
        self.knownHostsURL = knownHostsURL
            ?? (environment["TATWO2_SSH_KNOWN_HOSTS"] ?? environment["TATWO2_KNOWN_HOSTS"])
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/known_hosts")
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func list() -> [DeviceRecord] {
        lock.withLock { (try? readUnlocked()) ?? [] }
    }

    @discardableResult
    func add(_ record: DeviceRecord) throws -> DeviceRecord {
        guard Self.isSafeDeviceID(record.id) else { throw RegistryError.invalidDeviceID }
        return try lock.withLock {
            var rows = try readUnlocked()
            if let index = rows.firstIndex(where: { $0.id == record.id }) {
                rows[index] = record
            } else {
                rows.append(record)
            }
            try writeUnlocked(rows)
            return record
        }
    }

    @discardableResult
    func add(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        host: String,
        user: String,
        sshPort: Int = 22,
        publicKeyFingerprint: String,
        now: Date = Date(),
        workdirMap: [String: String] = [:],
        lanHost: String? = nil,
        role: DeviceRole? = nil,
        epoch: Int? = nil,
        hostKeyFingerprint: String? = nil,
        clientKeyFingerprint: String? = nil,
        hostKeyFingerprintSource: DeviceFingerprintProvenance? = nil,
        clientKeyFingerprintSource: DeviceFingerprintProvenance? = nil
    ) throws -> DeviceRecord {
        try add(DeviceRecord(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            sshPort: sshPort,
            publicKeyFingerprint: publicKeyFingerprint,
            addedAt: now,
            lastSeenAt: now,
            workdirMap: workdirMap,
            lanHost: lanHost,
            role: role,
            epoch: epoch,
            hostKeyFingerprint: hostKeyFingerprint,
            clientKeyFingerprint: clientKeyFingerprint,
            hostKeyFingerprintSource: hostKeyFingerprintSource,
            clientKeyFingerprintSource: clientKeyFingerprintSource))
    }

    enum FingerprintRole: String, Sendable { case host, client }

    /// 成功用過之後補記一把指紋（隧道成功補 host、RPC 簽章驗過補 client）。
    /// 只補空的那把或補來源；值不同一律拒絕，絕不覆蓋已經 pin 住的指紋，
    /// 也不會因為補齊而放寬任何比對——缺的那把在補齊前照樣擋。
    @discardableResult
    func recordFingerprint(
        id: String, role: FingerprintRole, fingerprint: String, source: String, now: Date = Date()
    ) throws -> DeviceRecord {
        guard Self.isSafeDeviceID(id) else { throw RegistryError.invalidDeviceID }
        guard fingerprint.hasPrefix("SHA256:"), fingerprint.count > "SHA256:".count else {
            throw RegistryError.invalidPublicKey
        }
        return try lock.withLock {
            var rows = try readUnlocked()
            guard let index = rows.firstIndex(where: { $0.id == id }) else { throw RegistryError.deviceNotFound }
            let existing = role == .host ? rows[index].hostKeyFingerprint : rows[index].clientKeyFingerprint
            guard existing == nil || existing == fingerprint else { throw RegistryError.fingerprintConflict }
            let recorded = role == .host
                ? rows[index].hostKeyFingerprintSource : rows[index].clientKeyFingerprintSource
            guard existing == nil || recorded?.source != source else { return rows[index] }
            let stamp = DeviceFingerprintProvenance(source: source, recordedAt: now)
            switch role {
            case .host:
                rows[index].hostKeyFingerprint = fingerprint
                rows[index].hostKeyFingerprintSource = stamp
            case .client:
                rows[index].clientKeyFingerprint = fingerprint
                rows[index].clientKeyFingerprintSource = stamp
            }
            rows[index].needsFingerprintRepair = false
            try writeUnlocked(rows)
            return rows[index]
        }
    }

    /// Re-pairing the same SSH key must retain its UUID; a peer cannot claim another key's ID.
    func pairingDeviceID(publicKey: String, requestedID: String?, localDeviceID: String) throws -> String {
        let fingerprint = try Self.fingerprint(publicKey: publicKey)
        return try lock.withLock {
            let rows = try readUnlocked()
            let matches = rows.filter { $0.publicKeyFingerprint == fingerprint }
            guard matches.count <= 1 else { throw RegistryError.pairingIdentityConflict }
            let id = (requestedID ?? matches.first?.id ?? UUID().uuidString).lowercased()
            guard UUID(uuidString: id) != nil, id != localDeviceID.lowercased(),
                  matches.first.map({ $0.id.lowercased() == id }) ?? true,
                  !rows.contains(where: { $0.id.lowercased() == id && $0.publicKeyFingerprint != fingerprint })
            else { throw RegistryError.pairingIdentityConflict }
            return id
        }
    }

    /// Old clients mislabeled their own pairing UUID as the host row. Correct only a
    /// verified matching host/key row; never guess from a name or delete SSH authorization.
    func recordPairedHost(_ record: DeviceRecord, localDeviceID: String) throws -> DeviceRecord {
        guard Self.isSafeDeviceID(record.id), record.id.lowercased() != localDeviceID.lowercased()
        else { throw RegistryError.pairingIdentityConflict }
        return try lock.withLock {
            var rows = try readUnlocked()
            var previous: DeviceRecord?
            if let index = rows.firstIndex(where: { $0.id.lowercased() == localDeviceID.lowercased() }) {
                guard rows[index].publicKeyFingerprint == record.publicKeyFingerprint,
                      rows[index].host == record.host, rows[index].user == record.user
                else { throw RegistryError.pairingIdentityConflict }
                previous = rows[index]
                rows.remove(at: index)
            }
            previous = rows.first { $0.id == record.id } ?? previous
            var updated = record
            if let previous {
                updated.addedAt = previous.addedAt
                updated.workdirMap = previous.workdirMap
                updated.lanHost = previous.lanHost
                updated.role = previous.role
                updated.epoch = previous.epoch
                updated.endpoints = previous.endpoints
                updated.retiredEndpoints = previous.retiredEndpoints
                updated.lastEndpoint = previous.lastEndpoint
                if updated.hostKeyFingerprint == nil {
                    updated.hostKeyFingerprint = previous.hostKeyFingerprint
                    updated.hostKeyFingerprintSource = previous.hostKeyFingerprintSource
                }
                if updated.clientKeyFingerprint == nil {
                    updated.clientKeyFingerprint = previous.clientKeyFingerprint
                    updated.clientKeyFingerprintSource = previous.clientKeyFingerprintSource
                }
                updated.needsFingerprintRepair = updated.hostKeyFingerprint == nil
                    && updated.clientKeyFingerprint == nil && previous.needsFingerprintRepair
                updated.syncLegacyAddress()
            }
            if let index = rows.firstIndex(where: { $0.id == record.id }) {
                rows[index] = updated
            } else {
                rows.append(updated)
            }
            try writeUnlocked(rows)
            return updated
        }
    }

    func remove(id: String) throws {
        guard Self.isSafeDeviceID(id) else { throw RegistryError.invalidDeviceID }
        try lock.withLock {
            var rows = try readUnlocked()
            guard rows.contains(where: { $0.id == id }) else { throw RegistryError.deviceNotFound }
            rows.removeAll { $0.id == id }
            try writeUnlocked(rows)
            try removeAuthorizedKeyUnlocked(deviceID: id)
        }
    }

    @discardableResult
    func touch(id: String, at now: Date = Date(), endpoint: DeviceEndpoint? = nil) throws -> DeviceRecord {
        guard Self.isSafeDeviceID(id) else { throw RegistryError.invalidDeviceID }
        return try lock.withLock {
            var rows = try readUnlocked()
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                throw RegistryError.deviceNotFound
            }
            if let endpoint {
                guard rows[index].orderedEndpoints.contains(endpoint) else { throw RegistryError.invalidEndpoint }
                rows[index].lastEndpoint = endpoint
            }
            rows[index].lastSeenAt = now
            try writeUnlocked(rows)
            return rows[index]
        }
    }

    @discardableResult
    func updateEndpoint(id: String, endpoint: DeviceEndpoint, retire: Bool = false) throws -> DeviceRecord {
        guard endpoint.isValid else { throw RegistryError.invalidEndpoint }
        return try lock.withLock {
            var rows = try readUnlocked()
            guard let index = rows.firstIndex(where: { $0.id == id }) else { throw RegistryError.deviceNotFound }
            if retire {
                guard rows[index].endpoints.contains(endpoint) else { throw RegistryError.invalidEndpoint }
                if !rows[index].retiredEndpoints.contains(endpoint) { rows[index].retiredEndpoints.append(endpoint) }
                rows[index].endpoints.removeAll { $0 == endpoint }
                if rows[index].lastEndpoint == endpoint { rows[index].lastEndpoint = nil }
            } else {
                guard !rows[index].retiredEndpoints.contains(endpoint) else { throw RegistryError.invalidEndpoint }
                if !rows[index].endpoints.contains(endpoint) { rows[index].endpoints.append(endpoint) }
            }
            rows[index].syncLegacyAddress()
            try writeUnlocked(rows)
            return rows[index]
        }
    }

    /// 只追加 R1 自己管理的一行；回傳 OpenSSH 相容的 SHA256 fingerprint。
    @discardableResult
    func authorize(publicKey: String, deviceID: String) throws -> String {
        guard Self.isSafeDeviceID(deviceID) else { throw RegistryError.invalidDeviceID }
        let normalized = try Self.normalizedPublicKey(publicKey)
        let fingerprint = try Self.fingerprint(forNormalizedPublicKey: normalized)
        try lock.withLock {
            let directory = authorizedKeysURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = chmod(directory.path, S_IRWXU)

            var lines = Self.readLines(at: authorizedKeysURL)
            let marker = Self.marker(deviceID)
            lines.removeAll { Self.trailingMarker(in: $0) == marker }
            lines.append("\(normalized) \(marker)")
            try Self.writeLinesAtomically(lines, to: authorizedKeysURL)
            _ = chmod(authorizedKeysURL.path, S_IRUSR | S_IWUSR)
        }
        return fingerprint
    }

    static func fingerprint(publicKey: String) throws -> String {
        try fingerprint(forNormalizedPublicKey: normalizedPublicKey(publicKey))
    }

    func removeAuthorizedKey(deviceID: String) throws {
        guard Self.isSafeDeviceID(deviceID) else { throw RegistryError.invalidDeviceID }
        try lock.withLock { try removeAuthorizedKeyUnlocked(deviceID: deviceID) }
    }

    private func readUnlocked() throws -> [DeviceRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return classifiedLegacyFingerprints(try decoder.decode([DeviceRecord].self, from: data))
    }

    /// 舊格式升級：舊欄那把指紋依配對方向可能是主機金鑰或客戶端金鑰。
    /// 用本機既有的憑據判方向——`authorized_keys` 裡掛著這台 ID 的那行代表「我是產生配對碼端」，
    /// 舊值就是對方的客戶端金鑰；`known_hosts` 裡有這把代表「我是加入端」，舊值是對方的主機金鑰。
    /// 兩邊都比不到才判不出來：兩把皆空、標記待修；同時比到（金鑰重用）兩欄都填。只分類，不改值、不寫檔。
    private func classifiedLegacyFingerprints(_ rows: [DeviceRecord]) -> [DeviceRecord] {
        guard rows.contains(where: Self.needsLegacyClassification) else { return rows }
        let authorized = Self.authorizedFingerprintsByDevice(at: authorizedKeysURL)
        let knownHosts = Self.knownHostFingerprints(at: knownHostsURL)
        return rows.map { row in
            guard Self.needsLegacyClassification(row) else { return row }
            var updated = row
            let legacy = row.publicKeyFingerprint
            let asClient = authorized[row.id.lowercased()]?.contains(legacy) ?? false
            let asHost = knownHosts.contains(legacy)
            switch (asClient, asHost) {
            case (true, false):
                updated.clientKeyFingerprint = legacy
                updated.clientKeyFingerprintSource = .init(
                    source: "legacy_authorized_keys", recordedAt: row.addedAt)
            case (false, true):
                updated.hostKeyFingerprint = legacy
                updated.hostKeyFingerprintSource = .init(
                    source: "legacy_known_hosts", recordedAt: row.addedAt)
            case (true, true):
                // 同一把金鑰同時是對方的主機金鑰與客戶端金鑰（金鑰重用）：兩欄都填舊值，兩條路都維持可比對；
                // 之後任一次成功連線補記到不同值會走 fingerprintConflict 擋下，不會靜默放行。
                updated.clientKeyFingerprint = legacy
                updated.clientKeyFingerprintSource = .init(
                    source: "legacy_authorized_keys", recordedAt: row.addedAt)
                updated.hostKeyFingerprint = legacy
                updated.hostKeyFingerprintSource = .init(
                    source: "legacy_known_hosts", recordedAt: row.addedAt)
            default:
                updated.needsFingerprintRepair = true
            }
            return updated
        }
    }

    private static func needsLegacyClassification(_ row: DeviceRecord) -> Bool {
        row.hostKeyFingerprint == nil && row.clientKeyFingerprint == nil
            && row.publicKeyFingerprint.hasPrefix("SHA256:")
    }

    /// `authorized_keys` 只讀，取出每台設備被授權的客戶端金鑰指紋。
    private static func authorizedFingerprintsByDevice(at url: URL) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for line in readLines(at: url).prefix(4096) where !line.hasPrefix("#") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let marker = fields.last.map(String.init),
                  marker.hasPrefix("tatwo2-device:"),
                  let fingerprint = try? fingerprint(publicKey: "\(fields[0]) \(fields[1])")
            else { continue }
            result[String(marker.dropFirst("tatwo2-device:".count)).lowercased(), default: []].insert(fingerprint)
        }
        return result
    }

    /// `known_hosts` 只讀，取出已知的主機金鑰指紋。
    private static func knownHostFingerprints(at url: URL) -> Set<String> {
        var result: Set<String> = []
        for line in readLines(at: url).prefix(4096) where !line.hasPrefix("#") && !line.hasPrefix("@") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  let fingerprint = try? fingerprint(publicKey: "\(fields[1]) \(fields[2])")
            else { continue }
            result.insert(fingerprint)
        }
        return result
    }

    private func writeUnlocked(_ rows: [DeviceRecord]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows.sorted { $0.addedAt < $1.addedAt }).write(to: url, options: .atomic)
    }

    private func removeAuthorizedKeyUnlocked(deviceID: String) throws {
        guard FileManager.default.fileExists(atPath: authorizedKeysURL.path) else { return }
        let marker = Self.marker(deviceID)
        let original = Self.readLines(at: authorizedKeysURL)
        let filtered = original.filter { Self.trailingMarker(in: $0) != marker }
        guard filtered != original else { return }
        try Self.writeLinesAtomically(filtered, to: authorizedKeysURL)
        _ = chmod(authorizedKeysURL.path, S_IRUSR | S_IWUSR)
    }

    private static func normalizedPublicKey(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw RegistryError.invalidPublicKey
        }
        let fields = trimmed.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "ssh-ed25519",
              Data(base64Encoded: String(fields[1])) != nil
        else {
            throw RegistryError.invalidPublicKey
        }
        return "\(fields[0]) \(fields[1])"
    }

    private static func fingerprint(forNormalizedPublicKey key: String) throws -> String {
        let fields = key.split(separator: " ")
        guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw RegistryError.invalidPublicKey
        }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private static func readLines(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func writeLinesAtomically(_ lines: [String], to url: URL) throws {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func marker(_ deviceID: String) -> String {
        "tatwo2-device:\(deviceID)"
    }

    private static func trailingMarker(in line: String) -> String? {
        line.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    private static func isSafeDeviceID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }
}

extension DeviceRegistry {
    /// 本機自己的主機金鑰指紋（配對時報給對方，讓對方之後能 pin 住往這台的隧道）。
    /// 只讀公開的 `.pub`，不碰任何私鑰。
    static func localHostKeyFingerprint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        fingerprintOfPublicKeyFile(
            environment["TATWO2_SSH_HOST_KEY_PUB"] ?? "/etc/ssh/ssh_host_ed25519_key.pub")
    }

    /// 本機自己的客戶端金鑰指紋（配對時報給對方，讓對方之後能驗本機送出的 RPC 簽章）。
    static func localClientKeyFingerprint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let base = environment["TATWO2_SSH_KEY_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/id_ed25519").path
        return fingerprintOfPublicKeyFile(base + ".pub")
    }

    private static func fingerprintOfPublicKeyFile(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            if let value = try? fingerprint(publicKey: String(line)) { return value }
        }
        return nil
    }
}

extension DeviceRecord {
    static func shortFingerprint(_ value: String) -> String {
        value.count <= 24 ? value : String(value.prefix(24)) + "…"
    }

    /// 設備頁用：兩把指紋分別是什麼、來源、缺哪把。只顯示登記表既有內容。
    var fingerprintSummary: String {
        guard hostKeyFingerprint != nil || clientKeyFingerprint != nil else {
            let legacy = publicKeyFingerprint.isEmpty ? "缺" : Self.shortFingerprint(publicKeyFingerprint)
            return "指紋 \(legacy)・尚未分流" + (needsFingerprintRepair ? "（判不出方向，下次配對補齊）" : "")
        }
        func part(_ label: String, _ value: String?, _ origin: DeviceFingerprintProvenance?) -> String {
            guard let value, !value.isEmpty else { return "\(label) 缺" }
            return "\(label) \(Self.shortFingerprint(value))" + (origin.map { "（\($0.source)）" } ?? "")
        }
        // W98：只換白話字面，欄位與判斷完全不動。
        let missing = hostKeyFingerprint == nil || hostKeyFingerprint?.isEmpty == true
            || clientKeyFingerprint == nil || clientKeyFingerprint?.isEmpty == true
        return part("隧道識別", hostKeyFingerprint, hostKeyFingerprintSource)
            + "・" + part("簽章識別", clientKeyFingerprint, clientKeyFingerprintSource)
            + (missing ? "・重新配對即可補齊" : "")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

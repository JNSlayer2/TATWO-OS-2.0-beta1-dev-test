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

    var orderedEndpoints: [DeviceEndpoint] {
        [.lan, .tunnel, .alias].flatMap { kind in
            endpoints.filter { $0.kind == kind && $0.isValid && !retiredEndpoints.contains($0) }
        }
    }

    init(id: String, name: String, host: String, user: String, sshPort: Int,
         publicKeyFingerprint: String, addedAt: Date, lastSeenAt: Date,
         workdirMap: [String: String], lanHost: String? = nil, role: DeviceRole? = nil,
         epoch: Int? = nil, endpoints: [DeviceEndpoint]? = nil,
         retiredEndpoints: [DeviceEndpoint] = [], lastEndpoint: DeviceEndpoint? = nil) {
        self.id = id; self.name = name; self.host = host; self.user = user; self.sshPort = sshPort
        self.publicKeyFingerprint = publicKeyFingerprint; self.addedAt = addedAt
        self.lastSeenAt = lastSeenAt; self.workdirMap = workdirMap; self.lanHost = lanHost
        self.role = role; self.epoch = epoch
        self.endpoints = endpoints ?? [.init(kind: .lan, host: host, port: sshPort)]
        self.retiredEndpoints = retiredEndpoints; self.lastEndpoint = lastEndpoint
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
            lastEndpoint: try c.decodeIfPresent(DeviceEndpoint.self, forKey: .lastEndpoint))
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

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "invalid_device_endpoint"
            case .invalidDeviceID: "invalid_device_id"
            case .invalidPublicKey: "invalid_public_key"
            case .deviceNotFound: "device_not_found"
            case .pairingIdentityConflict: "pairing_identity_conflict"
            }
        }
    }

    let root: URL
    let url: URL
    let authorizedKeysURL: URL
    // UI edits and successful background links create separate registry instances.
    // Serialize their read-modify-write cycles so a touch cannot erase an endpoint edit.
    private static let storageLock = NSLock()
    private var lock: NSLock { Self.storageLock }

    init(
        root: URL? = nil,
        authorizedKeysURL: URL? = nil,
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
        epoch: Int? = nil
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
            epoch: epoch))
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
        return try decoder.decode([DeviceRecord].self, from: data)
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

import CryptoKit
import Darwin
import Foundation

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
}

/// `live/devices.json` 是 2.0 遠端設備的唯一薄登記表；SSH authorized_keys 才是信任真值。
final class DeviceRegistry: @unchecked Sendable {
    enum RegistryError: Error, LocalizedError {
        case invalidDeviceID
        case invalidPublicKey
        case deviceNotFound

        var errorDescription: String? {
            switch self {
            case .invalidDeviceID: "invalid_device_id"
            case .invalidPublicKey: "invalid_public_key"
            case .deviceNotFound: "device_not_found"
            }
        }
    }

    let root: URL
    let url: URL
    let authorizedKeysURL: URL
    private let lock = NSLock()

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
        lanHost: String? = nil
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
            lanHost: lanHost))
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
    func touch(id: String, at now: Date = Date()) throws -> DeviceRecord {
        guard Self.isSafeDeviceID(id) else { throw RegistryError.invalidDeviceID }
        return try lock.withLock {
            var rows = try readUnlocked()
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                throw RegistryError.deviceNotFound
            }
            rows[index].lastSeenAt = now
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

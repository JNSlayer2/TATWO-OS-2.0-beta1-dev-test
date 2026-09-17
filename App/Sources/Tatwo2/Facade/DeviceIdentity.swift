import Darwin
import Foundation

enum DeviceRole: String, Codable, Sendable {
    case primary, secondary
}

/// The UUID is the existing 2.0 pairing identity, not a second identity namespace.
struct DeviceIdentity: Codable, Equatable, Sendable {
    static let schemaName = "tatwo.device-identity.v1"
    var schema: String = schemaName
    let deviceID: String
    var name: String
    var hardwareModel: String
    var role: DeviceRole
    /// nil means sovereignty has not been migrated/assigned; it does NOT mean epoch zero.
    var epoch: Int?
    var primaryDeviceID: String?
    var legacyIdentity: String?
    var updatedAt: Date
    /// W83 checkpoints are independent of the sovereignty epoch.
    var transfer: PrimaryTransferState.Record? = nil

    func validated() throws -> Self {
        guard schema == Self.schemaName,
              UUID(uuidString: deviceID) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hardwareModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              epoch.map({ $0 >= 0 }) ?? true,
              (epoch == nil) == (primaryDeviceID == nil),
              primaryDeviceID.map({ UUID(uuidString: $0) != nil }) ?? true
        else { throw DeviceIdentityError.invalidIdentity }
        if role == .primary {
            guard epoch != nil, primaryDeviceID?.lowercased() == deviceID.lowercased()
            else { throw DeviceIdentityError.invalidIdentity }
        } else if primaryDeviceID?.lowercased() == deviceID.lowercased() {
            throw DeviceIdentityError.invalidIdentity
        }
        try transfer?.validate()
        return self
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data).validated()
    }

    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Keep unknown optional fields explicitly present in the public format.
        var object = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        for key in ["epoch", "primaryDeviceID", "legacyIdentity"] where object[key] == nil {
            object[key] = NSNull()
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

enum DeviceIdentityError: String, Error, LocalizedError {
    case invalidIdentity, identityConflict, foreignDeviceWrite, unsafeIdentityPath
    case hardwareModelUnavailable, invalidLegacyMapping
    var errorDescription: String? { "device_identity_\(rawValue)" }
}

/// Only this local writer owns a destination. Remote device_status results are plain values.
/// No API accepts a destination path on write. An existing UUID can never be rebound by write().
final class DeviceIdentityStore {
    private static let lock = NSLock()
    private let entry: TatwoEntry
    private let resolvedRoot: URL
    let localDeviceID: String

    private init(entry: TatwoEntry, localDeviceID: String) {
        self.entry = entry
        self.resolvedRoot = Self.canonical(entry.root)
        self.localDeviceID = localDeviceID.lowercased()
    }

    /// Read-only, including missing/corrupt files. Does not bootstrap or repair anything.
    static func readLocal(entry: TatwoEntry = TatwoEntry()) throws -> DeviceIdentity? {
        if !FileManager.default.fileExists(atPath: entry.deviceJSON.path),
           (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.deviceJSON.path)) == nil {
            return nil
        }
        try checkFile(entry.deviceJSON)
        return try DeviceIdentity.decode(Data(contentsOf: entry.deviceJSON))
    }

    /// pairedDeviceID must come from a pairing reply or a verified legacy mapping, never a
    /// remote registry's first row (old clients stored their own pairing UUID as the host row).
    static func forLocalDevice(
        entry: TatwoEntry = TatwoEntry(),
        pairedDeviceID: String? = nil,
        name: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        now: Date = Date()
    ) throws -> DeviceIdentityStore {
        try lock.withLock {
            if let existing = try readLocal(entry: entry) {
                if let pairedDeviceID,
                   existing.deviceID.lowercased() != pairedDeviceID.lowercased() {
                    throw DeviceIdentityError.identityConflict
                }
                return DeviceIdentityStore(entry: entry, localDeviceID: existing.deviceID)
            }
            let id = (pairedDeviceID ?? UUID().uuidString).lowercased()
            let store = DeviceIdentityStore(entry: entry, localDeviceID: id)
            let identity = DeviceIdentity(
                deviceID: id, name: name, hardwareModel: try hardwareModel(),
                role: .secondary, epoch: nil, primaryDeviceID: nil, legacyIdentity: nil,
                updatedAt: now)
            try store.writeUnlocked(identity)
            return store
        }
    }

    func read() throws -> DeviceIdentity {
        guard let identity = try Self.readLocal(entry: entry),
              identity.deviceID.lowercased() == localDeviceID
        else { throw DeviceIdentityError.identityConflict }
        return identity
    }

    func write(_ identity: DeviceIdentity) throws {
        try Self.lock.withLock { try writeUnlocked(identity) }
    }

    private func writeUnlocked(_ identity: DeviceIdentity) throws {
        guard identity.deviceID.lowercased() == localDeviceID else {
            throw DeviceIdentityError.foreignDeviceWrite
        }
        _ = try identity.validated()
        guard Self.canonical(entry.root) == resolvedRoot,
              entry.status == .available || entry.status == .missing
        else { throw DeviceIdentityError.unsafeIdentityPath }
        try Self.checkFile(entry.deviceJSON)
        if let existing = try Self.readLocal(entry: entry),
           existing.deviceID.lowercased() != localDeviceID {
            throw DeviceIdentityError.foreignDeviceWrite
        }
        try FileManager.default.createDirectory(at: entry.root, withIntermediateDirectories: true)
        let encoded = try identity.encoded()
        // Pairing/epoch updates must retain local onboarding resources, preferences and
        // stricter boundaries. Remote identity records never supply these local extensions.
        if let old = try? Data(contentsOf: entry.deviceJSON),
           var object = try JSONSerialization.jsonObject(with: old) as? [String: Any],
           let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            object.merge(fields) { _, new in new }
            if identity.transfer == nil { object.removeValue(forKey: "transfer") }
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: entry.deviceJSON, options: .atomic)
        } else {
            try encoded.write(to: entry.deviceJSON, options: .atomic)
        }
    }

    /// realpath(3) of the nearest existing ancestor plus the not-yet-created tail.
    /// Stable before and after the entrance is created (URL.resolvingSymlinksInPath
    /// is not: it may drop /private depending on whether components exist).
    static func canonical(_ url: URL) -> URL {
        var existing = url.path
        var tail: [String] = []
        while !existing.isEmpty, existing != "/", !FileManager.default.fileExists(atPath: existing) {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var base = existing
        if let resolved = realpath(existing, nil) { base = String(cString: resolved); free(resolved) }
        return tail.reduce(URL(fileURLWithPath: base, isDirectory: true)) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private static func checkFile(_ url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw DeviceIdentityError.unsafeIdentityPath
        }
        // Includes dangling links. The entrance itself may legitimately be a symlink.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw DeviceIdentityError.unsafeIdentityPath
        }
    }

    static func hardwareModel() throws -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            throw DeviceIdentityError.hardwareModelUnavailable
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            throw DeviceIdentityError.hardwareModelUnavailable
        }
        return String(cString: bytes)
    }
}

enum DeviceIdentityMigration {
    struct LegacyPrimary: Decodable {
        let name: String
        let epoch: Int
    }
    struct Details {
        let name: String
        /// Supplied by a read-only inventory on THAT device, never inferred from its name.
        let hardwareModel: String
    }

    /// Pure preview: consumes the 1.0 primary.json snapshot and explicit UUID/name mapping.
    /// The lead installs each returned value on its own device via that device's local writer.
    /// No filesystem, channel, SSH, Keychain or registry mutation takes place here.
    static func preview(
        primaryJSON: Data,
        deviceIDsByLegacyName: [String: String],
        detailsByLegacyName: [String: Details],
        updatedAt: Date = Date()
    ) throws -> [String: DeviceIdentity] {
        let primary = try JSONDecoder().decode(LegacyPrimary.self, from: primaryJSON)
        guard primary.epoch >= 0,
              let primaryID = deviceIDsByLegacyName[primary.name],
              Set(deviceIDsByLegacyName.keys) == Set(detailsByLegacyName.keys),
              Set(deviceIDsByLegacyName.values.map { $0.lowercased() }).count == deviceIDsByLegacyName.count
        else { throw DeviceIdentityError.invalidLegacyMapping }
        var result: [String: DeviceIdentity] = [:]
        for (legacyName, id) in deviceIDsByLegacyName {
            guard !legacyName.isEmpty, let details = detailsByLegacyName[legacyName] else {
                throw DeviceIdentityError.invalidLegacyMapping
            }
            result[legacyName] = try DeviceIdentity(
                deviceID: id.lowercased(), name: details.name, hardwareModel: details.hardwareModel,
                role: legacyName == primary.name ? .primary : .secondary,
                epoch: primary.epoch, primaryDeviceID: primaryID.lowercased(),
                legacyIdentity: legacyName, updatedAt: updatedAt).validated()
        }
        return result
    }
}

/// Pure Codable identity metadata; no transport or UI dependencies (W76/W77 readers).
enum PrimaryTransferState {
    enum Brain: String, Codable, CaseIterable, Sendable {
        case retained, migrated, migrating
        var label: String {
            switch self {
            case .retained: return "仍在舊主設備（新主設備連舊的）"
            case .migrated: return "已遷移"
            case .migrating: return "遷移中"
            }
        }
    }
    enum Release: String, Codable, Sendable {
        case ready, missingCertificate, missingDependencies
        var label: String {
            switch self {
            case .ready: return "可發版"
            case .missingCertificate: return "缺憑證"
            case .missingDependencies: return "缺依賴"
            }
        }
    }
    struct Evidence: Codable, Equatable, Sendable {
        var signingNames: [String] = []
        var missingDependencies: [String] = []
        var brainMode: String = "unconfigured"
        var brainHealthy = false
        var brainHostID: String?
        var pages: Int?
        var acquiredAt: Date = Date()
        var limitation: String?
    }
    struct Record: Codable, Equatable, Sendable {
        var id: String = UUID().uuidString
        var from: String
        var to: String
        var oldEpoch: Int
        var epoch: Int
        var participants: [String]
        var previousTransferID: String?
        var revision: Int = 1
        var committed = false
        var epochACKs: [String] = []
        var acknowledgedRevision: Int = 0
        var constitution = false
        var constitutionRevision = 0
        var sourceDeviceID: String
        var sourceRoot: String
        var hashes: [String: String]
        var brain: Brain = .retained
        var brainVerified = false
        var brainRevision = 0
        var sourcePages: Int?
        var targetPages: Int?
        var release: Release = .missingCertificate
        var releaseChecked = false
        var releaseRevision = 0
        var signingName: String
        var missingDependencies: [String] = []
        var targetEvidence: Evidence?
        var targetRoot: String?

        var epochComplete: Bool { committed && Set(epochACKs).isSuperset(of: participants) }
        var constitutionComplete: Bool {
            constitution && constitutionRevision > 0 && acknowledgedRevision >= constitutionRevision
        }
        var brainComplete: Bool {
            brain != .migrating && brainVerified && brainRevision > 0 && acknowledgedRevision >= brainRevision
        }
        var releaseComplete: Bool {
            releaseChecked && release == .ready && releaseRevision > 0 && acknowledgedRevision >= releaseRevision
        }
        var complete: Bool {
            epochComplete && constitutionComplete && brainComplete && releaseComplete
                && acknowledgedRevision == revision
        }
        var summary: String { complete ? "移交完成" : "移交未完成（epoch 成功不代表移交完成）" }

        func validate() throws {
            guard UUID(uuidString: id) != nil, UUID(uuidString: from) != nil, UUID(uuidString: to) != nil,
                  from != to, oldEpoch >= 0, epoch > 0, epoch - 1 == oldEpoch,
                  revision > 0, revision < Int.max, acknowledgedRevision >= 0, acknowledgedRevision <= revision,
                  [constitutionRevision, brainRevision, releaseRevision].allSatisfy({ $0 >= 0 && $0 <= revision }),
                  !participants.isEmpty, participants.count <= 128, Set(participants).count == participants.count,
                  participants.contains(to), !participants.contains(from),
                  participants.allSatisfy({ UUID(uuidString: $0) != nil }),
                  previousTransferID.map({ UUID(uuidString: $0) != nil }) ?? true,
                  Set(epochACKs).isSubset(of: participants),
                  committed || epochACKs.isEmpty,
                  sourceDeviceID == (constitution ? to : from), sourceRoot.hasPrefix("/"),
                  hashes["os.md"] != nil, hashes["skillet.md"] != nil, hashes.count <= 512
            else { throw DeviceIdentityError.invalidIdentity }
            for (path, hash) in hashes {
                guard path.count <= 1024, !path.contains("\\"),
                      path.split(separator: "/", omittingEmptySubsequences: false)
                        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw DeviceIdentityError.invalidIdentity
                }
                guard (path == "os.md" || path == "skillet.md" || path.hasPrefix("note/")),
                      hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                    throw DeviceIdentityError.invalidIdentity
                }
            }
        }
    }
    struct ACK: Codable, Sendable {
        var id: String
        var revision: Int
        var committed: Bool
        var root: String
        var evidence: Evidence
    }
}

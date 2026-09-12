import CryptoKit
import Foundation
import TatwoWorkReceiptContracts

public enum TatwoDomainDeviceKindV1: String, Codable, Hashable, Sendable {
    case macMini
    case macBook
    case iPad
    case visionPro
    case remoteHost
    case other
}

public enum TatwoDomainConnectionStateV1: String, Codable, Hashable, Sendable {
    case connected
    case syncing
    case offline
}

public struct TatwoDomainDeviceV1: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let domainID: String
    public let displayName: String
    public let kind: TatwoDomainDeviceKindV1
    public let connectionState: TatwoDomainConnectionStateV1
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let registeredAt: Date
    public let lastHeartbeatAt: Date?

    public init(
        id: String,
        domainID: String,
        displayName: String,
        kind: TatwoDomainDeviceKindV1,
        connectionState: TatwoDomainConnectionStateV1,
        schemaVersion: Int,
        protocolVersion: Int,
        registeredAt: Date,
        lastHeartbeatAt: Date?
    ) {
        self.id = id
        self.domainID = domainID
        self.displayName = displayName
        self.kind = kind
        self.connectionState = connectionState
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.registeredAt = registeredAt
        self.lastHeartbeatAt = lastHeartbeatAt
    }
}

public enum TatwoAuthorityLeaseSourceV1: String, Codable, Hashable, Sendable {
    case humanConfirmed
    case importedVerifiedReceipt
}

public struct TatwoAuthorityLeaseV1: Codable, Hashable, Sendable {
    public let domainID: String
    public let holderDeviceID: String
    public let epoch: UInt64
    public let fencingToken: String
    public let observedAt: Date
    public let expiresAt: Date
    public let source: TatwoAuthorityLeaseSourceV1
    public let receiptMetadata: TatwoWorkReceiptMetadataV1

    public init(
        domainID: String,
        holderDeviceID: String,
        epoch: UInt64,
        fencingToken: String,
        observedAt: Date,
        expiresAt: Date,
        source: TatwoAuthorityLeaseSourceV1,
        receiptMetadata: TatwoWorkReceiptMetadataV1
    ) {
        self.domainID = domainID
        self.holderDeviceID = holderDeviceID
        self.epoch = epoch
        self.fencingToken = fencingToken
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.source = source
        self.receiptMetadata = receiptMetadata
    }
}

public enum TatwoDomainEventKindV1: String, Codable, Hashable, Sendable {
    case deviceRegistered = "device.registered"
    case heartbeat = "device.heartbeat"
    case authorityObserved = "authority.observed"
    case goalRunProjection = "goal_run.projection"
    case issueQueueProjection = "issue_queue.projection"
    case receiptMetadata = "receipt.metadata"
    case threadProjection = "thread.projection"
    case messageProjection = "message.projection"
    case attachmentReference = "attachment.reference"
    case annotation = "annotation"
    case scenarioPreference = "scenario.preference"
    case pluginPreference = "plugin.preference"
}

public enum TatwoDomainPayloadClassV1: String, Codable, Hashable, Sendable {
    case typedMetadata
    case goalRunProjection
    case issueQueueProjection
    case threadMessageProjection
    case attachmentReference
    case userPreference
    case authSessionToken
    case modelCredential
    case privateKey
    case browserProfile
    case machinePermission
    case launchAgent
    case processState
    case cache
    case sourceTree
    case rawDatabase

    public var isProtected: Bool {
        switch self {
        case .typedMetadata,
             .goalRunProjection,
             .issueQueueProjection,
             .threadMessageProjection,
             .attachmentReference,
             .userPreference:
            false
        case .authSessionToken,
             .modelCredential,
             .privateKey,
             .browserProfile,
             .machinePermission,
             .launchAgent,
             .processState,
             .cache,
             .sourceTree,
             .rawDatabase:
            true
        }
    }

    public func isAllowed(for kind: TatwoDomainEventKindV1) -> Bool {
        switch kind {
        case .deviceRegistered, .heartbeat, .authorityObserved, .receiptMetadata:
            self == .typedMetadata
        case .goalRunProjection:
            self == .goalRunProjection
        case .issueQueueProjection:
            self == .issueQueueProjection
        case .threadProjection, .messageProjection:
            self == .threadMessageProjection
        case .attachmentReference:
            self == .attachmentReference
        case .annotation, .scenarioPreference, .pluginPreference:
            self == .userPreference
        }
    }
}

public indirect enum TatwoDomainJSONValueV1: Hashable, Sendable {
    case object([String: TatwoDomainJSONValueV1])
    case array([TatwoDomainJSONValueV1])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null

    public func canonicalJSONData() -> Data {
        Data(canonicalJSONString.utf8)
    }

    public var canonicalJSONString: String {
        switch self {
        case .object(let object):
            let members = object.keys.sorted().map { key in
                "\(Self.canonicalJSONStringLiteral(key)):\(object[key]!.canonicalJSONString)"
            }
            return "{\(members.joined(separator: ","))}"
        case .array(let values):
            return "[\(values.map(\.canonicalJSONString).joined(separator: ","))]"
        case .string(let value):
            return Self.canonicalJSONStringLiteral(value)
        case .integer(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func canonicalJSONStringLiteral(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                result += "\\b"
            case 0x09:
                result += "\\t"
            case 0x0A:
                result += "\\n"
            case 0x0C:
                result += "\\f"
            case 0x0D:
                result += "\\r"
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x00...0x1F:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}

extension TatwoDomainJSONValueV1: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TatwoDomainJSONValueV1].self) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: TatwoDomainJSONValueV1].self
        ) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                TatwoDomainJSONValueV1.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Domain payloads allow objects, arrays, strings, signed integers, booleans and null only."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum TatwoDomainPayloadValidationErrorV1: Error, Equatable, Sendable {
    case payloadTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidKey(path: String)
    case protectedKey(path: String)
    case protectedValue(path: String)
    case integerOutOfRange(path: String)
    case digestMismatch
}

public enum TatwoDomainPayloadValidatorV1 {
    public static let maximumPayloadBytes = 64 * 1024
    public static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    private static let protectedKeyFragments = [
        "accesskey",
        "apikey",
        "authorization",
        "bearer",
        "clientsecret",
        "cookie",
        "credential",
        "keychain",
        "password",
        "privatekey",
        "refreshtoken",
        "secret",
        "session",
        "signingkey",
        "sshkey",
        "token",
        "tcc",
        "accessibilitypermission",
        "screenrecordingpermission",
        "launchagent",
        "launchdaemon",
        "rawsqlite",
        "sourcetree",
        "worktree",
        "cliprocess",
        "modelcredential"
    ]
    private static let protectedExactKeys = ["auth"]
    private static let protectedKeyPrefixes = ["authentication", "oauth"]

    public static func validate(_ payload: TatwoDomainJSONValueV1) throws {
        if let path = firstInvalidKeyPath(in: payload) {
            throw TatwoDomainPayloadValidationErrorV1.invalidKey(path: path)
        }
        if let path = firstUnsafeIntegerPath(in: payload) {
            throw TatwoDomainPayloadValidationErrorV1.integerOutOfRange(path: path)
        }
        let size = payload.canonicalJSONData().count
        guard size <= maximumPayloadBytes else {
            throw TatwoDomainPayloadValidationErrorV1.payloadTooLarge(
                actualBytes: size,
                maximumBytes: maximumPayloadBytes
            )
        }
        if let path = firstProtectedPath(in: payload) {
            throw TatwoDomainPayloadValidationErrorV1.protectedKey(path: path)
        }
        if let path = firstProtectedValuePath(in: payload) {
            throw TatwoDomainPayloadValidationErrorV1.protectedValue(path: path)
        }
    }

    public static func digest(_ payload: TatwoDomainJSONValueV1) throws -> String {
        try validate(payload)
        return SHA256.hash(data: payload.canonicalJSONData())
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func validate(
        _ payload: TatwoDomainJSONValueV1,
        expectedDigest: String
    ) throws {
        guard try digest(payload) == expectedDigest else {
            throw TatwoDomainPayloadValidationErrorV1.digestMismatch
        }
    }

    private static func firstProtectedPath(
        in value: TatwoDomainJSONValueV1,
        path: String = "$"
    ) -> String? {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                let normalized = key.lowercased().unicodeScalars
                    .filter { scalar in
                        (48...57).contains(scalar.value)
                            || (97...122).contains(scalar.value)
                    }
                    .map(String.init)
                    .joined()
                if protectedExactKeys.contains(normalized)
                    || protectedKeyPrefixes.contains(where: normalized.hasPrefix)
                    || protectedKeyFragments.contains(where: normalized.contains)
                {
                    return "\(path).\(key)"
                }
                if let nested = firstProtectedPath(
                    in: object[key]!,
                    path: "\(path).\(key)"
                ) {
                    return nested
                }
            }
            return nil
        case .array(let array):
            for (index, item) in array.enumerated() {
                if let nested = firstProtectedPath(
                    in: item,
                    path: "\(path)[\(index)]"
                ) {
                    return nested
                }
            }
            return nil
        case .string, .integer, .bool, .null:
            return nil
        }
    }

    private static func firstProtectedValuePath(
        in value: TatwoDomainJSONValueV1,
        path: String = "$"
    ) -> String? {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                if let nested = firstProtectedValuePath(
                    in: object[key]!,
                    path: "\(path).\(key)"
                ) {
                    return nested
                }
            }
            return nil
        case .array(let array):
            for (index, item) in array.enumerated() {
                if let nested = firstProtectedValuePath(
                    in: item,
                    path: "\(path)[\(index)]"
                ) {
                    return nested
                }
            }
            return nil
        case .string(let value):
            return looksLikeProtectedValue(value) ? path : nil
        case .integer, .bool, .null:
            return nil
        }
    }

    private static func looksLikeProtectedValue(_ value: String) -> Bool {
        if value.range(
            of: #"(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        if value.range(
            of: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if value.range(
            of: #"-----BEGIN [A-Z0-9 ]+-----"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateBytes = Array(candidate.utf8)
        return candidateBytes.count > 40
            && candidateBytes.allSatisfy {
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || [43, 45, 47, 61, 95].contains($0)
            }
    }

    private static func firstInvalidKeyPath(
        in value: TatwoDomainJSONValueV1,
        path: String = "$"
    ) -> String? {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                let bytes = Array(key.utf8)
                guard !bytes.isEmpty,
                      bytes.count <= 128,
                      bytes.allSatisfy({
                          (48...57).contains($0)
                              || (65...90).contains($0)
                              || (97...122).contains($0)
                              || [45, 46, 95].contains($0)
                      })
                else {
                    return "\(path).\(key)"
                }
                if let nested = firstInvalidKeyPath(
                    in: object[key]!,
                    path: "\(path).\(key)"
                ) {
                    return nested
                }
            }
            return nil
        case .array(let array):
            for (index, item) in array.enumerated() {
                if let nested = firstInvalidKeyPath(
                    in: item,
                    path: "\(path)[\(index)]"
                ) {
                    return nested
                }
            }
            return nil
        case .string, .integer, .bool, .null:
            return nil
        }
    }

    private static func firstUnsafeIntegerPath(
        in value: TatwoDomainJSONValueV1,
        path: String = "$"
    ) -> String? {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                if let nested = firstUnsafeIntegerPath(
                    in: object[key]!,
                    path: "\(path).\(key)"
                ) {
                    return nested
                }
            }
            return nil
        case .array(let array):
            for (index, item) in array.enumerated() {
                if let nested = firstUnsafeIntegerPath(
                    in: item,
                    path: "\(path)[\(index)]"
                ) {
                    return nested
                }
            }
            return nil
        case .integer(let integer):
            return (
                integer > maximumSafeInteger
                    || integer < -maximumSafeInteger
            ) ? path : nil
        case .string, .bool, .null:
            return nil
        }
    }
}

public struct TatwoDomainEventV1: Codable, Hashable, Sendable {
    public static let maximumSafeSequence =
        UInt64(TatwoDomainPayloadValidatorV1.maximumSafeInteger)

    public let eventID: String
    public let domainID: String
    public let deviceID: String
    public let leaseEpoch: UInt64
    public let fencingToken: String
    public let idempotencyKey: String
    public let sequence: UInt64
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let kind: TatwoDomainEventKindV1
    public let payloadClass: TatwoDomainPayloadClassV1
    public let payload: TatwoDomainJSONValueV1
    public let payloadDigest: String
    public let observedAt: Date

    public init(
        eventID: String,
        domainID: String,
        deviceID: String,
        leaseEpoch: UInt64,
        fencingToken: String,
        idempotencyKey: String,
        sequence: UInt64,
        schemaVersion: Int,
        protocolVersion: Int,
        kind: TatwoDomainEventKindV1,
        payloadClass: TatwoDomainPayloadClassV1,
        payload: TatwoDomainJSONValueV1,
        observedAt: Date
    ) throws {
        guard leaseEpoch > 0,
              leaseEpoch <= Self.maximumSafeSequence
        else {
            throw TatwoDomainPayloadValidationErrorV1.integerOutOfRange(
                path: "$.leaseEpoch"
            )
        }
        guard sequence > 0, sequence <= Self.maximumSafeSequence else {
            throw TatwoDomainPayloadValidationErrorV1.integerOutOfRange(
                path: "$.sequence"
            )
        }
        self.eventID = eventID
        self.domainID = domainID
        self.deviceID = deviceID
        self.leaseEpoch = leaseEpoch
        self.fencingToken = fencingToken
        self.idempotencyKey = idempotencyKey
        self.sequence = sequence
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.payloadClass = payloadClass
        self.payload = payload
        self.payloadDigest = try TatwoDomainPayloadValidatorV1.digest(payload)
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case domainID
        case deviceID
        case leaseEpoch
        case fencingToken
        case idempotencyKey
        case sequence
        case schemaVersion
        case protocolVersion
        case kind
        case payloadClass
        case payload
        case payloadDigest
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(String.self, forKey: .eventID)
        domainID = try container.decode(String.self, forKey: .domainID)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        leaseEpoch = try container.decode(UInt64.self, forKey: .leaseEpoch)
        guard leaseEpoch > 0,
              leaseEpoch <= Self.maximumSafeSequence
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .leaseEpoch,
                in: container,
                debugDescription:
                    "Lease epoch must be a positive JavaScript-safe integer."
            )
        }
        fencingToken = try container.decode(String.self, forKey: .fencingToken)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        guard sequence > 0, sequence <= Self.maximumSafeSequence else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence,
                in: container,
                debugDescription:
                    "Domain event sequence must be a positive JavaScript-safe integer."
            )
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        kind = try container.decode(TatwoDomainEventKindV1.self, forKey: .kind)
        payloadClass = try container.decode(
            TatwoDomainPayloadClassV1.self,
            forKey: .payloadClass
        )
        payload = try container.decode(TatwoDomainJSONValueV1.self, forKey: .payload)
        payloadDigest = try container.decode(String.self, forKey: .payloadDigest)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        try TatwoDomainPayloadValidatorV1.validate(
            payload,
            expectedDigest: payloadDigest
        )
    }
}

public enum TatwoSyncHealthStatusV1: String, Codable, Hashable, Sendable {
    case healthy
    case degraded
    case failed
    case locked
}

public enum TatwoSyncErrorKindV1: String, Codable, Hashable, Sendable {
    case none
    case invalidDomain
    case invalidDevice
    case heartbeatStale
    case transportOffline
    case transportNotConfigured
    case transportRejected
    case transportProtocolViolation
    case duplicateConflict
    case outOfOrder
    case leaseMissing
    case leaseExpired
    case leaseEpochMismatch
    case fencingTokenMismatch
    case splitBrain
    case schemaIncompatible
    case protocolIncompatible
    case snapshotCorrupt
    case persistenceFailure
    case protectedDataRejected
    case payloadClassMismatch
    case payloadInvalid
    case payloadDigestMismatch
    case humanConfirmationRequired
}

public struct TatwoSyncSafetyEvidenceV1: Codable, Hashable, Sendable {
    public let updaterCallCount: Int
    public let bundleMutationCount: Int
    public let authMaterialReadCount: Int
    public let automaticElectionCount: Int

    public init() {
        updaterCallCount = 0
        bundleMutationCount = 0
        authMaterialReadCount = 0
        automaticElectionCount = 0
    }
}

public struct TatwoSyncHealthReceiptV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let correlationID: String
    public let status: TatwoSyncHealthStatusV1
    public let attempts: Int
    public let hasError: Bool
    public let errorKind: TatwoSyncErrorKindV1
    public let observedAt: Date
    public let lastOKAt: Date?
    public let acceptedEventIDs: [String]
    public let queuedEventIDs: [String]
    public let rejectedEventIDs: [String]
    public let safetyEvidence: TatwoSyncSafetyEvidenceV1
    public let detail: String

    public init(
        receiptID: String,
        correlationID: String,
        status: TatwoSyncHealthStatusV1,
        attempts: Int,
        errorKind: TatwoSyncErrorKindV1,
        observedAt: Date,
        lastOKAt: Date?,
        acceptedEventIDs: [String] = [],
        queuedEventIDs: [String] = [],
        rejectedEventIDs: [String] = [],
        detail: String
    ) {
        self.schemaVersion = 1
        self.receiptID = receiptID
        self.correlationID = correlationID
        self.status = status
        self.attempts = attempts
        self.hasError = errorKind != .none
        self.errorKind = errorKind
        self.observedAt = observedAt
        self.lastOKAt = lastOKAt
        self.acceptedEventIDs = acceptedEventIDs
        self.queuedEventIDs = queuedEventIDs
        self.rejectedEventIDs = rejectedEventIDs
        self.safetyEvidence = TatwoSyncSafetyEvidenceV1()
        self.detail = detail
    }
}

public enum TatwoDomainSnapshotProducerHealthV1: String, Codable, Hashable, Sendable {
    case healthy
    case degraded
    case failed
}

public struct TatwoDomainDeviceSnapshotV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let domainID: String
    public let producerHealth: TatwoDomainSnapshotProducerHealthV1
    public let producerReceiptSHA256: String
    public let observedAt: Date
    public let devices: [TatwoDomainDeviceV1]
    public let authorityLeases: [TatwoAuthorityLeaseV1]

    public init(
        schemaVersion: Int = 1,
        protocolVersion: Int,
        domainID: String,
        producerHealth: TatwoDomainSnapshotProducerHealthV1,
        producerReceiptSHA256: String,
        observedAt: Date,
        devices: [TatwoDomainDeviceV1],
        authorityLeases: [TatwoAuthorityLeaseV1]
    ) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.domainID = domainID
        self.producerHealth = producerHealth
        self.producerReceiptSHA256 = producerReceiptSHA256
        self.observedAt = observedAt
        self.devices = devices
        self.authorityLeases = authorityLeases
    }
}

public enum TatwoDomainSnapshotValidationError: Error, Equatable, Sendable {
    case invalidSchema
    case invalidProtocol
    case invalidDomain
    case invalidProducerDigest
    case unhealthyProducer
    case duplicateDevice
    case deviceSchemaIncompatible
    case deviceProtocolIncompatible
    case deviceDomainMismatch
    case duplicateLeaseReceipt
    case leaseDomainMismatch
    case leaseHolderMissing
    case invalidLease
    case splitBrain
}

public enum TatwoDomainSnapshotValidatorV1 {
    public static func validate(
        _ snapshot: TatwoDomainDeviceSnapshotV1,
        supportedSchemaVersion: Int = 1,
        supportedProtocolVersion: Int = 1,
        now: Date? = nil
    ) throws {
        guard snapshot.schemaVersion == supportedSchemaVersion else {
            throw TatwoDomainSnapshotValidationError.invalidSchema
        }
        guard snapshot.protocolVersion == supportedProtocolVersion else {
            throw TatwoDomainSnapshotValidationError.invalidProtocol
        }
        guard isBoundedText(snapshot.domainID) else {
            throw TatwoDomainSnapshotValidationError.invalidDomain
        }
        guard isSHA256(snapshot.producerReceiptSHA256),
              !isPlaceholderSHA256(snapshot.producerReceiptSHA256)
        else {
            throw TatwoDomainSnapshotValidationError.invalidProducerDigest
        }
        guard snapshot.producerHealth == .healthy else {
            throw TatwoDomainSnapshotValidationError.unhealthyProducer
        }

        let deviceIDs = snapshot.devices.map(\.id)
        guard Set(deviceIDs).count == deviceIDs.count else {
            throw TatwoDomainSnapshotValidationError.duplicateDevice
        }
        guard snapshot.devices.allSatisfy({
            $0.schemaVersion == supportedSchemaVersion
        }) else {
            throw TatwoDomainSnapshotValidationError.deviceSchemaIncompatible
        }
        guard snapshot.devices.allSatisfy({
            $0.protocolVersion == supportedProtocolVersion
        }) else {
            throw TatwoDomainSnapshotValidationError.deviceProtocolIncompatible
        }
        guard snapshot.devices.allSatisfy({
            $0.domainID == snapshot.domainID
                && isBoundedText($0.id)
                && isBoundedText($0.displayName)
        }) else {
            throw TatwoDomainSnapshotValidationError.deviceDomainMismatch
        }

        let receiptIDs = snapshot.authorityLeases.map(\.receiptMetadata.receiptID)
        guard Set(receiptIDs).count == receiptIDs.count else {
            throw TatwoDomainSnapshotValidationError.duplicateLeaseReceipt
        }
        let knownDeviceIDs = Set(deviceIDs)
        guard snapshot.authorityLeases.allSatisfy({ $0.domainID == snapshot.domainID }) else {
            throw TatwoDomainSnapshotValidationError.leaseDomainMismatch
        }
        guard snapshot.authorityLeases.allSatisfy({ knownDeviceIDs.contains($0.holderDeviceID) }) else {
            throw TatwoDomainSnapshotValidationError.leaseHolderMissing
        }
        guard snapshot.authorityLeases.allSatisfy({
            $0.epoch > 0
                && isBoundedText($0.fencingToken)
                && $0.expiresAt > $0.observedAt
        }) else {
            throw TatwoDomainSnapshotValidationError.invalidLease
        }

        if let now {
            let active = snapshot.authorityLeases.filter { $0.expiresAt > now }
            guard active.count <= 1 else {
                throw TatwoDomainSnapshotValidationError.splitBrain
            }
            guard snapshot.authorityLeases.isEmpty || !active.isEmpty else {
                throw TatwoDomainSnapshotValidationError.invalidLease
            }
        }
    }

    public static func isValid(
        _ snapshot: TatwoDomainDeviceSnapshotV1,
        supportedSchemaVersion: Int = 1,
        supportedProtocolVersion: Int = 1,
        now: Date? = nil
    ) -> Bool {
        (try? validate(
            snapshot,
            supportedSchemaVersion: supportedSchemaVersion,
            supportedProtocolVersion: supportedProtocolVersion,
            now: now
        )) != nil
    }

    private static func isBoundedText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.utf8.count <= 256
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isPlaceholderSHA256(_ value: String) -> Bool {
        Set(value).count == 1
    }
}

public protocol DomainDeviceSnapshotProvider {
    func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1?
}

public struct TatwoStaticDomainDeviceSnapshotProvider: DomainDeviceSnapshotProvider, Sendable {
    private let snapshot: TatwoDomainDeviceSnapshotV1?
    private let now: @Sendable () -> Date

    public init(
        snapshot: TatwoDomainDeviceSnapshotV1?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.snapshot = snapshot
        self.now = now
    }

    public func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1? {
        guard let snapshot,
              TatwoDomainSnapshotValidatorV1.isValid(snapshot, now: now())
        else {
            return nil
        }
        return snapshot
    }
}

public struct TatwoRegisterDeviceRequestV1: Codable, Hashable, Sendable {
    public let device: TatwoDomainDeviceV1
    public let correlationID: String

    public init(device: TatwoDomainDeviceV1, correlationID: String) {
        self.device = device
        self.correlationID = correlationID
    }
}

public struct TatwoEnqueueDomainEventRequestV1: Codable, Hashable, Sendable {
    public let event: TatwoDomainEventV1
    public let transportAvailable: Bool
    public let correlationID: String

    public init(
        event: TatwoDomainEventV1,
        transportAvailable: Bool,
        correlationID: String
    ) {
        self.event = event
        self.transportAvailable = transportAvailable
        self.correlationID = correlationID
    }
}

public struct TatwoSyncDomainRequestV1: Codable, Hashable, Sendable {
    public let domainID: String
    public let transportAvailable: Bool
    public let correlationID: String

    public init(domainID: String, transportAvailable: Bool, correlationID: String) {
        self.domainID = domainID
        self.transportAvailable = transportAvailable
        self.correlationID = correlationID
    }
}

public struct TatwoDomainCoordinatorAppendAcknowledgementV1:
    Codable,
    Hashable,
    Sendable
{
    public let code: String
    public let eventID: String
    public let idempotencyKey: String
    public let sequence: UInt64
    public let payloadDigest: String
    public let idempotentReplay: Bool

    public init(
        code: String,
        eventID: String,
        idempotencyKey: String,
        sequence: UInt64,
        payloadDigest: String,
        idempotentReplay: Bool
    ) {
        self.code = code
        self.eventID = eventID
        self.idempotencyKey = idempotencyKey
        self.sequence = sequence
        self.payloadDigest = payloadDigest
        self.idempotentReplay = idempotentReplay
    }
}

public enum TatwoDomainCoordinatorTransportErrorV1: Error, Equatable, Sendable {
    case unavailable
    case credentialMissing
    case insecureEndpoint
    case remoteRejected(statusCode: Int, code: String)
    case malformedResponse
    case acknowledgementMismatch

    public var isRetryable: Bool {
        switch self {
        case .unavailable:
            true
        case .remoteRejected(let statusCode, _):
            statusCode == 408 || statusCode == 429 || statusCode >= 500
        case .credentialMissing,
             .insecureEndpoint,
             .malformedResponse,
             .acknowledgementMismatch:
            false
        }
    }
}

public protocol TatwoDomainCoordinatorTransportPort: AnyObject {
    func append(
        event: TatwoDomainEventV1,
        correlationID: String
    ) throws -> TatwoDomainCoordinatorAppendAcknowledgementV1
}

public struct TatwoAuthorityTransferRequestV1: Codable, Hashable, Sendable {
    public let domainID: String
    public let fromDeviceID: String
    public let toDeviceID: String
    public let humanConfirmationReceiptID: String?
    public let correlationID: String

    public init(
        domainID: String,
        fromDeviceID: String,
        toDeviceID: String,
        humanConfirmationReceiptID: String?,
        correlationID: String
    ) {
        self.domainID = domainID
        self.fromDeviceID = fromDeviceID
        self.toDeviceID = toDeviceID
        self.humanConfirmationReceiptID = humanConfirmationReceiptID
        self.correlationID = correlationID
    }
}

public protocol TatwoDataCommandPort {
    func registerDevice(_ request: TatwoRegisterDeviceRequestV1) -> TatwoSyncHealthReceiptV1
    func enqueueEvent(_ request: TatwoEnqueueDomainEventRequestV1) -> TatwoSyncHealthReceiptV1
    func sync(_ request: TatwoSyncDomainRequestV1) -> TatwoSyncHealthReceiptV1
    func requestAuthorityTransfer(
        _ request: TatwoAuthorityTransferRequestV1
    ) -> TatwoSyncHealthReceiptV1
}

extension TatwoDomainEventKindV1: CaseIterable {}

extension TatwoDomainPayloadClassV1: CaseIterable {}

public struct TatwoCoordinatorSnapshotSummaryV1: Codable, Hashable, Sendable {
    public let domainID: String
    public let nextSequence: UInt64
    public let activeLease: TatwoAuthorityLeaseV1?
    /// Lightweight lease facts lifted directly from the coordinator's raw
    /// `activeLease` JSON (`leaseEpoch` / `holderDeviceID` in `core.mjs`
    /// `publicSnapshot()`), surfaced even when the full
    /// `TatwoAuthorityLeaseV1` cannot be reconstructed without fabricating
    /// `receiptMetadata`. Additive: absent keys decode as `nil`.
    public let activeLeaseEpoch: UInt64?
    public let activeLeaseHolderDeviceID: String?

    public init(
        domainID: String,
        nextSequence: UInt64,
        activeLease: TatwoAuthorityLeaseV1?,
        activeLeaseEpoch: UInt64? = nil,
        activeLeaseHolderDeviceID: String? = nil
    ) {
        self.domainID = domainID
        self.nextSequence = nextSequence
        self.activeLease = activeLease
        self.activeLeaseEpoch = activeLeaseEpoch
        self.activeLeaseHolderDeviceID = activeLeaseHolderDeviceID
    }
}

public struct TatwoAuthorityLeaseGrantRequestV1: Codable, Hashable, Sendable {
    public let domainID: String
    public let toDeviceID: String
    public let leaseEpoch: UInt64
    public let fencingToken: String
    public let expectedSequence: UInt64
    public let expiresAt: Date
    public let approvalID: String
    public let approvedAt: Date
    public let idempotencyKey: String
    public let correlationID: String

    public init(
        domainID: String,
        toDeviceID: String,
        leaseEpoch: UInt64,
        fencingToken: String,
        expectedSequence: UInt64,
        expiresAt: Date,
        approvalID: String,
        approvedAt: Date,
        idempotencyKey: String,
        correlationID: String
    ) {
        self.domainID = domainID
        self.toDeviceID = toDeviceID
        self.leaseEpoch = leaseEpoch
        self.fencingToken = fencingToken
        self.expectedSequence = expectedSequence
        self.expiresAt = expiresAt
        self.approvalID = approvalID
        self.approvedAt = approvedAt
        self.idempotencyKey = idempotencyKey
        self.correlationID = correlationID
    }
}

public struct TatwoAuthorityLeaseGrantAcknowledgementV1: Codable, Hashable, Sendable {
    public let code: String
    public let sequence: UInt64
    public let holderDeviceID: String
    public let leaseEpoch: UInt64
    public let fencingToken: String
    public let expiresAt: Date
    public let idempotentReplay: Bool

    public init(
        code: String,
        sequence: UInt64,
        holderDeviceID: String,
        leaseEpoch: UInt64,
        fencingToken: String,
        expiresAt: Date,
        idempotentReplay: Bool
    ) {
        self.code = code
        self.sequence = sequence
        self.holderDeviceID = holderDeviceID
        self.leaseEpoch = leaseEpoch
        self.fencingToken = fencingToken
        self.expiresAt = expiresAt
        self.idempotentReplay = idempotentReplay
    }
}

public protocol TatwoDomainAuthorityCoordinatorPort: AnyObject {
    func fetchSnapshotSummary(domainID: String) throws -> TatwoCoordinatorSnapshotSummaryV1
    func grantAuthorityLease(
        _ request: TatwoAuthorityLeaseGrantRequestV1
    ) throws -> TatwoAuthorityLeaseGrantAcknowledgementV1
}

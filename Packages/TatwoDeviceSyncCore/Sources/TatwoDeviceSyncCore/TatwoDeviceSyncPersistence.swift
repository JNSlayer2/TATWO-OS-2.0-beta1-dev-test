import CryptoKit
import Foundation
import TatwoDomainContracts

public enum TatwoDeviceSyncPersistenceKindV1: String, Codable, Hashable, Sendable {
    case offlineQueue
    case syncState
    case verifiedSnapshot
}

public enum TatwoDeviceSyncPersistenceError: Error, LocalizedError {
    case invalidPersistenceRoot
    case invalidEvent(String)
    case protectedPayload(String)
    case payloadClassMismatch(String)
    case invalidSnapshot
    case noRecoverableGeneration(
        kind: TatwoDeviceSyncPersistenceKindV1,
        corruptArtifactURLs: [URL]
    )

    public var errorDescription: String? {
        switch self {
        case .invalidPersistenceRoot:
            "Device Sync persistence root must be a local file URL."
        case .invalidEvent(let eventID):
            "Event \(eventID) is not eligible for durable queue persistence."
        case .protectedPayload(let eventID):
            "Protected event \(eventID) is not eligible for durable queue persistence."
        case .payloadClassMismatch(let eventID):
            "Event \(eventID) has a kind/payload-class mismatch."
        case .invalidSnapshot:
            "Snapshot failed domain validation before persistence."
        case .noRecoverableGeneration(let kind, let corruptArtifactURLs):
            "No recoverable \(kind.rawValue) generation exists; corrupt artifacts preserved: \(corruptArtifactURLs.count)."
        }
    }
}

public struct TatwoPersistedQueueLoadV1: Sendable {
    public let events: [TatwoDomainEventV1]
    public let sourceURL: URL?
    public let recoveredFromCorruption: Bool
    public let corruptArtifactURLs: [URL]

    public init(
        events: [TatwoDomainEventV1],
        sourceURL: URL?,
        recoveredFromCorruption: Bool,
        corruptArtifactURLs: [URL]
    ) {
        self.events = events
        self.sourceURL = sourceURL
        self.recoveredFromCorruption = recoveredFromCorruption
        self.corruptArtifactURLs = corruptArtifactURLs
    }
}

public struct TatwoPersistedSnapshotLoadV1: Sendable {
    public let snapshot: TatwoDomainDeviceSnapshotV1?
    public let sourceURL: URL?
    public let recoveredFromCorruption: Bool
    public let corruptArtifactURLs: [URL]

    public init(
        snapshot: TatwoDomainDeviceSnapshotV1?,
        sourceURL: URL?,
        recoveredFromCorruption: Bool,
        corruptArtifactURLs: [URL]
    ) {
        self.snapshot = snapshot
        self.sourceURL = sourceURL
        self.recoveredFromCorruption = recoveredFromCorruption
        self.corruptArtifactURLs = corruptArtifactURLs
    }
}

public struct TatwoPersistedDeviceSyncStateV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let domainID: String
    public let lastAcceptedDomainSequence: UInt64
    public let queuedEvents: [TatwoDomainEventV1]
    public let uncertainDeliveryEventIDs: [String]

    public init(
        domainID: String,
        lastAcceptedDomainSequence: UInt64,
        queuedEvents: [TatwoDomainEventV1],
        uncertainDeliveryEventIDs: [String] = []
    ) {
        schemaVersion = 1
        self.domainID = domainID
        self.lastAcceptedDomainSequence = lastAcceptedDomainSequence
        self.queuedEvents = queuedEvents
        self.uncertainDeliveryEventIDs = uncertainDeliveryEventIDs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case domainID
        case lastAcceptedDomainSequence
        case queuedEvents
        case uncertainDeliveryEventIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        domainID = try container.decode(String.self, forKey: .domainID)
        lastAcceptedDomainSequence = try container.decode(
            UInt64.self,
            forKey: .lastAcceptedDomainSequence
        )
        queuedEvents = try container.decode(
            [TatwoDomainEventV1].self,
            forKey: .queuedEvents
        )
        uncertainDeliveryEventIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .uncertainDeliveryEventIDs
        ) ?? []
    }
}

public struct TatwoPersistedDeviceSyncStateLoadV1: Sendable {
    public let state: TatwoPersistedDeviceSyncStateV1
    public let sourceURL: URL?
    public let recoveredFromCorruption: Bool
    public let corruptArtifactURLs: [URL]

    public init(
        state: TatwoPersistedDeviceSyncStateV1,
        sourceURL: URL?,
        recoveredFromCorruption: Bool,
        corruptArtifactURLs: [URL]
    ) {
        self.state = state
        self.sourceURL = sourceURL
        self.recoveredFromCorruption = recoveredFromCorruption
        self.corruptArtifactURLs = corruptArtifactURLs
    }
}

public protocol TatwoDeviceSyncPersistenceAdapter: AnyObject {
    func loadOfflineQueue() throws -> TatwoPersistedQueueLoadV1

    @discardableResult
    func persistOfflineQueue(_ events: [TatwoDomainEventV1]) throws -> URL

    func loadSyncState(
        domainID: String
    ) throws -> TatwoPersistedDeviceSyncStateLoadV1

    @discardableResult
    func persistSyncState(
        _ state: TatwoPersistedDeviceSyncStateV1
    ) throws -> URL

    func loadVerifiedSnapshot(
        supportedSchemaVersion: Int,
        supportedProtocolVersion: Int
    ) throws -> TatwoPersistedSnapshotLoadV1

    @discardableResult
    func persistVerifiedSnapshot(_ snapshot: TatwoDomainDeviceSnapshotV1) throws -> URL
}

public final class TatwoFileBackedDeviceSyncPersistenceAdapter:
    TatwoDeviceSyncPersistenceAdapter
{
    private struct Envelope: Codable {
        let schemaVersion: Int
        let kind: TatwoDeviceSyncPersistenceKindV1
        let createdAt: Date
        let payloadSHA256: String
        let payload: Data
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        createRootIfMissing: Bool = true,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init
    ) throws {
        guard rootURL.isFileURL else {
            throw TatwoDeviceSyncPersistenceError.invalidPersistenceRoot
        }
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
        self.makeUUID = makeUUID
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        if createRootIfMissing {
            try fileManager.createDirectory(
                at: self.rootURL,
                withIntermediateDirectories: true
            )
        }
    }

    public func loadOfflineQueue() throws -> TatwoPersistedQueueLoadV1 {
        let result: LoadResult<[TatwoDomainEventV1]> = try loadLatest(
            kind: .offlineQueue,
            emptyValue: []
        ) { [self] events in
            try events.forEach(validatePersistableEvent)
        }
        return TatwoPersistedQueueLoadV1(
            events: result.value,
            sourceURL: result.sourceURL,
            recoveredFromCorruption: !result.corruptArtifactURLs.isEmpty,
            corruptArtifactURLs: result.corruptArtifactURLs
        )
    }

    @discardableResult
    public func persistOfflineQueue(_ events: [TatwoDomainEventV1]) throws -> URL {
        try events.forEach(validatePersistableEvent)
        return try persist(events, kind: .offlineQueue)
    }

    public func loadSyncState(
        domainID: String
    ) throws -> TatwoPersistedDeviceSyncStateLoadV1 {
        let emptyState = TatwoPersistedDeviceSyncStateV1(
            domainID: domainID,
            lastAcceptedDomainSequence: 0,
            queuedEvents: []
        )
        let result: LoadResult<TatwoPersistedDeviceSyncStateV1> = try loadLatest(
            kind: .syncState,
            emptyValue: emptyState
        ) { [self] state in
            try validateSyncState(state, expectedDomainID: domainID)
        }
        if result.sourceURL != nil {
            return TatwoPersistedDeviceSyncStateLoadV1(
                state: result.value,
                sourceURL: result.sourceURL,
                recoveredFromCorruption: !result.corruptArtifactURLs.isEmpty,
                corruptArtifactURLs: result.corruptArtifactURLs
            )
        }

        // Candidate migration path: a pre-cursor queue may exist from the
        // immediately preceding isolated build. Infer only the prefix before
        // the first queued sequence; never infer an accepted event from prose.
        let legacy = try loadOfflineQueue()
        let inferredCursor: UInt64
        if let firstSequence = legacy.events.map(\.sequence).min() {
            guard firstSequence > 0,
                  firstSequence <= TatwoDomainEventV1.maximumSafeSequence
            else {
                throw TatwoDeviceSyncPersistenceError.invalidEvent(
                    legacy.events.first?.eventID ?? "legacy-offline-queue"
                )
            }
            inferredCursor = firstSequence - 1
        } else {
            inferredCursor = 0
        }
        let migrated = TatwoPersistedDeviceSyncStateV1(
            domainID: domainID,
            lastAcceptedDomainSequence: inferredCursor,
            queuedEvents: legacy.events,
            uncertainDeliveryEventIDs: []
        )
        try validateSyncState(migrated, expectedDomainID: domainID)
        return TatwoPersistedDeviceSyncStateLoadV1(
            state: migrated,
            sourceURL: legacy.sourceURL,
            recoveredFromCorruption: legacy.recoveredFromCorruption,
            corruptArtifactURLs: legacy.corruptArtifactURLs
        )
    }

    @discardableResult
    public func persistSyncState(
        _ state: TatwoPersistedDeviceSyncStateV1
    ) throws -> URL {
        try validateSyncState(state, expectedDomainID: state.domainID)
        return try persist(state, kind: .syncState)
    }

    public func loadVerifiedSnapshot(
        supportedSchemaVersion: Int = 1,
        supportedProtocolVersion: Int = 1
    ) throws -> TatwoPersistedSnapshotLoadV1 {
        let observedAt = now()
        let result: LoadResult<TatwoDomainDeviceSnapshotV1?> = try loadLatest(
            kind: .verifiedSnapshot,
            emptyValue: nil
        ) { snapshot in
            guard let snapshot else {
                throw TatwoDeviceSyncPersistenceError.invalidSnapshot
            }
            try TatwoDomainSnapshotValidatorV1.validate(
                snapshot,
                supportedSchemaVersion: supportedSchemaVersion,
                supportedProtocolVersion: supportedProtocolVersion,
                now: observedAt
            )
        }
        return TatwoPersistedSnapshotLoadV1(
            snapshot: result.value,
            sourceURL: result.sourceURL,
            recoveredFromCorruption: !result.corruptArtifactURLs.isEmpty,
            corruptArtifactURLs: result.corruptArtifactURLs
        )
    }

    @discardableResult
    public func persistVerifiedSnapshot(
        _ snapshot: TatwoDomainDeviceSnapshotV1
    ) throws -> URL {
        guard TatwoDomainSnapshotValidatorV1.isValid(snapshot, now: now()) else {
            throw TatwoDeviceSyncPersistenceError.invalidSnapshot
        }
        return try persist(snapshot, kind: .verifiedSnapshot)
    }

    private struct LoadResult<Value> {
        let value: Value
        let sourceURL: URL?
        let corruptArtifactURLs: [URL]
    }

    private func loadLatest<Value: Codable>(
        kind: TatwoDeviceSyncPersistenceKindV1,
        emptyValue: Value,
        validate: (Value) throws -> Void
    ) throws -> LoadResult<Value> {
        let generationURLs = try generationURLs(for: kind)
        guard !generationURLs.isEmpty else {
            return LoadResult(
                value: emptyValue,
                sourceURL: nil,
                corruptArtifactURLs: []
            )
        }

        var corruptArtifactURLs: [URL] = []
        for generationURL in generationURLs {
            do {
                let envelopeData = try Data(contentsOf: generationURL)
                let envelope = try decoder.decode(Envelope.self, from: envelopeData)
                guard envelope.schemaVersion == 1, envelope.kind == kind else {
                    throw TatwoDeviceSyncPersistenceError.noRecoverableGeneration(
                        kind: kind,
                        corruptArtifactURLs: [generationURL]
                    )
                }
                guard Self.sha256(envelope.payload) == envelope.payloadSHA256 else {
                    throw TatwoDeviceSyncPersistenceError.noRecoverableGeneration(
                        kind: kind,
                        corruptArtifactURLs: [generationURL]
                    )
                }
                let value = try decoder.decode(Value.self, from: envelope.payload)
                try validate(value)
                return LoadResult(
                    value: value,
                    sourceURL: generationURL,
                    corruptArtifactURLs: corruptArtifactURLs
                )
            } catch {
                // Generations are append-only. The corrupt artifact stays untouched as
                // evidence while an older verified generation is considered.
                corruptArtifactURLs.append(generationURL)
            }
        }

        throw TatwoDeviceSyncPersistenceError.noRecoverableGeneration(
            kind: kind,
            corruptArtifactURLs: corruptArtifactURLs
        )
    }

    private func persist<Value: Codable>(
        _ value: Value,
        kind: TatwoDeviceSyncPersistenceKindV1
    ) throws -> URL {
        let payload = try encoder.encode(value)
        let envelope = Envelope(
            schemaVersion: 1,
            kind: kind,
            createdAt: now(),
            payloadSHA256: Self.sha256(payload),
            payload: payload
        )
        let envelopeData = try encoder.encode(envelope)
        let directory = directoryURL(for: kind)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let generation = String(
            format: "%020llu",
            try nextGenerationOrdinal(in: directory)
        )
        let destination = directory.appendingPathComponent(
            "generation-\(generation)-\(makeUUID().uuidString.lowercased()).json",
            isDirectory: false
        )
        try envelopeData.write(to: destination, options: [.atomic])
        return destination
    }

    private func generationURLs(
        for kind: TatwoDeviceSyncPersistenceKindV1
    ) throws -> [URL] {
        let directory = directoryURL(for: kind)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func nextGenerationOrdinal(in directory: URL) throws -> UInt64 {
        let existing = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let maximum = existing.compactMap { url -> UInt64? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("generation-") else { return nil }
            let components = name.split(separator: "-", maxSplits: 2)
            guard components.count >= 2 else { return nil }
            return UInt64(components[1])
        }.max() ?? 0
        return maximum + 1
    }

    private func directoryURL(
        for kind: TatwoDeviceSyncPersistenceKindV1
    ) -> URL {
        rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    private func validatePersistableEvent(_ event: TatwoDomainEventV1) throws {
        guard !event.payloadClass.isProtected else {
            throw TatwoDeviceSyncPersistenceError.protectedPayload(event.eventID)
        }
        guard event.payloadClass.isAllowed(for: event.kind) else {
            throw TatwoDeviceSyncPersistenceError.payloadClassMismatch(event.eventID)
        }
        guard Self.isBounded(event.eventID),
              Self.isBounded(event.domainID),
              Self.isBounded(event.deviceID),
              Self.isBounded(event.fencingToken),
              Self.isBounded(event.idempotencyKey),
              event.sequence > 0,
              event.sequence <= TatwoDomainEventV1.maximumSafeSequence,
              event.schemaVersion > 0,
              event.protocolVersion > 0,
              Self.isSHA256(event.payloadDigest)
        else {
            throw TatwoDeviceSyncPersistenceError.invalidEvent(event.eventID)
        }
        do {
            try TatwoDomainPayloadValidatorV1.validate(
                event.payload,
                expectedDigest: event.payloadDigest
            )
        } catch {
            throw TatwoDeviceSyncPersistenceError.invalidEvent(event.eventID)
        }
    }

    private func validateSyncState(
        _ state: TatwoPersistedDeviceSyncStateV1,
        expectedDomainID: String
    ) throws {
        guard state.schemaVersion == 1,
              state.domainID == expectedDomainID,
              Self.isBounded(state.domainID),
              state.lastAcceptedDomainSequence
                <= TatwoDomainEventV1.maximumSafeSequence
        else {
            throw TatwoDeviceSyncPersistenceError.invalidEvent("sync-state")
        }
        try state.queuedEvents.forEach(validatePersistableEvent)
        guard state.queuedEvents.allSatisfy({ $0.domainID == state.domainID }) else {
            throw TatwoDeviceSyncPersistenceError.invalidEvent("sync-state-domain")
        }
        let ordered = state.queuedEvents.sorted { $0.sequence < $1.sequence }
        guard Set(ordered.map(\.idempotencyKey)).count == ordered.count,
              Set(ordered.map(\.eventID)).count == ordered.count
        else {
            throw TatwoDeviceSyncPersistenceError.invalidEvent("sync-state-duplicate")
        }
        let queuedEventIDs = Set(ordered.map(\.eventID))
        let uncertainEventIDs = Set(state.uncertainDeliveryEventIDs)
        guard uncertainEventIDs.count == state.uncertainDeliveryEventIDs.count,
              uncertainEventIDs.isSubset(of: queuedEventIDs)
        else {
            throw TatwoDeviceSyncPersistenceError.invalidEvent(
                "sync-state-uncertain-delivery"
            )
        }
        var previous = state.lastAcceptedDomainSequence
        for event in ordered {
            let (expected, overflow) = previous.addingReportingOverflow(1)
            guard !overflow,
                  expected <= TatwoDomainEventV1.maximumSafeSequence
            else {
                throw TatwoDeviceSyncPersistenceError.invalidEvent(event.eventID)
            }
            guard event.sequence == expected else {
                throw TatwoDeviceSyncPersistenceError.invalidEvent(event.eventID)
            }
            previous = event.sequence
        }
    }

    private static func isBounded(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.utf8.count <= 256
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public final class TatwoPersistedDomainDeviceSnapshotProvider:
    DomainDeviceSnapshotProvider
{
    private let persistenceAdapter: any TatwoDeviceSyncPersistenceAdapter
    private let supportedSchemaVersion: Int
    private let supportedProtocolVersion: Int
    private let now: @Sendable () -> Date

    public private(set) var lastLoad: TatwoPersistedSnapshotLoadV1?
    public private(set) var lastErrorDescription: String?

    public init(
        persistenceAdapter: any TatwoDeviceSyncPersistenceAdapter,
        supportedSchemaVersion: Int = 1,
        supportedProtocolVersion: Int = 1,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistenceAdapter = persistenceAdapter
        self.supportedSchemaVersion = supportedSchemaVersion
        self.supportedProtocolVersion = supportedProtocolVersion
        self.now = now
    }

    public func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1? {
        do {
            let loaded = try persistenceAdapter.loadVerifiedSnapshot(
                supportedSchemaVersion: supportedSchemaVersion,
                supportedProtocolVersion: supportedProtocolVersion
            )
            lastLoad = loaded
            guard let snapshot = loaded.snapshot else {
                lastErrorDescription = nil
                return nil
            }
            guard TatwoDomainSnapshotValidatorV1.isValid(
                snapshot,
                supportedSchemaVersion: supportedSchemaVersion,
                supportedProtocolVersion: supportedProtocolVersion,
                now: now()
            ) else {
                lastErrorDescription =
                    "Persisted snapshot failed provider-side domain validation"
                return nil
            }
            lastErrorDescription = nil
            return snapshot
        } catch {
            lastLoad = nil
            lastErrorDescription = String(describing: error)
            return nil
        }
    }
}

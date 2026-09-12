import Foundation
import TatwoDomainContracts

public enum TatwoDataPlaneObservedEffectV1: Equatable, Sendable {
    case dataCommandStarted(String)
    case updaterInvocation
    case bundleMutation
    case hostOrRunnerStart

    public var isForbiddenCrossPlaneEffect: Bool {
        switch self {
        case .dataCommandStarted:
            false
        case .updaterInvocation, .bundleMutation, .hostOrRunnerStart:
            true
        }
    }
}

public protocol TatwoDataPlaneEffectObserver: AnyObject {
    func record(_ effect: TatwoDataPlaneObservedEffectV1)
}

public final class TatwoDeviceSyncCore: TatwoDataCommandPort, DomainDeviceSnapshotProvider {
    public static let maximumHeartbeatAge: TimeInterval = 120
    public static let maximumAuthorityLeaseDuration: TimeInterval = 24 * 60 * 60

    private let domainID: String
    private let supportedSchemaVersion: Int
    private let supportedProtocolVersion: Int
    private let makeReceiptID: () -> String
    private let snapshotProducerReceiptSHA256: () -> String?
    private let persistenceAdapter: (any TatwoDeviceSyncPersistenceAdapter)?
    private let transport: (any TatwoDomainCoordinatorTransportPort)?
    private let effectObserver: (any TatwoDataPlaneEffectObserver)?
    private let originAuthorityProvider: any TatwoOriginAuthorityProviding
    private let now: () -> Date
    private var devicesByID: [String: TatwoDomainDeviceV1]
    private var authorityLeases: [TatwoAuthorityLeaseV1]
    private var retiredAuthorityLeases: [TatwoAuthorityLeaseV1]
    private var queuedEvents: [TatwoDomainEventV1]
    private var uncertainDeliveryEventIDs: Set<String>
    private var acceptedEventsByIdempotencyKey: [String: TatwoDomainEventV1]
    private var lastAcceptedDomainSequence: UInt64
    private var snapshotIntegrityIsValid: Bool
    private var persistenceLoadFailureDetail: String?
    private var persistenceRecoveryArtifactCount: Int
    private var lastOKAt: Date?

    public init(
        domainID: String,
        supportedSchemaVersion: Int = 1,
        supportedProtocolVersion: Int = 1,
        initialDevices: [TatwoDomainDeviceV1] = [],
        authorityLeases: [TatwoAuthorityLeaseV1] = [],
        receiptID: @escaping () -> String = { UUID().uuidString },
        snapshotProducerReceiptSHA256: @escaping () -> String? = { nil },
        persistenceAdapter: (any TatwoDeviceSyncPersistenceAdapter)? = nil,
        transport: (any TatwoDomainCoordinatorTransportPort)? = nil,
        effectObserver: (any TatwoDataPlaneEffectObserver)? = nil,
        originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil,
        initialAcceptedDomainSequence: UInt64 = 0,
        now: @escaping () -> Date = Date.init
    ) {
        self.domainID = domainID
        self.supportedSchemaVersion = supportedSchemaVersion
        self.supportedProtocolVersion = supportedProtocolVersion
        self.devicesByID = Dictionary(uniqueKeysWithValues: initialDevices.map { ($0.id, $0) })
        self.authorityLeases = authorityLeases
        self.retiredAuthorityLeases = []
        self.queuedEvents = []
        self.uncertainDeliveryEventIDs = []
        self.acceptedEventsByIdempotencyKey = [:]
        self.lastAcceptedDomainSequence = min(
            initialAcceptedDomainSequence,
            TatwoDomainEventV1.maximumSafeSequence
        )
        self.snapshotIntegrityIsValid = true
        self.persistenceLoadFailureDetail =
            initialAcceptedDomainSequence <= TatwoDomainEventV1.maximumSafeSequence
                ? nil
                : "Initial sync cursor exceeds the cross-runtime safe integer range"
        self.persistenceRecoveryArtifactCount = 0
        self.makeReceiptID = receiptID
        self.snapshotProducerReceiptSHA256 = snapshotProducerReceiptSHA256
        self.persistenceAdapter = persistenceAdapter
        self.transport = transport
        self.effectObserver = effectObserver
        self.originAuthorityProvider =
            originAuthorityProvider ?? TatwoDefaultOriginAuthorityProvider()
        self.now = now

        if let persistenceAdapter, self.persistenceLoadFailureDetail == nil {
            do {
                let persisted = try persistenceAdapter.loadSyncState(
                    domainID: domainID
                )
                guard persisted.state.lastAcceptedDomainSequence
                        >= initialAcceptedDomainSequence,
                      persisted.state.lastAcceptedDomainSequence
                        <= TatwoDomainEventV1.maximumSafeSequence,
                      persisted.state.queuedEvents.allSatisfy({
                    $0.domainID == domainID
                        && !$0.payloadClass.isProtected
                        && $0.payloadClass.isAllowed(for: $0.kind)
                        && Self.hasValidPayload($0)
                }) else {
                    throw TatwoDeviceSyncPersistenceError.invalidEvent(
                        persisted.state.queuedEvents.first?.eventID ?? "sync-state"
                    )
                }
                self.lastAcceptedDomainSequence =
                    persisted.state.lastAcceptedDomainSequence
                self.queuedEvents = persisted.state.queuedEvents
                self.uncertainDeliveryEventIDs = Set(
                    persisted.state.uncertainDeliveryEventIDs
                )
                self.persistenceRecoveryArtifactCount =
                    persisted.corruptArtifactURLs.count
            } catch {
                self.persistenceLoadFailureDetail =
                    "Persistent sync cursor and offline queue could not be restored safely"
            }
        }
    }

    public func registerDevice(
        _ request: TatwoRegisterDeviceRequestV1
    ) -> TatwoSyncHealthReceiptV1 {
        effectObserver?.record(.dataCommandStarted("registerDevice"))
        let observedAt = now()
        guard request.device.domainID == domainID else {
            return failure(
                correlationID: request.correlationID,
                error: .invalidDomain,
                observedAt: observedAt,
                detail: "Device domain does not match coordinator domain"
            )
        }
        guard request.device.schemaVersion == supportedSchemaVersion else {
            return failure(
                correlationID: request.correlationID,
                error: .schemaIncompatible,
                observedAt: observedAt,
                detail: "Device schema is incompatible"
            )
        }
        guard request.device.protocolVersion == supportedProtocolVersion else {
            return failure(
                correlationID: request.correlationID,
                error: .protocolIncompatible,
                observedAt: observedAt,
                detail: "Device protocol is incompatible"
            )
        }
        devicesByID[request.device.id] = request.device
        lastOKAt = observedAt
        return success(
            correlationID: request.correlationID,
            observedAt: observedAt,
            detail: "Device registered without granting authority"
        )
    }

    public func enqueueEvent(
        _ request: TatwoEnqueueDomainEventRequestV1
    ) -> TatwoSyncHealthReceiptV1 {
        effectObserver?.record(.dataCommandStarted("enqueueEvent"))
        let observedAt = now()
        let event = request.event

        if let persistenceLoadFailureDetail {
            return failure(
                correlationID: request.correlationID,
                error: .persistenceFailure,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: persistenceLoadFailureDetail
            )
        }

        if event.payloadClass.isProtected {
            return failure(
                correlationID: request.correlationID,
                error: .protectedDataRejected,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Protected data class is never eligible for domain sync"
            )
        }
        guard event.payloadClass.isAllowed(for: event.kind) else {
            return failure(
                correlationID: request.correlationID,
                error: .payloadClassMismatch,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Event kind and payload class are not an allowed typed sync pair"
            )
        }
        do {
            try TatwoDomainPayloadValidatorV1.validate(
                event.payload,
                expectedDigest: event.payloadDigest
            )
        } catch TatwoDomainPayloadValidationErrorV1.digestMismatch {
            return failure(
                correlationID: request.correlationID,
                error: .payloadDigestMismatch,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Event payload digest does not match canonical JSON"
            )
        } catch {
            return failure(
                correlationID: request.correlationID,
                error: .payloadInvalid,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Event payload is not eligible for domain sync"
            )
        }

        guard snapshotIntegrityIsValid else {
            return failure(
                correlationID: request.correlationID,
                error: .snapshotCorrupt,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Snapshot integrity is invalid"
            )
        }
        if let topologyFailure = validateTopology(observedAt: observedAt) {
            return failure(
                correlationID: request.correlationID,
                error: topologyFailure,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Domain topology is not safe to enqueue"
            )
        }
        if let existing = acceptedEventsByIdempotencyKey[event.idempotencyKey] {
            guard existing == event else {
                return failure(
                    correlationID: request.correlationID,
                    error: .duplicateConflict,
                    observedAt: observedAt,
                    rejected: [event.eventID],
                    detail: "Idempotency key already exists with divergent event content"
                )
            }
            lastOKAt = observedAt
            return success(
                correlationID: request.correlationID,
                observedAt: observedAt,
                accepted: [existing.eventID],
                detail: "Duplicate event ignored idempotently"
            )
        }
        if let queued = queuedEvents.first(where: { $0.idempotencyKey == event.idempotencyKey }) {
            guard queued == event else {
                return failure(
                    correlationID: request.correlationID,
                    error: .duplicateConflict,
                    observedAt: observedAt,
                    rejected: [event.eventID],
                    detail: "Offline queue contains divergent idempotency content"
                )
            }
            return degraded(
                correlationID: request.correlationID,
                error: .transportOffline,
                observedAt: observedAt,
                queued: [queued.eventID],
                detail: "Event already queued while transport is offline"
            )
        }
        if event.sequence <= lastAcceptedDomainSequence {
            return verifyPreviouslyAcceptedEvent(
                event,
                transportAvailable: request.transportAvailable,
                correlationID: request.correlationID,
                observedAt: observedAt
            )
        }
        if let validationFailure = validate(
            event: event,
            observedAt: observedAt,
            includeQueuedPredecessors: true
        ) {
            return failure(
                correlationID: request.correlationID,
                error: validationFailure,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Event rejected by fail-closed domain validation"
            )
        }

        if !request.transportAvailable {
            return queueForReplay(
                event,
                correlationID: request.correlationID,
                observedAt: observedAt,
                error: .transportOffline,
                detail: "Event queued because transport was declared offline"
            )
        }
        if !queuedEvents.isEmpty {
            return queueForReplay(
                event,
                correlationID: request.correlationID,
                observedAt: observedAt,
                error: .transportOffline,
                detail:
                    "Event queued behind the existing ordered replay backlog"
            )
        }

        guard let transport else {
            return queueForReplay(
                event,
                correlationID: request.correlationID,
                observedAt: observedAt,
                error: .transportNotConfigured,
                detail: "Event queued because no coordinator transport adapter is configured"
            )
        }

        do {
            try prepareForTransport(event)
        } catch {
            return failure(
                correlationID: request.correlationID,
                error: .persistenceFailure,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail:
                    "Coordinator transport was not called because durable delivery preparation failed"
            )
        }

        do {
            let acknowledgement = try transport.append(
                event: event,
                correlationID: request.correlationID
            )
            guard acknowledgementMatches(acknowledgement, event: event) else {
                return failure(
                    correlationID: request.correlationID,
                    error: .transportProtocolViolation,
                    observedAt: observedAt,
                    queued: [event.eventID],
                    rejected: [event.eventID],
                    detail:
                        "Coordinator acknowledgement did not match; delivery remains uncertain"
                )
            }
            let remaining = queuedEvents.filter {
                $0.idempotencyKey != event.idempotencyKey
            }
            let remainingUncertain =
                uncertainDeliveryEventIDs.subtracting([event.eventID])
            do {
                try persistSyncState(
                    lastAcceptedDomainSequence: event.sequence,
                    queuedEvents: remaining,
                    uncertainDeliveryEventIDs: remainingUncertain
                )
            } catch {
                return failure(
                    correlationID: request.correlationID,
                    error: .persistenceFailure,
                    observedAt: observedAt,
                    queued: [event.eventID],
                    detail:
                        "Remote acknowledgement was not committed locally; retry the same idempotency key"
                )
            }
            accept(event)
            queuedEvents = remaining
            uncertainDeliveryEventIDs = remainingUncertain
            lastOKAt = observedAt
            return success(
                correlationID: request.correlationID,
                observedAt: observedAt,
                accepted: [event.eventID],
                detail: "Event accepted after coordinator acknowledgement"
            )
        } catch let error as TatwoDomainCoordinatorTransportErrorV1 {
            if error.isRetryable {
                return degraded(
                    correlationID: request.correlationID,
                    error: .transportOffline,
                    observedAt: observedAt,
                    queued: [event.eventID],
                    detail:
                        "Event remains durably queued with uncertain delivery after a retryable transport failure"
                )
            }
            do {
                try clearDeliveryUncertainty(for: event, removeFromQueue: true)
            } catch {
                return failure(
                    correlationID: request.correlationID,
                    error: .persistenceFailure,
                    observedAt: observedAt,
                    queued: [event.eventID],
                    rejected: [event.eventID],
                    detail:
                        "Coordinator rejected the event but durable delivery state could not be cleared"
                )
            }
            return failure(
                correlationID: request.correlationID,
                error: transportErrorKind(error),
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Coordinator rejected the event without a valid acknowledgement"
            )
        } catch {
            return degraded(
                correlationID: request.correlationID,
                error: .transportOffline,
                observedAt: observedAt,
                queued: [event.eventID],
                detail:
                    "Event remains durably queued with uncertain delivery because coordinator transport is unavailable"
            )
        }
    }

    public func sync(_ request: TatwoSyncDomainRequestV1) -> TatwoSyncHealthReceiptV1 {
        effectObserver?.record(.dataCommandStarted("sync"))
        let observedAt = now()
        if let persistenceLoadFailureDetail {
            return failure(
                correlationID: request.correlationID,
                error: .persistenceFailure,
                observedAt: observedAt,
                queued: queuedEvents.map(\.eventID),
                detail: persistenceLoadFailureDetail
            )
        }
        guard request.domainID == domainID else {
            return failure(
                correlationID: request.correlationID,
                error: .invalidDomain,
                observedAt: observedAt,
                detail: "Sync domain does not match coordinator domain"
            )
        }
        guard snapshotIntegrityIsValid else {
            return failure(
                correlationID: request.correlationID,
                error: .snapshotCorrupt,
                observedAt: observedAt,
                detail: "Snapshot integrity is invalid"
            )
        }
        if let topologyFailure = validateTopology(observedAt: observedAt) {
            return failure(
                correlationID: request.correlationID,
                error: topologyFailure,
                observedAt: observedAt,
                detail: "Domain topology is not safe to sync"
            )
        }
        guard request.transportAvailable else {
            return degraded(
                correlationID: request.correlationID,
                error: .transportOffline,
                observedAt: observedAt,
                queued: queuedEvents.map(\.eventID),
                detail: "Transport offline; queue preserved"
            )
        }
        guard let transport else {
            return degraded(
                correlationID: request.correlationID,
                error: .transportNotConfigured,
                observedAt: observedAt,
                queued: queuedEvents.map(\.eventID),
                detail: "No coordinator transport adapter is configured; queue preserved"
            )
        }

        var accepted: [String] = []
        let orderedQueue = queuedEvents.sorted {
            return $0.sequence < $1.sequence
        }
        for event in orderedQueue {
            if let validationError = validate(event: event, observedAt: observedAt) {
                return failure(
                    correlationID: request.correlationID,
                    error: validationError,
                    observedAt: observedAt,
                    accepted: accepted,
                    queued: queuedEvents.map(\.eventID),
                    rejected: [event.eventID],
                    detail: "Queued event replay stopped at first unsafe event"
                )
            }
            guard let expected = Self.nextSequence(
                after: lastAcceptedDomainSequence
            ), event.sequence == expected else {
                return failure(
                    correlationID: request.correlationID,
                    error: .outOfOrder,
                    observedAt: observedAt,
                    accepted: accepted,
                    queued: queuedEvents.map(\.eventID),
                    rejected: [event.eventID],
                    detail: "Queued event sequence is not contiguous"
                )
            }
            let requiresIdempotentReplay =
                uncertainDeliveryEventIDs.contains(event.eventID)
            if !requiresIdempotentReplay {
                do {
                    try markDeliveryUncertain(for: event)
                } catch {
                    return failure(
                        correlationID: request.correlationID,
                        error: .persistenceFailure,
                        observedAt: observedAt,
                        accepted: accepted,
                        queued: queuedEvents.map(\.eventID),
                        rejected: [event.eventID],
                        detail:
                            "Queued replay did not call transport because durable delivery preparation failed"
                    )
                }
            }
            do {
                let acknowledgement = try transport.append(
                    event: event,
                    correlationID: request.correlationID
                )
                guard acknowledgementMatches(acknowledgement, event: event),
                      !requiresIdempotentReplay
                        || acknowledgement.idempotentReplay
                else {
                    return failure(
                        correlationID: request.correlationID,
                        error: .transportProtocolViolation,
                        observedAt: observedAt,
                        accepted: accepted,
                        queued: queuedEvents.map(\.eventID),
                        rejected: [event.eventID],
                        detail:
                            "Queued replay stopped because uncertain delivery was not confirmed idempotently"
                    )
                }

                let remaining = queuedEvents.filter {
                    $0.idempotencyKey != event.idempotencyKey
                }
                let remainingUncertain =
                    uncertainDeliveryEventIDs.subtracting([event.eventID])
                do {
                    try persistSyncState(
                        lastAcceptedDomainSequence: event.sequence,
                        queuedEvents: remaining,
                        uncertainDeliveryEventIDs: remainingUncertain
                    )
                } catch {
                    return failure(
                        correlationID: request.correlationID,
                        error: .persistenceFailure,
                        observedAt: observedAt,
                        accepted: accepted,
                        queued: queuedEvents.map(\.eventID),
                        detail:
                            "Remote acknowledgement was not committed locally; idempotent replay is required"
                    )
                }
                accept(event)
                queuedEvents = remaining
                uncertainDeliveryEventIDs = remainingUncertain
                accepted.append(event.eventID)
            } catch let error as TatwoDomainCoordinatorTransportErrorV1 {
                if error.isRetryable {
                    return degraded(
                        correlationID: request.correlationID,
                        error: .transportOffline,
                        observedAt: observedAt,
                        accepted: accepted,
                        queued: queuedEvents.map(\.eventID),
                        detail:
                            "Queued replay paused after a retryable coordinator transport failure"
                    )
                }
                do {
                    try clearDeliveryUncertainty(
                        for: event,
                        removeFromQueue: false
                    )
                } catch {
                    return failure(
                        correlationID: request.correlationID,
                        error: .persistenceFailure,
                        observedAt: observedAt,
                        accepted: accepted,
                        queued: queuedEvents.map(\.eventID),
                        rejected: [event.eventID],
                        detail:
                            "Coordinator rejected a queued event but durable uncertainty could not be cleared"
                    )
                }
                return failure(
                    correlationID: request.correlationID,
                    error: transportErrorKind(error),
                    observedAt: observedAt,
                    accepted: accepted,
                    queued: queuedEvents.map(\.eventID),
                    rejected: [event.eventID],
                    detail: "Queued replay stopped after a coordinator rejection"
                )
            } catch {
                return degraded(
                    correlationID: request.correlationID,
                    error: .transportOffline,
                    observedAt: observedAt,
                    accepted: accepted,
                    queued: queuedEvents.map(\.eventID),
                    detail: "Queued replay paused because coordinator transport is unavailable"
                )
            }
        }
        lastOKAt = observedAt
        return success(
            correlationID: request.correlationID,
            observedAt: observedAt,
            accepted: accepted,
            detail: "Offline queue replayed in deterministic order"
        )
    }

    public func requestAuthorityTransfer(
        _ request: TatwoAuthorityTransferRequestV1
    ) -> TatwoSyncHealthReceiptV1 {
        effectObserver?.record(.dataCommandStarted("requestAuthorityTransfer"))
        let observedAt = now()
        guard request.domainID == domainID else {
            return failure(
                correlationID: request.correlationID,
                error: .invalidDomain,
                observedAt: observedAt,
                detail: "Authority transfer domain mismatch"
            )
        }
        guard devicesByID[request.fromDeviceID] != nil,
              devicesByID[request.toDeviceID] != nil
        else {
            return failure(
                correlationID: request.correlationID,
                error: .invalidDevice,
                observedAt: observedAt,
                detail: "Authority transfer references an unknown device"
            )
        }
        guard let confirmation = request.humanConfirmationReceiptID,
              !confirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return failure(
                correlationID: request.correlationID,
                error: .humanConfirmationRequired,
                observedAt: observedAt,
                detail: "Authority transfer requires an explicit human confirmation receipt"
            )
        }

        return degraded(
            correlationID: request.correlationID,
            error: .humanConfirmationRequired,
            observedAt: observedAt,
            detail: "Human confirmation recorded; external authority coordinator must issue the new lease"
        )
    }

    public func adoptAuthorityLease(
        _ lease: TatwoAuthorityLeaseV1,
        correlationID: String
    ) -> TatwoSyncHealthReceiptV1 {
        effectObserver?.record(.dataCommandStarted("adoptAuthorityLease"))
        let observedAt = now()
        do {
            try originAuthorityProvider.requireAuthorityLeaseAdoption(
                deviceID: lease.holderDeviceID,
                epoch: lease.epoch,
                surface: "domain_authority_lease_adopt",
                now: observedAt)
        } catch {
            return degraded(
                correlationID: correlationID,
                error: .leaseEpochMismatch,
                observedAt: observedAt,
                detail: "origin_authority_gate:\(error.localizedDescription)")
        }
        guard lease.domainID == domainID else {
            return degraded(
                correlationID: correlationID,
                error: .invalidDomain,
                observedAt: observedAt,
                detail: "Adopted lease domain does not match coordinator domain"
            )
        }
        guard devicesByID[lease.holderDeviceID] != nil else {
            return degraded(
                correlationID: correlationID,
                error: .invalidDevice,
                observedAt: observedAt,
                detail: "Adopted lease holder is not a registered device"
            )
        }
        let knownLeases = authorityLeases + retiredAuthorityLeases
        let maximumKnownEpoch = knownLeases.map(\.epoch).max() ?? 0
        guard lease.epoch > maximumKnownEpoch else {
            return degraded(
                correlationID: correlationID,
                error: .leaseEpochMismatch,
                observedAt: observedAt,
                detail:
                    "Adopted lease epoch does not advance beyond every known lease epoch"
            )
        }
        guard !knownLeases.contains(where: {
            $0.fencingToken == lease.fencingToken
        }) else {
            return degraded(
                correlationID: correlationID,
                error: .fencingTokenMismatch,
                observedAt: observedAt,
                detail:
                    "Adopted lease fencing token was already used by a historical lease"
            )
        }
        guard lease.expiresAt > lease.observedAt,
              lease.expiresAt.timeIntervalSince(lease.observedAt)
                <= Self.maximumAuthorityLeaseDuration
        else {
            return degraded(
                correlationID: correlationID,
                error: .leaseExpired,
                observedAt: observedAt,
                detail:
                    "Adopted lease expiry must be after observation and within the 24 hour bound"
            )
        }
        guard lease.source == .humanConfirmed else {
            return degraded(
                correlationID: correlationID,
                error: .humanConfirmationRequired,
                observedAt: observedAt,
                detail:
                    "Adopted lease must originate from an explicit human confirmation"
            )
        }
        retiredAuthorityLeases.append(contentsOf: authorityLeases)
        authorityLeases = [lease]
        lastOKAt = observedAt
        return success(
            correlationID: correlationID,
            observedAt: observedAt,
            detail: "Authority lease adopted as the sole active lease"
        )
    }

    public func heartbeat(
        deviceID: String,
        correlationID: String
    ) -> TatwoSyncHealthReceiptV1 {
        effectObserver?.record(.dataCommandStarted("heartbeat"))
        let observedAt = now()
        guard let device = devicesByID[deviceID] else {
            return degraded(
                correlationID: correlationID,
                error: .invalidDevice,
                observedAt: observedAt,
                detail: "Heartbeat references an unknown device"
            )
        }
        devicesByID[deviceID] = TatwoDomainDeviceV1(
            id: device.id,
            domainID: device.domainID,
            displayName: device.displayName,
            kind: device.kind,
            connectionState: device.connectionState,
            schemaVersion: device.schemaVersion,
            protocolVersion: device.protocolVersion,
            registeredAt: device.registeredAt,
            lastHeartbeatAt: observedAt
        )
        lastOKAt = observedAt
        return success(
            correlationID: correlationID,
            observedAt: observedAt,
            detail: "Device heartbeat recorded"
        )
    }

    public func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1? {
        let observedAt = now()
        guard snapshotIntegrityIsValid,
              let producerDigest = snapshotProducerReceiptSHA256()
        else {
            return nil
        }
        let snapshot = TatwoDomainDeviceSnapshotV1(
            protocolVersion: supportedProtocolVersion,
            domainID: domainID,
            producerHealth: .healthy,
            producerReceiptSHA256: producerDigest,
            observedAt: observedAt,
            devices: devicesByID.values.sorted { $0.id < $1.id },
            authorityLeases: authorityLeases
        )
        guard TatwoDomainSnapshotValidatorV1.isValid(
                snapshot,
                supportedSchemaVersion: supportedSchemaVersion,
                supportedProtocolVersion: supportedProtocolVersion,
                now: observedAt
              )
        else {
            return nil
        }
        return snapshot
    }

    public func persistVerifiedSnapshot(
        correlationID: String
    ) -> TatwoSyncHealthReceiptV1 {
        effectObserver?.record(.dataCommandStarted("persistVerifiedSnapshot"))
        let observedAt = now()
        guard let persistenceAdapter else {
            return failure(
                correlationID: correlationID,
                error: .persistenceFailure,
                observedAt: observedAt,
                detail: "No Device Sync persistence adapter is configured"
            )
        }
        guard let snapshot = verifiedSnapshot() else {
            return failure(
                correlationID: correlationID,
                error: .snapshotCorrupt,
                observedAt: observedAt,
                detail: "Only a verified snapshot can be persisted"
            )
        }
        do {
            try persistenceAdapter.persistVerifiedSnapshot(snapshot)
            lastOKAt = observedAt
            return success(
                correlationID: correlationID,
                observedAt: observedAt,
                detail: "Verified snapshot persisted as an append-only generation"
            )
        } catch {
            return failure(
                correlationID: correlationID,
                error: .persistenceFailure,
                observedAt: observedAt,
                detail: "Verified snapshot persistence failed"
            )
        }
    }

    public func replaceAuthorityLeasesForTesting(_ leases: [TatwoAuthorityLeaseV1]) {
        authorityLeases = leases
    }

    public func markSnapshotCorruptForTesting() {
        snapshotIntegrityIsValid = false
    }

    public var offlineQueueCount: Int {
        queuedEvents.count
    }

    public var syncCursor: UInt64 {
        lastAcceptedDomainSequence
    }

    public var recoveredCorruptPersistenceArtifactCount: Int {
        persistenceRecoveryArtifactCount
    }

    private func validate(
        event: TatwoDomainEventV1,
        observedAt: Date,
        includeQueuedPredecessors: Bool = false
    ) -> TatwoSyncErrorKindV1? {
        guard event.domainID == domainID else { return .invalidDomain }
        guard devicesByID[event.deviceID] != nil else { return .invalidDevice }
        guard event.sequence > 0,
              event.sequence <= TatwoDomainEventV1.maximumSafeSequence
        else {
            return .outOfOrder
        }
        guard event.schemaVersion == supportedSchemaVersion else { return .schemaIncompatible }
        guard event.protocolVersion == supportedProtocolVersion else { return .protocolIncompatible }
        let active = activeLeases(observedAt: observedAt)
        if active.count > 1 { return .splitBrain }
        guard !authorityLeases.isEmpty else { return .leaseMissing }
        guard let lease = active.first else { return .leaseExpired }
        guard lease.holderDeviceID == event.deviceID else { return .invalidDevice }
        guard lease.epoch == event.leaseEpoch else { return .leaseEpochMismatch }
        guard lease.fencingToken == event.fencingToken else { return .fencingTokenMismatch }

        let queueTail = includeQueuedPredecessors
            ? (queuedEvents.map(\.sequence).max() ?? lastAcceptedDomainSequence)
            : lastAcceptedDomainSequence
        guard let expected = Self.nextSequence(
            after: max(lastAcceptedDomainSequence, queueTail)
        ), event.sequence == expected else {
            return .outOfOrder
        }
        return nil
    }

    private func validateTopology(observedAt: Date) -> TatwoSyncErrorKindV1? {
        let active = activeLeases(observedAt: observedAt)
        if active.count > 1 { return .splitBrain }
        guard devicesByID.values.allSatisfy({
            $0.schemaVersion == supportedSchemaVersion
        }) else {
            return .schemaIncompatible
        }
        guard devicesByID.values.allSatisfy({
            $0.protocolVersion == supportedProtocolVersion
        }) else {
            return .protocolIncompatible
        }
        guard !authorityLeases.isEmpty else { return .leaseMissing }
        guard let lease = active.first else { return .leaseExpired }
        guard devicesByID[lease.holderDeviceID] != nil else { return .invalidDevice }
        for device in devicesByID.values
        where device.connectionState != .offline {
            guard let heartbeat = device.lastHeartbeatAt,
                  observedAt.timeIntervalSince(heartbeat) <= Self.maximumHeartbeatAge,
                  observedAt.timeIntervalSince(heartbeat) >= -30
            else {
                return .heartbeatStale
            }
        }
        return nil
    }

    private func activeLeases(observedAt: Date) -> [TatwoAuthorityLeaseV1] {
        authorityLeases.filter { $0.expiresAt > observedAt }
    }

    private func activeLease(observedAt: Date) -> TatwoAuthorityLeaseV1? {
        let active = activeLeases(observedAt: observedAt)
        return active.count == 1 ? active[0] : nil
    }

    private func accept(_ event: TatwoDomainEventV1) {
        acceptedEventsByIdempotencyKey[event.idempotencyKey] = event
        lastAcceptedDomainSequence = event.sequence
    }

    private func queueForReplay(
        _ event: TatwoDomainEventV1,
        correlationID: String,
        observedAt: Date,
        error: TatwoSyncErrorKindV1,
        detail: String
    ) -> TatwoSyncHealthReceiptV1 {
        let nextQueue = queuedEvents + [event]
        do {
            try persistSyncState(
                lastAcceptedDomainSequence: lastAcceptedDomainSequence,
                queuedEvents: nextQueue,
                uncertainDeliveryEventIDs: uncertainDeliveryEventIDs
            )
        } catch {
            return failure(
                correlationID: correlationID,
                error: .persistenceFailure,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Event was not queued because durable persistence failed"
            )
        }
        queuedEvents = nextQueue
        return degraded(
            correlationID: correlationID,
            error: error,
            observedAt: observedAt,
            queued: [event.eventID],
            detail: detail
        )
    }

    private func verifyPreviouslyAcceptedEvent(
        _ event: TatwoDomainEventV1,
        transportAvailable: Bool,
        correlationID: String,
        observedAt: Date
    ) -> TatwoSyncHealthReceiptV1 {
        guard event.domainID == domainID,
              devicesByID[event.deviceID] != nil,
              event.schemaVersion == supportedSchemaVersion,
              event.protocolVersion == supportedProtocolVersion,
              event.payloadClass.isAllowed(for: event.kind),
              Self.hasValidPayload(event)
        else {
            return failure(
                correlationID: correlationID,
                error: .outOfOrder,
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Historical retry failed structural validation"
            )
        }
        guard transportAvailable else {
            return degraded(
                correlationID: correlationID,
                error: .transportOffline,
                observedAt: observedAt,
                detail:
                    "Historical retry requires a coordinator idempotency acknowledgement"
            )
        }
        guard let transport else {
            return degraded(
                correlationID: correlationID,
                error: .transportNotConfigured,
                observedAt: observedAt,
                detail:
                    "Historical retry requires a configured coordinator transport"
            )
        }
        do {
            let acknowledgement = try transport.append(
                event: event,
                correlationID: correlationID
            )
            guard acknowledgementMatches(acknowledgement, event: event),
                  acknowledgement.idempotentReplay
            else {
                return failure(
                    correlationID: correlationID,
                    error: .transportProtocolViolation,
                    observedAt: observedAt,
                    rejected: [event.eventID],
                    detail:
                        "Historical retry was not confirmed as the exact coordinator replay"
                )
            }
            lastOKAt = observedAt
            return success(
                correlationID: correlationID,
                observedAt: observedAt,
                accepted: [event.eventID],
                detail: "Historical event retry confirmed idempotently"
            )
        } catch let error as TatwoDomainCoordinatorTransportErrorV1 {
            if error.isRetryable {
                return degraded(
                    correlationID: correlationID,
                    error: .transportOffline,
                    observedAt: observedAt,
                    detail: "Historical retry paused after a retryable transport failure"
                )
            }
            return failure(
                correlationID: correlationID,
                error: transportErrorKind(error),
                observedAt: observedAt,
                rejected: [event.eventID],
                detail: "Historical retry was rejected by the coordinator"
            )
        } catch {
            return degraded(
                correlationID: correlationID,
                error: .transportOffline,
                observedAt: observedAt,
                detail: "Historical retry could not reach the coordinator"
            )
        }
    }

    private func persistSyncState(
        lastAcceptedDomainSequence: UInt64,
        queuedEvents: [TatwoDomainEventV1],
        uncertainDeliveryEventIDs: Set<String>
    ) throws {
        guard let persistenceAdapter else {
            throw TatwoDeviceSyncPersistenceError.invalidPersistenceRoot
        }
        try persistenceAdapter.persistSyncState(
            TatwoPersistedDeviceSyncStateV1(
                domainID: domainID,
                lastAcceptedDomainSequence: lastAcceptedDomainSequence,
                queuedEvents: queuedEvents,
                uncertainDeliveryEventIDs:
                    uncertainDeliveryEventIDs.sorted()
            )
        )
    }

    private func prepareForTransport(_ event: TatwoDomainEventV1) throws {
        let nextQueue = queuedEvents.contains {
            $0.idempotencyKey == event.idempotencyKey
        } ? queuedEvents : queuedEvents + [event]
        let nextUncertain = uncertainDeliveryEventIDs.union([event.eventID])
        try persistSyncState(
            lastAcceptedDomainSequence: lastAcceptedDomainSequence,
            queuedEvents: nextQueue,
            uncertainDeliveryEventIDs: nextUncertain
        )
        queuedEvents = nextQueue
        uncertainDeliveryEventIDs = nextUncertain
    }

    private func markDeliveryUncertain(
        for event: TatwoDomainEventV1
    ) throws {
        guard queuedEvents.contains(where: {
            $0.idempotencyKey == event.idempotencyKey
        }) else {
            throw TatwoDeviceSyncPersistenceError.invalidEvent(event.eventID)
        }
        let nextUncertain = uncertainDeliveryEventIDs.union([event.eventID])
        try persistSyncState(
            lastAcceptedDomainSequence: lastAcceptedDomainSequence,
            queuedEvents: queuedEvents,
            uncertainDeliveryEventIDs: nextUncertain
        )
        uncertainDeliveryEventIDs = nextUncertain
    }

    private func clearDeliveryUncertainty(
        for event: TatwoDomainEventV1,
        removeFromQueue: Bool
    ) throws {
        let nextQueue = removeFromQueue
            ? queuedEvents.filter {
                $0.idempotencyKey != event.idempotencyKey
            }
            : queuedEvents
        let nextUncertain =
            uncertainDeliveryEventIDs.subtracting([event.eventID])
        try persistSyncState(
            lastAcceptedDomainSequence: lastAcceptedDomainSequence,
            queuedEvents: nextQueue,
            uncertainDeliveryEventIDs: nextUncertain
        )
        queuedEvents = nextQueue
        uncertainDeliveryEventIDs = nextUncertain
    }

    private static func nextSequence(after sequence: UInt64) -> UInt64? {
        guard sequence < TatwoDomainEventV1.maximumSafeSequence else {
            return nil
        }
        return sequence + 1
    }

    private func acknowledgementMatches(
        _ acknowledgement: TatwoDomainCoordinatorAppendAcknowledgementV1,
        event: TatwoDomainEventV1
    ) -> Bool {
        let acceptedCodes = ["domain_event_appended", "domain_event_duplicate"]
        return acceptedCodes.contains(acknowledgement.code)
            && acknowledgement.eventID == event.eventID
            && acknowledgement.idempotencyKey == event.idempotencyKey
            && acknowledgement.sequence == event.sequence
            && acknowledgement.payloadDigest == event.payloadDigest
    }

    private func transportErrorKind(
        _ error: TatwoDomainCoordinatorTransportErrorV1
    ) -> TatwoSyncErrorKindV1 {
        switch error {
        case .malformedResponse, .acknowledgementMismatch:
            .transportProtocolViolation
        case .remoteRejected,
             .credentialMissing,
             .insecureEndpoint:
            .transportRejected
        case .unavailable:
            .transportOffline
        }
    }

    private static func hasValidPayload(_ event: TatwoDomainEventV1) -> Bool {
        (try? TatwoDomainPayloadValidatorV1.validate(
            event.payload,
            expectedDigest: event.payloadDigest
        )) != nil
    }

    private func success(
        correlationID: String,
        observedAt: Date,
        accepted: [String] = [],
        detail: String
    ) -> TatwoSyncHealthReceiptV1 {
        TatwoSyncHealthReceiptV1(
            receiptID: makeReceiptID(),
            correlationID: correlationID,
            status: .healthy,
            attempts: 1,
            errorKind: .none,
            observedAt: observedAt,
            lastOKAt: observedAt,
            acceptedEventIDs: accepted,
            detail: detail
        )
    }

    private func degraded(
        correlationID: String,
        error: TatwoSyncErrorKindV1,
        observedAt: Date,
        accepted: [String] = [],
        queued: [String] = [],
        detail: String
    ) -> TatwoSyncHealthReceiptV1 {
        TatwoSyncHealthReceiptV1(
            receiptID: makeReceiptID(),
            correlationID: correlationID,
            status: .degraded,
            attempts: 1,
            errorKind: error,
            observedAt: observedAt,
            lastOKAt: lastOKAt,
            acceptedEventIDs: accepted,
            queuedEventIDs: queued,
            detail: detail
        )
    }

    private func failure(
        correlationID: String,
        error: TatwoSyncErrorKindV1,
        observedAt: Date,
        accepted: [String] = [],
        queued: [String] = [],
        rejected: [String] = [],
        detail: String
    ) -> TatwoSyncHealthReceiptV1 {
        TatwoSyncHealthReceiptV1(
            receiptID: makeReceiptID(),
            correlationID: correlationID,
            status: error == .splitBrain ? .locked : .failed,
            attempts: 1,
            errorKind: error,
            observedAt: observedAt,
            lastOKAt: lastOKAt,
            acceptedEventIDs: accepted,
            queuedEventIDs: queued,
            rejectedEventIDs: rejected,
            detail: detail
        )
    }
}

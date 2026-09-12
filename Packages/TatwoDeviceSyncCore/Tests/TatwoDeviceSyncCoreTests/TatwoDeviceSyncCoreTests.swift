import Foundation
import XCTest
import TatwoDomainContracts
import TatwoWorkReceiptContracts
@testable import TatwoDeviceSyncCore

final class TatwoDeviceSyncCoreTests: XCTestCase {
    func testHeartbeatStaleFailsClosedAndNeverCallsUpdater() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(
            now: now,
            heartbeat: now.addingTimeInterval(-TatwoDeviceSyncCore.maximumHeartbeatAge - 1)
        )

        let receipt = core.sync(
            TatwoSyncDomainRequestV1(
                domainID: "studio",
                transportAvailable: true,
                correlationID: "sync"
            )
        )

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorKind, .heartbeatStale)
        XCTAssertEqual(receipt.safetyEvidence.updaterCallCount, 0)
    }

    func testDataFailureAndOrderingMatrixNeverInvokesUpdaterBundleOrRunner() {
        let now = Date(timeIntervalSince1970: 1_000)
        let spy = DataPlaneEffectSpy()
        var receipts: [TatwoSyncHealthReceiptV1] = []

        func capture(
            _ receipt: TatwoSyncHealthReceiptV1,
            expectedError: TatwoSyncErrorKindV1? = nil
        ) {
            if let expectedError {
                XCTAssertEqual(receipt.errorKind, expectedError)
            }
            receipts.append(receipt)
        }

        let stale = makeCore(
            now: now,
            heartbeat:
                now.addingTimeInterval(
                    -TatwoDeviceSyncCore.maximumHeartbeatAge - 1
                ),
            effectObserver: spy
        )
        capture(
            stale.sync(
                .init(
                    domainID: "studio",
                    transportAvailable: true,
                    correlationID: "matrix-stale"
                )
            ),
            expectedError: .heartbeatStale
        )

        let offline = makeCore(now: now, effectObserver: spy)
        capture(
            offline.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 1, now: now),
                    transportAvailable: false,
                    correlationID: "matrix-offline"
                )
            ),
            expectedError: .transportOffline
        )

        let duplicate = makeCore(now: now, effectObserver: spy)
        let duplicateEvent = makeEvent(sequence: 1, now: now)
        capture(
            duplicate.enqueueEvent(
                .init(
                    event: duplicateEvent,
                    transportAvailable: true,
                    correlationID: "matrix-duplicate-first"
                )
            )
        )
        capture(
            duplicate.enqueueEvent(
                .init(
                    event: duplicateEvent,
                    transportAvailable: true,
                    correlationID: "matrix-duplicate-idempotent"
                )
            )
        )
        let divergentDuplicate = try! TatwoDomainEventV1(
            eventID: duplicateEvent.eventID,
            domainID: duplicateEvent.domainID,
            deviceID: duplicateEvent.deviceID,
            leaseEpoch: duplicateEvent.leaseEpoch,
            fencingToken: duplicateEvent.fencingToken,
            idempotencyKey: duplicateEvent.idempotencyKey,
            sequence: duplicateEvent.sequence,
            schemaVersion: duplicateEvent.schemaVersion,
            protocolVersion: duplicateEvent.protocolVersion,
            kind: duplicateEvent.kind,
            payloadClass: duplicateEvent.payloadClass,
            payload: .object(["receiptID": .string("divergent")]),
            observedAt: duplicateEvent.observedAt
        )
        capture(
            duplicate.enqueueEvent(
                .init(
                    event: divergentDuplicate,
                    transportAvailable: true,
                    correlationID: "matrix-duplicate-divergent"
                )
            ),
            expectedError: .duplicateConflict
        )

        let ordering = makeCore(now: now, effectObserver: spy)
        capture(
            ordering.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 2, now: now),
                    transportAvailable: true,
                    correlationID: "matrix-sequence-2"
                )
            ),
            expectedError: .outOfOrder
        )
        let sequenceOne = makeEvent(sequence: 1, now: now)
        capture(
            ordering.enqueueEvent(
                .init(
                    event: sequenceOne,
                    transportAvailable: true,
                    correlationID: "matrix-sequence-1"
                )
            )
        )
        capture(
            ordering.enqueueEvent(
                .init(
                    event: sequenceOne,
                    transportAvailable: true,
                    correlationID: "matrix-sequence-1-duplicate"
                )
            )
        )

        let expired = makeCore(
            now: now,
            leaseExpiresAt: now.addingTimeInterval(-1),
            effectObserver: spy
        )
        capture(
            expired.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 1, now: now),
                    transportAvailable: true,
                    correlationID: "matrix-lease-expired"
                )
            ),
            expectedError: .leaseExpired
        )

        let splitBrain = makeCore(now: now, effectObserver: spy)
        splitBrain.replaceAuthorityLeasesForTesting([
            makeLease(deviceID: "mini", epoch: 1, now: now),
            makeLease(deviceID: "book", epoch: 2, now: now)
        ])
        capture(
            splitBrain.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 1, now: now),
                    transportAvailable: true,
                    correlationID: "matrix-split-mini"
                )
            ),
            expectedError: .splitBrain
        )
        capture(
            splitBrain.enqueueEvent(
                .init(
                    event: makeEvent(
                        sequence: 1,
                        now: now,
                        fencingToken: "fence-2",
                        deviceID: "book",
                        leaseEpoch: 2,
                        eventID: "event-book-1",
                        idempotencyKey: "idem-book-1"
                    ),
                    transportAvailable: true,
                    correlationID: "matrix-split-book"
                )
            ),
            expectedError: .splitBrain
        )

        let schema = makeCore(now: now, effectObserver: spy)
        capture(
            schema.enqueueEvent(
                .init(
                    event: makeEvent(
                        sequence: 1,
                        now: now,
                        schemaVersion: 2
                    ),
                    transportAvailable: true,
                    correlationID: "matrix-schema"
                )
            ),
            expectedError: .schemaIncompatible
        )
        let protocolMismatch = makeCore(now: now, effectObserver: spy)
        capture(
            protocolMismatch.enqueueEvent(
                .init(
                    event: makeEvent(
                        sequence: 1,
                        now: now,
                        protocolVersion: 2
                    ),
                    transportAvailable: true,
                    correlationID: "matrix-protocol"
                )
            ),
            expectedError: .protocolIncompatible
        )

        let corrupt = makeCore(now: now, effectObserver: spy)
        corrupt.markSnapshotCorruptForTesting()
        capture(
            corrupt.sync(
                .init(
                    domainID: "studio",
                    transportAvailable: true,
                    correlationID: "matrix-corrupt"
                )
            ),
            expectedError: .snapshotCorrupt
        )

        let fence = makeCore(now: now, effectObserver: spy)
        capture(
            fence.enqueueEvent(
                .init(
                    event: makeEvent(
                        sequence: 1,
                        now: now,
                        fencingToken: "wrong-fence"
                    ),
                    transportAvailable: true,
                    correlationID: "matrix-fence"
                )
            ),
            expectedError: .fencingTokenMismatch
        )
        let epoch = makeCore(now: now, effectObserver: spy)
        capture(
            epoch.enqueueEvent(
                .init(
                    event: makeEvent(
                        sequence: 1,
                        now: now,
                        leaseEpoch: 2
                    ),
                    transportAvailable: true,
                    correlationID: "matrix-epoch"
                )
            ),
            expectedError: .leaseEpochMismatch
        )

        let failingTransport = AcknowledgingTransport()
        let transportEvent = makeEvent(sequence: 1, now: now)
        failingTransport.failuresByEventID[transportEvent.eventID] = .unavailable
        let transportFailure = makeCore(
            now: now,
            transport: failingTransport,
            effectObserver: spy
        )
        capture(
            transportFailure.enqueueEvent(
                .init(
                    event: transportEvent,
                    transportAvailable: true,
                    correlationID: "matrix-transport"
                )
            ),
            expectedError: .transportOffline
        )

        let failingPersistence =
            InMemorySyncPersistenceAdapter(domainID: "studio")
        failingPersistence.failPersistCallNumbers = [1]
        let persistenceFailure = makeCore(
            now: now,
            persistenceAdapter: failingPersistence,
            effectObserver: spy
        )
        capture(
            persistenceFailure.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 1, now: now),
                    transportAvailable: true,
                    correlationID: "matrix-persistence"
                )
            ),
            expectedError: .persistenceFailure
        )

        XCTAssertEqual(spy.effects.count, receipts.count)
        XCTAssertEqual(spy.updaterInvocationCount, 0)
        XCTAssertEqual(spy.bundleMutationCount, 0)
        XCTAssertEqual(spy.hostOrRunnerStartCount, 0)
        XCTAssertTrue(
            spy.effects.allSatisfy { !$0.isForbiddenCrossPlaneEffect }
        )
        for receipt in receipts {
            XCTAssertEqual(receipt.safetyEvidence.updaterCallCount, 0)
            XCTAssertEqual(receipt.safetyEvidence.bundleMutationCount, 0)
            XCTAssertEqual(receipt.safetyEvidence.automaticElectionCount, 0)
        }
    }

    func testDirectEnqueueRejectsUnsafeTopologyBeforeQueueOrTransport() {
        let now = Date(timeIntervalSince1970: 1_000)
        let staleHeartbeat = now.addingTimeInterval(
            -TatwoDeviceSyncCore.maximumHeartbeatAge - 1
        )

        let onlineTransport = AcknowledgingTransport()
        let staleOnline = makeCore(
            now: now,
            heartbeat: staleHeartbeat,
            transport: onlineTransport
        )
        let onlineReceipt = staleOnline.enqueueEvent(
            .init(
                event: makeEvent(sequence: 1, now: now),
                transportAvailable: true,
                correlationID: "stale-online"
            )
        )
        XCTAssertEqual(onlineReceipt.errorKind, .heartbeatStale)
        XCTAssertEqual(staleOnline.offlineQueueCount, 0)
        XCTAssertEqual(onlineTransport.appendedEvents.count, 0)

        let offlineTransport = AcknowledgingTransport()
        let staleOffline = makeCore(
            now: now,
            heartbeat: staleHeartbeat,
            transport: offlineTransport
        )
        let offlineReceipt = staleOffline.enqueueEvent(
            .init(
                event: makeEvent(sequence: 1, now: now),
                transportAvailable: false,
                correlationID: "stale-offline"
            )
        )
        XCTAssertEqual(offlineReceipt.errorKind, .heartbeatStale)
        XCTAssertEqual(staleOffline.offlineQueueCount, 0)
        XCTAssertEqual(offlineTransport.appendedEvents.count, 0)

        let corruptTransport = AcknowledgingTransport()
        let corrupt = makeCore(now: now, transport: corruptTransport)
        corrupt.markSnapshotCorruptForTesting()
        let corruptReceipt = corrupt.enqueueEvent(
            .init(
                event: makeEvent(sequence: 1, now: now),
                transportAvailable: true,
                correlationID: "corrupt-direct"
            )
        )
        XCTAssertEqual(corruptReceipt.errorKind, .snapshotCorrupt)
        XCTAssertEqual(corrupt.offlineQueueCount, 0)
        XCTAssertEqual(corruptTransport.appendedEvents.count, 0)
    }

    func testDirectEnqueueTopologyGateCoversAcceptedAndQueuedIdempotentRetries() {
        let now = Date(timeIntervalSince1970: 1_000)
        let staleAt = now.addingTimeInterval(
            TatwoDeviceSyncCore.maximumHeartbeatAge + 1
        )
        let event = makeEvent(sequence: 1, now: now)

        var acceptedClock = now
        let acceptedTransport = AcknowledgingTransport()
        let accepted = makeCore(
            now: now,
            leaseExpiresAt: now.addingTimeInterval(300),
            transport: acceptedTransport,
            clock: { acceptedClock }
        )
        XCTAssertEqual(
            accepted.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: true,
                    correlationID: "accepted-first"
                )
            ).status,
            .healthy
        )
        acceptedClock = staleAt
        XCTAssertEqual(
            accepted.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: true,
                    correlationID: "accepted-stale-retry"
                )
            ).errorKind,
            .heartbeatStale
        )
        XCTAssertEqual(acceptedTransport.appendedEvents.count, 1)

        let corruptAcceptedTransport = AcknowledgingTransport()
        let corruptAccepted = makeCore(
            now: now,
            transport: corruptAcceptedTransport
        )
        XCTAssertEqual(
            corruptAccepted.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: true,
                    correlationID: "accepted-before-corruption"
                )
            ).status,
            .healthy
        )
        corruptAccepted.markSnapshotCorruptForTesting()
        XCTAssertEqual(
            corruptAccepted.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: true,
                    correlationID: "accepted-corrupt-retry"
                )
            ).errorKind,
            .snapshotCorrupt
        )
        XCTAssertEqual(corruptAcceptedTransport.appendedEvents.count, 1)

        var queuedClock = now
        let queuedTransport = AcknowledgingTransport()
        let queued = makeCore(
            now: now,
            leaseExpiresAt: now.addingTimeInterval(300),
            transport: queuedTransport,
            clock: { queuedClock }
        )
        XCTAssertEqual(
            queued.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: false,
                    correlationID: "queued-first"
                )
            ).errorKind,
            .transportOffline
        )
        queuedClock = staleAt
        XCTAssertEqual(
            queued.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: false,
                    correlationID: "queued-stale-retry"
                )
            ).errorKind,
            .heartbeatStale
        )
        XCTAssertEqual(queued.offlineQueueCount, 1)
        XCTAssertEqual(queuedTransport.appendedEvents.count, 0)

        let corruptQueuedTransport = AcknowledgingTransport()
        let corruptQueued = makeCore(
            now: now,
            transport: corruptQueuedTransport
        )
        XCTAssertEqual(
            corruptQueued.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: false,
                    correlationID: "queued-before-corruption"
                )
            ).errorKind,
            .transportOffline
        )
        corruptQueued.markSnapshotCorruptForTesting()
        XCTAssertEqual(
            corruptQueued.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: false,
                    correlationID: "queued-corrupt-retry"
                )
            ).errorKind,
            .snapshotCorrupt
        )
        XCTAssertEqual(corruptQueued.offlineQueueCount, 1)
        XCTAssertEqual(corruptQueuedTransport.appendedEvents.count, 0)
    }

    func testOfflineQueueReplaysAfterTransportReturns() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)
        let event = makeEvent(sequence: 1, now: now)

        let queued = core.enqueueEvent(
            TatwoEnqueueDomainEventRequestV1(
                event: event,
                transportAvailable: false,
                correlationID: "enqueue"
            )
        )
        XCTAssertEqual(queued.status, .degraded)
        XCTAssertEqual(queued.errorKind, .transportOffline)
        XCTAssertEqual(core.offlineQueueCount, 1)

        let replayed = core.sync(
            TatwoSyncDomainRequestV1(
                domainID: "studio",
                transportAvailable: true,
                correlationID: "sync"
            )
        )
        XCTAssertEqual(replayed.status, .healthy)
        XCTAssertEqual(replayed.acceptedEventIDs, [event.eventID])
        XCTAssertEqual(core.offlineQueueCount, 0)
    }

    func testDuplicateIsIdempotentButDivergentDuplicateFails() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)
        let event = makeEvent(sequence: 1, now: now)

        XCTAssertEqual(
            core.enqueueEvent(
                .init(event: event, transportAvailable: true, correlationID: "first")
            ).status,
            .healthy
        )
        XCTAssertEqual(
            core.enqueueEvent(
                .init(event: event, transportAvailable: true, correlationID: "duplicate")
            ).status,
            .healthy
        )

        let divergent = try! TatwoDomainEventV1(
            eventID: event.eventID,
            domainID: event.domainID,
            deviceID: event.deviceID,
            leaseEpoch: event.leaseEpoch,
            fencingToken: event.fencingToken,
            idempotencyKey: event.idempotencyKey,
            sequence: event.sequence,
            schemaVersion: event.schemaVersion,
            protocolVersion: event.protocolVersion,
            kind: event.kind,
            payloadClass: event.payloadClass,
            payload: .object(["receiptID": .string("different")]),
            observedAt: event.observedAt
        )
        let rejected = core.enqueueEvent(
            .init(event: divergent, transportAvailable: true, correlationID: "divergent")
        )
        XCTAssertEqual(rejected.errorKind, .duplicateConflict)
    }

    func testOutOfOrderLeaseExpirySplitBrainSchemaAndSnapshotCorruptionFailClosed() {
        let now = Date(timeIntervalSince1970: 1_000)

        let outOfOrderCore = makeCore(now: now)
        XCTAssertEqual(
            outOfOrderCore.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 2, now: now),
                    transportAvailable: true,
                    correlationID: "out-of-order"
                )
            ).errorKind,
            .outOfOrder
        )

        let expiredCore = makeCore(now: now, leaseExpiresAt: now.addingTimeInterval(-1))
        XCTAssertEqual(
            expiredCore.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 1, now: now),
                    transportAvailable: true,
                    correlationID: "expired"
                )
            ).errorKind,
            .leaseExpired
        )

        let splitBrainCore = makeCore(now: now)
        splitBrainCore.replaceAuthorityLeasesForTesting([
            makeLease(deviceID: "mini", epoch: 1, now: now),
            makeLease(deviceID: "book", epoch: 2, now: now)
        ])
        let split = splitBrainCore.sync(
            .init(domainID: "studio", transportAvailable: true, correlationID: "split")
        )
        XCTAssertEqual(split.status, .locked)
        XCTAssertEqual(split.errorKind, .splitBrain)

        let schemaCore = makeCore(now: now)
        let incompatible = makeEvent(sequence: 1, now: now, schemaVersion: 2)
        XCTAssertEqual(
            schemaCore.enqueueEvent(
                .init(event: incompatible, transportAvailable: true, correlationID: "schema")
            ).errorKind,
            .schemaIncompatible
        )

        let corruptCore = makeCore(now: now)
        corruptCore.markSnapshotCorruptForTesting()
        XCTAssertEqual(
            corruptCore.sync(
                .init(domainID: "studio", transportAvailable: true, correlationID: "corrupt")
            ).errorKind,
            .snapshotCorrupt
        )
        XCTAssertNil(corruptCore.verifiedSnapshot())
    }

    func testMissingLeaseIsNotMisreportedAsExpired() {
        let now = Date(timeIntervalSince1970: 1_000)
        let transport = AcknowledgingTransport()
        let core = TatwoDeviceSyncCore(
            domainID: "studio",
            initialDevices: [
                makeDevice(id: "mini", kind: .macMini, now: now)
            ],
            authorityLeases: [],
            receiptID: { "receipt-fixed" },
            snapshotProducerReceiptSHA256: { Self.validDigest },
            transport: transport,
            now: { now }
        )

        XCTAssertEqual(
            core.enqueueEvent(
                .init(
                    event: makeEvent(sequence: 1, now: now),
                    transportAvailable: true,
                    correlationID: "missing-lease-enqueue"
                )
            ).errorKind,
            .leaseMissing
        )
        XCTAssertTrue(transport.appendedEvents.isEmpty)

        XCTAssertEqual(
            core.sync(
                .init(
                    domainID: "studio",
                    transportAvailable: true,
                    correlationID: "missing-lease-sync"
                )
            ).errorKind,
            .leaseMissing
        )
        XCTAssertTrue(transport.appendedEvents.isEmpty)
    }

    func testFencingAndProtectedDataAreRejected() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)
        let wrongFence = makeEvent(sequence: 1, now: now, fencingToken: "wrong")
        XCTAssertEqual(
            core.enqueueEvent(
                .init(event: wrongFence, transportAvailable: true, correlationID: "fence")
            ).errorKind,
            .fencingTokenMismatch
        )

        let protected = makeEvent(
            sequence: 1,
            now: now,
            payloadClass: .authSessionToken
        )
        let rejected = core.enqueueEvent(
            .init(event: protected, transportAvailable: true, correlationID: "protected")
        )
        XCTAssertEqual(rejected.errorKind, .protectedDataRejected)
        XCTAssertEqual(rejected.safetyEvidence.authMaterialReadCount, 0)
    }

    func testEventKindAndPayloadClassMustMatchTypedAllowlist() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)
        let disguised = makeEvent(
            sequence: 1,
            now: now,
            kind: .receiptMetadata,
            payloadClass: .threadMessageProjection
        )

        let receipt = core.enqueueEvent(
            .init(event: disguised, transportAvailable: true, correlationID: "mismatch")
        )

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorKind, .payloadClassMismatch)
        XCTAssertEqual(receipt.rejectedEventIDs, [disguised.eventID])
    }

    func testTransportBooleanCannotReplaceMissingCoordinatorAdapter() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now, transport: nil)
        let event = makeEvent(sequence: 1, now: now)

        let receipt = core.enqueueEvent(
            .init(
                event: event,
                transportAvailable: true,
                correlationID: "missing-adapter"
            )
        )

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .transportNotConfigured)
        XCTAssertEqual(receipt.acceptedEventIDs, [])
        XCTAssertEqual(receipt.queuedEventIDs, [event.eventID])
        XCTAssertEqual(core.offlineQueueCount, 1)
    }

    func testRemoteAcknowledgementMustMatchBeforeLocalAcceptance() {
        let now = Date(timeIntervalSince1970: 1_000)
        let transport = AcknowledgingTransport()
        transport.acknowledgementMutation = { acknowledgement in
            .init(
                code: acknowledgement.code,
                eventID: "wrong-event",
                idempotencyKey: acknowledgement.idempotencyKey,
                sequence: acknowledgement.sequence,
                payloadDigest: acknowledgement.payloadDigest,
                idempotentReplay: acknowledgement.idempotentReplay
            )
        }
        let core = makeCore(now: now, transport: transport)
        let event = makeEvent(sequence: 1, now: now)

        let receipt = core.enqueueEvent(
            .init(event: event, transportAvailable: true, correlationID: "mismatch")
        )

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorKind, .transportProtocolViolation)
        XCTAssertEqual(receipt.acceptedEventIDs, [])
        XCTAssertEqual(receipt.rejectedEventIDs, [event.eventID])
    }

    func testPartialReplayCommitsOnlyRemoteAcknowledgedPrefix() {
        let now = Date(timeIntervalSince1970: 1_000)
        let transport = AcknowledgingTransport()
        let core = makeCore(now: now, transport: transport)
        let first = makeEvent(sequence: 1, now: now)
        let second = makeEvent(sequence: 2, now: now)
        _ = core.enqueueEvent(
            .init(event: first, transportAvailable: false, correlationID: "queue-1")
        )
        _ = core.enqueueEvent(
            .init(event: second, transportAvailable: false, correlationID: "queue-2")
        )
        transport.failuresByEventID[second.eventID] = .remoteRejected(
            statusCode: 422,
            code: "payload_rejected"
        )

        let receipt = core.sync(
            .init(domainID: "studio", transportAvailable: true, correlationID: "replay")
        )

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorKind, .transportRejected)
        XCTAssertEqual(receipt.acceptedEventIDs, [first.eventID])
        XCTAssertEqual(receipt.rejectedEventIDs, [second.eventID])
        XCTAssertEqual(receipt.queuedEventIDs, [second.eventID])
        XCTAssertEqual(core.offlineQueueCount, 1)
    }

    func testNewOnlineEventQueuesBehindExistingReplayBacklog() {
        let now = Date(timeIntervalSince1970: 1_000)
        let transport = AcknowledgingTransport()
        let core = makeCore(now: now, transport: transport)
        let first = makeEvent(sequence: 1, now: now)
        let second = makeEvent(sequence: 2, now: now)
        XCTAssertEqual(
            core.enqueueEvent(
                .init(
                    event: first,
                    transportAvailable: false,
                    correlationID: "offline-first"
                )
            ).status,
            .degraded
        )

        let queuedBehind = core.enqueueEvent(
            .init(
                event: second,
                transportAvailable: true,
                correlationID: "online-second"
            )
        )

        XCTAssertEqual(queuedBehind.status, .degraded)
        XCTAssertEqual(queuedBehind.queuedEventIDs, [second.eventID])
        XCTAssertEqual(transport.appendedEvents, [])
        let replayed = core.sync(
            .init(
                domainID: "studio",
                transportAvailable: true,
                correlationID: "ordered-replay"
            )
        )
        XCTAssertEqual(replayed.status, .healthy)
        XCTAssertEqual(
            replayed.acceptedEventIDs,
            [first.eventID, second.eventID]
        )
        XCTAssertEqual(core.syncCursor, 2)
    }

    func testOnlineAcknowledgementPersistsCursorAcrossCoreRecreation() {
        let now = Date(timeIntervalSince1970: 1_000)
        let persistence = InMemorySyncPersistenceAdapter(domainID: "studio")
        let firstCore = makeCore(
            now: now,
            persistenceAdapter: persistence
        )
        let event = makeEvent(sequence: 1, now: now)

        let accepted = firstCore.enqueueEvent(
            .init(
                event: event,
                transportAvailable: true,
                correlationID: "online"
            )
        )

        XCTAssertEqual(accepted.status, .healthy)
        XCTAssertEqual(firstCore.syncCursor, 1)
        let restoredCore = makeCore(
            now: now,
            persistenceAdapter: persistence
        )
        XCTAssertEqual(restoredCore.syncCursor, 1)
        XCTAssertEqual(restoredCore.offlineQueueCount, 0)
        XCTAssertEqual(persistence.state.lastAcceptedDomainSequence, 1)
        XCTAssertEqual(persistence.state.queuedEvents, [])
        XCTAssertEqual(persistence.state.uncertainDeliveryEventIDs, [])
    }

    func testCrashAfterRemoteAcknowledgementRequiresIdempotentReplay() {
        let now = Date(timeIntervalSince1970: 1_000)
        let persistence = InMemorySyncPersistenceAdapter(domainID: "studio")
        persistence.failPersistCallNumbers = [2]
        let firstTransport = AcknowledgingTransport()
        let firstCore = makeCore(
            now: now,
            persistenceAdapter: persistence,
            transport: firstTransport
        )
        let event = makeEvent(sequence: 1, now: now)

        let uncommitted = firstCore.enqueueEvent(
            .init(
                event: event,
                transportAvailable: true,
                correlationID: "remote-acked-local-crash"
            )
        )

        XCTAssertEqual(uncommitted.status, .failed)
        XCTAssertEqual(uncommitted.errorKind, .persistenceFailure)
        XCTAssertEqual(persistence.state.lastAcceptedDomainSequence, 0)
        XCTAssertEqual(persistence.state.queuedEvents, [event])
        XCTAssertEqual(
            persistence.state.uncertainDeliveryEventIDs,
            [event.eventID]
        )

        persistence.failPersistCallNumbers = []
        let retryTransport = AcknowledgingTransport()
        let restoredCore = makeCore(
            now: now,
            persistenceAdapter: persistence,
            transport: retryTransport
        )
        let unsafeRetry = restoredCore.sync(
            .init(
                domainID: "studio",
                transportAvailable: true,
                correlationID: "retry-without-idempotent-proof"
            )
        )
        XCTAssertEqual(unsafeRetry.status, .failed)
        XCTAssertEqual(unsafeRetry.errorKind, .transportProtocolViolation)
        XCTAssertEqual(restoredCore.syncCursor, 0)

        retryTransport.idempotentReplayByEventID[event.eventID] = true
        let confirmedRetry = restoredCore.sync(
            .init(
                domainID: "studio",
                transportAvailable: true,
                correlationID: "retry-with-idempotent-proof"
            )
        )
        XCTAssertEqual(confirmedRetry.status, .healthy)
        XCTAssertEqual(confirmedRetry.acceptedEventIDs, [event.eventID])
        XCTAssertEqual(restoredCore.syncCursor, 1)
        XCTAssertEqual(restoredCore.offlineQueueCount, 0)
    }

    func testOldSequenceRetryFailsClosedWithoutIdempotentReplayProof() {
        let now = Date(timeIntervalSince1970: 1_000)
        let persistence = InMemorySyncPersistenceAdapter(domainID: "studio")
        let event = makeEvent(sequence: 1, now: now)
        let firstCore = makeCore(
            now: now,
            persistenceAdapter: persistence
        )
        XCTAssertEqual(
            firstCore.enqueueEvent(
                .init(
                    event: event,
                    transportAvailable: true,
                    correlationID: "first"
                )
            ).status,
            .healthy
        )

        let retryTransport = AcknowledgingTransport()
        let restoredCore = makeCore(
            now: now,
            persistenceAdapter: persistence,
            transport: retryTransport
        )
        let rejected = restoredCore.enqueueEvent(
            .init(
                event: event,
                transportAvailable: true,
                correlationID: "old-sequence"
            )
        )

        XCTAssertEqual(rejected.status, .failed)
        XCTAssertEqual(rejected.errorKind, .transportProtocolViolation)
        XCTAssertEqual(restoredCore.syncCursor, 1)
    }

    func testHTTPTransportEnforcesHTTPSAndExactAcknowledgementWithoutPersistingSecret() throws {
        XCTAssertThrowsError(
            try TatwoDomainCoordinatorHTTPTransport(
                baseURL: URL(string: "http://example.com")!,
                secretProvider: { String(repeating: "s", count: 48) },
                client: StubHTTPClient()
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .insecureEndpoint
            )
        }
        XCTAssertThrowsError(
            try TatwoDomainCoordinatorHTTPTransport(
                baseURL: URL(string: "https://user:password@example.com")!,
                secretProvider: { String(repeating: "s", count: 48) },
                client: StubHTTPClient()
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .insecureEndpoint
            )
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let event = makeEvent(sequence: 1, now: now)
        let client = StubHTTPClient()
        client.responseBody = try JSONSerialization.data(
            withJSONObject: [
                "ok": true,
                "code": "domain_event_appended",
                "sequence": 1,
                "eventID": event.eventID,
                "idempotencyKey": event.idempotencyKey,
                "payloadDigest": event.payloadDigest,
                "idempotentReplay": false
            ],
            options: [.sortedKeys]
        )
        let transport = try TatwoDomainCoordinatorHTTPTransport(
            baseURL: URL(string: "https://sync.example.invalid")!,
            secretProvider: { String(repeating: "s", count: 48) },
            client: client
        )

        let acknowledgement = try transport.append(
            event: event,
            correlationID: "http"
        )

        XCTAssertEqual(acknowledgement.eventID, event.eventID)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "authorization"),
            "Bearer \(String(repeating: "s", count: 48))"
        )
        let body = try XCTUnwrap(request.httpBody)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(bodyText.contains(event.payloadDigest))
        XCTAssertFalse(bodyText.contains(String(repeating: "s", count: 48)))

        let invalidSecretTransport = try TatwoDomainCoordinatorHTTPTransport(
            baseURL: URL(string: "https://sync.example.invalid")!,
            secretProvider: { String(repeating: "s", count: 31) + "\n" },
            client: client
        )
        XCTAssertThrowsError(
            try invalidSecretTransport.append(
                event: event,
                correlationID: "invalid-secret"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .credentialMissing
            )
        }
    }

    func testVerifiedSnapshotRequiresExternallySuppliedNonPlaceholderProducerDigest() {
        let now = Date(timeIntervalSince1970: 1_000)
        let missing = TatwoDeviceSyncCore(
            domainID: "studio",
            initialDevices: [
                makeDevice(id: "mini", kind: .macMini, now: now)
            ],
            authorityLeases: [makeLease(deviceID: "mini", epoch: 1, now: now)],
            now: { now }
        )
        XCTAssertNil(missing.verifiedSnapshot())

        let placeholder = TatwoDeviceSyncCore(
            domainID: "studio",
            initialDevices: [
                makeDevice(id: "mini", kind: .macMini, now: now)
            ],
            authorityLeases: [makeLease(deviceID: "mini", epoch: 1, now: now)],
            snapshotProducerReceiptSHA256: { String(repeating: "a", count: 64) },
            now: { now }
        )
        XCTAssertNil(placeholder.verifiedSnapshot())

        let valid = makeCore(now: now)
        XCTAssertEqual(valid.verifiedSnapshot()?.producerReceiptSHA256, Self.validDigest)
    }

    func testVerifiedSnapshotRejectsSplitBrainAndExpiredAuthorityLease() {
        let now = Date(timeIntervalSince1970: 1_000)
        let splitBrain = makeCore(now: now)
        splitBrain.replaceAuthorityLeasesForTesting([
            makeLease(deviceID: "mini", epoch: 1, now: now),
            makeLease(deviceID: "book", epoch: 2, now: now)
        ])
        XCTAssertNil(splitBrain.verifiedSnapshot())

        let expired = makeCore(
            now: now,
            leaseExpiresAt: now.addingTimeInterval(-1)
        )
        XCTAssertNil(expired.verifiedSnapshot())
    }

    func testDeviceVersionMismatchFailsClosedAcrossCoreAndVerifiedSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000)
        let schemaMismatch = TatwoDeviceSyncCore(
            domainID: "studio",
            initialDevices: [
                makeDevice(
                    id: "mini",
                    kind: .macMini,
                    now: now,
                    schemaVersion: 2
                )
            ],
            authorityLeases: [makeLease(deviceID: "mini", epoch: 1, now: now)],
            snapshotProducerReceiptSHA256: { Self.validDigest },
            now: { now }
        )
        XCTAssertNil(schemaMismatch.verifiedSnapshot())
        XCTAssertEqual(
            schemaMismatch.sync(
                .init(
                    domainID: "studio",
                    transportAvailable: true,
                    correlationID: "schema-mismatch"
                )
            ).errorKind,
            .schemaIncompatible
        )

        let protocolMismatch = TatwoDeviceSyncCore(
            domainID: "studio",
            initialDevices: [
                makeDevice(
                    id: "mini",
                    kind: .macMini,
                    now: now,
                    protocolVersion: 2
                )
            ],
            authorityLeases: [makeLease(deviceID: "mini", epoch: 1, now: now)],
            snapshotProducerReceiptSHA256: { Self.validDigest },
            now: { now }
        )
        XCTAssertNil(protocolMismatch.verifiedSnapshot())
        XCTAssertEqual(
            protocolMismatch.sync(
                .init(
                    domainID: "studio",
                    transportAvailable: true,
                    correlationID: "protocol-mismatch"
                )
            ).errorKind,
            .protocolIncompatible
        )
    }

    func testAuthorityTransferNeverAutoElects() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)

        let missingHumanGate = core.requestAuthorityTransfer(
            .init(
                domainID: "studio",
                fromDeviceID: "mini",
                toDeviceID: "book",
                humanConfirmationReceiptID: nil,
                correlationID: "transfer"
            )
        )
        XCTAssertEqual(missingHumanGate.errorKind, .humanConfirmationRequired)
        XCTAssertEqual(missingHumanGate.safetyEvidence.automaticElectionCount, 0)

        let confirmedButNotIssued = core.requestAuthorityTransfer(
            .init(
                domainID: "studio",
                fromDeviceID: "mini",
                toDeviceID: "book",
                humanConfirmationReceiptID: "human-receipt",
                correlationID: "transfer"
            )
        )
        XCTAssertEqual(confirmedButNotIssued.status, .degraded)
        XCTAssertEqual(confirmedButNotIssued.errorKind, .humanConfirmationRequired)
        XCTAssertEqual(
            core.verifiedSnapshot()?.authorityLeases.first?.holderDeviceID,
            "mini"
        )
    }

    func testFileBackedOfflineQueueSurvivesCoreRecreation() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = try makePersistenceRoot("queue-recreation")
        let firstAdapter = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: root
        )
        let firstCore = makeCore(now: now, persistenceAdapter: firstAdapter)
        let event = makeEvent(sequence: 1, now: now)

        let queued = firstCore.enqueueEvent(
            .init(
                event: event,
                transportAvailable: false,
                correlationID: "persist-queue"
            )
        )
        XCTAssertEqual(queued.status, .degraded)
        XCTAssertEqual(firstCore.offlineQueueCount, 1)

        let secondAdapter = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: root
        )
        let restoredCore = makeCore(now: now, persistenceAdapter: secondAdapter)
        XCTAssertEqual(restoredCore.offlineQueueCount, 1)

        let replayed = restoredCore.sync(
            .init(
                domainID: "studio",
                transportAvailable: true,
                correlationID: "persist-replay"
            )
        )
        XCTAssertEqual(replayed.status, .healthy)
        XCTAssertEqual(replayed.acceptedEventIDs, [event.eventID])
        XCTAssertEqual(restoredCore.offlineQueueCount, 0)

        let finalLoad = try secondAdapter.loadSyncState(domainID: "studio")
        XCTAssertEqual(finalLoad.state.lastAcceptedDomainSequence, 1)
        XCTAssertEqual(finalLoad.state.queuedEvents, [])
        XCTAssertEqual(finalLoad.state.uncertainDeliveryEventIDs, [])
    }

    func testFileBackedQueueRecoversOlderGenerationAndPreservesCorruptEvidence() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = try makePersistenceRoot("queue-corruption-recovery")
        let adapter = try TatwoFileBackedDeviceSyncPersistenceAdapter(rootURL: root)
        let first = makeEvent(sequence: 1, now: now)
        let second = makeEvent(sequence: 2, now: now)
        try adapter.persistOfflineQueue([first])
        try adapter.persistOfflineQueue([first, second])

        let queueDirectory = root.appendingPathComponent("offlineQueue")
        let newest = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: queueDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
        )
        try Data("{corrupt-json".utf8).write(to: newest)

        let loaded = try adapter.loadOfflineQueue()
        XCTAssertEqual(loaded.events, [first])
        XCTAssertTrue(loaded.recoveredFromCorruption)
        XCTAssertEqual(loaded.corruptArtifactURLs, [newest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))

        let restoredCore = makeCore(now: now, persistenceAdapter: adapter)
        XCTAssertEqual(restoredCore.offlineQueueCount, 1)
        XCTAssertEqual(restoredCore.recoveredCorruptPersistenceArtifactCount, 1)
    }

    func testFileBackedQueueFailsClosedWhenEveryGenerationIsCorrupt() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = try makePersistenceRoot("queue-no-recovery")
        let adapter = try TatwoFileBackedDeviceSyncPersistenceAdapter(rootURL: root)
        try adapter.persistOfflineQueue([makeEvent(sequence: 1, now: now)])

        let queueDirectory = root.appendingPathComponent("offlineQueue")
        let onlyGeneration = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: queueDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        try Data("not-an-envelope".utf8).write(to: onlyGeneration)

        XCTAssertThrowsError(try adapter.loadOfflineQueue()) { error in
            guard case TatwoDeviceSyncPersistenceError.noRecoverableGeneration(
                kind: .offlineQueue,
                corruptArtifactURLs: let urls
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(urls, [onlyGeneration])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: onlyGeneration.path))

        let core = makeCore(now: now, persistenceAdapter: adapter)
        let receipt = core.sync(
            .init(
                domainID: "studio",
                transportAvailable: true,
                correlationID: "corrupt-load"
            )
        )
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorKind, .persistenceFailure)
    }

    func testVerifiedSnapshotPersistsAndProviderRecoversPreviousGeneration() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = try makePersistenceRoot("snapshot-recovery")
        let adapter = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: root,
            now: { now }
        )
        let core = makeCore(now: now, persistenceAdapter: adapter)

        XCTAssertEqual(
            core.persistVerifiedSnapshot(correlationID: "snapshot").status,
            .healthy
        )
        let snapshot = try XCTUnwrap(core.verifiedSnapshot())
        try adapter.persistVerifiedSnapshot(snapshot)

        let snapshotDirectory = root.appendingPathComponent("verifiedSnapshot")
        let newest = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: snapshotDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
        )
        try Data("broken-snapshot".utf8).write(to: newest)

        let provider = TatwoPersistedDomainDeviceSnapshotProvider(
            persistenceAdapter: adapter,
            now: { now }
        )
        XCTAssertEqual(provider.verifiedSnapshot(), snapshot)
        XCTAssertEqual(provider.lastLoad?.recoveredFromCorruption, true)
        XCTAssertEqual(provider.lastLoad?.corruptArtifactURLs, [newest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }

    func testPersistenceAndPersistedProviderRejectUnsafeSnapshots() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = try makePersistenceRoot("unsafe-snapshots")
        let adapter = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: root,
            now: { now }
        )
        let splitBrain = makeSnapshot(
            now: now,
            leases: [
                makeLease(deviceID: "mini", epoch: 1, now: now),
                makeLease(deviceID: "book", epoch: 2, now: now)
            ]
        )
        XCTAssertThrowsError(try adapter.persistVerifiedSnapshot(splitBrain)) {
            guard case TatwoDeviceSyncPersistenceError.invalidSnapshot = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        let expired = makeSnapshot(
            now: now,
            leases: [
                makeLease(
                    deviceID: "mini",
                    epoch: 1,
                    now: now.addingTimeInterval(-120)
                )
            ]
        )
        XCTAssertThrowsError(try adapter.persistVerifiedSnapshot(expired)) {
            guard case TatwoDeviceSyncPersistenceError.invalidSnapshot = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        let agingRoot = try makePersistenceRoot("snapshot-expiry-on-load")
        let writer = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: agingRoot,
            now: { now }
        )
        let initiallyValid = makeSnapshot(
            now: now,
            leases: [makeLease(deviceID: "mini", epoch: 1, now: now)]
        )
        try writer.persistVerifiedSnapshot(initiallyValid)
        let reader = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: agingRoot,
            now: { now.addingTimeInterval(120) }
        )
        XCTAssertThrowsError(try reader.loadVerifiedSnapshot()) { error in
            guard case TatwoDeviceSyncPersistenceError.noRecoverableGeneration(
                kind: .verifiedSnapshot,
                corruptArtifactURLs: let urls
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(urls.count, 1)
        }

        let untrusted = InMemorySyncPersistenceAdapter(domainID: "studio")
        try untrusted.persistVerifiedSnapshot(splitBrain)
        let splitProvider = TatwoPersistedDomainDeviceSnapshotProvider(
            persistenceAdapter: untrusted,
            now: { now }
        )
        XCTAssertNil(splitProvider.verifiedSnapshot())

        try untrusted.persistVerifiedSnapshot(expired)
        let expiredProvider = TatwoPersistedDomainDeviceSnapshotProvider(
            persistenceAdapter: untrusted,
            now: { now }
        )
        XCTAssertNil(expiredProvider.verifiedSnapshot())

        for mismatch in [
            makeSnapshot(
                now: now,
                devices: [
                    makeDevice(
                        id: "mini",
                        kind: .macMini,
                        now: now,
                        schemaVersion: 2
                    ),
                    makeDevice(id: "book", kind: .macBook, now: now)
                ],
                leases: [makeLease(deviceID: "mini", epoch: 1, now: now)]
            ),
            makeSnapshot(
                now: now,
                devices: [
                    makeDevice(
                        id: "mini",
                        kind: .macMini,
                        now: now,
                        protocolVersion: 2
                    ),
                    makeDevice(id: "book", kind: .macBook, now: now)
                ],
                leases: [makeLease(deviceID: "mini", epoch: 1, now: now)]
            )
        ] {
            XCTAssertThrowsError(try adapter.persistVerifiedSnapshot(mismatch)) {
                guard case TatwoDeviceSyncPersistenceError.invalidSnapshot = $0 else {
                    return XCTFail("unexpected error: \($0)")
                }
            }
            try untrusted.persistVerifiedSnapshot(mismatch)
            XCTAssertNil(
                TatwoPersistedDomainDeviceSnapshotProvider(
                    persistenceAdapter: untrusted,
                    now: { now }
                ).verifiedSnapshot()
            )
        }
    }

    func testPersistenceAdapterRejectsProtectedPayloadBeforeWriting() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let root = try makePersistenceRoot("protected-egress")
        let adapter = try TatwoFileBackedDeviceSyncPersistenceAdapter(rootURL: root)
        let protected = makeEvent(
            sequence: 1,
            now: now,
            payloadClass: .authSessionToken
        )

        XCTAssertThrowsError(try adapter.persistOfflineQueue([protected])) { error in
            guard case TatwoDeviceSyncPersistenceError.protectedPayload(
                protected.eventID
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("offlineQueue").path
            )
        )
    }

    func testSyncStateRejectsSequenceBeyondCrossRuntimeSafeRangeWithoutOverflow() {
        let persistence = InMemorySyncPersistenceAdapter(domainID: "studio")
        persistence.state = TatwoPersistedDeviceSyncStateV1(
            domainID: "studio",
            lastAcceptedDomainSequence:
                TatwoDomainEventV1.maximumSafeSequence,
            queuedEvents: []
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(
            now: now,
            persistenceAdapter: persistence
        )

        XCTAssertEqual(
            core.sync(
                .init(
                    domainID: "studio",
                    transportAvailable: true,
                    correlationID: "maximum-cursor"
                )
            ).status,
            .healthy
        )
        XCTAssertEqual(
            core.syncCursor,
            TatwoDomainEventV1.maximumSafeSequence
        )
    }

    func testAdoptAuthorityLeaseReplacesActiveLease() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)
        let newLease = makeLease(deviceID: "book", epoch: 2, now: now)

        let receipt = core.adoptAuthorityLease(newLease, correlationID: "adopt")

        XCTAssertEqual(receipt.status, .healthy)
        XCTAssertEqual(receipt.errorKind, TatwoSyncErrorKindV1.none)
        let snapshot = core.verifiedSnapshot()
        XCTAssertEqual(snapshot?.authorityLeases, [newLease])
    }

    func testAdoptAuthorityLeaseRequiresOriginAuthorityGate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(
            now: now,
            originAuthorityProvider: SyncTestAuthorityProvider(allowed: false)
        )
        let newLease = makeLease(deviceID: "book", epoch: 2, now: now)

        let receipt = core.adoptAuthorityLease(newLease, correlationID: "adopt-fenced")

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .leaseEpochMismatch)
        XCTAssertTrue(receipt.detail.contains("origin_authority_gate"))
        XCTAssertEqual(core.verifiedSnapshot()?.authorityLeases.map(\.epoch), [1])
    }

    func testAdoptAuthorityLeaseAllowsConfiguredOriginGate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(
            now: now,
            originAuthorityProvider: SyncTestAuthorityProvider(allowed: true)
        )
        let newLease = makeLease(deviceID: "book", epoch: 2, now: now)

        let receipt = core.adoptAuthorityLease(newLease, correlationID: "adopt-allowed")

        XCTAssertEqual(receipt.status, .healthy)
        XCTAssertEqual(receipt.errorKind, .none)
        XCTAssertEqual(core.verifiedSnapshot()?.authorityLeases, [newLease])
    }

    func testAdoptAuthorityLeaseRejectsEpochRollback() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)

        let receipt = core.adoptAuthorityLease(
            makeLease(deviceID: "book", epoch: 1, now: now, fencingToken: "fence-rollback"),
            correlationID: "adopt-rollback"
        )

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .leaseEpochMismatch)
        XCTAssertEqual(core.verifiedSnapshot()?.authorityLeases.map(\.epoch), [1])
    }

    func testAdoptAuthorityLeaseRejectsFencingTokenReuse() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)
        XCTAssertEqual(
            core.adoptAuthorityLease(
                makeLease(deviceID: "book", epoch: 2, now: now),
                correlationID: "adopt-second"
            ).status,
            .healthy
        )

        let receipt = core.adoptAuthorityLease(
            makeLease(deviceID: "mini", epoch: 3, now: now, fencingToken: "fence-1"),
            correlationID: "adopt-token-reuse"
        )

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .fencingTokenMismatch)
        XCTAssertEqual(core.verifiedSnapshot()?.authorityLeases.map(\.epoch), [2])
    }

    func testAdoptAuthorityLeaseRejectsExpiryBeyondTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)

        let receipt = core.adoptAuthorityLease(
            makeLease(
                deviceID: "book",
                epoch: 2,
                now: now,
                expiresAt: now.addingTimeInterval(
                    TatwoDeviceSyncCore.maximumAuthorityLeaseDuration + 1
                )
            ),
            correlationID: "adopt-expiry"
        )

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .leaseExpired)
        XCTAssertEqual(core.verifiedSnapshot()?.authorityLeases.map(\.epoch), [1])
    }

    func testAdoptAuthorityLeaseRejectsNonHumanConfirmedSource() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)

        let receipt = core.adoptAuthorityLease(
            makeLease(
                deviceID: "book",
                epoch: 2,
                now: now,
                source: .importedVerifiedReceipt
            ),
            correlationID: "adopt-source"
        )

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .humanConfirmationRequired)
        XCTAssertEqual(core.verifiedSnapshot()?.authorityLeases.map(\.epoch), [1])
    }

    func testAdoptAuthorityLeaseRejectsUnregisteredHolder() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)

        let receipt = core.adoptAuthorityLease(
            makeLease(deviceID: "ghost", epoch: 2, now: now),
            correlationID: "adopt-holder"
        )

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .invalidDevice)
        XCTAssertEqual(core.verifiedSnapshot()?.authorityLeases.map(\.epoch), [1])
    }

    func testHeartbeatUpdatesDeviceLastHeartbeatInVerifiedSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000)
        var current = now
        let core = makeCore(now: now, clock: { current })
        current = now.addingTimeInterval(30)

        let receipt = core.heartbeat(deviceID: "mini", correlationID: "hb")

        XCTAssertEqual(receipt.status, .healthy)
        XCTAssertEqual(receipt.errorKind, TatwoSyncErrorKindV1.none)
        let snapshot = core.verifiedSnapshot()
        XCTAssertEqual(
            snapshot?.devices.first { $0.id == "mini" }?.lastHeartbeatAt,
            now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            snapshot?.devices.first { $0.id == "book" }?.lastHeartbeatAt,
            now
        )
    }

    func testHeartbeatRejectsUnregisteredDevice() {
        let now = Date(timeIntervalSince1970: 1_000)
        let core = makeCore(now: now)

        let receipt = core.heartbeat(deviceID: "ghost", correlationID: "hb-ghost")

        XCTAssertEqual(receipt.status, .degraded)
        XCTAssertEqual(receipt.errorKind, .invalidDevice)
        XCTAssertEqual(core.verifiedSnapshot()?.devices.map(\.id), ["book", "mini"])
    }

    private func makeCore(
        now: Date,
        heartbeat: Date? = nil,
        leaseExpiresAt: Date? = nil,
        persistenceAdapter: (any TatwoDeviceSyncPersistenceAdapter)? =
            InMemorySyncPersistenceAdapter(domainID: "studio"),
        transport: (any TatwoDomainCoordinatorTransportPort)? =
            AcknowledgingTransport(),
        effectObserver: (any TatwoDataPlaneEffectObserver)? = nil,
        originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil,
        clock: (() -> Date)? = nil
    ) -> TatwoDeviceSyncCore {
        let mini = makeDevice(id: "mini", kind: .macMini, now: heartbeat ?? now)
        let book = makeDevice(id: "book", kind: .macBook, now: heartbeat ?? now)
        return TatwoDeviceSyncCore(
            domainID: "studio",
            initialDevices: [mini, book],
            authorityLeases: [
                makeLease(
                    deviceID: "mini",
                    epoch: 1,
                    now: now,
                    expiresAt: leaseExpiresAt
                )
            ],
            receiptID: { "receipt-fixed" },
            snapshotProducerReceiptSHA256: { Self.validDigest },
            persistenceAdapter: persistenceAdapter,
            transport: transport,
            effectObserver: effectObserver,
            originAuthorityProvider: originAuthorityProvider,
            now: clock ?? { now }
        )
    }

    private func makePersistenceRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-device-sync-persistence-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }

    private func makeDevice(
        id: String,
        kind: TatwoDomainDeviceKindV1,
        now: Date,
        schemaVersion: Int = 1,
        protocolVersion: Int = 1
    ) -> TatwoDomainDeviceV1 {
        TatwoDomainDeviceV1(
            id: id,
            domainID: "studio",
            displayName: id,
            kind: kind,
            connectionState: .connected,
            schemaVersion: schemaVersion,
            protocolVersion: protocolVersion,
            registeredAt: now,
            lastHeartbeatAt: now
        )
    }

    private func makeSnapshot(
        now: Date,
        devices: [TatwoDomainDeviceV1]? = nil,
        leases: [TatwoAuthorityLeaseV1]
    ) -> TatwoDomainDeviceSnapshotV1 {
        TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: devices ?? [
                makeDevice(id: "mini", kind: .macMini, now: now),
                makeDevice(id: "book", kind: .macBook, now: now)
            ],
            authorityLeases: leases
        )
    }

    private func makeLease(
        deviceID: String,
        epoch: UInt64,
        now: Date,
        expiresAt: Date? = nil,
        fencingToken: String? = nil,
        source: TatwoAuthorityLeaseSourceV1 = .humanConfirmed
    ) -> TatwoAuthorityLeaseV1 {
        TatwoAuthorityLeaseV1(
            domainID: "studio",
            holderDeviceID: deviceID,
            epoch: epoch,
            fencingToken: fencingToken ?? "fence-\(epoch)",
            observedAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(60),
            source: source,
            receiptMetadata: TatwoWorkReceiptMetadataV1(
                receiptID: "lease-\(deviceID)-\(epoch)",
                schema: "TatwoAuthorityLeaseV1",
                version: 1,
                correlationID: "authority",
                createdAt: now,
                sourceDeviceID: deviceID
            )
        )
    }

    private func makeEvent(
        sequence: UInt64,
        now: Date,
        schemaVersion: Int = 1,
        protocolVersion: Int = 1,
        fencingToken: String = "fence-1",
        deviceID: String = "mini",
        leaseEpoch: UInt64 = 1,
        eventID: String? = nil,
        idempotencyKey: String? = nil,
        kind: TatwoDomainEventKindV1 = .receiptMetadata,
        payloadClass: TatwoDomainPayloadClassV1 = .typedMetadata
    ) -> TatwoDomainEventV1 {
        try! TatwoDomainEventV1(
            eventID: eventID ?? "event-\(sequence)",
            domainID: "studio",
            deviceID: deviceID,
            leaseEpoch: leaseEpoch,
            fencingToken: fencingToken,
            idempotencyKey: idempotencyKey ?? "idem-\(sequence)",
            sequence: sequence,
            schemaVersion: schemaVersion,
            protocolVersion: protocolVersion,
            kind: kind,
            payloadClass: payloadClass,
            payload: .object([
                "receiptID": .string("receipt-\(sequence)"),
                "status": .string("ok")
            ]),
            observedAt: now
        )
    }

    private static let validDigest =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

private final class DataPlaneEffectSpy: TatwoDataPlaneEffectObserver {
    private(set) var effects: [TatwoDataPlaneObservedEffectV1] = []

    var updaterInvocationCount: Int {
        effects.filter {
            if case .updaterInvocation = $0 { return true }
            return false
        }.count
    }

    var bundleMutationCount: Int {
        effects.filter {
            if case .bundleMutation = $0 { return true }
            return false
        }.count
    }

    var hostOrRunnerStartCount: Int {
        effects.filter {
            if case .hostOrRunnerStart = $0 { return true }
            return false
        }.count
    }

    func record(_ effect: TatwoDataPlaneObservedEffectV1) {
        effects.append(effect)
    }
}

private final class AcknowledgingTransport: TatwoDomainCoordinatorTransportPort {
    var failuresByEventID: [String: TatwoDomainCoordinatorTransportErrorV1] = [:]
    var idempotentReplayByEventID: [String: Bool] = [:]
    var acknowledgementMutation:
        ((TatwoDomainCoordinatorAppendAcknowledgementV1)
            -> TatwoDomainCoordinatorAppendAcknowledgementV1)?
    private(set) var appendedEvents: [TatwoDomainEventV1] = []

    func append(
        event: TatwoDomainEventV1,
        correlationID: String
    ) throws -> TatwoDomainCoordinatorAppendAcknowledgementV1 {
        appendedEvents.append(event)
        if let failure = failuresByEventID[event.eventID] {
            throw failure
        }
        let acknowledgement = TatwoDomainCoordinatorAppendAcknowledgementV1(
            code: "domain_event_appended",
            eventID: event.eventID,
            idempotencyKey: event.idempotencyKey,
            sequence: event.sequence,
            payloadDigest: event.payloadDigest,
            idempotentReplay:
                idempotentReplayByEventID[event.eventID] ?? false
        )
        return acknowledgementMutation?(acknowledgement) ?? acknowledgement
    }
}

private struct SyncTestAuthorityProvider: TatwoOriginAuthorityProviding {
    let authorityDomainID: String? = "studio"
    let authorityEpoch: UInt64? = 2
    let allowed: Bool

    func isOriginAuthority(
        deviceID: String,
        epoch: UInt64,
        now: Date
    ) -> Bool {
        allowed
    }
}

private final class InMemorySyncPersistenceAdapter:
    TatwoDeviceSyncPersistenceAdapter
{
    var state: TatwoPersistedDeviceSyncStateV1
    var failPersistCallNumbers: Set<Int> = []
    private var persistCallCount = 0
    private var snapshot: TatwoDomainDeviceSnapshotV1?

    init(domainID: String) {
        state = TatwoPersistedDeviceSyncStateV1(
            domainID: domainID,
            lastAcceptedDomainSequence: 0,
            queuedEvents: []
        )
    }

    func loadOfflineQueue() throws -> TatwoPersistedQueueLoadV1 {
        TatwoPersistedQueueLoadV1(
            events: state.queuedEvents,
            sourceURL: nil,
            recoveredFromCorruption: false,
            corruptArtifactURLs: []
        )
    }

    @discardableResult
    func persistOfflineQueue(
        _ events: [TatwoDomainEventV1]
    ) throws -> URL {
        state = TatwoPersistedDeviceSyncStateV1(
            domainID: state.domainID,
            lastAcceptedDomainSequence:
                state.lastAcceptedDomainSequence,
            queuedEvents: events,
            uncertainDeliveryEventIDs:
                state.uncertainDeliveryEventIDs
        )
        return URL(fileURLWithPath: "/tmp/tatwo-in-memory-offline-queue")
    }

    func loadSyncState(
        domainID: String
    ) throws -> TatwoPersistedDeviceSyncStateLoadV1 {
        guard state.domainID == domainID else {
            throw TatwoDeviceSyncPersistenceError.invalidEvent(
                "sync-state-domain"
            )
        }
        return TatwoPersistedDeviceSyncStateLoadV1(
            state: state,
            sourceURL: nil,
            recoveredFromCorruption: false,
            corruptArtifactURLs: []
        )
    }

    @discardableResult
    func persistSyncState(
        _ state: TatwoPersistedDeviceSyncStateV1
    ) throws -> URL {
        persistCallCount += 1
        if failPersistCallNumbers.contains(persistCallCount) {
            throw TatwoDeviceSyncPersistenceError.invalidEvent(
                "injected-persistence-failure"
            )
        }
        self.state = state
        return URL(fileURLWithPath: "/tmp/tatwo-in-memory-sync-state")
    }

    func loadVerifiedSnapshot(
        supportedSchemaVersion: Int,
        supportedProtocolVersion: Int
    ) throws -> TatwoPersistedSnapshotLoadV1 {
        TatwoPersistedSnapshotLoadV1(
            snapshot: snapshot,
            sourceURL: nil,
            recoveredFromCorruption: false,
            corruptArtifactURLs: []
        )
    }

    @discardableResult
    func persistVerifiedSnapshot(
        _ snapshot: TatwoDomainDeviceSnapshotV1
    ) throws -> URL {
        self.snapshot = snapshot
        return URL(fileURLWithPath: "/tmp/tatwo-in-memory-snapshot")
    }
}

private final class StubHTTPClient: TatwoDomainCoordinatorHTTPClient {
    var responseBody = Data()
    var statusCode = 200
    var thrownError: Error?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let thrownError {
            throw thrownError
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/2",
            headerFields: ["content-type": "application/json"]
        )!
        return (responseBody, response)
    }
}

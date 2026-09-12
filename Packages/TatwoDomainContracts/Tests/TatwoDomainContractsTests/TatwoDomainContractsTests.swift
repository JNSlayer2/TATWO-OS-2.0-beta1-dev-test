import Foundation
import XCTest
import TatwoWorkReceiptContracts
@testable import TatwoDomainContracts

final class TatwoDomainContractsTests: XCTestCase {
    func testSnapshotContractsAreFoundationOnlyImmutableValues() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(now: now)

        try TatwoDomainSnapshotValidatorV1.validate(snapshot, now: now)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(TatwoDomainDeviceSnapshotV1.self, from: encoded),
            snapshot
        )
    }

    func testSnapshotRejectsDuplicateDevicesAndSplitBrain() {
        let now = Date(timeIntervalSince1970: 1_000)
        let device = makeDevice(id: "mini", now: now)
        let duplicate = TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: [device, device],
            authorityLeases: []
        )
        XCTAssertThrowsError(try TatwoDomainSnapshotValidatorV1.validate(duplicate, now: now)) {
            XCTAssertEqual($0 as? TatwoDomainSnapshotValidationError, .duplicateDevice)
        }

        let second = makeDevice(id: "book", now: now)
        let splitBrain = TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: [device, second],
            authorityLeases: [
                makeLease(deviceID: "mini", epoch: 1, now: now),
                makeLease(deviceID: "book", epoch: 2, now: now)
            ]
        )
        XCTAssertThrowsError(try TatwoDomainSnapshotValidatorV1.validate(splitBrain, now: now)) {
            XCTAssertEqual($0 as? TatwoDomainSnapshotValidationError, .splitBrain)
        }
    }

    func testSnapshotRejectsDeviceSchemaAndProtocolMismatch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let schemaMismatch = makeSnapshot(
            now: now,
            device: makeDevice(
                id: "mini",
                now: now,
                schemaVersion: 2
            )
        )
        XCTAssertThrowsError(
            try TatwoDomainSnapshotValidatorV1.validate(
                schemaMismatch,
                now: now
            )
        ) {
            XCTAssertEqual(
                $0 as? TatwoDomainSnapshotValidationError,
                .deviceSchemaIncompatible
            )
        }
        XCTAssertNil(
            TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: schemaMismatch,
                now: { now }
            ).verifiedSnapshot()
        )

        let protocolMismatch = makeSnapshot(
            now: now,
            device: makeDevice(
                id: "mini",
                now: now,
                protocolVersion: 2
            )
        )
        XCTAssertThrowsError(
            try TatwoDomainSnapshotValidatorV1.validate(
                protocolMismatch,
                now: now
            )
        ) {
            XCTAssertEqual(
                $0 as? TatwoDomainSnapshotValidationError,
                .deviceProtocolIncompatible
            )
        }
        XCTAssertNil(
            TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: protocolMismatch,
                now: { now }
            ).verifiedSnapshot()
        )
    }

    func testStaticProviderRejectsSplitBrainAndExpiredAuthorityLease() {
        let now = Date(timeIntervalSince1970: 1_000)
        let mini = makeDevice(id: "mini", now: now)
        let book = makeDevice(id: "book", now: now)
        let splitBrain = TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: [mini, book],
            authorityLeases: [
                makeLease(deviceID: "mini", epoch: 1, now: now),
                makeLease(deviceID: "book", epoch: 2, now: now)
            ]
        )
        let splitProvider = TatwoStaticDomainDeviceSnapshotProvider(
            snapshot: splitBrain,
            now: { now }
        )
        XCTAssertNil(splitProvider.verifiedSnapshot())

        let expired = TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: [mini],
            authorityLeases: [
                makeLease(
                    deviceID: "mini",
                    epoch: 1,
                    now: now.addingTimeInterval(-120)
                )
            ]
        )
        let expiredProvider = TatwoStaticDomainDeviceSnapshotProvider(
            snapshot: expired,
            now: { now }
        )
        XCTAssertNil(expiredProvider.verifiedSnapshot())
    }

    func testProtectedPayloadClassesAreDefaultDeny() {
        XCTAssertFalse(TatwoDomainPayloadClassV1.typedMetadata.isProtected)
        XCTAssertFalse(TatwoDomainPayloadClassV1.attachmentReference.isProtected)
        XCTAssertTrue(TatwoDomainPayloadClassV1.authSessionToken.isProtected)
        XCTAssertTrue(TatwoDomainPayloadClassV1.rawDatabase.isProtected)
        XCTAssertTrue(TatwoDomainPayloadClassV1.sourceTree.isProtected)
    }

    func testTypedPayloadAllowlistBindsEventKindToPayloadClass() {
        XCTAssertTrue(
            TatwoDomainPayloadClassV1.goalRunProjection.isAllowed(for: .goalRunProjection)
        )
        XCTAssertTrue(
            TatwoDomainPayloadClassV1.threadMessageProjection.isAllowed(for: .messageProjection)
        )
        XCTAssertFalse(
            TatwoDomainPayloadClassV1.typedMetadata.isAllowed(for: .messageProjection)
        )
        XCTAssertFalse(
            TatwoDomainPayloadClassV1.threadMessageProjection.isAllowed(for: .receiptMetadata)
        )
    }

    func testCanonicalTypedPayloadDigestIsStableAcrossObjectKeyOrder() throws {
        let first = TatwoDomainJSONValueV1.object([
            "status": .string("ok"),
            "nested": .object([
                "count": .integer(2),
                "enabled": .bool(true)
            ])
        ])
        let reordered = TatwoDomainJSONValueV1.object([
            "nested": .object([
                "enabled": .bool(true),
                "count": .integer(2)
            ]),
            "status": .string("ok")
        ])

        XCTAssertEqual(first.canonicalJSONString, reordered.canonicalJSONString)
        XCTAssertEqual(
            try TatwoDomainPayloadValidatorV1.digest(first),
            try TatwoDomainPayloadValidatorV1.digest(reordered)
        )
        XCTAssertEqual(
            try TatwoDomainPayloadValidatorV1.digest(first),
            "22140370b692dcc11d4dfb33c25bc2ab142ea4953aa4e96b32d4feccfa0b23b7"
        )
    }

    func testPayloadValidationRejectsProtectedKeysAndOversizeData() {
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object(["authToken": .string("must-not-sync")])
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainPayloadValidationErrorV1,
                .protectedKey(path: "$.authToken")
            )
        }
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object([
                    "sequence": .integer(
                        TatwoDomainPayloadValidatorV1.maximumSafeInteger + 1
                    )
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainPayloadValidationErrorV1,
                .integerOutOfRange(path: "$.sequence")
            )
        }

        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object([
                    "body": .string(
                        String(
                            repeating: "x",
                            count: TatwoDomainPayloadValidatorV1.maximumPayloadBytes
                        )
                    )
                ])
            )
        ) { error in
            guard case .payloadTooLarge = error as? TatwoDomainPayloadValidationErrorV1 else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object(["日本語": .string("must-use-typed-ascii-key")])
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainPayloadValidationErrorV1,
                .invalidKey(path: "$.日本語")
            )
        }
        XCTAssertNoThrow(
            try TatwoDomainPayloadValidatorV1.validate(
                .object(["authority": .string("primary")])
            )
        )
    }

    func testPayloadValidationRejectsSecretBearingValuesAndAllowsTypedMetadata() {
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object(["apiKey": .string("must-not-sync")])
            )
        )
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object([
                    "note": .string("sk-proj-abcdefghijklmnopqrstuvwxyz0123456789")
                ])
            )
        )
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object([
                    "certificate": .string(
                        "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----"
                    )
                ])
            )
        )
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object([
                    "note": .string(
                        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJtaW5pIn0.signature"
                    )
                ])
            )
        )
        XCTAssertThrowsError(
            try TatwoDomainPayloadValidatorV1.validate(
                .object([
                    "note": .string(String(repeating: "a", count: 41))
                ])
            )
        )
        XCTAssertNoThrow(
            try TatwoDomainPayloadValidatorV1.validate(
                .object([
                    "deviceID": .string("mini"),
                    "online": .bool(true),
                    "status": .string("healthy")
                ])
            )
        )
    }

    func testDomainEventDecodeRejectsTamperedPayloadDigest() throws {
        let event = try TatwoDomainEventV1(
            eventID: "event-1",
            domainID: "studio",
            deviceID: "mini",
            leaseEpoch: 1,
            fencingToken: "fence-1",
            idempotencyKey: "idem-1",
            sequence: 1,
            schemaVersion: 1,
            protocolVersion: 1,
            kind: .receiptMetadata,
            payloadClass: .typedMetadata,
            payload: .object(["receiptID": .string("receipt-1")]),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any]
        )
        object["payloadDigest"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(
            try decoder.decode(TatwoDomainEventV1.self, from: tampered)
        )
    }

    func testCanonicalPayloadDigestMatchesNodeForUnicodeValues() throws {
        let payload = TatwoDomainJSONValueV1.object([
            "message": .string("日本🙂\u{2028}line"),
            "key": .string("value")
        ])

        XCTAssertEqual(
            try TatwoDomainPayloadValidatorV1.digest(payload),
            "2698c26cac4386e2147ff1ce139385b267f77b03c0c88fa9d5b78a5fd351fa2e"
        )
    }

    func testDomainEventSequenceMustFitJavaScriptSafeIntegerRange() {
        XCTAssertThrowsError(
            try TatwoDomainEventV1(
                eventID: "event-unsafe-sequence",
                domainID: "studio",
                deviceID: "mini",
                leaseEpoch: 1,
                fencingToken: "fence-1",
                idempotencyKey: "idem-unsafe-sequence",
                sequence: TatwoDomainEventV1.maximumSafeSequence + 1,
                schemaVersion: 1,
                protocolVersion: 1,
                kind: .receiptMetadata,
                payloadClass: .typedMetadata,
                payload: .object([
                    "receiptID": .string("receipt-unsafe-sequence")
                ]),
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainPayloadValidationErrorV1,
                .integerOutOfRange(path: "$.sequence")
            )
        }

        XCTAssertThrowsError(
            try TatwoDomainEventV1(
                eventID: "event-unsafe-lease",
                domainID: "studio",
                deviceID: "mini",
                leaseEpoch: TatwoDomainEventV1.maximumSafeSequence + 1,
                fencingToken: "fence-unsafe",
                idempotencyKey: "idem-unsafe-lease",
                sequence: 1,
                schemaVersion: 1,
                protocolVersion: 1,
                kind: .receiptMetadata,
                payloadClass: .typedMetadata,
                payload: .object([
                    "receiptID": .string("receipt-unsafe-lease")
                ]),
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainPayloadValidationErrorV1,
                .integerOutOfRange(path: "$.leaseEpoch")
            )
        }
    }

    func testSnapshotRejectsPlaceholderProducerDigest() {
        let now = Date(timeIntervalSince1970: 1_000)
        let placeholder = TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: String(repeating: "a", count: 64),
            observedAt: now,
            devices: [makeDevice(id: "mini", now: now)],
            authorityLeases: [makeLease(deviceID: "mini", epoch: 1, now: now)]
        )
        XCTAssertThrowsError(try TatwoDomainSnapshotValidatorV1.validate(placeholder, now: now)) {
            XCTAssertEqual(
                $0 as? TatwoDomainSnapshotValidationError,
                .invalidProducerDigest
            )
        }
    }

    func testSyncHealthReceiptAlwaysCarriesZeroCrossPlaneEffectEvidence() {
        let receipt = TatwoSyncHealthReceiptV1(
            receiptID: "receipt",
            correlationID: "sync",
            status: .failed,
            attempts: 1,
            errorKind: .snapshotCorrupt,
            observedAt: Date(timeIntervalSince1970: 1),
            lastOKAt: nil,
            detail: "corrupt"
        )

        XCTAssertTrue(receipt.hasError)
        XCTAssertEqual(receipt.safetyEvidence.updaterCallCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.bundleMutationCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.authMaterialReadCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.automaticElectionCount, 0)
    }

    private func makeSnapshot(
        now: Date,
        device: TatwoDomainDeviceV1? = nil
    ) -> TatwoDomainDeviceSnapshotV1 {
        let device = device ?? makeDevice(id: "mini", now: now)
        return TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: [device],
            authorityLeases: [makeLease(deviceID: device.id, epoch: 1, now: now)]
        )
    }

    private func makeDevice(
        id: String,
        now: Date,
        schemaVersion: Int = 1,
        protocolVersion: Int = 1
    ) -> TatwoDomainDeviceV1 {
        TatwoDomainDeviceV1(
            id: id,
            domainID: "studio",
            displayName: id,
            kind: id == "mini" ? .macMini : .macBook,
            connectionState: .connected,
            schemaVersion: schemaVersion,
            protocolVersion: protocolVersion,
            registeredAt: now,
            lastHeartbeatAt: now
        )
    }

    private func makeLease(deviceID: String, epoch: UInt64, now: Date) -> TatwoAuthorityLeaseV1 {
        TatwoAuthorityLeaseV1(
            domainID: "studio",
            holderDeviceID: deviceID,
            epoch: epoch,
            fencingToken: "fence-\(epoch)",
            observedAt: now,
            expiresAt: now.addingTimeInterval(60),
            source: .humanConfirmed,
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

    private static let validDigest =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    func testEventKindAndPayloadClassAreCaseIterable() {
        XCTAssertEqual(TatwoDomainEventKindV1.allCases.count, 12)
        XCTAssertEqual(TatwoDomainPayloadClassV1.allCases.count, 16)
        for kind in TatwoDomainEventKindV1.allCases {
            let allowed = TatwoDomainPayloadClassV1.allCases.filter { $0.isAllowed(for: kind) }
            XCTAssertEqual(allowed.count, 1, "each event kind maps to exactly one payload class: \(kind)")
            XCTAssertFalse(allowed[0].isProtected, "allowed payload class must not be protected: \(kind)")
        }
    }

    func testAuthorityLeaseGrantContractsRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let request = TatwoAuthorityLeaseGrantRequestV1(
            domainID: "studio",
            toDeviceID: "mini",
            leaseEpoch: 1,
            fencingToken: "token-1",
            expectedSequence: 0,
            expiresAt: now.addingTimeInterval(8 * 3600),
            approvalID: "approval-1",
            approvedAt: now,
            idempotencyKey: "idem-1",
            correlationID: "corr-1"
        )
        let encodedRequest = try JSONEncoder().encode(request)
        XCTAssertEqual(
            try JSONDecoder().decode(TatwoAuthorityLeaseGrantRequestV1.self, from: encodedRequest),
            request
        )

        let acknowledgement = TatwoAuthorityLeaseGrantAcknowledgementV1(
            code: "authority_lease_granted",
            sequence: 1,
            holderDeviceID: "mini",
            leaseEpoch: 1,
            fencingToken: "token-1",
            expiresAt: request.expiresAt,
            idempotentReplay: false
        )
        let encodedAck = try JSONEncoder().encode(acknowledgement)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TatwoAuthorityLeaseGrantAcknowledgementV1.self,
                from: encodedAck
            ),
            acknowledgement
        )

        let summary = TatwoCoordinatorSnapshotSummaryV1(
            domainID: "studio",
            nextSequence: 1,
            activeLease: nil
        )
        let encodedSummary = try JSONEncoder().encode(summary)
        XCTAssertEqual(
            try JSONDecoder().decode(TatwoCoordinatorSnapshotSummaryV1.self, from: encodedSummary),
            summary
        )
    }

    func testSnapshotSummaryLightweightLeaseFieldsDefaultToNilAndRoundTrip() throws {
        let defaulted = TatwoCoordinatorSnapshotSummaryV1(
            domainID: "studio",
            nextSequence: 3,
            activeLease: nil
        )
        XCTAssertNil(defaulted.activeLeaseEpoch)
        XCTAssertNil(defaulted.activeLeaseHolderDeviceID)

        let populated = TatwoCoordinatorSnapshotSummaryV1(
            domainID: "studio",
            nextSequence: 4,
            activeLease: nil,
            activeLeaseEpoch: 9,
            activeLeaseHolderDeviceID: "mini"
        )
        XCTAssertEqual(populated.activeLeaseEpoch, 9)
        XCTAssertEqual(populated.activeLeaseHolderDeviceID, "mini")
        let encoded = try JSONEncoder().encode(populated)
        XCTAssertEqual(
            try JSONDecoder().decode(TatwoCoordinatorSnapshotSummaryV1.self, from: encoded),
            populated
        )
    }

    func testSnapshotSummaryDecodesLegacyJSONWithoutLightweightLeaseKeys() throws {
        let legacyJSON = Data(
            #"{"domainID":"studio","nextSequence":7,"activeLease":null}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            TatwoCoordinatorSnapshotSummaryV1.self,
            from: legacyJSON
        )
        XCTAssertEqual(decoded.domainID, "studio")
        XCTAssertEqual(decoded.nextSequence, 7)
        XCTAssertNil(decoded.activeLease)
        XCTAssertNil(decoded.activeLeaseEpoch)
        XCTAssertNil(decoded.activeLeaseHolderDeviceID)
    }
}

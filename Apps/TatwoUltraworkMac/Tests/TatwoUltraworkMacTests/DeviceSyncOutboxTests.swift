import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class DeviceSyncOutboxTests: XCTestCase {
    func testTargetAttestationVerifierRequiresAllFiveCanonicalConsumers() {
        XCTAssertEqual(
            DeviceSyncTargetAttestationVerifier.requiredConsumerIDs,
            [
                "work-os.bootstrap",
                "tatwo-app.shared-runtime",
                "skillet.runtime-loader",
                "codex.native-skills",
                "claude.native-skills",
            ]
        )
    }

    func testDefaultApplicationSupportRootUsesCanonicalUltraworkOverride() {
        let canonicalKey = "TATWO_ULTRAWORK_APP_SUPPORT"
        let legacyKey = "TATWO_APP_SUPPORT"
        let originalCanonical = getenv(canonicalKey).map { String(cString: $0) }
        let originalLegacy = getenv(legacyKey).map { String(cString: $0) }
        defer {
            if let originalCanonical {
                setenv(canonicalKey, originalCanonical, 1)
            } else {
                unsetenv(canonicalKey)
            }
            if let originalLegacy {
                setenv(legacyKey, originalLegacy, 1)
            } else {
                unsetenv(legacyKey)
            }
        }

        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-canonical-app-support", isDirectory: true)
            .standardizedFileURL
        let legacy = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-legacy-app-support", isDirectory: true)
            .standardizedFileURL
        setenv(canonicalKey, expected.path, 1)
        setenv(legacyKey, legacy.path, 1)

        XCTAssertEqual(
            DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
                .standardizedFileURL,
            expected
        )
    }

    func testDefaultApplicationSupportRootPreservesLegacyDeviceSyncAlias() {
        let canonicalKey = "TATWO_ULTRAWORK_APP_SUPPORT"
        let legacyKey = "TATWO_APP_SUPPORT"
        let originalCanonical = getenv(canonicalKey).map { String(cString: $0) }
        let originalLegacy = getenv(legacyKey).map { String(cString: $0) }
        defer {
            if let originalCanonical {
                setenv(canonicalKey, originalCanonical, 1)
            } else {
                unsetenv(canonicalKey)
            }
            if let originalLegacy {
                setenv(legacyKey, originalLegacy, 1)
            } else {
                unsetenv(legacyKey)
            }
        }

        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-legacy-app-support", isDirectory: true)
            .standardizedFileURL
        unsetenv(canonicalKey)
        setenv(legacyKey, expected.path, 1)

        XCTAssertEqual(
            DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
                .standardizedFileURL,
            expected
        )
    }

    func testEnqueueWritesUUIDNamedIntentJSONAtomically() throws {
        try withTemporaryDirectory { root in
            let requestedAt = Date(timeIntervalSince1970: 1_752_000_000)
            let intentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            let store = DeviceSyncOutboxStore(
                rootURL: root,
                now: { requestedAt },
                uuid: { intentID }
            )

            let intent = try store.enqueue(target: "macbook-m3", action: "system-pull")

            XCTAssertEqual(intent.target, "macbook-m3")
            XCTAssertEqual(intent.action, "system-pull")
            XCTAssertEqual(intent.requestedAt, requestedAt)

            let pending = root
                .appendingPathComponent("device-sync-outbox", isDirectory: true)
                .appendingPathComponent("pending", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: pending,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(files.map(\.lastPathComponent), ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json"])

            let data = try Data(contentsOf: try XCTUnwrap(files.first))
            let decoded = try DeviceSyncOutboxJSON.decoder.decode(DeviceSyncIntent.self, from: data)
            XCTAssertEqual(decoded, intent)
            XCTAssertFalse(files.contains { $0.pathExtension == "tmp" })
        }
    }

    func testEnqueueRejectsCombinedActionThatCannotConverge() throws {
        try withTemporaryDirectory { root in
            let store = DeviceSyncOutboxStore(rootURL: root)

            XCTAssertThrowsError(
                try store.enqueue(target: "macbook-m3", action: "both")
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("separate")
                        || error.localizedDescription.contains("分開")
                )
            }

            XCTAssertEqual(try store.pendingCount(), 0)
        }
    }

    func testPendingCountOnlyCountsPendingJSONFiles() throws {
        try withTemporaryDirectory { root in
            let store = DeviceSyncOutboxStore(rootURL: root)
            let pending = root
                .appendingPathComponent("device-sync-outbox", isDirectory: true)
                .appendingPathComponent("pending", isDirectory: true)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: pending.appendingPathComponent("one.json"))
            try Data("{}".utf8).write(to: pending.appendingPathComponent("two.json"))
            try Data("not json".utf8).write(to: pending.appendingPathComponent("ignored.txt"))
            try Data("{}".utf8).write(to: pending.appendingPathComponent(".staging.tmp"))

            XCTAssertEqual(try store.pendingCount(), 2)
        }
    }

    func testReceiptLoadResultParsesReceiptAndFailsClosedOnMalformedJSON() throws {
        try withTemporaryDirectory { root in
            let requestedAt = Date(timeIntervalSince1970: 1_752_000_000)
            let completedAt = Date(timeIntervalSince1970: 1_752_000_030)
            let store = DeviceSyncOutboxStore(rootURL: root)
            let receipts = root
                .appendingPathComponent("device-sync-outbox", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)

            let receipt = DeviceSyncReceipt(
                target: "macbook-m3",
                action: "both",
                requestedAt: requestedAt,
                result: "pending",
                completedAt: completedAt,
                message: "sync-request delivered",
                phase: .delivered,
                requestID: "request-1",
                authorityEpoch: 3,
                ledgerSequence: 7,
                authorityPrimary: "mac-mini",
                sourceDeviceID: "mini-id",
                targetDeviceID: "book-id",
                catalogRevision: "2026-07-23.1",
                digestAlgorithm: "sha256",
                sourceDigest: String(repeating: "a", count: 64),
                appliedDigest: String(repeating: "a", count: 64),
                requiredItemIDs: ["os.issue"],
                items: [
                    .init(
                        id: "os.issue",
                        displayName: "issue.md",
                        phase: .verified,
                        digestAlgorithm: "sha256",
                        sourceDigest: String(repeating: "a", count: 64),
                        appliedDigest: String(repeating: "a", count: 64),
                        message: "verified"
                    )
                ]
            )
            let data = try DeviceSyncOutboxJSON.encoder.encode(receipt)
            try data.write(to: receipts.appendingPathComponent("intent.json"))
            try Data("{ malformed".utf8).write(to: receipts.appendingPathComponent("broken.json"))
            try Data("{}".utf8).write(to: receipts.appendingPathComponent("ignored.txt"))

            let result = try store.receiptLoadResult()

            XCTAssertEqual(result.receipts, [receipt])
            XCTAssertTrue(result.isFailClosed)
            XCTAssertEqual(result.issues.map(\.kind), ["receipt-unreadable"])
            XCTAssertTrue(result.issues[0].message.contains("broken.json"))
            XCTAssertNil(result.issues[0].target)
            XCTAssertNil(result.issues[0].action)
            XCTAssertNil(result.issues[0].requestID)
        }
    }

    func testConflictingPhasesForSameRequestBindingFailClosedInsteadOfUsingClockOrPhasePrecedence() throws {
        try withTemporaryDirectory { root in
            let store = DeviceSyncOutboxStore(rootURL: root)
            let receipts = root
                .appendingPathComponent("device-sync-outbox", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: receipts,
                withIntermediateDirectories: true
            )

            let delivered = DeviceSyncReceipt(
                target: "macbook-m3",
                action: "version-pull",
                requestedAt: Date(timeIntervalSince1970: 9_000),
                result: "pending",
                completedAt: Date(timeIntervalSince1970: 9_999),
                message: "delivered artifact",
                phase: .delivered,
                requestID: "request-conflict",
                authorityEpoch: 8,
                ledgerSequence: 12
            )
            let validating = DeviceSyncReceipt(
                target: "macbook-m3",
                action: "version-pull",
                requestedAt: Date(timeIntervalSince1970: 1),
                result: "partial",
                completedAt: Date(timeIntervalSince1970: 2),
                message: "validating artifact",
                phase: .validating,
                requestID: "request-conflict",
                authorityEpoch: 8,
                ledgerSequence: 12
            )
            try DeviceSyncOutboxJSON.encoder.encode(delivered).write(
                to: receipts.appendingPathComponent("a.json")
            )
            try DeviceSyncOutboxJSON.encoder.encode(validating).write(
                to: receipts.appendingPathComponent("b.json")
            )

            let result = try store.receiptLoadResult()
            let indexed = DeviceSyncOperationIndex.latestReceipts(result.receipts)
            let selected = try XCTUnwrap(indexed[delivered.operationKey])
            let presentation = DeviceSyncReceiptPresentation(
                receipt: selected,
                artifactIssues: result.issues
            )

            XCTAssertTrue(result.isFailClosed)
            XCTAssertEqual(result.issues.map(\.kind), ["receipt-conflict"])
            XCTAssertEqual(result.issues.first?.target, "macbook-m3")
            XCTAssertEqual(result.issues.first?.action, "version-pull")
            XCTAssertEqual(result.issues.first?.requestID, "request-conflict")
            XCTAssertEqual(presentation.state, .unreadable)
            XCTAssertFalse(presentation.isConverged)
        }
    }

    func testReceiptConflictAcrossTargetsAndActionsDoesNotScopeToArbitraryFirstArtifact() throws {
        try withTemporaryDirectory { root in
            let store = DeviceSyncOutboxStore(rootURL: root)
            let receipts = root
                .appendingPathComponent("device-sync-outbox", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: receipts,
                withIntermediateDirectories: true
            )

            let first = DeviceSyncReceipt(
                target: "macbook-a",
                action: "system-pull",
                requestedAt: Date(timeIntervalSince1970: 1),
                result: "pending",
                completedAt: Date(timeIntervalSince1970: 2),
                message: "first",
                phase: .delivered,
                requestID: "request-cross-target",
                authorityEpoch: 8,
                ledgerSequence: 12
            )
            let second = DeviceSyncReceipt(
                target: "macbook-b",
                action: "version-pull",
                requestedAt: Date(timeIntervalSince1970: 1),
                result: "partial",
                completedAt: Date(timeIntervalSince1970: 3),
                message: "second",
                phase: .validating,
                requestID: "request-cross-target",
                authorityEpoch: 8,
                ledgerSequence: 12
            )
            try DeviceSyncOutboxJSON.encoder.encode(first).write(
                to: receipts.appendingPathComponent("a.json")
            )
            try DeviceSyncOutboxJSON.encoder.encode(second).write(
                to: receipts.appendingPathComponent("b.json")
            )

            let result = try store.receiptLoadResult()
            let issue = try XCTUnwrap(result.issues.first)

            XCTAssertEqual(issue.kind, "receipt-conflict")
            XCTAssertEqual(issue.requestID, "request-cross-target")
            XCTAssertNil(issue.target)
            XCTAssertNil(issue.action)
        }
    }

    func testMalformedTransactionJournalUsesProductionGlobalIssueShape() throws {
        try withTemporaryDirectory { root in
            let transactionDirectory = root
                .appendingPathComponent("device-sync-state", isDirectory: true)
                .appendingPathComponent("system-transactions", isDirectory: true)
                .appendingPathComponent("request-malformed", isDirectory: true)
            try FileManager.default.createDirectory(
                at: transactionDirectory,
                withIntermediateDirectories: true
            )
            try Data("{ malformed".utf8).write(
                to: transactionDirectory.appendingPathComponent("journal.json")
            )

            let result = try DeviceSyncOutboxStore(
                rootURL: root
            ).transactionProjectionLoadResult(receipts: [])
            let issue = try XCTUnwrap(result.issues.first)

            XCTAssertEqual(issue.kind, "transaction-journal-unreadable")
            XCTAssertNil(issue.target)
            XCTAssertNil(issue.action)
            XCTAssertNil(issue.requestID)
        }
    }

    func testFutureReceiptSchemaBlocksOtherwiseConvergedPresentation() throws {
        try withTemporaryDirectory { root in
            let requestID = "request-valid"
            _ = try writeAttestationFixture(
                root: root,
                requestID: requestID,
                authorityEpoch: 7,
                ledgerSequence: 30,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let store = DeviceSyncOutboxStore(rootURL: root)
            let receiptsDirectory = root
                .appendingPathComponent("device-sync-outbox", isDirectory: true)
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: receiptsDirectory,
                withIntermediateDirectories: true
            )
            try Data(
                """
                {
                  "schema": "TatwoDeviceSyncReceiptV999",
                  "schemaVersion": 999
                }
                """.utf8
            ).write(to: receiptsDirectory.appendingPathComponent("future.json"))

            let result = try store.receiptLoadResult()
            let loaded = try XCTUnwrap(
                result.receipts.first { $0.requestID == requestID }
            )
            let presentation = DeviceSyncReceiptPresentation(
                receipt: loaded,
                artifactIssues: result.issues
            )

            XCTAssertTrue(loaded.isConverged)
            XCTAssertTrue(result.isFailClosed)
            XCTAssertEqual(result.issues.map(\.kind), ["receipt-unreadable"])
            XCTAssertEqual(presentation.state, .unreadable)
            XCTAssertFalse(presentation.isConverged)
        }
    }

    func testSignedChannelACKProjectsIssueAndTargetAttestation() throws {
        try withTemporaryDirectory { root in
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-channel-projection",
                authorityEpoch: 9,
                ledgerSequence: 41,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let store = DeviceSyncOutboxStore(rootURL: root)

            let result = try store.receiptLoadResult()
            let receipt = try XCTUnwrap(
                result.receipts.first {
                    $0.requestID == "request-channel-projection"
                }
            )

            XCTAssertTrue(result.issues.isEmpty)
            XCTAssertEqual(
                receipt.attestationEvidence.level,
                .targetLocallyAttested
            )
            XCTAssertTrue(receipt.isConverged)
            XCTAssertEqual(receipt.items?.map(\.displayName), [
                "os.md",
                "issue.md",
                "TODO.md",
                "Skillet private repositories",
            ])
            XCTAssertEqual(
                DeviceSyncOperationIndex.targetNames(
                    pending: [:],
                    receipts: DeviceSyncOperationIndex.latestReceipts(
                        result.receipts
                    )
                ),
                ["macbook-m3"]
            )
            XCTAssertEqual(
                fixture.channelRoot.standardizedFileURL,
                root
                    .appendingPathComponent(
                        "device-sync-channel",
                        isDirectory: true
                    )
                    .standardizedFileURL
            )
        }
    }

    func testSignedOutboxACKVerifiesWhenChannelACKCopyIsArchived() throws {
        try withTemporaryDirectory { root in
            let requestID = "request-signed-outbox-only"
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: requestID,
                authorityEpoch: 9,
                ledgerSequence: 411,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let channelACK = fixture.channelRoot
                .appendingPathComponent("acks", isDirectory: true)
                .appendingPathComponent("\(requestID).json")
            let receiptData = try Data(contentsOf: channelACK)
            let outboxDirectory = root
                .appendingPathComponent(
                    "device-sync-outbox",
                    isDirectory: true
                )
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outboxDirectory,
                withIntermediateDirectories: true
            )
            try receiptData.write(
                to: outboxDirectory.appendingPathComponent("\(requestID).json")
            )
            try FileManager.default.moveItem(
                at: channelACK,
                to: root.appendingPathComponent(
                    "\(requestID)-archived-channel-ack.json"
                )
            )

            let result = try DeviceSyncOutboxStore(
                rootURL: root
            ).receiptLoadResult()
            let receipt = try XCTUnwrap(result.receipts.first)

            XCTAssertTrue(result.issues.isEmpty)
            XCTAssertEqual(
                receipt.attestationEvidence.level,
                .targetLocallyAttested
            )
            XCTAssertTrue(receipt.isConverged)
        }
    }

    func testOutboxOnlyTerminalACKWithoutSignatureFailsClosed() throws {
        try withTemporaryDirectory { root in
            let requestID = "request-outbox-missing-signature"
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: requestID,
                authorityEpoch: 9,
                ledgerSequence: 412,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let channelACK = fixture.channelRoot
                .appendingPathComponent("acks", isDirectory: true)
                .appendingPathComponent("\(requestID).json")
            let receiptData = try Data(contentsOf: channelACK)
            let outboxDirectory = root
                .appendingPathComponent(
                    "device-sync-outbox",
                    isDirectory: true
                )
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outboxDirectory,
                withIntermediateDirectories: true
            )
            try receiptData.write(
                to: outboxDirectory.appendingPathComponent("\(requestID).json")
            )
            try FileManager.default.moveItem(
                at: channelACK,
                to: root.appendingPathComponent(
                    "\(requestID)-archived-channel-ack.json"
                )
            )
            let signature = fixture.channelRoot
                .appendingPathComponent("signatures", isDirectory: true)
                .appendingPathComponent("acks", isDirectory: true)
                .appendingPathComponent("\(requestID).json")
            try FileManager.default.moveItem(
                at: signature,
                to: root.appendingPathComponent(
                    "\(requestID)-archived-ack-signature.json"
                )
            )

            let result = try DeviceSyncOutboxStore(
                rootURL: root
            ).receiptLoadResult()
            let receipt = try XCTUnwrap(result.receipts.first)

            XCTAssertEqual(result.issues.map(\.kind), ["attestation-unreadable"])
            XCTAssertTrue(result.issues.allSatisfy { $0.target == nil })
            XCTAssertTrue(result.issues.allSatisfy { $0.action == nil })
            XCTAssertTrue(result.issues.allSatisfy { $0.requestID == nil })
            XCTAssertEqual(receipt.attestationEvidence.level, .unreadable)
            XCTAssertFalse(receipt.isConverged)
        }
    }

    func testTamperedOutboxOnlyACKFailsSignatureAndNeverConverges() throws {
        try withTemporaryDirectory { root in
            let requestID = "request-outbox-tampered"
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: requestID,
                authorityEpoch: 9,
                ledgerSequence: 413,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let channelACK = fixture.channelRoot
                .appendingPathComponent("acks", isDirectory: true)
                .appendingPathComponent("\(requestID).json")
            let receiptData = try Data(contentsOf: channelACK)
            guard var object = try JSONSerialization.jsonObject(
                with: receiptData
            ) as? [String: Any] else {
                return XCTFail("channel ACK must be a JSON object")
            }
            object["message"] = "tampered outbox-only message"
            object["progress"] = ["percent": 100]

            let outboxDirectory = root
                .appendingPathComponent(
                    "device-sync-outbox",
                    isDirectory: true
                )
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outboxDirectory,
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ).write(
                to: outboxDirectory.appendingPathComponent("\(requestID).json")
            )
            try FileManager.default.moveItem(
                at: channelACK,
                to: root.appendingPathComponent(
                    "\(requestID)-archived-channel-ack.json"
                )
            )

            let result = try DeviceSyncOutboxStore(
                rootURL: root
            ).receiptLoadResult()
            let receipt = try XCTUnwrap(result.receipts.first)

            XCTAssertEqual(result.issues.map(\.kind), ["attestation-unreadable"])
            XCTAssertTrue(result.issues.allSatisfy { $0.target == nil })
            XCTAssertTrue(result.issues.allSatisfy { $0.action == nil })
            XCTAssertTrue(result.issues.allSatisfy { $0.requestID == nil })
            XCTAssertEqual(receipt.attestationEvidence.level, .unreadable)
            XCTAssertFalse(receipt.isConverged)
            XCTAssertLessThan(receipt.progressFraction, 1)
        }
    }

    func testConflictingOutboxAndChannelACKForSameRequestFailsClosed() throws {
        try withTemporaryDirectory { root in
            let requestID = "request-cross-source-conflict"
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: requestID,
                authorityEpoch: 9,
                ledgerSequence: 42,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let channelACK = fixture.channelRoot
                .appendingPathComponent("acks", isDirectory: true)
                .appendingPathComponent("\(requestID).json")
            let channelData = try Data(contentsOf: channelACK)
            guard var object = try JSONSerialization.jsonObject(
                with: channelData
            ) as? [String: Any] else {
                return XCTFail("channel ACK must be a JSON object")
            }
            object["message"] = "conflicting outbox copy"
            let outboxDirectory = root
                .appendingPathComponent(
                    "device-sync-outbox",
                    isDirectory: true
                )
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outboxDirectory,
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ).write(
                to: outboxDirectory.appendingPathComponent("\(requestID).json")
            )

            let result = try DeviceSyncOutboxStore(
                rootURL: root
            ).receiptLoadResult()

            XCTAssertTrue(result.isFailClosed)
            XCTAssertEqual(
                result.issues.map(\.kind),
                ["receipt-conflict", "attestation-unreadable"]
            )
        }
    }

    func testUnsafeChannelACKDirectoryFailsClosedWithoutHidingLocalReceipt() throws {
        try withTemporaryDirectory { root in
            let outboxDirectory = root
                .appendingPathComponent(
                    "device-sync-outbox",
                    isDirectory: true
                )
                .appendingPathComponent("receipts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outboxDirectory,
                withIntermediateDirectories: true
            )
            let localReceipt = DeviceSyncReceipt(
                target: "macbook-m3",
                action: "version-pull",
                requestedAt: Date(timeIntervalSince1970: 1),
                result: "success",
                completedAt: Date(timeIntervalSince1970: 2),
                message: "legacy local publication"
            )
            try DeviceSyncOutboxJSON.encoder.encode(localReceipt).write(
                to: outboxDirectory.appendingPathComponent("legacy.json")
            )

            let channelRoot = root.appendingPathComponent(
                "device-sync-channel",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: channelRoot,
                withIntermediateDirectories: true
            )
            let redirectedACKs = root.appendingPathComponent(
                "redirected-acks",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: redirectedACKs,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: channelRoot.appendingPathComponent(
                    "acks",
                    isDirectory: true
                ),
                withDestinationURL: redirectedACKs
            )

            let result = try DeviceSyncOutboxStore(
                rootURL: root
            ).receiptLoadResult()

            XCTAssertEqual(result.receipts, [localReceipt])
            XCTAssertEqual(
                result.issues.map(\.kind),
                ["channel-ack-root-unreadable"]
            )
        }
    }

    func testTamperedChannelACKSignatureFailsClosed() throws {
        try withTemporaryDirectory { root in
            let requestID = "request-tampered-channel-ack"
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: requestID,
                authorityEpoch: 9,
                ledgerSequence: 43,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let channelACK = fixture.channelRoot
                .appendingPathComponent("acks", isDirectory: true)
                .appendingPathComponent("\(requestID).json")
            let channelData = try Data(contentsOf: channelACK)
            guard var object = try JSONSerialization.jsonObject(
                with: channelData
            ) as? [String: Any] else {
                return XCTFail("channel ACK must be a JSON object")
            }
            object["target"] = "forged-victim-device"
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ).write(to: channelACK)

            let result = try DeviceSyncOutboxStore(
                rootURL: root
            ).receiptLoadResult()
            let receipt = try XCTUnwrap(result.receipts.first)

            XCTAssertEqual(
                result.issues.map(\.kind),
                ["channel-ack-unreadable"]
            )
            XCTAssertEqual(receipt.target, "forged-victim-device")
            XCTAssertTrue(result.issues.allSatisfy { $0.scope == .global })
            XCTAssertTrue(result.issues.allSatisfy { $0.target == nil })
            XCTAssertTrue(result.issues.allSatisfy { $0.action == nil })
            XCTAssertTrue(result.issues.allSatisfy { $0.requestID == nil })
            XCTAssertEqual(receipt.attestationEvidence.level, .unreadable)
            XCTAssertFalse(receipt.isConverged)
        }
    }

    func testDeliveredReceiptIsNotReportedAsSuccessfulConvergence() {
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "both",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "pending",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "request delivered",
            phase: .delivered,
            requestID: "request-1"
        )

        XCTAssertFalse(receipt.isConverged)
        XCTAssertEqual(receipt.progressFraction, 2.0 / 8.0, accuracy: 0.001)
        XCTAssertEqual(receipt.statusLabel, "已送達，等待設備接收")
    }

    func testFailedItemProgressNeverDisplaysOneHundredPercent() {
        let item = DeviceSyncItemReceipt(
            id: "os.issue",
            displayName: "issue.md",
            phase: .failed,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "a", count: 64),
            appliedDigest: nil,
            message: "activation failed",
            progress: DeviceSyncProgressPayload(percent: 100)
        )

        XCTAssertEqual(item.progressValue.provenance, .artifact)
        XCTAssertEqual(
            item.progressValue.fraction,
            DeviceSyncReceiptPhase.failed.progressFraction
        )
        XCTAssertNotEqual(item.progressValue.percentLabel, "100%")
    }

    func testMeasuredByteProgressTakesPriorityOverOpaquePercent() {
        let payload = DeviceSyncProgressPayload(
            completedUnits: 9,
            totalUnits: 10,
            percent: 95,
            completedBytes: 512,
            totalBytes: 2_048,
            completedItems: 1,
            totalItems: 4,
            completedRepositories: 2,
            totalRepositories: 5,
            elapsedMilliseconds: 2_000,
            throughputBytesPerSecond: 256,
            currentItem: "issue.md"
        )

        let progress = DeviceSyncProgressValue.make(
            payload: payload,
            fallbackPhase: .transferring
        )

        XCTAssertEqual(progress.provenance, .artifact)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.001)
        XCTAssertTrue(payload.hasMeasuredProgress)
    }

    func testReceiptProgressUsesMeasuredProducerPayload() {
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "version-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "partial",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "transferring",
            phase: .transferring,
            requestID: "request-measured-progress",
            authorityEpoch: 3,
            ledgerSequence: 9,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: "version-catalog",
            digestAlgorithm: "git-object-id",
            sourceDigest: String(repeating: "a", count: 40),
            appliedDigest: nil,
            requiredItemIDs: ["app.version"],
            items: [],
            progress: DeviceSyncProgressPayload(
                completedBytes: 1_024,
                totalBytes: 4_096,
                completedItems: 0,
                totalItems: 1,
                elapsedMilliseconds: 4_000,
                throughputBytesPerSecond: 256,
                currentItem: "Tatwo source version"
            )
        )

        XCTAssertEqual(receipt.progressValue.provenance, .artifact)
        XCTAssertEqual(receipt.progressFraction, 0.25, accuracy: 0.001)
    }

    func testConvergedReceiptRequiresVerifiedItemsWithMatchingDigests() {
        let requestID = "request-2"
        let catalogRevision = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "all items verified",
            phase: .converged,
            requestID: requestID,
            authorityEpoch: 3,
            ledgerSequence: 8,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            sourceMode: DeviceSyncSourceProvenanceValidator.canonical,
            inventoryDigest: String(repeating: "7", count: 64),
            fallbackAuthorizationID: "",
            fallbackAuthorizationPath: "",
            fallbackAuthorizationDigest: "",
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "f", count: 64),
            appliedDigest: String(repeating: "f", count: 64),
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: [
                verifiedItem("os.constitution", displayName: "os.md", digest: "a"),
                verifiedItem("os.issue", displayName: "issue.md", digest: "b"),
                verifiedItem("os.todo", displayName: "TODO.md", digest: "c"),
                verifiedSkilletItem(
                    requestID: requestID,
                    authorityEpoch: 3,
                    ledgerSequence: 8,
                    sourceDeviceID: "mini-id",
                    targetDeviceID: "book-id",
                    catalogRevision: catalogRevision
                )
            ]
        )

        XCTAssertTrue(receipt.isChannelClaimed)
        XCTAssertFalse(receipt.isConverged)
        XCTAssertEqual(receipt.progressFraction, 0.94)
        XCTAssertEqual(
            receipt.statusLabel,
            "channel-claimed · 等待 actual consumer readback / target attestation"
        )
    }

    func testConvergedReceiptRejectsNonHexDigestWithValidLength() {
        let malformed = String(repeating: "a", count: 56) + "zzzzzzzz"
        let catalogRevision = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "forged",
            phase: .converged,
            requestID: "request-3",
            authorityEpoch: 3,
            ledgerSequence: 9,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            sourceMode: DeviceSyncSourceProvenanceValidator.canonical,
            inventoryDigest: String(repeating: "7", count: 64),
            fallbackAuthorizationID: "",
            fallbackAuthorizationPath: "",
            fallbackAuthorizationDigest: "",
            digestAlgorithm: "sha256",
            sourceDigest: malformed,
            appliedDigest: malformed,
            requiredItemIDs: ["os.issue"],
            items: [
                .init(
                    id: "os.issue",
                    displayName: "issue.md",
                    phase: .verified,
                    digestAlgorithm: "sha256",
                    sourceDigest: malformed,
                    appliedDigest: malformed,
                    message: "forged"
                )
            ]
        )

        XCTAssertFalse(receipt.isConverged)
        XCTAssertEqual(receipt.statusLabel, "缺少項目驗證")
    }

    func testConvergedSystemReceiptRejectsRequiredItemSubsetAndMissingAuthorityBinding() {
        let digest = String(repeating: "a", count: 64)
        let item = DeviceSyncItemReceipt(
            id: "os.issue",
            displayName: "issue.md",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: digest,
            appliedDigest: digest,
            message: "forged subset"
        )
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "forged subset",
            phase: .converged,
            requestID: "request-4",
            authorityEpoch: nil,
            authorityPrimary: nil,
            sourceDeviceID: nil,
            targetDeviceID: nil,
            catalogRevision: nil,
            digestAlgorithm: "sha256",
            sourceDigest: digest,
            appliedDigest: digest,
            requiredItemIDs: ["os.issue"],
            items: [item]
        )

        XCTAssertEqual(
            receipt.effectiveRequiredItemIDs,
            ["os.constitution", "os.issue", "os.todo", "skills.skillet"]
        )
        XCTAssertFalse(receipt.isConverged)
    }

    func testConvergedReceiptMissingAuthorityBindingNeverDisplaysHundredPercent() throws {
        let receipt = makeChannelClaimedSystemReceipt(
            requestID: "request-missing-authority-progress",
            authorityEpoch: 3,
            ledgerSequence: 91,
            progress: DeviceSyncProgressPayload(percent: 100)
        )
        let encoded = try DeviceSyncOutboxJSON.encoder.encode(receipt)
        guard var object = try JSONSerialization.jsonObject(
            with: encoded
        ) as? [String: Any] else {
            return XCTFail("receipt must encode as a JSON object")
        }
        for key in [
            "authorityEpoch",
            "ledgerSequence",
            "authorityPrimary",
            "sourceDeviceID",
            "targetDeviceID",
            "catalogRevision",
        ] {
            object.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let decoded = try DeviceSyncOutboxJSON.decoder.decode(
            DeviceSyncReceipt.self,
            from: stripped
        )

        XCTAssertFalse(decoded.isChannelClaimed)
        XCTAssertFalse(decoded.isConverged)
        XCTAssertEqual(
            decoded.progressFraction,
            DeviceSyncReceiptPhase.verified.progressFraction,
            accuracy: 0.001
        )
        XCTAssertNotEqual(decoded.progressValue.percentLabel, "100%")
    }

    func testConvergedReceiptRejectsDuplicateOrExtraItems() {
        let aggregate = String(repeating: "f", count: 64)
        let catalogRevision = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
        func item(_ id: String, digest: Character) -> DeviceSyncItemReceipt {
            let value = String(repeating: String(digest), count: 64)
            return DeviceSyncItemReceipt(
                id: id,
                displayName: id,
                phase: .verified,
                digestAlgorithm: "sha256",
                sourceDigest: value,
                appliedDigest: value,
                message: "verified"
            )
        }
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "forged duplicate",
            phase: .converged,
            requestID: "request-5",
            authorityEpoch: 3,
            ledgerSequence: 9,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            digestAlgorithm: "sha256",
            sourceDigest: aggregate,
            appliedDigest: aggregate,
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: [
                item("os.constitution", digest: "a"),
                item("os.issue", digest: "b"),
                item("os.todo", digest: "c"),
                item("os.todo", digest: "c")
            ]
        )

        XCTAssertFalse(receipt.isConverged)
    }

    func testConvergedReceiptRejectsCatalogRevisionThatAppDoesNotShip() {
        let requestID = "request-stale-catalog"
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "target used another catalog",
            phase: .converged,
            requestID: requestID,
            authorityEpoch: 3,
            ledgerSequence: 10,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: "future-catalog",
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "f", count: 64),
            appliedDigest: String(repeating: "f", count: 64),
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: [
                verifiedItem("os.constitution", displayName: "os.md", digest: "a"),
                verifiedItem("os.issue", displayName: "issue.md", digest: "b"),
                verifiedItem("os.todo", displayName: "TODO.md", digest: "c"),
                verifiedSkilletItem(
                    requestID: requestID,
                    authorityEpoch: 3,
                    ledgerSequence: 10,
                    sourceDeviceID: "mini-id",
                    targetDeviceID: "book-id",
                    catalogRevision: "future-catalog"
                )
            ]
        )

        XCTAssertFalse(receipt.isCatalogCompatible)
        XCTAssertFalse(receipt.isConverged)
        XCTAssertEqual(receipt.statusLabel, "同步 catalog 不相容")
    }

    func testConvergedReceiptRejectsSkilletRepositoryBindingMismatch() {
        let requestID = "request-skillet-forged"
        let catalogRevision = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
        var skillet = verifiedSkilletItem(
            requestID: requestID,
            authorityEpoch: 3,
            ledgerSequence: 11,
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision
        )
        let forgedRepository = DeviceSyncSkilletRepositoryReceipt(
            repositoryID: "alpha-skill",
            revisionID: "rev-\(String(repeating: "d", count: 64))",
            contentDigest: String(repeating: "d", count: 64),
            bundleDigest: String(repeating: "e", count: 64),
            requestID: "another-request",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            authorityEpoch: 3,
            ledgerSequence: 11,
            catalogRevision: catalogRevision,
            phase: .verified
        )
        skillet = DeviceSyncItemReceipt(
            id: skillet.id,
            displayName: skillet.displayName,
            phase: skillet.phase,
            digestAlgorithm: skillet.digestAlgorithm,
            sourceDigest: skillet.sourceDigest,
            appliedDigest: skillet.appliedDigest,
            message: skillet.message,
            repositoryCount: 1,
            repositories: [forgedRepository]
        )
        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "forged nested binding",
            phase: .converged,
            requestID: requestID,
            authorityEpoch: 3,
            ledgerSequence: 11,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "f", count: 64),
            appliedDigest: String(repeating: "f", count: 64),
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: [
                verifiedItem("os.constitution", displayName: "os.md", digest: "a"),
                verifiedItem("os.issue", displayName: "issue.md", digest: "b"),
                verifiedItem("os.todo", displayName: "TODO.md", digest: "c"),
                skillet
            ]
        )

        XCTAssertFalse(receipt.isConverged)
    }

    func testCatalogParsesEnrolledDevicesAndFiltersSecondaryRole() throws {
        try withTemporaryDirectory { root in
            let devices = root
                .appendingPathComponent("device-sync-channel", isDirectory: true)
                .appendingPathComponent("devices", isDirectory: true)
            try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)

            let primary = EnrolledDevice(
                name: "mac-mini",
                role: "primary",
                enrolledAt: Date(timeIntervalSince1970: 1_751_000_000)
            )
            let secondary = EnrolledDevice(
                name: "macbook-m3",
                role: "secondary",
                enrolledAt: Date(timeIntervalSince1970: 1_751_000_100)
            )
            try DeviceSyncOutboxJSON.encoder.encode(primary)
                .write(to: devices.appendingPathComponent("mac-mini.json"))
            try DeviceSyncOutboxJSON.encoder.encode(secondary)
                .write(to: devices.appendingPathComponent("macbook-m3.json"))
            try Data("{ malformed".utf8).write(to: devices.appendingPathComponent("broken.json"))

            let store = DeviceSyncOutboxStore(rootURL: root)

            XCTAssertEqual(try store.enrolledDevices(), [primary, secondary])
            XCTAssertEqual(try store.secondaryDevices(), [secondary])
        }
    }

    func testOperationIndexKeepsDifferentActionsForSameTargetAndShowsNewPendingWork() {
        let oldSystemReceipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 10),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 20),
            message: "old system receipt",
            phase: .converged,
            requestID: "system-old"
        )
        let versionReceipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "version-pull",
            requestedAt: Date(timeIntervalSince1970: 21),
            result: "pending",
            completedAt: Date(timeIntervalSince1970: 25),
            message: "version delivered",
            phase: .delivered,
            requestID: "version-current"
        )
        let newerSystemIntent = DeviceSyncIntent(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 30)
        )

        let pending = DeviceSyncOperationIndex.latestPending([newerSystemIntent])
        let receipts = DeviceSyncOperationIndex.latestReceipts([
            oldSystemReceipt,
            versionReceipt
        ])
        let keys = DeviceSyncOperationIndex.operationKeys(
            for: "macbook-m3",
            pending: pending,
            receipts: receipts
        )

        XCTAssertEqual(
            Set(keys),
            Set([
                DeviceSyncOperationKey(target: "macbook-m3", action: "system-pull"),
                DeviceSyncOperationKey(target: "macbook-m3", action: "version-pull")
            ])
        )
        XCTAssertEqual(keys.first?.action, "system-pull")
        XCTAssertEqual(
            DeviceSyncOperationIndex.presentationReceipt(
                for: DeviceSyncOperationKey(
                    target: "macbook-m3",
                    action: "system-pull"
                ),
                pending: pending,
                receipts: receipts
            )?.effectivePhase,
            .queued
        )
        XCTAssertEqual(
            DeviceSyncOperationIndex.presentationReceipt(
                for: DeviceSyncOperationKey(
                    target: "macbook-m3",
                    action: "version-pull"
                ),
                pending: pending,
                receipts: receipts
            )?.requestID,
            "version-current"
        )
    }

    func testOperationIndexKeepsNewestReceiptPerTargetAndAction() {
        let older = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "failed",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "older",
            phase: .failed,
            requestID: "request-old",
            authorityEpoch: 4,
            ledgerSequence: 8
        )
        let newer = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 3),
            result: "pending",
            completedAt: Date(timeIntervalSince1970: 4),
            message: "newer",
            phase: .delivered,
            requestID: "request-new",
            authorityEpoch: 4,
            ledgerSequence: 9
        )

        let indexed = DeviceSyncOperationIndex.latestReceipts([older, newer])
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed[older.operationKey]?.requestID, "request-new")
    }

    func testOperationOrderingUsesPendingThenAuthorityTupleNotWallClock() {
        let authoritative = makeOrderingReceipt(
            action: "system-pull",
            requestID: "request-a",
            authorityEpoch: 8,
            ledgerSequence: 12,
            requestedAt: 1,
            completedAt: 2
        )
        let futureClockStaleAuthority = makeOrderingReceipt(
            action: "version-pull",
            requestID: "request-z",
            authorityEpoch: 7,
            ledgerSequence: 999,
            requestedAt: 9_000,
            completedAt: 9_999
        )
        let receipts = DeviceSyncOperationIndex.latestReceipts([
            futureClockStaleAuthority,
            authoritative
        ])

        let authorityOrdered = DeviceSyncOperationIndex.operationKeys(
            for: "macbook-m3",
            pending: [:],
            receipts: receipts
        )
        let pendingVersion = DeviceSyncIntent(
            target: "macbook-m3",
            action: "version-pull",
            requestedAt: Date(timeIntervalSince1970: -9_000)
        )
        let pendingOrdered = DeviceSyncOperationIndex.operationKeys(
            for: "macbook-m3",
            pending: DeviceSyncOperationIndex.latestPending([pendingVersion]),
            receipts: receipts
        )

        XCTAssertEqual(authorityOrdered.map(\.action), ["system-pull", "version-pull"])
        XCTAssertEqual(pendingOrdered.first?.action, "version-pull")
    }

    func testNewPendingIntentImmediatelyOverridesOldConvergedWithoutWallClockComparison() {
        let key = DeviceSyncOperationKey(target: "macbook-m3", action: "system-pull")
        let oldConverged = makeChannelClaimedSystemReceipt(
            requestID: "request-old",
            authorityEpoch: 9,
            ledgerSequence: 99,
            requestedAt: Date(timeIntervalSince1970: 500),
            completedAt: Date(timeIntervalSince1970: 900)
        )
        let newlyWrittenIntentWithSkewedClock = DeviceSyncIntent(
            target: key.target,
            action: key.action,
            requestedAt: Date(timeIntervalSince1970: 100)
        )

        let presentation = DeviceSyncOperationIndex.presentationReceipt(
            for: key,
            pending: DeviceSyncOperationIndex.latestPending([
                newlyWrittenIntentWithSkewedClock
            ]),
            receipts: DeviceSyncOperationIndex.latestReceipts([oldConverged])
        )

        XCTAssertEqual(presentation?.effectivePhase, .queued)
        XCTAssertNil(presentation?.requestID)
        XCTAssertFalse(presentation?.isConverged == true)
    }

    func testTargetNamesIncludeReceiptTargetWithoutEnrollmentRow() {
        let receipt = DeviceSyncReceipt(
            target: "Mac-mini-fangjian",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "self-target production verification",
            phase: .converged,
            requestID: "request-self-target"
        )

        let targets = DeviceSyncOperationIndex.targetNames(
            pending: [:],
            receipts: DeviceSyncOperationIndex.latestReceipts([receipt])
        )

        XCTAssertEqual(targets, ["Mac-mini-fangjian"])
    }

    func testSourceRefreshAttemptLoaderProjectsEveryRequiredFailureKind() throws {
        try withTemporaryDirectory { root in
            let store = DeviceSyncOutboxStore(rootURL: root)
            let receiptRoot = root
                .appendingPathComponent("device-sync-state", isDirectory: true)
                .appendingPathComponent("skillet-export-receipts", isDirectory: true)
            let fixtures: [(String, String, String, String)] = [
                (
                    "attempt-missing-alias",
                    "刺青網頁",
                    "",
                    "missing governed portable repository alias"
                ),
                (
                    "attempt-source-unavailable",
                    "canonical-root",
                    "canonical-root",
                    "canonical source root unavailable"
                ),
                (
                    "attempt-prohibited-content",
                    "alpha-skill",
                    "alpha-skill",
                    "prohibited secret-bearing path"
                ),
                (
                    "attempt-one-failed-source",
                    "beta-skill",
                    "beta-skill",
                    "one source failed while valid sources remained staged"
                ),
            ]

            for (offset, fixture) in fixtures.enumerated() {
                let attempt = makeSourceRefreshAttempt(
                    attemptID: fixture.0,
                    ledgerSequence: 20 + offset,
                    results: [
                        DeviceSyncSourceRefreshResult(
                            sourceName: fixture.1,
                            repositoryID: fixture.2,
                            displayName: fixture.1,
                            status: "failed",
                            message: fixture.3,
                            revisionID: nil,
                            contentDigest: nil
                        )
                    ]
                )
                let directory = receiptRoot
                    .appendingPathComponent(attempt.attemptID, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try DeviceSyncOutboxJSON.encoder.encode(attempt).write(
                    to: directory.appendingPathComponent("canonical-refresh.json")
                )
            }

            let loaded = try store.sourceRefreshAttemptLoadResult()

            XCTAssertFalse(loaded.isFailClosed)
            XCTAssertEqual(loaded.attempts.count, fixtures.count)
            XCTAssertEqual(
                Set(loaded.attempts.map(\.attemptID)),
                Set(fixtures.map(\.0))
            )
            for attempt in loaded.attempts {
                let receipt = attempt.presentationReceipt
                XCTAssertNil(receipt.requestID)
                XCTAssertEqual(receipt.sourceRefreshAttemptID, attempt.attemptID)
                XCTAssertEqual(receipt.effectivePhase, .failed)
                XCTAssertFalse(receipt.isConverged)
                XCTAssertEqual(receipt.items?.count, 1)
                XCTAssertEqual(receipt.items?.first?.phase, .failed)
                XCTAssertEqual(
                    receipt.attestationEvidence.provenance,
                    DeviceSyncSourceRefreshAttempt.evidenceKind
                )
            }
        }
    }

    func testSourceRefreshAttemptLoaderFailsClosedOnActivationClaimAndPrivatePath() throws {
        try withTemporaryDirectory { root in
            let store = DeviceSyncOutboxStore(rootURL: root)
            let receiptRoot = root
                .appendingPathComponent("device-sync-state", isDirectory: true)
                .appendingPathComponent("skillet-export-receipts", isDirectory: true)
            let fixtures = [
                makeSourceRefreshAttempt(
                    attemptID: "attempt-activation-claim",
                    ledgerSequence: 30,
                    storeMutation: "activated-live-store",
                    results: [
                        DeviceSyncSourceRefreshResult(
                            sourceName: "alpha",
                            repositoryID: "alpha",
                            displayName: "alpha",
                            status: "failed",
                            message: "failed safely",
                            revisionID: nil,
                            contentDigest: nil
                        )
                    ]
                ),
                makeSourceRefreshAttempt(
                    attemptID: "attempt-private-path",
                    ledgerSequence: 31,
                    message: "failed at /Users/private/skills/alpha",
                    results: [
                        DeviceSyncSourceRefreshResult(
                            sourceName: "alpha",
                            repositoryID: "alpha",
                            displayName: "alpha",
                            status: "failed",
                            message: "private path redaction failed",
                            revisionID: nil,
                            contentDigest: nil
                        )
                    ]
                ),
            ]
            for attempt in fixtures {
                let directory = receiptRoot
                    .appendingPathComponent(attempt.attemptID, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try DeviceSyncOutboxJSON.encoder.encode(attempt).write(
                    to: directory.appendingPathComponent("canonical-refresh.json")
                )
            }

            let loaded = try store.sourceRefreshAttemptLoadResult()

            XCTAssertTrue(loaded.isFailClosed)
            XCTAssertTrue(loaded.attempts.isEmpty)
            XCTAssertEqual(loaded.issues.count, 2)
            XCTAssertTrue(
                loaded.issues.allSatisfy {
                    $0.kind == "source-refresh-attempt-unreadable"
                }
            )
            XCTAssertTrue(loaded.issues.allSatisfy { $0.requestID == nil })
            XCTAssertTrue(loaded.issues.allSatisfy { $0.target == nil })
            XCTAssertTrue(loaded.issues.allSatisfy { $0.action == nil })
        }
    }

    func testSourceRefreshAttemptOrderingUsesExactBindingAndPendingStillWins() {
        let key = DeviceSyncOperationKey(target: "macbook-m3", action: "system-pull")
        let attempt = makeSourceRefreshAttempt(
            attemptID: "attempt-exact-binding",
            ledgerSequence: 42,
            results: [
                DeviceSyncSourceRefreshResult(
                    sourceName: "broken-skill",
                    repositoryID: "broken-skill",
                    displayName: "Broken Skill",
                    status: "failed",
                    message: "source refresh failed",
                    revisionID: nil,
                    contentDigest: nil
                )
            ]
        )
        let helperFailure = DeviceSyncReceipt(
            target: key.target,
            action: key.action,
            requestedAt: attempt.requestedAt,
            result: "failure",
            completedAt: attempt.completedAt,
            message: "sync-request failed before publication",
            phase: .failed,
            requestID: nil,
            sourceRefreshAttemptID: attempt.attemptID,
            authorityEpoch: attempt.authorityEpoch,
            ledgerSequence: attempt.ledgerSequence
        )
        let oldConverged = DeviceSyncReceipt(
            target: key.target,
            action: key.action,
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "old convergence",
            phase: .converged,
            requestID: "old-request",
            authorityEpoch: attempt.authorityEpoch,
            ledgerSequence: attempt.ledgerSequence - 1
        )
        let attempts = DeviceSyncOperationIndex.latestSourceRefreshAttempts([attempt])

        let exactFailureProjection = DeviceSyncOperationIndex.presentationReceipt(
            for: key,
            pending: [:],
            receipts: DeviceSyncOperationIndex.latestReceipts([
                oldConverged,
                helperFailure,
            ]),
            sourceRefreshAttempts: attempts
        )
        XCTAssertEqual(
            exactFailureProjection?.sourceRefreshAttemptID,
            attempt.attemptID
        )
        XCTAssertEqual(exactFailureProjection?.items?.first?.phase, .failed)

        let pending = DeviceSyncIntent(
            target: key.target,
            action: key.action,
            requestedAt: Date(timeIntervalSince1970: -10_000)
        )
        let pendingProjection = DeviceSyncOperationIndex.presentationReceipt(
            for: key,
            pending: DeviceSyncOperationIndex.latestPending([pending]),
            receipts: DeviceSyncOperationIndex.latestReceipts([helperFailure]),
            sourceRefreshAttempts: attempts
        )
        XCTAssertEqual(pendingProjection?.effectivePhase, .queued)
        XCTAssertNil(pendingProjection?.sourceRefreshAttemptID)
    }

    func testNewerNonFailedSourceRefreshAttemptOverridesOlderReceipt() {
        let key = DeviceSyncOperationKey(target: "macbook-m3", action: "system-pull")
        let oldConverged = DeviceSyncReceipt(
            target: key.target,
            action: key.action,
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "old convergence",
            phase: .converged,
            requestID: "old-request",
            authorityEpoch: 8,
            ledgerSequence: 41
        )

        for outcome in [
            DeviceSyncSourceRefreshOutcome.started,
            .converged,
        ] {
            let attempt = makeSourceRefreshAttempt(
                attemptID: "attempt-\(outcome.rawValue)",
                ledgerSequence: 42,
                outcome: outcome,
                storeMutation: "staged-not-activated",
                message: "new local source refresh",
                results: []
            )
            let presentation = DeviceSyncOperationIndex.presentationReceipt(
                for: key,
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([oldConverged]),
                sourceRefreshAttempts:
                    DeviceSyncOperationIndex.latestSourceRefreshAttempts([attempt])
            )

            XCTAssertEqual(
                presentation?.sourceRefreshAttemptID,
                attempt.attemptID,
                "\(outcome.rawValue) attempt must invalidate an older ACK"
            )
            XCTAssertNil(presentation?.requestID)
            XCTAssertEqual(presentation?.effectivePhase, .validating)
        }
    }

    func testAllOperationKeysIncludesSourceRefreshOnlyOperation() {
        let attempt = makeSourceRefreshAttempt(
            attemptID: "attempt-source-refresh-only",
            ledgerSequence: 42,
            outcome: .started,
            results: []
        )
        let attempts = DeviceSyncOperationIndex.latestSourceRefreshAttempts([attempt])

        let keys = DeviceSyncOperationIndex.allOperationKeys(
            pending: [:],
            receipts: [:],
            sourceRefreshAttempts: attempts
        )

        XCTAssertEqual(keys, Set([attempt.operationKey]))
    }

    func testReceiptOrderingUsesAuthorityEpochBeforeLedgerRequestAndWallClock() {
        let higherEpoch = makeOrderingReceipt(
            requestID: "request-a",
            authorityEpoch: 8,
            ledgerSequence: 1,
            requestedAt: 10,
            completedAt: 10
        )
        let futureClockLowerEpoch = makeOrderingReceipt(
            requestID: "request-z",
            authorityEpoch: 7,
            ledgerSequence: 999,
            requestedAt: 9_000,
            completedAt: 9_999
        )

        let indexed = DeviceSyncOperationIndex.latestReceipts([
            futureClockLowerEpoch,
            higherEpoch
        ])

        XCTAssertEqual(indexed[higherEpoch.operationKey]?.requestID, "request-a")
    }

    func testReceiptOrderingUsesLedgerSequenceBeforeRequestIDAndWallClock() {
        let higherSequence = makeOrderingReceipt(
            requestID: "request-a",
            authorityEpoch: 8,
            ledgerSequence: 12,
            requestedAt: 10,
            completedAt: 10
        )
        let futureClockLowerSequence = makeOrderingReceipt(
            requestID: "request-z",
            authorityEpoch: 8,
            ledgerSequence: 11,
            requestedAt: 9_000,
            completedAt: 9_999
        )

        let indexed = DeviceSyncOperationIndex.latestReceipts([
            futureClockLowerSequence,
            higherSequence
        ])

        XCTAssertEqual(indexed[higherSequence.operationKey]?.requestID, "request-a")
    }

    func testReceiptOrderingUsesRequestIDWhenAuthorityEpochAndSequenceMatch() {
        let lowerRequestWithFutureClock = makeOrderingReceipt(
            requestID: "request-a",
            authorityEpoch: 8,
            ledgerSequence: 12,
            requestedAt: 9_000,
            completedAt: 9_999
        )
        let higherRequestWithPastClock = makeOrderingReceipt(
            requestID: "request-b",
            authorityEpoch: 8,
            ledgerSequence: 12,
            requestedAt: 10,
            completedAt: 10
        )

        let indexed = DeviceSyncOperationIndex.latestReceipts([
            lowerRequestWithFutureClock,
            higherRequestWithPastClock
        ])

        XCTAssertEqual(
            indexed[higherRequestWithPastClock.operationKey]?.requestID,
            "request-b"
        )
    }

    func testIdenticalAuthorityBindingDoesNotUseWallClockAsLatestEvidence() {
        let first = makeOrderingReceipt(
            requestID: "request-same",
            authorityEpoch: 8,
            ledgerSequence: 12,
            requestedAt: 9_000,
            completedAt: 9_999,
            message: "first artifact"
        )
        let second = makeOrderingReceipt(
            requestID: "request-same",
            authorityEpoch: 8,
            ledgerSequence: 12,
            requestedAt: 1,
            completedAt: 2,
            message: "second artifact"
        )

        XCTAssertFalse(DeviceSyncOperationIndex.isLater(first, than: second))
        XCTAssertFalse(DeviceSyncOperationIndex.isLater(second, than: first))
    }

    func testSystemPullWithoutAttestationRemainsChannelClaimedAndNeverGreen() {
        let receipt = makeChannelClaimedSystemReceipt(
            requestID: "request-no-attestation",
            authorityEpoch: 5,
            ledgerSequence: 20
        )
        let verifier = DeviceSyncTargetAttestationVerifier(
            channelRootURL: URL(fileURLWithPath: "/definitely-not-used")
        )

        let evidence = verifier.verify(receipt: receipt)
        let projected = receipt.withAttestationEvidence(evidence)

        XCTAssertEqual(evidence.level, .channelClaimed)
        XCTAssertTrue(projected.isChannelClaimed)
        XCTAssertFalse(projected.isConverged)
        XCTAssertEqual(projected.progressFraction, 0.94)
    }

    func testLegacyPartialSkilletACKRepositoryShapesRemainReadableAndNonConverged() throws {
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        let bundleA = String(repeating: "c", count: 64)
        let bundleB = String(repeating: "d", count: 64)
        let data = Data(
            """
            {
              "target": "macbook-m3",
              "action": "system-pull",
              "requestedAt": "2026-07-27T02:11:55Z",
              "result": "partial",
              "completedAt": "2026-07-27T02:45:12Z",
              "message": "merge proposals preserved",
              "phase": "merging",
              "requestID": "request-legacy-merge",
              "authorityEpoch": 1,
              "ledgerSequence": 9,
              "authorityPrimary": "mac-mini",
              "sourceDeviceID": "mini-id",
              "targetDeviceID": "book-id",
              "catalogRevision": "\(try XCTUnwrap(DeviceSyncCatalogProjection.currentRevision))",
              "requiredItemIDs": ["skills.skillet"],
              "items": [{
                "id": "skills.skillet",
                "displayName": "Skillet private repositories",
                "phase": "merging",
                "sourceDigest": "\(digestA)",
                "appliedDigest": "",
                "message": "waiting for merge decision",
                "repositoryCount": 2,
                "repositories": [{
                  "repositoryID": "proposal-skill",
                  "proposedRevisionID": "rev-\(digestA)",
                  "contentDigest": "\(digestA)",
                  "bundleDigest": "\(bundleA)",
                  "status": "pending",
                  "phase": "merging"
                }, {
                  "repositoryID": "preserved-skill",
                  "revisionID": "rev-\(digestB)",
                  "contentDigest": "\(digestB)",
                  "bundleDigest": "\(bundleB)",
                  "status": "branch-preserved",
                  "phase": "merging"
                }]
              }]
            }
            """.utf8
        )

        let receipt = try DeviceSyncOutboxJSON.decoder.decode(
            DeviceSyncReceipt.self,
            from: data
        )

        XCTAssertEqual(receipt.effectivePhase, .merging)
        XCTAssertEqual(receipt.items?.last?.repositories?.count, 2)
        XCTAssertFalse(receipt.isChannelClaimed)
        XCTAssertFalse(receipt.isConverged)
    }

    func testTargetPreservedRepositoryFieldsSurviveReceiptRoundTrip() throws {
        let contentDigest = String(repeating: "a", count: 64)
        let data = Data(
            """
            {
              "id": "skills.skillet",
              "displayName": "Skillet private repositories",
              "phase": "verified",
              "digestAlgorithm": "sha256",
              "sourceDigest": "\(String(repeating: "b", count: 64))",
              "appliedDigest": "\(String(repeating: "b", count: 64))",
              "message": "verified",
              "repositoryCount": 0,
              "repositories": [],
              "targetPreservedCount": 1,
              "targetPreservedRepositories": [{
                "repositoryID": "target-only-skill",
                "revisionID": "rev-\(contentDigest)",
                "contentDigest": "\(contentDigest)",
                "state": "runtime-preserved",
                "phase": "preserved"
              }],
              "targetPreservedRuntimeClosureCapability":
                "target-preserved-runtime-closure-v1",
              "targetPreservedRuntimeClosed": true
            }
            """.utf8
        )
        let item = try DeviceSyncOutboxJSON.decoder.decode(
            DeviceSyncItemReceipt.self,
            from: data
        )
        let encoded = try DeviceSyncOutboxJSON.encoder.encode(item)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["targetPreservedCount"] as? Int, 1)
        XCTAssertEqual(
            object["targetPreservedRuntimeClosureCapability"] as? String,
            "target-preserved-runtime-closure-v1"
        )
        XCTAssertEqual(object["targetPreservedRuntimeClosed"] as? Bool, true)
        let repositories = try XCTUnwrap(
            object["targetPreservedRepositories"] as? [[String: Any]]
        )
        XCTAssertEqual(repositories.first?["repositoryID"] as? String, "target-only-skill")
        XCTAssertEqual(repositories.first?["contentDigest"] as? String, contentDigest)
    }

    func testTargetPreservedRepositoryConsumerReadbacksCanConverge() throws {
        try withTemporaryDirectory { root in
            let preservedDigest = String(repeating: "f", count: 64)
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-target-preserved-readback",
                authorityEpoch: 6,
                ledgerSequence: 234,
                attestedAt: Date(timeIntervalSince1970: 100),
                targetPreservedRepository: (
                    repositoryID: "target-only-skill",
                    contentDigest: preservedDigest
                )
            )

            let evidence = DeviceSyncTargetAttestationVerifier(
                channelRootURL: fixture.channelRoot
            ).verify(receipt: fixture.receipt)
            let projected = fixture.receipt.withAttestationEvidence(evidence)

            XCTAssertEqual(evidence.level, .targetLocallyAttested)
            XCTAssertTrue(projected.isChannelClaimed)
            XCTAssertTrue(projected.isConverged)
            XCTAssertEqual(
                evidence.consumerReadbacks.filter {
                    $0.sourceItemID == "skills.skillet"
                }.count,
                6
            )
        }
    }

    func testNonCanonicalAndUnknownActionsCannotClaimChannelOrConverge() {
        let base = makeChannelClaimedSystemReceipt(
            requestID: "request-invalid-action",
            authorityEpoch: 5,
            ledgerSequence: 201
        )

        for action in ["system-pull ", "future-pull"] {
            let receipt = replacingAction(in: base, action: action)

            XCTAssertFalse(
                receipt.isChannelClaimed,
                "action=\(action.debugDescription) must fail closed before channel claim"
            )
            XCTAssertFalse(
                receipt.isConverged,
                "action=\(action.debugDescription) must never self-certify convergence"
            )
        }
    }

    func testInvalidAttestationPathFailsClosedBeforeArtifactRead() {
        let base = makeChannelClaimedSystemReceipt(
            requestID: "request-invalid-path",
            authorityEpoch: 5,
            ledgerSequence: 21
        )
        let receipt = replacingAttestationBinding(
            in: base,
            kind: DeviceSyncTargetAttestationVerifier.attestationKind,
            path: "../attestations/request-invalid-path.json",
            digest: String(repeating: "a", count: 64)
        )
        let verifier = DeviceSyncTargetAttestationVerifier(
            channelRootURL: URL(fileURLWithPath: "/definitely-not-used")
        )

        let evidence = verifier.verify(receipt: receipt)

        XCTAssertEqual(evidence.level, .unreadable)
        XCTAssertFalse(receipt.withAttestationEvidence(evidence).isConverged)
        XCTAssertTrue(evidence.detail.contains("kind/path/digest"))
    }

    func testAttestationDigestMismatchFailsClosed() throws {
        try withTemporaryDirectory { root in
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-wrong-digest",
                authorityEpoch: 5,
                ledgerSequence: 22,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let receipt = replacingAttestationBinding(
                in: fixture.receipt,
                kind: DeviceSyncTargetAttestationVerifier.attestationKind,
                path: "attestations/macbook-m3/request-wrong-digest.json",
                digest: String(repeating: "f", count: 64)
            )

            let evidence = DeviceSyncTargetAttestationVerifier(
                channelRootURL: fixture.channelRoot
            ).verify(receipt: receipt)

            XCTAssertEqual(evidence.level, .unreadable)
            XCTAssertFalse(receipt.withAttestationEvidence(evidence).isConverged)
            XCTAssertTrue(evidence.detail.contains("digest"))
        }
    }

    func testUnknownAttestationSchemaFailsClosed() throws {
        try withTemporaryDirectory { root in
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-future-schema",
                authorityEpoch: 5,
                ledgerSequence: 23,
                attestedAt: Date(timeIntervalSince1970: 100),
                attestationSchema: "TatwoTargetLocalSystemAttestationV999"
            )

            let evidence = DeviceSyncTargetAttestationVerifier(
                channelRootURL: fixture.channelRoot
            ).verify(receipt: fixture.receipt)

            XCTAssertEqual(evidence.level, .unreadable)
            XCTAssertFalse(
                fixture.receipt.withAttestationEvidence(evidence).isConverged
            )
        }
    }

    func testCatalogSelfLabelCannotReplaceContentBoundLoadedRevision() throws {
        try withTemporaryDirectory { root in
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-self-labeled-revision",
                authorityEpoch: 5,
                ledgerSequence: 231,
                attestedAt: Date(timeIntervalSince1970: 100),
                osLoadedRevisionOverride: try XCTUnwrap(
                    DeviceSyncCatalogProjection.currentRevision
                )
            )

            let evidence = DeviceSyncTargetAttestationVerifier(
                channelRootURL: fixture.channelRoot
            ).verify(receipt: fixture.receipt)

            XCTAssertEqual(evidence.level, .unreadable)
            XCTAssertFalse(
                fixture.receipt.withAttestationEvidence(evidence).isConverged
            )
            XCTAssertTrue(evidence.detail.contains("digest/revision"))
        }
    }

    func testExplicitRuntimeFallbackProvenanceCanBeTargetAttested() throws {
        try withTemporaryDirectory { root in
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-runtime-fallback",
                authorityEpoch: 6,
                ledgerSequence: 232,
                attestedAt: Date(timeIntervalSince1970: 100),
                sourceMode: DeviceSyncSourceProvenanceValidator.runtimeFallback,
                fallbackAuthorizationID: "fallback-auth-232",
                fallbackAuthorizationDigest: String(repeating: "8", count: 64)
            )

            let evidence = DeviceSyncTargetAttestationVerifier(
                channelRootURL: fixture.channelRoot
            ).verify(receipt: fixture.receipt)
            let projected = fixture.receipt.withAttestationEvidence(evidence)

            XCTAssertEqual(evidence.level, .targetLocallyAttested)
            XCTAssertTrue(projected.isConverged)
        }
    }

    func testReceiptSourceProvenanceMustMatchRequestAndManifest() throws {
        try withTemporaryDirectory { root in
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-provenance-mismatch",
                authorityEpoch: 6,
                ledgerSequence: 233,
                attestedAt: Date(timeIntervalSince1970: 100)
            )
            let receipt = replacingSourceProvenance(
                in: fixture.receipt,
                sourceMode: DeviceSyncSourceProvenanceValidator.runtimeFallback,
                inventoryDigest: String(repeating: "7", count: 64),
                fallbackAuthorizationID: "fallback-auth-233",
                fallbackAuthorizationPath:
                    "fallback-authorizations/mac-mini/epoch-6.json",
                fallbackAuthorizationDigest: String(repeating: "8", count: 64)
            )

            let evidence = DeviceSyncTargetAttestationVerifier(
                channelRootURL: fixture.channelRoot
            ).verify(receipt: receipt)

            XCTAssertEqual(evidence.level, .unreadable)
            XCTAssertFalse(receipt.withAttestationEvidence(evidence).isConverged)
            XCTAssertTrue(evidence.detail.contains("request"))
        }
    }

    func testClockSkewDoesNotInvalidateDigestAndAuthorityBoundAttestation() throws {
        try withTemporaryDirectory { root in
            let fixture = try writeAttestationFixture(
                root: root,
                requestID: "request-clock-skew",
                authorityEpoch: 6,
                ledgerSequence: 24,
                requestedAt: Date(timeIntervalSince1970: 9_000),
                completedAt: Date(timeIntervalSince1970: 100),
                requestArtifactRequestedAt: Date(timeIntervalSince1970: 50_000),
                attestedAt: Date(timeIntervalSince1970: -5_000)
            )

            let evidence = DeviceSyncTargetAttestationVerifier(
                channelRootURL: fixture.channelRoot
            ).verify(receipt: fixture.receipt)
            let projected = fixture.receipt.withAttestationEvidence(evidence)

            XCTAssertEqual(evidence.level, .targetLocallyAttested)
            XCTAssertEqual(evidence.attestedAt, Date(timeIntervalSince1970: -5_000))
            XCTAssertTrue(projected.isConverged)
            XCTAssertEqual(projected.progressFraction, 1)
        }
    }

    func testTransactionProjectionCoversDurableRecoveryStatesWithoutGreenGuessing() {
        let cases: [
            (
                phase: String,
                recovery: String,
                ack: String,
                expected: DeviceSyncTransactionProjectionState
            )
        ] = [
            ("preparing", "none", "pending", .preparing),
            ("oldMirrorMoveStarted", "none", "pending", .oldMirrorMoveStarted),
            ("committed", "none", "pending", .committedAwaitingACK),
            ("committed", "recovering", "pending", .recovering),
            ("rollbackPending", "rollbackPending", "pending", .rollbackPending),
            ("diverged", "diverged", "blocked", .diverged),
        ]

        for fixture in cases {
            let state = DeviceSyncOutboxStore.projectTransactionState(
                journal: makeTransactionJournal(
                    phase: fixture.phase,
                    recoveryState: fixture.recovery,
                    ackState: fixture.ack
                ),
                receipt: nil,
                evidence: .none
            )

            XCTAssertEqual(
                state,
                fixture.expected,
                "\(fixture.phase)/\(fixture.recovery)/\(fixture.ack)"
            )
            XCTAssertLessThan(state.progress.fraction, 1)
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceSyncOutboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeSourceRefreshAttempt(
        attemptID: String,
        ledgerSequence: Int,
        outcome: DeviceSyncSourceRefreshOutcome = .failed,
        storeMutation: String = "staged-not-activated",
        message: String? = "local source refresh failed",
        results: [DeviceSyncSourceRefreshResult]
    ) -> DeviceSyncSourceRefreshAttempt {
        let requestedAt = Date(timeIntervalSince1970: 1_753_500_000)
        let failedCount = results.filter(\.isFailed).count
        return DeviceSyncSourceRefreshAttempt(
            schema: DeviceSyncSourceRefreshAttempt.schema,
            evidenceKind: DeviceSyncSourceRefreshAttempt.evidenceKind,
            attemptID: attemptID,
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: requestedAt,
            currentDeviceName: "mac-mini",
            currentDeviceID: "mini-id",
            authorityPrimary: "mac-mini",
            authorityEpoch: 8,
            ledgerSequence: ledgerSequence,
            catalogRevision: "2026-07-23.2",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            outcome: outcome,
            sourceMode: "unresolved",
            storeMutation: storeMutation,
            inventoryDigest: "",
            fallbackAuthorizationID: "",
            fallbackAuthorizationPath: "",
            fallbackAuthorizationDigest: "",
            discoveredSourceCount: results.count,
            refreshedCount: results.filter { !$0.isFailed }.count,
            failedCount: failedCount,
            results: results,
            message: message,
            startedAt: requestedAt.addingTimeInterval(1),
            completedAt: requestedAt.addingTimeInterval(2)
        )
    }

    private func verifiedItem(
        _ id: String,
        displayName: String,
        digest: Character
    ) -> DeviceSyncItemReceipt {
        let value = String(repeating: String(digest), count: 64)
        return DeviceSyncItemReceipt(
            id: id,
            displayName: displayName,
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: value,
            appliedDigest: value,
            message: "verified"
        )
    }

    private func verifiedSkilletItem(
        requestID: String,
        authorityEpoch: Int,
        ledgerSequence: Int,
        sourceDeviceID: String,
        targetDeviceID: String,
        catalogRevision: String
    ) -> DeviceSyncItemReceipt {
        let contentDigest = String(repeating: "d", count: 64)
        let bundleDigest = String(repeating: "e", count: 64)
        return DeviceSyncItemReceipt(
            id: "skills.skillet",
            displayName: "Skillet private repositories",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "9", count: 64),
            appliedDigest: String(repeating: "9", count: 64),
            message: "verified",
            repositoryCount: 1,
            repositories: [
                DeviceSyncSkilletRepositoryReceipt(
                    repositoryID: "alpha-skill",
                    revisionID: "rev-\(contentDigest)",
                    contentDigest: contentDigest,
                    bundleDigest: bundleDigest,
                    requestID: requestID,
                    sourceDeviceID: sourceDeviceID,
                    targetDeviceID: targetDeviceID,
                    authorityEpoch: authorityEpoch,
                    ledgerSequence: ledgerSequence,
                    catalogRevision: catalogRevision,
                    phase: .verified
                )
            ]
        )
    }

    private func makeOrderingReceipt(
        action: String = "version-pull",
        requestID: String,
        authorityEpoch: Int,
        ledgerSequence: Int,
        requestedAt: TimeInterval,
        completedAt: TimeInterval,
        message: String = "ordering fixture"
    ) -> DeviceSyncReceipt {
        DeviceSyncReceipt(
            target: "macbook-m3",
            action: action,
            requestedAt: Date(timeIntervalSince1970: requestedAt),
            result: "pending",
            completedAt: Date(timeIntervalSince1970: completedAt),
            message: message,
            phase: .delivered,
            requestID: requestID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence
        )
    }

    private func makeTransactionJournal(
        phase: String,
        recoveryState: String,
        ackState: String
    ) -> DeviceSyncSystemTransactionJournal {
        DeviceSyncSystemTransactionJournal(
            schema: DeviceSyncOutboxStore.transactionSchema,
            requestID: "request-transaction-state",
            phase: phase,
            authorityPrimary: "mac-mini",
            authorityEpoch: 5,
            ledgerSequence: 25,
            catalogRevision: DeviceSyncCatalogProjection.currentRevision ?? "catalog-test",
            ackState: ackState,
            recoveryState: recoveryState,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            message: "transaction projection fixture"
        )
    }

    private func makeChannelClaimedSystemReceipt(
        requestID: String,
        authorityEpoch: Int,
        ledgerSequence: Int,
        requestedAt: Date = Date(timeIntervalSince1970: 1),
        completedAt: Date = Date(timeIntervalSince1970: 2),
        progress: DeviceSyncProgressPayload? = nil
    ) -> DeviceSyncReceipt {
        let catalogRevision = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
        return DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: requestedAt,
            result: "converged",
            completedAt: completedAt,
            message: "channel ACK claims converged",
            phase: .converged,
            requestID: requestID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            sourceMode: DeviceSyncSourceProvenanceValidator.canonical,
            inventoryDigest: String(repeating: "7", count: 64),
            fallbackAuthorizationID: "",
            fallbackAuthorizationPath: "",
            fallbackAuthorizationDigest: "",
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "f", count: 64),
            appliedDigest: String(repeating: "f", count: 64),
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: [
                verifiedItem("os.constitution", displayName: "os.md", digest: "a"),
                verifiedItem("os.issue", displayName: "issue.md", digest: "b"),
                verifiedItem("os.todo", displayName: "TODO.md", digest: "c"),
                verifiedSkilletItem(
                    requestID: requestID,
                    authorityEpoch: authorityEpoch,
                    ledgerSequence: ledgerSequence,
                    sourceDeviceID: "mini-id",
                    targetDeviceID: "book-id",
                    catalogRevision: catalogRevision
                )
            ],
            progress: progress
        )
    }

    private func replacingAttestationBinding(
        in receipt: DeviceSyncReceipt,
        kind: String?,
        path: String?,
        digest: String?
    ) -> DeviceSyncReceipt {
        DeviceSyncReceipt(
            target: receipt.target,
            action: receipt.action,
            requestedAt: receipt.requestedAt,
            result: receipt.result,
            completedAt: receipt.completedAt,
            message: receipt.message,
            phase: receipt.phase,
            requestID: receipt.requestID,
            authorityEpoch: receipt.authorityEpoch,
            ledgerSequence: receipt.ledgerSequence,
            authorityPrimary: receipt.authorityPrimary,
            sourceDeviceID: receipt.sourceDeviceID,
            targetDeviceID: receipt.targetDeviceID,
            catalogRevision: receipt.catalogRevision,
            sourceMode: receipt.sourceMode,
            inventoryDigest: receipt.inventoryDigest,
            fallbackAuthorizationID: receipt.fallbackAuthorizationID,
            fallbackAuthorizationPath: receipt.fallbackAuthorizationPath,
            fallbackAuthorizationDigest: receipt.fallbackAuthorizationDigest,
            digestAlgorithm: receipt.digestAlgorithm,
            sourceDigest: receipt.sourceDigest,
            appliedDigest: receipt.appliedDigest,
            signaturePurpose: receipt.signaturePurpose,
            signaturePath: receipt.signaturePath,
            attestationKind: kind,
            targetAttestationPath: path,
            targetAttestationDigest: digest,
            targetAttestationSignaturePath:
                receipt.targetAttestationSignaturePath,
            consumerReadbackKind: receipt.consumerReadbackKind,
            consumerReadbackPath: receipt.consumerReadbackPath,
            consumerReadbackDigest: receipt.consumerReadbackDigest,
            consumerReadbackCount: receipt.consumerReadbackCount,
            requiredItemIDs: receipt.requiredItemIDs,
            items: receipt.items ?? [],
            attestationEvidence: receipt.attestationEvidence
        )
    }

    private func replacingSourceProvenance(
        in receipt: DeviceSyncReceipt,
        sourceMode: String?,
        inventoryDigest: String?,
        fallbackAuthorizationID: String?,
        fallbackAuthorizationPath: String?,
        fallbackAuthorizationDigest: String?
    ) -> DeviceSyncReceipt {
        DeviceSyncReceipt(
            target: receipt.target,
            action: receipt.action,
            requestedAt: receipt.requestedAt,
            result: receipt.result,
            completedAt: receipt.completedAt,
            message: receipt.message,
            phase: receipt.phase,
            requestID: receipt.requestID,
            authorityEpoch: receipt.authorityEpoch,
            ledgerSequence: receipt.ledgerSequence,
            authorityPrimary: receipt.authorityPrimary,
            sourceDeviceID: receipt.sourceDeviceID,
            targetDeviceID: receipt.targetDeviceID,
            catalogRevision: receipt.catalogRevision,
            sourceMode: sourceMode,
            inventoryDigest: inventoryDigest,
            fallbackAuthorizationID: fallbackAuthorizationID,
            fallbackAuthorizationPath: fallbackAuthorizationPath,
            fallbackAuthorizationDigest: fallbackAuthorizationDigest,
            digestAlgorithm: receipt.digestAlgorithm,
            sourceDigest: receipt.sourceDigest,
            appliedDigest: receipt.appliedDigest,
            signaturePurpose: receipt.signaturePurpose,
            signaturePath: receipt.signaturePath,
            attestationKind: receipt.attestationKind,
            targetAttestationPath: receipt.targetAttestationPath,
            targetAttestationDigest: receipt.targetAttestationDigest,
            targetAttestationSignaturePath:
                receipt.targetAttestationSignaturePath,
            consumerReadbackKind: receipt.consumerReadbackKind,
            consumerReadbackPath: receipt.consumerReadbackPath,
            consumerReadbackDigest: receipt.consumerReadbackDigest,
            consumerReadbackCount: receipt.consumerReadbackCount,
            requiredItemIDs: receipt.requiredItemIDs,
            items: receipt.items ?? [],
            attestationEvidence: receipt.attestationEvidence,
            progress: receipt.progress
        )
    }

    private func replacingAction(
        in receipt: DeviceSyncReceipt,
        action: String
    ) -> DeviceSyncReceipt {
        DeviceSyncReceipt(
            target: receipt.target,
            action: action,
            requestedAt: receipt.requestedAt,
            result: receipt.result,
            completedAt: receipt.completedAt,
            message: receipt.message,
            phase: receipt.phase,
            requestID: receipt.requestID,
            authorityEpoch: receipt.authorityEpoch,
            ledgerSequence: receipt.ledgerSequence,
            authorityPrimary: receipt.authorityPrimary,
            sourceDeviceID: receipt.sourceDeviceID,
            targetDeviceID: receipt.targetDeviceID,
            catalogRevision: receipt.catalogRevision,
            sourceMode: receipt.sourceMode,
            inventoryDigest: receipt.inventoryDigest,
            fallbackAuthorizationID: receipt.fallbackAuthorizationID,
            fallbackAuthorizationPath: receipt.fallbackAuthorizationPath,
            fallbackAuthorizationDigest: receipt.fallbackAuthorizationDigest,
            digestAlgorithm: receipt.digestAlgorithm,
            sourceDigest: receipt.sourceDigest,
            appliedDigest: receipt.appliedDigest,
            signaturePurpose: receipt.signaturePurpose,
            signaturePath: receipt.signaturePath,
            attestationKind: receipt.attestationKind,
            targetAttestationPath: receipt.targetAttestationPath,
            targetAttestationDigest: receipt.targetAttestationDigest,
            targetAttestationSignaturePath:
                receipt.targetAttestationSignaturePath,
            consumerReadbackKind: receipt.consumerReadbackKind,
            consumerReadbackPath: receipt.consumerReadbackPath,
            consumerReadbackDigest: receipt.consumerReadbackDigest,
            consumerReadbackCount: receipt.consumerReadbackCount,
            requiredItemIDs: receipt.requiredItemIDs,
            items: receipt.items ?? [],
            attestationEvidence: receipt.attestationEvidence,
            progress: receipt.progress
        )
    }

    private func writeAttestationFixture(
        root: URL,
        requestID: String,
        authorityEpoch: Int,
        ledgerSequence: Int,
        requestedAt: Date = Date(timeIntervalSince1970: 1),
        completedAt: Date = Date(timeIntervalSince1970: 2),
        requestArtifactRequestedAt: Date = Date(timeIntervalSince1970: 1),
        attestedAt: Date,
        attestationSchema: String = DeviceSyncTargetAttestationVerifier.attestationSchema,
        osLoadedRevisionOverride: String? = nil,
        sourceMode: String = DeviceSyncSourceProvenanceValidator.canonical,
        inventoryDigest: String = String(repeating: "7", count: 64),
        fallbackAuthorizationID: String = "",
        fallbackAuthorizationPath: String? = nil,
        fallbackAuthorizationDigest: String = "",
        targetPreservedRepository: (
            repositoryID: String,
            contentDigest: String
        )? = nil
    ) throws -> (channelRoot: URL, receipt: DeviceSyncReceipt) {
        let catalogRevision = try XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
        let resolvedFallbackAuthorizationPath = fallbackAuthorizationPath
            ?? (
                sourceMode == DeviceSyncSourceProvenanceValidator.runtimeFallback
                    ? "fallback-authorizations/mac-mini/epoch-\(authorityEpoch).json"
                    : ""
            )
        let channelRoot = root.appendingPathComponent(
            "device-sync-channel",
            isDirectory: true
        )
        let privateKeyStore = try TatwoDeviceTestFilePrivateKeyStore(
            rootURL: root.appendingPathComponent(
                ".device-trust-test-keys",
                isDirectory: true
            ),
            testModeAuthorized: true,
            environment: [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
        )
        let trustAuthority = TatwoDeviceTrustAuthority(
            privateKeyStore: privateKeyStore
        )
        let sourceIdentity = try trustAuthority.ensureIdentity(
            deviceID: "mini-id",
            pinnedAt: "2026-07-26T00:00:00Z"
        )
        let targetIdentity = try trustAuthority.ensureIdentity(
            deviceID: "book-id",
            pinnedAt: "2026-07-26T00:00:00Z"
        )
        try writeRegisteredIdentity(
            sourceIdentity,
            name: "mac-mini",
            role: "primary",
            root: root,
            channelRoot: channelRoot,
            isLocal: true
        )
        try writeRegisteredIdentity(
            targetIdentity,
            name: "macbook-m3",
            role: "secondary",
            root: root,
            channelRoot: channelRoot,
            isLocal: false
        )
        let requestDirectory = channelRoot
            .appendingPathComponent("requests", isDirectory: true)
            .appendingPathComponent("macbook-m3", isDirectory: true)
        let payloadDirectory = channelRoot
            .appendingPathComponent("payloads", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
        let attestationDirectory = channelRoot
            .appendingPathComponent("attestations", isDirectory: true)
            .appendingPathComponent("macbook-m3", isDirectory: true)
        let consumerReadbackDirectory = channelRoot
            .appendingPathComponent("consumer-readbacks", isDirectory: true)
            .appendingPathComponent("macbook-m3", isDirectory: true)
        try FileManager.default.createDirectory(
            at: requestDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: payloadDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attestationDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: consumerReadbackDirectory,
            withIntermediateDirectories: true
        )

        let items = [
            verifiedItem("os.constitution", displayName: "os.md", digest: "a"),
            verifiedItem("os.issue", displayName: "issue.md", digest: "b"),
            verifiedItem("os.todo", displayName: "TODO.md", digest: "c"),
            verifiedSkilletItem(
                requestID: requestID,
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                sourceDeviceID: "mini-id",
                targetDeviceID: "book-id",
                catalogRevision: catalogRevision
            ),
        ]
        let manifest = DeviceSyncManifestArtifact(
            schemaVersion: 1,
            requestID: requestID,
            catalogRevision: catalogRevision,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            sourceMode: sourceMode,
            inventoryDigest: inventoryDigest,
            fallbackAuthorizationID: fallbackAuthorizationID,
            fallbackAuthorizationPath: resolvedFallbackAuthorizationPath,
            fallbackAuthorizationDigest: fallbackAuthorizationDigest,
            items: try items.map { item in
                DeviceSyncManifestItemArtifact(
                    id: item.id,
                    displayName: item.displayName,
                    payloadRelativePath: "\(item.id)/payload",
                    mirrorRelativePath: "\(item.id)/mirror",
                    sourceDigest: try XCTUnwrap(item.sourceDigest),
                    byteCount: 1,
                    repositoryCount: item.repositoryCount
                )
            }
        )
        let manifestData = try DeviceSyncOutboxJSON.encoder.encode(manifest)
        let manifestDigest = DeviceSyncArtifactDigester.sha256(manifestData)
        try manifestData.write(
            to: payloadDirectory.appendingPathComponent("manifest.json")
        )

        let request = DeviceSyncRequestArtifact(
            id: requestID,
            requestID: requestID,
            action: "system-pull",
            target: "macbook-m3",
            targetDeviceName: "macbook-m3",
            targetDeviceID: "book-id",
            requestedAt: requestArtifactRequestedAt,
            authorityPrimary: "mac-mini",
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            sourceDeviceID: "mini-id",
            catalogRevision: catalogRevision,
            sourceMode: sourceMode,
            inventoryDigest: inventoryDigest,
            fallbackAuthorizationID: fallbackAuthorizationID,
            fallbackAuthorizationPath: resolvedFallbackAuthorizationPath,
            fallbackAuthorizationDigest: fallbackAuthorizationDigest,
            digestAlgorithm: "sha256",
            sourceDigest: manifestDigest,
            manifestPath: "payloads/\(requestID)/manifest.json",
            manifestDigest: manifestDigest,
            signaturePurpose: "sync-request",
            signaturePath: "signatures/requests/macbook-m3/\(requestID).json"
        )
        let requestData = try DeviceSyncOutboxJSON.encoder.encode(request)
        try requestData.write(
            to: requestDirectory.appendingPathComponent("\(requestID).json")
        )
        try writeSignature(
            payload: requestData,
            purpose: "sync-request",
            identity: sourceIdentity,
            authority: trustAuthority,
            relativePath: "signatures/requests/macbook-m3/\(requestID).json",
            channelRoot: channelRoot
        )

        let osReadbacks = items
            .filter { $0.id != "skills.skillet" }
            .flatMap { item -> [DeviceSyncTargetConsumerReadbackArtifact] in
                let digest = item.sourceDigest!
                let loadedPath: String
                switch item.id {
                case "os.constitution": loadedPath = "os/os.md"
                case "os.issue": loadedPath = "os/issue.md"
                case "os.todo": loadedPath = "os/TODO.md"
                default: loadedPath = "os/unknown"
                }
                return [
                    DeviceSyncTargetConsumerReadbackArtifact(
                        schema: "TatwoTargetConsumerReadbackV1",
                        requestID: requestID,
                        targetDeviceID: "book-id",
                        authorityPrimary: "mac-mini",
                        authorityEpoch: authorityEpoch,
                        ledgerSequence: ledgerSequence,
                        catalogRevision: catalogRevision,
                        consumerID: "work-os.bootstrap",
                        consumerKind: "work-os-bootstrap",
                        sourceItemID: item.id,
                        expectedDigest: digest,
                        loadedDigest: digest,
                        loadedRevision: osLoadedRevisionOverride ?? "sha256-\(digest)",
                        loadedPath: loadedPath,
                        runtimeRef: "TatwoWorkOSBootstrap",
                        observedAt: attestedAt,
                        status: "loaded"
                    ),
                    DeviceSyncTargetConsumerReadbackArtifact(
                        schema: "TatwoTargetConsumerReadbackV1",
                        requestID: requestID,
                        targetDeviceID: "book-id",
                        authorityPrimary: "mac-mini",
                        authorityEpoch: authorityEpoch,
                        ledgerSequence: ledgerSequence,
                        catalogRevision: catalogRevision,
                        consumerID: "tatwo-app.shared-runtime",
                        consumerKind: "tatwo-app-shared-loader",
                        sourceItemID: item.id,
                        expectedDigest: digest,
                        loadedDigest: digest,
                        loadedRevision: osLoadedRevisionOverride ?? "sha256-\(digest)",
                        loadedPath: loadedPath,
                        runtimeRef: "TatwoUltraworkCore",
                        observedAt: attestedAt,
                        status: "loaded"
                    ),
                ]
            }
        let skilletRepository = try XCTUnwrap(items.last?.repositories?.first)
        let synchronizedSkilletReadbacks = [
            DeviceSyncTargetConsumerReadbackArtifact(
                schema: "TatwoTargetConsumerReadbackV1",
                requestID: requestID,
                targetDeviceID: "book-id",
                authorityPrimary: "mac-mini",
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                catalogRevision: catalogRevision,
                consumerID: "skillet.runtime-loader",
                consumerKind: "active-skill-runtime-loader",
                sourceItemID: "skills.skillet",
                expectedDigest: skilletRepository.contentDigest,
                loadedDigest: skilletRepository.contentDigest,
                loadedRevision: skilletRepository.revisionID,
                loadedPath: "skillet/\(skilletRepository.repositoryID)",
                runtimeRef: "TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive",
                observedAt: attestedAt,
                status: "loaded"
            ),
            DeviceSyncTargetConsumerReadbackArtifact(
                schema: "TatwoTargetConsumerReadbackV1",
                requestID: requestID,
                targetDeviceID: "book-id",
                authorityPrimary: "mac-mini",
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                catalogRevision: catalogRevision,
                consumerID: "codex.native-skills",
                consumerKind: "codex-native-skills-loader",
                sourceItemID: "skills.skillet",
                expectedDigest: skilletRepository.contentDigest,
                loadedDigest: skilletRepository.contentDigest,
                loadedRevision: skilletRepository.revisionID,
                loadedPath: ".codex/skills/\(skilletRepository.repositoryID)",
                runtimeRef:
                    "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
                observedAt: attestedAt,
                status: "loaded"
            ),
            DeviceSyncTargetConsumerReadbackArtifact(
                schema: "TatwoTargetConsumerReadbackV1",
                requestID: requestID,
                targetDeviceID: "book-id",
                authorityPrimary: "mac-mini",
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                catalogRevision: catalogRevision,
                consumerID: "claude.native-skills",
                consumerKind: "claude-native-skills-loader",
                sourceItemID: "skills.skillet",
                expectedDigest: skilletRepository.contentDigest,
                loadedDigest: skilletRepository.contentDigest,
                loadedRevision: skilletRepository.revisionID,
                loadedPath: ".claude/skills/\(skilletRepository.repositoryID)",
                runtimeRef:
                    "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
                observedAt: attestedAt,
                status: "loaded"
            )
        ]
        let targetPreservedReadbacks = targetPreservedRepository.map { repository in
            [
                DeviceSyncTargetConsumerReadbackArtifact(
                    schema: "TatwoTargetConsumerReadbackV1",
                    requestID: requestID,
                    targetDeviceID: "book-id",
                    authorityPrimary: "mac-mini",
                    authorityEpoch: authorityEpoch,
                    ledgerSequence: ledgerSequence,
                    catalogRevision: catalogRevision,
                    consumerID: "skillet.runtime-loader",
                    consumerKind: "active-skill-runtime-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: repository.contentDigest,
                    loadedDigest: repository.contentDigest,
                    loadedRevision: "rev-\(repository.contentDigest)",
                    loadedPath: "skillet/\(repository.repositoryID)",
                    runtimeRef:
                        "TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive",
                    observedAt: attestedAt,
                    status: "loaded"
                ),
                DeviceSyncTargetConsumerReadbackArtifact(
                    schema: "TatwoTargetConsumerReadbackV1",
                    requestID: requestID,
                    targetDeviceID: "book-id",
                    authorityPrimary: "mac-mini",
                    authorityEpoch: authorityEpoch,
                    ledgerSequence: ledgerSequence,
                    catalogRevision: catalogRevision,
                    consumerID: "codex.native-skills",
                    consumerKind: "codex-native-skills-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: repository.contentDigest,
                    loadedDigest: repository.contentDigest,
                    loadedRevision: "rev-\(repository.contentDigest)",
                    loadedPath: ".codex/skills/\(repository.repositoryID)",
                    runtimeRef:
                        "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
                    observedAt: attestedAt,
                    status: "loaded"
                ),
                DeviceSyncTargetConsumerReadbackArtifact(
                    schema: "TatwoTargetConsumerReadbackV1",
                    requestID: requestID,
                    targetDeviceID: "book-id",
                    authorityPrimary: "mac-mini",
                    authorityEpoch: authorityEpoch,
                    ledgerSequence: ledgerSequence,
                    catalogRevision: catalogRevision,
                    consumerID: "claude.native-skills",
                    consumerKind: "claude-native-skills-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: repository.contentDigest,
                    loadedDigest: repository.contentDigest,
                    loadedRevision: "rev-\(repository.contentDigest)",
                    loadedPath: ".claude/skills/\(repository.repositoryID)",
                    runtimeRef:
                        "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
                    observedAt: attestedAt,
                    status: "loaded"
                ),
            ]
        } ?? []
        let readbacks =
            osReadbacks + synchronizedSkilletReadbacks + targetPreservedReadbacks
        let consumerReadback = DeviceSyncTargetConsumerReadbackSetArtifact(
            schema: "TatwoTargetConsumerReadbackSetV1",
            requestID: requestID,
            target: "macbook-m3",
            targetDeviceID: "book-id",
            sourceDeviceID: "mini-id",
            authorityPrimary: "mac-mini",
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            manifestDigest: manifestDigest,
            requiredConsumerIDs: DeviceSyncTargetAttestationVerifier.requiredConsumerIDs,
            readbackCount: readbacks.count,
            readbacks: readbacks,
            observedAt: attestedAt,
            status: "passed"
        )
        let consumerReadbackData = try DeviceSyncOutboxJSON.encoder.encode(
            consumerReadback
        )
        let consumerReadbackDigest = DeviceSyncArtifactDigester.sha256(
            consumerReadbackData
        )
        try consumerReadbackData.write(
            to: consumerReadbackDirectory.appendingPathComponent("\(requestID).json")
        )

        let attestation = DeviceSyncTargetAttestationArtifact(
            schema: attestationSchema,
            kind: DeviceSyncTargetAttestationVerifier.attestationKind,
            requestID: requestID,
            target: "macbook-m3",
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            transactionPhase: "committed",
            transactionJournalDigest: String(repeating: "d", count: 64),
            manifestDigest: manifestDigest,
            skilletActiveSetReceiptDigest: String(repeating: "e", count: 64),
            consumerReadbackKind: DeviceSyncTargetAttestationVerifier.consumerReadbackKind,
            consumerReadbackPath: "consumer-readbacks/macbook-m3/\(requestID).json",
            consumerReadbackDigest: consumerReadbackDigest,
            consumerReadbackCount: readbacks.count,
            attestedAt: attestedAt,
            signaturePurpose: "target-attestation",
            signaturePath:
                "signatures/attestations/macbook-m3/\(requestID).json"
        )
        let attestationData = try DeviceSyncOutboxJSON.encoder.encode(attestation)
        let attestationDigest = DeviceSyncArtifactDigester.sha256(attestationData)
        try attestationData.write(
            to: attestationDirectory.appendingPathComponent("\(requestID).json")
        )
        try writeSignature(
            payload: attestationData,
            purpose: "target-attestation",
            identity: targetIdentity,
            authority: trustAuthority,
            relativePath:
                "signatures/attestations/macbook-m3/\(requestID).json",
            channelRoot: channelRoot
        )

        let receipt = DeviceSyncReceipt(
            target: "macbook-m3",
            action: "system-pull",
            requestedAt: requestedAt,
            result: "converged",
            completedAt: completedAt,
            message: "channel ACK with target-local attestation binding",
            phase: .converged,
            requestID: requestID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            sourceMode: sourceMode,
            inventoryDigest: inventoryDigest,
            fallbackAuthorizationID: fallbackAuthorizationID,
            fallbackAuthorizationPath: resolvedFallbackAuthorizationPath,
            fallbackAuthorizationDigest: fallbackAuthorizationDigest,
            digestAlgorithm: "sha256",
            sourceDigest: manifestDigest,
            appliedDigest: manifestDigest,
            signaturePurpose: "sync-ack",
            signaturePath: "signatures/acks/\(requestID).json",
            attestationKind: DeviceSyncTargetAttestationVerifier.attestationKind,
            targetAttestationPath: "attestations/macbook-m3/\(requestID).json",
            targetAttestationDigest: attestationDigest,
            targetAttestationSignaturePath:
                "signatures/attestations/macbook-m3/\(requestID).json",
            consumerReadbackKind: DeviceSyncTargetAttestationVerifier.consumerReadbackKind,
            consumerReadbackPath: "consumer-readbacks/macbook-m3/\(requestID).json",
            consumerReadbackDigest: consumerReadbackDigest,
            consumerReadbackCount: readbacks.count,
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: items
        )
        let acknowledgementsDirectory = channelRoot.appendingPathComponent(
            "acks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: acknowledgementsDirectory,
            withIntermediateDirectories: true
        )
        var receiptData = try DeviceSyncOutboxJSON.encoder.encode(receipt)
        if let targetPreservedRepository {
            guard var object = try JSONSerialization.jsonObject(
                with: receiptData
            ) as? [String: Any],
                var receiptItems = object["items"] as? [[String: Any]],
                let skilletIndex = receiptItems.firstIndex(where: {
                    $0["id"] as? String == "skills.skillet"
                })
            else {
                throw DeviceSyncArtifactError.unreadableArtifact(
                    "test target-preserved ACK"
                )
            }
            receiptItems[skilletIndex]["targetPreservedCount"] = 1
            receiptItems[skilletIndex]["targetPreservedRepositories"] = [[
                "repositoryID": targetPreservedRepository.repositoryID,
                "revisionID": "rev-\(targetPreservedRepository.contentDigest)",
                "contentDigest": targetPreservedRepository.contentDigest,
                "state": "runtime-preserved",
                "phase": "preserved",
            ]]
            receiptItems[skilletIndex]["targetPreservedRuntimeClosureCapability"] =
                "target-preserved-runtime-closure-v1"
            receiptItems[skilletIndex]["targetPreservedRuntimeClosed"] = true
            object["items"] = receiptItems
            receiptData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
        try receiptData.write(
            to: acknowledgementsDirectory.appendingPathComponent(
                "\(requestID).json"
            )
        )
        try writeSignature(
            payload: receiptData,
            purpose: "sync-ack",
            identity: targetIdentity,
            authority: trustAuthority,
            relativePath: "signatures/acks/\(requestID).json",
            channelRoot: channelRoot
        )
        return (
            channelRoot,
            try DeviceSyncOutboxJSON.decoder.decode(
                DeviceSyncReceipt.self,
                from: receiptData
            )
        )
    }

    private func writeRegisteredIdentity(
        _ identity: TatwoDevicePublicIdentityV1,
        name: String,
        role: String,
        root: URL,
        channelRoot: URL,
        isLocal: Bool
    ) throws {
        let identityData = try DeviceSyncOutboxJSON.encoder.encode(identity)
        guard var object = try JSONSerialization.jsonObject(
            with: identityData
        ) as? [String: Any] else {
            throw DeviceSyncArtifactError.unreadableArtifact("test identity")
        }
        object["name"] = name
        object["role"] = role
        object["deviceId"] = identity.deviceID
        object["enrolledAt"] = "2026-07-26T00:00:00Z"
        let registryData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let devicesDirectory = channelRoot.appendingPathComponent(
            "devices",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: devicesDirectory,
            withIntermediateDirectories: true
        )
        try registryData.write(
            to: devicesDirectory.appendingPathComponent("\(name).json")
        )

        if isLocal {
            let localDirectory = root.appendingPathComponent(
                "device-trust",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: localDirectory,
                withIntermediateDirectories: true
            )
            try identityData.write(
                to: localDirectory.appendingPathComponent("identity.json")
            )
        } else {
            let peersDirectory = root
                .appendingPathComponent("device-trust", isDirectory: true)
                .appendingPathComponent("peers", isDirectory: true)
            try FileManager.default.createDirectory(
                at: peersDirectory,
                withIntermediateDirectories: true
            )
            try registryData.write(
                to: peersDirectory.appendingPathComponent("\(name).json")
            )
        }
    }

    private func writeSignature(
        payload: Data,
        purpose: String,
        identity: TatwoDevicePublicIdentityV1,
        authority: TatwoDeviceTrustAuthority,
        relativePath: String,
        channelRoot: URL
    ) throws {
        let signature = try authority.sign(
            payload: payload,
            purpose: purpose,
            identity: identity,
            signedAt: "2026-07-26T00:00:01Z"
        )
        let destination = relativePath.split(separator: "/").reduce(
            channelRoot
        ) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try DeviceSyncOutboxJSON.encoder.encode(signature).write(to: destination)
    }
}

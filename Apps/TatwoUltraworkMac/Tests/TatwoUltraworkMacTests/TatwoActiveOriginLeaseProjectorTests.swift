import Foundation
import XCTest
import TatwoDomainContracts
import TatwoUltraworkCore
import TatwoWorkReceiptContracts
@testable import TatwoUltraworkMac

final class TatwoActiveOriginLeaseProjectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    func testMissingSnapshotFailsClosed() {
        let root = temporaryDirectory("snapshot-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        writeLocalDeviceID("mini", to: root)

        XCTAssertEqual(
            project(snapshot: nil, root: root),
            .verifiedSnapshotUnavailable
        )
    }

    func testMissingOrInvalidLocalDeviceIDFailsClosedWithoutCreatingOne() {
        let root = temporaryDirectory("local-id-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            project(snapshot: makeSnapshot(leases: [makeLease(holder: "mini")]), root: root),
            .localDeviceIDUnavailable
        )

        try? Data(repeating: 0x61, count: 257).write(
            to: root.appendingPathComponent("local-device-id")
        )
        XCTAssertEqual(
            project(snapshot: makeSnapshot(leases: [makeLease(holder: "mini")]), root: root),
            .localDeviceIDUnavailable
        )

        try? Data(" \n\t ".utf8).write(
            to: root.appendingPathComponent("local-device-id")
        )
        XCTAssertEqual(
            project(snapshot: makeSnapshot(leases: [makeLease(holder: "mini")]), root: root),
            .localDeviceIDUnavailable
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("local-device-id").path
            )
        )

        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try? Data("../mini".utf8).write(
            to: root.appendingPathComponent("local-device-id")
        )
        XCTAssertEqual(
            project(snapshot: makeSnapshot(leases: [makeLease(holder: "mini")]), root: root),
            .localDeviceIDUnavailable
        )
    }

    func testMissingLeaseFailsClosed() {
        let root = readyRoot("lease-missing", localDeviceID: "mini")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            project(snapshot: makeSnapshot(leases: []), root: root),
            .activeLeaseUnavailable
        )
    }

    func testExpiredLeaseFailsClosed() {
        let root = readyRoot("lease-expired", localDeviceID: "mini")
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = makeSnapshot(
            leases: [
                makeLease(
                    holder: "mini",
                    observedAt: now.addingTimeInterval(-120),
                    expiresAt: now.addingTimeInterval(-60)
                )
            ]
        )

        XCTAssertEqual(
            TatwoActiveOriginLeaseProjector.project(
                snapshotProvider: RawSnapshotProvider(snapshot: expired),
                stateRootURL: root,
                now: now
            ),
            .activeLeaseExpired
        )
    }

    func testLeaseHolderMustMatchPersistedLocalDeviceID() {
        let root = readyRoot("holder-mismatch", localDeviceID: "book")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            project(
                snapshot: makeSnapshot(leases: [makeLease(holder: "mini")]),
                root: root
            ),
            .localDeviceIsNotOrigin(holderDeviceID: "mini")
        )
    }

    func testSplitBrainAndInvalidSnapshotFailClosedEvenIfProviderBreaksContract() {
        let root = readyRoot("snapshot-invalid", localDeviceID: "mini")
        defer { try? FileManager.default.removeItem(at: root) }
        let splitBrain = makeSnapshot(
            leases: [
                makeLease(holder: "mini", epoch: 1),
                makeLease(holder: "book", epoch: 2)
            ]
        )
        XCTAssertEqual(
            TatwoActiveOriginLeaseProjector.project(
                snapshotProvider: RawSnapshotProvider(snapshot: splitBrain),
                stateRootURL: root,
                now: now
            ),
            .splitBrain
        )

        let invalid = TatwoDomainDeviceSnapshotV1(
            protocolVersion: 2,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: makeDevices(),
            authorityLeases: [makeLease(holder: "mini")]
        )
        XCTAssertEqual(
            TatwoActiveOriginLeaseProjector.project(
                snapshotProvider: RawSnapshotProvider(snapshot: invalid),
                stateRootURL: root,
                now: now
            ),
            .invalidVerifiedSnapshot(.invalidProtocol)
        )
    }

    func testReadyReturnsOnlyVerifiedLeaseHeldByPersistedLocalDevice() {
        let root = readyRoot("ready", localDeviceID: "mini")
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = makeLease(holder: "mini")

        XCTAssertEqual(
            project(snapshot: makeSnapshot(leases: [lease]), root: root),
            .ready(localDeviceID: "mini", lease: lease)
        )
    }

    func testImmediateAuthorizationDoesNotPersistGrantUntilOriginIsReady() throws {
        let root = readyRoot("authorization-blocked", localDeviceID: "book")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TatwoRemoteBorrowAuthorizationStore(
            rootURL: root.appendingPathComponent("authorization", isDirectory: true)
        )
        let observedAt = now

        let result = try TatwoImmediateRemoteBorrowAuthorizer.authorize(
            snapshotProvider: TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: makeSnapshot(leases: [makeLease(holder: "mini")]),
                now: { observedAt }
            ),
            stateRootURL: root,
            authorizationStore: store,
            sessionID: "thread-1",
            targetDeviceID: "mini",
            contractID: "contract-1",
            now: now
        )

        XCTAssertEqual(
            result,
            .blocked(.localDeviceIsNotOrigin(holderDeviceID: "mini"))
        )
        XCTAssertNil(
            try store.sessionGrant(
                sessionID: "thread-1",
                targetDeviceID: "mini",
                contractID: "contract-1",
                now: now
            )
        )
    }

    func testImmediateAuthorizationPersistsGrantAfterOriginReadiness() throws {
        let root = readyRoot("authorization-ready", localDeviceID: "mini")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TatwoRemoteBorrowAuthorizationStore(
            rootURL: root.appendingPathComponent("authorization", isDirectory: true)
        )
        let observedAt = now

        let result = try TatwoImmediateRemoteBorrowAuthorizer.authorize(
            snapshotProvider: TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: makeSnapshot(leases: [makeLease(holder: "mini")]),
                now: { observedAt }
            ),
            stateRootURL: root,
            authorizationStore: store,
            sessionID: "thread-1",
            targetDeviceID: "book",
            contractID: "contract-1",
            now: now
        )

        guard case .granted(let grant) = result else {
            return XCTFail("expected authorization grant, got \(result)")
        }
        XCTAssertEqual(
            try store.sessionGrant(
                sessionID: "thread-1",
                targetDeviceID: "book",
                contractID: "contract-1",
                now: now
            ),
            grant
        )
    }

    private func project(
        snapshot: TatwoDomainDeviceSnapshotV1?,
        root: URL
    ) -> TatwoActiveOriginLeaseReadiness {
        let observedAt = now
        return TatwoActiveOriginLeaseProjector.project(
            snapshotProvider: TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: snapshot,
                now: { observedAt }
            ),
            stateRootURL: root,
            now: observedAt
        )
    }

    private func makeSnapshot(
        leases: [TatwoAuthorityLeaseV1]
    ) -> TatwoDomainDeviceSnapshotV1 {
        TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256: Self.validDigest,
            observedAt: now,
            devices: makeDevices(),
            authorityLeases: leases
        )
    }

    private func makeDevices() -> [TatwoDomainDeviceV1] {
        [
            makeDevice(id: "mini", name: "Mac mini", kind: .macMini),
            makeDevice(id: "book", name: "MacBook", kind: .macBook)
        ]
    }

    private func makeDevice(
        id: String,
        name: String,
        kind: TatwoDomainDeviceKindV1
    ) -> TatwoDomainDeviceV1 {
        TatwoDomainDeviceV1(
            id: id,
            domainID: "studio",
            displayName: name,
            kind: kind,
            connectionState: .connected,
            schemaVersion: 1,
            protocolVersion: 1,
            registeredAt: now,
            lastHeartbeatAt: now
        )
    }

    private func makeLease(
        holder: String,
        epoch: UInt64 = 1,
        observedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> TatwoAuthorityLeaseV1 {
        let observedAt = observedAt ?? now
        return TatwoAuthorityLeaseV1(
            domainID: "studio",
            holderDeviceID: holder,
            epoch: epoch,
            fencingToken: "fence-\(epoch)",
            observedAt: observedAt,
            expiresAt: expiresAt ?? observedAt.addingTimeInterval(60),
            source: .humanConfirmed,
            receiptMetadata: TatwoWorkReceiptMetadataV1(
                receiptID: "lease-\(holder)-\(epoch)",
                schema: "TatwoAuthorityLeaseV1",
                version: 1,
                correlationID: "authority",
                createdAt: observedAt,
                sourceDeviceID: holder
            )
        )
    }

    private func readyRoot(_ label: String, localDeviceID: String) -> URL {
        let root = temporaryDirectory(label)
        writeLocalDeviceID(localDeviceID, to: root)
        return root
    }

    private func writeLocalDeviceID(_ deviceID: String, to root: URL) {
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try? Data(deviceID.utf8).write(
            to: root.appendingPathComponent("local-device-id"),
            options: .atomic
        )
    }

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-origin-lease-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private static let validDigest =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

private struct RawSnapshotProvider: DomainDeviceSnapshotProvider {
    let snapshot: TatwoDomainDeviceSnapshotV1?

    func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1? {
        snapshot
    }
}

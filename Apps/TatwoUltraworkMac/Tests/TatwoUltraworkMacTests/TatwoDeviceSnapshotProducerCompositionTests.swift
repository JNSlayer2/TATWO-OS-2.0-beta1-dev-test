import Foundation
import TatwoDeviceSyncCore
import TatwoDomainContracts
import XCTest

@testable import TatwoUltraworkMac

final class TatwoDeviceSnapshotProducerCompositionTests: XCTestCase {
    private static let secret = String(repeating: "s", count: 48)

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "producer-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(url)
        return url
    }

    @MainActor
    private func makeProducer(
        syncCore: TatwoDeviceSyncCore? = nil,
        stateRootURL: URL,
        domainID: String = "studio",
        receiptHashSink: @escaping (String?) -> Void = { _ in }
    ) -> TatwoDeviceSnapshotProducer {
        TatwoDeviceSnapshotProducer(
            syncCore: syncCore ?? TatwoDeviceSyncCore(domainID: domainID),
            deviceDisplayName: "Test Mac",
            deviceKind: .macMini,
            stateRootURL: stateRootURL,
            domainID: domainID,
            receiptHashSink: receiptHashSink
        )
    }

    // MARK: - Local device id persistence

    @MainActor
    func testLocalDeviceIDIsPersistedAndReusedAcrossProducers() throws {
        let stateRoot = try makeTemporaryDirectory()

        let first = makeProducer(stateRootURL: stateRoot)
        XCTAssertFalse(first.localDeviceID.isEmpty)
        XCTAssertNil(first.lastErrorDescription)

        let fileURL = stateRoot.appendingPathComponent(
            TatwoDeviceSnapshotProducer.localDeviceIDFileName
        )
        let stored = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(stored, first.localDeviceID)

        let second = makeProducer(stateRootURL: stateRoot)
        XCTAssertEqual(second.localDeviceID, first.localDeviceID)
    }

    @MainActor
    func testLocalDeviceIDFailsSoftToSessionUUIDWhenRootIsUnwritable() throws {
        let parent = try makeTemporaryDirectory()
        let blockerFile = parent.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blockerFile)
        // A state root nested under a plain file can be neither read nor
        // created, so persistence must fail.
        let unwritableRoot = blockerFile.appendingPathComponent(
            "state",
            isDirectory: true
        )

        let first = makeProducer(stateRootURL: unwritableRoot)
        XCTAssertNotNil(UUID(uuidString: first.localDeviceID))
        XCTAssertNotNil(first.lastErrorDescription)

        // Session-scoped fallback: a second producer gets a fresh UUID.
        let second = makeProducer(stateRootURL: unwritableRoot)
        XCTAssertNotEqual(second.localDeviceID, first.localDeviceID)
    }

    // MARK: - Tick behavior

    @MainActor
    func testTickRegistersDevicePublishesRealHashAndPersistsSnapshot() throws {
        let stateRoot = try makeTemporaryDirectory()
        let ledgerRoot = stateRoot.appendingPathComponent(
            "domain-ledger",
            isDirectory: true
        )
        let persistence = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: ledgerRoot,
            createRootIfMissing: true
        )
        let hashRelay = TatwoSnapshotProducerReceiptHashRelay()
        let syncCore = TatwoDeviceSyncCore(
            domainID: "studio",
            snapshotProducerReceiptSHA256: { hashRelay.value },
            persistenceAdapter: persistence
        )
        let producer = makeProducer(
            syncCore: syncCore,
            stateRootURL: stateRoot,
            receiptHashSink: { hashRelay.value = $0 }
        )

        producer.tick()

        let hash = try XCTUnwrap(hashRelay.value)
        XCTAssertEqual(hash.utf8.count, 64)
        XCTAssertTrue(hash.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        })
        XCTAssertGreaterThan(Set(hash).count, 1)
        XCTAssertNil(producer.lastErrorDescription)

        let snapshot = try XCTUnwrap(syncCore.verifiedSnapshot())
        XCTAssertEqual(snapshot.producerReceiptSHA256, hash)
        XCTAssertEqual(
            snapshot.devices.map(\.id),
            [producer.localDeviceID]
        )
        XCTAssertEqual(snapshot.devices.first?.kind, .macMini)
        XCTAssertEqual(snapshot.devices.first?.displayName, "Test Mac")
        XCTAssertNotNil(snapshot.devices.first?.lastHeartbeatAt)

        // The verified snapshot generation was persisted for the read-only
        // provider path.
        let persisted = try persistence.loadVerifiedSnapshot()
        XCTAssertEqual(persisted.snapshot?.producerReceiptSHA256, hash)
    }

    @MainActor
    func testTickFailsSoftWhenPersistenceAdapterIsMissing() throws {
        let stateRoot = try makeTemporaryDirectory()
        let hashRelay = TatwoSnapshotProducerReceiptHashRelay()
        let syncCore = TatwoDeviceSyncCore(
            domainID: "studio",
            snapshotProducerReceiptSHA256: { hashRelay.value }
        )
        let producer = makeProducer(
            syncCore: syncCore,
            stateRootURL: stateRoot,
            receiptHashSink: { hashRelay.value = $0 }
        )

        producer.tick()

        // Registration succeeded and the real hash was still published…
        XCTAssertEqual(hashRelay.value?.utf8.count, 64)
        // …but the persistence failure is recorded instead of crashing.
        let detail = try XCTUnwrap(producer.lastErrorDescription)
        XCTAssertTrue(detail.contains("persistVerifiedSnapshot"))
    }

    @MainActor
    func testTickRecordsRegisterFailureForMismatchedDomain() throws {
        let stateRoot = try makeTemporaryDirectory()
        let producer = makeProducer(
            syncCore: TatwoDeviceSyncCore(domainID: "other-domain"),
            stateRootURL: stateRoot,
            domainID: "studio"
        )

        producer.tick()

        let detail = try XCTUnwrap(producer.lastErrorDescription)
        XCTAssertTrue(detail.contains("registerDevice"))
    }

    // MARK: - makeInteractiveStack environment gate

    private func makeEnvironment(
        url: String? = "https://coordinator.example.invalid",
        secret: String? = TatwoDeviceSnapshotProducerCompositionTests.secret,
        loopbackFlag: String? = nil,
        domainID: String? = nil,
        deviceKind: String? = "macMini",
        stateDirectory: URL
    ) -> [String: String] {
        var environment: [String: String] = [
            "TATWO_ULTRAWORK_STATE_DIR": stateDirectory.path
        ]
        if let url {
            environment["TATWO_DOMAIN_COORDINATOR_URL"] = url
        }
        if let secret {
            environment["TATWO_DOMAIN_GATEWAY_SECRET"] = secret
        }
        if let loopbackFlag {
            environment["TATWO_DOMAIN_COORDINATOR_ALLOW_LOOPBACK"] = loopbackFlag
        }
        if let domainID {
            environment["TATWO_DOMAIN_ID"] = domainID
        }
        if let deviceKind {
            environment["TATWO_DOMAIN_DEVICE_KIND"] = deviceKind
        }
        return environment
    }

    @MainActor
    private func makeStack(
        environment: [String: String],
        applicationSupportURL: URL
    ) -> TatwoDevicesInteractiveStack? {
        TatwoDevicesCompositionRoot.makeInteractiveStack(
            environment: environment,
            applicationSupportURL: applicationSupportURL,
            deviceDisplayName: "Test Mac"
        )
    }

    @MainActor
    func testMakeInteractiveStackEnvironmentGateMatrix() throws {
        let stateDir = try makeTemporaryDirectory()
        let support = try makeTemporaryDirectory()

        // Missing URL → nil.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(url: nil, stateDirectory: stateDir),
            applicationSupportURL: support
        ))
        // Missing secret → nil.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(secret: nil, stateDirectory: stateDir),
            applicationSupportURL: support
        ))
        // Missing device kind → nil; never guess Mac mini for a MacBook.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(
                deviceKind: nil,
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        // Unknown device kind → nil.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(
                deviceKind: "not-a-device",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        // Secret below 32 bytes → nil.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(
                secret: String(repeating: "s", count: 31),
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        // Unparseable URL → nil.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(
                url: "not a url",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        // https + valid secret → stack.
        XCTAssertNotNil(makeStack(
            environment: makeEnvironment(stateDirectory: stateDir),
            applicationSupportURL: support
        ))
        // Loopback http without the explicit flag → nil.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(
                url: "http://127.0.0.1:18888",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        // Loopback http with flag set to anything but "1" → nil.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(
                url: "http://127.0.0.1:18888",
                loopbackFlag: "true",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        // Loopback http with the flag → stack.
        XCTAssertNotNil(makeStack(
            environment: makeEnvironment(
                url: "http://127.0.0.1:18888",
                loopbackFlag: "1",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        // Non-loopback http stays forbidden even with the flag.
        XCTAssertNil(makeStack(
            environment: makeEnvironment(
                url: "http://" + [192, 168, 1, 10].map(String.init).joined(separator: ".") + ":18888",
                loopbackFlag: "1",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
    }

    @MainActor
    func testMakeInteractiveStackDomainIDDefaultsAndEnvOverride() throws {
        let stateDir = try makeTemporaryDirectory()
        let support = try makeTemporaryDirectory()

        let defaulted = try XCTUnwrap(makeStack(
            environment: makeEnvironment(stateDirectory: stateDir),
            applicationSupportURL: support
        ))
        XCTAssertEqual(defaulted.domainID, "tatwo-primary")

        let overridden = try XCTUnwrap(makeStack(
            environment: makeEnvironment(
                domainID: "env-domain",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))
        XCTAssertEqual(overridden.domainID, "env-domain")

        // The sync core really runs on the configured domain: registering a
        // device for that domain succeeds end to end.
        overridden.producer.tick()
        XCTAssertNil(overridden.producer.lastErrorDescription)
        XCTAssertEqual(
            overridden.syncCore.verifiedSnapshot()?.domainID,
            "env-domain"
        )
    }

    @MainActor
    func testMakeInteractiveStackPreservesMacBookDeviceKind() throws {
        let stateDir = try makeTemporaryDirectory()
        let support = try makeTemporaryDirectory()
        let stack = try XCTUnwrap(makeStack(
            environment: makeEnvironment(
                deviceKind: "macBook",
                stateDirectory: stateDir
            ),
            applicationSupportURL: support
        ))

        stack.producer.tick()

        XCTAssertEqual(
            stack.syncCore.verifiedSnapshot()?.devices.first?.kind,
            .macBook
        )
    }
}

import Foundation
import XCTest
import TatwoDeviceSyncCore
import TatwoDomainContracts
import TatwoUltraworkCore
import TatwoWorkReceiptContracts
@testable import TatwoUltraworkMac

final class DevicesPageModelTests: XCTestCase {
    func testPeerInventoryIngestsChannelReportWithoutSeeding() throws {
        let root = temporaryDirectory("peer-channel-ingest")
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = root
            .appendingPathComponent("device-sync-channel/inventory", isDirectory: true)
        let devices = root
            .appendingPathComponent("device-sync-channel/devices", isDirectory: true)
        try FileManager.default.createDirectory(at: inventory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try """
        {
          "schema": "TatwoDevicePeerInventoryV1",
          "deviceID": "book",
          "hardwareModel": "Mac15,12",
          "chipName": "Apple M3",
          "ramTotalBytes": 17179869184,
          "cpuPercent": 18.0,
          "memoryPressureLevel": "normal",
          "activeLoopCount": 1,
          "timestamp": "2026-08-14T02:10:00Z"
        }
        """.write(
            to: inventory.appendingPathComponent("book.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "name": "MacBook Air",
          "role": "secondary",
          "deviceId": "book",
          "deviceID": "book",
          "enrolledAt": "2026-07-28T00:00:00Z"
        }
        """.write(
            to: devices.appendingPathComponent("MacBook.json"),
            atomically: true,
            encoding: .utf8
        )

        let records = DevicesPagePresentation.loadPeerInventories(appSupportRoot: root)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].deviceID, "book")
        XCTAssertEqual(records[0].registeredName, "MacBook Air")
        XCTAssertEqual(records[0].hardwareModel, "Mac15,12")
        XCTAssertEqual(records[0].chipName, "Apple M3")
        XCTAssertEqual(records[0].cpuPercent, 18)
        XCTAssertNil(
            records.first(where: { $0.hardwareModel == "Mac16,10" }),
            "must not seed static local fixture values"
        )
    }

    func testCompositionIgnoresArbitraryPathAndAllowsInlineFixtureOnlyForSnapshotExport() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let applicationSupport = temporaryDirectory("composition")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            makeSnapshot(
                now: now,
                leases: [makeLease(deviceID: "mini", epoch: 1, now: now)]
            )
        )
        let inline = String(decoding: data, as: UTF8.self)

        let regular = TatwoDevicesCompositionRoot.makeProvider(
            environment: [
                "TATWO_ULTRAWORK_DEVICE_STATE_PATH": "/tmp/forbidden.json",
                "TATWO_ULTRAWORK_DEVICE_STATE_JSON": inline
            ],
            applicationSupportURL: applicationSupport,
            now: { now }
        )
        XCTAssertNil(regular.verifiedSnapshot())

        let export = TatwoDevicesCompositionRoot.makeProvider(
            environment: [
                "TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT": "/tmp/panel.png",
                "TATWO_ULTRAWORK_DEVICE_STATE_PATH": "/tmp/forbidden.json",
                "TATWO_ULTRAWORK_DEVICE_STATE_JSON": inline
            ],
            applicationSupportURL: applicationSupport,
            now: { now }
        )
        XCTAssertEqual(export.verifiedSnapshot()?.domainID, "studio")
    }

    func testIdentityCardsMarkLocalAndRemoteAndKeepPrimaryCrown() {
        let now = Date(timeIntervalSince1970: 2_000)
        let primary = TatwoFlexPrimaryState(
            localDeviceName: "Mac mini",
            currentPrimaryName: "Mac mini",
            epoch: 3,
            changedAt: now
        )
        let inventory = TatwoDeviceHostInventoryV1(
            hardwareModel: "Mac16,10",
            chipName: "Apple M4",
            ramTotalBytes: 24 * 1_024 * 1_024 * 1_024,
            cpuPercent: 18,
            memoryPressureLevel: .normal,
            connectionStatus: .local,
            activeLoopCount: 2
        )
        let cards = DevicesPagePresentation.identityCards(
            primary: primary,
            enrolled: [
                EnrolledDevice(name: "MacBook Air", role: "secondary", enrolledAt: now)
            ],
            verified: [
                makeDevice(id: "mini", name: "Mac mini", kind: .macMini, now: now),
                makeDevice(id: "book", name: "MacBook Air", kind: .macBook, now: now)
            ],
            localInventory: inventory,
            localAppVersion: "0.4.1"
        )

        XCTAssertEqual(cards.map(\.displayName), ["Mac mini", "MacBook Air"])
        XCTAssertEqual(cards[0].isLocal, true)
        XCTAssertEqual(cards[0].isPrimary, true)
        XCTAssertEqual(cards[0].localityLabel, "本機")
        XCTAssertEqual(cards[0].hardwareModel, "Mac16,10")
        XCTAssertEqual(cards[0].chipName, "Apple M4")
        XCTAssertEqual(cards[0].appVersion, "0.4.1")
        XCTAssertEqual(cards[1].isLocal, false)
        XCTAssertEqual(cards[1].isPrimary, false)
        XCTAssertEqual(cards[1].localityLabel, "遠端")
        XCTAssertEqual(cards[1].connection, .syncing)
        XCTAssertNil(cards[1].hardwareModel)
        XCTAssertNil(cards[1].inventoryUpdatedLabel)
        XCTAssertFalse(cards[1].isInventoryStale)
    }

    func testRemoteCardsBindPeerReportedInventoryAndFreshStalenessLabel() {
        let now = Date(timeIntervalSince1970: 1_786_680_000)
        let peer = TatwoDevicePeerInventoryRecordV1(
            deviceID: "book",
            registeredName: "MacBook Air",
            hardwareModel: "Mac15,12",
            chipName: "Apple M3",
            ramTotalBytes: 16 * 1_024 * 1_024 * 1_024,
            cpuPercent: 22,
            memoryPressureLevel: .normal,
            activeLoopCount: 4,
            timestamp: now.addingTimeInterval(-7 * 60),
            ingestedAt: now
        )
        let identity = DevicesPagePresentation.identityCards(
            primary: TatwoFlexPrimaryState(
                localDeviceName: "Mac mini",
                currentPrimaryName: "Mac mini",
                epoch: 1,
                changedAt: now
            ),
            enrolled: [
                EnrolledDevice(
                    name: "MacBook Air",
                    role: "secondary",
                    enrolledAt: now,
                    deviceId: "book"
                )
            ],
            verified: [
                makeDevice(id: "book", name: "MacBook Air", kind: .macBook, now: now)
            ],
            localInventory: nil,
            localAppVersion: nil,
            peerInventories: [peer],
            now: now
        )
        let cards = DevicesPagePresentation.pressureCards(
            identityCards: identity,
            localInventory: nil,
            localProjection: nil,
            peerInventories: [peer],
            now: now
        )

        XCTAssertEqual(identity[1].hardwareModel, "Mac15,12")
        XCTAssertEqual(identity[1].chipName, "Apple M3")
        XCTAssertEqual(identity[1].ramLabel, DevicesPagePresentation.formatRAM(16 * 1_024 * 1_024 * 1_024))
        XCTAssertEqual(identity[1].inventoryUpdatedLabel, "更新於 7 分前")
        XCTAssertFalse(identity[1].isInventoryStale)
        XCTAssertEqual(cards[1].cpuPercentLabel, "22%")
        XCTAssertEqual(cards[1].pressureLevel, .normal)
        XCTAssertEqual(cards[1].activeLoopCount, 4)
        XCTAssertEqual(cards[1].inventoryUpdatedLabel, "更新於 7 分前")
        XCTAssertFalse(cards[1].isInventoryStale)
    }

    func testRemoteCardsDimWhenPeerInventoryOlderThanThirtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_786_680_000)
        let peer = TatwoDevicePeerInventoryRecordV1(
            deviceID: "book",
            registeredName: "MacBook Air",
            hardwareModel: "Mac15,12",
            chipName: "Apple M3",
            ramTotalBytes: 16 * 1_024 * 1_024 * 1_024,
            cpuPercent: 9,
            memoryPressureLevel: .warn,
            activeLoopCount: 1,
            timestamp: now.addingTimeInterval(-31 * 60),
            ingestedAt: now
        )
        let identity = DevicesPagePresentation.identityCards(
            primary: TatwoFlexPrimaryState(
                localDeviceName: "Mac mini",
                currentPrimaryName: "Mac mini",
                epoch: 1,
                changedAt: now
            ),
            enrolled: [
                EnrolledDevice(
                    name: "MacBook Air",
                    role: "secondary",
                    enrolledAt: now,
                    deviceId: "book"
                )
            ],
            verified: [],
            localInventory: nil,
            localAppVersion: nil,
            peerInventories: [peer],
            now: now
        )
        let cards = DevicesPagePresentation.pressureCards(
            identityCards: identity,
            localInventory: nil,
            localProjection: nil,
            peerInventories: [peer],
            now: now
        )

        XCTAssertEqual(identity[1].hardwareModel, "Mac15,12")
        XCTAssertEqual(identity[1].inventoryUpdatedLabel, "更新於 31 分前")
        XCTAssertTrue(identity[1].isInventoryStale)
        XCTAssertEqual(cards[1].cpuPercentLabel, "9%")
        XCTAssertEqual(cards[1].inventoryUpdatedLabel, "更新於 31 分前")
        XCTAssertTrue(cards[1].isInventoryStale)
    }

    func testRemoteCardsDoNotInventInventoryWhenPeerDidNotReport() {
        let now = Date(timeIntervalSince1970: 1_786_680_000)
        let identity = DevicesPagePresentation.identityCards(
            primary: TatwoFlexPrimaryState(
                localDeviceName: "Mac mini",
                currentPrimaryName: "Mac mini",
                epoch: 1,
                changedAt: now
            ),
            enrolled: [
                EnrolledDevice(
                    name: "MacBook Air",
                    role: "secondary",
                    enrolledAt: now,
                    deviceId: "book"
                )
            ],
            verified: [],
            localInventory: TatwoDeviceHostInventoryV1(
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramTotalBytes: 24 * 1_024 * 1_024 * 1_024,
                cpuPercent: 11,
                memoryPressureLevel: .normal,
                connectionStatus: .local,
                activeLoopCount: 1
            ),
            localAppVersion: nil,
            peerInventories: [],
            now: now
        )
        let cards = DevicesPagePresentation.pressureCards(
            identityCards: identity,
            localInventory: TatwoDeviceHostInventoryV1(
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramTotalBytes: 24 * 1_024 * 1_024 * 1_024,
                cpuPercent: 11,
                memoryPressureLevel: .normal,
                connectionStatus: .local,
                activeLoopCount: 1
            ),
            localProjection: nil,
            peerInventories: [],
            now: now
        )

        XCTAssertEqual(identity[0].hardwareModel, "Mac16,10")
        XCTAssertNil(identity[1].hardwareModel)
        XCTAssertNil(identity[1].chipName)
        XCTAssertNil(identity[1].inventoryUpdatedLabel)
        XCTAssertFalse(identity[1].isInventoryStale)
        XCTAssertNil(cards[1].cpuPercentLabel)
        XCTAssertNil(cards[1].pressureLevel)
        XCTAssertNil(cards[1].activeLoopCount)
        XCTAssertNil(cards[1].inventoryUpdatedLabel)
    }

    func testDataModuleRowsUseRegistrySectionAndExcludeThreadsToggle() throws {
        let registry = try XCTUnwrap(TatwoDevicesCompositionRoot.makeSyncModulesRegistry())
        let rows = DevicesPagePresentation.dataModuleRows(
            resolved: registry.modules.map { definition in
                TatwoSyncModuleResolvedV1(
                    definition: definition,
                    enabled: definition.enabled,
                    runtime: TatwoSyncModuleRuntimeRecordV1(
                        moduleID: definition.id,
                        state: definition.id == "governance-docs" ? .syncing
                            : definition.id == "memory-sync" ? .failed : .idle,
                        reason: definition.id == "memory-sync" ? "adapter missing" : nil
                    )
                )
            }
        )

        XCTAssertEqual(rows.map(\.id), [
            DevicesPagePresentation.skilletPresentedID,
            "model-collab-presets",
            "governance-docs",
        ])
        XCTAssertFalse(rows.contains { $0.id == "cli-version" || $0.id == "os-app-version" })
        XCTAssertFalse(rows.contains { $0.id == "goal-state" || $0.id == "threads" })
        XCTAssertFalse(rows.contains { $0.id == "mcp-plugin-registry" || $0.id == "memory-sync" })
        XCTAssertFalse(rows.contains { $0.id == "skillet-bundle-lane" || $0.id == "os-skillet-md" })
        let skillet = try XCTUnwrap(rows.first { $0.id == DevicesPagePresentation.skilletPresentedID })
        XCTAssertEqual(skillet.titleZh, "Skillet 技能")
        XCTAssertEqual(skillet.plainZh, DevicesPagePresentation.skilletPlainZh)
        XCTAssertFalse(skillet.excluded)
        XCTAssertTrue(skillet.enabled)
        XCTAssertEqual(skillet.sourceModuleIDs, DevicesPagePresentation.skilletSourceModuleIDs)
        XCTAssertEqual(
            DevicesPagePresentation.enablementModuleIDs(forPresentedID: skillet.id),
            ["skillet-bundle-lane", "os-skillet-md"]
        )
        let syncing = try XCTUnwrap(rows.first { $0.id == "governance-docs" })
        XCTAssertTrue(syncing.isSyncing)
        XCTAssertEqual(
            DevicesPagePresentation.cliVersionInfo(registry: registry)?.titleZh,
            "CLI 版本"
        )
    }

    func testVersionRowsBindAutosyncHeadAndPerDeviceChecking() {
        let cards = [
            DevicesIdentityCardModel(
                id: "mini",
                displayName: "Mac mini",
                isLocal: true,
                isPrimary: true,
                connection: .connected,
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramLabel: "24 GB",
                appVersion: "0.4.1",
                inventoryUpdatedLabel: nil,
                isInventoryStale: false
            ),
            DevicesIdentityCardModel(
                id: "book",
                displayName: "MacBook Air",
                isLocal: false,
                isPrimary: false,
                connection: .connected,
                hardwareModel: nil,
                chipName: nil,
                ramLabel: nil,
                appVersion: nil,
                inventoryUpdatedLabel: nil,
                isInventoryStale: false
            ),
        ]
        let now = Date(timeIntervalSince1970: 1_785_542_400)
        let rows = DevicesPagePresentation.versionRows(
            cards: cards,
            autosync: TatwoAutosyncStatusSnapshot(
                lastInstalledCommit: "deadbeefcafe",
                lastCheckAt: now.addingTimeInterval(-120)
            ),
            versionReceipts: [
                DeviceSyncReceipt(
                    target: "MacBook Air",
                    action: "version-pull",
                    requestedAt: now.addingTimeInterval(-90),
                    result: "converged",
                    completedAt: now.addingTimeInterval(-30),
                    message: "verified",
                    sourceDigest: "ffffffffffffffff",
                    appliedDigest: "1111111111111111"
                )
            ],
            checkingDeviceNames: ["MacBook Air"],
            now: now
        )

        XCTAssertEqual(rows[0].appVersion, "0.4.1")
        XCTAssertEqual(rows[0].releaseHead, "deadbeefcafe")
        XCTAssertFalse(rows[0].isChecking)
        XCTAssertEqual(rows[1].appVersion, "111111111111")
        XCTAssertEqual(rows[1].releaseHead, "deadbeefcafe")
        XCTAssertTrue(rows[1].isChecking)
        XCTAssertEqual(rows[1].lastCheckLabel, DevicesPagePresentation.formatLastCheck(
            now.addingTimeInterval(-30),
            now: now
        ))
    }

    func testPressureCardsExposeInventoryAndKeepDispatchOnRemoteOnly() {
        let identity = DevicesPagePresentation.identityCards(
            primary: TatwoFlexPrimaryState(
                localDeviceName: "Mac mini",
                currentPrimaryName: "Mac mini",
                epoch: 1,
                changedAt: Date(timeIntervalSince1970: 10)
            ),
            enrolled: [
                EnrolledDevice(
                    name: "MacBook Air",
                    role: "secondary",
                    enrolledAt: Date(timeIntervalSince1970: 1)
                )
            ],
            verified: [],
            localInventory: TatwoDeviceHostInventoryV1(
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramTotalBytes: 32 * 1_024 * 1_024 * 1_024,
                cpuPercent: 41.2,
                memoryPressureLevel: .warn,
                connectionStatus: .local,
                activeLoopCount: 3
            ),
            localAppVersion: "0.4.1"
        )
        let inventory = TatwoDeviceHostInventoryV1(
            hardwareModel: "Mac16,10",
            chipName: "Apple M4",
            ramTotalBytes: 32 * 1_024 * 1_024 * 1_024,
            cpuPercent: 41.2,
            memoryPressureLevel: .warn,
            connectionStatus: .local,
            activeLoopCount: 3
        )
        let projection = TatwoPressureUIProjectionV1(
            deviceID: "mini",
            displayClassification: .yellow,
            lastObservedAt: Date(timeIntervalSince1970: 20),
            activeLoopID: "loop-a",
            workerIDs: ["w1"],
            stopReason: nil,
            canRequestLightLoop: true,
            canRequestHeavyLoop: false,
            hostInventory: inventory
        )
        let cards = DevicesPagePresentation.pressureCards(
            identityCards: identity,
            localInventory: inventory,
            localProjection: projection
        )

        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].localityLabel, "本機")
        XCTAssertEqual(cards[0].cpuPercentLabel, "41%")
        XCTAssertEqual(cards[0].pressureLevel, .warn)
        XCTAssertEqual(cards[0].activeLoopCount, 3)
        XCTAssertEqual(cards[0].canRequestLightLoop, true)
        XCTAssertEqual(cards[0].canRequestHeavyLoop, false)
        XCTAssertFalse(cards[0].showsDispatch)
        XCTAssertEqual(cards[1].localityLabel, "遠端")
        XCTAssertTrue(cards[1].showsDispatch)
        XCTAssertNil(cards[1].canRequestLightLoop)
    }

    func testLocalIdentityReadsInfoPlistVersionAndSourceCommit() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.4.1",
            "TatwoSourceCommit": "cafebabedeadbeefcafebabedeadbeefcafebabe",
        ]
        XCTAssertEqual(
            DevicesPagePresentation.localAppVersion(infoDictionary: info),
            "0.4.1"
        )
        XCTAssertEqual(
            DevicesPagePresentation.localSourceCommit(infoDictionary: info),
            "cafebabedead"
        )
        XCTAssertEqual(
            DevicesPagePresentation.localAppVersion(infoDictionary: [
                "TatwoSourceCommit": "cafebabedeadbeefcafebabedeadbeefcafebabe"
            ]),
            "cafebabedead"
        )
    }

    func testLocalDeviceStaysOnlineWithoutInventoryOrDomain() {
        let cards = DevicesPagePresentation.identityCards(
            primary: TatwoFlexPrimaryState(
                localDeviceName: "Mac mini",
                currentPrimaryName: "Mac mini",
                epoch: 1,
                changedAt: Date(timeIntervalSince1970: 10)
            ),
            enrolled: [],
            verified: [],
            localInventory: nil,
            localAppVersion: nil
        )
        XCTAssertEqual(cards[0].connection, .connected)
        XCTAssertEqual(cards[0].connection.label, "在線")
    }

    func testPressureCardsPreferCollectorHardwareOverEmptyProjection() {
        let identity = DevicesPagePresentation.identityCards(
            primary: TatwoFlexPrimaryState(
                localDeviceName: "Mac mini",
                currentPrimaryName: "Mac mini",
                epoch: 1,
                changedAt: Date(timeIntervalSince1970: 10)
            ),
            enrolled: [],
            verified: [],
            localInventory: TatwoDeviceHostInventoryV1(
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramTotalBytes: 24 * 1_024 * 1_024 * 1_024,
                cpuPercent: nil,
                memoryPressureLevel: .normal,
                connectionStatus: .local,
                activeLoopCount: 1
            ),
            localAppVersion: "0.4.1"
        )
        let cards = DevicesPagePresentation.pressureCards(
            identityCards: identity,
            localInventory: TatwoDeviceHostInventoryV1(
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramTotalBytes: 24 * 1_024 * 1_024 * 1_024,
                cpuPercent: nil,
                memoryPressureLevel: .normal,
                connectionStatus: .local,
                activeLoopCount: 1
            ),
            localProjection: TatwoPressureUIProjectionV1(
                deviceID: "mini",
                displayClassification: .unknown,
                lastObservedAt: nil,
                activeLoopID: nil,
                workerIDs: [],
                stopReason: "monitor_unknown",
                canRequestLightLoop: false,
                canRequestHeavyLoop: false,
                hostInventory: nil
            )
        )

        XCTAssertEqual(cards[0].hardwareModel, "Mac16,10")
        XCTAssertEqual(cards[0].chipName, "Apple M4")
        XCTAssertEqual(cards[0].ramLabel, DevicesPagePresentation.formatRAM(24 * 1_024 * 1_024 * 1_024))
        XCTAssertNil(cards[0].cpuPercentLabel)
        XCTAssertEqual(cards[0].connection, .connected)
        XCTAssertEqual(cards[0].connection.label, "在線")
        XCTAssertEqual(cards[0].pressureLevel, .normal)
        XCTAssertEqual(cards[0].activeLoopCount, 1)
    }

    func testDataModuleRowsLoadFromBundledRegistryWithoutEnablementFile() throws {
        let registry = try XCTUnwrap(TatwoDevicesCompositionRoot.makeSyncModulesRegistry())
        let isolated = temporaryDirectory("empty-enablement")
        defer { try? FileManager.default.removeItem(at: isolated) }
        let rows = DevicesPagePresentation.dataModuleRows(
            registry: registry,
            enablement: TatwoSyncModuleEnablementStore(
                fileURL: isolated.appendingPathComponent("sync-modules.enablement.v1.json")
            ),
            runtime: TatwoSyncModuleRuntimeStateStore(
                fileURL: isolated.appendingPathComponent("sync-modules.runtime.v1.json")
            )
        )
        XCTAssertEqual(rows.map(\.id), [
            DevicesPagePresentation.skilletPresentedID,
            "model-collab-presets",
            "governance-docs",
        ])
        let skillet = try XCTUnwrap(rows.first { $0.id == DevicesPagePresentation.skilletPresentedID })
        XCTAssertFalse(skillet.excluded)
        XCTAssertTrue(skillet.enabled)
        XCTAssertEqual(skillet.sourceModuleIDs, ["skillet-bundle-lane", "os-skillet-md"])
        XCTAssertNil(rows.first { $0.id == "threads" })
        XCTAssertNil(rows.first { $0.id == "goal-state" })
    }

    func testVersionRowsFallbackToLocalInstallHeadWhenInfoPlistMissing() {
        let cards = [
            DevicesIdentityCardModel(
                id: "mini",
                displayName: "Mac mini",
                isLocal: true,
                isPrimary: true,
                connection: .connected,
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramLabel: "24 GB",
                appVersion: nil,
                inventoryUpdatedLabel: nil,
                isInventoryStale: false
            ),
        ]
        let now = Date(timeIntervalSince1970: 1_785_542_400)
        let rows = DevicesPagePresentation.versionRows(
            cards: cards,
            autosync: TatwoAutosyncStatusSnapshot(
                lastInstalledCommit: "aaaaaaaaaaaa",
                lastCheckAt: now
            ),
            versionReceipts: [],
            checkingDeviceNames: [],
            now: now
        )
        XCTAssertEqual(rows[0].appVersion, "aaaaaaaaaaaa")
        XCTAssertEqual(rows[0].releaseHead, "aaaaaaaaaaaa")
        XCTAssertNotEqual(rows[0].appVersion, DevicesPagePresentation.unknownVersion)
    }

    func testAutosyncReaderParsesCommitAndLogTimestamp() throws {
        let root = temporaryDirectory("autosync-status")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "cafebabedeadbeef\n".write(
            to: root.appendingPathComponent("last-installed-commit"),
            atomically: true,
            encoding: .utf8
        )
        try "2026-08-14T01:02:03Z result=ok\nnot-a-date ignored\n".write(
            to: root.appendingPathComponent("autosync.log"),
            atomically: true,
            encoding: .utf8
        )

        let status = TatwoAutosyncStatusReader.read(appSupportRoot: root)
        XCTAssertEqual(status.lastInstalledCommit, "cafebabedead")
        XCTAssertEqual(
            status.lastCheckAt,
            ISO8601DateFormatter().date(from: "2026-08-14T01:02:03Z")
        )
    }

    func testCompositionReadsOnlyTypedPersistedSnapshotFromCanonicalApplicationSupportRoot() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let applicationSupport = temporaryDirectory("persisted-composition")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let persistenceRoot = applicationSupport
            .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
            .appendingPathComponent("state/domain-ledger", isDirectory: true)
        let writer = try TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: persistenceRoot,
            now: { now }
        )
        let expected = makeSnapshot(
            now: now,
            leases: [makeLease(deviceID: "mini", epoch: 1, now: now)]
        )
        try writer.persistVerifiedSnapshot(expected)

        let provider = TatwoDevicesCompositionRoot.makeProvider(
            environment: [
                "TATWO_ULTRAWORK_DEVICE_STATE_PATH": "/tmp/ignored.json"
            ],
            applicationSupportURL: applicationSupport,
            now: { now }
        )

        XCTAssertEqual(provider.verifiedSnapshot(), expected)
    }

    func testBatchInclusionDefaultsOnPersistsExcludedAndDisablesActionWhenAllOff() {
        XCTAssertEqual(
            DevicesBatchInclusionStore.versionExcludedKey,
            "tatwo.devices.batchInclusion.version.excluded"
        )
        XCTAssertEqual(
            DevicesBatchInclusionStore.dataExcludedKey,
            "tatwo.devices.batchInclusion.data.excluded"
        )
        XCTAssertEqual(
            DevicesBatchInclusionKind.version.excludedDefaultsKey,
            DevicesBatchInclusionStore.versionExcludedKey
        )
        XCTAssertEqual(
            DevicesBatchInclusionKind.data.excludedDefaultsKey,
            DevicesBatchInclusionStore.dataExcludedKey
        )

        let suite = "tatwo.devices.batchInclusion.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let devices = ["Mac mini", "MacBook Air"]
        XCTAssertTrue(DevicesBatchInclusionStore.loadExcluded(kind: .version, defaults: defaults).isEmpty)
        XCTAssertTrue(
            DevicesBatchInclusionStore.actionEnabled(deviceNames: devices, excluded: [])
        )
        XCTAssertEqual(
            DevicesBatchInclusionStore.selectedDeviceNames(devices, excluded: []),
            devices
        )

        var excluded: Set<String> = []
        DevicesBatchInclusionStore.setIncluded(false, deviceName: "MacBook Air", excluded: &excluded)
        XCTAssertFalse(
            DevicesBatchInclusionStore.isIncluded(deviceName: "MacBook Air", excluded: excluded)
        )
        XCTAssertTrue(
            DevicesBatchInclusionStore.isIncluded(deviceName: "Mac mini", excluded: excluded)
        )
        XCTAssertEqual(
            DevicesBatchInclusionStore.selectedDeviceNames(devices, excluded: excluded),
            ["Mac mini"]
        )
        DevicesBatchInclusionStore.saveExcluded(excluded, kind: .version, defaults: defaults)
        XCTAssertEqual(
            DevicesBatchInclusionStore.loadExcluded(kind: .version, defaults: defaults),
            ["MacBook Air"]
        )

        DevicesBatchInclusionStore.setIncluded(false, deviceName: "Mac mini", excluded: &excluded)
        XCTAssertFalse(
            DevicesBatchInclusionStore.actionEnabled(deviceNames: devices, excluded: excluded)
        )
        XCTAssertTrue(
            DevicesBatchInclusionStore.selectedDeviceNames(devices, excluded: excluded).isEmpty
        )
        DevicesBatchInclusionStore.saveExcluded(excluded, kind: .data, defaults: defaults)
        XCTAssertEqual(
            DevicesBatchInclusionStore.loadExcluded(kind: .data, defaults: defaults),
            Set(devices)
        )
        XCTAssertTrue(
            DevicesBatchInclusionStore.isIncluded(deviceName: "New Device", excluded: excluded),
            "new devices stay included by default"
        )
    }

    func testDataDeviceRowsBindPerDeviceStatusAndFailureWithoutProgressWall() {
        let cards = [
            DevicesIdentityCardModel(
                id: "mini",
                displayName: "Mac mini",
                isLocal: true,
                isPrimary: true,
                connection: .connected,
                hardwareModel: "Mac16,10",
                chipName: "Apple M4",
                ramLabel: "24 GB",
                appVersion: "0.4.1",
                inventoryUpdatedLabel: nil,
                isInventoryStale: false
            ),
            DevicesIdentityCardModel(
                id: "book",
                displayName: "MacBook Air",
                isLocal: false,
                isPrimary: false,
                connection: .connected,
                hardwareModel: nil,
                chipName: nil,
                ramLabel: nil,
                appVersion: nil,
                inventoryUpdatedLabel: nil,
                isInventoryStale: false
            ),
        ]
        let now = Date(timeIntervalSince1970: 1_785_542_400)
        let rows = DevicesPagePresentation.dataDeviceRows(
            cards: cards,
            dataReceipts: [
                DeviceSyncReceipt(
                    target: "MacBook Air",
                    action: "system-pull",
                    requestedAt: now.addingTimeInterval(-90),
                    result: "failure",
                    completedAt: now.addingTimeInterval(-30),
                    message: "signature mismatch\nengine detail"
                ),
            ],
            syncingDeviceNames: ["Mac mini"],
            now: now
        )

        XCTAssertEqual(rows.map(\.deviceName), ["Mac mini", "MacBook Air"])
        XCTAssertTrue(rows[0].isSyncing)
        XCTAssertFalse(rows[0].isFailed)
        XCTAssertNil(rows[0].statusLabel)
        XCTAssertFalse(rows[1].isSyncing)
        XCTAssertTrue(rows[1].isFailed)
        XCTAssertEqual(rows[1].statusLabel, "signature mismatch")
    }

    func testVersionRowsMarkFailedReceiptOnStatusLine() {
        let cards = [
            DevicesIdentityCardModel(
                id: "book",
                displayName: "MacBook Air",
                isLocal: false,
                isPrimary: false,
                connection: .connected,
                hardwareModel: nil,
                chipName: nil,
                ramLabel: nil,
                appVersion: nil,
                inventoryUpdatedLabel: nil,
                isInventoryStale: false
            ),
        ]
        let now = Date(timeIntervalSince1970: 1_785_542_400)
        let rows = DevicesPagePresentation.versionRows(
            cards: cards,
            autosync: .empty,
            versionReceipts: [
                DeviceSyncReceipt(
                    target: "MacBook Air",
                    action: "version-pull",
                    requestedAt: now.addingTimeInterval(-40),
                    result: "failure",
                    completedAt: now.addingTimeInterval(-10),
                    message: "os-image conflict"
                ),
            ],
            checkingDeviceNames: [],
            now: now
        )
        XCTAssertTrue(rows[0].isFailed)
        XCTAssertEqual(rows[0].lastCheckLabel, "os-image conflict")
        XCTAssertFalse(rows[0].isChecking)
    }

    func testSkilletRowsMergeAndTakeWorseRuntimeState() throws {
        let registry = try XCTUnwrap(TatwoDevicesCompositionRoot.makeSyncModulesRegistry())
        let rows = DevicesPagePresentation.dataModuleRows(
            resolved: registry.modules.map { definition in
                TatwoSyncModuleResolvedV1(
                    definition: definition,
                    enabled: definition.id == "os-skillet-md",
                    runtime: TatwoSyncModuleRuntimeRecordV1(
                        moduleID: definition.id,
                        state: definition.id == "skillet-bundle-lane" ? .failed : .syncing,
                        reason: definition.id == "skillet-bundle-lane" ? "lane rejected" : nil
                    )
                )
            }
        )
        let skillet = try XCTUnwrap(rows.first { $0.id == DevicesPagePresentation.skilletPresentedID })
        XCTAssertTrue(skillet.enabled, "either module on => presented on")
        XCTAssertTrue(skillet.isFailed, "failed beats syncing")
        XCTAssertFalse(skillet.isSyncing)
        XCTAssertEqual(skillet.failureReason, "lane rejected")
        XCTAssertEqual(skillet.sourceModuleIDs, ["skillet-bundle-lane", "os-skillet-md"])
        XCTAssertEqual(rows.filter { $0.id == skillet.id }.count, 1)
    }

    func testBorrowTargetDeviceIDPrefersInventoryWhenDomainSnapshotIsEmpty() {
        let peer = TatwoDevicePeerInventoryRecordV1(
            deviceID: "7C09A998AABB",
            registeredName: "TATWO",
            hardwareModel: "Mac15,12",
            chipName: "Apple M3",
            ramTotalBytes: 16 * 1_024 * 1_024 * 1_024,
            cpuPercent: 8,
            memoryPressureLevel: .normal,
            activeLoopCount: 0,
            timestamp: Date(timeIntervalSince1970: 1_786_680_000),
            ingestedAt: Date(timeIntervalSince1970: 1_786_680_060)
        )
        XCTAssertEqual(
            DevicesPagePresentation.borrowTargetDeviceID(
                displayName: "TATWO",
                verified: [],
                enrolled: [
                    EnrolledDevice(
                        name: "TATWO",
                        role: "secondary",
                        enrolledAt: Date(timeIntervalSince1970: 1)
                    )
                ],
                peerInventories: [peer]
            ),
            "7C09A998AABB"
        )
        XCTAssertNil(
            DevicesPagePresentation.borrowTargetDeviceID(
                displayName: "TATWO",
                verified: [],
                enrolled: [
                    EnrolledDevice(
                        name: "TATWO",
                        role: "secondary",
                        enrolledAt: Date(timeIntervalSince1970: 1)
                    )
                ],
                peerInventories: []
            )
        )
        XCTAssertEqual(
            DevicesPagePresentation.borrowTargetDeviceID(
                displayName: "TATWO",
                verified: [
                    makeDevice(
                        id: "domain-tatwo",
                        name: "TATWO",
                        kind: .macBook,
                        now: Date(timeIntervalSince1970: 2)
                    )
                ],
                enrolled: [],
                peerInventories: [peer]
            ),
            "domain-tatwo"
        )
        XCTAssertEqual(
            DevicesPagePresentation.admissionCaption(
                canRequestLight: true,
                canRequestHeavy: false
            ),
            "可接輕型工作 · 不接重型工作"
        )
    }

    func testIdentityCardIDFallsBackToPeerInventoryWithoutVerifiedSnapshot() {
        let now = Date(timeIntervalSince1970: 1_786_680_000)
        let cards = DevicesPagePresentation.identityCards(
            primary: TatwoFlexPrimaryState(
                localDeviceName: "Mac mini",
                currentPrimaryName: "Mac mini",
                epoch: 1,
                changedAt: now
            ),
            enrolled: [
                EnrolledDevice(
                    name: "TATWO",
                    role: "secondary",
                    enrolledAt: now
                )
            ],
            verified: [],
            localInventory: nil,
            localAppVersion: nil,
            peerInventories: [
                TatwoDevicePeerInventoryRecordV1(
                    deviceID: "7C09A998AABB",
                    registeredName: "TATWO",
                    hardwareModel: "Mac15,12",
                    chipName: "Apple M3",
                    ramTotalBytes: 16 * 1_024 * 1_024 * 1_024,
                    cpuPercent: 4,
                    memoryPressureLevel: .normal,
                    activeLoopCount: 0,
                    timestamp: now.addingTimeInterval(-60),
                    ingestedAt: now
                )
            ],
            now: now
        )
        XCTAssertEqual(cards[1].displayName, "TATWO")
        XCTAssertEqual(cards[1].id, "7C09A998AABB")
    }

    func testDevicesNameplateAndHiddenDeferredModulesArePresentationOnly() throws {
        let repoRoot = try findRepoRoot()
        let appShell = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift"
            ),
            encoding: .utf8
        )
        let card = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceCrossSyncCard.swift"
            ),
            encoding: .utf8
        )
        let composition = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicesComposition.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(appShell.contains("selection != .devices"))
        XCTAssertTrue(card.contains("DevicesPagePresentation.nameplateTitle"))
        XCTAssertTrue(card.contains("DevicesPagePresentation.nameplateSubtitle"))
        XCTAssertTrue(card.contains("Divider().opacity(0.25)"))
        XCTAssertTrue(composition.contains("deferredDataModuleIDs"))
        XCTAssertTrue(composition.contains("\"goal-state\""))
        XCTAssertFalse(composition.contains("\"id\": \"goal-state\""))
    }

    private func findRepoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            let marker = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory
            }
        }
        throw XCTSkip("repo root not found from test file")
    }

    private func makeSnapshot(
        now: Date,
        leases: [TatwoAuthorityLeaseV1]
    ) -> TatwoDomainDeviceSnapshotV1 {
        TatwoDomainDeviceSnapshotV1(
            protocolVersion: 1,
            domainID: "studio",
            producerHealth: .healthy,
            producerReceiptSHA256:
                "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            observedAt: now,
            devices: [
                makeDevice(id: "mini", name: "Mac mini", kind: .macMini, now: now),
                makeDevice(id: "book", name: "MacBook", kind: .macBook, now: now)
            ],
            authorityLeases: leases
        )
    }

    private func makeDevice(
        id: String,
        name: String,
        kind: TatwoDomainDeviceKindV1,
        now: Date
    ) -> TatwoDomainDeviceV1 {
        TatwoDomainDeviceV1(
            id: id,
            domainID: "studio",
            displayName: name,
            kind: kind,
            connectionState: id == "book" ? .syncing : .connected,
            schemaVersion: 1,
            protocolVersion: 1,
            registeredAt: now,
            lastHeartbeatAt: now
        )
    }

    private func makeLease(
        deviceID: String,
        epoch: UInt64,
        now: Date
    ) -> TatwoAuthorityLeaseV1 {
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

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-devices-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}

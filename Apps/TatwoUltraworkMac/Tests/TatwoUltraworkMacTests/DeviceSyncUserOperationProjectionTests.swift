import Foundation
import XCTest
@testable import TatwoUltraworkMac

final class DeviceSyncUserOperationProjectionTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReducerShowsExactlyOneUserOperationPerTargetAcrossActions() throws {
        let target = "macbook-m3"
        let pending = DeviceSyncIntent(
            target: target,
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 30)
        )
        let versionReceipt = makeReceipt(
            target: target,
            action: "version-pull",
            phase: .delivered,
            requestID: "version-current",
            ledgerSequence: 20
        )

        let projections = DeviceSyncUserOperationReducer.project(
            pending: DeviceSyncOperationIndex.latestPending([pending]),
            receipts: DeviceSyncOperationIndex.latestReceipts([versionReceipt])
        )

        let projection = try XCTUnwrap(projections.first)
        XCTAssertEqual(projections.count, 1)
        XCTAssertEqual(projection.target, target)
        XCTAssertEqual(projection.operationKeys.count, 2)
        XCTAssertEqual(projection.operationLabel, "OS 資料＋來源版本")
        XCTAssertEqual(projection.stage, .preparing)
        XCTAssertEqual(projection.outcome, .active)
        XCTAssertEqual(projection.statusLabel, "正在準備同步")
    }

    func testOnlyRealByteTransferShowsNumericPercent() throws {
        let measured = makeReceipt(
            phase: .transferring,
            requestID: "request-measured",
            progress: DeviceSyncProgressPayload(
                completedBytes: 1_024,
                totalBytes: 4_096
            )
        )
        let phaseOnly = makeReceipt(
            target: "other-device",
            phase: .transferring,
            requestID: "request-phase-only"
        )

        let projections = DeviceSyncUserOperationReducer.project(
            pending: [:],
            receipts: DeviceSyncOperationIndex.latestReceipts([
                measured,
                phaseOnly,
            ])
        )

        let measuredProjection = try XCTUnwrap(
            projections.first { $0.target == measured.target }
        )
        XCTAssertEqual(measuredProjection.stage, .transferring)
        XCTAssertEqual(measuredProjection.measuredTransferProgress?.fraction, 0.25)
        XCTAssertEqual(measuredProjection.measuredTransferProgress?.percentLabel, "25%")

        let phaseOnlyProjection = try XCTUnwrap(
            projections.first { $0.target == phaseOnly.target }
        )
        XCTAssertEqual(phaseOnlyProjection.stage, .transferring)
        XCTAssertNil(phaseOnlyProjection.measuredTransferProgress)
    }

    func testTwoSameTargetActionsAggregateMeasuredBytesIntoOneProgress() throws {
        let target = "macbook-aggregate"
        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([
                    makeReceipt(
                        target: target,
                        action: "system-pull",
                        phase: .transferring,
                        requestID: "request-system",
                        ledgerSequence: 20,
                        progress: DeviceSyncProgressPayload(
                            completedBytes: 1_024,
                            totalBytes: 4_096)),
                    makeReceipt(
                        target: target,
                        action: "version-pull",
                        phase: .transferring,
                        requestID: "request-version",
                        ledgerSequence: 21,
                        progress: DeviceSyncProgressPayload(
                            completedBytes: 2_048,
                            totalBytes: 2_048)),
                ])
            ).first
        )

        let progress = try XCTUnwrap(projection.measuredTransferProgress)
        XCTAssertEqual(projection.operationKeys.count, 2)
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertEqual(progress.percentLabel, "50%")
        XCTAssertEqual(
            progress.detailLabel,
            byteDetail(completed: 3_072, total: 6_144)
        )
    }

    func testMixedInvalidBytePayloadsDoNotManufactureAggregateProgress() throws {
        let target = "macbook-mixed-progress"
        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([
                    makeReceipt(
                        target: target,
                        action: "system-pull",
                        phase: .transferring,
                        requestID: "request-valid",
                        ledgerSequence: 30,
                        progress: DeviceSyncProgressPayload(
                            completedBytes: 256,
                            totalBytes: 1_024)),
                    makeReceipt(
                        target: target,
                        action: "version-pull",
                        phase: .transferring,
                        requestID: "request-invalid",
                        ledgerSequence: 31,
                        progress: DeviceSyncProgressPayload(
                            completedBytes: 2_048,
                            totalBytes: 1_024)),
                    makeReceipt(
                        target: target,
                        action: "db-pull",
                        phase: .transferring,
                        requestID: "request-incomplete",
                        ledgerSequence: 32,
                        progress: DeviceSyncProgressPayload(
                            completedBytes: 512)),
                ])
            ).first
        )

        let progress = try XCTUnwrap(projection.measuredTransferProgress)
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertEqual(progress.percentLabel, "25%")
        XCTAssertEqual(
            progress.detailLabel,
            byteDetail(completed: 256, total: 1_024)
        )
    }

    func testCompletedMeasuredPayloadsProduceCompletedAggregateProgress() throws {
        let target = "macbook-complete-progress"
        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([
                    makeReceipt(
                        target: target,
                        action: "system-pull",
                        phase: .transferring,
                        requestID: "request-system-complete",
                        ledgerSequence: 40,
                        progress: DeviceSyncProgressPayload(
                            completedBytes: 1_024,
                            totalBytes: 1_024)),
                    makeReceipt(
                        target: target,
                        action: "version-pull",
                        phase: .transferring,
                        requestID: "request-version-complete",
                        ledgerSequence: 41,
                        progress: DeviceSyncProgressPayload(
                            completedBytes: 3_072,
                            totalBytes: 3_072)),
                ])
            ).first
        )

        let progress = try XCTUnwrap(projection.measuredTransferProgress)
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.percentLabel, "100%")
        XCTAssertEqual(
            progress.detailLabel,
            byteDetail(completed: 4_096, total: 4_096)
        )
    }

    func testDuplicateReceiptIdentityDoesNotOvercountMeasuredBytes() throws {
        let target = "macbook-duplicate-progress"
        let receipt = makeReceipt(
            target: target,
            action: "system-pull",
            phase: .transferring,
            requestID: "request-duplicated",
            ledgerSequence: 50,
            progress: DeviceSyncProgressPayload(
                completedBytes: 512,
                totalBytes: 2_048)
        )
        let duplicate = makeReceipt(
            target: target,
            action: "version-pull",
            phase: .transferring,
            requestID: "request-duplicated",
            ledgerSequence: 50,
            progress: receipt.progress
        )

        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([
                    receipt,
                    duplicate,
                ])
            ).first
        )

        let progress = try XCTUnwrap(projection.measuredTransferProgress)
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertEqual(progress.percentLabel, "25%")
        XCTAssertEqual(
            progress.detailLabel,
            byteDetail(completed: 512, total: 2_048)
        )
    }

    func testCompletedRequiresEveryCurrentActionToComplete() throws {
        let target = "macbook-m3"
        let systemTransaction = makeTransaction(
            target: target,
            action: "system-pull",
            requestID: "system-complete",
            ledgerSequence: 20,
            state: .targetLocallyAttested
        )
        let versionReceipt = makeReceipt(
            target: target,
            action: "version-pull",
            phase: .delivered,
            requestID: "version-active",
            ledgerSequence: 21
        )

        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([versionReceipt]),
                transactions: [systemTransaction]
            ).first
        )

        XCTAssertEqual(projection.outcome, .active)
        XCTAssertEqual(projection.stage, .comparing)
        XCTAssertEqual(projection.statusLabel, "正在比對內容")
    }

    func testTargetAttestedTransactionsCompleteTheSingleTargetOperation() throws {
        let target = "macbook-m3"
        let projections = DeviceSyncUserOperationReducer.project(
            pending: [:],
            receipts: [:],
            transactions: [
                makeTransaction(
                    target: target,
                    action: "system-pull",
                    requestID: "system-complete",
                    ledgerSequence: 20,
                    state: .targetLocallyAttested
                ),
                makeTransaction(
                    target: target,
                    action: "version-pull",
                    requestID: "version-complete",
                    ledgerSequence: 21,
                    state: .targetLocallyAttested
                ),
            ]
        )

        let projection = try XCTUnwrap(projections.first)
        XCTAssertEqual(projections.count, 1)
        XCTAssertEqual(projection.outcome, .completed)
        XCTAssertEqual(projection.stage, .completed)
        XCTAssertEqual(projection.statusLabel, "已同步，目標設備已驗證")
    }

    func testNewPendingIntentInvalidatesOlderCompletedTransaction() throws {
        let target = "macbook-m3"
        let pending = DeviceSyncIntent(
            target: target,
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 30)
        )
        let oldTransaction = makeTransaction(
            target: target,
            action: "system-pull",
            requestID: "old-complete",
            ledgerSequence: 19,
            state: .targetLocallyAttested
        )

        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: DeviceSyncOperationIndex.latestPending([pending]),
                receipts: [:],
                transactions: [oldTransaction]
            ).first
        )

        XCTAssertEqual(projection.outcome, .active)
        XCTAssertEqual(projection.stage, .preparing)
        XCTAssertTrue(projection.transactions.isEmpty)
        XCTAssertEqual(projection.statusLabel, "正在準備同步")
    }

    func testArtifactIssueFailsClosedWithPlainLanguageStatus() throws {
        let receipt = makeReceipt(
            phase: .converged,
            requestID: "request-unreadable"
        )
        let issue = DeviceSyncArtifactIssue(
            kind: "receipt-unreadable",
            fileName: "broken.json",
            message: "malformed"
        )

        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([receipt]),
                artifactIssues: [issue]
            ).first
        )

        XCTAssertEqual(projection.outcome, .failed)
        XCTAssertEqual(
            projection.statusLabel,
            "同步證據讀取失敗，已停止顯示成功"
        )
    }

    func testProductionTransactionJournalUnreadableIssueFailsClosedForEveryVisibleTarget() throws {
        let projections = DeviceSyncUserOperationReducer.project(
            pending: [:],
            receipts: [:],
            transactions: [
                makeTransaction(
                    target: "macbook-a",
                    action: "system-pull",
                    requestID: "request-target-a",
                    ledgerSequence: 20,
                    state: .targetLocallyAttested),
                makeTransaction(
                    target: "macbook-b",
                    action: "system-pull",
                    requestID: "request-target-b",
                    ledgerSequence: 21,
                    state: .targetLocallyAttested),
            ],
            artifactIssues: [
                DeviceSyncArtifactIssue(
                    kind: "transaction-journal-unreadable",
                    fileName: "journal.json",
                    message: "malformed"),
            ]
        )

        XCTAssertEqual(projections.count, 2)
        XCTAssertTrue(projections.allSatisfy { $0.outcome == .failed })
        XCTAssertTrue(projections.allSatisfy { $0.artifactIssues.count == 1 })
        XCTAssertTrue(
            projections.allSatisfy {
                $0.statusLabel == "同步證據讀取失敗，已停止顯示成功"
            }
        )
    }

    func testUnreadableACKWithoutVerifiedScopeFailsClosedGlobally() throws {
        let projections = DeviceSyncUserOperationReducer.project(
            pending: [:],
            receipts: [:],
            transactions: [
                makeTransaction(
                    target: "macbook-a",
                    action: "system-pull",
                    requestID: "known-a",
                    ledgerSequence: 20,
                    state: .targetLocallyAttested),
                makeTransaction(
                    target: "macbook-b",
                    action: "system-pull",
                    requestID: "known-b",
                    ledgerSequence: 21,
                    state: .targetLocallyAttested),
            ],
            artifactIssues: [
                DeviceSyncArtifactIssue(
                    kind: "channel-ack-unreadable",
                    fileName: "forged.json",
                    message: "signature mismatch"),
            ]
        )

        XCTAssertEqual(projections.count, 2)
        XCTAssertTrue(projections.allSatisfy { $0.outcome == .failed })
        XCTAssertTrue(
            projections.allSatisfy {
                $0.statusLabel == "同步證據讀取失敗，已停止顯示成功"
            }
        )
    }

    func testVerifiedTransactionPhaseScopeOnlyFailsMatchingTargetAction() throws {
        let firstTarget = "macbook-a"
        let secondTarget = "macbook-b"
        let projections = DeviceSyncUserOperationReducer.project(
            pending: [:],
            receipts: [:],
            transactions: [
                makeTransaction(
                    target: firstTarget,
                    action: "system-pull",
                    requestID: "old-readable-a",
                    ledgerSequence: 20,
                    state: .targetLocallyAttested),
                makeTransaction(
                    target: secondTarget,
                    action: "system-pull",
                    requestID: "readable-b",
                    ledgerSequence: 21,
                    state: .targetLocallyAttested),
            ],
            artifactIssues: [
                DeviceSyncArtifactIssue(
                    kind: "transaction-phase-unreadable",
                    fileName: "journal.json",
                    message: "verified binding has an unknown phase",
                    scope: .verifiedBinding(
                        target: firstTarget,
                        action: "system-pull",
                        requestID: "newer-unreadable-a")),
            ]
        )

        let first = try XCTUnwrap(
            projections.first { $0.target == firstTarget })
        XCTAssertEqual(first.outcome, .failed)

        let second = try XCTUnwrap(
            projections.first { $0.target == secondTarget })
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertTrue(second.artifactIssues.isEmpty)
    }

    func testFailedOutcomeWinsAcrossFailedDivergedAndRolledBackActions() throws {
        let target = "macbook-mixed"
        let projections = DeviceSyncUserOperationReducer.project(
            pending: [:],
            receipts: DeviceSyncOperationIndex.latestReceipts([
                makeReceipt(
                    target: target,
                    action: "system-pull",
                    phase: .failed,
                    requestID: "request-failed",
                    ledgerSequence: 30),
                makeReceipt(
                    target: target,
                    action: "version-pull",
                    phase: .diverged,
                    requestID: "request-diverged",
                    ledgerSequence: 31),
            ]),
            transactions: [
                makeTransaction(
                    target: target,
                    action: "db-pull",
                    requestID: "request-rolled-back",
                    ledgerSequence: 32,
                    state: .rolledBack),
            ]
        )

        let projection = try XCTUnwrap(projections.first)
        XCTAssertEqual(projection.outcome, .failed)
        XCTAssertNotEqual(projection.stage, .completed)
        XCTAssertEqual(projection.statusLabel, "同步失敗，尚未完成")
    }

    func testRolledBackOperationCannotKeepCompletedStageOrFullProgress() throws {
        let target = "macbook-rollback"
        let requestID = "request-rollback"
        let projection = try XCTUnwrap(
            DeviceSyncUserOperationReducer.project(
                pending: [:],
                receipts: DeviceSyncOperationIndex.latestReceipts([
                    makeConvergedVersionReceipt(
                        target: target,
                        requestID: requestID)
                ]),
                transactions: [
                    makeTransaction(
                        target: target,
                        action: "version-pull",
                        requestID: requestID,
                        ledgerSequence: 40,
                        state: .rolledBack)
                ]
            ).first
        )

        XCTAssertEqual(projection.outcome, .attention)
        XCTAssertEqual(projection.stage, .activating)
        XCTAssertNotEqual(projection.stage, .completed)
        XCTAssertNil(projection.measuredTransferProgress)
        XCTAssertEqual(projection.statusLabel, "同步未完成，已回復前一版")
    }

    func testArtifactIssueStableIDDistinguishesNilAndDelimiterValues() {
        let nilScoped = DeviceSyncArtifactIssue(
            kind: "a::b",
            fileName: "c",
            message: "first"
        )
        let literalScoped = DeviceSyncArtifactIssue(
            kind: "a",
            fileName: "c",
            message: "second",
            scope: .verifiedBinding(
                target: "b::nil",
                action: "-",
                requestID: "-"
            )
        )

        XCTAssertNotEqual(nilScoped.id, literalScoped.id)
    }

    func testDevicesCardRemovesProgressWallAndUsesRegistryModuleRows() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceCrossSyncCard.swift"
            ),
            encoding: .utf8
        )
        let leaf = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceSyncLeafViews.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Text(\"同步進度\")"))
        XCTAssertFalse(source.contains("recentSyncSection"))
        XCTAssertFalse(source.contains("recentSyncTarget"))
        XCTAssertFalse(source.contains("syncStageProgress"))
        XCTAssertFalse(source.contains("expandedSyncEngineeringDetails"))
        XCTAssertFalse(source.contains("syncIntegritySection"))
        XCTAssertFalse(source.contains("同步證據無法讀取"))
        XCTAssertFalse(source.contains("DeviceSyncUserOperationProgressView("))
        XCTAssertFalse(source.contains("DeviceSyncReceiptProgressView("))
        XCTAssertTrue(source.contains("versionSyncSection"))
        XCTAssertTrue(source.contains("dataSyncSection"))
        XCTAssertTrue(source.contains("DeviceDataModuleRow"))
        XCTAssertTrue(source.contains("DeviceVersionRow"))
        XCTAssertTrue(source.contains("DeviceDataDeviceRow"))
        XCTAssertTrue(source.contains("DevicesPagePresentation.nameplateTitle"))
        XCTAssertTrue(source.contains("Divider().opacity(0.25)"))
        XCTAssertTrue(source.contains("actionTitle: \"更新\""))
        XCTAssertTrue(source.contains("actionTitle: \"同步\""))
        XCTAssertFalse(source.contains("actionTitle: \"同步資料\""))
        XCTAssertTrue(source.contains("performSelectedVersionUpdates"))
        XCTAssertTrue(source.contains("performSelectedDataSyncs"))
        XCTAssertTrue(source.contains("DevicesBatchInclusionStore"))
        XCTAssertFalse(leaf.contains("Text(\"檢查更新\")"))
        XCTAssertFalse(leaf.contains("一鍵更新"))
        XCTAssertFalse(leaf.contains("一鍵同步資料"))
        XCTAssertTrue(leaf.contains("struct DevicesInclusionPill"))
        XCTAssertTrue(leaf.contains(".disabled(!actionEnabled)"))
        XCTAssertTrue(leaf.contains("DevicesPagePresentation.threadsExclusionNote"))
        XCTAssertTrue(leaf.contains("if model.isSyncing"))
        XCTAssertTrue(leaf.contains("ProgressView()"))
        XCTAssertTrue(leaf.contains("if model.isFailed"))
        XCTAssertTrue(leaf.contains("if model.excluded"))
    }

    func testDevicesCardUsesInclusionPillsAndHeaderActions() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceCrossSyncCard.swift"
            ),
            encoding: .utf8
        )
        let leaf = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceSyncLeafViews.swift"
            ),
            encoding: .utf8
        )
        let composition = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicesComposition.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(leaf.contains("struct DevicesInclusionPill"))
        XCTAssertTrue(leaf.contains(".toggleStyle(.switch)"))
        XCTAssertTrue(leaf.contains("var actionTitle: String? = nil"))
        XCTAssertTrue(leaf.contains(".disabled(!actionEnabled)"))
        XCTAssertTrue(source.contains("actionTitle: \"更新\""))
        XCTAssertTrue(source.contains("actionTitle: \"同步\""))
        XCTAssertFalse(source.contains("actionTitle: \"同步資料\""))
        XCTAssertTrue(source.contains("dispatchSync(kind: .version"))
        XCTAssertTrue(source.contains("dispatchSync(kind: .data"))
        XCTAssertFalse(source.contains("let targets = Set(secondaryDevices.map(\\.name))"))
        XCTAssertTrue(composition.contains("static let versionExcludedKey"))
        XCTAssertTrue(composition.contains("static let dataExcludedKey"))
        XCTAssertTrue(composition.contains("tatwo.devices.batchInclusion.version.excluded"))
        XCTAssertTrue(composition.contains("tatwo.devices.batchInclusion.data.excluded"))
    }

    func testDataModuleFailureExpandsOneReasonLineWithoutProgressWall() throws {
        let leaf = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceSyncLeafViews.swift"
            ),
            encoding: .utf8
        )
        let rowStart = try XCTUnwrap(leaf.range(of: "struct DeviceDataModuleRow"))
        let rowSource = String(leaf[rowStart.lowerBound...])

        XCTAssertTrue(rowSource.contains("if isReasonExpanded, let reason = model.failureReason"))
        XCTAssertTrue(rowSource.contains(".lineLimit(1)"))
        XCTAssertFalse(rowSource.contains("percentLabel"))
        XCTAssertFalse(rowSource.contains("journal.requestID"))
        XCTAssertFalse(rowSource.contains("receipt.message"))
        XCTAssertTrue(rowSource.contains("else if model.isSyncing"))
        let syncingStart = try XCTUnwrap(rowSource.range(of: "else if model.isSyncing"))
        let excludedStart = try XCTUnwrap(rowSource.range(of: "if model.excluded"))
        let syncingBlock = String(rowSource[syncingStart.lowerBound..<rowSource.range(of: "} else {", range: syncingStart.lowerBound..<rowSource.endIndex)!.lowerBound])
        XCTAssertTrue(syncingBlock.contains("ProgressView()"))
        XCTAssertFalse(syncingBlock.contains("Toggle("))
        XCTAssertTrue(String(rowSource[excludedStart.lowerBound...]).contains("threadsExclusionNote"))
    }

    func testSyncConfirmationExplainsScopeAndProtectedData() throws {
        let source = try String(
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

        XCTAssertTrue(composition.contains("不會同步：Keychain、auth、session、token、PID、cache 與 secrets。"))
        XCTAssertTrue(composition.contains("衝突或驗證失敗時會停止，不會顯示完成。"))
        XCTAssertTrue(source.contains("DevicesPagePresentation.secretsCaption"))
        XCTAssertTrue(source.contains("DevicesPagePresentation.versionStopCaption"))
        XCTAssertTrue(source.contains("DeviceCLIVersionInfoRow"))
    }

    func testProgressWallAndIntegrityBannerAreRemoved() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceCrossSyncCard.swift"
            ),
            encoding: .utf8
        )
        let page = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicesPage.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("同步證據無法讀取，已停止顯示成功"))
        XCTAssertFalse(source.contains("allSyncArtifactIssues.count - 4"))
        XCTAssertFalse(source.contains("項未顯示"))
        XCTAssertFalse(source.contains("→ \\("))
        XCTAssertFalse(page.contains("Text(\"同步進度\")"))
        XCTAssertFalse(source.contains("Text(\"同步進度\")"))
        XCTAssertTrue(page.contains("DevicePressureMonitorCard("))
        XCTAssertTrue(page.contains("DeviceCrossSyncCard("))
    }

    private func makeReceipt(
        target: String = "macbook-m3",
        action: String = "version-pull",
        phase: DeviceSyncReceiptPhase,
        requestID: String,
        ledgerSequence: Int = 10,
        progress: DeviceSyncProgressPayload? = nil
    ) -> DeviceSyncReceipt {
        DeviceSyncReceipt(
            target: target,
            action: action,
            requestedAt: Date(timeIntervalSince1970: 10),
            result: phase == .failed ? "failure" : "pending",
            completedAt: Date(timeIntervalSince1970: 20),
            message: phase.rawValue,
            phase: phase,
            requestID: requestID,
            authorityEpoch: 3,
            ledgerSequence: ledgerSequence,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: target,
            catalogRevision: DeviceSyncCatalogProjection.currentRevision,
            progress: progress
        )
    }

    private func byteDetail(completed: Int64, total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: completed)) / "
            + formatter.string(fromByteCount: total)
    }

    private func makeTransaction(
        target: String,
        action: String,
        requestID: String,
        ledgerSequence: Int,
        state: DeviceSyncTransactionProjectionState
    ) -> DeviceSyncTransactionProjection {
        DeviceSyncTransactionProjection(
            target: target,
            action: action,
            journal: DeviceSyncSystemTransactionJournal(
                schema: "TatwoDeviceSyncSystemTransactionV1",
                requestID: requestID,
                phase: state == .targetLocallyAttested ? "committed" : "preparing",
                authorityPrimary: "mac-mini",
                authorityEpoch: 3,
                ledgerSequence: ledgerSequence,
                catalogRevision: DeviceSyncCatalogProjection.currentRevision ?? "catalog",
                ackState: state == .targetLocallyAttested ? "received" : "pending",
                recoveryState: "none",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                message: state.rawValue
            ),
            state: state,
            attestationEvidence: state == .targetLocallyAttested
                ? DeviceSyncAttestationEvidence(
                    level: .targetLocallyAttested,
                    attestedAt: Date(timeIntervalSince1970: 20),
                    provenance: "fixture",
                    detail: "verified"
                )
                : .none
        )
    }

    private func makeConvergedVersionReceipt(
        target: String,
        requestID: String
    ) -> DeviceSyncReceipt {
        let digest = String(repeating: "a", count: 64)
        return DeviceSyncReceipt(
            target: target,
            action: "version-pull",
            requestedAt: Date(timeIntervalSince1970: 10),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 20),
            message: "verified",
            phase: .converged,
            requestID: requestID,
            authorityEpoch: 3,
            ledgerSequence: 40,
            authorityPrimary: "mac-mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: target,
            catalogRevision: "version-catalog",
            digestAlgorithm: "sha256",
            sourceDigest: digest,
            appliedDigest: digest,
            requiredItemIDs: ["app.version"],
            items: [
                DeviceSyncItemReceipt(
                    id: "app.version",
                    displayName: "Tatwo source version",
                    phase: .verified,
                    digestAlgorithm: "sha256",
                    sourceDigest: digest,
                    appliedDigest: digest,
                    message: "verified")
            ],
            progress: DeviceSyncProgressPayload(percent: 100)
        )
    }
}

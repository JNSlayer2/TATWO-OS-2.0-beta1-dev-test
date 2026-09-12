import XCTest
@testable import TatwoUltraworkMac

final class DeviceSyncReceiptPresentationTests: XCTestCase {
    func testQueuedSystemPullShowsPendingInsteadOfInventingMissingItems() {
        let receipt = makeReceipt(result: "pending", phase: .queued, items: [])
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertEqual(presentation.state, .pending)
        XCTAssertEqual(presentation.statusLabel, "等待送出")
        XCTAssertEqual(presentation.percentLabel, "8%")
        XCTAssertEqual(presentation.progressBasisLabel, "階段推估")
        XCTAssertTrue(presentation.itemPresentations.isEmpty)
    }

    func testQueuedProducerHundredPercentIsCappedUntilConverged() {
        let receipt = makeReceipt(
            result: "pending",
            phase: .queued,
            items: [],
            progress: DeviceSyncProgressPayload(percent: 100)
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertFalse(receipt.isConverged)
        XCTAssertEqual(presentation.state, .pending)
        XCTAssertEqual(
            presentation.progressFraction,
            DeviceSyncReceiptPhase.verified.progressFraction,
            accuracy: 0.001
        )
        XCTAssertEqual(presentation.percentLabel, "94%")
        XCTAssertEqual(receipt.progressValue.provenance, .artifact)
    }

    func testEveryNonConvergedPhaseCapsProducerHundredPercent() {
        for phase in DeviceSyncReceiptPhase.allCases where phase != .converged {
            let receipt = makeReceipt(
                action: "version-pull",
                result: phase.rawValue,
                phase: phase,
                items: [],
                progress: DeviceSyncProgressPayload(percent: 100)
            )
            let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

            XCTAssertFalse(presentation.isConverged, "phase \(phase.rawValue)")
            XCTAssertLessThanOrEqual(
                presentation.progressFraction,
                DeviceSyncReceiptPhase.verified.progressFraction,
                "phase \(phase.rawValue)"
            )
            XCTAssertNotEqual(presentation.percentLabel, "100%", "phase \(phase.rawValue)")
            XCTAssertEqual(receipt.progressValue.provenance, .artifact)
        }
    }

    func testMeasuredReceiptProgressShowsProducerDimensions() {
        let receipt = makeReceipt(
            action: "version-pull",
            result: "partial",
            phase: .transferring,
            items: [],
            progress: DeviceSyncProgressPayload(
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
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertEqual(presentation.progressFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(presentation.percentLabel, "25%")
        XCTAssertEqual(presentation.progressBasisLabel, "實測")
        XCTAssertTrue(presentation.progressDetailLabel?.contains("issue.md") == true)
        XCTAssertTrue(presentation.progressDetailLabel?.contains("512 bytes / 2 KB") == true)
        XCTAssertTrue(presentation.progressDetailLabel?.contains("1 / 4 項") == true)
        XCTAssertTrue(presentation.progressDetailLabel?.contains("2 / 5 repositories") == true)
        XCTAssertTrue(presentation.progressDetailLabel?.contains("2.0 秒") == true)
        XCTAssertTrue(presentation.progressDetailLabel?.contains("256 bytes/s") == true)
    }

    func testCanonicalSourceProvenanceIsVisible() {
        let receipt = makeReceipt(result: "partial", phase: .transferring, items: [])
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertTrue(presentation.hasTrustedSourceProvenance)
        XCTAssertEqual(
            presentation.sourceProvenanceLabel,
            "canonical source · inventory \(String(repeating: "7", count: 10))"
        )
    }

    func testRuntimeFallbackProvenanceShowsExplicitAuthorization() {
        let receipt = makeReceipt(
            result: "partial",
            phase: .transferring,
            items: [],
            sourceMode: DeviceSyncSourceProvenanceValidator.runtimeFallback,
            fallbackAuthorizationID: "fallback-auth-123456789",
            fallbackAuthorizationPath:
                "fallback-authorizations/mini/epoch-3.json",
            fallbackAuthorizationDigest: String(repeating: "8", count: 64)
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertTrue(presentation.hasTrustedSourceProvenance)
        XCTAssertEqual(
            presentation.sourceProvenanceLabel,
            "runtime fallback · explicitly authorized"
                + " · inventory \(String(repeating: "7", count: 10))"
                + " · authorization fallback-aut/\(String(repeating: "8", count: 10))"
        )
    }

    func testMalformedRuntimeFallbackProvenanceIsVisibleAndUntrusted() {
        let receipt = makeReceipt(
            result: "partial",
            phase: .transferring,
            items: [],
            sourceMode: DeviceSyncSourceProvenanceValidator.runtimeFallback,
            fallbackAuthorizationID: "fallback-auth-123456789",
            fallbackAuthorizationPath:
                "fallback-authorizations/other-device/epoch-3.json",
            fallbackAuthorizationDigest: String(repeating: "8", count: 64)
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertFalse(presentation.hasTrustedSourceProvenance)
        XCTAssertEqual(
            presentation.sourceProvenanceLabel,
            "source provenance missing or invalid"
        )
    }

    func testLocalSourceRefreshAttemptIsExplicitlyLabeledWithoutInventingTargetProof() {
        let requestedAt = Date(timeIntervalSince1970: 1_753_500_000)
        let attempt = DeviceSyncSourceRefreshAttempt(
            schema: DeviceSyncSourceRefreshAttempt.schema,
            evidenceKind: DeviceSyncSourceRefreshAttempt.evidenceKind,
            attemptID: "attempt-ui-failure",
            target: "MacBook",
            action: "system-pull",
            requestedAt: requestedAt,
            currentDeviceName: "mini",
            currentDeviceID: "mini-id",
            authorityPrimary: "mini",
            authorityEpoch: 9,
            ledgerSequence: 44,
            catalogRevision: "2026-07-23.2",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            outcome: .failed,
            sourceMode: "unresolved",
            storeMutation: "staged-not-activated",
            inventoryDigest: "",
            fallbackAuthorizationID: "",
            fallbackAuthorizationPath: "",
            fallbackAuthorizationDigest: "",
            discoveredSourceCount: 1,
            refreshedCount: 0,
            failedCount: 1,
            results: [
                DeviceSyncSourceRefreshResult(
                    sourceName: "刺青網頁",
                    repositoryID: "",
                    displayName: "刺青網頁",
                    status: "failed",
                    message: "missing governed portable repository alias",
                    revisionID: nil,
                    contentDigest: nil
                )
            ],
            message: "canonical source refresh failed",
            startedAt: requestedAt.addingTimeInterval(1),
            completedAt: requestedAt.addingTimeInterval(2)
        )
        let presentation = DeviceSyncReceiptPresentation(
            receipt: attempt.presentationReceipt
        )

        XCTAssertTrue(presentation.isLocalSourceRefreshAttempt)
        XCTAssertEqual(
            presentation.operationLabel,
            "OS 資料 · 本機來源刷新"
        )
        XCTAssertEqual(
            presentation.attestationLabel,
            "local-source-refresh-attempt · not-request · not-ACK · "
                + "not-target-attestation"
        )
        XCTAssertFalse(presentation.expectsIssueDocument)
        XCTAssertEqual(presentation.state, .failed)
        XCTAssertEqual(presentation.itemPresentations.count, 1)
        XCTAssertEqual(
            presentation.itemPresentations.first?.displayName,
            "刺青網頁"
        )
        XCTAssertFalse(
            presentation.itemPresentations.contains {
                $0.isSyntheticMissingItem
            }
        )
    }

    func testLegacySuccessRemainsDeliveredAndNeverGreen() {
        let receipt = makeReceipt(result: "success", phase: nil, items: [])
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertEqual(presentation.receipt.effectivePhase, .delivered)
        XCTAssertEqual(presentation.state, .partial)
        XCTAssertFalse(presentation.isConverged)
        XCTAssertEqual(
            presentation.statusLabel,
            "部分同步 · 缺少 os.md、issue.md、TODO.md、Skillet repositories"
        )
    }

    func testConvergedRequiresVerifiedIssueDocument() {
        let issue = DeviceSyncItemReceipt(
            id: "os.issue",
            displayName: "issue.md",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "a", count: 64),
            appliedDigest: String(repeating: "a", count: 64),
            message: "verified"
        )
        let constitution = DeviceSyncItemReceipt(
            id: "os.constitution",
            displayName: "os.md",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "b", count: 64),
            appliedDigest: String(repeating: "b", count: 64),
            message: "verified"
        )
        let todo = DeviceSyncItemReceipt(
            id: "os.todo",
            displayName: "TODO.md",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "c", count: 64),
            appliedDigest: String(repeating: "c", count: 64),
            message: "verified"
        )
        let receipt = makeReceipt(
            result: "converged",
            phase: .converged,
            items: [constitution, issue, todo, makeSkilletItem()],
            attestationEvidence: targetLocallyAttestedEvidence
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertTrue(receipt.isConverged)
        XCTAssertTrue(presentation.isConverged)
        XCTAssertEqual(presentation.state, .converged)
        XCTAssertEqual(presentation.statusLabel, receipt.statusLabel)
    }

    func testMissingIssueDocumentDowngradesTerminalReceiptToDiverged() {
        let constitution = DeviceSyncItemReceipt(
            id: "os.constitution",
            displayName: "os.md",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "a", count: 64),
            appliedDigest: String(repeating: "a", count: 64),
            message: "verified"
        )
        let todo = DeviceSyncItemReceipt(
            id: "os.todo",
            displayName: "TODO.md",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "c", count: 64),
            appliedDigest: String(repeating: "c", count: 64),
            message: "verified"
        )
        let receipt = makeReceipt(
            result: "converged",
            phase: .converged,
            items: [constitution, todo, makeSkilletItem()]
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertFalse(receipt.isConverged)
        XCTAssertFalse(presentation.isConverged)
        XCTAssertEqual(presentation.state, .diverged)
        XCTAssertEqual(presentation.statusLabel, "內容分岔 · issue.md 未驗證")
        XCTAssertTrue(
            presentation.itemPresentations.contains {
                $0.displayName == "issue.md" && $0.isSyntheticMissingItem
            }
        )
    }

    func testLegacyDatabaseSyncDoesNotRequireIssueDocument() {
        let database = DeviceSyncItemReceipt(
            id: "work.goal-state",
            displayName: "Goal state",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "d", count: 64),
            appliedDigest: String(repeating: "d", count: 64),
            message: "verified"
        )
        let receipt = makeReceipt(
            action: "db-pull",
            result: "converged",
            phase: .converged,
            items: [database]
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertFalse(presentation.expectsIssueDocument)
        XCTAssertTrue(presentation.isConverged)
        XCTAssertEqual(presentation.statusLabel, "已收斂")
    }

    func testGenuineConvergenceCanRenderProducerHundredPercent() {
        let database = DeviceSyncItemReceipt(
            id: "work.goal-state",
            displayName: "Goal state",
            phase: .verified,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "d", count: 64),
            appliedDigest: String(repeating: "d", count: 64),
            message: "verified"
        )
        let receipt = makeReceipt(
            action: "db-pull",
            result: "converged",
            phase: .converged,
            items: [database],
            progress: DeviceSyncProgressPayload(percent: 100)
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertTrue(presentation.isConverged)
        XCTAssertEqual(presentation.state, .converged)
        XCTAssertEqual(presentation.progressFraction, 1, accuracy: 0.001)
        XCTAssertEqual(presentation.percentLabel, "100%")
        XCTAssertEqual(receipt.progressValue.provenance, .artifact)
    }

    func testSkilletItemPresentsEveryNestedRepositoryReceipt() {
        let receipt = makeReceipt(
            result: "converged",
            phase: .converged,
            items: [
                makeItem("os.constitution", displayName: "os.md", digest: "a"),
                makeItem("os.issue", displayName: "issue.md", digest: "b"),
                makeItem("os.todo", displayName: "TODO.md", digest: "c"),
                makeSkilletItem()
            ],
            attestationEvidence: targetLocallyAttestedEvidence
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)
        let skillet = presentation.itemPresentations.first {
            $0.id == "skills.skillet"
        }

        XCTAssertTrue(presentation.isConverged)
        XCTAssertEqual(skillet?.repositories.count, 1)
        XCTAssertEqual(skillet?.repositories.first?.repositoryID, "alpha-skill")
        XCTAssertTrue(skillet?.repositories.first?.isVerified == true)
        XCTAssertTrue(skillet?.repositories.first?.bindingLabel.contains("epoch 3") == true)
    }

    func testSystemPullMakesItemsPreservedRepositoriesAndReadbacksVisible() {
        let receipt = makeReceipt(
            result: "partial",
            phase: .verified,
            items: [
                makeItem("os.constitution", displayName: "os.md", digest: "a"),
                makeItem("os.issue", displayName: "issue.md", digest: "b"),
                makeItem("os.todo", displayName: "TODO.md", digest: "c"),
                makeSkilletItem(targetPreserved: true)
            ],
            attestationEvidence: targetLocallyAttestedEvidence
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)
        let skillet = presentation.itemPresentations.first {
            $0.id == "skills.skillet"
        }

        XCTAssertEqual(
            presentation.syncItemEvidenceLabel,
            "同步項目 4 / 4：os.md、issue.md、TODO.md、Skillet private repositories"
        )
        XCTAssertEqual(
            presentation.skilletEvidenceLabel,
            "Skillet：1 同步 repositories · 1 目標保留 repositories · "
                + "9 consumer readbacks"
        )
        XCTAssertEqual(skillet?.repositories.count, 2)
        XCTAssertEqual(skillet?.repositories.last?.repositoryID, "beta-local")
        XCTAssertTrue(
            skillet?.repositories.last?.bindingLabel.contains("target-preserved") == true
        )
        XCTAssertTrue(skillet?.repositories.last?.isVerified == true)
    }

    func testChannelClaimedWithoutTargetAttestationIsPartialAndNeverGreen() {
        let receipt = makeReceipt(
            result: "converged",
            phase: .converged,
            items: [
                makeItem("os.constitution", displayName: "os.md", digest: "a"),
                makeItem("os.issue", displayName: "issue.md", digest: "b"),
                makeItem("os.todo", displayName: "TODO.md", digest: "c"),
                makeSkilletItem()
            ],
            attestationEvidence: .channelClaimed("target-local attestation missing")
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertTrue(receipt.isChannelClaimed)
        XCTAssertFalse(receipt.isConverged)
        XCTAssertFalse(presentation.isConverged)
        XCTAssertEqual(presentation.state, .partial)
        XCTAssertEqual(presentation.percentLabel, "94%")
        XCTAssertTrue(presentation.attestationLabel.contains("channel-claimed"))
    }

    func testChannelClaimedProducerHundredPercentIsCappedUntilTargetAttested() {
        let receipt = makeReceipt(
            result: "converged",
            phase: .converged,
            items: [
                makeItem("os.constitution", displayName: "os.md", digest: "a"),
                makeItem("os.issue", displayName: "issue.md", digest: "b"),
                makeItem("os.todo", displayName: "TODO.md", digest: "c"),
                makeSkilletItem()
            ],
            attestationEvidence: .channelClaimed(
                "target-local attestation missing"
            ),
            progress: DeviceSyncProgressPayload(percent: 100)
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertTrue(receipt.isChannelClaimed)
        XCTAssertFalse(receipt.isConverged)
        XCTAssertEqual(presentation.state, .partial)
        XCTAssertEqual(
            presentation.progressFraction,
            DeviceSyncReceiptPhase.verified.progressFraction,
            accuracy: 0.001
        )
        XCTAssertEqual(presentation.percentLabel, "94%")
    }

    func testTargetAttestationWithoutConsumerReadbackShowsFirstBrokenPhase() {
        let receipt = makeReceipt(
            result: "converged",
            phase: .converged,
            items: [
                makeItem("os.constitution", displayName: "os.md", digest: "a"),
                makeItem("os.issue", displayName: "issue.md", digest: "b"),
                makeItem("os.todo", displayName: "TODO.md", digest: "c"),
                makeSkilletItem()
            ],
            attestationEvidence: DeviceSyncAttestationEvidence(
                level: .targetLocallyAttested,
                attestedAt: Date(timeIntervalSince1970: 50),
                provenance: "TatwoTargetLocalSystemAttestationV2",
                detail: "attestation exists but consumer readback is missing"
            )
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertFalse(receipt.isConverged)
        XCTAssertFalse(presentation.isConverged)
        XCTAssertEqual(presentation.state, .partial)
        XCTAssertEqual(
            presentation.statusLabel,
            "部分同步 · first broken phase consumer-readback"
        )
        XCTAssertEqual(presentation.firstBrokenPhaseLabel, "consumer-readback")
    }

    func testUnreadableAttestationBlocksOldGreenPresentation() {
        let receipt = makeReceipt(
            result: "converged",
            phase: .converged,
            items: [
                makeItem("os.constitution", displayName: "os.md", digest: "a"),
                makeItem("os.issue", displayName: "issue.md", digest: "b"),
                makeItem("os.todo", displayName: "TODO.md", digest: "c"),
                makeSkilletItem()
            ],
            attestationEvidence: .unreadable("future schema")
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertEqual(presentation.state, .unreadable)
        XCTAssertFalse(presentation.isConverged)
        XCTAssertEqual(
            presentation.statusLabel,
            "unreadable · target attestation 驗證失敗"
        )
        XCTAssertLessThan(presentation.progressFraction, 1)
    }

    func testTerminalReceiptFromDifferentCatalogIsShownAsDiverged() {
        let receipt = DeviceSyncReceipt(
            target: "MacBook",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "converged",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "receipt",
            phase: .converged,
            requestID: "request-123456789",
            authorityEpoch: 3,
            ledgerSequence: 11,
            authorityPrimary: "mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: "future-catalog",
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "f", count: 64),
            appliedDigest: String(repeating: "f", count: 64),
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: []
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)
        let expected = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)

        XCTAssertEqual(presentation.state, .diverged)
        XCTAssertEqual(
            presentation.statusLabel,
            "內容分岔 · catalog future-catalog ≠ \(expected)"
        )
        XCTAssertFalse(presentation.isConverged)
    }

    func testVerifiedProducerHundredPercentWithCatalogMismatchIsCapped() {
        let receipt = DeviceSyncReceipt(
            target: "MacBook",
            action: "system-pull",
            requestedAt: Date(timeIntervalSince1970: 1),
            result: "partial",
            completedAt: Date(timeIntervalSince1970: 2),
            message: "receipt",
            phase: .verified,
            requestID: "request-123456789",
            authorityEpoch: 3,
            ledgerSequence: 11,
            authorityPrimary: "mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: "future-catalog",
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "f", count: 64),
            appliedDigest: String(repeating: "f", count: 64),
            requiredItemIDs: DeviceSyncCatalogProjection.systemPullItemIDs,
            items: [],
            progress: DeviceSyncProgressPayload(percent: 100)
        )
        let presentation = DeviceSyncReceiptPresentation(receipt: receipt)

        XCTAssertFalse(receipt.isConverged)
        XCTAssertEqual(presentation.state, .diverged)
        XCTAssertEqual(
            presentation.progressFraction,
            DeviceSyncReceiptPhase.verified.progressFraction,
            accuracy: 0.001
        )
        XCTAssertEqual(presentation.percentLabel, "94%")
        XCTAssertEqual(receipt.progressValue.provenance, .artifact)
    }

    private func makeReceipt(
        action: String = "system-pull",
        result: String,
        phase: DeviceSyncReceiptPhase?,
        items: [DeviceSyncItemReceipt],
        attestationEvidence: DeviceSyncAttestationEvidence = .none,
        progress: DeviceSyncProgressPayload? = nil,
        sourceMode: String = DeviceSyncSourceProvenanceValidator.canonical,
        fallbackAuthorizationID: String = "",
        fallbackAuthorizationPath: String = "",
        fallbackAuthorizationDigest: String = ""
    ) -> DeviceSyncReceipt {
        let catalogRevision = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
        return DeviceSyncReceipt(
            target: "MacBook",
            action: action,
            requestedAt: Date(timeIntervalSince1970: 1),
            result: result,
            completedAt: Date(timeIntervalSince1970: 2),
            message: "receipt",
            phase: phase,
            requestID: "request-123456789",
            authorityEpoch: 3,
            ledgerSequence: 11,
            authorityPrimary: "mini",
            sourceDeviceID: "mini-id",
            targetDeviceID: "book-id",
            catalogRevision: catalogRevision,
            sourceMode: action == "system-pull" ? sourceMode : nil,
            inventoryDigest: action == "system-pull"
                ? String(repeating: "7", count: 64)
                : nil,
            fallbackAuthorizationID: action == "system-pull"
                ? fallbackAuthorizationID
                : nil,
            fallbackAuthorizationPath: action == "system-pull"
                ? fallbackAuthorizationPath
                : nil,
            fallbackAuthorizationDigest: action == "system-pull"
                ? fallbackAuthorizationDigest
                : nil,
            digestAlgorithm: "sha256",
            sourceDigest: String(repeating: "f", count: 64),
            appliedDigest: String(repeating: "f", count: 64),
            requiredItemIDs: action == "system-pull"
                ? DeviceSyncCatalogProjection.systemPullItemIDs
                : items.map(\.id),
            items: items,
            attestationEvidence: attestationEvidence,
            progress: progress
        )
    }

    private var targetLocallyAttestedEvidence: DeviceSyncAttestationEvidence {
        let osRecords = [
            ("os.constitution", Character("a"), "os/os.md"),
            ("os.issue", Character("b"), "os/issue.md"),
            ("os.todo", Character("c"), "os/TODO.md"),
        ].flatMap { item in
            [
                makeConsumerReadback(
                    consumerID: "work-os.bootstrap",
                    consumerKind: "work-os-bootstrap",
                    sourceItemID: item.0,
                    digest: item.1,
                    loadedRevision: "sha256-\(String(repeating: String(item.1), count: 64))",
                    loadedPath: item.2,
                    runtimeRef: "TatwoWorkOSBootstrap"
                ),
                makeConsumerReadback(
                    consumerID: "tatwo-app.shared-runtime",
                    consumerKind: "tatwo-app-shared-loader",
                    sourceItemID: item.0,
                    digest: item.1,
                    loadedRevision: "sha256-\(String(repeating: String(item.1), count: 64))",
                    loadedPath: item.2,
                    runtimeRef: "TatwoUltraworkCore"
                ),
            ]
        }
        let skilletDigest = String(repeating: "d", count: 64)
        return DeviceSyncAttestationEvidence(
            level: .targetLocallyAttested,
            attestedAt: Date(timeIntervalSince1970: 50),
            provenance: "TatwoTargetLocalSystemAttestationV2",
            detail: "digest, authority and actual consumer readback binding verified",
            consumerReadbackDigest: String(repeating: "8", count: 64),
            consumerReadbacks: osRecords + [
                DeviceSyncConsumerReadbackEvidence(
                    consumerID: "skillet.runtime-loader",
                    consumerKind: "active-skill-runtime-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: skilletDigest,
                    loadedDigest: skilletDigest,
                    loadedRevision: "rev-\(skilletDigest)",
                    loadedPath: "skillet/alpha-skill",
                    runtimeRef: "TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive",
                    observedAt: Date(timeIntervalSince1970: 49),
                    status: "loaded"
                ),
                DeviceSyncConsumerReadbackEvidence(
                    consumerID: "codex.native-skills",
                    consumerKind: "codex-native-skills-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: skilletDigest,
                    loadedDigest: skilletDigest,
                    loadedRevision: "rev-\(skilletDigest)",
                    loadedPath: ".codex/skills/alpha-skill",
                    runtimeRef:
                        "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
                    observedAt: Date(timeIntervalSince1970: 49),
                    status: "loaded"
                ),
                DeviceSyncConsumerReadbackEvidence(
                    consumerID: "claude.native-skills",
                    consumerKind: "claude-native-skills-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: skilletDigest,
                    loadedDigest: skilletDigest,
                    loadedRevision: "rev-\(skilletDigest)",
                    loadedPath: ".claude/skills/alpha-skill",
                    runtimeRef:
                        "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
                    observedAt: Date(timeIntervalSince1970: 49),
                    status: "loaded"
                )
            ]
        )
    }

    private func makeConsumerReadback(
        consumerID: String,
        consumerKind: String,
        sourceItemID: String,
        digest: Character,
        loadedRevision: String,
        loadedPath: String,
        runtimeRef: String
    ) -> DeviceSyncConsumerReadbackEvidence {
        let value = String(repeating: String(digest), count: 64)
        return DeviceSyncConsumerReadbackEvidence(
            consumerID: consumerID,
            consumerKind: consumerKind,
            sourceItemID: sourceItemID,
            expectedDigest: value,
            loadedDigest: value,
            loadedRevision: loadedRevision,
            loadedPath: loadedPath,
            runtimeRef: runtimeRef,
            observedAt: Date(timeIntervalSince1970: 49),
            status: "loaded"
        )
    }

    private func makeItem(
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

    private func makeSkilletItem(
        targetPreserved: Bool = false
    ) -> DeviceSyncItemReceipt {
        let contentDigest = String(repeating: "d", count: 64)
        let preservedDigest = String(repeating: "6", count: 64)
        let catalogRevision = try! XCTUnwrap(DeviceSyncCatalogProjection.currentRevision)
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
                    bundleDigest: String(repeating: "e", count: 64),
                    requestID: "request-123456789",
                    sourceDeviceID: "mini-id",
                    targetDeviceID: "book-id",
                    authorityEpoch: 3,
                    ledgerSequence: 11,
                    catalogRevision: catalogRevision,
                    phase: .verified
                )
            ],
            targetPreservedCount: targetPreserved ? 1 : nil,
            targetPreservedRepositories: targetPreserved
                ? [
                    DeviceSyncTargetPreservedRepositoryReceipt(
                        repositoryID: "beta-local",
                        revisionID: "rev-\(preservedDigest)",
                        contentDigest: preservedDigest,
                        state: "runtime-preserved",
                        phase: "preserved"
                    )
                ]
                : nil,
            targetPreservedRuntimeClosureCapability: targetPreserved
                ? "target-preserved-runtime-closure-v1"
                : nil,
            targetPreservedRuntimeClosed: targetPreserved ? true : nil
        )
    }
}

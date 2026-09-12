import Foundation
import CryptoKit
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class SkilletPresentationTests: XCTestCase {
    func testRuntimeCatalogReconcilerUsesPortableRepositoryIDAndHidesNonSkills() {
        let runtimeSkill = TatwoSkillsDirectoryEntryV1(
            id: "刺青網頁",
            name: "刺青網頁",
            summary: "Tattoo skill",
            path: "/tmp/tatwo2-fixture/skills/刺青網頁",
            hasManifest: true,
            isRegistered: true
        )
        let archivedDirectory = TatwoSkillsDirectoryEntryV1(
            id: "open-ultrawork",
            name: "open-ultrawork",
            summary: nil,
            path: "/tmp/tatwo2-fixture/skills/open-ultrawork",
            hasManifest: false,
            isRegistered: false
        )

        let reconciled = SkilletRuntimeCatalogReconciler.reconcile(
            runtimeEntries: [runtimeSkill, archivedDirectory],
            repositoryDisplayNames: ["tattoo-web": "刺青網頁"]
        )

        XCTAssertEqual(Set(reconciled.keys), ["tattoo-web"])
        XCTAssertEqual(reconciled["tattoo-web"]?.id, "tattoo-web")
        XCTAssertEqual(
            reconciled["tattoo-web"]?.path,
            "/tmp/tatwo2-fixture/skills/刺青網頁"
        )
        XCTAssertTrue(reconciled["tattoo-web"]?.hasManifest == true)
    }

    func testRegisteredSkillWithoutSnapshotDoesNotInventRevision() {
        let skill = TatwoSkillsDirectoryEntryV1(
            id: "tatwo-ultrawork",
            name: "tatwo-ultrawork",
            summary: "Work OS",
            path: "/tmp/tatwo-ultrawork",
            hasManifest: true,
            isRegistered: true
        )

        let summary = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: nil
        )

        XCTAssertFalse(summary.isStaged)
        XCTAssertFalse(summary.hasSnapshot)
        XCTAssertTrue(summary.repository.revisions.isEmpty)
        XCTAssertNil(summary.repository.stableRevision)
        XCTAssertNil(summary.repository.canaryRevision)
        XCTAssertEqual(summary.currentRevisionLabel, "尚未快照")
        XCTAssertEqual(summary.stableLabel, "未發布")
        XCTAssertEqual(summary.canaryLabel, "未發布")
        XCTAssertEqual(summary.reconciliationState, .runtimeOnly)
        XCTAssertTrue(summary.syncLabel.contains("runtime-only"))
    }

    func testMissingManifestIsUnavailableAndHasNoRevision() {
        let skill = TatwoSkillsDirectoryEntryV1(
            id: "empty",
            name: "empty",
            summary: nil,
            path: "/tmp/empty",
            hasManifest: false,
            isRegistered: false
        )

        let summary = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: nil
        )

        XCTAssertEqual(summary.repository.health, .unavailable)
        XCTAssertEqual(summary.healthLabel, "unavailable")
        XCTAssertEqual(summary.currentRevisionLabel, "尚未快照")
        XCTAssertEqual(summary.deviceCount, 0)
        XCTAssertEqual(summary.reconciliationState, .missing)
    }

    func testRealRepositoryAndSnapshotManifestDrivePresentation() {
        let revision = TatwoSkillRevisionV1(
            id: "rev-abcdef",
            repositoryID: "fixture",
            parentRevisionID: nil,
            contentDigest: "abcdef",
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let skill = TatwoSkillsDirectoryEntryV1(
            id: "fixture",
            name: "Fixture",
            summary: "Stored fixture",
            path: "/tmp/fixture",
            hasManifest: true,
            isRegistered: true
        )
        let repository = TatwoCapabilityRepositoryV1(
            id: "fixture",
            displayName: "Fixture",
            summary: "Stored fixture",
            canonicalRevision: revision.id,
            stableRevision: nil,
            canaryRevision: nil,
            revisions: [revision],
            deviceHeads: []
        )
        let summary = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: repository
        )
        let detail = SkilletPresentationBuilder.loadDetail(
            revisionID: revision.id,
            snapshotManifest: .init(
                contentDigest: "abcdef",
                files: [
                    .init(relativePath: "SKILL.md", contentDigest: "one", byteCount: 8),
                    .init(relativePath: "scripts/run.sh", contentDigest: "two", byteCount: 20)
                ]
            )
        )

        XCTAssertTrue(summary.isStaged)
        XCTAssertTrue(summary.hasSnapshot)
        XCTAssertEqual(summary.currentRevisionLabel, "rev-abcdef")
        XCTAssertEqual(summary.reconciliationState, .receiptMissing)
        XCTAssertEqual(detail.revisionID, revision.id)
        XCTAssertEqual(detail.files.map(\.relativePath), ["SKILL.md", "scripts/run.sh"])
    }

    func testVerifiedCountRequiresCanonicalActiveHeadAndExactDeviceReceipt() {
        let digest = String(repeating: "a", count: 64)
        let revisionID = "rev-\(digest)"
        let verifiedAt = Date(timeIntervalSince1970: 100)
        let skill = TatwoSkillsDirectoryEntryV1(
            id: "fixture",
            name: "Fixture",
            summary: "Stored fixture",
            path: "/tmp/fixture",
            hasManifest: true,
            isRegistered: true
        )
        let head = TatwoDeviceHeadV1(
            deviceID: "macbook",
            repositoryID: skill.id,
            revisionID: revisionID,
            contentDigest: digest,
            requestID: "request-12",
            authorityEpoch: 7,
            ledgerSequence: 12,
            activationState: .active,
            lastVerifiedAt: verifiedAt
        )
        let repository = TatwoCapabilityRepositoryV1(
            id: skill.id,
            displayName: skill.name,
            summary: "Stored fixture",
            canonicalRevision: revisionID,
            stableRevision: revisionID,
            canaryRevision: nil,
            revisions: [
                TatwoSkillRevisionV1(
                    id: revisionID,
                    repositoryID: skill.id,
                    parentRevisionID: nil,
                    contentDigest: digest,
                    channel: .stable,
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ],
            deviceHeads: [head]
        )
        let receipt = TatwoSkilletRepositoryReceiptV1(
            id: "device-macbook-e7-s12-request-12",
            repositoryID: skill.id,
            revisionID: revisionID,
            kind: .deviceHead,
            contentDigest: digest,
            deviceID: "macbook",
            requestID: "request-12",
            authorityEpoch: 7,
            ledgerSequence: 12,
            activationState: .active,
            recordedAt: verifiedAt,
            message: "verified"
        )

        let withoutReceipt = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: repository,
            receipts: []
        )
        let verified = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: repository,
            receipts: [receipt]
        )

        XCTAssertEqual(withoutReceipt.deviceCount, 0)
        XCTAssertEqual(withoutReceipt.reconciliationState, .receiptMissing)
        XCTAssertEqual(verified.deviceCount, 1)
        XCTAssertEqual(verified.reconciliationState, .verified)
        XCTAssertTrue(verified.syncLabel.contains("1 台設備"))
    }

    func testUnreadableRepositoryArtifactFailsClosed() {
        let skill = TatwoSkillsDirectoryEntryV1(
            id: "fixture",
            name: "Fixture",
            summary: nil,
            path: "/tmp/fixture",
            hasManifest: true,
            isRegistered: true
        )

        let summary = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: nil,
            runtimePresent: true,
            unreadableReason: "future repository schema"
        )

        XCTAssertEqual(summary.reconciliationState, .unreadable)
        XCTAssertEqual(summary.deviceCount, 0)
        XCTAssertTrue(summary.syncLabel.contains("fail-closed"))
        XCTAssertEqual(summary.reconciliationDetail, "future repository schema")
    }

    func testRepositoryWithoutRuntimeIsMissingRatherThanVerified() {
        let revision = TatwoSkillRevisionV1(
            id: "rev-abcdef",
            repositoryID: "fixture",
            parentRevisionID: nil,
            contentDigest: "abcdef",
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let skill = TatwoSkillsDirectoryEntryV1(
            id: "fixture",
            name: "Fixture",
            summary: nil,
            path: "",
            hasManifest: false,
            isRegistered: false
        )
        let repository = TatwoCapabilityRepositoryV1(
            id: skill.id,
            displayName: skill.name,
            summary: "Stored fixture",
            canonicalRevision: revision.id,
            stableRevision: nil,
            canaryRevision: nil,
            revisions: [revision],
            deviceHeads: []
        )

        let summary = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: repository,
            runtimePresent: false
        )

        XCTAssertEqual(summary.reconciliationState, .missing)
        XCTAssertEqual(summary.deviceCount, 0)
        XCTAssertTrue(summary.reconciliationDetail.contains("runtime/canonical"))
    }

    func testMergePresentationExposesPendingProposalAndConflictEvidence() {
        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("presentation-proposal"))",
            repositoryID: "fixture",
            sourceDeviceID: "macbook",
            baseRevisionID: "rev-\(digest("base"))",
            canonicalRevisionID: "rev-\(digest("canonical"))",
            proposedRevisionID: "rev-\(digest("proposed"))",
            mergedRevisionID: nil,
            conflictArtifactIDs: ["conflict-\(digest("conflict"))"]
        )
        let conflict = TatwoSkilletMergeConflictArtifactV1(
            id: proposal.conflictArtifactIDs[0],
            repositoryID: proposal.repositoryID,
            sourceDeviceID: proposal.sourceDeviceID,
            baseRevisionID: proposal.baseRevisionID,
            canonicalRevisionID: proposal.canonicalRevisionID,
            proposedRevisionID: proposal.proposedRevisionID,
            relativePath: "SKILL.md",
            kind: .overlappingTextEdits,
            baseContentDigest: digest("base"),
            canonicalContentDigest: digest("canonical"),
            proposedContentDigest: digest("proposed")
        )
        let skill = TatwoSkillsDirectoryEntryV1(
            id: "fixture",
            name: "Fixture",
            summary: nil,
            path: "/tmp/fixture",
            hasManifest: true,
            isRegistered: true
        )

        let summary = SkilletPresentationBuilder.makeSummary(
            skill: skill,
            repository: nil,
            mergeProposals: [proposal],
            mergeConflictsByProposal: [proposal.id: [conflict]]
        )

        XCTAssertEqual(summary.pendingMergeCount, 1)
        XCTAssertEqual(summary.mergeProposals, [proposal])
        XCTAssertEqual(
            summary.mergeConflictsByProposal[proposal.id],
            [conflict]
        )
    }

    func testAppExecutorApprovesCleanMergeWithoutMutatingRuntime() throws {
        let fixture = try makeMergeFixture(
            repositoryID: "app-clean-merge",
            includeMergedRevision: true,
            conflict: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try SkilletMergeDecisionExecutor.execute(
            storeRoot: fixture.storeRoot,
            runtimeRoot: fixture.runtimeRoot,
            request: SkilletMergeDecisionRequest(
                kind: .approve,
                repositoryID: fixture.repositoryID,
                proposalID: fixture.proposal.id,
                resolvedRevisionID: nil
            ),
            decidedBy: "human-mini",
            decidedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(result.receipt.status, .approved)
        XCTAssertEqual(result.receipt.resolvedRevisionID, fixture.merged?.id)
        XCTAssertTrue(result.runtimeUnchanged)
        XCTAssertEqual(result.runtimeBefore.state, .absent)
        XCTAssertEqual(
            try fixture.store.loadRepository(id: fixture.repositoryID)
                .canonicalRevision,
            fixture.merged?.id
        )
    }

    func testAppExecutorRequiresExplicitResolvedRevisionForConflict() throws {
        let fixture = try makeMergeFixture(
            repositoryID: "app-conflict-merge",
            includeMergedRevision: false,
            conflict: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try SkilletMergeDecisionExecutor.execute(
                storeRoot: fixture.storeRoot,
                runtimeRoot: fixture.runtimeRoot,
                request: SkilletMergeDecisionRequest(
                    kind: .approve,
                    repositoryID: fixture.repositoryID,
                    proposalID: fixture.proposal.id,
                    resolvedRevisionID: nil
                ),
                decidedBy: "human-mini"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .unresolvedMergeConflicts(fixture.proposal.id)
            )
        }

        let resolved = try SkilletMergeDecisionExecutor.execute(
            storeRoot: fixture.storeRoot,
            runtimeRoot: fixture.runtimeRoot,
            request: SkilletMergeDecisionRequest(
                kind: .approve,
                repositoryID: fixture.repositoryID,
                proposalID: fixture.proposal.id,
                resolvedRevisionID: fixture.proposed.id
            ),
            decidedBy: "human-mini"
        )
        XCTAssertEqual(resolved.receipt.status, .approved)
        XCTAssertEqual(resolved.receipt.resolvedRevisionID, fixture.proposed.id)
        XCTAssertTrue(resolved.runtimeUnchanged)
    }

    func testAppExecutorRejectsMergeAndPreservesCanonicalAndRuntime() throws {
        let fixture = try makeMergeFixture(
            repositoryID: "app-reject-merge",
            includeMergedRevision: false,
            conflict: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonicalBefore = try fixture.store
            .loadRepository(id: fixture.repositoryID).canonicalRevision

        let result = try SkilletMergeDecisionExecutor.execute(
            storeRoot: fixture.storeRoot,
            runtimeRoot: fixture.runtimeRoot,
            request: SkilletMergeDecisionRequest(
                kind: .reject,
                repositoryID: fixture.repositoryID,
                proposalID: fixture.proposal.id,
                resolvedRevisionID: nil
            ),
            decidedBy: "human-mini"
        )

        XCTAssertEqual(result.receipt.status, .rejected)
        XCTAssertNil(result.receipt.resolvedRevisionID)
        XCTAssertTrue(result.runtimeUnchanged)
        XCTAssertEqual(
            try fixture.store.loadRepository(id: fixture.repositoryID)
                .canonicalRevision,
            canonicalBefore
        )
        XCTAssertEqual(
            try fixture.store.loadMergeProposals(
                repositoryID: fixture.repositoryID
            ).first?.status,
            .rejected
        )
    }

    func testMergeDecisionActorIsAlwaysAStoreSafeIdentifier() {
        XCTAssertEqual(
            SkilletMergeDecisionExecutor.currentActor(
                environment: ["TATWO_DEVICE_NAME": "MacBook Pro / 外出"],
                hostName: "ignored"
            ),
            "human-MacBook-Pro"
        )
    }

    private func makeMergeFixture(
        repositoryID: String,
        includeMergedRevision: Bool,
        conflict: Bool
    ) throws -> (
        root: URL,
        storeRoot: URL,
        runtimeRoot: URL,
        store: TatwoSkilletRepositoryStore,
        repositoryID: String,
        proposal: TatwoMergeProposalV1,
        proposed: TatwoSkillRevisionV1,
        merged: TatwoSkillRevisionV1?
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-app-merge-\(UUID().uuidString)",
                isDirectory: true
            )
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: runtimeRoot,
            withIntermediateDirectories: true
        )
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        try Data("base\n".utf8).write(
            to: source.appendingPathComponent("SKILL.md")
        )
        let base = try store.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: repositoryID,
            summary: "App merge fixture",
            sourceDirectory: source,
            channel: .stable,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try Data("proposed\n".utf8).write(
            to: source.appendingPathComponent("SKILL.md")
        )
        let proposed = try store.snapshotDetachedSkillDirectory(
            repositoryID: repositoryID,
            displayName: repositoryID,
            summary: "App merge fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let merged: TatwoSkillRevisionV1?
        if includeMergedRevision {
            try Data("merged\n".utf8).write(
                to: source.appendingPathComponent("SKILL.md")
            )
            merged = try store.snapshotDetachedSkillDirectory(
                repositoryID: repositoryID,
                displayName: repositoryID,
                summary: "App merge fixture",
                sourceDirectory: source,
                channel: .staging,
                parentRevisionID: base.id,
                createdAt: Date(timeIntervalSince1970: 3)
            )
        } else {
            merged = nil
        }
        let conflicts: [TatwoSkilletMergeConflictArtifactV1]
        if conflict {
            conflicts = [
                TatwoSkilletMergeConflictArtifactV1(
                    id: "conflict-\(digest("\(repositoryID)-conflict"))",
                    repositoryID: repositoryID,
                    sourceDeviceID: "macbook",
                    baseRevisionID: base.id,
                    canonicalRevisionID: base.id,
                    proposedRevisionID: proposed.id,
                    relativePath: "SKILL.md",
                    kind: .overlappingTextEdits,
                    baseContentDigest: base.contentDigest,
                    canonicalContentDigest: base.contentDigest,
                    proposedContentDigest: proposed.contentDigest
                )
            ]
        } else {
            conflicts = []
        }
        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("\(repositoryID)-proposal"))",
            repositoryID: repositoryID,
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            mergedRevisionID: merged?.id,
            conflictArtifactIDs: conflicts.map(\.id),
            createdAt: Date(timeIntervalSince1970: 4)
        )
        try store.persistMergeProposal(proposal, conflicts: conflicts)
        return (
            root,
            storeRoot,
            runtimeRoot,
            store,
            repositoryID,
            proposal,
            proposed,
            merged
        )
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

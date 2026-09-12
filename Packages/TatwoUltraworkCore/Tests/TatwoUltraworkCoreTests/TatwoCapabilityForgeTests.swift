import XCTest
@testable import TatwoUltraworkCore

final class TatwoCapabilityForgeTests: XCTestCase {
    func testSyncCatalogRejectsPersistentSurfaceWithoutRegistration() throws {
        let catalog = TatwoSyncCatalogV1(entries: [
            .init(
                id: "os.issue",
                displayName: "issue.md",
                kind: .osDocument,
                scope: .shared,
                relativePath: "os/issue.md",
                mergePolicy: .markdownSections,
                activationPolicy: .automaticAfterValidation,
                requiredOnDevices: ["mac-mini", "macbook"]
            )
        ])

        XCTAssertThrowsError(
            try catalog.validatePersistentSurfaceIDs(["os.issue", "os.todo"])
        ) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogError,
                .unregisteredPersistentSurface(["os.todo"])
            )
        }
    }

    func testSyncCatalogRejectsForbiddenEntryWithTransferPath() {
        let catalog = TatwoSyncCatalogV1(entries: [
            .init(
                id: "secret.keychain",
                displayName: "Keychain",
                kind: .machineLocal,
                scope: .forbidden,
                relativePath: "secrets/keychain.json",
                mergePolicy: .never,
                activationPolicy: .never,
                requiredOnDevices: []
            )
        ])

        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogError,
                .forbiddenEntryHasTransferPath("secret.keychain")
            )
        }
    }

    func testSyncCatalogRejectsLocalOnlyEntryWithTransferPath() {
        let catalog = TatwoSyncCatalogV1(entries: [
            .init(
                id: "machine.launchagents",
                displayName: "LaunchAgents",
                kind: .machineLocal,
                scope: .localOnly,
                relativePath: "Library/LaunchAgents",
                mergePolicy: .never,
                activationPolicy: .never,
                requiredOnDevices: []
            )
        ])

        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogError,
                .localOnlyEntryHasTransferPath("machine.launchagents")
            )
        }
    }

    func testSyncCatalogRequiresNeverPoliciesForForbiddenEntries() {
        let catalog = TatwoSyncCatalogV1(entries: [
            .init(
                id: "secret.sessions",
                displayName: "Private sessions",
                kind: .machineLocal,
                scope: .forbidden,
                relativePath: nil,
                mergePolicy: .replaceAfterValidation,
                activationPolicy: .automaticAfterValidation,
                requiredOnDevices: []
            )
        ])

        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogError,
                .nonTransferableEntryRequiresNeverPolicies("secret.sessions")
            )
        }
    }

    func testConvergenceRequiresEveryRequiredItemVerifiedWithMatchingHashes() {
        let manifest = TatwoSyncManifestV1(
            id: "sync-1",
            sourceDeviceID: "mac-mini",
            targetDeviceID: "macbook",
            catalogRevision: "catalog-a",
            authorityEpoch: 7,
            items: [
                .init(
                    catalogID: "os.issue",
                    displayName: "issue.md",
                    required: true,
                    sourceDigest: "aaa"
                ),
                .init(
                    catalogID: "skill.tatwo-ultrawork",
                    displayName: "tatwo-ultrawork",
                    required: true,
                    sourceDigest: "bbb"
                )
            ]
        )

        let partial = TatwoConvergenceEvaluatorV1.evaluate(
            manifest: manifest,
            progress: [
                .init(
                    manifestID: "sync-1",
                    catalogID: "os.issue",
                    phase: .verified,
                    sourceDigest: "aaa",
                    appliedDigest: "aaa",
                    message: "verified",
                    authorityEpoch: 7,
                    ledgerSequence: 1
                ),
                .init(
                    manifestID: "sync-1",
                    catalogID: "skill.tatwo-ultrawork",
                    phase: .delivered,
                    sourceDigest: "bbb",
                    appliedDigest: nil,
                    message: "request delivered",
                    authorityEpoch: 7,
                    ledgerSequence: 2
                )
            ]
        )

        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.missingOrDivergedCatalogIDs, ["skill.tatwo-ultrawork"])

        let converged = TatwoConvergenceEvaluatorV1.evaluate(
            manifest: manifest,
            progress: [
                .init(
                    manifestID: "sync-1",
                    catalogID: "os.issue",
                    phase: .verified,
                    sourceDigest: "aaa",
                    appliedDigest: "aaa",
                    message: "verified",
                    authorityEpoch: 7,
                    ledgerSequence: 3
                ),
                .init(
                    manifestID: "sync-1",
                    catalogID: "skill.tatwo-ultrawork",
                    phase: .verified,
                    sourceDigest: "bbb",
                    appliedDigest: "bbb",
                    message: "verified",
                    authorityEpoch: 7,
                    ledgerSequence: 4
                )
            ]
        )

        XCTAssertEqual(converged.state, .converged)
        XCTAssertTrue(converged.missingOrDivergedCatalogIDs.isEmpty)
    }

    func testDivergentDigestNeverConverges() {
        let manifest = TatwoSyncManifestV1(
            id: "sync-2",
            sourceDeviceID: "mac-mini",
            targetDeviceID: "macbook",
            catalogRevision: "catalog-a",
            authorityEpoch: 8,
            items: [
                .init(
                    catalogID: "os.issue",
                    displayName: "issue.md",
                    required: true,
                    sourceDigest: "expected"
                )
            ]
        )

        let result = TatwoConvergenceEvaluatorV1.evaluate(
            manifest: manifest,
            progress: [
                .init(
                    manifestID: "sync-2",
                    catalogID: "os.issue",
                    phase: .verified,
                    sourceDigest: "expected",
                    appliedDigest: "different",
                    message: "wrong content",
                    authorityEpoch: 8,
                    ledgerSequence: 1
                )
            ]
        )

        XCTAssertEqual(result.state, .diverged)
        XCTAssertEqual(result.missingOrDivergedCatalogIDs, ["os.issue"])
    }

    func testConvergenceUsesAuthorityEpochAndLedgerSequenceInsteadOfWallClock() {
        let manifest = TatwoSyncManifestV1(
            id: "sync-ledger-order",
            sourceDeviceID: "mac-mini",
            targetDeviceID: "macbook",
            catalogRevision: "catalog-a",
            authorityEpoch: 9,
            items: [
                .init(
                    catalogID: "os.issue",
                    displayName: "issue.md",
                    required: true,
                    sourceDigest: "expected"
                )
            ]
        )

        let result = TatwoConvergenceEvaluatorV1.evaluate(
            manifest: manifest,
            progress: [
                .init(
                    manifestID: manifest.id,
                    catalogID: "os.issue",
                    phase: .failed,
                    sourceDigest: "expected",
                    appliedDigest: nil,
                    message: "older ledger entry with a future wall clock",
                    authorityEpoch: 9,
                    ledgerSequence: 10,
                    recordedAt: Date(timeIntervalSince1970: 500)
                ),
                .init(
                    manifestID: manifest.id,
                    catalogID: "os.issue",
                    phase: .verified,
                    sourceDigest: "expected",
                    appliedDigest: "expected",
                    message: "newer ledger entry",
                    authorityEpoch: 9,
                    ledgerSequence: 11,
                    recordedAt: Date(timeIntervalSince1970: 100)
                ),
                .init(
                    manifestID: manifest.id,
                    catalogID: "os.issue",
                    phase: .verified,
                    sourceDigest: "expected",
                    appliedDigest: "expected",
                    message: "stale authority epoch must be ignored",
                    authorityEpoch: 8,
                    ledgerSequence: 99,
                    recordedAt: Date(timeIntervalSince1970: 900)
                )
            ]
        )

        XCTAssertEqual(result.state, .converged)
        XCTAssertEqual(result.verifiedCatalogIDs, ["os.issue"])
    }

    func testConvergenceRejectsEmptyRequiredManifestAndAmbiguousLedgerSequence() {
        let empty = TatwoSyncManifestV1(
            id: "sync-empty",
            sourceDeviceID: "mac-mini",
            targetDeviceID: "macbook",
            catalogRevision: "catalog-a",
            authorityEpoch: 10,
            items: [
                .init(
                    catalogID: "optional",
                    displayName: "Optional",
                    required: false,
                    sourceDigest: "optional"
                )
            ]
        )
        let emptyResult = TatwoConvergenceEvaluatorV1.evaluate(
            manifest: empty,
            progress: []
        )
        XCTAssertEqual(emptyResult.state, .partial)
        XCTAssertEqual(
            emptyResult.missingOrDivergedCatalogIDs,
            ["manifest.required-items"]
        )

        let manifest = TatwoSyncManifestV1(
            id: "sync-ambiguous",
            sourceDeviceID: "mac-mini",
            targetDeviceID: "macbook",
            catalogRevision: "catalog-a",
            authorityEpoch: 10,
            items: [
                .init(
                    catalogID: "os.issue",
                    displayName: "issue.md",
                    required: true,
                    sourceDigest: "expected"
                )
            ]
        )
        let ambiguous = TatwoConvergenceEvaluatorV1.evaluate(
            manifest: manifest,
            progress: [
                .init(
                    manifestID: manifest.id,
                    catalogID: "os.issue",
                    phase: .verified,
                    sourceDigest: "expected",
                    appliedDigest: "expected",
                    message: "first writer",
                    authorityEpoch: 10,
                    ledgerSequence: 4
                ),
                .init(
                    manifestID: manifest.id,
                    catalogID: "os.issue",
                    phase: .failed,
                    sourceDigest: "expected",
                    appliedDigest: nil,
                    message: "conflicting writer",
                    authorityEpoch: 10,
                    ledgerSequence: 4
                )
            ]
        )
        XCTAssertEqual(ambiguous.state, .diverged)
        XCTAssertEqual(ambiguous.missingOrDivergedCatalogIDs, ["os.issue"])
    }

    func testConvergenceTreatsExactHighestSequenceReplayAsIdempotent() {
        let manifest = TatwoSyncManifestV1(
            id: "sync-idempotent",
            sourceDeviceID: "mac-mini",
            targetDeviceID: "macbook",
            catalogRevision: "catalog-a",
            authorityEpoch: 11,
            items: [
                .init(
                    catalogID: "os.issue",
                    displayName: "issue.md",
                    required: true,
                    sourceDigest: "expected"
                )
            ]
        )
        let receipt = TatwoSyncProgressReceiptV1(
            manifestID: manifest.id,
            catalogID: "os.issue",
            phase: .verified,
            sourceDigest: "expected",
            appliedDigest: "expected",
            message: "verified",
            authorityEpoch: 11,
            ledgerSequence: 8,
            recordedAt: Date(timeIntervalSince1970: 100)
        )
        let replay = TatwoSyncProgressReceiptV1(
            manifestID: receipt.manifestID,
            catalogID: receipt.catalogID,
            phase: receipt.phase,
            sourceDigest: receipt.sourceDigest,
            appliedDigest: receipt.appliedDigest,
            message: receipt.message,
            authorityEpoch: receipt.authorityEpoch,
            ledgerSequence: receipt.ledgerSequence,
            recordedAt: Date(timeIntervalSince1970: 900)
        )

        let result = TatwoConvergenceEvaluatorV1.evaluate(
            manifest: manifest,
            progress: [receipt, replay]
        )

        XCTAssertEqual(result.state, .converged)
        XCTAssertEqual(result.verifiedCatalogIDs, ["os.issue"])
    }

    func testSkilletRepositoryDerivesHealthFromRevisionAndDeviceHeads() {
        let repository = TatwoCapabilityRepositoryV1(
            id: "tatwo-ultrawork",
            displayName: "TATWO Ultrawork",
            summary: "Work OS",
            canonicalRevision: "rev-stable",
            stableRevision: "rev-stable",
            canaryRevision: "rev-canary",
            revisions: [
                .init(
                    id: "rev-stable",
                    repositoryID: "tatwo-ultrawork",
                    parentRevisionID: nil,
                    contentDigest: "stable-digest",
                    channel: .stable,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                .init(
                    id: "rev-canary",
                    repositoryID: "tatwo-ultrawork",
                    parentRevisionID: "rev-stable",
                    contentDigest: "canary-digest",
                    channel: .canary,
                    createdAt: Date(timeIntervalSince1970: 2)
                )
            ],
            deviceHeads: [
                .init(
                    deviceID: "mac-mini",
                    repositoryID: "tatwo-ultrawork",
                    revisionID: "rev-stable",
                    activationState: .active,
                    lastVerifiedAt: Date(timeIntervalSince1970: 3)
                ),
                .init(
                    deviceID: "macbook",
                    repositoryID: "tatwo-ultrawork",
                    revisionID: "rev-canary",
                    activationState: .canary,
                    lastVerifiedAt: Date(timeIntervalSince1970: 4)
                )
            ]
        )

        XCTAssertEqual(repository.health, .canary)
        XCTAssertEqual(repository.compatibleDeviceCount, 0)
        XCTAssertTrue(repository.verifiedDeviceHeads(receipts: []).isEmpty)
    }

    func testVerifiedDeviceCountRequiresActiveCanonicalHeadAndMatchingReceipt() {
        let digest = String(repeating: "a", count: 64)
        let revisionID = "rev-\(digest)"
        let verifiedAt = Date(timeIntervalSince1970: 100)
        let head = TatwoDeviceHeadV1(
            deviceID: "macbook",
            repositoryID: "fixture",
            revisionID: revisionID,
            contentDigest: digest,
            requestID: "request-12",
            authorityEpoch: 7,
            ledgerSequence: 12,
            activationState: .active,
            lastVerifiedAt: verifiedAt
        )
        let repository = TatwoCapabilityRepositoryV1(
            id: "fixture",
            displayName: "Fixture",
            summary: "Fixture",
            canonicalRevision: revisionID,
            stableRevision: revisionID,
            canaryRevision: nil,
            revisions: [
                TatwoSkillRevisionV1(
                    id: revisionID,
                    repositoryID: "fixture",
                    parentRevisionID: nil,
                    contentDigest: digest,
                    channel: .stable,
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ],
            deviceHeads: [head]
        )
        let matching = TatwoSkilletRepositoryReceiptV1(
            id: "device-macbook-e7-s12-request-12",
            repositoryID: "fixture",
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
        let stale = TatwoSkilletRepositoryReceiptV1(
            id: "device-macbook-e7-s11-request-11",
            repositoryID: "fixture",
            revisionID: revisionID,
            kind: .deviceHead,
            contentDigest: digest,
            deviceID: "macbook",
            requestID: "request-11",
            authorityEpoch: 7,
            ledgerSequence: 11,
            activationState: .active,
            recordedAt: verifiedAt,
            message: "stale"
        )

        XCTAssertTrue(repository.verifiedDeviceHeads(receipts: []).isEmpty)
        XCTAssertTrue(repository.verifiedDeviceHeads(receipts: [stale]).isEmpty)
        XCTAssertEqual(repository.verifiedDeviceHeads(receipts: [matching]), [head])
        XCTAssertEqual(
            repository.matchingDeviceReceipt(for: head, receipts: [matching]),
            matching
        )
    }
}

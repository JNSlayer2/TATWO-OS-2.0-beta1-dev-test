import CryptoKit
import Foundation
import XCTest
@_spi(TatwoHumanGateApp) @testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class GoalRevisionConfirmationTests: XCTestCase {
    func testApproveForMeIssuesExactRevisionBoundHostAuthorizationAfterActivationTokenExpires()
        throws
    {
        try withPlannedCurrent { fixture in
            let staging = try makeStagingRevisionIssuerArtifact()
            defer {
                try? FileManager.default.removeItem(
                    at: staging.bundleURL.deletingLastPathComponent())
            }
            let challenge = try prepareChallenge(
                fixture,
                scenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLFableGrokScenarioID,
                artifact: staging.artifact)
            let result = try TatwoGoalRevisionCoordinator.confirm(
                challenge: challenge,
                newObjective:
                    "Revision-bound native host authorization smoke.",
                goalStore: fixture.goalStore,
                sessionStore: fixture.sessionStore,
                dispatchRegistry: fixture.dispatchRegistry,
                now: fixture.now,
                artifactProvider: { staging.artifact })
            XCTAssertEqual(result.transition.successor.status, .running)

            let operationTime = fixture.now.addingTimeInterval(60 * 60)
            let approvalStore = TatwoHostApprovalStore(
                directoryURL: fixture.root.appendingPathComponent(
                    "host-executor/approvals",
                    isDirectory: true),
                goalRunStore: fixture.goalStore)
            let content = "native revision write\n"
            let contentDigest = SHA256.hash(data: Data(content.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let argumentDigest =
                TatwoHostOperationAuthorizationV1.argumentDigest(
                    action: .writeFile,
                    components: ["native-auth.txt", contentDigest])
            let request = TatwoNativeHostAuthorizationRequest(
                action: .writeFile,
                argumentDigest: argumentDigest,
                isMutation: true)
            let issuer = ChatNativeHostOperationAuthorizationIssuer(
                approvalStore: approvalStore,
                contractID: result.transition.successor.contractID,
                workspaceRoot: fixture.root.path,
                permissionPreset: .approveForMe,
                now: { operationTime })
            let authorizationID = try issuer.authorizationID(for: request)
            let lease = try approvalStore.issueHostOperationBound(
                authorizationID: authorizationID,
                sessionStore: fixture.sessionStore,
                now: operationTime)
            let readback = try approvalStore.require(
                id: lease.id,
                contractID: result.transition.successor.contractID,
                workspaceRoot: fixture.root.path,
                action: .writeFile,
                argumentDigest: argumentDigest,
                isMutation: true,
                now: operationTime)

            XCTAssertEqual(readback, lease)
            XCTAssertEqual(readback.argumentDigest, argumentDigest)
            XCTAssertEqual(
                readback.hostOperationAuthorizationID,
                authorizationID)
        }
    }

    func testConfirmAllowsPrivateTmpStagingIssuerForRevisionActivationOnly()
        throws
    {
        try withPlannedCurrent { fixture in
            let staging = try makeStagingRevisionIssuerArtifact()
            defer {
                try? FileManager.default.removeItem(
                    at: staging.bundleURL.deletingLastPathComponent())
            }
            let challenge = try prepareChallenge(
                fixture,
                scenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLFableGrokScenarioID,
                artifact: staging.artifact)
            XCTAssertEqual(
                challenge.requestedHostScope,
                .revisionActivationOnly)

            let result = try TatwoGoalRevisionCoordinator.confirm(
                challenge: challenge,
                newObjective:
                    "Revision-only staging successor for Fable then Grok.",
                goalStore: fixture.goalStore,
                sessionStore: fixture.sessionStore,
                dispatchRegistry: fixture.dispatchRegistry,
                now: fixture.now,
                artifactProvider: { staging.artifact })

            XCTAssertEqual(result.transition.predecessor.status, .superseded)
            XCTAssertEqual(result.transition.successor.status, .running)
            XCTAssertEqual(
                result.issuerArtifact.identity.bundleIdentifier,
                staging.artifact.identity.bundleIdentifier)
        }
    }

    func testPrepareRejectsStagingIssuerOutsidePrivateTmp() throws {
        try withRunningCurrent { fixture in
            let outsideRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "tatwo-staging-issuer-outside-\(UUID().uuidString)",
                    isDirectory: true)
            let staging = try makeStagingRevisionIssuerArtifact(
                root: outsideRoot)
            defer {
                try? FileManager.default.removeItem(at: outsideRoot)
            }

            XCTAssertThrowsError(
                try prepareChallenge(
                    fixture,
                    artifact: staging.artifact)
            ) { error in
                assertOperationFailure(error, contains: "private/tmp")
            }
        }
    }

    func testPrepareAcceptsCanonicalRuntimePathWhenSignedBundleDeclaresPrivateTmp()
        throws
    {
        try withRunningCurrent { fixture in
            let staging = try makeStagingRevisionIssuerArtifact()
            defer {
                try? FileManager.default.removeItem(
                    at: staging.bundleURL.deletingLastPathComponent())
            }
            let canonicalArtifact = TatwoGoalRevisionIssuerArtifactEvidence(
                identity: staging.artifact.identity,
                executableURL:
                    staging.artifact.executableURL.resolvingSymlinksInPath())

            let challenge = try prepareChallenge(
                fixture,
                artifact: canonicalArtifact)

            XCTAssertEqual(
                challenge.issuerArtifact.executableURL.path,
                staging.artifact.executableURL.path)
        }
    }

    func testPrepareRejectsStagingIssuerWithoutRevisionOnlyMarker() throws {
        try withRunningCurrent { fixture in
            let staging = try makeStagingRevisionIssuerArtifact(
                includeRevisionMarker: false)
            defer {
                try? FileManager.default.removeItem(
                    at: staging.bundleURL.deletingLastPathComponent())
            }

            XCTAssertThrowsError(
                try prepareChallenge(
                    fixture,
                    artifact: staging.artifact)
            ) { error in
                assertOperationFailure(
                    error,
                    contains: "revision activation marker")
            }
        }
    }

    func testPrepareRejectsStagingIssuerWithExecutableHashMismatch() throws {
        try withRunningCurrent { fixture in
            let staging = try makeStagingRevisionIssuerArtifact(
                executableSHA256Override: String(repeating: "f", count: 64))
            defer {
                try? FileManager.default.removeItem(
                    at: staging.bundleURL.deletingLastPathComponent())
            }

            XCTAssertThrowsError(
                try prepareChallenge(
                    fixture,
                    artifact: staging.artifact)
            ) { error in
                assertOperationFailure(
                    error,
                    contains: "executable hash")
            }
        }
    }

    func testPrepareAndConfirmUseValidatedIssuedContractWhenScenarioBindingsDrift()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-app-goal-revision-binding-drift-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        let dispatchRegistry = TatwoDispatchRegistry(directoryURL: root)
        let scenarioID =
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID
        let legacyBook = legacyFourBindingFableGrokBook()
        let objective =
            "Current four-binding Fable to Grok Goal requires canonical revision."
        let predecessor = try WorkOSFactory.projectContract(
            mode: .xxl,
            scenarioProfileID: scenarioID,
            objective: objective,
            scenarioBook: legacyBook)
        XCTAssertEqual(predecessor.identityBindings.count, 4)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: root,
            contractID: predecessor.contractID)
        _ = try sessionStore.beginCurrent(
            mode: .xxl,
            scenarioProfileID: scenarioID,
            objective: objective,
            scenarioBook: legacyBook,
            owner: .thread(
                TatwoSessionOwnerExpectationV1(
                    provider: "tatwo-app-test",
                    externalProviderSessionID: "binding-drift",
                    workspacePath: root.path)),
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        let artifact = TatwoGoalRevisionIssuerArtifactEvidence(
            identity: TatwoHumanGateIssuerArtifactIdentityV1(
                bundleIdentifier: "com.tatwo.ultrawork",
                teamIdentifier: "TESTTEAM",
                codeDirectoryHash: "fixture-cdhash",
                executableSHA256: String(repeating: "a", count: 64)),
            executableURL: root.appendingPathComponent("TatwoUltraworkMac"))

        let challenge = try TatwoGoalRevisionCoordinator.prepare(
            selection: TatwoGoalRevisionSelection(
                mode: .xxl,
                scenarioProfileID: scenarioID,
                scenarioBook: TatwoScenarioConfigDefaults.book,
                loopPresetID: "recommended",
                enabledLoopTemplateIDs: nil),
            goalStore: goalStore,
            sessionStore: sessionStore,
            challengeID: "binding-drift-challenge",
            now: Date(timeIntervalSince1970: 1_800_000_000),
            artifactProvider: { artifact })
        let proposal = try challenge.proposal(
            newObjective:
                "Revised six-binding Fable to Grok Goal with the same protected scope.")

        XCTAssertEqual(challenge.oldBindings.count, 4)
        XCTAssertEqual(proposal.newBindings.count, 6)
        XCTAssertEqual(challenge.oldContract.contractID, predecessor.contractID)

        let result = try TatwoGoalRevisionCoordinator.confirm(
            challenge: challenge,
            newObjective:
                "Revised six-binding Fable to Grok Goal with the same protected scope.",
            goalStore: goalStore,
            sessionStore: sessionStore,
            dispatchRegistry: dispatchRegistry,
            now: Date(timeIntervalSince1970: 1_800_000_001),
            artifactProvider: { artifact })

        XCTAssertEqual(result.transition.predecessor.status, .superseded)
        XCTAssertEqual(result.transition.successor.status, .running)
        XCTAssertEqual(
            result.readback.goalRecord.issuedIdentityBindings?.count,
            6)
    }

    func testAuthorityBootstrapProposalPreservesCanonicalOwnerKind() {
        let root = URL(
            fileURLWithPath: "/tmp/tatwo-bootstrap-owner-kind",
            isDirectory: true)
        let preflight = TatwoSessionAuthorityLockPreflightV1(
            canonicalGoalStoreRootPath: root.path,
            contractID: "contract-m-coding-ownerkind",
            rootDeviceID: 1,
            rootInode: 2,
            presentArtifactNames: [],
            artifactFingerprints: [])
        let expectation = TatwoSessionOwnerExpectationV1(
            provider: "codex",
            externalProviderSessionID: "same-provider-id",
            workspacePath: root.appendingPathComponent(
                "workspace", isDirectory: true).path)
        let sessionProposal = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: root,
            contractID: preflight.contractID,
            owner: .session(expectation),
            preflight: preflight,
            objectivePreview: "owner kind")
        let threadProposal = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: root,
            contractID: preflight.contractID,
            owner: .thread(expectation),
            preflight: preflight,
            objectivePreview: "owner kind")

        XCTAssertEqual(sessionProposal.owner.ownerKind, .session)
        XCTAssertEqual(threadProposal.owner.ownerKind, .thread)
        XCTAssertNotEqual(sessionProposal, threadProposal)
    }

    func testAuthorityBootstrapProposalRecognizesSafeLegacyLifecycleMigration() {
        let root = URL(
            fileURLWithPath: "/tmp/tatwo-bootstrap-legacy-lifecycle",
            isDirectory: true)
        let contractID =
            "contract-xxl-general-xxl-sol-opus5-luna-grok-exact-test"
        let preflight = TatwoSessionAuthorityLockPreflightV1(
            canonicalGoalStoreRootPath: root.path,
            contractID: contractID,
            rootDeviceID: 1,
            rootInode: 2,
            presentArtifactNames: [
                TatwoGoalStoreLifecycleLock.lifecycleDirectoryName
            ],
            artifactFingerprints: [])
        let proposal = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: root,
            contractID: contractID,
            owner: TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread("legacy-lifecycle-migration"),
                workspacePath: root.path),
            preflight: preflight,
            objectivePreview: "migrate legacy lifecycle directory")

        XCTAssertEqual(
            proposal.bootstrapDispositionPreview,
            "create_global_and_contract_lifecycle_preserving_existing_directory")
    }

    @MainActor
    func testExplicitUserOwnedAuthorityBootstrapConsumesFreshReadback()
        throws
    {
        let fixture = try makeAuthorityBootstrapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertTrue(
            try fixture.model
                .bootstrapAndConsumeExplicitUserOwnedActivation(
                    fixture.proposal))
        XCTAssertNil(fixture.model.pendingProposal)
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(
                for: fixture.proposal),
            "automatic bootstrap confirmation must be single-use")

        let nonUserOwnedProposal =
            TatwoAppAuthorityBootstrapProposalV1(
                goalStoreRoot: fixture.root,
                contractID: fixture.contractID,
                owner: TatwoCanonicalSessionOwnerV1(
                    provider: "codex",
                    locator: .thread("provider-mirror"),
                    workspacePath: fixture.owner.workspacePath),
                preflight:
                    try TatwoSessionAuthorityLockBootstrap
                        .preflightSnapshot(
                            goalStoreRoot: fixture.root,
                            contractID: fixture.contractID),
                objectivePreview:
                    fixture.proposal.objectivePreview)
        XCTAssertThrowsError(
            try fixture.model
                .bootstrapAndConsumeExplicitUserOwnedActivation(
                    nonUserOwnedProposal))
    }

    @MainActor
    func testAuthorityBootstrapRejectsOwnerObjectiveRootAndContractMismatch()
        async throws
    {
        let fixture = try makeAuthorityBootstrapFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let proposal = fixture.proposal
        fixture.model.stage(proposal)
        await fixture.model.confirmPending()
        XCTAssertNil(fixture.model.errorMessage)

        let mismatchedOwner = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: fixture.root,
            contractID: fixture.contractID,
            owner: TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread("other-thread"),
                workspacePath: fixture.owner.workspacePath),
            preflight: proposal.preflight,
            objectivePreview: proposal.objectivePreview)
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: mismatchedOwner))

        let mismatchedObjective = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: fixture.root,
            contractID: fixture.contractID,
            owner: fixture.owner,
            preflight: proposal.preflight,
            objectivePreview: "different objective")
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: mismatchedObjective))

        let otherRoot = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent(
                "tatwo-bootstrap-other-root-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherRoot,
            withIntermediateDirectories: true)
        let otherPreflight =
            try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
                goalStoreRoot: otherRoot,
                contractID: fixture.contractID)
        let mismatchedRoot = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: otherRoot,
            contractID: fixture.contractID,
            owner: fixture.owner,
            preflight: otherPreflight,
            objectivePreview: proposal.objectivePreview)
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: mismatchedRoot))

        let otherContractID = "contract-m-coding-otherbootstrap01"
        let contractPreflight =
            try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
                goalStoreRoot: fixture.root,
                contractID: otherContractID)
        let mismatchedContract = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: fixture.root,
            contractID: otherContractID,
            owner: fixture.owner,
            preflight: contractPreflight,
            objectivePreview: proposal.objectivePreview)
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: mismatchedContract))

        let currentPreflight =
            try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
                goalStoreRoot: fixture.root,
                contractID: fixture.contractID)
        let currentProposal = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: fixture.root,
            contractID: fixture.contractID,
            owner: fixture.owner,
            preflight: currentPreflight,
            objectivePreview: proposal.objectivePreview)
        XCTAssertTrue(
            fixture.model.consumeConfirmedReadback(for: currentProposal))
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: currentProposal),
            "confirmed readback is single-use and must reject replay")
    }

    @MainActor
    func testAuthorityBootstrapRejectsPreflightDriftCreatedDispositionTTLAndDismiss()
        async throws
    {
        let fixture = try makeAuthorityBootstrapFixture(ttl: 60)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.stage(fixture.proposal)
        fixture.model.dismissPending()
        XCTAssertNil(fixture.model.pendingProposal)
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: fixture.proposal))

        let createdReadback =
            try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
                goalStoreRoot: fixture.root,
                contractID: fixture.contractID,
                expectedPreflight: fixture.proposal.preflight,
                createdAt: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(createdReadback.disposition, .created)
        fixture.model.installConfirmedForTesting(
            TatwoAppAuthorityBootstrapConfirmationV1(
                proposal: fixture.proposal,
                readback: createdReadback))
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: fixture.proposal))

        let freshPreflight =
            try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
                goalStoreRoot: fixture.root,
                contractID: fixture.contractID)
        let readback =
            try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
                goalStoreRoot: fixture.root,
                contractID: fixture.contractID,
                expectedPreflight: freshPreflight,
                createdAt: Date(timeIntervalSince1970: 401))
        XCTAssertEqual(readback.disposition, .validatedExisting)

        let stalePreflightProposal = fixture.proposal
        fixture.model.installConfirmedForTesting(
            TatwoAppAuthorityBootstrapConfirmationV1(
                proposal: stalePreflightProposal,
                readback: readback))
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(
                for: stalePreflightProposal))

        let currentProposal = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: fixture.root,
            contractID: fixture.contractID,
            owner: fixture.owner,
            preflight: freshPreflight,
            objectivePreview: fixture.proposal.objectivePreview)
        fixture.model.installConfirmedForTesting(
            TatwoAppAuthorityBootstrapConfirmationV1(
                proposal: currentProposal,
                readback: readback,
                confirmedAt: Date(timeIntervalSince1970: 100),
                ttl: 60))
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: currentProposal))

        fixture.model.installConfirmedForTesting(
            TatwoAppAuthorityBootstrapConfirmationV1(
                proposal: currentProposal,
                readback: readback))
        XCTAssertTrue(
            fixture.model.consumeConfirmedReadback(for: currentProposal))
        XCTAssertFalse(
            fixture.model.consumeConfirmedReadback(for: currentProposal),
            "fresh confirmation must still be consumed exactly once")
    }

    func testProposalDiffIsExactDeterministicAndKeepsSelectedExactScenario()
        throws
    {
        try withRunningCurrent { fixture in
            let challenge = try prepareChallenge(fixture)
            let objective =
                "Ship App-confirmed Goal revision with exact XXL topology, "
                + "human gate evidence, stale detection, and no deployment."

            let first = try challenge.proposal(newObjective: objective)
            let second = try challenge.proposal(newObjective: objective)

            XCTAssertEqual(first, second)
            XCTAssertEqual(
                first.newContract.scenario,
                TatwoScenarioConfigDefaults
                    .exactXXLSolOpusLunaGrokScenarioID)
            XCTAssertEqual(first.newContract.objective, objective)
            XCTAssertFalse(first.capabilityChanges.isEmpty)
            XCTAssertEqual(
                first.capabilityChanges.map(\.bindingID),
                first.capabilityChanges.map(\.bindingID).sorted())
            XCTAssertEqual(
                first.newBindingsDigest,
                TatwoIssuedIdentityBindingV1.deterministicDigest(
                    for: TatwoIssuedIdentityBindingV1.canonicalSnapshot(
                        for: first.newContract)))
            XCTAssertEqual(
                first.requestedHostScopeDigest,
                second.requestedHostScopeDigest)
            XCTAssertEqual(
                first.humanGateSubjectDigest,
                second.humanGateSubjectDigest)
            XCTAssertTrue(
                first.newBindings.allSatisfy {
                    !$0.canonicalValue.isEmpty
                        && !$0.authority.rawValue.isEmpty
                })
        }
    }

    func testCancelByDiscardingPendingChallengeCausesZeroCanonicalMutation()
        throws
    {
        try withRunningCurrent { fixture in
            let beforePointer = try fixture.sessionStore.snapshotCurrent()
            let beforeGoal = try fixture.goalStore.snapshot(
                forContractID: fixture.old.contractID)
            var pending: TatwoGoalRevisionChallenge? =
                try prepareChallenge(fixture)

            pending = nil

            XCTAssertNil(pending)
            XCTAssertEqual(
                try fixture.sessionStore.snapshotCurrent(),
                beforePointer)
            XCTAssertEqual(
                try fixture.goalStore.snapshot(
                    forContractID: fixture.old.contractID),
                beforeGoal)
            XCTAssertEqual(
                try fixture.sessionStore.snapshotCurrent()?.pointer.contractID,
                fixture.old.contractID)
            XCTAssertEqual(
                try fixture.goalStore.requireIssuedContract(
                    fixture.old.contractID).status,
                .running)
        }
    }

    func testConfirmFailsClosedWhenExactPointerSnapshotBecomesStale()
        throws
    {
        try withRunningCurrent { fixture in
            let challenge = try prepareChallenge(fixture)
            let objective =
                "A distinct complete Goal objective for stale pointer testing."
            let candidate = try challenge.proposal(newObjective: objective)
            let pointer = try XCTUnwrap(
                fixture.sessionStore.snapshotCurrent()?.pointer)
            _ = try fixture.sessionStore.writeRawPointerFixtureForTesting(
                TatwoSessionPointer(
                    schema: pointer.schema,
                    contractID: pointer.contractID,
                    goalID: pointer.goalID,
                    mode: pointer.mode,
                    scenario: pointer.scenario,
                    objective: pointer.objective,
                    startedAt: pointer.startedAt,
                    ownerBinding: pointer.ownerBinding,
                    generation: (pointer.generation ?? 1) + 1
                ))

            XCTAssertThrowsError(
                try TatwoGoalRevisionCoordinator.confirm(
                    challenge: challenge,
                    newObjective: objective,
                    goalStore: fixture.goalStore,
                    sessionStore: fixture.sessionStore,
                    dispatchRegistry: fixture.dispatchRegistry,
                    now: fixture.now,
                    artifactProvider: { fixture.artifact })
            ) { error in
                XCTAssertEqual(
                    error as? TatwoGoalRevisionConfirmationError,
                    .staleCurrentSession)
            }
            XCTAssertNil(
                try fixture.goalStore.record(
                    forContractID: candidate.newContract.contractID))
            XCTAssertEqual(
                try fixture.goalStore.requireIssuedContract(
                    fixture.old.contractID).status,
                .running)
        }
    }

    func testConfirmPromotesSuccessorEndToEndAndSupersedesPredecessor()
        throws
    {
        try withRunningCurrent { fixture in
            let challenge = try prepareChallenge(fixture)
            let objective =
                "Implement the full App-confirmed revision workflow, preserve "
                + "the current chat session, and verify canonical cold read."

            let result = try TatwoGoalRevisionCoordinator.confirm(
                challenge: challenge,
                newObjective: objective,
                goalStore: fixture.goalStore,
                sessionStore: fixture.sessionStore,
                dispatchRegistry: fixture.dispatchRegistry,
                now: fixture.now,
                artifactProvider: { fixture.artifact })

            XCTAssertEqual(result.transition.predecessor.status, .superseded)
            XCTAssertEqual(result.transition.successor.status, .running)
            XCTAssertEqual(result.readback.contract.objective, objective)
            XCTAssertEqual(
                result.readback.contract.scenario,
                TatwoScenarioConfigDefaults
                    .exactXXLSolOpusLunaGrokScenarioID)
            XCTAssertEqual(
                result.pointerSnapshot.pointer.contractID,
                result.transition.successor.contractID)
            XCTAssertEqual(
                try fixture.goalStore.requireIssuedContract(
                    fixture.old.contractID).status,
                .superseded)
            XCTAssertEqual(
                result.transition.successor.predecessorContractID,
                fixture.old.contractID)
            XCTAssertEqual(
                result.transition.successor.supersession?
                    .humanGateReceiptID,
                "goal-revision-human-deterministic-challenge")
        }
    }

    func testConfirmPromotesPristinePlannedPredecessorBeforeDispatch()
        throws
    {
        try withPlannedCurrent { fixture in
            let challenge = try prepareChallenge(
                fixture,
                scenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLFableGrokScenarioID)
            let objective =
                "Preserve the Island then Aurora objective while revising "
                + "the pristine Fable to Grok execution topology."

            let result = try TatwoGoalRevisionCoordinator.confirm(
                challenge: challenge,
                newObjective: objective,
                goalStore: fixture.goalStore,
                sessionStore: fixture.sessionStore,
                dispatchRegistry: fixture.dispatchRegistry,
                now: fixture.now,
                artifactProvider: { fixture.artifact })

            XCTAssertEqual(result.transition.predecessor.status, .superseded)
            XCTAssertEqual(result.transition.successor.status, .running)
            XCTAssertEqual(
                result.readback.contract.scenario,
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID)
            XCTAssertEqual(
                result.readback.goalRecord.issuedIdentityBindings?.count,
                6)
        }
    }

    func testProposalRejectsPlaceholderEmptyAndReusedPredecessorObjective()
        throws
    {
        try withRunningCurrent { fixture in
            let challenge = try prepareChallenge(fixture)

            for invalid in [
                "",
                challenge.initialNewObjective,
                challenge.oldContract.objective
            ] {
                XCTAssertThrowsError(
                    try challenge.proposal(newObjective: invalid)
                ) { error in
                    guard case .some(.invalidNewObjective) =
                        error as? TatwoGoalRevisionConfirmationError
                    else {
                        return XCTFail("expected invalidNewObjective: \(error)")
                    }
                }
            }
        }
    }

    func testConfirmRejectsChangedIssuerArtifactBeforeCandidateMutation()
        throws
    {
        try withRunningCurrent { fixture in
            let challenge = try prepareChallenge(fixture)
            let objective =
                "A distinct objective whose App issuer must remain exact."
            let candidate = try challenge.proposal(
                newObjective: objective)
            let changedArtifact =
                TatwoGoalRevisionIssuerArtifactEvidence(
                    identity:
                        TatwoHumanGateIssuerArtifactIdentityV1(
                            bundleIdentifier:
                                fixture.artifact.identity.bundleIdentifier,
                            teamIdentifier:
                                fixture.artifact.identity.teamIdentifier,
                            codeDirectoryHash:
                                fixture.artifact.identity.codeDirectoryHash,
                            executableSHA256:
                                String(repeating: "c", count: 64)),
                    executableURL: fixture.artifact.executableURL)

            XCTAssertThrowsError(
                try TatwoGoalRevisionCoordinator.confirm(
                    challenge: challenge,
                    newObjective: objective,
                    goalStore: fixture.goalStore,
                    sessionStore: fixture.sessionStore,
                    dispatchRegistry: fixture.dispatchRegistry,
                    now: fixture.now,
                    artifactProvider: { changedArtifact })
            ) { error in
                XCTAssertEqual(
                    error as? TatwoGoalRevisionConfirmationError,
                    .issuerArtifactChanged)
            }
            XCTAssertNil(
                try fixture.goalStore.record(
                    forContractID:
                        candidate.newContract.contractID))
            XCTAssertEqual(
                try fixture.goalStore.requireIssuedContract(
                    fixture.old.contractID).status,
                .running)
        }
    }

    func testPostBeginAuthorizationConflictRollsBackOnlyThisCandidate()
        throws
    {
        try withRunningCurrent { fixture in
            let challenge = try prepareChallenge(fixture)
            let objective =
                "A distinct objective for rollback after candidate begin."
            let candidate = try challenge.proposal(
                newObjective: objective)
            _ = try TatwoAppHumanGateAuthorizationStore(
                stateDirectoryURL: fixture.root
            ).authorizeAfterHumanConfirmation(
                id: "goal-revision-human-deterministic-challenge",
                sessionID: challenge.sessionID,
                oldContractID: fixture.old.contractID,
                oldGoalID: fixture.old.goalID,
                newContractID:
                    candidate.newContract.contractID,
                newGoalID: candidate.newContract.goalID,
                subjectDigest:
                    "sha256:\(String(repeating: "0", count: 64))",
                issuerArtifactIdentity: fixture.artifact.identity,
                ttl: 600,
                now: fixture.now)

            XCTAssertThrowsError(
                try TatwoGoalRevisionCoordinator.confirm(
                    challenge: challenge,
                    newObjective: objective,
                    goalStore: fixture.goalStore,
                    sessionStore: fixture.sessionStore,
                    dispatchRegistry: fixture.dispatchRegistry,
                    now: fixture.now,
                    artifactProvider: { fixture.artifact })
            )
            XCTAssertNil(
                try fixture.goalStore.record(
                    forContractID:
                        candidate.newContract.contractID))
            XCTAssertEqual(
                try fixture.goalStore.requireIssuedContract(
                    fixture.old.contractID).status,
                .running)
            XCTAssertEqual(
                try fixture.sessionStore.snapshotCurrent()?
                    .pointer.contractID,
                fixture.old.contractID)
        }
    }

    func testSourceKeepsProposalAndColdReadMismatchInsideRollbackBoundary()
        throws
    {
        let source = try String(
            contentsOf: ChatPageSourceScanner.repoRoot()
                .appendingPathComponent(
                    "Apps/TatwoUltraworkMac/Sources/"
                        + "TatwoUltraworkMac/"
                        + "GoalRevisionConfirmation.swift"),
            encoding: .utf8)
        let candidateBegin = try XCTUnwrap(
            source.range(of: "recordBeginWithDisposition"))
        let proposalChanged = try XCTUnwrap(
            source.range(
                of:
                    "TatwoGoalRevisionConfirmationError.proposalChanged"))
        let transition = try XCTUnwrap(
            source.range(of: "transitionCurrentToPlannedRevision"))
        let coldReadMismatch = try XCTUnwrap(
            source.range(
                of:
                    "TatwoGoalRevisionConfirmationError.coldReadMismatch"))
        let rollback = try XCTUnwrap(
            source.range(of: "rollbackUnpublishedBegin"))

        XCTAssertLessThan(
            candidateBegin.lowerBound,
            proposalChanged.lowerBound)
        XCTAssertLessThan(
            proposalChanged.lowerBound,
            transition.lowerBound)
        XCTAssertLessThan(
            transition.lowerBound,
            coldReadMismatch.lowerBound)
        XCTAssertLessThan(
            coldReadMismatch.lowerBound,
            rollback.lowerBound)
    }

    private struct Fixture {
        let root: URL
        let goalStore: TatwoGoalRunStore
        let sessionStore: TatwoSessionStore
        let dispatchRegistry: TatwoDispatchRegistry
        let old: TatwoWorkOSContractV1
        let artifact: TatwoGoalRevisionIssuerArtifactEvidence
        let now: Date
    }

    private struct AuthorityBootstrapFixture {
        let root: URL
        let contractID: String
        let owner: TatwoCanonicalSessionOwnerV1
        let proposal: TatwoAppAuthorityBootstrapProposalV1
        let model: TatwoAppAuthorityBootstrapModel
    }

    @MainActor
    private func makeAuthorityBootstrapFixture(
        ttl: TimeInterval = TatwoAppAuthorityBootstrapModel
            .defaultConfirmationTTL
    ) throws -> AuthorityBootstrapFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-app-authority-bootstrap-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let contractID = "contract-m-coding-appbootstrap01"
        let owner = TatwoCanonicalSessionOwnerV1(
            provider: "tatwo-chat",
            locator: .thread("thread-app-bootstrap"),
            workspacePath: root.appendingPathComponent(
                "workspace", isDirectory: true).path)
        let preflight =
            try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
                goalStoreRoot: root,
                contractID: contractID)
        let proposal = TatwoAppAuthorityBootstrapProposalV1(
            goalStoreRoot: root,
            contractID: contractID,
            owner: owner,
            preflight: preflight,
            objectivePreview: "authority bootstrap fixture")
        return AuthorityBootstrapFixture(
            root: root,
            contractID: contractID,
            owner: owner,
            proposal: proposal,
            model: TatwoAppAuthorityBootstrapModel(
                confirmationTTL: ttl))
    }

    private func withRunningCurrent(
        _ body: (Fixture) throws -> Void
    ) throws {
        try withCurrent(activatePredecessor: true, body)
    }

    private func withPlannedCurrent(
        _ body: (Fixture) throws -> Void
    ) throws {
        try withCurrent(activatePredecessor: false, body)
    }

    private func withCurrent(
        activatePredecessor: Bool,
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-app-goal-revision-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        let dispatchRegistry = TatwoDispatchRegistry(directoryURL: root)
        let owner = TatwoSessionOwnerExpectationV1(
            provider: "tatwo-app-test",
            externalProviderSessionID: "goal-revision-confirmation",
            workspacePath: root.path)
        let predecessor = try WorkOSFactory.projectContract(
            mode: .m,
            scenarioProfileID: "coding",
            objective:
                "Current predecessor objective: analysis only, no install.")
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: root,
            contractID: predecessor.contractID)
        let attachment = try sessionStore.beginCurrent(
            mode: .m,
            scenarioProfileID: "coding",
            objective:
                "Current predecessor objective: analysis only, no install.",
            owner: .session(owner),
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        if activatePredecessor {
            _ = try goalStore.updateStatus(
                contractID: attachment.contract.contractID,
                status: .running,
                authority: .revisionPromotion,
                reason: "test_running")
        }
        let artifact = TatwoGoalRevisionIssuerArtifactEvidence(
            identity: TatwoHumanGateIssuerArtifactIdentityV1(
                bundleIdentifier: "com.tatwo.ultrawork",
                teamIdentifier: "TESTTEAM",
                codeDirectoryHash: "fixture-cdhash",
                executableSHA256: String(repeating: "a", count: 64)),
            executableURL: root.appendingPathComponent("TatwoUltraworkMac"))
        try body(
            Fixture(
                root: root,
                goalStore: goalStore,
                sessionStore: sessionStore,
                dispatchRegistry: dispatchRegistry,
                old: attachment.contract,
                artifact: artifact,
                now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    private func prepareChallenge(
        _ fixture: Fixture,
        scenarioProfileID: String =
            TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
        artifact: TatwoGoalRevisionIssuerArtifactEvidence? = nil
    ) throws -> TatwoGoalRevisionChallenge {
        try TatwoGoalRevisionCoordinator.prepare(
            selection: TatwoGoalRevisionSelection(
                mode: .xxl,
                scenarioProfileID: scenarioProfileID,
                scenarioBook: TatwoScenarioConfigDefaults.book,
                loopPresetID: "recommended",
                enabledLoopTemplateIDs: nil),
            goalStore: fixture.goalStore,
            sessionStore: fixture.sessionStore,
            challengeID: "deterministic-challenge",
            now: fixture.now,
            artifactProvider: { artifact ?? fixture.artifact })
    }

    private struct StagingRevisionIssuerFixture {
        let bundleURL: URL
        let artifact: TatwoGoalRevisionIssuerArtifactEvidence
    }

    private func makeStagingRevisionIssuerArtifact(
        root: URL? = nil,
        includeRevisionMarker: Bool = true,
        executableSHA256Override: String? = nil
    ) throws -> StagingRevisionIssuerFixture {
        let resolvedRoot = root ?? URL(
            fileURLWithPath:
                "/private/tmp/tatwo-os-staging-20260819T120000Z."
                + UUID().uuidString.prefix(6),
            isDirectory: true)
        let bundleURL = resolvedRoot.appendingPathComponent(
            "Tatwo Ultrawork Staging.app",
            isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent(
            "MacOS",
            isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent(
            "TatwoUltraworkMacStaging")
        try FileManager.default.createDirectory(
            at: macOSURL,
            withIntermediateDirectories: true)
        let executableData = Data("staging-revision-executable".utf8)
        try executableData.write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path)
        let token = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(8)
        let bundleIdentifier =
            "com.tatwo.ultrawork.staging.s20260819T120000Z.\(token)"
        var info: [String: Any] = [
            "CFBundleExecutable": executableURL.lastPathComponent,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "TatwoStagingAnchorIdentity":
                "ai.tatwo.ultrawork.plg-chain-anchor.staging.test"
                + "|staging.test",
            "TatwoStagingDeclaredBundlePath": bundleURL.path
        ]
        if includeRevisionMarker {
            info["TatwoStagingRevisionIssuerScope"] =
                "revision_activation_only"
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0)
        try plist.write(
            to: contentsURL.appendingPathComponent("Info.plist"))
        let executableSHA256 =
            executableSHA256Override
            ?? SHA256.hash(data: executableData)
                .map { String(format: "%02x", $0) }
                .joined()
        let artifact = TatwoGoalRevisionIssuerArtifactEvidence(
            identity: TatwoHumanGateIssuerArtifactIdentityV1(
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: nil,
                codeDirectoryHash: "fixture-staging-cdhash",
                executableSHA256: executableSHA256),
            executableURL: executableURL)
        return StagingRevisionIssuerFixture(
            bundleURL: bundleURL,
            artifact: artifact)
    }

    private func assertOperationFailure(
        _ error: Error,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .operationFailed(let message) =
            error as? TatwoGoalRevisionConfirmationError
        else {
            return XCTFail(
                "expected operationFailed, got \(error)",
                file: file,
                line: line)
        }
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains(expected),
            "expected '\(message)' to contain '\(expected)'",
            file: file,
            line: line)
    }

    private func legacyFourBindingFableGrokBook()
        -> TatwoScenarioConfigBookV1
    {
        var book = TatwoScenarioConfigDefaults.book
        let scenarioID =
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID
        guard let scenarioIndex = book.scenarios.firstIndex(
            where: { $0.id == scenarioID }),
            var modeConfig = book.scenarios[scenarioIndex].modeConfigs[.xxl]
        else {
            return book
        }
        modeConfig.bindings.removeAll {
            $0.id
                == "general-xxl-native-development-loops-supervisor-fable5"
                || $0.id
                    == "general-xxl-native-development-loops-verifier-fable5"
        }
        book.scenarios[scenarioIndex].modeConfigs[.xxl] = modeConfig
        return book
    }

}

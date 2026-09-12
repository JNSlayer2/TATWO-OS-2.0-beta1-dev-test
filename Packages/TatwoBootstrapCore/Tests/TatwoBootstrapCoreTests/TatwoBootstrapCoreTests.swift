import Foundation
import XCTest
import TatwoModuleContracts
import TatwoDeploymentPrimitives
@testable import TatwoBootstrapCore

final class TatwoBootstrapCoreTests: XCTestCase {
    func testPlanOrdersDependenciesBeforeDependentsAndHasNoAuthorityEffects() throws {
        let activation = RecordingActivationPort()
        let reset = RecordingResetPort()
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: reset)
        let runtime = try makeManifest(id: "runtime")
        let app = try makeManifest(id: "app", dependencies: ["runtime"])

        let receipt = core.plan(
            TatwoBootstrapPlanRequestV1(
                manifests: [app, runtime],
                requestedModuleIDs: [app.moduleID],
                correlationID: "bootstrap-1"
            )
        )

        XCTAssertEqual(receipt.operation, .plan)
        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertEqual(receipt.orderedModuleIDs.map(\.rawValue), ["runtime", "app"])
        XCTAssertEqual(receipt.safetyEvidence.domainAuthorityAcquisitionCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.domainAuthorityTransferCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.userDataDeleteCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.domainLedgerDeleteCount, 0)
        XCTAssertEqual(
            receipt.steps.first?.resetArtifacts,
            [.cache, .stagedBundle, .generatedState]
        )
        XCTAssertTrue(activation.invocations.isEmpty)
        XCTAssertTrue(reset.requests.isEmpty)
    }

    func testPlanFailsClosedForMissingDependencyAndCycle() throws {
        let core = TatwoBootstrapCore(
            activationPort: RecordingActivationPort(),
            resetPort: RecordingResetPort()
        )
        let missing = try makeManifest(id: "app", dependencies: ["runtime"])
        let missingReceipt = core.plan(
            TatwoBootstrapPlanRequestV1(
                manifests: [missing],
                requestedModuleIDs: [missing.moduleID],
                correlationID: "bootstrap-1"
            )
        )
        XCTAssertEqual(missingReceipt.outcome, .failed)
        XCTAssertEqual(missingReceipt.failureCode, .missingDependency)

        let first = try makeManifest(id: "first", dependencies: ["second"])
        let second = try makeManifest(id: "second", dependencies: ["first"])
        let cycleReceipt = core.plan(
            TatwoBootstrapPlanRequestV1(
                manifests: [first, second],
                requestedModuleIDs: [first.moduleID],
                correlationID: "bootstrap-2"
            )
        )
        XCTAssertEqual(cycleReceipt.outcome, .failed)
        XCTAssertEqual(cycleReceipt.failureCode, .dependencyCycle)
    }

    func testPlanFailsClosedWhenDependencyVersionIsBelowManifestMinimum() throws {
        let core = TatwoBootstrapCore(
            activationPort: RecordingActivationPort(),
            resetPort: RecordingResetPort()
        )
        let runtime = try makeManifest(
            id: "runtime",
            version: TatwoModuleVersionV1(major: 1, minor: 0, patch: 0)
        )
        let app = try makeManifest(
            id: "app",
            dependencyRequirements: [
                ("runtime", TatwoModuleVersionV1(major: 2, minor: 0, patch: 0))
            ]
        )

        let receipt = core.plan(
            TatwoBootstrapPlanRequestV1(
                manifests: [app, runtime],
                requestedModuleIDs: [app.moduleID],
                correlationID: "bootstrap-version"
            )
        )

        XCTAssertEqual(receipt.outcome, .failed)
        XCTAssertEqual(receipt.failureCode, .incompatibleDependencyVersion)
    }

    func testApplyStagesVerifiesArchivesSwapsAndChecksHealthInOrder() throws {
        let activation = RecordingActivationPort()
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: RecordingResetPort())
        let manifest = try makeManifest(id: "app")
        let plan = try TatwoBootstrapPlanV1(
            manifests: [manifest],
            orderedModuleIDs: [manifest.moduleID]
        )

        let receipt = core.apply(
            TatwoBootstrapApplyRequestV1(
                plan: plan,
                candidates: [try makeCandidate(manifest: manifest)],
                correlationID: "bootstrap-apply"
            )
        )

        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .healthCheck]
        )
        XCTAssertFalse(activation.invocations.contains { $0.operation == .rollbackBundle })
        XCTAssertEqual(receipt.safetyEvidence.domainAuthorityAcquisitionCount, 0)
    }

    func testVerificationFailureStopsBeforeArchiveOrSwap() throws {
        let activation = RecordingActivationPort()
        activation.failedOperation = .verify
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: RecordingResetPort())
        let manifest = try makeManifest(id: "app")
        let plan = try TatwoBootstrapPlanV1(manifests: [manifest], orderedModuleIDs: [manifest.moduleID])

        let receipt = core.apply(
            TatwoBootstrapApplyRequestV1(
                plan: plan,
                candidates: [try makeCandidate(manifest: manifest)],
                correlationID: "bootstrap-apply"
            )
        )

        XCTAssertEqual(receipt.outcome, .failed)
        XCTAssertEqual(receipt.failureCode, .verificationFailed)
        XCTAssertEqual(activation.invocations.map(\.operation), [.stage, .verify])
    }

    func testThrownVerificationErrorIsClassifiedAsVerificationFailure() throws {
        let activation = RecordingActivationPort()
        activation.thrownOperation = .verify
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: RecordingResetPort())
        let manifest = try makeManifest(id: "app")
        let plan = try TatwoBootstrapPlanV1(manifests: [manifest], orderedModuleIDs: [manifest.moduleID])

        let receipt = core.apply(
            TatwoBootstrapApplyRequestV1(
                plan: plan,
                candidates: [try makeCandidate(manifest: manifest)],
                correlationID: "bootstrap-apply"
            )
        )

        XCTAssertEqual(receipt.outcome, .failed)
        XCTAssertEqual(receipt.failureCode, .verificationFailed)
        XCTAssertEqual(activation.invocations.map(\.operation), [.stage, .verify])
    }

    func testFailedPostSwapHealthRollsBackBundleOnly() throws {
        let activation = RecordingActivationPort()
        activation.failedOperation = .healthCheck
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: RecordingResetPort())
        let manifest = try makeManifest(id: "app")
        let plan = try TatwoBootstrapPlanV1(manifests: [manifest], orderedModuleIDs: [manifest.moduleID])

        let receipt = core.apply(
            TatwoBootstrapApplyRequestV1(
                plan: plan,
                candidates: [try makeCandidate(manifest: manifest)],
                correlationID: "bootstrap-apply"
            )
        )

        XCTAssertEqual(receipt.outcome, .failed)
        XCTAssertEqual(receipt.failureCode, .healthCheckFailed)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .healthCheck, .rollbackBundle]
        )
        XCTAssertEqual(receipt.safetyEvidence.userDataDeleteCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.domainLedgerDeleteCount, 0)
        XCTAssertTrue(receipt.steps.last?.bundleIsolationEvidence?.isBundleOnly == true)
    }

    func testResetModuleCanRequestOnlyManifestResettableArtifacts() throws {
        let reset = RecordingResetPort()
        let core = TatwoBootstrapCore(
            activationPort: RecordingActivationPort(),
            resetPort: reset
        )
        let manifest = try makeManifest(id: "app")

        let receipt = core.resetModule(
            TatwoBootstrapResetModuleRequestV1(
                manifest: manifest,
                correlationID: "bootstrap-reset"
            )
        )

        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertEqual(reset.requests.count, 1)
        XCTAssertEqual(reset.requests[0].artifacts, [.cache, .stagedBundle, .generatedState])
        XCTAssertEqual(reset.requests[0].installLocation, manifest.locations.install)
        XCTAssertEqual(reset.requests[0].dataLocation, manifest.locations.data)
        XCTAssertEqual(reset.requests[0].cacheLocation, manifest.locations.cache)
        XCTAssertTrue(reset.requests[0].preservesUserData)
        XCTAssertTrue(reset.requests[0].preservesDomainLedger)
        let resetFieldNames = Set(Mirror(reflecting: reset.requests[0]).children.compactMap(\.label))
        XCTAssertTrue(resetFieldNames.contains("dataLocation"))
        XCTAssertFalse(resetFieldNames.contains("domainLedgerLocation"))
        XCTAssertEqual(receipt.safetyEvidence.userDataDeleteCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.domainLedgerDeleteCount, 0)
    }

    func testDoctorReadsSnapshotsWithoutInvokingDeploymentOrReset() throws {
        let activation = RecordingActivationPort()
        let reset = RecordingResetPort()
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: reset)
        let manifest = try makeManifest(id: "app")
        let snapshot = TatwoModuleHealthSnapshotV1(
            moduleID: manifest.moduleID,
            version: manifest.version,
            status: .healthy,
            observedAt: Date(timeIntervalSince1970: 1),
            detail: "healthy"
        )

        let receipt = core.doctor(
            TatwoBootstrapDoctorRequestV1(
                manifests: [manifest],
                snapshots: [snapshot],
                correlationID: "bootstrap-doctor"
            )
        )

        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertTrue(activation.invocations.isEmpty)
        XCTAssertTrue(reset.requests.isEmpty)
        XCTAssertEqual(receipt.safetyEvidence.domainAuthorityAcquisitionCount, 0)
    }

    func testRepairUsesSameSafeActivationChainForSelectedModules() throws {
        let activation = RecordingActivationPort()
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: RecordingResetPort())
        let manifest = try makeManifest(id: "app")
        let plan = try TatwoBootstrapPlanV1(manifests: [manifest], orderedModuleIDs: [manifest.moduleID])

        let receipt = core.repair(
            TatwoBootstrapRepairRequestV1(
                plan: plan,
                candidates: [try makeCandidate(manifest: manifest)],
                moduleIDs: [manifest.moduleID],
                correlationID: "bootstrap-repair"
            )
        )

        XCTAssertEqual(receipt.operation, .repair)
        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .healthCheck]
        )
    }

    func testThrownHealthCheckStillRollsBackAndPreservesOriginalFailure() throws {
        let activation = RecordingActivationPort()
        activation.thrownOperation = .healthCheck
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: RecordingResetPort())
        let manifest = try makeManifest(id: "app")
        let plan = try TatwoBootstrapPlanV1(
            manifests: [manifest],
            orderedModuleIDs: [manifest.moduleID]
        )

        let receipt = core.apply(
            .init(
                plan: plan,
                candidates: [try makeCandidate(manifest: manifest)],
                correlationID: "health-throw"
            )
        )

        XCTAssertEqual(receipt.outcome, .failed)
        XCTAssertEqual(receipt.failureCode, .healthCheckFailed)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .healthCheck, .rollbackBundle]
        )
    }

    func testUncertainAtomicSwapThrowAttemptsRollbackAndReportsRollbackFailure() throws {
        let activation = RecordingActivationPort()
        activation.thrownOperation = .atomicSwap
        activation.failedOperation = .rollbackBundle
        let core = TatwoBootstrapCore(activationPort: activation, resetPort: RecordingResetPort())
        let manifest = try makeManifest(id: "app")
        let plan = try TatwoBootstrapPlanV1(
            manifests: [manifest],
            orderedModuleIDs: [manifest.moduleID]
        )

        let receipt = core.apply(
            .init(
                plan: plan,
                candidates: [try makeCandidate(manifest: manifest)],
                correlationID: "swap-throw"
            )
        )

        XCTAssertEqual(receipt.outcome, .failed)
        XCTAssertEqual(receipt.failureCode, .rollbackFailed)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .rollbackBundle]
        )
    }

    func testDeploymentSafetyEvidenceRejectsDecodedAuthorityOrDataEffects() {
        let unsafeJSON = """
        {
          "domainAuthorityAcquisitionCount": 1,
          "domainAuthorityTransferCount": 0,
          "userDataDeleteCount": 0,
          "domainLedgerDeleteCount": 0
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(TatwoDeploymentSafetyEvidenceV1.self, from: unsafeJSON)
        )
    }

    func testResetReceiptRejectsDecodedUserDataOrDomainLedgerDeletion() {
        let unsafeJSON = """
        {
          "moduleID": {"rawValue": "app"},
          "resetArtifacts": ["cache"],
          "userDataDeleteCount": 0,
          "domainLedgerDeleteCount": 1,
          "detail": "unsafe"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(TatwoModuleResetEffectReceiptV1.self, from: unsafeJSON)
        )
    }

    private func makeManifest(
        id: String,
        dependencies: [String] = [],
        version: TatwoModuleVersionV1 = TatwoModuleVersionV1(major: 1, minor: 0, patch: 0),
        dependencyRequirements: [(String, TatwoModuleVersionV1)] = []
    ) throws -> TatwoModuleManifestV1 {
        try TatwoModuleManifestV1(
            moduleID: TatwoModuleIDV1(id),
            version: version,
            dependencies: dependencies.map {
                TatwoModuleDependencyV1(moduleID: try! TatwoModuleIDV1($0))
            } + dependencyRequirements.map {
                TatwoModuleDependencyV1(
                    moduleID: try! TatwoModuleIDV1($0.0),
                    minimumVersion: $0.1
                )
            },
            locations: TatwoModuleLocationsV1(
                install: TatwoModuleLocationDescriptorV1(kind: .install, path: "/Applications/\(id).app"),
                data: TatwoModuleLocationDescriptorV1(kind: .userData, path: "/data/\(id)"),
                cache: TatwoModuleLocationDescriptorV1(kind: .cache, path: "/cache/\(id)")
            ),
            health: TatwoModuleHealthPolicyV1(kind: .executableProbe, timeoutSeconds: 5),
            migration: TatwoModuleMigrationPolicyV1(mode: .none, currentSchemaVersion: 1),
            rollback: TatwoModuleRollbackPolicyV1(scope: .bundleOnly, retainedVerifiedArchives: 1),
            reset: TatwoModuleResetPolicyV1(
                resettableArtifacts: [.cache, .stagedBundle, .generatedState]
            )
        )
    }

    private func makeCandidate(
        manifest: TatwoModuleManifestV1
    ) throws -> TatwoBootstrapBundleCandidateV1 {
        let boundary = TatwoBundleActivationBoundaryV1(
            moduleID: manifest.moduleID,
            installRoot: manifest.locations.install.path,
            stagingRoots: ["/staging", "/downloads"],
            archiveRoots: ["/archives"],
            protectedUserDataRoots: [manifest.locations.data.path],
            protectedDomainLedgerRoots: [manifest.locations.data.path + "/domain-ledger"]
        )
        return try TatwoBootstrapBundleCandidateV1(
            moduleID: manifest.moduleID,
            stage: TatwoBundleStageRequestV1(
                boundary: boundary,
                sourceBundle: TatwoBundlePathV1("/downloads/\(manifest.moduleID.rawValue).app", role: .sourceArtifact),
                stagedBundle: TatwoBundlePathV1("/staging/\(manifest.moduleID.rawValue).app", role: .stagedBundle),
                correlationID: "candidate"
            ),
            verify: TatwoBundleVerifyRequestV1(
                boundary: boundary,
                stagedBundle: TatwoBundlePathV1("/staging/\(manifest.moduleID.rawValue).app", role: .stagedBundle),
                expectedArtifactDigest: "abc",
                correlationID: "candidate"
            ),
            archiveCurrent: TatwoBundleArchiveCurrentRequestV1(
                boundary: boundary,
                currentBundle: TatwoBundlePathV1(manifest.locations.install.path, role: .activeBundle),
                archivedBundle: TatwoBundlePathV1("/archives/\(manifest.moduleID.rawValue).app", role: .archivedBundle),
                correlationID: "candidate"
            ),
            atomicSwap: TatwoBundleAtomicSwapRequestV1(
                boundary: boundary,
                stagedBundle: TatwoBundlePathV1("/staging/\(manifest.moduleID.rawValue).app", role: .stagedBundle),
                activeBundle: TatwoBundlePathV1(manifest.locations.install.path, role: .activeBundle),
                correlationID: "candidate"
            ),
            healthCheck: TatwoBundleHealthCheckRequestV1(
                boundary: boundary,
                activeBundle: TatwoBundlePathV1(manifest.locations.install.path, role: .activeBundle),
                policy: manifest.health,
                correlationID: "candidate"
            ),
            rollbackBundle: TatwoBundleRollbackRequestV1(
                boundary: boundary,
                archivedBundle: TatwoBundlePathV1("/archives/\(manifest.moduleID.rawValue).app", role: .rollbackBundle),
                activeBundle: TatwoBundlePathV1(manifest.locations.install.path, role: .activeBundle),
                correlationID: "candidate"
            )
        )
    }
}

private final class RecordingActivationPort: TatwoBootstrapDeploymentPort {
    private(set) var invocations: [TatwoBundleActivationInvocationV1] = []
    var failedOperation: TatwoBundleOperationKindV1?
    var thrownOperation: TatwoBundleOperationKindV1?

    func stage(_ request: TatwoBundleStageRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.stage(request), moduleID: request.boundary.moduleID, correlationID: request.correlationID)
    }

    func verify(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.verify(request), moduleID: request.boundary.moduleID, correlationID: request.correlationID)
    }

    func archiveCurrent(_ request: TatwoBundleArchiveCurrentRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.archiveCurrent(request), moduleID: request.boundary.moduleID, correlationID: request.correlationID)
    }

    func atomicSwap(_ request: TatwoBundleAtomicSwapRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.atomicSwap(request), moduleID: request.boundary.moduleID, correlationID: request.correlationID)
    }

    func healthCheck(_ request: TatwoBundleHealthCheckRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.healthCheck(request), moduleID: request.boundary.moduleID, correlationID: request.correlationID)
    }

    func rollbackBundle(_ request: TatwoBundleRollbackRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.rollbackBundle(request), moduleID: request.boundary.moduleID, correlationID: request.correlationID)
    }

    private func record(
        _ invocation: TatwoBundleActivationInvocationV1,
        moduleID: TatwoModuleIDV1,
        correlationID: String
    ) throws -> TatwoBundleOperationReceiptV1 {
        invocations.append(invocation)
        if thrownOperation == invocation.operation {
            throw RecordingActivationError.forced(invocation.operation)
        }
        let outcome: TatwoBundleOperationOutcomeV1 =
            failedOperation == invocation.operation ? .failed : .succeeded
        return TatwoBundleOperationReceiptV1(
            receiptID: "activation-\(invocations.count)",
            operation: invocation.operation,
            moduleID: moduleID,
            correlationID: correlationID,
            createdAt: Date(timeIntervalSince1970: Double(invocations.count)),
            outcome: outcome,
            isolationEvidence: TatwoBundleOnlyMutationEvidenceV1(bundlePaths: invocation.bundlePaths),
            detail: outcome == .failed ? "forced failure" : "ok"
        )
    }
}

private enum RecordingActivationError: Error {
    case forced(TatwoBundleOperationKindV1)
}

private final class RecordingResetPort: TatwoModuleResetPort {
    private(set) var requests: [TatwoModuleResetEffectRequestV1] = []

    func reset(_ request: TatwoModuleResetEffectRequestV1) throws -> TatwoModuleResetEffectReceiptV1 {
        requests.append(request)
        return TatwoModuleResetEffectReceiptV1(
            moduleID: request.moduleID,
            resetArtifacts: request.artifacts,
            detail: "reset"
        )
    }
}

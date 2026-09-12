import Foundation
import TatwoModuleContracts
import TatwoDeploymentPrimitives

public enum TatwoBootstrapCommandOperationV1: String, Codable, Hashable, Sendable {
    case plan
    case apply
    case repair
    case resetModule
    case doctor
}

public enum TatwoDeploymentReceiptOutcomeV1: String, Codable, Hashable, Sendable {
    case succeeded
    case failed
}

public enum TatwoDeploymentFailureCodeV1: String, Codable, Hashable, Sendable {
    case missingDependency
    case incompatibleDependencyVersion
    case dependencyCycle
    case invalidPlan
    case missingCandidate
    case stageFailed
    case verificationFailed
    case archiveFailed
    case atomicSwapFailed
    case healthCheckFailed
    case rollbackFailed
    case resetFailed
    case unhealthyModule
}

public struct TatwoDeploymentSafetyEvidenceV1: Codable, Hashable, Sendable {
    public let domainAuthorityAcquisitionCount: Int
    public let domainAuthorityTransferCount: Int
    public let userDataDeleteCount: Int
    public let domainLedgerDeleteCount: Int

    public init() {
        self.domainAuthorityAcquisitionCount = 0
        self.domainAuthorityTransferCount = 0
        self.userDataDeleteCount = 0
        self.domainLedgerDeleteCount = 0
    }

    private enum CodingKeys: String, CodingKey {
        case domainAuthorityAcquisitionCount
        case domainAuthorityTransferCount
        case userDataDeleteCount
        case domainLedgerDeleteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let counts = [
            try container.decode(Int.self, forKey: .domainAuthorityAcquisitionCount),
            try container.decode(Int.self, forKey: .domainAuthorityTransferCount),
            try container.decode(Int.self, forKey: .userDataDeleteCount),
            try container.decode(Int.self, forKey: .domainLedgerDeleteCount)
        ]
        guard counts.allSatisfy({ $0 == 0 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .domainAuthorityAcquisitionCount,
                in: container,
                debugDescription: "Bootstrap safety evidence cannot contain authority or user-domain effects"
            )
        }
        self.init()
    }
}

public struct TatwoDeploymentStepReceiptV1: Codable, Hashable, Sendable {
    public let moduleID: TatwoModuleIDV1
    public let step: String
    public let outcome: TatwoDeploymentReceiptOutcomeV1
    public let detail: String
    public let bundleIsolationEvidence: TatwoBundleOnlyMutationEvidenceV1?
    public let resetArtifacts: [TatwoResettableArtifactV1]?

    public init(
        moduleID: TatwoModuleIDV1,
        step: String,
        outcome: TatwoDeploymentReceiptOutcomeV1,
        detail: String,
        bundleIsolationEvidence: TatwoBundleOnlyMutationEvidenceV1? = nil,
        resetArtifacts: [TatwoResettableArtifactV1]? = nil
    ) {
        self.moduleID = moduleID
        self.step = step
        self.outcome = outcome
        self.detail = detail
        self.bundleIsolationEvidence = bundleIsolationEvidence
        self.resetArtifacts = resetArtifacts
    }
}

public struct TatwoDeploymentReceiptV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let operation: TatwoBootstrapCommandOperationV1
    public let correlationID: String
    public let createdAt: Date
    public let outcome: TatwoDeploymentReceiptOutcomeV1
    public let failureCode: TatwoDeploymentFailureCodeV1?
    public let orderedModuleIDs: [TatwoModuleIDV1]
    public let steps: [TatwoDeploymentStepReceiptV1]
    public let safetyEvidence: TatwoDeploymentSafetyEvidenceV1
    public let detail: String

    public init(
        receiptID: String,
        operation: TatwoBootstrapCommandOperationV1,
        correlationID: String,
        createdAt: Date,
        outcome: TatwoDeploymentReceiptOutcomeV1,
        failureCode: TatwoDeploymentFailureCodeV1?,
        orderedModuleIDs: [TatwoModuleIDV1],
        steps: [TatwoDeploymentStepReceiptV1],
        detail: String
    ) {
        self.schemaVersion = 1
        self.receiptID = receiptID
        self.operation = operation
        self.correlationID = correlationID
        self.createdAt = createdAt
        self.outcome = outcome
        self.failureCode = failureCode
        self.orderedModuleIDs = orderedModuleIDs
        self.steps = steps
        self.safetyEvidence = TatwoDeploymentSafetyEvidenceV1()
        self.detail = detail
    }
}

public typealias TatwoDeploymentReceipt = TatwoDeploymentReceiptV1

public struct TatwoBootstrapPlanRequestV1: Codable, Hashable, Sendable {
    public let manifests: [TatwoModuleManifestV1]
    public let requestedModuleIDs: [TatwoModuleIDV1]
    public let correlationID: String

    public init(
        manifests: [TatwoModuleManifestV1],
        requestedModuleIDs: [TatwoModuleIDV1],
        correlationID: String
    ) {
        self.manifests = manifests
        self.requestedModuleIDs = requestedModuleIDs
        self.correlationID = correlationID
    }
}

public enum TatwoBootstrapPlanValidationError: Error, Equatable, Sendable {
    case duplicateManifest(TatwoModuleIDV1)
    case unknownOrderedModule(TatwoModuleIDV1)
    case duplicateOrderedModule(TatwoModuleIDV1)
    case dependencyOrderViolation(module: TatwoModuleIDV1, dependency: TatwoModuleIDV1)
}

public struct TatwoBootstrapPlanV1: Codable, Hashable, Sendable {
    public let manifests: [TatwoModuleManifestV1]
    public let orderedModuleIDs: [TatwoModuleIDV1]

    public init(
        manifests: [TatwoModuleManifestV1],
        orderedModuleIDs: [TatwoModuleIDV1]
    ) throws {
        let grouped = Dictionary(grouping: manifests, by: \.moduleID)
        if let duplicate = grouped.first(where: { $0.value.count > 1 })?.key {
            throw TatwoBootstrapPlanValidationError.duplicateManifest(duplicate)
        }
        let manifestByID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.moduleID, $0) })
        var seen = Set<TatwoModuleIDV1>()
        for moduleID in orderedModuleIDs {
            guard let manifest = manifestByID[moduleID] else {
                throw TatwoBootstrapPlanValidationError.unknownOrderedModule(moduleID)
            }
            guard seen.insert(moduleID).inserted else {
                throw TatwoBootstrapPlanValidationError.duplicateOrderedModule(moduleID)
            }
            for dependency in manifest.dependencies where !seen.contains(dependency.moduleID) {
                throw TatwoBootstrapPlanValidationError.dependencyOrderViolation(
                    module: moduleID,
                    dependency: dependency.moduleID
                )
            }
        }
        self.manifests = manifests
        self.orderedModuleIDs = orderedModuleIDs
    }
}

public enum TatwoBootstrapBundleCandidateValidationError: Error, Equatable, Sendable {
    case moduleMismatch(expected: TatwoModuleIDV1, actual: TatwoModuleIDV1)
}

public struct TatwoBootstrapBundleCandidateV1: Codable, Hashable, Sendable {
    public let moduleID: TatwoModuleIDV1
    public let stage: TatwoBundleStageRequestV1
    public let verify: TatwoBundleVerifyRequestV1
    public let archiveCurrent: TatwoBundleArchiveCurrentRequestV1
    public let atomicSwap: TatwoBundleAtomicSwapRequestV1
    public let healthCheck: TatwoBundleHealthCheckRequestV1
    public let rollbackBundle: TatwoBundleRollbackRequestV1

    public init(
        moduleID: TatwoModuleIDV1,
        stage: TatwoBundleStageRequestV1,
        verify: TatwoBundleVerifyRequestV1,
        archiveCurrent: TatwoBundleArchiveCurrentRequestV1,
        atomicSwap: TatwoBundleAtomicSwapRequestV1,
        healthCheck: TatwoBundleHealthCheckRequestV1,
        rollbackBundle: TatwoBundleRollbackRequestV1
    ) throws {
        let boundaryIDs = [
            stage.boundary.moduleID,
            verify.boundary.moduleID,
            archiveCurrent.boundary.moduleID,
            atomicSwap.boundary.moduleID,
            healthCheck.boundary.moduleID,
            rollbackBundle.boundary.moduleID
        ]
        if let mismatch = boundaryIDs.first(where: { $0 != moduleID }) {
            throw TatwoBootstrapBundleCandidateValidationError.moduleMismatch(
                expected: moduleID,
                actual: mismatch
            )
        }
        self.moduleID = moduleID
        self.stage = stage
        self.verify = verify
        self.archiveCurrent = archiveCurrent
        self.atomicSwap = atomicSwap
        self.healthCheck = healthCheck
        self.rollbackBundle = rollbackBundle
    }
}

public struct TatwoBootstrapApplyRequestV1: Codable, Hashable, Sendable {
    public let plan: TatwoBootstrapPlanV1
    public let candidates: [TatwoBootstrapBundleCandidateV1]
    public let correlationID: String

    public init(
        plan: TatwoBootstrapPlanV1,
        candidates: [TatwoBootstrapBundleCandidateV1],
        correlationID: String
    ) {
        self.plan = plan
        self.candidates = candidates
        self.correlationID = correlationID
    }
}

public struct TatwoBootstrapRepairRequestV1: Codable, Hashable, Sendable {
    public let plan: TatwoBootstrapPlanV1
    public let candidates: [TatwoBootstrapBundleCandidateV1]
    public let moduleIDs: [TatwoModuleIDV1]
    public let correlationID: String

    public init(
        plan: TatwoBootstrapPlanV1,
        candidates: [TatwoBootstrapBundleCandidateV1],
        moduleIDs: [TatwoModuleIDV1],
        correlationID: String
    ) {
        self.plan = plan
        self.candidates = candidates
        self.moduleIDs = moduleIDs
        self.correlationID = correlationID
    }
}

public struct TatwoBootstrapResetModuleRequestV1: Codable, Hashable, Sendable {
    public let manifest: TatwoModuleManifestV1
    public let correlationID: String

    public init(manifest: TatwoModuleManifestV1, correlationID: String) {
        self.manifest = manifest
        self.correlationID = correlationID
    }
}

public struct TatwoBootstrapDoctorRequestV1: Codable, Hashable, Sendable {
    public let manifests: [TatwoModuleManifestV1]
    public let snapshots: [TatwoModuleHealthSnapshotV1]
    public let correlationID: String

    public init(
        manifests: [TatwoModuleManifestV1],
        snapshots: [TatwoModuleHealthSnapshotV1],
        correlationID: String
    ) {
        self.manifests = manifests
        self.snapshots = snapshots
        self.correlationID = correlationID
    }
}

public struct TatwoModuleResetEffectRequestV1: Codable, Hashable, Sendable {
    public let moduleID: TatwoModuleIDV1
    public let artifacts: [TatwoResettableArtifactV1]
    public let installLocation: TatwoModuleLocationDescriptorV1
    public let dataLocation: TatwoModuleLocationDescriptorV1
    public let cacheLocation: TatwoModuleLocationDescriptorV1

    public init(manifest: TatwoModuleManifestV1) {
        self.moduleID = manifest.moduleID
        self.artifacts = manifest.reset.resettableArtifacts
        self.installLocation = manifest.locations.install
        self.dataLocation = manifest.locations.data
        self.cacheLocation = manifest.locations.cache
    }

    public var preservesUserData: Bool {
        true
    }

    public var preservesDomainLedger: Bool {
        true
    }
}

public struct TatwoModuleResetEffectReceiptV1: Codable, Hashable, Sendable {
    public let moduleID: TatwoModuleIDV1
    public let resetArtifacts: [TatwoResettableArtifactV1]
    public let userDataDeleteCount: Int
    public let domainLedgerDeleteCount: Int
    public let detail: String

    public init(
        moduleID: TatwoModuleIDV1,
        resetArtifacts: [TatwoResettableArtifactV1],
        detail: String
    ) {
        self.moduleID = moduleID
        self.resetArtifacts = resetArtifacts
        self.userDataDeleteCount = 0
        self.domainLedgerDeleteCount = 0
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case moduleID
        case resetArtifacts
        case userDataDeleteCount
        case domainLedgerDeleteCount
        case detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let userDataDeleteCount = try container.decode(Int.self, forKey: .userDataDeleteCount)
        let domainLedgerDeleteCount = try container.decode(Int.self, forKey: .domainLedgerDeleteCount)
        guard userDataDeleteCount == 0, domainLedgerDeleteCount == 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: userDataDeleteCount == 0 ? .domainLedgerDeleteCount : .userDataDeleteCount,
                in: container,
                debugDescription: "Module reset receipts cannot contain user data or domain ledger deletions"
            )
        }
        self.init(
            moduleID: try container.decode(TatwoModuleIDV1.self, forKey: .moduleID),
            resetArtifacts: try container.decode([TatwoResettableArtifactV1].self, forKey: .resetArtifacts),
            detail: try container.decode(String.self, forKey: .detail)
        )
    }
}

public protocol TatwoModuleResetPort {
    func reset(_ request: TatwoModuleResetEffectRequestV1) throws -> TatwoModuleResetEffectReceiptV1
}

public protocol TatwoBootstrapCommandPort {
    func plan(_ request: TatwoBootstrapPlanRequestV1) -> TatwoDeploymentReceipt
    func apply(_ request: TatwoBootstrapApplyRequestV1) -> TatwoDeploymentReceipt
    func repair(_ request: TatwoBootstrapRepairRequestV1) -> TatwoDeploymentReceipt
    func resetModule(_ request: TatwoBootstrapResetModuleRequestV1) -> TatwoDeploymentReceipt
    func doctor(_ request: TatwoBootstrapDoctorRequestV1) -> TatwoDeploymentReceipt
}

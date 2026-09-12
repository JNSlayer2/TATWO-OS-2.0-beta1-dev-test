import Foundation
import TatwoModuleContracts

public enum TatwoBundlePathRoleV1: String, Codable, Hashable, Sendable {
    case sourceArtifact
    case stagedBundle
    case activeBundle
    case archivedBundle
    case rollbackBundle
}

public struct TatwoBundlePathV1: Codable, Hashable, Sendable {
    public let path: String
    public let role: TatwoBundlePathRoleV1

    public init(_ path: String, role: TatwoBundlePathRoleV1) {
        self.path = path
        self.role = role
    }
}

public enum TatwoProtectedPathKindV1: String, Codable, Hashable, Sendable {
    case userData
    case domainLedger
}

public struct TatwoBundleActivationBoundaryV1: Codable, Hashable, Sendable {
    public let moduleID: TatwoModuleIDV1
    public let installRoot: String
    public let stagingRoots: [String]
    public let archiveRoots: [String]
    public let protectedUserDataRoots: [String]
    public let protectedDomainLedgerRoots: [String]

    public init(
        moduleID: TatwoModuleIDV1,
        installRoot: String,
        stagingRoots: [String],
        archiveRoots: [String],
        protectedUserDataRoots: [String],
        protectedDomainLedgerRoots: [String]
    ) {
        self.moduleID = moduleID
        self.installRoot = installRoot
        self.stagingRoots = stagingRoots
        self.archiveRoots = archiveRoots
        self.protectedUserDataRoots = protectedUserDataRoots
        self.protectedDomainLedgerRoots = protectedDomainLedgerRoots
    }
}

public struct TatwoBundleStageRequestV1: Codable, Hashable, Sendable {
    public let boundary: TatwoBundleActivationBoundaryV1
    public let sourceBundle: TatwoBundlePathV1
    public let stagedBundle: TatwoBundlePathV1
    public let correlationID: String

    public init(
        boundary: TatwoBundleActivationBoundaryV1,
        sourceBundle: TatwoBundlePathV1,
        stagedBundle: TatwoBundlePathV1,
        correlationID: String
    ) {
        self.boundary = boundary
        self.sourceBundle = sourceBundle
        self.stagedBundle = stagedBundle
        self.correlationID = correlationID
    }
}

public struct TatwoBundleVerifyRequestV1: Codable, Hashable, Sendable {
    public let boundary: TatwoBundleActivationBoundaryV1
    public let stagedBundle: TatwoBundlePathV1
    public let expectedArtifactDigest: String
    public let correlationID: String

    public init(
        boundary: TatwoBundleActivationBoundaryV1,
        stagedBundle: TatwoBundlePathV1,
        expectedArtifactDigest: String,
        correlationID: String
    ) {
        self.boundary = boundary
        self.stagedBundle = stagedBundle
        self.expectedArtifactDigest = expectedArtifactDigest
        self.correlationID = correlationID
    }
}

public struct TatwoBundleArchiveCurrentRequestV1: Codable, Hashable, Sendable {
    public let boundary: TatwoBundleActivationBoundaryV1
    public let currentBundle: TatwoBundlePathV1
    public let archivedBundle: TatwoBundlePathV1
    public let correlationID: String

    public init(
        boundary: TatwoBundleActivationBoundaryV1,
        currentBundle: TatwoBundlePathV1,
        archivedBundle: TatwoBundlePathV1,
        correlationID: String
    ) {
        self.boundary = boundary
        self.currentBundle = currentBundle
        self.archivedBundle = archivedBundle
        self.correlationID = correlationID
    }
}

public struct TatwoBundleAtomicSwapRequestV1: Codable, Hashable, Sendable {
    public let boundary: TatwoBundleActivationBoundaryV1
    public let stagedBundle: TatwoBundlePathV1
    public let activeBundle: TatwoBundlePathV1
    public let correlationID: String

    public init(
        boundary: TatwoBundleActivationBoundaryV1,
        stagedBundle: TatwoBundlePathV1,
        activeBundle: TatwoBundlePathV1,
        correlationID: String
    ) {
        self.boundary = boundary
        self.stagedBundle = stagedBundle
        self.activeBundle = activeBundle
        self.correlationID = correlationID
    }
}

public struct TatwoBundleHealthCheckRequestV1: Codable, Hashable, Sendable {
    public let boundary: TatwoBundleActivationBoundaryV1
    public let activeBundle: TatwoBundlePathV1
    public let policy: TatwoModuleHealthPolicyV1
    public let correlationID: String

    public init(
        boundary: TatwoBundleActivationBoundaryV1,
        activeBundle: TatwoBundlePathV1,
        policy: TatwoModuleHealthPolicyV1,
        correlationID: String
    ) {
        self.boundary = boundary
        self.activeBundle = activeBundle
        self.policy = policy
        self.correlationID = correlationID
    }
}

public struct TatwoBundleRollbackRequestV1: Codable, Hashable, Sendable {
    public let boundary: TatwoBundleActivationBoundaryV1
    public let archivedBundle: TatwoBundlePathV1
    public let activeBundle: TatwoBundlePathV1
    public let correlationID: String

    public init(
        boundary: TatwoBundleActivationBoundaryV1,
        archivedBundle: TatwoBundlePathV1,
        activeBundle: TatwoBundlePathV1,
        correlationID: String
    ) {
        self.boundary = boundary
        self.archivedBundle = archivedBundle
        self.activeBundle = activeBundle
        self.correlationID = correlationID
    }
}

public enum TatwoBundleOperationKindV1: String, Codable, Hashable, Sendable {
    case stage
    case verify
    case archiveCurrent
    case atomicSwap
    case healthCheck
    case rollbackBundle
}

public enum TatwoBundleOperationOutcomeV1: String, Codable, Hashable, Sendable {
    case succeeded
    case failed
}

public enum TatwoDeploymentMutationScopeV1: String, Codable, Hashable, Sendable {
    case bundleOnly
}

public struct TatwoBundleOnlyMutationEvidenceV1: Codable, Hashable, Sendable {
    public let scope: TatwoDeploymentMutationScopeV1
    public let bundlePaths: [TatwoBundlePathV1]
    public let userDataWriteCount: Int
    public let domainLedgerWriteCount: Int

    public init(bundlePaths: [TatwoBundlePathV1]) {
        self.scope = .bundleOnly
        self.bundlePaths = bundlePaths
        self.userDataWriteCount = 0
        self.domainLedgerWriteCount = 0
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case bundlePaths
        case userDataWriteCount
        case domainLedgerWriteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try container.decode(TatwoDeploymentMutationScopeV1.self, forKey: .scope)
        let userDataWriteCount = try container.decode(Int.self, forKey: .userDataWriteCount)
        let domainLedgerWriteCount = try container.decode(Int.self, forKey: .domainLedgerWriteCount)
        guard scope == .bundleOnly, userDataWriteCount == 0, domainLedgerWriteCount == 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .scope,
                in: container,
                debugDescription: "Deployment evidence must be bundle-only with zero user data and domain writes"
            )
        }
        self.init(
            bundlePaths: try container.decode([TatwoBundlePathV1].self, forKey: .bundlePaths)
        )
    }

    public var isBundleOnly: Bool {
        scope == .bundleOnly && userDataWriteCount == 0 && domainLedgerWriteCount == 0
    }
}

public struct TatwoBundleOperationReceiptV1: Codable, Hashable, Sendable {
    public let receiptID: String
    public let operation: TatwoBundleOperationKindV1
    public let moduleID: TatwoModuleIDV1
    public let correlationID: String
    public let createdAt: Date
    public let outcome: TatwoBundleOperationOutcomeV1
    public let isolationEvidence: TatwoBundleOnlyMutationEvidenceV1
    public let detail: String

    public init(
        receiptID: String,
        operation: TatwoBundleOperationKindV1,
        moduleID: TatwoModuleIDV1,
        correlationID: String,
        createdAt: Date,
        outcome: TatwoBundleOperationOutcomeV1,
        isolationEvidence: TatwoBundleOnlyMutationEvidenceV1,
        detail: String
    ) {
        self.receiptID = receiptID
        self.operation = operation
        self.moduleID = moduleID
        self.correlationID = correlationID
        self.createdAt = createdAt
        self.outcome = outcome
        self.isolationEvidence = isolationEvidence
        self.detail = detail
    }

    public static func succeeded(
        operation: TatwoBundleOperationKindV1,
        moduleID: TatwoModuleIDV1,
        correlationID: String,
        receiptID: String,
        createdAt: Date,
        bundlePaths: [TatwoBundlePathV1],
        detail: String
    ) -> Self {
        Self(
            receiptID: receiptID,
            operation: operation,
            moduleID: moduleID,
            correlationID: correlationID,
            createdAt: createdAt,
            outcome: .succeeded,
            isolationEvidence: TatwoBundleOnlyMutationEvidenceV1(bundlePaths: bundlePaths),
            detail: detail
        )
    }

    public static func failed(
        operation: TatwoBundleOperationKindV1,
        moduleID: TatwoModuleIDV1,
        correlationID: String,
        receiptID: String,
        createdAt: Date,
        bundlePaths: [TatwoBundlePathV1],
        detail: String
    ) -> Self {
        Self(
            receiptID: receiptID,
            operation: operation,
            moduleID: moduleID,
            correlationID: correlationID,
            createdAt: createdAt,
            outcome: .failed,
            isolationEvidence: TatwoBundleOnlyMutationEvidenceV1(bundlePaths: bundlePaths),
            detail: detail
        )
    }
}

public struct TatwoBundleVerificationResultV1: Codable, Hashable, Sendable {
    public let isValid: Bool
    public let observedDigest: String
    public let detail: String

    public init(isValid: Bool, observedDigest: String, detail: String) {
        self.isValid = isValid
        self.observedDigest = observedDigest
        self.detail = detail
    }
}

public struct TatwoBundleHealthCheckResultV1: Codable, Hashable, Sendable {
    public let isHealthy: Bool
    public let detail: String

    public init(isHealthy: Bool, detail: String) {
        self.isHealthy = isHealthy
        self.detail = detail
    }
}

public enum TatwoBundleActivationInvocationV1: Codable, Hashable, Sendable {
    case stage(TatwoBundleStageRequestV1)
    case verify(TatwoBundleVerifyRequestV1)
    case archiveCurrent(TatwoBundleArchiveCurrentRequestV1)
    case atomicSwap(TatwoBundleAtomicSwapRequestV1)
    case healthCheck(TatwoBundleHealthCheckRequestV1)
    case rollbackBundle(TatwoBundleRollbackRequestV1)

    public var operation: TatwoBundleOperationKindV1 {
        switch self {
        case .stage: .stage
        case .verify: .verify
        case .archiveCurrent: .archiveCurrent
        case .atomicSwap: .atomicSwap
        case .healthCheck: .healthCheck
        case .rollbackBundle: .rollbackBundle
        }
    }

    public var bundlePaths: [TatwoBundlePathV1] {
        switch self {
        case let .stage(request):
            [request.sourceBundle, request.stagedBundle]
        case let .verify(request):
            [request.stagedBundle]
        case let .archiveCurrent(request):
            [request.currentBundle, request.archivedBundle]
        case let .atomicSwap(request):
            [request.stagedBundle, request.activeBundle]
        case let .healthCheck(request):
            [request.activeBundle]
        case let .rollbackBundle(request):
            [request.archivedBundle, request.activeBundle]
        }
    }
}

public protocol TatwoBundleActivationPort {
    func stage(_ request: TatwoBundleStageRequestV1) throws -> TatwoBundleOperationReceiptV1
    func verify(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleOperationReceiptV1
    func archiveCurrent(_ request: TatwoBundleArchiveCurrentRequestV1) throws -> TatwoBundleOperationReceiptV1
    func atomicSwap(_ request: TatwoBundleAtomicSwapRequestV1) throws -> TatwoBundleOperationReceiptV1
    func healthCheck(_ request: TatwoBundleHealthCheckRequestV1) throws -> TatwoBundleOperationReceiptV1
    func rollbackBundle(_ request: TatwoBundleRollbackRequestV1) throws -> TatwoBundleOperationReceiptV1
}

public protocol TatwoBootstrapDeploymentPort: TatwoBundleActivationPort {}

public protocol TatwoBundleFileSystemPort: AnyObject {
    func stageBundle(from source: TatwoBundlePathV1, to staged: TatwoBundlePathV1) throws
    func archiveBundle(from current: TatwoBundlePathV1, to archive: TatwoBundlePathV1) throws
    func atomicSwap(staged: TatwoBundlePathV1, active: TatwoBundlePathV1) throws
    func rollbackBundle(from archive: TatwoBundlePathV1, to active: TatwoBundlePathV1) throws
}

public protocol TatwoBundleVerifierPort: AnyObject {
    func verifyBundle(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleVerificationResultV1
}

public protocol TatwoBundleHealthCheckPort: AnyObject {
    func healthCheckBundle(_ request: TatwoBundleHealthCheckRequestV1) throws -> TatwoBundleHealthCheckResultV1
}

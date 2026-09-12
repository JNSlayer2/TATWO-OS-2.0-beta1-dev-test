import Foundation
import TatwoDeploymentPrimitives
import TatwoModuleContracts

public enum TatwoUpdateChannelV1: String, Codable, Hashable, Sendable {
    case internalCanary = "internal-canary"
    case stable
}

public struct TatwoUpdateArtifactMetadataV1: Codable, Hashable, Sendable {
    public let version: TatwoModuleVersionV1
    public let channel: TatwoUpdateChannelV1
    public let artifactURL: String
    public let artifactSHA256: String
    public let sparkleEdDSASignature: String
    public let developerIDTeamID: String
    public let notarizationTicketID: String
    public let sourceCommit: String
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let rollbackTargetVersion: TatwoModuleVersionV1
    public let publishedAt: Date

    public init(
        version: TatwoModuleVersionV1,
        channel: TatwoUpdateChannelV1,
        artifactURL: String,
        artifactSHA256: String,
        sparkleEdDSASignature: String,
        developerIDTeamID: String,
        notarizationTicketID: String,
        sourceCommit: String,
        schemaVersion: Int,
        protocolVersion: Int,
        rollbackTargetVersion: TatwoModuleVersionV1,
        publishedAt: Date
    ) {
        self.version = version
        self.channel = channel
        self.artifactURL = artifactURL
        self.artifactSHA256 = artifactSHA256
        self.sparkleEdDSASignature = sparkleEdDSASignature
        self.developerIDTeamID = developerIDTeamID
        self.notarizationTicketID = notarizationTicketID
        self.sourceCommit = sourceCommit
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.rollbackTargetVersion = rollbackTargetVersion
        self.publishedAt = publishedAt
    }
}

public struct TatwoSignedAppcastEntryV1: Codable, Hashable, Sendable {
    public let feedID: String
    public let feedChannel: TatwoUpdateChannelV1
    public let feedSignature: String
    public let artifact: TatwoUpdateArtifactMetadataV1

    public init(
        feedID: String,
        feedChannel: TatwoUpdateChannelV1,
        feedSignature: String,
        artifact: TatwoUpdateArtifactMetadataV1
    ) {
        self.feedID = feedID
        self.feedChannel = feedChannel
        self.feedSignature = feedSignature
        self.artifact = artifact
    }
}

public struct TatwoUpdateTrustVerificationV1: Codable, Hashable, Sendable {
    public let feedSignatureValid: Bool
    public let artifactHashValid: Bool
    public let artifactEdDSAValid: Bool
    public let developerIDValid: Bool
    public let notarizationValid: Bool
    public let sourceCommitValid: Bool
    public let schemaCompatible: Bool
    public let protocolCompatible: Bool
    public let detail: String

    public init(
        feedSignatureValid: Bool,
        artifactHashValid: Bool,
        artifactEdDSAValid: Bool,
        developerIDValid: Bool,
        notarizationValid: Bool,
        sourceCommitValid: Bool,
        schemaCompatible: Bool,
        protocolCompatible: Bool,
        detail: String
    ) {
        self.feedSignatureValid = feedSignatureValid
        self.artifactHashValid = artifactHashValid
        self.artifactEdDSAValid = artifactEdDSAValid
        self.developerIDValid = developerIDValid
        self.notarizationValid = notarizationValid
        self.sourceCommitValid = sourceCommitValid
        self.schemaCompatible = schemaCompatible
        self.protocolCompatible = protocolCompatible
        self.detail = detail
    }

    public var isTrusted: Bool {
        feedSignatureValid
            && artifactHashValid
            && artifactEdDSAValid
            && developerIDValid
            && notarizationValid
            && sourceCommitValid
            && schemaCompatible
            && protocolCompatible
    }
}

public enum TatwoUpdateOperationV1: String, Codable, Hashable, Sendable {
    case check
    case download
    case requestUserApprovedInstall
    case rollbackBundle
}

public enum TatwoUpdateStatusV1: String, Codable, Hashable, Sendable {
    case idle
    case noUpdate
    case available
    case downloaded
    case awaitingApproval
    case installed
    case rolledBack
    case failed
}

public enum TatwoUpdateErrorKindV1: String, Codable, Hashable, Sendable {
    case none
    case checkThrottled
    case feedUnavailable
    case channelMismatch
    case untrustedFeed
    case untrustedArtifact
    case schemaIncompatible
    case protocolIncompatible
    case noVerifiedCandidate
    case downloadFailed
    case artifactMismatch
    case userApprovalRequired
    case stageFailed
    case verificationFailed
    case archiveFailed
    case activationFailed
    case healthCheckFailed
    case rollbackFailed
}

public struct TatwoUpdateSafetyEvidenceV1: Codable, Hashable, Sendable {
    public let bundleMutationCount: Int
    public let userDataWriteCount: Int
    public let domainLedgerWriteCount: Int
    public let domainAuthorityMutationCount: Int
    public let syncCallCount: Int

    public init(bundleReceipts: [TatwoBundleOperationReceiptV1] = []) {
        bundleMutationCount = bundleReceipts.filter {
            [.stage, .archiveCurrent, .atomicSwap, .rollbackBundle].contains($0.operation)
        }.count
        userDataWriteCount = bundleReceipts.reduce(0) {
            $0 + $1.isolationEvidence.userDataWriteCount
        }
        domainLedgerWriteCount = bundleReceipts.reduce(0) {
            $0 + $1.isolationEvidence.domainLedgerWriteCount
        }
        domainAuthorityMutationCount = 0
        syncCallCount = 0
    }
}

public struct TatwoUpdateReceiptV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let operation: TatwoUpdateOperationV1
    public let correlationID: String
    public let status: TatwoUpdateStatusV1
    public let errorKind: TatwoUpdateErrorKindV1
    public let observedAt: Date
    public let channel: TatwoUpdateChannelV1
    public let artifact: TatwoUpdateArtifactMetadataV1?
    public let bundleReceipts: [TatwoBundleOperationReceiptV1]
    public let safetyEvidence: TatwoUpdateSafetyEvidenceV1
    public let detail: String

    public init(
        receiptID: String,
        operation: TatwoUpdateOperationV1,
        correlationID: String,
        status: TatwoUpdateStatusV1,
        errorKind: TatwoUpdateErrorKindV1,
        observedAt: Date,
        channel: TatwoUpdateChannelV1,
        artifact: TatwoUpdateArtifactMetadataV1?,
        bundleReceipts: [TatwoBundleOperationReceiptV1] = [],
        detail: String
    ) {
        schemaVersion = 1
        self.receiptID = receiptID
        self.operation = operation
        self.correlationID = correlationID
        self.status = status
        self.errorKind = errorKind
        self.observedAt = observedAt
        self.channel = channel
        self.artifact = artifact
        self.bundleReceipts = bundleReceipts
        self.safetyEvidence = TatwoUpdateSafetyEvidenceV1(bundleReceipts: bundleReceipts)
        self.detail = detail
    }
}

public struct TatwoUpdateCheckRequestV1: Codable, Hashable, Sendable {
    public let channel: TatwoUpdateChannelV1
    public let currentVersion: TatwoModuleVersionV1
    public let force: Bool
    public let correlationID: String

    public init(
        channel: TatwoUpdateChannelV1,
        currentVersion: TatwoModuleVersionV1,
        force: Bool = false,
        correlationID: String
    ) {
        self.channel = channel
        self.currentVersion = currentVersion
        self.force = force
        self.correlationID = correlationID
    }
}

public struct TatwoUpdateDownloadRequestV1: Codable, Hashable, Sendable {
    public let channel: TatwoUpdateChannelV1
    public let destination: TatwoBundlePathV1
    public let correlationID: String

    public init(
        channel: TatwoUpdateChannelV1,
        destination: TatwoBundlePathV1,
        correlationID: String
    ) {
        self.channel = channel
        self.destination = destination
        self.correlationID = correlationID
    }
}

public struct TatwoUpdateActivationPlanV1: Codable, Hashable, Sendable {
    public let stage: TatwoBundleStageRequestV1
    public let verify: TatwoBundleVerifyRequestV1
    public let archiveCurrent: TatwoBundleArchiveCurrentRequestV1
    public let atomicSwap: TatwoBundleAtomicSwapRequestV1
    public let healthCheck: TatwoBundleHealthCheckRequestV1
    public let rollbackBundle: TatwoBundleRollbackRequestV1

    public init(
        stage: TatwoBundleStageRequestV1,
        verify: TatwoBundleVerifyRequestV1,
        archiveCurrent: TatwoBundleArchiveCurrentRequestV1,
        atomicSwap: TatwoBundleAtomicSwapRequestV1,
        healthCheck: TatwoBundleHealthCheckRequestV1,
        rollbackBundle: TatwoBundleRollbackRequestV1
    ) {
        self.stage = stage
        self.verify = verify
        self.archiveCurrent = archiveCurrent
        self.atomicSwap = atomicSwap
        self.healthCheck = healthCheck
        self.rollbackBundle = rollbackBundle
    }
}

public struct TatwoUserApprovedInstallRequestV1: Codable, Hashable, Sendable {
    public let channel: TatwoUpdateChannelV1
    public let userApproved: Bool
    public let activationPlan: TatwoUpdateActivationPlanV1
    public let correlationID: String

    public init(
        channel: TatwoUpdateChannelV1,
        userApproved: Bool,
        activationPlan: TatwoUpdateActivationPlanV1,
        correlationID: String
    ) {
        self.channel = channel
        self.userApproved = userApproved
        self.activationPlan = activationPlan
        self.correlationID = correlationID
    }
}

public struct TatwoUpdateRollbackRequestV1: Codable, Hashable, Sendable {
    public let channel: TatwoUpdateChannelV1
    public let userApproved: Bool
    public let automaticActivationHealthRecovery: Bool
    public let rollbackRequest: TatwoBundleRollbackRequestV1
    public let correlationID: String

    public init(
        channel: TatwoUpdateChannelV1,
        userApproved: Bool,
        automaticActivationHealthRecovery: Bool,
        rollbackRequest: TatwoBundleRollbackRequestV1,
        correlationID: String
    ) {
        self.channel = channel
        self.userApproved = userApproved
        self.automaticActivationHealthRecovery = automaticActivationHealthRecovery
        self.rollbackRequest = rollbackRequest
        self.correlationID = correlationID
    }
}

public struct TatwoUpdateStatusSnapshotV1: Codable, Hashable, Sendable {
    public let channel: TatwoUpdateChannelV1
    public let status: TatwoUpdateStatusV1
    public let lastCheckedAt: Date?
    public let candidateVersion: TatwoModuleVersionV1?

    public init(
        channel: TatwoUpdateChannelV1,
        status: TatwoUpdateStatusV1,
        lastCheckedAt: Date?,
        candidateVersion: TatwoModuleVersionV1?
    ) {
        self.channel = channel
        self.status = status
        self.lastCheckedAt = lastCheckedAt
        self.candidateVersion = candidateVersion
    }
}

public protocol TatwoSignedAppcastPort {
    func latestEntry(for channel: TatwoUpdateChannelV1) throws -> TatwoSignedAppcastEntryV1?
}

public protocol TatwoUpdateTrustVerificationPort {
    func verify(_ entry: TatwoSignedAppcastEntryV1) -> TatwoUpdateTrustVerificationV1
}

public protocol TatwoUpdateDownloadPort {
    func download(
        artifact: TatwoUpdateArtifactMetadataV1,
        to destination: TatwoBundlePathV1
    ) throws -> TatwoBundlePathV1
}

public protocol TatwoUpdateCommandPort {
    func check(_ request: TatwoUpdateCheckRequestV1) -> TatwoUpdateReceiptV1
    func download(_ request: TatwoUpdateDownloadRequestV1) -> TatwoUpdateReceiptV1
    func requestUserApprovedInstall(
        _ request: TatwoUserApprovedInstallRequestV1
    ) -> TatwoUpdateReceiptV1
    func rollbackBundle(_ request: TatwoUpdateRollbackRequestV1) -> TatwoUpdateReceiptV1
}

public protocol TatwoUpdateStatusSnapshotProvider {
    func updateStatusSnapshot() -> TatwoUpdateStatusSnapshotV1
}

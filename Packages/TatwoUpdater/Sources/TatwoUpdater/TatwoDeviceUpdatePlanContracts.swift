import Foundation
import TatwoModuleContracts

public enum TatwoDeviceUpdateRoleV1: String, Codable, Hashable, Sendable {
    case secondary
    case primary
}

public struct TatwoDeviceUpdatePreflightSnapshotV1: Codable, Hashable, Sendable {
    public let deviceID: String
    public let role: TatwoDeviceUpdateRoleV1
    public let enrolledChannel: TatwoUpdateChannelV1
    public let currentVersion: TatwoModuleVersionV1
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let isOnline: Bool
    public let isHealthy: Bool
    public let lastSeenAt: Date?
    public let hasVerifiedRollbackBundle: Bool

    public init(
        deviceID: String,
        role: TatwoDeviceUpdateRoleV1,
        enrolledChannel: TatwoUpdateChannelV1,
        currentVersion: TatwoModuleVersionV1,
        schemaVersion: Int,
        protocolVersion: Int,
        isOnline: Bool,
        isHealthy: Bool,
        lastSeenAt: Date?,
        hasVerifiedRollbackBundle: Bool
    ) {
        self.deviceID = deviceID
        self.role = role
        self.enrolledChannel = enrolledChannel
        self.currentVersion = currentVersion
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.isOnline = isOnline
        self.isHealthy = isHealthy
        self.lastSeenAt = lastSeenAt
        self.hasVerifiedRollbackBundle = hasVerifiedRollbackBundle
    }
}

public enum TatwoDeviceUpdateSkipReasonV1: String, Codable, Hashable, Sendable {
    case none
    case userApprovalRequired
    case offline
    case staleHeartbeat
    case unhealthy
    case channelMismatch
    case schemaMismatch
    case protocolMismatch
    case rollbackUnavailable
    case alreadyCurrent
}

public enum TatwoDeviceUpdateStepStatusV1: String, Codable, Hashable, Sendable {
    case awaitingApproval
    case eligible
    case skipped
    case installed
    case failed
}

public struct TatwoDeviceUpdateStepV1: Codable, Hashable, Sendable {
    public let deviceID: String
    public let role: TatwoDeviceUpdateRoleV1
    public let executionOrder: Int
    public let observedVersion: TatwoModuleVersionV1
    public let status: TatwoDeviceUpdateStepStatusV1
    public let skipReason: TatwoDeviceUpdateSkipReasonV1
    public let lastPreflightAt: Date?
    public let detail: String

    public init(
        deviceID: String,
        role: TatwoDeviceUpdateRoleV1,
        executionOrder: Int,
        observedVersion: TatwoModuleVersionV1,
        status: TatwoDeviceUpdateStepStatusV1,
        skipReason: TatwoDeviceUpdateSkipReasonV1,
        lastPreflightAt: Date?,
        detail: String
    ) {
        self.deviceID = deviceID
        self.role = role
        self.executionOrder = executionOrder
        self.observedVersion = observedVersion
        self.status = status
        self.skipReason = skipReason
        self.lastPreflightAt = lastPreflightAt
        self.detail = detail
    }
}

public enum TatwoDeviceUpdatePlanStatusV1: String, Codable, Hashable, Sendable {
    case awaitingApproval
    case ready
    case partiallyEligible
    case blocked
    case inProgress
    case completed
    case failed
}

public struct TatwoDeviceUpdatePlanV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let domainID: String
    public let channel: TatwoUpdateChannelV1
    public let artifact: TatwoUpdateArtifactMetadataV1
    public let createdAt: Date
    public let approvedAt: Date?
    public let maximumHeartbeatAgeSeconds: TimeInterval
    public let status: TatwoDeviceUpdatePlanStatusV1
    public let steps: [TatwoDeviceUpdateStepV1]

    public init(
        planID: String,
        domainID: String,
        channel: TatwoUpdateChannelV1,
        artifact: TatwoUpdateArtifactMetadataV1,
        createdAt: Date,
        approvedAt: Date?,
        maximumHeartbeatAgeSeconds: TimeInterval,
        status: TatwoDeviceUpdatePlanStatusV1,
        steps: [TatwoDeviceUpdateStepV1]
    ) {
        schemaVersion = 1
        self.planID = planID
        self.domainID = domainID
        self.channel = channel
        self.artifact = artifact
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.maximumHeartbeatAgeSeconds = maximumHeartbeatAgeSeconds
        self.status = status
        self.steps = steps
    }
}

public struct TatwoCreateDeviceUpdatePlanRequestV1: Codable, Hashable, Sendable {
    public let planID: String
    public let domainID: String
    public let channel: TatwoUpdateChannelV1
    public let artifact: TatwoUpdateArtifactMetadataV1
    public let selectedDevices: [TatwoDeviceUpdatePreflightSnapshotV1]
    public let maximumHeartbeatAgeSeconds: TimeInterval
    public let createdAt: Date

    public init(
        planID: String,
        domainID: String,
        channel: TatwoUpdateChannelV1,
        artifact: TatwoUpdateArtifactMetadataV1,
        selectedDevices: [TatwoDeviceUpdatePreflightSnapshotV1],
        maximumHeartbeatAgeSeconds: TimeInterval = 120,
        createdAt: Date
    ) {
        self.planID = planID
        self.domainID = domainID
        self.channel = channel
        self.artifact = artifact
        self.selectedDevices = selectedDevices
        self.maximumHeartbeatAgeSeconds = maximumHeartbeatAgeSeconds
        self.createdAt = createdAt
    }
}

public struct TatwoApproveDeviceUpdatePlanRequestV1: Codable, Hashable, Sendable {
    public let planID: String
    public let userApproved: Bool
    public let deviceSnapshots: [TatwoDeviceUpdatePreflightSnapshotV1]
    public let observedAt: Date

    public init(
        planID: String,
        userApproved: Bool,
        deviceSnapshots: [TatwoDeviceUpdatePreflightSnapshotV1],
        observedAt: Date
    ) {
        self.planID = planID
        self.userApproved = userApproved
        self.deviceSnapshots = deviceSnapshots
        self.observedAt = observedAt
    }
}

public enum TatwoDeviceUpdateExecutionOutcomeV1: String, Codable, Hashable, Sendable {
    case installed
    case failed
}

public protocol TatwoDeviceUpdatePlanCommandPort {
    func createPlan(
        _ request: TatwoCreateDeviceUpdatePlanRequestV1
    ) throws -> TatwoDeviceUpdatePlanV1

    func approvePlan(
        _ request: TatwoApproveDeviceUpdatePlanRequestV1
    ) throws -> TatwoDeviceUpdatePlanV1

    func revalidateDevice(
        planID: String,
        snapshot: TatwoDeviceUpdatePreflightSnapshotV1,
        observedAt: Date
    ) throws -> TatwoDeviceUpdatePlanV1

    func recordDeviceOutcome(
        planID: String,
        deviceID: String,
        outcome: TatwoDeviceUpdateExecutionOutcomeV1,
        detail: String,
        observedAt: Date
    ) throws -> TatwoDeviceUpdatePlanV1
}

public protocol TatwoDeviceUpdatePlanSnapshotProvider {
    func deviceUpdatePlan(planID: String) -> TatwoDeviceUpdatePlanV1?
    func allDeviceUpdatePlans() -> [TatwoDeviceUpdatePlanV1]
    func nextEligibleDeviceID(planID: String) -> String?
}

public enum TatwoDeviceUpdatePlanError: Error, Equatable, Sendable {
    case emptyPlanID
    case emptyDomainID
    case emptyDeviceSelection
    case invalidHeartbeatAge
    case artifactChannelMismatch
    case duplicateDeviceID(String)
    case multiplePrimaryDevices
    case planAlreadyExists(String)
    case planNotFound(String)
    case userApprovalRequired
    case planAlreadyApproved(String)
    case deviceSetMismatch
    case deviceRoleChanged(String)
    case deviceNotFound(String)
    case invalidDeviceTransition(String)
    case corruptPersistence(String)
}

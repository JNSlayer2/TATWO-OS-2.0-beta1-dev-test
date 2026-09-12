import Foundation

public struct TatwoWorkReceiptMetadataV1: Codable, Hashable, Sendable {
    public let receiptID: String
    public let schema: String
    public let version: Int
    public let correlationID: String
    public let createdAt: Date
    public let sourceDeviceID: String

    public init(
        receiptID: String,
        schema: String,
        version: Int,
        correlationID: String,
        createdAt: Date,
        sourceDeviceID: String
    ) {
        self.receiptID = receiptID
        self.schema = schema
        self.version = version
        self.correlationID = correlationID
        self.createdAt = createdAt
        self.sourceDeviceID = sourceDeviceID
    }
}

public enum TatwoGoalRunProjectionStatusV1: String, Codable, Hashable, Sendable {
    case planned
    case running
    case blocked
    case succeeded
    case failed
    case cancelled
}

public struct TatwoGoalRunProjectionV1: Codable, Hashable, Sendable {
    public let goalRunID: String
    public let objective: String
    public let status: TatwoGoalRunProjectionStatusV1
    public let phase: String
    public let progressCompleted: Int
    public let progressTotal: Int
    public let issueIDs: [String]
    public let updatedAt: Date
    public let receiptMetadata: TatwoWorkReceiptMetadataV1

    public init(
        goalRunID: String,
        objective: String,
        status: TatwoGoalRunProjectionStatusV1,
        phase: String,
        progressCompleted: Int,
        progressTotal: Int,
        issueIDs: [String],
        updatedAt: Date,
        receiptMetadata: TatwoWorkReceiptMetadataV1
    ) {
        precondition(progressCompleted >= 0, "Completed progress must be non-negative")
        precondition(progressTotal >= 0, "Total progress must be non-negative")
        precondition(progressCompleted <= progressTotal, "Completed progress cannot exceed total")
        self.goalRunID = goalRunID
        self.objective = objective
        self.status = status
        self.phase = phase
        self.progressCompleted = progressCompleted
        self.progressTotal = progressTotal
        self.issueIDs = issueIDs
        self.updatedAt = updatedAt
        self.receiptMetadata = receiptMetadata
    }
}

public enum TatwoIssueProjectionStatusV1: String, Codable, Hashable, Sendable {
    case queued
    case active
    case blocked
    case resolved
    case dismissed
}

public enum TatwoIssueProjectionPriorityV1: Int, Codable, Hashable, Sendable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TatwoIssueProjectionV1: Codable, Hashable, Sendable {
    public let issueID: String
    public let goalRunID: String?
    public let title: String
    public let status: TatwoIssueProjectionStatusV1
    public let priority: TatwoIssueProjectionPriorityV1
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        issueID: String,
        goalRunID: String?,
        title: String,
        status: TatwoIssueProjectionStatusV1,
        priority: TatwoIssueProjectionPriorityV1,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.issueID = issueID
        self.goalRunID = goalRunID
        self.title = title
        self.status = status
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TatwoIssueQueueProjectionV1: Codable, Hashable, Sendable {
    public let queueID: String
    public let issues: [TatwoIssueProjectionV1]
    public let projectedAt: Date
    public let receiptMetadata: TatwoWorkReceiptMetadataV1

    public init(
        queueID: String,
        issues: [TatwoIssueProjectionV1],
        projectedAt: Date,
        receiptMetadata: TatwoWorkReceiptMetadataV1
    ) {
        self.queueID = queueID
        self.issues = issues
        self.projectedAt = projectedAt
        self.receiptMetadata = receiptMetadata
    }
}

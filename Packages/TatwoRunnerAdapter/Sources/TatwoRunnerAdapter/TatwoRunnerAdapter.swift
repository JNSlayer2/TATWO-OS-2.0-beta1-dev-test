import Foundation
import TatwoWorkReceiptContracts

public enum TatwoRunnerLifecycleStateV1: String, Codable, Hashable, Sendable {
    case idle
    case running
    case suspended
    case cancelled
}

public struct TatwoRunnerSessionRequestV1: Codable, Hashable, Sendable {
    public let sessionID: String
    public let correlationID: String
    public let sourceDeviceID: String
    public let sandboxReference: String
    public let worktreeReference: String?

    public init(
        sessionID: String,
        correlationID: String,
        sourceDeviceID: String,
        sandboxReference: String,
        worktreeReference: String? = nil
    ) {
        self.sessionID = sessionID
        self.correlationID = correlationID
        self.sourceDeviceID = sourceDeviceID
        self.sandboxReference = sandboxReference
        self.worktreeReference = worktreeReference
    }
}

public struct TatwoRunnerActivityProjectionV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: String
    public let state: TatwoRunnerLifecycleStateV1
    public let sandboxReference: String
    public let worktreeReference: String?
    public let observedAt: Date
    public let dataPlaneEligible: Bool

    public init(
        sessionID: String,
        state: TatwoRunnerLifecycleStateV1,
        sandboxReference: String,
        worktreeReference: String?,
        observedAt: Date
    ) {
        self.schemaVersion = 1
        self.sessionID = sessionID
        self.state = state
        self.sandboxReference = sandboxReference
        self.worktreeReference = worktreeReference
        self.observedAt = observedAt
        self.dataPlaneEligible = false
    }
}

public struct TatwoRunnerCommandReceiptV1: Codable, Hashable, Sendable {
    public let metadata: TatwoWorkReceiptMetadataV1
    public let accepted: Bool
    public let activity: TatwoRunnerActivityProjectionV1?
    public let processMutationCount: Int
    public let domainTruthWriteCount: Int
    public let authorityMutationCount: Int
    public let updateTriggerCount: Int
    public let detail: String

    public init(
        metadata: TatwoWorkReceiptMetadataV1,
        accepted: Bool,
        activity: TatwoRunnerActivityProjectionV1?,
        processMutationCount: Int,
        detail: String
    ) {
        self.metadata = metadata
        self.accepted = accepted
        self.activity = activity
        self.processMutationCount = processMutationCount
        self.domainTruthWriteCount = 0
        self.authorityMutationCount = 0
        self.updateTriggerCount = 0
        self.detail = detail
    }
}

public enum TatwoRunnerBoundaryKindV1: String, Codable, Hashable, Sendable {
    case domainEventEncoding
    case domainReceiptFromProse
}

public struct TatwoRunnerBoundaryReceiptV1: Codable, Hashable, Sendable {
    public let metadata: TatwoWorkReceiptMetadataV1
    public let boundary: TatwoRunnerBoundaryKindV1
    public let allowed: Bool
    public let domainTruthWriteCount: Int
    public let domainReceiptAcceptedCount: Int
    public let updateTriggerCount: Int
    public let detail: String

    public init(
        metadata: TatwoWorkReceiptMetadataV1,
        boundary: TatwoRunnerBoundaryKindV1,
        detail: String
    ) {
        self.metadata = metadata
        self.boundary = boundary
        self.allowed = false
        self.domainTruthWriteCount = 0
        self.domainReceiptAcceptedCount = 0
        self.updateTriggerCount = 0
        self.detail = detail
    }
}

public protocol TatwoRunnerAdapterCommandPort: AnyObject {
    func start(_ request: TatwoRunnerSessionRequestV1) -> TatwoRunnerCommandReceiptV1
    func resume(_ request: TatwoRunnerSessionRequestV1) -> TatwoRunnerCommandReceiptV1
    func cancel(_ request: TatwoRunnerSessionRequestV1) -> TatwoRunnerCommandReceiptV1
    func subscribeLocalEvents() -> [TatwoRunnerActivityProjectionV1]
}

public protocol TatwoRunnerActivitySnapshotProvider: AnyObject {
    func activitySnapshot() -> [TatwoRunnerActivityProjectionV1]
}

public final class TatwoRunnerAdapter:
    TatwoRunnerAdapterCommandPort,
    TatwoRunnerActivitySnapshotProvider
{
    private let now: () -> Date
    private let makeReceiptID: () -> String
    private var activitiesBySessionID: [String: TatwoRunnerActivityProjectionV1] = [:]

    public init(
        now: @escaping () -> Date = Date.init,
        receiptID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.now = now
        self.makeReceiptID = receiptID
    }

    public func start(
        _ request: TatwoRunnerSessionRequestV1
    ) -> TatwoRunnerCommandReceiptV1 {
        transition(
            request,
            to: .running,
            processMutationCount: 1,
            detail: "Started a machine-local runner session"
        )
    }

    public func resume(
        _ request: TatwoRunnerSessionRequestV1
    ) -> TatwoRunnerCommandReceiptV1 {
        transition(
            request,
            to: .running,
            processMutationCount: 1,
            detail: "Resumed a machine-local runner session"
        )
    }

    public func cancel(
        _ request: TatwoRunnerSessionRequestV1
    ) -> TatwoRunnerCommandReceiptV1 {
        transition(
            request,
            to: .cancelled,
            processMutationCount: 1,
            detail: "Cancelled a machine-local runner session"
        )
    }

    public func subscribeLocalEvents() -> [TatwoRunnerActivityProjectionV1] {
        activitySnapshot()
    }

    public func activitySnapshot() -> [TatwoRunnerActivityProjectionV1] {
        activitiesBySessionID.values.sorted { $0.sessionID < $1.sessionID }
    }

    public func rejectDomainEventEncoding(
        activity: TatwoRunnerActivityProjectionV1,
        correlationID: String,
        sourceDeviceID: String
    ) -> TatwoRunnerBoundaryReceiptV1 {
        TatwoRunnerBoundaryReceiptV1(
            metadata: metadata(
                correlationID: correlationID,
                sourceDeviceID: sourceDeviceID,
                schema: "TatwoRunnerBoundaryReceiptV1"
            ),
            boundary: .domainEventEncoding,
            detail:
                "Runner state is machine-local activity and cannot encode itself as domain truth"
        )
    }

    public func rejectProseAsDomainReceipt(
        _ prose: String,
        correlationID: String,
        sourceDeviceID: String
    ) -> TatwoRunnerBoundaryReceiptV1 {
        TatwoRunnerBoundaryReceiptV1(
            metadata: metadata(
                correlationID: correlationID,
                sourceDeviceID: sourceDeviceID,
                schema: "TatwoRunnerBoundaryReceiptV1"
            ),
            boundary: .domainReceiptFromProse,
            detail:
                prose.isEmpty
                    ? "Empty prose is not a typed domain receipt"
                    : "Runner prose is not a typed, verified domain receipt"
        )
    }

    private func transition(
        _ request: TatwoRunnerSessionRequestV1,
        to state: TatwoRunnerLifecycleStateV1,
        processMutationCount: Int,
        detail: String
    ) -> TatwoRunnerCommandReceiptV1 {
        guard Self.isBounded(request.sessionID),
              Self.isBounded(request.correlationID),
              Self.isBounded(request.sourceDeviceID),
              Self.isBounded(request.sandboxReference)
        else {
            return TatwoRunnerCommandReceiptV1(
                metadata: metadata(
                    correlationID: request.correlationID,
                    sourceDeviceID: request.sourceDeviceID,
                    schema: "TatwoRunnerCommandReceiptV1"
                ),
                accepted: false,
                activity: nil,
                processMutationCount: 0,
                detail: "Runner command identifiers must be bounded non-empty text"
            )
        }

        let activity = TatwoRunnerActivityProjectionV1(
            sessionID: request.sessionID,
            state: state,
            sandboxReference: request.sandboxReference,
            worktreeReference: request.worktreeReference,
            observedAt: now()
        )
        activitiesBySessionID[request.sessionID] = activity
        return TatwoRunnerCommandReceiptV1(
            metadata: metadata(
                correlationID: request.correlationID,
                sourceDeviceID: request.sourceDeviceID,
                schema: "TatwoRunnerCommandReceiptV1"
            ),
            accepted: true,
            activity: activity,
            processMutationCount: processMutationCount,
            detail: detail
        )
    }

    private func metadata(
        correlationID: String,
        sourceDeviceID: String,
        schema: String
    ) -> TatwoWorkReceiptMetadataV1 {
        TatwoWorkReceiptMetadataV1(
            receiptID: makeReceiptID(),
            schema: schema,
            version: 1,
            correlationID: correlationID,
            createdAt: now(),
            sourceDeviceID: sourceDeviceID
        )
    }

    private static func isBounded(_ value: String) -> Bool {
        let count = value.utf8.count
        return count > 0 && count <= 512
    }
}

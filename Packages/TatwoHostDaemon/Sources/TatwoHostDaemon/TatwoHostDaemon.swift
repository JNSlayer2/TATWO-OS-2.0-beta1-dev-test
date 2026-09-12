import Foundation
import TatwoRunnerAdapter
import TatwoWorkReceiptContracts

public enum TatwoHostConnectionStateV1: String, Codable, Hashable, Sendable {
    case offline
    case connected
    case reconnecting
}

public struct TatwoHostSessionRequestV1: Codable, Hashable, Sendable {
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

public struct TatwoHostActivitySnapshotV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let hostID: String
    public let connectionState: TatwoHostConnectionStateV1
    public let observedAt: Date
    public let activeRunnerSessionIDs: [String]
    public let dataPlaneEligible: Bool
    public let authorityPromotionCount: Int
    public let domainTruthWriteCount: Int
    public let updateTriggerCount: Int

    public init(
        hostID: String,
        connectionState: TatwoHostConnectionStateV1,
        observedAt: Date,
        activeRunnerSessionIDs: [String]
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.connectionState = connectionState
        self.observedAt = observedAt
        self.activeRunnerSessionIDs = activeRunnerSessionIDs
        self.dataPlaneEligible = false
        self.authorityPromotionCount = 0
        self.domainTruthWriteCount = 0
        self.updateTriggerCount = 0
    }
}

public struct TatwoHostCommandReceiptV1: Codable, Hashable, Sendable {
    public let metadata: TatwoWorkReceiptMetadataV1
    public let accepted: Bool
    public let runnerReceipt: TatwoRunnerCommandReceiptV1?
    public let authorityPromotionCount: Int
    public let domainTruthWriteCount: Int
    public let updateTriggerCount: Int
    public let detail: String

    public init(
        metadata: TatwoWorkReceiptMetadataV1,
        accepted: Bool,
        runnerReceipt: TatwoRunnerCommandReceiptV1?,
        detail: String
    ) {
        self.metadata = metadata
        self.accepted = accepted
        self.runnerReceipt = runnerReceipt
        self.authorityPromotionCount = 0
        self.domainTruthWriteCount = 0
        self.updateTriggerCount = 0
        self.detail = detail
    }
}

public protocol TatwoHostDaemonCommandPort: AnyObject {
    func startLocalSession(_ request: TatwoHostSessionRequestV1) -> TatwoHostCommandReceiptV1
    func resumeLocalSession(_ request: TatwoHostSessionRequestV1) -> TatwoHostCommandReceiptV1
    func cancelLocalSession(_ request: TatwoHostSessionRequestV1) -> TatwoHostCommandReceiptV1
    func requestReconnect(correlationID: String) -> TatwoHostCommandReceiptV1
}

public protocol TatwoHostActivitySnapshotProvider: AnyObject {
    func hostActivitySnapshot() -> TatwoHostActivitySnapshotV1
}

public final class TatwoHostDaemon:
    TatwoHostDaemonCommandPort,
    TatwoHostActivitySnapshotProvider
{
    private let hostID: String
    private let sourceDeviceID: String
    private let runner: any TatwoRunnerAdapterCommandPort
    private let now: () -> Date
    private let makeReceiptID: () -> String
    private var connectionState: TatwoHostConnectionStateV1

    public init(
        hostID: String,
        sourceDeviceID: String,
        runner: any TatwoRunnerAdapterCommandPort,
        initiallyConnected: Bool = false,
        now: @escaping () -> Date = Date.init,
        receiptID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.hostID = hostID
        self.sourceDeviceID = sourceDeviceID
        self.runner = runner
        self.connectionState = initiallyConnected ? .connected : .offline
        self.now = now
        self.makeReceiptID = receiptID
    }

    public func startLocalSession(
        _ request: TatwoHostSessionRequestV1
    ) -> TatwoHostCommandReceiptV1 {
        wrap(
            request: request,
            runnerReceipt: runner.start(runnerRequest(request)),
            detail: "Host forwarded an explicit machine-local start command"
        )
    }

    public func resumeLocalSession(
        _ request: TatwoHostSessionRequestV1
    ) -> TatwoHostCommandReceiptV1 {
        wrap(
            request: request,
            runnerReceipt: runner.resume(runnerRequest(request)),
            detail: "Host forwarded an explicit machine-local resume command"
        )
    }

    public func cancelLocalSession(
        _ request: TatwoHostSessionRequestV1
    ) -> TatwoHostCommandReceiptV1 {
        wrap(
            request: request,
            runnerReceipt: runner.cancel(runnerRequest(request)),
            detail: "Host forwarded an explicit machine-local cancel command"
        )
    }

    public func requestReconnect(
        correlationID: String
    ) -> TatwoHostCommandReceiptV1 {
        connectionState = .reconnecting
        connectionState = .connected
        return TatwoHostCommandReceiptV1(
            metadata: metadata(correlationID: correlationID),
            accepted: true,
            runnerReceipt: nil,
            detail:
                "Host reconnect changed machine-local connectivity only; it did not promote authority"
        )
    }

    public func hostActivitySnapshot() -> TatwoHostActivitySnapshotV1 {
        TatwoHostActivitySnapshotV1(
            hostID: hostID,
            connectionState: connectionState,
            observedAt: now(),
            activeRunnerSessionIDs: runner.subscribeLocalEvents()
                .filter { $0.state == .running || $0.state == .suspended }
                .map(\.sessionID)
                .sorted()
        )
    }

    public func rejectAuthorityPromotion(
        correlationID: String
    ) -> TatwoHostCommandReceiptV1 {
        TatwoHostCommandReceiptV1(
            metadata: metadata(correlationID: correlationID),
            accepted: false,
            runnerReceipt: nil,
            detail:
                "Host connectivity and execution state cannot promote domain authority"
        )
    }

    private func runnerRequest(
        _ request: TatwoHostSessionRequestV1
    ) -> TatwoRunnerSessionRequestV1 {
        TatwoRunnerSessionRequestV1(
            sessionID: request.sessionID,
            correlationID: request.correlationID,
            sourceDeviceID: request.sourceDeviceID,
            sandboxReference: request.sandboxReference,
            worktreeReference: request.worktreeReference
        )
    }

    private func wrap(
        request: TatwoHostSessionRequestV1,
        runnerReceipt: TatwoRunnerCommandReceiptV1,
        detail: String
    ) -> TatwoHostCommandReceiptV1 {
        TatwoHostCommandReceiptV1(
            metadata: metadata(correlationID: request.correlationID),
            accepted: runnerReceipt.accepted,
            runnerReceipt: runnerReceipt,
            detail: detail
        )
    }

    private func metadata(
        correlationID: String
    ) -> TatwoWorkReceiptMetadataV1 {
        TatwoWorkReceiptMetadataV1(
            receiptID: makeReceiptID(),
            schema: "TatwoHostCommandReceiptV1",
            version: 1,
            correlationID: correlationID,
            createdAt: now(),
            sourceDeviceID: sourceDeviceID
        )
    }
}

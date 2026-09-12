// CLI Core 同名假資料版；只保留 Apps/TatwoUltraworkMac CLI 畫面實際讀取的欄位與 case。
import Foundation

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoChatRouteProfile.swift:5-123；只保留顯示名稱
// TatwoChatRouteProfile：已由照搬檔提供，stub 移除


// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/DispatchRegistry.swift:17-384；只保留畫面欄位
enum TatwoDispatchFailureClass: String, Sendable, Equatable {
    case retryable, terminal, unknown
}

struct TatwoDispatchFailureReceipt: Sendable, Equatable {
    let failureClass: TatwoDispatchFailureClass
    let errorCode: String?
    let operatorMessage: String
}

extension TatwoDispatchRecord {
    var contractID: String { "fixture-contract" }
    var goalID: String? { nil }
    var subtask: String { "" }
    var receiptID: String? { nil }
    var outputRef: String? { nil }
    var errorMessage: String? { nil }
    var failureReceipt: TatwoDispatchFailureReceipt? { nil }
    var remoteStatus: TatwoLoopJobStatusV1? { nil }
}

struct TatwoStoredDispatchRun {
    let contractID: String
    var records: [TatwoDispatchRecord]
    var updatedAt: Date
    var sealID: String?

    init(
        contractID: String,
        records: [TatwoDispatchRecord] = [],
        updatedAt: Date = Date(),
        sealID: String? = nil
    ) {
        self.contractID = contractID
        self.records = records
        self.updatedAt = updatedAt
        self.sealID = sealID
    }
}

extension TatwoDispatchRegistry {
    var directoryURL: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }

    static func `default`(
        environment: [String: String]
    ) -> TatwoDispatchRegistry {
        .init()
    }

    func allRuns() -> [TatwoStoredDispatchRun] { [] }
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/RemoteLoopJob.swift:4-48；只保留畫面 case 與標籤
enum TatwoLoopJobStatusV1: String, Sendable, Equatable, CaseIterable {
    case queued, delivered, accepted, running, completed, failed, cancelled, verified

    var designSemanticLabel: String {
        switch self {
        case .queued: "已排隊"
        case .delivered: "已送達"
        case .accepted: "已啟動(runner接受)"
        case .running: "執行中"
        case .completed: "已完成"
        case .failed: "失敗"
        case .cancelled: "已取消"
        case .verified: "已驗收"
        }
    }
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoLoopsSubActivityPresentation.swift:3-124；同名純投影假資料
struct TatwoLoopsSubActivityInput: Sendable, Equatable {
    let id: String
    let contractID: String
    let identity: String
    let modelName: String
    let subtask: String
    let queued: Bool
    let startedAt: Date
}

enum TatwoLoopsContractActivityPhase: String, Sendable, Equatable {
    case running, awaitingAcceptance, blocked, completed
}

enum TatwoLoopsSubActivityStatus: String, Sendable, Equatable {
    case queued = "排隊"
    case running = "執行中"
    case awaitingAcceptance = "等待驗收"
    case blocked = "受阻"
    case completed = "已完成"
}

struct TatwoLoopsSubActivityPresentationRow: Identifiable, Sendable, Equatable {
    let id: String
    let identity: String
    let modelName: String
    let currentWork: String
    let status: TatwoLoopsSubActivityStatus
    let elapsedSeconds: TimeInterval
    let elapsedLabel: String
    let stepNumber: Int
}

enum TatwoLoopsSubActivityPresentation: Sendable, Equatable {
    case empty(message: String)
    case rows([TatwoLoopsSubActivityPresentationRow])
}

enum TatwoLoopsSubActivityPresenter {
    static func present(
        rows: [TatwoLoopsSubActivityInput],
        currentContractID: String,
        phase: TatwoLoopsContractActivityPhase,
        now: Date
    ) -> TatwoLoopsSubActivityPresentation {
        let matching = rows.filter { $0.contractID == currentContractID }
        guard !matching.isEmpty else { return .empty(message: "目前沒有 sub 在跑") }
        return .rows(matching.enumerated().map { index, input in
            let status: TatwoLoopsSubActivityStatus
            switch phase {
            case .running: status = input.queued ? .queued : .running
            case .awaitingAcceptance: status = .awaitingAcceptance
            case .blocked: status = .blocked
            case .completed: status = .completed
            }
            let elapsed = max(0, now.timeIntervalSince(input.startedAt))
            return TatwoLoopsSubActivityPresentationRow(
                id: input.id,
                identity: input.identity,
                modelName: input.modelName,
                currentWork: input.subtask,
                status: status,
                elapsedSeconds: elapsed,
                elapsedLabel: "\(Int(elapsed)) 秒",
                stepNumber: index + 1)
        })
    }
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/LoopsSessionCore.swift:3-198；只保留 LoopsSessionRail 畫面欄位
struct TatwoLoopsPLG: Sendable, Equatable {
    var plan = ""
    var loops = ""
    var goal = ""
}

enum TatwoLoopsStatus: String, Sendable, Equatable {
    case planned, running, blocked, passed, rollbackRequired
}

struct TatwoLoopsSubAgent: Identifiable, Sendable, Equatable {
    let id = UUID()
    var label: String
    var modelID: String
    var status: TatwoLoopsStatus
}

struct TatwoLoopsCycleProgress: Identifiable, Sendable, Equatable {
    let id = UUID()
    var round: Int
    var totalRounds: Int
    var producedCount: Int
    var verifiedCount: Int
    var blockedCount: Int
}

struct TatwoLoopsMessage: Identifiable, Sendable, Equatable {
    let id = UUID()
    var role: String
    var authorModelID: String?
    var text: String
    var createdISO: String
}

struct TatwoLoopsSession: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var supervisorModelID: String
    var reviewerModelID: String?
    var plg: TatwoLoopsPLG
    var subAgents: [TatwoLoopsSubAgent]
    var status: TatwoLoopsStatus
    var cycles: [TatwoLoopsCycleProgress]
    var createdISO: String
    var messages: [TatwoLoopsMessage]
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/LoopsDispatchPlanner.swift:3-174；只保留 UI truth
enum TatwoLoopsRuntimeTruthState: String, Sendable, Equatable {
    case planningPreview, notDispatched, dispatched, running, receiptGated, blocked
}

struct TatwoLoopsRuntimeTruthSummary: Sendable, Equatable {
    let state: TatwoLoopsRuntimeTruthState
    let headline: String
    let dispatchLabel: String
    let runtimeReceiptLabel: String
    let nextAction: String
    let plannedAgentCount: Int
    let activeAgentCount: Int
    let producedArtifactCount: Int
    let verifiedArtifactCount: Int
    let blockedArtifactCount: Int
    let runtimeReceiptCount: Int
    let countsAsRuntimeProgress: Bool
}

enum TatwoLoopsDispatchPlanner {
    static func runtimeTruth(
        session: TatwoLoopsSession,
        dispatchRecords: [TatwoDispatchRecord] = []
    ) -> TatwoLoopsRuntimeTruthSummary {
        let ledger = TatwoDispatchRuntimeReducer.reduce(records: dispatchRecords)
        let state: TatwoLoopsRuntimeTruthState
        switch ledger.phase {
        case .failed: state = .blocked
        case .running: state = .running
        case .queued, .delivered, .started: state = .dispatched
        case .completed, .verified: state = .receiptGated
        case .none:
            state = session.subAgents.isEmpty && session.cycles.isEmpty
                ? .planningPreview : .notDispatched
        }
        return TatwoLoopsRuntimeTruthSummary(
            state: state,
            headline: ledger.headline,
            dispatchLabel: ledger.progressLabel,
            runtimeReceiptLabel: ledger.runtimeReceiptLabel,
            nextAction: "假資料模式",
            plannedAgentCount: session.subAgents.count,
            activeAgentCount: ledger.runningCount,
            producedArtifactCount: session.cycles.last?.producedCount ?? 0,
            verifiedArtifactCount: session.cycles.last?.verifiedCount ?? 0,
            blockedArtifactCount: session.cycles.last?.blockedCount ?? 0,
            runtimeReceiptCount: ledger.runtimeReceiptCount,
            countsAsRuntimeProgress: ledger.hasRuntimeEvidence)
    }
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/DispatchRuntimeProjection.swift:6-205；同名假資料 reducer
enum TatwoDispatchRuntimePhase: String, Sendable, Equatable {
    case none, queued, delivered, started, running, completed, verified, failed
}

struct TatwoDispatchRuntimeSummary: Sendable, Equatable {
    let phase: TatwoDispatchRuntimePhase
    let recordCount: Int
    let runningCount: Int
    let runtimeReceiptCount: Int

    var hasRuntimeEvidence: Bool { recordCount > 0 }
    var headline: String {
        switch phase {
        case .none: "尚未派發"
        case .queued: "已排隊"
        case .delivered: "已送達"
        case .started: "已啟動"
        case .running: "執行中"
        case .completed: "已完成，等待驗收"
        case .verified: "已驗收"
        case .failed: "執行受阻"
        }
    }
    var progressLabel: String { hasRuntimeEvidence ? "\(recordCount) 筆 dispatch" : "dispatch ledger 尚無紀錄" }
    var runtimeReceiptLabel: String { runtimeReceiptCount == 0 ? "無 runtime receipt" : "\(runtimeReceiptCount) 份 runtime receipt" }
}

enum TatwoDispatchRuntimeReducer {
    static func reduce(
        records: [TatwoDispatchRecord],
        contractID: String? = nil
    ) -> TatwoDispatchRuntimeSummary {
        let scoped = records.filter { contractID == nil || $0.contractID == contractID }
        let phase: TatwoDispatchRuntimePhase
        if scoped.contains(where: { $0.status == .failed }) {
            phase = .failed
        } else if scoped.contains(where: { $0.status == .running }) {
            phase = .running
        } else if scoped.contains(where: { $0.status == .queued }) {
            phase = .queued
        } else if scoped.contains(where: { $0.status == .verified }) {
            phase = .verified
        } else if scoped.contains(where: { $0.status == .completed }) {
            phase = .completed
        } else {
            phase = .none
        }
        return TatwoDispatchRuntimeSummary(
            phase: phase,
            recordCount: scoped.count,
            runningCount: scoped.filter { $0.status == .running }.count,
            runtimeReceiptCount: scoped.filter { $0.receiptID != nil }.count)
    }
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoPLGOrchestrator.swift:393-454；只保留 UI 欄位
struct TatwoPLGRun: Identifiable, Sendable, Equatable {
    let id: UUID
    var contractID: String
    var planSummary: String
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/PLGGovernance.swift:26-340；只保留 UI execution truth
enum TatwoPLGExecutionTruthState: String, Sendable, Equatable {
    case planningPreview, notDispatched, dispatched, running, receiptGated, blocked
}

struct TatwoPLGExecutionTruthSummary: Sendable, Equatable {
    let state: TatwoPLGExecutionTruthState
}

enum TatwoPLGGovernance {
    static func executionTruth(
        run: TatwoPLGRun,
        dispatchRecords: [TatwoDispatchRecord]
    ) -> TatwoPLGExecutionTruthSummary {
        let phase = TatwoDispatchRuntimeReducer.reduce(
            records: dispatchRecords,
            contractID: run.contractID).phase
        switch phase {
        case .failed: return .init(state: .blocked)
        case .running: return .init(state: .running)
        case .queued, .delivered, .started: return .init(state: .dispatched)
        case .completed, .verified: return .init(state: .receiptGated)
        case .none: return .init(state: .planningPreview)
        }
    }
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalRunStore.swift:240-323；只保留 UI join 欄位
struct TatwoStoredGoalRun: Sendable, Equatable {
    let contractID: String
    let updatedAt: Date
}

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalRunLaneAggregation.swift:5-254；只保留狀態、blocker 與聚合結果
enum TatwoGoalRunLaneStateV1: String, Sendable, Equatable {
    case planned, waitingDependency, ready, running, humanGate, blocked, superseded, passed, rollbackRequired
}

struct TatwoGoalRunLaneV1: Identifiable, Sendable, Equatable {
    let id: String
    let state: TatwoGoalRunLaneStateV1
    let blockers: [String]
}

struct TatwoGoalRunLaneSnapshotV1: Sendable, Equatable {
    let lanes: [TatwoGoalRunLaneV1]
}

enum TatwoGoalRunLaneAggregator {
    static func aggregate(
        goalRecords: [TatwoStoredGoalRun],
        dispatchRuns: [TatwoStoredDispatchRun],
        observedAt: Date
    ) -> TatwoGoalRunLaneSnapshotV1 {
        .init(lanes: [])
    }
}

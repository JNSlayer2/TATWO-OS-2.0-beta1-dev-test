// 來源：1.0 Work OS workflow 畫面相依型別；只保留 run A 畫面欄位與記憶體假資料
import SwiftUI

enum GoalRunStatus: String, Equatable, Sendable {
    case planned, dispatching, running, succeeded, failed, cancelled
    case humanGate = "human_gate"
    case awaitingNextCycle = "awaiting_next_cycle"
    case blocked, passed
    case rollbackRequired = "rollback_required"
    case superseded
}

enum WorkOSConfigStage: String, Equatable, Sendable {
    case staging
    case activeReady = "active_ready"
}

enum WorkOSSandboxType: String, Equatable, Sendable {
    case none
    case stagingConfig = "staging_config"
    case tempWorkspace = "temp_workspace"
    case colimaDryRun = "colima_dry_run"
}

struct WorkOSSandboxPolicy: Equatable, Sendable {
    let required = true
    let humanGateRequired = true
}

struct WorkOSReceiptRequirement: Identifiable, Equatable, Sendable {
    let id = "fixture-receipt"
    let title = "測試"
    let kind = "test"
    let requiredForPass = true
}

enum WorkOSDomainKind: String, Equatable, Sendable {
    case ui, code, debug, research, modeling, ops, custom
    var plainName: String {
        switch self {
        case .ui: "UI / UX"
        case .code: "代碼"
        case .debug: "除錯"
        case .research: "研究"
        case .modeling: "建模"
        case .ops: "運維"
        case .custom: "自訂"
        }
    }
}

struct GoalRun: Equatable, Sendable { let status: GoalRunStatus = .planned }

struct MainlineLoop: Equatable, Sendable {
    let ownerIdentity: IdentityKind = .lead
    let allowedTools = ["diff", "test"]
}

struct DomainLoop: Identifiable, Equatable, Sendable {
    let id = "fixture-domain"
    let domain: WorkOSDomainKind = .code
    let ownerIdentity: IdentityKind = .lead
    let allowedTools = ["diff"]
    let sandboxType: WorkOSSandboxType = .stagingConfig
    let requiredReceipts = [WorkOSReceiptRequirement]()
    let autonomyLevel = "受主線約束"
    let mergeBackRule = "只交證據"
}

struct WorkOSIdentityBinding: Equatable, Sendable {
    let identity: IdentityKind = .lead
}

enum WorkOSShowLoopNodeKind: String, Equatable, Sendable {
    case goal, contract, mainline, domain, receipt, gate
}

struct WorkOSShowLoopNode: Identifiable, Equatable, Sendable {
    let id: String
    let kind: WorkOSShowLoopNodeKind
    let title: String
    let ownerIdentity: IdentityKind?
    let status: GoalRunStatus
    let receiptIDs: [String]
    let canPromoteRunState: Bool
    let plainPurpose: String
}

struct WorkOSShowLoopEdge: Identifiable, Equatable, Sendable {
    let id: String
    let from: String
    let to: String
    let label: String
}

struct WorkOSShowLoopsProjection: Equatable, Sendable {
    let readOnly: Bool
    let visualizerCanPromoteRunState: Bool
    let nodes: [WorkOSShowLoopNode]
    let edges: [WorkOSShowLoopEdge]

    static let fixture = WorkOSShowLoopsProjection(
        readOnly: true,
        visualizerCanPromoteRunState: false,
        nodes: [
            .init(id: "goal", kind: .goal, title: "Goal", ownerIdentity: .lead, status: .planned, receiptIDs: [], canPromoteRunState: false, plainPurpose: "純資料預覽")
        ],
        edges: []
    )
}

enum TatwoOSModeRouteStatus: String, Equatable, Sendable {
    case dashboardReady = "dashboard_ready"
}

struct TatwoOSModeRouteV1: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let route: String
    let mode: WorkModeID
    let speedDefault: String
    let status: TatwoOSModeRouteStatus
    let plainPurpose: String
}

enum TatwoOSModeRouteCatalog {
    static let all: [TatwoOSModeRouteV1] = [.s, .m, .l, .xl].map { mode in
        .init(
            id: "tatwo-os-\(mode.rawValue.lowercased())",
            displayName: "TATWO ULTRAWORK \(mode.rawValue)",
            route: "tatwo-os-\(mode.rawValue.lowercased())",
            mode: mode,
            speedDefault: "fast",
            status: .dashboardReady,
            plainPurpose: "純資料 OS 模式路由"
        )
    }
}

struct TatwoWorkOSDashboardGoalSummary: Equatable, Sendable {
    let status: GoalRunStatus
    let mode: WorkModeID
    let scenario: String
}

struct TatwoWorkOSDashboardContractSummary: Equatable, Sendable {
    let configStage: WorkOSConfigStage
    let failClosed: Bool
    let visualizerCanPromoteRunState: Bool
    let contractID: String
}

enum TatwoWorkOSDashboardLaneKind: Equatable, Sendable { case mainline, domain }
struct TatwoWorkOSDashboardLane: Equatable, Sendable { let kind: TatwoWorkOSDashboardLaneKind }
struct TatwoWorkOSDashboardReceiptRail: Equatable, Sendable { let submittedCount: Int; let requiredCount: Int }
struct TatwoWorkOSDashboardNextAction: Equatable, Sendable { let plainText: String; let commandHint: String }

struct TatwoWorkOSDashboardSnapshot: Equatable, Sendable {
    let goal: TatwoWorkOSDashboardGoalSummary
    let contract: TatwoWorkOSDashboardContractSummary
    let lanes: [TatwoWorkOSDashboardLane]
    let receiptRail: TatwoWorkOSDashboardReceiptRail
    let nextAction: TatwoWorkOSDashboardNextAction
}

struct TatwoSandboxRun: Identifiable, Equatable, Sendable {
    var id: String { "\(sandboxType)/\(runID)" }
    let runID: String
    let sandboxType: String
    let modifiedAt: Date
    let hasSummary: Bool
    let hasSeal: Bool
    let hasScoreReport: Bool
}

struct TatwoSandboxRunReader: Sendable {
    let rootURL: URL
    init(rootURL: URL) { self.rootURL = rootURL }
    func listRuns() -> [TatwoSandboxRun] { [] }
}

enum TatwoGBrainLayer: String, Equatable, Sendable { case curated, truth }
enum TatwoGBrainReaderStatus: String, Equatable, Sendable {
    case available
    case rootMissing = "root_missing"
    case permissionDenied = "permission_denied"
    case ioError = "io_error"
    case unavailable
}

struct TatwoGBrainEntry: Identifiable, Equatable, Sendable {
    let id: String
    let fileName: String
    let title: String
    let layer: TatwoGBrainLayer
    let size: Int64
}

struct TatwoGBrainListResult: Equatable, Sendable {
    let entries: [TatwoGBrainEntry]
    let status: TatwoGBrainReaderStatus
}

struct TatwoGBrainReader: Sendable {
    let rootURL: URL
    init(rootURL: URL) { self.rootURL = rootURL }
    func list() -> TatwoGBrainListResult { .init(entries: [], status: .rootMissing) }
}

enum TatwoRuntimeLayout {
    static func stateRoot(environment: [String: String], applicationSupportBase: URL) -> URL { applicationSupportBase.appendingPathComponent("Tatwo2Fixture", isDirectory: true) }
    static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("Tatwo2-Fixture", isDirectory: true)
    }
}

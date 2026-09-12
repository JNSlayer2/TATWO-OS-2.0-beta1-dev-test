// 來源：1.0 plugin registry、skills directory 與 Skillet 型別；只保留 run A 畫面欄位與記憶體假資料
import Foundation
import AppKit

enum PluginsFixture {
    static let entries: [PluginRegistryEntry] = [
        // 逐字取自 1.0 Packages/TatwoUltraworkCore/.../TatwoCatalog.swift 的 Defaults registry（4 skill + 3 mcp），讓金樣一致
        .init(id: "chatgpt-pro-mcp", name: "ChatGPT Pro MCP", kind: .mcp, purpose: "完整 TATWO 必備的 Pro 研究 / 審稿 lane；負責長 memo、來源整理、反方觀點與 handoff，不是同步 dropdown 模型。", path: "mcp:chatgpt-pro-mcp", trigger: "安裝時必須連接；實際調用於需要 source-backed research、Pro reviewer 或重大方案反方審稿時", safetyLevel: .high, installState: .installed, smokeCommand: "rg -q '^\\[mcp_servers\\.chatgpt_pro_mcp\\]' \"$HOME/.codex/config.toml\"", publicInstallHint: "required: install/connect chatgpt-pro-mcp guarded async ProResearchJobV1 lane"),
        .init(id: "tatwo-ultrawork", name: "Tatwo Ultrawork", kind: .skill, purpose: "TATWO Work OS 的主技能；輸入 $tatwo-ultrawork 啟動 Plan + Loops + Goal。", path: "skill:tatwo-ultrawork", trigger: "在 Chat 輸入 $tatwo-ultrawork，或任務需要 Work OS contract、Loops、收據與驗收時。", safetyLevel: .high, installState: .installed, smokeCommand: "test -f \"$HOME/Library/Application Support/Tatwo Ultrawork/capabilities/skills/tatwo-ultrawork/SKILL.md\"", publicInstallHint: "Tatwo-owned canonical skill"),
        .init(id: "tatwo-ultrawork-mcp", name: "Tatwo Ultrawork MCP", kind: .mcp, purpose: "TATWO Work OS 的 mode、scenario、sandbox、receipt、goal 與 doctor MCP 控制面。", path: "mcp:tatwo_ultrawork", trigger: "需要查詢或執行 TATWO Work OS contract、workflow、sandbox、receipt 與驗證工具時。", safetyLevel: .high, installState: .installed, smokeCommand: "rg -q '^\\[mcp_servers\\.tatwo_ultrawork\\]' \"$HOME/.codex/config.toml\"", publicInstallHint: "installed MCP: tatwo_ultrawork"),
        .init(id: "gbrain", name: "GBrain", kind: .mcp, purpose: "多代理研究、整理與次級分析入口；輸出仍是 advisory evidence，需由 host receipts 驗證。", path: "mcp:gbrain_allai", trigger: "需要 GBrain 多代理查詢、整理或交叉分析，且 contract 允許外部 runner 時。", safetyLevel: .high, installState: .installed, smokeCommand: "rg -q '^\\[mcp_servers\\.gbrain_allai\\]' \"$HOME/.codex/config.toml\"", publicInstallHint: "installed MCP: gbrain_allai"),
        .init(id: "open-ultrawork", name: "open-ultrawork", kind: .skill, purpose: "S/M/L/XL、分工、預算、停止條件、驗證。", path: "skill:open-ultrawork", trigger: "多模型協作、重型模式、對抗驗證", safetyLevel: .high, installState: .installed, smokeCommand: "test -f \"$HOME/.codex/skills/open-ultrawork/SKILL.md\"", publicInstallHint: "skill: open-ultrawork"),
        .init(id: "tatworoom-web-app", name: "tatworoom-web-app", kind: .skill, purpose: "TATWO web/super app 任務專用上下文。", path: "skill:tatworoom-web-app", trigger: "任務屬於 TATWO 刺青室 / super app / travel / game module", safetyLevel: .medium, installState: .installed, smokeCommand: "test -f \"$HOME/.codex/skills/tatworoom-web-app/SKILL.md\"", publicInstallHint: "skill: tatworoom-web-app"),
        .init(id: "web-check", name: "web-check / 前端健檢", kind: .skill, purpose: "前端 UI/code/debug/ops 的本地驗收收據來源；掃 React/Next/Vite 風險、規則 parity、JSON report，不當模型也不當最終美感裁判。", path: "skill:web-check", trigger: "UI/UJ、frontend code、public URL read-only scan、前端 debug why file:line；L/XL UI 任務 promotion 前固定檢查。", safetyLevel: .high, installState: .installed, smokeCommand: "test -f \"$HOME/.codex/skills/web-check/SKILL.md\"", publicInstallHint: "recommended: install local web-check; run ./bin/tatwo-frontend-doctor rules list --json"),
    ]
}

struct TatwoPluginRegistryPartition { let skills: [PluginRegistryEntry]; let mcp: [PluginRegistryEntry]; static func make(_ entries: [PluginRegistryEntry]) -> Self { .init(skills: entries.filter { $0.kind == .skill }, mcp: entries.filter { $0.kind == .mcp }) } }
struct TatwoSkillsScanOutcome { var value: [TatwoSkillsDirectoryEntryV1]? = []; var access: ExternalVolumeAccess? = nil; var failure: ExternalVolumeFailure? = nil }
struct TatwoSkillsDirectoryEntryV1: Identifiable, Equatable, Sendable {
    let id: String; let name: String; let summary: String?; let path: String; let hasManifest: Bool; let isRegistered: Bool; let snapshotSourcePath: String?
    init(id: String, name: String, summary: String?, path: String, hasManifest: Bool, isRegistered: Bool, snapshotSourcePath: String? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.path = path
        self.hasManifest = hasManifest
        self.isRegistered = isRegistered
        self.snapshotSourcePath = snapshotSourcePath
    }
    var usesLinkedSnapshotSource: Bool { snapshotSourcePath != nil }
    var snapshotSourceURL: URL { URL(fileURLWithPath: snapshotSourcePath ?? path) }
}

enum TatwoCapabilityRepositoryHealthV1: String, Equatable, Sendable { case healthy, canary, diverged, failed, unavailable }
enum TatwoCapabilityRevisionChannelV1: String, Equatable, Sendable { case staging, canary, stable }
enum TatwoDeviceActivationStateV1: String, Equatable, Sendable { case active, inactive }
struct TatwoCapabilityRevisionV1: Identifiable, Equatable, Sendable { let id: String; let channel: TatwoCapabilityRevisionChannelV1; let createdAt = Date(); let sourceDigest = ""; let fileCount = 0 }
struct TatwoDeviceHeadV1: Identifiable, Equatable, Sendable { var id: String { deviceID }; let deviceID: String; let revisionID: String; let activationState: TatwoDeviceActivationStateV1; let requestID: String; let authorityEpoch: Int; let ledgerSequence: Int?; let lastVerifiedAt: Date? }
enum TatwoSkilletReceiptKindV1: String, Equatable, Sendable { case snapshot, deviceHead, merge }
struct TatwoSkilletRepositoryReceiptV1: Identifiable, Equatable, Sendable { let id: String; let kind: TatwoSkilletReceiptKindV1; let revisionID: String; let deviceID: String?; let requestID: String?; let authorityEpoch: Int?; let ledgerSequence: Int?; let message: String; let recordedAt: Date }
struct TatwoCapabilityRepositoryV1: Identifiable, Equatable, Sendable {
    let id: String; let displayName: String; let summary: String; let canonicalRevision: String?; let stableRevision: String?; let canaryRevision: String?; let revisions: [TatwoCapabilityRevisionV1]; let deviceHeads: [TatwoDeviceHeadV1]; let health: TatwoCapabilityRepositoryHealthV1 = .unavailable
    func verifiedDeviceHeads(receipts: [TatwoSkilletRepositoryReceiptV1]) -> [TatwoDeviceHeadV1] { [] }
    func matchingDeviceReceipt(for head: TatwoDeviceHeadV1, receipts: [TatwoSkilletRepositoryReceiptV1]) -> TatwoSkilletRepositoryReceiptV1? { nil }
}
enum TatwoMergeProposalStatusV1: String, Equatable, Sendable { case pending, approved, rejected }
struct TatwoMergeProposalV1: Identifiable, Equatable, Sendable { let id: String; let repositoryID: String; let status: TatwoMergeProposalStatusV1; let sourceDeviceID: String; let baseRevisionID: String?; let canonicalRevisionID: String; let proposedRevisionID: String; let mergedRevisionID: String? }
enum TatwoMergeConflictKindV1: String, Equatable, Sendable { case content }
struct TatwoSkilletMergeConflictArtifactV1: Identifiable, Equatable, Sendable { let id: String; let relativePath: String; let kind: TatwoMergeConflictKindV1 }
struct TatwoSkillSnapshotFileV1: Equatable, Sendable { let relativePath: String; let byteCount: Int }
struct TatwoSkillSnapshotManifestV1: Equatable, Sendable { let files: [TatwoSkillSnapshotFileV1] }
enum TatwoMergeDecisionStatusV1: String, Equatable, Sendable { case approved, rejected }
struct TatwoMergeDecisionReceiptV1: Identifiable, Equatable, Sendable { let id: String; let status: TatwoMergeDecisionStatusV1 }
struct TatwoSkilletRuntimeReadbackV1: Equatable, Sendable {}

extension TatwoSkilletRepositoryStore {
    func listRepositoryIDs() throws -> [String] { [] }
    func loadRepository(id: String) throws -> TatwoCapabilityRepositoryV1? { nil }
    func loadReceipts(repositoryID: String) throws -> [TatwoSkilletRepositoryReceiptV1] { [] }
    func loadMergeProposals(repositoryID: String) throws -> [TatwoMergeProposalV1] { [] }
    func loadMergeConflicts(repositoryID: String, proposalID: String) throws -> [TatwoSkilletMergeConflictArtifactV1] { [] }
    func loadSnapshotManifest(repositoryID: String, revisionID: String) throws -> TatwoSkillSnapshotManifestV1? { nil }
    func createSnapshotRepository(id: String, displayName: String, summary: String, sourceDirectory: URL) throws -> TatwoCapabilityRepositoryV1 { .init(id: id, displayName: displayName, summary: summary, canonicalRevision: nil, stableRevision: nil, canaryRevision: nil, revisions: [], deviceHeads: []) }
    func snapshotCanonicalSkillDirectory(repositoryID: String, displayName: String, summary: String, sourceDirectory: URL, channel: TatwoCapabilityRevisionChannelV1) throws -> TatwoCapabilityRevisionV1 { .init(id: "fixture", channel: channel) }
    func approveMergeProposal(repositoryID: String, proposalID: String, resolvedRevisionID: String?, decidedBy: String, decidedAt: Date) throws -> TatwoMergeDecisionReceiptV1 { .init(id: proposalID, status: .approved) }
    func rejectMergeProposal(repositoryID: String, proposalID: String, decidedBy: String, decidedAt: Date) throws -> TatwoMergeDecisionReceiptV1 { .init(id: proposalID, status: .rejected) }
}
enum TatwoSkilletRepositoryStoreError: Error { case corruptedMergeProposal(String) }
enum TatwoSkilletBundleTransport {
    static func preservingRuntimeRepository<T>(runtimeRoot: URL, repositoryID: String, operation: () throws -> T) throws -> (result: T, before: TatwoSkilletRuntimeReadbackV1, after: TatwoSkilletRuntimeReadbackV1) { (try operation(), .init(), .init()) }
}
enum TatwoModalPanelGate { static func run(_ operation: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse { operation() } }

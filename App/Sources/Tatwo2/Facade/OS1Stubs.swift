// 來源：OS 1.0 多個畫面相依型別；只保留 run A 畫面欄位，所有值均為記憶體假資料
import SwiftUI
import AppKit
import TatwoCEFBridge

// MARK: - 未輪到的房間
// ChatRunMode：已由照搬檔提供，stub 移除


// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageAppKitBridges.swift:120；只保留 Bot 畫面用到的欄位
// ChatComposerTextView：已由照搬檔提供，stub 移除


// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/CLITerminalWindows.swift:150；只保留 Bot 畫面用到的視窗燈同步
// WindowTrafficLightVisibilitySync 已由 CLI/CLITerminalWindows.swift 照搬版提供（合併時移除 stub）

// ChatPage / DevicesPage / PluginsPage / WorkflowPage stub 已由照搬檔提供（合併時移除）
struct GoalRevisionConfirmationSheet: View {
    init(challenge: TatwoGoalRevisionChallenge, isConfirming: Bool, errorMessage: String?, onCancel: @escaping () -> Void, onConfirm: @escaping (String) -> Void) {}
    var body: some View { Text("Goal revision") }
}

// MARK: - 共用資料

enum InstallState: String, Sendable { case installed, missing, skipped, unknown }
enum TatwoDispatchStatus: String, Sendable { case queued, running, completed, verified, failed }
enum ScenarioID: String, Sendable { case daily, design, coding, trading, modeling }
enum WorkModeID: String, Sendable, Codable, Hashable { case s = "S", m = "M", l = "L", xl = "XL", xxl = "XXL" }
struct WorkMode: Identifiable, Sendable {
    var id: WorkModeID { mode }
    let mode: WorkModeID; let englishName: String; let chineseName: String; let plainDescription: String; let maxHelpers: Int; let maxRounds: Int; let requiresHumanApproval: Bool; let requiresIndependentVerification: Bool
}
struct ScenarioProfile: Identifiable, Sendable {
    let id: String; let displayName: String; let baseScenario: ScenarioID?; let plainPurpose: String; let defaultMode: WorkModeID
}
struct ModelTraitScores: Sendable { let reasoning: Int; let coding: Int; let designSense: Int; let researchFreshness: Int; let bulkThroughput: Int; let reviewStrictness: Int; let costRisk: Int; let stabilityRisk: Int; let executionAuthority: Int }
struct ModelCalibrationNote: Identifiable, Sendable { let id: String; let observedPattern: String; let routingImplication: String; let confidence: String }
struct ModelTrait: Identifiable, Sendable {
    let id: String; let displayName: String; let plainSummary: String; let plainFailureMode: String; let verificationRule: String; let strengths: [String]; let weaknesses: [String]; let bestRoles: [String]; let avoidRoles: [String]; let calibrationNotes: [ModelCalibrationNote]; let scores: ModelTraitScores
}
struct TraitEvaluationDimension: Identifiable, Sendable { let id: String; let title: String; let plainMeaning: String; let usedForIdentities: [IdentityKind] }

enum TatwoEnvironmentComponentKind: Sendable { case app, cli, skill, legacyArchive, localRuntime, mcp, plugin, receipt, safetyGate }
struct TatwoHealthState: Sendable { let plainLabel: String }
struct TatwoEnvironmentComponent: Identifiable, Sendable {
    let id: String; let kind: TatwoEnvironmentComponentKind; let title: String; let status: InstallState; let healthState: TatwoHealthState?; let plainStatus: String; let nextAction: String
}
enum IdentityKind: Sendable {
    case lead, supervisor, consultant, sub, news, verifier
    var chineseName: String {
        switch self {
        case .lead: "主導"
        case .supervisor: "副審"
        case .consultant: "顧問"
        case .sub: "Sub"
        case .news: "消息"
        case .verifier: "驗證"
        }
    }
}
struct EngineID: Identifiable, Hashable, Sendable { let rawValue: String; var id: String { rawValue } }
struct IdentityCandidate: Identifiable, Sendable { let id: String; let engineID: EngineID; let modelID: String; let bestWhen: String; let canMutateHost: Bool }
struct IdentitySlot: Identifiable, Sendable { let id: String; let kind: IdentityKind; let label: String; let budgetWeight: Double; let required: Bool; let responsibilities: [String]; let candidates: [IdentityCandidate] }

// RegistryKind：已由照搬檔提供，stub 移除

enum PluginSafetyLevel: String, Sendable { case low, medium, high }
// PluginRegistryEntry：已由照搬檔提供，stub 移除

// TatwoClaudeMCPSyncReceiptV1：已由照搬檔提供，stub 移除

// RegistryKind：已由照搬檔提供，stub 移除

// PluginRegistryEntry：已由照搬檔提供，stub 移除

// TatwoClaudeMCPSyncReceiptV1：已由照搬檔提供，stub 移除

struct TatwoEnvironmentSnapshot: Sendable { var components: [TatwoEnvironmentComponent] = [] }
struct TatwoCatalog: Sendable {
    var usageProviders: [UsageProviderStatus] = UsageFixture.providers
    var workModes: [WorkMode] = ModesFixture.workModes
    var plugins: [PluginRegistryEntry] = []
    static let defaults = TatwoCatalog()
    func replacingPlugins(_ entries: [PluginRegistryEntry]) -> TatwoCatalog { var copy = self; copy.plugins = entries; return copy }
}
struct TatwoAppSnapshot: Sendable {
    var selectedMode: WorkModeID = .m
    var selectedScenario: ScenarioID = .coding
    var catalog: TatwoCatalog = .defaults
    var environment: TatwoEnvironmentSnapshot = .init()
    var plainSummary: String { "規劃預覽：Goal / Loops / identity rows 只是 contract 投影，尚未派發，無 runtime receipt；planned agents、預估輪次與 receipt requirements 不算實際進度。App-first 只呈現工作流、模型分工、插件/技能、主機安全 gate 與環境缺口；研討完成後才同步 skill 與 MCP。" }
    var workflowPlan: TatwoWorkflowPlanFixture { .init() }
    var hostMutationAllowed: Bool { false }
}
struct TatwoWorkflowPlanFixture: Sendable { let sandboxRequired = false }
struct TatwoUserPreferences: Sendable { let selectedMode: WorkModeID; let selectedScenario: ScenarioID }
struct TatwoProbe: Sendable {
    static func current(environment: [String: String]) -> TatwoProbe { .init() }
    func withGatewayLiveStatus(_ status: TatwoGatewayLiveStatus?) -> TatwoProbe { self }
}
enum TatwoAppSnapshotFactory {
    static func makeCurrent(environment: [String: String] = ProcessInfo.processInfo.environment, gatewayLiveStatus: TatwoGatewayLiveStatus? = nil) -> TatwoAppSnapshot { .init() }
    static func make(preferences: TatwoUserPreferences, probe: TatwoProbe, catalog: TatwoCatalog) -> TatwoAppSnapshot { .init(selectedMode: preferences.selectedMode, selectedScenario: preferences.selectedScenario, catalog: catalog) }
}
enum UsageFixture {
    static let providers = [
        UsageProviderStatus(id: "codex-gpt", displayName: "Codex / GPT", status: .unknown, cachePolicy: "先顯示本地 cache", liveRefreshPolicy: "使用者按重新整理才打 live source", quotaLabel: "依 Codex App / CLI 回報"),
        UsageProviderStatus(id: "claude", displayName: "Claude", status: .unknown, cachePolicy: "只顯示上次健康收據", liveRefreshPolicy: "透過 gateway/CLI smoke 更新", quotaLabel: "不讀 token，只顯示可用/需登入"),
        UsageProviderStatus(id: "grok", displayName: "Grok", status: .unknown, cachePolicy: "保留最後一次查消息能力狀態", liveRefreshPolicy: "OAuth/CLI 可用時再刷新", quotaLabel: "消息查找與反例 lane"),
        UsageProviderStatus(id: "minimax", displayName: "MiniMax", status: .unknown, cachePolicy: "保留低成本探索 lane 狀態", liveRefreshPolicy: "只在確認低風險額度池後啟用", quotaLabel: "大量草稿/掃描 lane"),
        UsageProviderStatus(id: "local-api", displayName: "API / 本地模型", status: .unknown, cachePolicy: "只保存 endpoint 類型，不保存 key", liveRefreshPolicy: "本地或使用者批准才跑", quotaLabel: "local / allowlisted only")
    ]
}
struct UsageProviderStatus: Identifiable, Equatable, Sendable { let id: String; let displayName: String; let status: InstallState; let cachePolicy: String; let liveRefreshPolicy: String; let quotaLabel: String }

// MARK: - 純假資料服務
// TatwoWorkOSContractV1：已由照搬檔提供，stub 移除

enum TatwoDynamicActivation: Equatable, Sendable { case enabled, disabled }
struct TatwoLoopGovernorBinding: Equatable, Sendable { var id = "fixture-binding"; var enabled = true; var dynamicActivation = TatwoDynamicActivation.enabled; var phase = TatwoScenarioPhase.loops; var boundModelIDs: [String] = []; var reasoningEffort: TatwoCodexReasoningEffort? }
struct TatwoLoopGovernorDecision: Equatable, Sendable { var activatedBindings: [TatwoLoopGovernorBinding] = [] }
// TatwoWorkOSContractV1：已由照搬檔提供，stub 移除

enum ModesIssuedIntegrityState: Equatable, Sendable { case noCurrentSession, noPointer, validated, invalid(String), revisionRequired(String), blocked(String) }
struct TatwoGoalRunStore { var directoryURL = URL(fileURLWithPath: NSTemporaryDirectory()); static func `default`(environment: [String:String] = [:]) -> TatwoGoalRunStore { .init() } }
struct TatwoSessionAttachment { let contract = TatwoWorkOSContractV1() }
struct TatwoSessionStore { init(directoryURL: URL) {}; func inspectCurrent(scenarioBook: TatwoScenarioConfigBookV1, goalStore: TatwoGoalRunStore) throws -> TatwoSessionAttachment? { nil } }
struct TatwoScenarioConfigBookV1 {}
enum TatwoScenarioConfigStore { static func loadDefaultStaging(environment: [String:String]) -> TatwoScenarioConfigBookV1 { .init() } }
enum WorkOSFactory { static func preview(mode: WorkModeID, scenarioProfileID: String, objective: String, scenarioBook: TatwoScenarioConfigBookV1) throws -> TatwoWorkOSContractV1 { .init() } }
struct TatwoDeviceIdentity { let deviceID: String }
struct TatwoDeviceSnapshotProducer {
    init(syncCore: TatwoDeviceSyncCore, deviceDisplayName: String, deviceKind: TatwoDomainDeviceKindV1, stateRootURL: URL, domainID: String, receiptHashSink: @escaping (String) -> Void, now: @escaping @Sendable () -> Date) {}
    static func loadOrCreateLocalDeviceID(stateRootURL: URL) -> TatwoDeviceIdentity { .init(deviceID: "fixture-device") }
}

enum TatwoAppMCPRuntimeState { case notStarted, ready(TatwoAppMCPEndpoint), failed(String) }
struct TatwoAppMCPEndpoint: Equatable { let url = URL(string: "http://127.0.0.1")!; static func loopback(port: UInt16) -> TatwoAppMCPEndpoint? { .init() } }
struct TatwoChatStorage { let chatRuntimeRootURL = URL(fileURLWithPath: NSTemporaryDirectory()) }
struct TatwoChatProcessComposition {
    let storage = TatwoChatStorage()
    @MainActor func makeChatPageModel(appMCPRuntimeProvider: @escaping @MainActor () -> TatwoAppMCPRuntimeState) -> ChatPageModel { let m = ChatPageModel(); RunTask.attachIfRequested(m); return m }
}
enum TatwoChatProcessCompositionResolver { static func resolve() -> TatwoChatProcessComposition { .init() } }
struct TatwoLocalMCPHTTPServer { init(toolCaller: @escaping (String, [String: Any]) async throws -> Any) {}; func start(port: UInt16) throws -> UInt16 { port }; func stop() {} }
enum TatwoAppManagementMCP { static func call(_ name: String, _ args: [String: Any]) async throws -> Any { [:] } }
@MainActor
final class TatwoSparkleUpdateCoordinator {
    private let checker = GitHubReleaseUpdateChecker.shared
    private var started = false
    var runtimeStatus: TatwoSignedUpdateRuntimeStatus { started ? .active(.githubRelease) : .notStarted }
    func start() { InAppUpdater.shared.consumeResultOnLaunch(); checker.start(); started = true }
    func stop() { checker.stop(); started = false }
    func checkForUpdatesFromUser() { checker.checkForUpdatesFromUser() }
}
final class TatwoAppPressureRuntimeV1 {}
final class TatwoMacPressureSensorProviderV1 {}

@MainActor
final class TatwoAppAuthorityBootstrapModel: ObservableObject {
    struct Proposal { let bootstrapDispositionPreview = "fixture"; let contractID = "fixture"; let canonicalGoalStoreRootPath = "fixture"; let objectivePreview = "fixture"; let authoritySubjectDigest = "fixture"; let preflightDigest = "fixture" }
    @Published var pendingProposal: Proposal?
    @Published var isConfirming = false
    func dismissPending() { pendingProposal = nil }
    func confirmPending() async {}
}
struct TatwoGoalRevisionChallenge: Identifiable { let id = UUID() }
struct TatwoGoalRevisionSelection {}
struct TatwoGoalRevisionReadback { let contract = TatwoWorkOSContractV1() }
struct TatwoGoalPointer { let scenario = "daily"; let mode = WorkModeID.s }
struct TatwoGoalPointerSnapshot { let pointer = TatwoGoalPointer() }
struct TatwoGoalRevisionConfirmationResult { let readback = TatwoGoalRevisionReadback(); let pointerSnapshot = TatwoGoalPointerSnapshot() }
enum TatwoGoalRevisionCoordinator {
    static func prepare(selection: TatwoGoalRevisionSelection, environment: [String:String]) throws -> TatwoGoalRevisionChallenge { .init() }
    static func confirm(challenge: TatwoGoalRevisionChallenge, newObjective: String, environment: [String:String]) throws -> TatwoGoalRevisionConfirmationResult { .init() }
}
enum TatwoPrivacyRedactor { static func redacted(_ value: String) -> String { value } }
final class TatwoRetainedChatLifecycle {
    init(initiallySelectedChat: Bool) {}
    func registerStopHandler(_ handler: @escaping @MainActor () -> Void) {}
    func pageSelectionChanged(isChatSelected: Bool) {}
    func closeContainer() {}
}
struct TatwoGatewayLiveStatus: Sendable, Equatable {}
enum TatwoGatewayLiveProbe { static func fetchSynchronously(environment: [String:String]) -> TatwoGatewayLiveStatus { .init() }; static func fetch(environment: [String:String]) async -> TatwoGatewayLiveStatus { .init() } }

struct TatwoSkilletRepositoryStore {
    let rootURL: URL
    init(rootURL: URL) { self.rootURL = rootURL }
}
struct DeviceSyncOutboxStore: Sendable {
    init() {}
    static func defaultApplicationSupportRootPublic() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
    func enqueue(target: String, action: String) throws -> DeviceSyncIntent { .init(target: target, action: action, requestedAt: Date()) }
    func pendingIntents() throws -> [DeviceSyncIntent] { [] }
    func receipts() throws -> [DeviceSyncReceipt] { [] }
    func receiptLoadResult() throws -> DeviceSyncReceiptLoadResult { .init(receipts: []) }
    func enrolledDevices() throws -> [EnrolledDevice] { DevicesExportSyncFixture.secondaryDevices() }
    func secondaryDevices() throws -> [EnrolledDevice] { DevicesExportSyncFixture.secondaryDevices() }
}
struct TatwoPluginRegistryStore {
    static func loadDefaultEntries() -> [PluginRegistryEntry] { PluginsSource.load() }
    static func defaultStore() -> TatwoPluginRegistryStore { .init() }
    func register(kind: RegistryKind, path: String, plainPurpose: String, name: String?) throws -> PluginRegistryEntry { .init(id: path, name: name ?? path, kind: kind, purpose: plainPurpose, path: path, trigger: "", safetyLevel: .medium, installState: .unknown, smokeCommand: nil, publicInstallHint: "") }
    func remove(id: String) throws -> PluginRegistryEntry {
        if PluginsSource.mcpEngine(from: id) != nil { return try PluginsSource.removeRegistration(id: id) }
        return PluginsFixture.entries.first ?? .init(id: id, name: id, kind: .plugin, purpose: "", path: nil, trigger: "", safetyLevel: .low, installState: .unknown, smokeCommand: nil, publicInstallHint: "")
    }
    func syncClaudeMCPConfig() throws -> TatwoClaudeMCPSyncReceiptV1 { .init() }
}
enum TatwoIdentityCatalog { static let scenarioProfiles = ModesFixture.scenarioProfiles }
enum TeamRoutingCatalog {
    static let modelTraits = ModesFixture.modelTraits
    static let traitEvaluationDimensions: [TraitEvaluationDimension] = []
    static let leadStrategies: [TatwoLeadStrategy] = []
    static let collaborationEvidence: [TatwoCollabEvidenceV1] = []
}

// MARK: - Settings 假資料
enum TatwoIssueSourceTypeV1: String, Codable, Equatable, Sendable { case plan, chat }
enum TatwoIssueEntryStatusV1: String, Codable, Equatable, Sendable { case queued, activated, archived }
// 來源：Packages/TatwoUltraworkCore/.../TatwoIssueListStore.swift:18；2.0 真資料版（存進討論串 JSON）
struct TatwoIssueListEntryV1: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var body: String
    var imageAssetPaths: [String] = []
    let sourceType: TatwoIssueSourceTypeV1
    let sourceReference: String
    let threadReference: String?
    var projectReference: String?
    var status: TatwoIssueEntryStatusV1
    let createdAt: Date
    init(id: String = UUID().uuidString, title: String, body: String, sourceType: TatwoIssueSourceTypeV1 = .chat, sourceReference: String = "", threadReference: String? = nil, projectReference: String? = nil, status: TatwoIssueEntryStatusV1 = .queued, createdAt: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.sourceType = sourceType; self.sourceReference = sourceReference
        self.threadReference = threadReference; self.projectReference = projectReference; self.status = status; self.createdAt = createdAt
    }
}
// TatwoBrowserManagementProviding / TatwoBrowserManagementProviderFactory /
// TatwoBrowserManagementView：已由 Browser 房間照搬檔提供，stub 移除
struct ChatNativeOpenAISubscriptionOnboardingView: View {
    var body: some View { Text("OpenAI") }
}
struct ChatNativeClaudeSubscriptionOnboardingView: View {
    var body: some View { Text("Claude") }
}
struct ChatNativeGrokSubscriptionOnboardingView: View {
    var body: some View { Text("Grok") }
}

// MARK: - Usage 假水電
enum TatwoRecentActivitySourceKind: Sendable { case dispatchRegistry, codexSessionJSONL }
enum TatwoRecentActivityModelConfidence: Sendable { case providerOnly, explicitTurnContext }
struct TatwoDispatchIdentity { let rawValue = "fixture" }
struct TatwoDispatchRecord { let id="fixture"; let modelID="fixture"; let bindingID="fixture"; let identity=TatwoDispatchIdentity(); let status=TatwoDispatchStatus.completed; let startedAt=Date(); let updatedAt=Date() }
struct TatwoDispatchRun { let records: [TatwoDispatchRecord] = [] }
struct TatwoDispatchRegistry { static func `default`() -> TatwoDispatchRegistry { .init() }; func allRuns(updatedSince: Date) -> [TatwoDispatchRun] { [] } }
struct TatwoActivityOutcome { let value: [TatwoRecentActivityRecord]? = []; let access: ExternalVolumeAccess? = nil; let failure: ExternalVolumeFailure? = nil; let lastGoodAt: Date? = nil }
enum TatwoCodexSessionActivitySource { static func loadRecentOutcome(since: Date, limit: Int, allowExternalVolumes: Bool) -> TatwoActivityOutcome { .init() } }
struct TatwoDispatchLedgerEntry { let id="fixture"; let model="fixture"; let label="fixture"; let note:String?=nil; let status=TatwoDispatchStatus.completed; let startedAt=Date.distantPast; let endedAt:Date?=nil }
struct TatwoDispatchLedgerReader { func readEntries() -> [TatwoDispatchLedgerEntry] { [] } }
struct TatwoRecentActivityRecord: Identifiable, Sendable {
    let id: String; let modelID: String; let modelProvider: String; let originator: String; let workdirSummary: String; let statusText: String; let startedAt: Date; let updatedAt: Date; let sourceKind: TatwoRecentActivitySourceKind; let modelConfidence: TatwoRecentActivityModelConfidence
}
enum ExternalVolumeAccess: Sendable { case notEnabled, enabled }
enum ExternalVolumeFailure: String, Sendable { case volumeAbsent, permissionDenied, ioError }
enum TatwoQuotaRefreshKind: Sendable { case manual, automatic }
enum ChatRateLimitFailure: String, Sendable { case unavailable }
struct ChatNativeSubscriptionAccountSnapshot: Sendable { let status: ChatNativeSubscriptionAccountStatus = .signedOut; let rateLimits: ChatRateLimits? = nil; let rateLimitFailure: ChatRateLimitFailure? = nil }
enum ChatNativeSubscriptionAccountStatus: Sendable { case unavailable, signedOut, requiresReauthentication, signedIn(String) }
struct ChatRateLimitWindow: Sendable { let utilization: Double = 0; let resetsAt: Date? = nil }
struct ChatRateLimits: Sendable { let remainingPercent:Int?=72; let primaryRemainingPercent:Int?=72; let secondaryRemainingPercent:Int?=61; let planType:String?="plus"; let primaryResetsAt:Int?=nil; let secondaryResetsAt:Int?=nil; let resetCreditsAvailable:Int?=nil; let resetCreditExpiryDates:[Int]=[] }
enum ChatNativeClaudeSubscriptionAccountStatus: Sendable { case unavailable, signedOut, signedIn(String) }
struct ClaudeOAuthUsageWindow: Sendable { let utilization: Double; let resetsAt: Date? }
struct ChatNativeSubscriptionHomeLocator { func resolve() -> URL { FileManager.default.homeDirectoryForCurrentUser } }
struct TatwoLocalUsageAggregate: Sendable { let requestCount = 0; let totalTokens: Int? = nil }
struct TatwoLocalUsageSnapshot: Sendable { let hasRecordedUsage = false; let fiveHour = TatwoLocalUsageAggregate(); let sevenDay = TatwoLocalUsageAggregate() }
actor TatwoLocalUsageMeter { static let shared = TatwoLocalUsageMeter(); func snapshot(provider: String) -> TatwoLocalUsageSnapshot { .init() } }
struct ChatNativeSubscriptionAccountService { func quotaSnapshot() async -> ChatNativeSubscriptionAccountSnapshot { .init() } }
struct ChatNativeClaudeSubscriptionAccountService { func status() async -> ChatNativeClaudeSubscriptionAccountStatus { .signedOut } }

actor TatwoQuotaSnapshotCache {
    static let shared = TatwoQuotaSnapshotCache()
    func load(providers: [UsageProviderStatus], refreshKind: TatwoQuotaRefreshKind = .automatic, allowExternalAccess: Bool = false) async -> LiveQuotaDeckSnapshot {
        await UsageSource.load(providers: providers)
    }
}

enum ChatNativeSubscriptionEnvironment { static func scrubCurrentProcessCredentials() {} }
// Both compiled and unavailable bridges provide the real AppKit host class.
// A UI stub here shadows CefAppProtocol and prevents Chromium from starting.
typealias TatwoCEFApplication = TatwoCEFBridge.TatwoCEFApplication
struct TatwoHostResourceProfile { let effectiveTier = 0 }
struct TatwoPreferenceStore { static func defaultStore() throws -> TatwoPreferenceStore { .init() }; func reconcileHostResourceProfileAtLaunch(physicalMemoryBytes: UInt64) throws -> TatwoHostResourceProfile { .init() } }
final class TatwoRuntimeGovernor { static let shared = TatwoRuntimeGovernor(); func configure(tier: Int) {} }
// HeaderQuotaSnapshotFixture：已由照搬檔提供，stub 移除

// WorkOSPlanLoopsGoalMetrics：已由照搬檔提供，stub 移除

// WorkOSPlanLoopsGoalCycleMap：已由照搬檔提供，stub 移除

struct TatwoLaunchCommand { let executable = "/usr/bin/true"; let arguments: [String] = [] }
enum TatwoChatCommandPlanner { static func launchctlSubmitStaleJobSweepLaunch(rootPath: String, uid: String, currentAppPID: String) -> TatwoLaunchCommand { .init() } }

enum TatwoSignedUpdateReason: String { case fixture }
enum TatwoSignedUpdateChannel: String { case fixture, githubRelease }
enum TatwoSignedUpdateRuntimeStatus { case notStarted, disabled(TatwoSignedUpdateReason), active(TatwoSignedUpdateChannel) }

enum TatwoPressureLifecycleReason { case appLaunch, appWillTerminate }
struct TatwoPressureProvider {}
extension TatwoMacPressureSensorProviderV1 { static func appProcessOwned() -> TatwoMacPressureSensorProviderV1 { .init() }; func provider() -> TatwoPressureProvider { .init() }; func resetSwapBaselineForLifecycle() async {} }
actor TatwoAppPressureSamplerV1 { let deviceID: String; init(deviceID: String, provider: TatwoPressureProvider) { self.deviceID = deviceID } }
struct TatwoAppPressureRuntimeLifecycleResetV1 { init(_ action: @escaping () async -> Void) {} }
extension TatwoAppPressureRuntimeV1 { convenience init(sampler: TatwoAppPressureSamplerV1, lifecycleReset: TatwoAppPressureRuntimeLifecycleResetV1) { self.init() }; func start(reason: TatwoPressureLifecycleReason, startTimers: Bool) async {}; func stop(reason: TatwoPressureLifecycleReason) async {} }
enum TatwoAppPressureRuntimeRegistry { static func install(_ runtime: TatwoAppPressureRuntimeV1) -> UInt64 { 1 }; static func clear(generation: UInt64?) {} }

enum TatwoInterruptKind { case appTerminate, escapeClose, windowClose, composerStop }
struct TatwoLoopsTerminationSnapshot {}
// TatwoLoopsActivitySnapshot：已由照搬檔提供，stub 移除

// TatwoLoopsActivityMonitor：已由照搬檔提供，stub 移除

struct TatwoInterruptDecision { let requiresConfirmation: Bool }
enum TatwoInterruptGate {
    /// Set by ChatPage: whether any chat/loops work is running right now.
    /// 2.0 has no real termination snapshot yet, so window close asks only when work is live.
    @MainActor static var activityProvider: () -> Bool = { false }
    /// One-shot: the updater sets this after the user already confirmed "重開" in Island,
    /// so the terminate that follows the hand-off does not ask a second time.
    @MainActor static var bypassNextTerminate = false
    @MainActor static func decision(kind: TatwoInterruptKind, snapshot: TatwoLoopsTerminationSnapshot) -> TatwoInterruptDecision {
        switch kind {
        case .appTerminate:
            if bypassNextTerminate { bypassNextTerminate = false; return .init(requiresConfirmation: false) }
            return .init(requiresConfirmation: true)
        case .composerStop: return .init(requiresConfirmation: true)
        case .windowClose, .escapeClose: return .init(requiresConfirmation: activityProvider())
        }
    }
}
@MainActor
enum TatwoInterruptConfirmationPresenter {
    static func confirm(kind: TatwoInterruptKind, snapshot: TatwoLoopsTerminationSnapshot, window: NSWindow?) -> Bool {
        confirm(kind: kind, window: window)
    }
    static func confirm(kind: TatwoInterruptKind, window: NSWindow?) -> Bool {
        guard TatwoInterruptGate.decision(kind: kind, snapshot: .init()).requiresConfirmation else { return true }
        let title: String
        let detail: String
        switch kind {
        case .appTerminate:
            title = "結束 TATWO OS？"
            detail = "執行中的工作會中斷"
        case .windowClose, .escapeClose:
            title = "關閉這個視窗？"
            detail = ""
        case .composerStop:
            title = "停止目前的回覆？"
            detail = ""
        }
        return IslandNotice.shared.confirmBlocking(title: title, detail: detail,
            confirmLabel: "確認", cancelLabel: "取消", timeout: 20, window: window)
    }
    static func confirm(kind: TatwoInterruptKind) -> Bool {
        confirm(kind: kind, window: nil)
    }
}

// MARK: - CLI 假水電
// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoNativeCLISession.swift:5-241；只保留畫面欄位
enum TatwoNativeCLIEngine: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case codex, claude, openclaw, grok, sandbox
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .openclaw: "OpenClaw"
        case .grok: "Grok"
        case .sandbox: "Sandbox"
        }
    }
}
// TatwoNativeCLISessionBook：已由照搬檔提供，stub 移除


// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/NativeTerminalCore.swift:3-49,823-865；只保留畫面欄位
// TatwoTerminalColor：已由照搬檔提供，stub 移除

// TatwoTerminalSpan：已由照搬檔提供，stub 移除

// TatwoTerminalLine：已由照搬檔提供，stub 移除

// TatwoNativeTerminalLaunch：已由照搬檔提供，stub 移除

// TatwoNativeTerminalStatus：已由照搬檔提供，stub 移除


// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TerminalInputEncoder.swift:3-78；只保留畫面欄位
enum TatwoTerminalSpecialKey: Sendable, Equatable, Hashable {
    case carriageReturn, backspace, tab, escape, upArrow, downArrow, leftArrow, rightArrow, home, end, deleteForward, pageUp, pageDown
}
enum TatwoTerminalInput {
    case text(String), control(Character), special(TatwoTerminalSpecialKey)
}
enum TatwoTerminalInputEncoder {
    static func bytes(for input: TatwoTerminalInput, optionAsMeta: Bool = false) -> [UInt8] {
        switch input {
        case .text(let text): return Array(text.utf8)
        case .control(let character):
            guard let scalar = character.uppercased().unicodeScalars.first else { return [] }
            return [UInt8(scalar.value & 0x1f)]
        case .special(let key):
            switch key {
            case .carriageReturn: return [13]
            case .backspace: return [127]
            case .tab: return [9]
            case .escape: return [27]
            case .upArrow: return Array("\u{1B}[A".utf8)
            case .downArrow: return Array("\u{1B}[B".utf8)
            case .leftArrow: return Array("\u{1B}[D".utf8)
            case .rightArrow: return Array("\u{1B}[C".utf8)
            case .home: return Array("\u{1B}[H".utf8)
            case .end: return Array("\u{1B}[F".utf8)
            case .deleteForward: return Array("\u{1B}[3~".utf8)
            case .pageUp: return Array("\u{1B}[5~".utf8)
            case .pageDown: return Array("\u{1B}[6~".utf8)
            }
        }
    }
}

// TatwoNativePTYTerminalSession：已由 Engine/PTYTerminalSession.swift 真版提供
// TatwoNativeTerminalSession：已由照搬檔提供，stub 移除


struct TatwoCLITab: Identifiable {
    let id: UUID
    let title: String
}
extension ChatPageModel {
}

extension TatwoLoopsActivityMonitor {
    static func terminationSnapshot() -> TatwoLoopsTerminationSnapshot { .init() }
}

struct PLGFlowCard: View {
    init(run: TatwoPLGRun, onAuthorize: @escaping () -> Void, onEvaluateMainline: @escaping (Bool) -> Void, onRollback: @escaping () -> Void, dispatchRecords: [TatwoDispatchRecord], blockerMessage: String?, onConfirmPlan: @escaping () -> Void, onEndGoal: @escaping () -> Void, onTogglePause: @escaping () -> Void, paused: Bool, canAdvanceCycle: Bool, onAdvanceCycle: @escaping () -> Void) {}
    var body: some View { EmptyView() }
    static func confirm(kind: TatwoInterruptKind, window: NSWindow? = nil) -> Bool { true }
}

struct TatwoSessionPointerSnapshot { let pointer = TatwoGoalPointer() }
extension TatwoSessionStore { func snapshotCurrent() throws -> TatwoSessionPointerSnapshot? { nil } }
struct TatwoGoalRevisionPredecessor { let attachment: TatwoSessionAttachment?; let requiresBindingRevision: Bool }
enum TatwoGoalRevisionPredecessorResolver { static func resolve(pointer: TatwoGoalPointer, scenarioBook: TatwoScenarioConfigBookV1, goalStore: TatwoGoalRunStore, sessionStore: TatwoSessionStore) throws -> TatwoGoalRevisionPredecessor { .init(attachment: nil, requiresBindingRevision: false) } }

// 以下三個型別取合併前主線（HEAD）的完整版，供 PluginsPage / Modes 使用
enum RegistryKind: String, Sendable { case plugin, skill, mcp, app, localRuntime, builtin }
struct PluginRegistryEntry: Identifiable, Equatable, Sendable {
    let id: String; let name: String; let kind: RegistryKind; let purpose: String; let path: String?; let trigger: String; let safetyLevel: PluginSafetyLevel; let installState: InstallState; let smokeCommand: String?; let publicInstallHint: String
    var liveness: PluginLivenessResult = .init(state: .unknown)
    var toolCount: Int? = nil
    var lastCalledAt: Date? = nil
    var availableTo: [String] = []
}
// TatwoWorkOSContractV1：已由照搬檔提供，stub 移除

public struct TatwoNativeCLISessionBook {
    public enum Engine: String, CaseIterable, Codable, Sendable { case codex, claude, grok, generic }
    struct Session: Identifiable { var id = UUID(); var engine = Engine.codex; var title = "CLI"; var workdir: String?; var createdAt = Date(); var updatedAt = Date(); var isRunning = false }
    var sessions: [Session] = []; var activeSessionID: UUID?; var activeSession: Session? { sessions.first { $0.id == activeSessionID } }
}
struct TatwoClaudeMCPSyncReceiptV1: Sendable { let backupPath: String? = nil; let serverNames: [String] = []; let wrotePath = "fixture" }

// TatwoWorkOSContractV1 取 chat 房間版（ChatPageModels 依賴其 loopGovernorDecision 形狀）
// TatwoWorkOSContractV1：已由照搬檔提供，stub 移除


// TatwoWorkOSContractV1：合併版（HEAD 的 Ultra/WorkOS 欄位 ＋ chat 的 loopGovernorDecision；scenario 依 1.0 為 ScenarioID）
struct TatwoWorkOSContractV1: Equatable, Sendable {
    let scenario: String = "coding"  // 1.0 WorkOS.swift:155 scenario 是 String
    let mode: WorkModeID = .m
    let contractID = "fixture-contract"
    let goalRun = GoalRun()
    let mainlineLoop = MainlineLoop()
    let domainLoops = [DomainLoop()]
    let identityBindings = [WorkOSIdentityBinding()]
    let sandboxPolicy = WorkOSSandboxPolicy()
    let receiptRequirements = [WorkOSReceiptRequirement]()
    let showLoopsProjection = WorkOSShowLoopsProjection.fixture
    let configStage: WorkOSConfigStage = .staging
    let failClosed = true
    let visualizerCanPromoteRunState = false
    var loopGovernorDecision = TatwoLoopGovernorDecision()
}

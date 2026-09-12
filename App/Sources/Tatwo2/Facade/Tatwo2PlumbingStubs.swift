// 來源：App/Sources/Tatwo2/Model/ChatThread.swift、ChatSession.swift；純 UI target 暫用同名假水電，原檔不修改
import Foundation
import SwiftUI
import AppKit

struct ChatThread {
    var id = UUID().uuidString
    var sessionId: String?
    var title = "selftest"
    var cwd = NSTemporaryDirectory()
    var messages: [ChatMessage] = []
}

final class ThreadStore {
    func delete(_ id: String) {}
}

@MainActor
final class ChatSession {
    struct PermissionRequest { let tool: String }
    var thread: ChatThread
    var pendingPermission: PermissionRequest?
    var isBusy = false
    var status = "UI fixture"
    var lastError: String?
    init(thread: ChatThread, store: ThreadStore) { self.thread = thread }
    func send(_ text: String) {}
    func answerPermission(allow: Bool) {}
    func shutdown() {}
}

public enum TatwoNativeChatEventKind: String, Codable, Sendable, Equatable, Hashable {
    case session, continuation, message, toolUse, thinking, raw, exit, failure
}

// TatwoNativeCLIEngine：已由照搬檔提供，stub 移除

struct TatwoNativeCLISession: Identifiable, Sendable, Equatable, Hashable {
    var id = UUID(); var name = "CLI"; var engine = TatwoNativeCLIEngine.codex; var cwd = NSTemporaryDirectory(); var createdISO = ""; var isArchived = false
}
struct TatwoGitHubRepoBinding: Sendable, Equatable, Hashable {
    enum Visibility: String, Sendable, Equatable, Hashable, CaseIterable { case pub = "public", priv = "private", unknown }
    var url = ""; var accountLabel = ""; var visibility = Visibility.unknown; var hasUpdate = false; var lastCheckedISO: String?
}
enum TatwoCodexAppStateBridge {
    enum MirrorStatus: String, Sendable, Equatable {
        case loaded, notEnabled, unavailable
    }
}
enum TatwoNativeDiscussionStatus: String, Sendable, Equatable, Hashable { case active, compressed }
struct TatwoNativeDiscussion: Identifiable, Sendable, Equatable, Hashable {
    var id = UUID(); var title = "討論"; var status = TatwoNativeDiscussionStatus.active; var inheritedSnapshot = ""; var compressedSummary: String?
    var isArchived: Bool { status == .compressed }
}
/// 子討論串（sub）的活性：綠＝5 分鐘內有輸出、黃＝5 分鐘沒動、紅＝15 分鐘零輸出（卡死）、灰＝已完成
enum ThreadLiveness: String, Codable, Sendable, Hashable {
    case active, idle, stalled, done, failed
    var label: String {
        switch self { case .active: "有輸出"; case .idle: "5 分鐘沒動"; case .stalled: "15 分鐘零輸出"; case .done: "已完成"; case .failed: "已失敗" }
    }
    static func from(status: String?, lastOutputAt: Date?, now: Date = Date()) -> ThreadLiveness? {
        guard let status else { return nil }
        if status == "done" { return .done }
        if status == "failed" { return .failed }   // 2026-09-06：failed 不能因為剛有輸出被映成 active（r8 DISPATCH 呈現落差）；不看時間門檻
        guard let lastOutputAt else { return .idle }
        let gap = now.timeIntervalSince(lastOutputAt)
        if gap > 15 * 60 { return .stalled }
        if gap > 5 * 60 { return .idle }
        return .active
    }
}

struct TatwoNativeChatThread: Identifiable, Sendable, Equatable, Hashable {
    var id = UUID(); var title = "新聊天"; var isPinned = false; var lastPreview = ""; var workOSContractID: String? = nil; var workOSGoalID: String? = nil; var loopsConfig: TatwoNativeThreadLoopsConfig? = nil; var discussions: [TatwoNativeDiscussion] = []
    // 2.0 B1：子討論串（sub）＝有父串的討論串；活性給側欄的燈用
    var parentThreadID: UUID? = nil; var liveness: ThreadLiveness? = nil; var lastOutputAt: Date? = nil; var engineLabel: String? = nil
}
struct TatwoNativeChatProject: Identifiable, Sendable, Equatable, Hashable {
    var id = UUID(); var name = "專案"; var workdir = NSTemporaryDirectory(); var isExpanded = true; var threads: [TatwoNativeChatThread] = []; var githubRepos: [TatwoGitHubRepoBinding] = []; var sessions: [TatwoNativeCLISession] = []
}
struct TatwoNativeChatStoreDocument: Sendable, Equatable, Hashable {
    var projects: [TatwoNativeChatProject] = []
    var generalProjectID: UUID? = nil
}

typealias ChatEngine = TatwoNativeChatEngine
extension TatwoNativeChatEngine {
    var symbol: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "sparkles"
        }
    }
}

struct TatwoNativeThreadLoopsConfig: Codable, Sendable, Equatable, Hashable {
    var scenarioID = "coding"; var mode = WorkModeID.m; var identitySummary = "fixture"; var tokenBudget = "fixture"; var primaryModelID: String?; var secondaryModelID: String?; var summaryLine: String { "scenario=\(scenarioID) · mode=\(mode.rawValue) · budget=\(tokenBudget)" }
}
extension TatwoChatCommandPlanner {
    static func isLikelyImagePath(_ path: String) -> Bool { ["png","jpg","jpeg","gif","webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
}

enum ChatPlanWorkOSLocalActionPhase: String, Equatable, Sendable { case idle, pending, dispatching, succeeded, failed }
struct ChatPlanWorkOSLocalActionPresentation: Equatable, Sendable {
    var phase = ChatPlanWorkOSLocalActionPhase.idle; var message = ""; var goalID: String?; var contractID: String?; var dispatchID: String?; var runnerEvidenceID: String?; var stateRoot: String?; var isRetryable = false
    static let idle = Self(); var isInFlight: Bool { phase == .pending || phase == .dispatching }
}
extension ChatMessageRole { var rawValue: String { String(describing: self) } }
extension ChatMessage { var toolName: String? { nil } }

struct TatwoPluginRegistryBookV1 { var entries: [PluginRegistryEntry] = []; var sortedEntries: [PluginRegistryEntry] { entries } }
enum TatwoNativeChatSessionKind: String, Hashable { case thread, discussion }
struct TatwoNativeChatSessionReference: Identifiable, Hashable { let kind: TatwoNativeChatSessionKind; let id: UUID; var stableKey: String { "\(kind.rawValue):\(id)" } }
// TatwoNativeCLISessionBook：已由照搬檔提供，stub 移除

// CLISessionTreeTerminalSession：已由照搬檔提供，stub 移除

// CLISessionTreeProject：已由照搬檔提供，stub 移除

// CLISessionTreeOpenSession：已由照搬檔提供，stub 移除

// CLILoopTreeStatus：已由照搬檔提供，stub 移除

// CLILoopTreeRow：已由照搬檔提供，stub 移除

// CLILoopTimelineEvent：已由照搬檔提供，stub 移除

// CLILoopDetailSnapshot：已由照搬檔提供，stub 移除

// TatwoNativePTYTerminalSession：已由照搬檔提供，stub 移除

// NativeTerminalPTYPalette：已由照搬檔提供，stub 移除

// NativeTerminalPTYView：已由照搬檔提供，stub 移除

// CLITerminalWindowManager：已由照搬檔提供，stub 移除

// CLISolidCard：已由照搬檔提供，stub 移除

// CLISessionTree：已由照搬檔提供，stub 移除

// CLILoopsTreeLoader：已由照搬檔提供，stub 移除

enum TatwoChatCommandMode: String, CaseIterable, Identifiable { case chat, cli, plan, code; var id: String { rawValue } }
enum ChatRemoteJobPublicState: String, Codable { case delivered, started, running, completed, verified }
enum ChatRemoteJobTerminalOutcome: String, Codable { case failed, cancelled }
enum ChatRemoteJobRuntimeTruth: String, Codable { case observedThisProcess, unknownAfterRelaunch, terminalReceipt, waitingForAuthority }
enum ChatRemoteJobInlinePresentation { struct Payload: Codable, Equatable { let state: ChatRemoteJobPublicState?; let terminalOutcome: ChatRemoteJobTerminalOutcome?; let runtimeTruth: ChatRemoteJobRuntimeTruth?; let blocker: String?; let details: [String:String] }; static func payload(from status: String?) -> Payload? { nil } }
enum TatwoComputerHostTurnRoute: String, Sendable, Equatable { case none, mcp, embeddedIntent }
enum TatwoScenarioPhase: String, Sendable, Equatable { case plan, loops, goal }
enum ChatTranscriptAttestationOutcomeV1: String, Sendable, Equatable { case unknown, requested, forwardedAwaitingProvider, verified, fallbackObserved, unsupportedEffort, providerEvidenceMissing, providerMismatch }
struct TatwoHostApprovalLeaseV1: Equatable, Sendable { let id = UUID() }
struct TatwoImageAsset { let relativePath: String; let url: URL; let displayName: String }
final class TatwoImageAssetStore { init() {}; func relativePath(for url: URL) -> String? { nil }; func resolve(relativePath: String) -> URL? { nil }; func ingest(fileURL: URL, displayName: String? = nil) throws -> TatwoImageAsset { .init(relativePath: fileURL.lastPathComponent, url: fileURL, displayName: displayName ?? fileURL.lastPathComponent) }; static func isDecodableImageFile(atPath path: String) -> Bool { true }; static func isImageCandidatePath(_ path: String) -> Bool { ["png","jpg","jpeg","gif","webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) } }
struct TatwoNativeChatStoredMessage: Identifiable, Equatable, Hashable { var id = UUID().uuidString; var role = "assistant"; var text = ""; var status: String?; var modelID: String?; var eventKind = TatwoNativeChatEventKind.message; var runtimeAdapterID: String?; var runtimeFallbackReason: TatwoChatRuntimeFallbackReason?; var createdAt = Date() }

// EmbeddedBrowserNavigationDecision / EmbeddedBrowserNavigationPolicy /
// EmbeddedBrowserView：已由 Browser 房間照搬檔提供，stub 移除
struct ProjectFileBrowserView: View {
    init(rootPath: String) {}
    var body: some View { EmptyView() }
}
// BotPageRootView：已由照搬檔提供，stub 移除

struct TabDesignPhilosophyPopoverView: View { var body: some View { EmptyView() } }
// TatwoModalPanelGate：已由照搬檔提供，stub 移除


// TatwoLoopsSession：已由照搬檔提供，stub 移除

// TatwoLoopsLiveRow：已由照搬檔提供，stub 移除

// TatwoPLGRun：已由照搬檔提供，stub 移除

// TatwoStoredGoalRun：已由照搬檔提供，stub 移除

struct TatwoDispatchRuntimeProjection { var canonicalRecords: [TatwoDispatchRecord] = [] }
// LoopsSessionRail：已由照搬檔提供，stub 移除

struct DiffReviewView: View {
    init(diffProvider: @escaping () -> TatwoParsedDiff, goalLabel: String? = nil, reviewerLabel: String? = nil) {}
    var body: some View { EmptyView() }
}
struct GitHubRepoBindingEditorView: View {
    init(bindings: [TatwoGitHubRepoBinding], onSave: @escaping ([TatwoGitHubRepoBinding]) -> Void, onCancel: @escaping () -> Void) {}
    var body: some View { EmptyView() }
}

struct TatwoChatMCPApprovalRequest { let toolName: String; init?(diagnosticText: String) { return nil } }
enum TatwoModelIdentityRegistry { static func canonicalModelID(for raw: String) -> String? { nil } }
// WindowTrafficLightVisibilitySync：已由照搬檔提供，stub 移除

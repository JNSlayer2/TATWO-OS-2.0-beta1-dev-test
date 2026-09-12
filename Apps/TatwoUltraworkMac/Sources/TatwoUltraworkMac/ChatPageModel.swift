import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

enum TatwoNativeDevelopmentDispatchSettlementError: Error {
    case terminalReceiptMissing
}

typealias ChatEngine = TatwoNativeChatEngine

enum ChatLifecyclePromptContextPolicy {
    static func shouldAppend(
        interactionMode: TatwoChatInteractionMode
    ) -> Bool {
        interactionMode == .standard
    }
}

enum ChatPlanClarificationContinuationPolicy {
    static let maximumAcceptedRounds = 8

    static func isClarificationEnvelope(_ text: String?) -> Bool {
        guard let normalized = normalized(text) else { return false }
        let lower = normalized.lowercased()
        return lower.contains("[tatwo plan clarification answers]")
            || lower.contains(
                "[tatwo plan terminal clarification answers]")
    }

    static func isTerminalEnvelope(_ text: String?) -> Bool {
        guard let normalized = normalized(text) else { return false }
        return normalized.lowercased().contains(
            "[tatwo plan terminal clarification answers]")
    }

    static func shouldFinalize(
        answers: [PlanQuestionAnswerV1],
        acceptedRound: Int
    ) -> Bool {
        if acceptedRound >= maximumAcceptedRounds {
            return true
        }
        let answerText = answers.flatMap { answer -> [String] in
            answer.selectedOptions.flatMap { option in
                [option.label, option.detail]
            } + [answer.otherText ?? ""]
        }
        return answerText.contains(where: isTerminalSelection)
    }

    static func isTerminalSelection(_ text: String) -> Bool {
        let lower = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lower.isEmpty else { return false }
        let exclusions = [
            "不要輸出", "不輸出", "先不要輸出", "暫停", "先暫停",
            "再補", "補充", "繼續問", "not yet", "do not output",
            "don't output", "pause", "more clarification",
        ]
        guard !exclusions.contains(where: lower.contains) else {
            return false
        }
        let terminalAnchors = [
            "輸出最終", "輸出定稿", "立即定稿", "直接定稿", "完成定稿",
            "最終 prompt", "最終提示詞", "最終計畫", "定稿並輸出",
            "finalize now", "finalise now", "output final",
            "final prompt", "complete the plan",
        ]
        return terminalAnchors.contains(where: lower.contains)
    }

    static func continuationPrompt(
        answerBlocks: [String],
        originalObjective: String?,
        forceFinal: Bool
    ) -> String {
        let objective = normalized(originalObjective)
            ?? "Preserve the original user Plan objective from this thread."
        let answers = answerBlocks.joined(separator: "\n\n")
        if forceFinal {
            return """
                [TATWO Plan terminal clarification answers]
                \(answers)

                Original Plan objective (preserve this objective; do not replace it with this internal envelope):
                \(objective)

                Finalize the Plan now. Do not ask another question and do not emit TATWO_PLAN_QUESTION. Output the complete Markdown Plan with all implementation sections, validation, risks, and rollback guidance. This remains planning-only: do not create a Goal, Work OS contract, dispatch, or runner.
                """
        }
        return """
            [TATWO Plan clarification answers]
            \(answers)

            Original Plan objective (preserve this objective; do not replace it with this internal envelope):
            \(objective)

            Continue the same Plan discussion without repeating answered questions. Ask at most one additional question only if a truly necessary decision remains; otherwise output the complete final Markdown Plan. This remains planning-only: do not create a Goal, Work OS contract, dispatch, or runner.
            """
    }

    static func objectiveCandidate(
        userTurn: String,
        pendingObjective: String?,
        existingObjective: String?,
        boundUserTurn: String?
    ) -> String? {
        guard isClarificationEnvelope(userTurn) else {
            return ChatPlanRevisionIntent.objectiveCandidate(
                userTurn: userTurn,
                pendingObjective: pendingObjective,
                existingObjective: existingObjective)
        }
        return firstExternalObjective(
            pendingObjective,
            existingObjective,
            boundUserTurn)
    }

    static func recoveredObjective(
        bindingObjective: String?,
        pendingObjective: String?,
        existingObjective: String?,
        boundUserTurn: String?
    ) -> String? {
        if let bindingObjective = externalObjective(bindingObjective) {
            return bindingObjective
        }
        return firstExternalObjective(
            pendingObjective,
            existingObjective,
            boundUserTurn)
    }

    private static func firstExternalObjective(
        _ candidates: String?...
    ) -> String? {
        candidates.lazy.compactMap(externalObjective).first
    }

    private static func externalObjective(_ text: String?) -> String? {
        guard let normalized = normalized(text),
              !isClarificationEnvelope(normalized)
        else {
            return nil
        }
        return normalized
    }

    private static func normalized(_ text: String?) -> String? {
        guard let normalized = text?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }
}

struct ChatPlanClarificationSourceSnapshot {
    let threadID: UUID
    let message: ChatMessage
    let originalIndex: Int
    let previousMessageID: ChatMessage.ID?
    let nextMessageID: ChatMessage.ID?
}

struct ChatQueuedPlanClarificationSettlement {
    let source: ChatPlanClarificationSourceSnapshot
    let acceptedRound: Int
}

private func chatLooksLikeInternalDelegationPrompt(_ rawText: String) -> Bool {
    TatwoChatTranscriptPresentation.isInternalDelegationEnvelope(rawText)
}

extension ChatEngine {
    var symbol: String {
        switch self {
        case .codex: "sparkles"
        case .claude: "brain.head.profile"
        }
    }

    var defaultModelChoices: [String] {
        switch self {
        case .codex: ["default", "gpt-5.5", "gpt-5.5-codex-low", "o4-mini"]
        case .claude: ["default", "fable", "sonnet", "opus"]
        }
    }
}

extension WorkModeID {
    var chatCollaborationLevel: ChatCollaborationLevel {
        switch self {
        case .s: .s
        case .m: .m
        case .l: .l
        case .xl: .xl
        case .xxl: .xxl
        }
    }
}

struct ChatInitialStoreLoadPayload: Sendable {
    let localDocument: TatwoNativeChatStoreDocument
    let composerDraftsBySessionKey: [String: String]
    let composerDraftUpdatedAtBySessionKey: [String: Date]
    let composerDraftAcknowledgedMessageIDBySessionKey: [String: String]
    let composerDraftPersistenceWarning: String?
    let unifiedLedgerRead: TatwoUnifiedSessionLedgerReadV1
    let codexMirrorDocument: TatwoNativeChatStoreDocument?
    let codexMirrorStatus: TatwoCodexAppStateBridge.MirrorStatus
    let scenarioConfigBook: TatwoScenarioConfigBookV1
    let pluginRegistryBook: TatwoPluginRegistryBookV1
    let currentSessionPointerPresent: Bool
    let verifiedCurrentSession: ChatVerifiedCurrentSessionBundle?
    let workOSBindingMutationRecoveryBlocked: Bool
    let workOSBindingMutationRecoveryIntent: WorkOSBindingMutationIntentV1?
    let workOSBindingMutationRecoveryMessage: String?
}

enum ChatColdStartHydrationState: Sendable, Equatable {
    case notScheduled
    case scheduled
    case retryScheduled
    case running
    case loadingStore
    case completed
    case failed(reason: String)
    case timedOut
}

enum ChatColdStartJournalLoad: Sendable {
    case loaded(ChatTranscriptJournalV1)
    case failed(String)
}

enum ChatColdStartCancellationLoad: Sendable {
    case loaded([ChatDurableCancellationRecord])
    case failed
}

struct ChatColdStartHydrationPayload: Sendable {
    let journalLoad: ChatColdStartJournalLoad
    let unifiedLedgerMigrationFailure: String?
    let cancellationLoad: ChatColdStartCancellationLoad
    let runnerAuthority: ChatRunnerAuthoritySnapshot
}

enum ChatInitialStoreLoadOutcome: Sendable {
    case loaded(ChatInitialStoreLoadPayload)
    case failed(String)
}

struct ChatVerifiedCurrentSessionBundle: Sendable {
    let pointer: TatwoSessionPointer
    let contract: TatwoWorkOSContractV1
    let goalRecord: TatwoStoredGoalRun
}

struct WorkOSBindingMutationIntentV1: Codable, Sendable, Equatable {
    let schema: String
    let id: UUID
    let threadID: UUID
    let projectID: UUID?
    let oldContractID: String
    let oldGoalID: String
    let desiredLoopsConfig: TatwoNativeThreadLoopsConfig?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        threadID: UUID,
        projectID: UUID?,
        oldContractID: String,
        oldGoalID: String,
        desiredLoopsConfig: TatwoNativeThreadLoopsConfig?,
        createdAt: Date = Date()
    ) {
        self.schema = "WorkOSBindingMutationIntentV1"
        self.id = id
        self.threadID = threadID
        self.projectID = projectID
        self.oldContractID = oldContractID
        self.oldGoalID = oldGoalID
        self.desiredLoopsConfig = desiredLoopsConfig
        self.createdAt = Date(
            timeIntervalSince1970:
                createdAt.timeIntervalSince1970.rounded(.down))
    }
}

struct WorkOSBindingMutationIntentStore: Sendable {
    let fileURL: URL

    func load() throws -> WorkOSBindingMutationIntentV1? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let intent = try decoder.decode(
            WorkOSBindingMutationIntentV1.self,
            from: Data(contentsOf: fileURL))
        guard intent.schema == "WorkOSBindingMutationIntentV1" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return intent
    }

    func create(_ intent: WorkOSBindingMutationIntentV1) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(intent)
        try TatwoCreateOnlyFile.write(
            data,
            to: fileURL,
            onDuplicate: {
                guard try load() == intent else {
                    throw CocoaError(.fileWriteFileExists)
                }
            })
    }

    func remove(_ intent: WorkOSBindingMutationIntentV1) throws {
        guard let current = try load() else { return }
        guard current == intent else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

struct ChatWorkOSBindingMutationRecovery: Sendable {
    let document: TatwoNativeChatStoreDocument
    let blocked: Bool
    let message: String?
}

struct ChatGatewayContinuationTurnState: Sendable, Equatable {
    let runID: String
    let request: TatwoGatewayContinuationRequestV1
    var receipt: TatwoGatewayContinuationReceiptV1?
}

struct ChatGatewayFallbackTurnInputs: Sendable, Equatable {
    let commandBaseTurn: String
    let visibleTurn: String
    let attachmentPaths: [String]
    let previewTurn: String
    let dispatchSnapshot: ChatTurnDispatchSnapshot
    let assistantTurnID: String
}

struct ChatParkedTurnRuntime {
    var sessionReference: TatwoNativeChatSessionReference
    var isRunning: Bool
    var activeAssistantID: ChatMessage.ID?
    var activeTurnLifecycle: TatwoChatTurnLifecycle?
    var activeTurnDispatchSnapshot: ChatTurnDispatchSnapshot?
    var activeTurnExecutionProvenance: ChatTurnExecutionProvenance?
    var streamLedger: StreamTranscriptLedger
    var userStopRequested: Bool
    var cancellationBlockedReason: String?
    var liveWorkActivities: [ChatLiveWorkActivity]
    var chatActivityFeed: ChatActivityFeedV1
    var chatActivityFeedReducer: ChatActivityFeedReducer
    var activePlanTurnBinding: ChatPlanTurnBinding?
    var pendingSingleModelGoalDispatch: TatwoDispatchRecord?
    var activeSingleModelGoalDispatch:
        (
            runID: String,
            contractID: String,
            dispatchID: String,
            runnerInstanceID: UUID,
            observedToolUse: Bool
        )?
    var pendingNativeDevelopmentDispatch: TatwoDispatchRecord?
    var activeNativeDevelopmentDispatch:
        (
            runID: String,
            contractID: String,
            dispatchID: String,
            modelID: String
        )?
    var activeGatewayContinuationTurn: ChatGatewayContinuationTurnState?
    var pendingComputerAutoContinuation: String?

    var hasForegroundTurnRuntimeState: Bool {
        isRunning
            || activeTurnLifecycle != nil
            || pendingSingleModelGoalDispatch != nil
            || activeSingleModelGoalDispatch != nil
            || pendingNativeDevelopmentDispatch != nil
            || activeNativeDevelopmentDispatch != nil
    }
}

struct ChatRuntimeTextProjection: Sendable, Equatable {
    let text: String
    let collapsedDiagnostic: Bool
    let isBlocker: Bool

    init(
        text: String,
        collapsedDiagnostic: Bool,
        isBlocker: Bool = false
    ) {
        self.text = text
        self.collapsedDiagnostic = collapsedDiagnostic
        self.isBlocker = isBlocker
    }
}

/// Converts known CLI/provider noise into one stable main-bubble line.
/// Raw events remain available through the existing activity diagnostics.
enum ChatRuntimeTextHumanizer {
    static func projectedOutput(_ text: String) -> ChatRuntimeTextProjection {
        let stripped = strippingTerminalControls(text)
        if let gatewaySummary =
            ChatGatewayDegradedNoticePolicy.userFacingSummary(stripped)
        {
            return ChatRuntimeTextProjection(
                text: gatewaySummary,
                collapsedDiagnostic: true,
                isBlocker: true)
        }
        let lower = stripped.lowercased()
        let blockerClass = authorityBlockerClass(lower)
        let authoritySource = blockerClass.flatMap {
            authorityBlockerSource(lower, blockerClass: $0)
        }
        if isGrokQuotaFailure(lower) || blockerClass == "quota" {
            let summary =
                isGrokQuotaFailure(lower)
                ? "Grok 4.6 額度用盡，本回合未執行。"
                : "模型額度不足，本回合未執行。"
            return ChatRuntimeTextProjection(
                text: preservingAuthorityBlocker(
                    summary,
                    blockerClass: blockerClass,
                    authoritySource: authoritySource),
                collapsedDiagnostic: true,
                isBlocker: true)
        }
        if isDeferredToolUnavailable(lower) || blockerClass == "tool_unavailable" {
            return ChatRuntimeTextProjection(
                text: preservingAuthorityBlocker(
                    "目前沒有可用的相符工具，本回合未執行工具操作。",
                    blockerClass: blockerClass,
                    authoritySource: authoritySource),
                collapsedDiagnostic: true,
                isBlocker: true)
        }
        if let blockerClass {
            let message = switch blockerClass {
            case "session_limit":
                "模型 Session 或上下文已達限制，本回合未執行。"
            case "auth":
                "模型登入或授權已失效，本回合未執行。"
            case "permission_denied":
                "目前權限不足，本回合未執行。"
            case "route_scope_unclear":
                "目前路由權限範圍不明，本回合未執行。"
            case "contract_missing":
                "缺少可驗證的工作契約，本回合未執行。"
            default:
                "本回合受阻，未完成執行。"
            }
            return ChatRuntimeTextProjection(
                text: preservingAuthorityBlocker(
                    message,
                    blockerClass: blockerClass,
                    authoritySource: authoritySource),
                collapsedDiagnostic: true,
                isBlocker: true)
        }
        return ChatRuntimeTextProjection(
            text: stripped,
            collapsedDiagnostic: false)
    }

    static func rawFallback(_ text: String) -> String {
        let projected = projectedOutput(text)
        if projected.collapsedDiagnostic {
            return projected.text
        }
        var seen = Set<String>()
        let kept = projected.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> String? in
                guard !line.isEmpty else { return nil }
                let lower = line.lowercased()
                if line.hasPrefix("{\"type\"")
                    || line.hasPrefix("{\"event\"")
                    || lower.hasPrefix("debug:")
                    || lower.hasPrefix("trace:")
                    || lower.hasPrefix("warning:")
                    || lower.hasPrefix("error: enoent")
                    || lower.contains("codex app-server")
                    || lower.contains("launchctl submit")
                    || lower.contains("hidden tatwo")
                {
                    return nil
                }
                let withoutURL = line.replacingOccurrences(
                    of: #"https?://[^\s\]\)\"']+"#,
                    with: "",
                    options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !withoutURL.isEmpty else { return nil }
                let key = withoutURL.lowercased()
                guard seen.insert(key).inserted else { return nil }
                return withoutURL
            }
        return String(
            kept.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(4_000))
    }

    static func failureSummary(_ text: String) -> String {
        let projected = projectedOutput(text)
        if projected.collapsedDiagnostic {
            return projected.text
        }
        let fallback = rawFallback(text)
        return fallback.isEmpty
            ? "模型路線中斷，本回合未執行。"
            : fallback
    }

    private static func isGrokQuotaFailure(_ lower: String) -> Bool {
        (lower.contains("grok") || lower.contains("x.ai"))
            && (
                lower.contains("usage balance exhausted")
                    || lower.contains("balance exhausted")
                    || lower.contains("http 402")
                    || lower.contains("status 402")
            )
    }

    private static func isDeferredToolUnavailable(_ lower: String) -> Bool {
        lower.contains("no matching deferred tools found")
            || (
                lower.contains("toolsearch")
                    && lower.contains("no matching")
            )
    }

    private static func authorityBlockerClass(_ lower: String) -> String? {
        var fenced = false
        for rawLine in lower.split(
            separator: "\n",
            omittingEmptySubsequences: false)
        {
            let line = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenced.toggle()
                continue
            }
            if fenced || line.hasPrefix(">") {
                continue
            }
            let marker: String
            if line.hasPrefix("blocker_class=") {
                marker = "blocker_class="
            } else if line.hasPrefix("blocker_class:") {
                marker = "blocker_class:"
            } else {
                continue
            }
            let value = line.dropFirst(marker.count).prefix {
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
            }
            if !value.isEmpty {
                return String(value)
            }
        }
        return nil
    }

    private static func authorityBlockerSource(
        _ lower: String,
        blockerClass: String
    ) -> String? {
        var fenced = false
        for rawLine in lower.split(
            separator: "\n",
            omittingEmptySubsequences: false)
        {
            let line = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenced.toggle()
                continue
            }
            guard !fenced,
                  !line.hasPrefix(">"),
                  line.hasPrefix("blocker_class=")
                    || line.hasPrefix("blocker_class:")
            else {
                continue
            }
            guard line.contains(blockerClass),
                  let range = line.range(
                    of: #"authority_source\s*[:=]\s*([a-z0-9_-]+)"#,
                    options: .regularExpression)
            else {
                return nil
            }
            let match = String(line[range])
            return match.split(whereSeparator: {
                $0 == "=" || $0 == ":" || $0.isWhitespace
            }).last.map(String.init)
        }
        return nil
    }

    private static func preservingAuthorityBlocker(
        _ summary: String,
        blockerClass: String?,
        authoritySource: String?
    ) -> String {
        guard let blockerClass else { return summary }
        return """
            \(summary)
            blocker_class=\(blockerClass) authority_source=\(authoritySource ?? "none")
            """
    }

    private static func strippingTerminalControls(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression)
            .replacingOccurrences(
                of: #"\u{001B}\][^\u{0007}]*(?:\u{0007}|\u{001B}\\)"#,
                with: "",
                options: .regularExpression)
    }
}

enum ChatAssistantTerminalStatusPolicy {
    static func resolvedStatus(
        exitStatus: Int32,
        wasUserInitiatedStop: Bool,
        currentStatus: String?
    ) -> String? {
        if wasUserInitiatedStop {
            return "stopped"
        }
        if exitStatus != 0 {
            return "failed \(exitStatus)"
        }
        if isBlocked(currentStatus) {
            return "blocked"
        }
        return nil
    }

    static func liveWorkStatus(
        exitStatus: Int32,
        wasUserInitiatedStop: Bool,
        assistantStatus: String?
    ) -> String {
        let resolved = resolvedStatus(
            exitStatus: exitStatus,
            wasUserInitiatedStop: wasUserInitiatedStop,
            currentStatus: assistantStatus)
        if resolved == "blocked" {
            return "blocked|本輪受阻"
        }
        if resolved == "stopped" {
            return "stopped|已停止"
        }
        if let resolved, resolved.hasPrefix("failed") {
            return "failed|exit \(exitStatus)"
        }
        return "completed|本輪完成"
    }

    static func allowsContinuationPromotion(
        exitStatus: Int32,
        wasUserInitiatedStop: Bool,
        assistantStatus: String?
    ) -> Bool {
        exitStatus == 0
            && !wasUserInitiatedStop
            && !isBlocked(assistantStatus)
    }

    static func resolvedEventKind(
        exitStatus: Int32,
        wasUserInitiatedStop: Bool,
        currentEventKind: TatwoNativeChatEventKind
    ) -> TatwoNativeChatEventKind {
        if wasUserInitiatedStop {
            return .message
        }
        if exitStatus != 0 {
            return .failure
        }
        return currentEventKind
    }

    private static func isBlocked(_ status: String?) -> Bool {
        let base = status?
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return base == "blocked" || base == "route-blocked"
    }
}

enum ChatActiveTurnRouteAttributionPolicy {
    static func modelID(
        dispatchSnapshot: ChatTurnDispatchSnapshot?,
        activeMessage: ChatMessage?
    ) -> String? {
        dispatchSnapshot?.routeID ?? activeMessage?.modelID
    }
}

/// Decides whether a terminal assistant row still owes the user something
/// visible, or is only an empty in-flight placeholder that must be dropped.
///
/// A Plan turn can end with a terminal `agent_message` whose entire body is a
/// `<TATWO_PLAN_QUESTION>` block. The stream parser strips that block, so the
/// row's visible text stays empty while the clarification card it carries is
/// the only output the turn produced. Judging such a row by text alone deletes
/// a successful completion: the transcript row is removed, the terminal
/// message is never journaled, and the plan-artifact completion hook is never
/// reached.
enum ChatAssistantTerminalVisibilityPolicy {
    static func hasNoUserVisibleReply(
        text: String,
        eventKind: TatwoNativeChatEventKind,
        planQuestions: [PlanQuestionV1]
    ) -> Bool {
        guard planQuestions.isEmpty else { return false }
        if eventKind == .thinking || eventKind == .toolUse { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "…" || trimmed == "..."
    }

    /// Questions must ride a `message`/`result` row: a thinking or tool row is
    /// journaled through a surface that carries no clarification payload.
    static func resolvedEventKind(
        currentEventKind: TatwoNativeChatEventKind,
        planQuestions: [PlanQuestionV1]
    ) -> TatwoNativeChatEventKind {
        guard !planQuestions.isEmpty,
              currentEventKind == .thinking || currentEventKind == .toolUse
        else { return currentEventKind }
        return .message
    }
}

enum ChatGatewayDegradedNoticePolicy {
    private static let prefix = "[gateway-notice] "
    /// Mirrors the gateway's leak-free `kind/class` taxonomy. The first token
    /// is the concrete failure kind and the optional second token is its class.
    /// Keeping this allowlisted prevents quoted or arbitrary assistant prose
    /// from masquerading as a route-blocked terminal.
    private static let degradedReasons: Set<String> = [
        "auth",
        "configuration",
        "model_attestation",
        "network",
        "operational",
        "output_cap",
        "parse",
        "partial_output",
        "policy",
        "quota",
        "spawn",
        "timeout",
        "transient",
        "unavailable",
        "upstream_5xx",
    ]

    static func shouldMarkRouteBlocked(
        exitStatus: Int32,
        wasUserInitiatedStop: Bool,
        assistantText: String
    ) -> Bool {
        exitStatus == 0
            && !wasUserInitiatedStop
            && isRouteBlockedNotice(assistantText)
    }

    static func isRouteBlockedNotice(_ assistantText: String) -> Bool {
        parsedReasons(assistantText) != nil
    }

    static func userFacingSummary(_ assistantText: String) -> String? {
        guard let reasons = parsedReasons(assistantText) else { return nil }
        if reasons.contains("auth") {
            return "模型登入或授權已失效，本回合未執行。"
        }
        if reasons.contains("quota") {
            return "模型額度不足，本回合未執行。"
        }
        if reasons.contains("unavailable") {
            return "模型路線目前無法使用，本回合未執行。"
        }
        return "模型路線執行失敗，本回合未完成。"
    }

    private static func parsedReasons(_ assistantText: String) -> Set<String>? {
        guard let firstNonEmptyLine = assistantText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            firstNonEmptyLine.hasPrefix(prefix)
        else {
            return nil
        }

        let noticeBody = firstNonEmptyLine.dropFirst(prefix.count)
        guard let degradedRange = noticeBody.range(of: " upstream degraded ("),
              degradedRange.lowerBound != noticeBody.startIndex
        else {
            return nil
        }

        let modelToken = noticeBody[..<degradedRange.lowerBound]
        guard modelToken.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return value == 45
                || value == 46
                || (48...57).contains(value)
                || (65...90).contains(value)
                || value == 95
                || (97...122).contains(value)
        }) else {
            return nil
        }

        let reasonAndDetail = noticeBody[degradedRange.upperBound...]
        guard let separatorRange = reasonAndDetail.range(of: "): "),
              separatorRange.lowerBound != reasonAndDetail.startIndex
        else {
            return nil
        }

        let reasonList = reasonAndDetail[..<separatorRange.lowerBound]
        let detail = reasonAndDetail[separatorRange.upperBound...]
        guard !String(detail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let reasons = reasonList.split(
            separator: "/",
            omittingEmptySubsequences: false)
        guard !reasons.isEmpty,
              reasons.allSatisfy({ degradedReasons.contains(String($0)) })
        else {
            return nil
        }
        return Set(reasons.map(String.init))
    }
}

struct ChatWorkOSStateLoadPayload: Sendable {
    let contract: TatwoWorkOSContractV1?
    let goalRecord: TatwoStoredGoalRun?
    let goalSnapshot: TatwoGoalRunSnapshotV1?
    let dispatchRecords: [TatwoDispatchRecord]
    let message: String
}

struct ChatWorkOSContext: Sendable {
    let mode: WorkModeID
    let scenario: String
    let objectiveIdentity: TatwoObjectiveIdentity
    let objectiveHash: String
    let preview: String

    var objective: String { objectiveIdentity.normalizedObjective }
}

struct ChatComputerHostAuthoritySnapshot: Sendable, Equatable {
    let contractID: String
    let goalID: String
    let goalHash: String
    let planHash: String
}

enum PLGAuthorityState: Equatable {
    case none
    case verified(runID: UUID, headHash: String)
    case quarantined(String)

    var isQuarantined: Bool {
        if case .quarantined = self { return true }
        return false
    }

    var quarantineMessage: String? {
        if case .quarantined(let message) = self { return message }
        return nil
    }
}

enum GitHubRepoUpdateCheckResult: Sendable, Equatable {
    case upToDate
    case updateAvailable
    case credentialUnavailable
    case unavailable
}

struct GitHubRepoUpdateChecker {
    static func check(url: String, workdir: String) async -> GitHubRepoUpdateCheckResult {
        await Task.detached(priority: .utility) {
            checkSynchronously(url: url, workdir: workdir)
        }.value
    }

    static func classifyRemoteFailure(_ stderr: String) -> GitHubRepoUpdateCheckResult {
        let normalized = stderr.lowercased()
        let credentialSignals = [
            "authentication failed",
            "could not read username",
            "permission denied (publickey)",
            "terminal prompts disabled",
            "access denied",
            "http 401",
            "http 403"
        ]
        return credentialSignals.contains(where: normalized.contains)
            ? .credentialUnavailable
            : .unavailable
    }

    private static func checkSynchronously(
        url: String,
        workdir: String
    ) -> GitHubRepoUpdateCheckResult {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkdir = workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedWorkdir.isEmpty else { return .unavailable }

        let local = runGit(["-C", trimmedWorkdir, "rev-parse", "HEAD"])
        guard local.status == 0 else { return .unavailable }
        let localHead = local.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localHead.isEmpty else { return .unavailable }

        let remote = runGit(["ls-remote", trimmedURL, "HEAD"])
        guard remote.status == 0 else {
            return classifyRemoteFailure(remote.stderr)
        }
        guard let remoteHead = remote.stdout
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init),
              !remoteHead.isEmpty
        else {
            return .unavailable
        }

        if remoteHead == localHead { return .upToDate }
        // 消假綠燈：遠端 HEAD 若已存在本地物件庫（代表本地已含該 commit＝本地領先或已同步），
        // 就不是「有新版本可拉」。只有本地缺該 commit（遠端有本地沒有的東西）才算真有更新。
        let hasRemoteCommit = runGit(["-C", trimmedWorkdir, "cat-file", "-e", "\(remoteHead)^{commit}"])
        return hasRemoteCommit.status == 0 ? .upToDate : .updateAvailable
    }

    private static func runGit(_ arguments: [String]) -> (
        status: Int32,
        stdout: String,
        stderr: String
    ) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        } catch {
            return (-1, "", "")
        }
    }
}

struct GitHubProjectBindingMerger {
    static func apply(
        localDocument: TatwoNativeChatStoreDocument,
        to mergedDocument: TatwoNativeChatStoreDocument
    ) -> TatwoNativeChatStoreDocument {
        var result = mergedDocument
        for localProject in localDocument.projects {
            guard let index = result.projects.firstIndex(where: {
                      normalizedPath($0.workdir) == normalizedPath(localProject.workdir)
                  })
            else { continue }
            if !localProject.githubRepos.isEmpty {
                result.projects[index].githubRepos = localProject.githubRepos
            }
            result.projects[index].sessions = localProject.sessions
        }
        return result
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

/// Export-only chat transcript negative-state selector.
///
/// Activated only when `TATWO_ULTRAWORK_CHAT_FIXTURE=chat-transcript` is already
/// installing the disposable export store. Values are fail-closed: unknown or
/// blank selectors never invent a state and fall back to the default
/// active/Stop fixture.
///
/// Process/PID orphan is intentionally **not** a static visual fixture here —
/// orphan evidence requires a live process probe and remains a documented
/// follow-up rather than a faked transcript row.
enum TatwoChatTranscriptFixtureState: String, CaseIterable, Sendable, Equatable {
    case active
    case failed
    case cancelled
    case disconnected
    case reconnected
    case acceptedRelaunch = "accepted-relaunch"

    static let environmentKey = "TATWO_ULTRAWORK_CHAT_FIXTURE_STATE"

    /// Stable local inline identity for reconnect-only export states.
    static let activeInlineMessageID = "fixture-chat-active-inline"
    /// Fixed thread + logical key make the journal-projected remote row ID stable
    /// across running, terminal, and relaunch export evidence.
    static let threadID = UUID(
        uuidString: "8B1D31B4-4525-4F02-88CE-BC9E7A7CBF10")!
    static let remoteLogicalJobID = "fixture-logical-remote-job"
    static let remoteJobID = "fixture-remote-job"
    static let remoteLogicalKey = remoteLogicalJobID

    /// Fail-closed allowlist parse. `nil` / blank / unknown → `nil`.
    static func parse(_ raw: String?) -> Self? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = Self(rawValue: trimmed) {
            return exact
        }
        return Self(rawValue: trimmed.lowercased())
    }

    /// Installer resolution: absent/blank/unknown fail closed to `.active`.
    static func resolve(_ raw: String?) -> Self {
        parse(raw) ?? .active
    }

    static var acceptedRawValues: [String] {
        allCases.map(\.rawValue)
    }

}

/// Frozen C0 Chat scenes used only by the window snapshot exporter.
///
/// The selector is intentionally inert unless the existing export-window gate
/// is present. This keeps production launches from interpreting fixture input
/// and, through `ChatPageModel`'s fixture-store path, guarantees every scene is
/// assembled in a disposable store rather than the user's real Chat store.
enum TatwoExportChatGoldenScene: String, CaseIterable, Sendable, Equatable {
    case send
    case stream
    case stop
    case resume
    case slash
    case plg
    case engineSwitch = "engine_switch"
    case reattach
    case coldStart = "cold_start"
    case orphan
    case queuedTurn = "queued_turn"

    static let environmentKey = "TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"
    static let windowSnapshotEnvironmentKey =
        "TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"

    static func parse(_ raw: String?) -> Self? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return Self(rawValue: normalized)
    }

    static func resolve(environment: [String: String]) -> Self? {
        guard environment[windowSnapshotEnvironmentKey] != nil else {
            return nil
        }
        return parse(environment[environmentKey])
    }

    static var acceptedRawValues: [String] {
        allCases.map(\.rawValue)
    }

    var isFrozenInFlight: Bool {
        switch self {
        case .stream, .reattach, .queuedTurn:
            true
        case .send, .stop, .resume, .slash, .plg, .engineSwitch,
             .coldStart, .orphan:
            false
        }
    }
}

enum ChatCodexMirrorMerger {
    static func merge(
        codexMirror: TatwoNativeChatStoreDocument,
        localDocument: TatwoNativeChatStoreDocument
    ) -> TatwoNativeChatStoreDocument {
        let mirroredThreads =
            codexMirror.threads + codexMirror.projects.flatMap(\.threads)
        guard !mirroredThreads.isEmpty else {
            // A successful zero-row query proves only that this mirror snapshot
            // is empty. It is not a durable deletion/tombstone authority for
            // Tatwo's canonical rows or journal-backed transcript state.
            return localDocument
        }

        // User D / ChatPage.swift:37: only explicit 新增/匯入 may create
        // projects. Codex session restore may refresh matching rows and
        // surface projectless standalone chats; it must not promote cwd
        // buckets into Tatwo projects or persist Codex App sidebar folders.
        var result = localDocument
        let mirrorByID = Dictionary(
            mirroredThreads.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
            })
        let mirrorByCodexSessionID = Dictionary(
            mirroredThreads.compactMap { thread -> (String, TatwoNativeChatThread)? in
                normalizedNonEmpty(thread.codexSessionID).map { ($0, thread) }
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
            })

        func mirrorMatch(for local: TatwoNativeChatThread) -> TatwoNativeChatThread? {
            if let exact = mirrorByID[local.id] {
                return exact
            }
            guard let localCodexID = normalizedNonEmpty(local.codexSessionID) else {
                return nil
            }
            return mirrorByCodexSessionID[localCodexID]
        }

        func isStaleImportedMirrorRow(_ thread: TatwoNativeChatThread) -> Bool {
            guard let codexID = normalizedNonEmpty(thread.codexSessionID) else {
                return false
            }
            if mirrorByID[thread.id] != nil || mirrorByCodexSessionID[codexID] != nil {
                return false
            }
            let isMirrorIdentity =
                thread.id.uuidString.lowercased() == codexID.lowercased()
            let isMarked =
                thread.sourceMarker
                    == TatwoNativeChatThreadSourceMarker.codexAppMirror
            return isMirrorIdentity || isMarked
        }

        func refreshed(_ local: TatwoNativeChatThread) -> TatwoNativeChatThread {
            guard let mirrored = mirrorMatch(for: local) else { return local }
            return preservingLocalState(local, in: mirrored)
        }

        result.threads = localDocument.threads
            .filter { !isStaleImportedMirrorRow($0) }
            .map(refreshed)
        result.projects = localDocument.projects.map { project in
            var copy = project
            copy.threads = project.threads
                .filter { !isStaleImportedMirrorRow($0) }
                .map(refreshed)
            return copy
        }

        var seenThreadIDs = Set(result.threads.map(\.id))
        var seenCodexSessionIDs = Set(
            result.threads.compactMap { normalizedNonEmpty($0.codexSessionID) })
        result.projects.flatMap(\.threads).forEach { thread in
            seenThreadIDs.insert(thread.id)
            if let codexID = normalizedNonEmpty(thread.codexSessionID) {
                seenCodexSessionIDs.insert(codexID)
            }
        }

        // Resume projectless Codex chats only. Overlay projects stay out of
        // the Tatwo store unless the user already created/imported them.
        for overlayThread in codexMirror.threads {
            let codexID = normalizedNonEmpty(overlayThread.codexSessionID)
            guard !seenThreadIDs.contains(overlayThread.id),
                  codexID.map({ !seenCodexSessionIDs.contains($0) }) ?? true
            else { continue }
            result.threads.append(overlayThread)
            seenThreadIDs.insert(overlayThread.id)
            if let codexID {
                seenCodexSessionIDs.insert(codexID)
            }
        }
        result.threads.sort { $0.updatedAt > $1.updatedAt }
        result.selectedDiscussionID = localDocument.selectedDiscussionID
        result.updatedAt = Date()
        return result
    }

    private static func preservingLocalState(
        _ local: TatwoNativeChatThread,
        in mirrored: TatwoNativeChatThread
    ) -> TatwoNativeChatThread {
        var result = mirrored
        result.cliSessionID = local.cliSessionID
        result.codexCLISessionID = local.codexCLISessionID
        result.claudeSessionID = local.claudeSessionID
        result.adapterSessionHandles = local.adapterSessionHandles
        result.isPinned = local.isPinned
        result.isPlanModeEnabled = local.isPlanModeEnabled
        result.loopsConfig = local.loopsConfig
        result.workOSGoalID = local.workOSGoalID
        result.workOSContractID = local.workOSContractID
        result.selectedThreadWorkOSContext = local.selectedThreadWorkOSContext
        result.bindingInvalidation = local.bindingInvalidation
        result.threadPluginIDs = local.threadPluginIDs
        result.discussions = local.discussions
        result.activePLGRunProjection = local.activePLGRunProjection
        result.loopsSessions = local.loopsSessions
        if local.messages != nil {
            result.messages = local.messages
        }
        result.createdAt = min(local.createdAt, mirrored.createdAt)
        result.updatedAt = max(local.updatedAt, mirrored.updatedAt)
        return result
    }

    private static func localDraftDocument(
        from document: TatwoNativeChatStoreDocument
    ) -> TatwoNativeChatStoreDocument {
        let standalone = document.threads.filter(isLocalDraftThread)
        let projects = document.projects.compactMap { project -> TatwoNativeChatProject? in
            var copy = project
            copy.threads = project.threads.filter(isLocalDraftThread)
            return copy.threads.isEmpty ? nil : copy
        }
        return TatwoNativeChatStoreDocument(threads: standalone, projects: projects)
    }

    private static func isLocalDraftThread(_ thread: TatwoNativeChatThread) -> Bool {
        guard !thread.isArchived, normalizedNonEmpty(thread.codexSessionID) == nil else {
            return false
        }
        if chatLooksLikeInternalDelegationPrompt(thread.title)
            || chatLooksLikeInternalDelegationPrompt(thread.lastPreview) {
            return false
        }
        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = title.lowercased()
        let hasPreview = !thread.lastPreview
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMessage = thread.messages?.contains { record in
            !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !chatLooksLikeInternalDelegationPrompt(record.text)
        } == true
        let isDefaultEmptyChat = title.isEmpty || title == "新聊天" || lowerTitle == "new chat"
        return hasPreview || hasMessage || !isDefaultEmptyChat
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

typealias ChatNativeDevelopmentReceiptSubmitting = @MainActor (
    _ goalID: String?,
    _ contractID: String?,
    _ loopID: String?,
    _ receiptID: String?,
    _ receiptKind: String,
    _ satisfiesRequirementID: String?,
    _ store: TatwoGoalRunStore
) -> WorkOSReceiptSubmissionResult

struct TatwoPlanArtifactDiskStore: Sendable {
    let directoryURL: URL

    func load(threadID: UUID) throws -> TatwoPlanArtifactV1? {
        let url = fileURL(threadID: threadID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let artifact = try JSONDecoder.tatwoPlanArtifact.decode(
            TatwoPlanArtifactV1.self,
            from: Data(contentsOf: url))
        guard artifact.schema == TatwoPlanArtifactV1.schemaName,
              artifact.threadID == threadID
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return artifact
    }

    func save(_ artifact: TatwoPlanArtifactV1) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true)
        try artifact.canonicalJSONData().write(
            to: fileURL(threadID: artifact.threadID),
            options: [.atomic])
    }

    private func fileURL(threadID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(threadID.uuidString.lowercased()).json",
            isDirectory: false)
    }
}

struct ConfirmedPlanComputerHostBlockerHintTraceEntry: Equatable {
    enum Event: String {
        case structuredPublish = "structured_publish"
        case deferredStartBoundaryAwaited =
            "deferred_start_boundary_awaited"
        case deferredStartBoundaryCancelled =
            "deferred_start_boundary_cancelled"
        case deferredStartBoundaryDiscarded =
            "deferred_start_boundary_discarded"
        case boundaryRepublish = "boundary_republish"
        case confirmationReleased = "confirmation_released"
        case timerAutoClearSuppressed = "timer_auto_clear_suppressed"
        case timerClear = "timer_clear"
        case ownershipReset = "ownership_reset"
        case unrelatedTurnClear = "unrelated_turn_clear"
        case sessionBoundaryClear = "session_boundary_clear"
    }

    enum BlockerClass: String {
        case bindingFailed = "binding_failed"
        case approvalFailed = "approval_failed"
    }

    let event: Event
    let planConfirmInFlight: Bool
    let pendingBlockerClass: BlockerClass?
    let visibleBlockerClass: BlockerClass?
    let ownerGeneration: Int?
    let clearGeneration: Int
    let confirmationGeneration: UInt64?
    let deferredBoundaryIdentity: UUID?
    let deferredRemoteTurnGeneration: UInt64?
    let deferredBoundaryCancelled: Bool?
}

struct ConfirmedPlanDeferredStartBoundaryHandle {
    let identity: UUID
    let remoteTurnGeneration: UInt64
    let confirmationGeneration: UInt64
    let task: Task<Void, Never>
    let cancellationFence: ChatRemoteTurnCancellationFence
}

@MainActor
final class ChatPageModel: ObservableObject {
    @Published var skin: ChatSkin = .codex
    @Published var engine: ChatEngine = .codex
    @Published var selectedModel: String = "gpt-5.5" {
        didSet {
            let route = routeChoice
            engine = route.engine
            // Keep the user's effort choice across model switches; fall back to
            // the route default only when the new route cannot honour it.
            if route.supportsNativeReasoningControl,
               !route.allowedEfforts.contains(selectedEffort) {
                selectedEffort = route.allowedEfforts.contains(route.defaultEffort)
                    ? route.defaultEffort
                    : (route.allowedEfforts.first ?? .high)
            }
            if route.supportsNativeSpeedControl {
                selectedSpeedTier = route.allowedSpeedTiers.contains(selectedSpeedTier)
                    ? selectedSpeedTier
                    : (route.defaultSpeedTier ?? route.allowedSpeedTiers.first ?? .fast)
            }
            syncSessionIDFromSelection()
            refreshGatewayCooldownProjection()
        }
    }
    /// A route chosen while a response is already running. The active turn
    /// stays bound to its launch route; this selection is applied only after
    /// the formal terminal event, before the next queued turn starts.
    @Published internal(set) var pendingModelID: String?
    @Published var selectedEffort: TatwoCodexReasoningEffort = .high
    @Published var selectedSpeedTier: TatwoModelSpeedTier = .fast
    @Published var mode: ChatRunMode = .chat
    @Published var permissionPreset: TatwoPermissionPreset = .approveForMe {
        didSet {
            if let mapped = permissionPreset.codexSandboxMode {
                sandboxMode = mapped
            }
        }
    }
    @Published var sandboxMode: TatwoCodexSandboxMode = .workspaceWrite
    @Published internal(set) var isLoadingStore = true
    @Published internal(set) var codexMirrorStatus: TatwoCodexAppStateBridge.MirrorStatus = .notEnabled
    @Published internal(set) var isEnablingCodexMirror = false
    @Published var document: TatwoNativeChatStoreDocument = TatwoNativeChatStoreDocument() {
        didSet {
            transcriptMessagesDocumentRevision &+= 1
        }
    }
    @Published var searchText: String = ""
    @Published var selectedProjectID: UUID?
    @Published var selectedThreadID: UUID? {
        didSet {
            if selectedThreadID != oldValue {
                activeBrowserAgentPageBinding = nil
                clearConfirmedPlanComputerHostBlockerAtSessionBoundaryIfNeeded()
                ChatTranscriptPerformanceCacheCoordinator
                    .sessionBoundaryDidChange()
                refreshActivePlanArtifact()
                let recoveryThreadID = selectedThreadID
                Task { @MainActor [weak self] in
                    await self?.recoverPendingBrowserLifecycleIntent(
                        for: recoveryThreadID)
                }
            }
        }
    }
    @Published var selectedDiscussionID: UUID? {
        didSet {
            if selectedDiscussionID != oldValue {
                clearConfirmedPlanComputerHostBlockerAtSessionBoundaryIfNeeded()
                ChatTranscriptPerformanceCacheCoordinator
                    .sessionBoundaryDidChange()
            }
        }
    }
    /// 工程 B 一鍵授權：per-thread MCP 工具 allowlist。CLI 回報權限請求時
    /// transcript 出「允許此工具」鈕→寫進這裡→下一輪 dispatch 帶入 --allowedTools。
    var threadAllowedMCPTools: [UUID: Set<String>] = [:]

    static let allowableBuiltinTools: Set<String> = [
        "Bash", "Read", "Write", "Edit", "Grep", "Glob",
        "WebFetch", "WebSearch", "ToolSearch",
    ]
    /// #16 右列 loops 收納串目前展開的 session。
    @Published var selectedLoopsSessionID: UUID?
    /// #16 P5 正在派工的 loop（顯示轉圈）。
    @Published var dispatchingLoopID: UUID?
    /// #16 /plg 當前 PLG 執行（狀態機投影）。
    @Published var activePLGRun: TatwoPLGRun?
    @Published var activePlanArtifact: TatwoPlanArtifactV1?
    @Published var planConfirmInFlight = false
    @Published var planWorkOSLocalActionPresentation =
        ChatPlanWorkOSLocalActionPresentation.idle
    @Published var plgError: String?
    /// #16 目標暫停：只暫停 App 投影；派工與 ledger 皆由 Work OS/MCP 管理。
    @Published var plgPaused = false
    /// #16 請求開右列 loops 面板（/plg 觸發後 view 觀察此旗標）。
    @Published var requestOpenLoopsPanel = false
    var appliedPLGEventIDs: Set<UUID> = [] // 治理層:事件去重
    var plgAuthorityState: PLGAuthorityState = .none
    @Published var messages: [ChatMessage] = [] {
        didSet {
            // Array element mutations (including streaming text appends) pass
            // through this setter, so the projection invalidates exactly when
            // the live source changes rather than on every SwiftUI body read.
            transcriptMessagesLiveRevision &+= 1
        }
    }
    @Published var prompt: String =
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_PROMPT"] ?? "" {
        didSet {
            if prompt != oldValue {
                scheduleComposerDraftPersistence()
            }
            // 打字改變後建議清單會變，兩種 picker 都重置高亮，避免指向錯項。
            if prompt != oldValue, skillSuggestionSelectedIndex != nil {
                skillSuggestionSelectedIndex = nil
            }
            if prompt != oldValue, slashCommandSelectedIndex != nil {
                slashCommandSelectedIndex = nil
            }
            if prompt != oldValue, issueMentionSelectedIndex != nil {
                issueMentionSelectedIndex = nil
            }
        }
    }
    /// #2 skill 建議鍵盤選取的高亮 index（nil＝未選，Enter 照常送出）。
    @Published var skillSuggestionSelectedIndex: Int?
    /// slash 建議鍵盤選取的高亮 index；語意與 skill picker 一致。
    @Published var slashCommandSelectedIndex: Int?
    @Published var workspacePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    /// A bundle/operator supplied workspace remains authoritative even for a
    /// standalone Chat thread. Ordinary standalone chats without this explicit
    /// override still use the isolated App Support workspace.
    var configuredChatWorkdirOverride: String?
    @Published var droppedPaths: [String] = []
    @Published var droppedPathDisplayNames: [String: String] = [:]
    /// #7 輸入框瞬時提示（如「剪貼簿沒有圖片」），約 2.4 秒後自動清除。
    @Published var composerHint: String?
    @Published internal(set) var composerDraftPersistenceWarning: String?
    @Published internal(set) var chatStorePersistenceWarning: String?
    var composerHintClearGeneration = 0
    var confirmedPlanComputerHostBlockerHintGeneration: Int?
    // Retains only an allowlisted, already-redacted blocker across the nested
    // confirmed-Plan unwind. The visible hint generation alone is insufficient:
    // downstream settlement can replace that transient surface before the
    // outer async confirmation boundary regains control.
    var pendingConfirmedPlanComputerHostBlockerHint: String?
    internal(set) var confirmedPlanComputerHostBlockerHintTrace:
        [ConfirmedPlanComputerHostBlockerHintTraceEntry] = []
    @Published internal(set) var sendActionSequence = 0
    @Published var isRunning = false
    @Published internal(set) var cancellationBlockedReason: String?
    @Published var lastCommand = "尚未執行"
    @Published var codexSessionID: String?
    @Published var claudeSessionID: String?
    @Published var accountName: String = ""
    @Published var gitBranch: String = "—"
    @Published var gitChangedFileCount: Int = 0
    @Published var gitChangedFilePreview: [String] = []
    @Published var gitChangedFiles: [ChatGitChangedFileSummary] = []
    @Published var gitChangedLineAdditions: Int = 0
    @Published var gitChangedLineDeletions: Int = 0
    @Published internal(set) var githubRepoCheckingProjectID: UUID?
    @Published internal(set) var githubRepoCheckMessageProjectID: UUID?
    @Published internal(set) var githubRepoCheckMessage: String?
    @Published var coworkTemplates: [TatwoCoworkTicketTemplate] = []
    @Published var selectedCoworkTemplateID: String?
    @Published var scenarioConfigBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
    /// Normal Chat is one runner at a time, but users may interrupt with the
    /// next request. These tickets remain visible and run in order after the
    /// active response finishes.
    @Published internal(set) var chatQueue: [ChatQueuedTicket] = []
    /// Internal continuations can carry a full runner command without creating
    /// a transcript user row. The ticket keeps its real command; this runtime
    /// marker only controls whether a canonical user echo exists.
    var queuedUserEchoSuppressionMessageIDs: Set<ChatMessage.ID> = []
    var queuedPlanClarificationSettlements:
        [ChatMessage.ID: ChatQueuedPlanClarificationSettlement] = [:]
    var isStartingQueuedChatTurn = false
    @Published internal(set) var chatQueuePaused = false
    static let maxQueuedChatTurns = 32
    static let maxQueuedChatUTF8Bytes = 512 * 1024
    /// Runtime-only audit trail for the human supervisor. It deliberately does
    /// not pollute the persisted assistant transcript with tool noise.
    @Published internal(set) var liveWorkActivities: [ChatLiveWorkActivity] = []
    /// Parallel structured activity feed; the legacy stringly strip above
    /// remains unchanged until the S3 UI slice consumes this projection.
    @Published internal(set) var chatActivityFeed = ChatActivityFeedV1(
        activities: [],
        completedOverflowCount: 0)
    @Published internal(set) var chatTranscriptJournal = ChatTranscriptJournalV1()
    internal(set) var chatTranscriptJournalPersistenceAllowed = true
    var chatTranscriptJournalRecoveryPending = false
    var chatTranscriptJournalRecoveryTask: Task<Void, Never>?
    var chatTranscriptJournalRevision: UInt64 = 0
    @Published internal(set) var coldStartHydrationState:
        ChatColdStartHydrationState = .notScheduled
    var legacyTranscriptMigrationCompleted = false
    var chatActivityFeedReducer = ChatActivityFeedReducer(maxVisibleCompleted: 12)
    @Published var cliSessions: [ChatCLISessionSnapshot] = []
    @Published var selectedCLISessionID: String?
    @Published var terminalLines: [TatwoTerminalLine] = []
    @Published var nativeTerminalStatus: String = "idle"
    // CLI 多工分頁（使用者 goal#2：cli 要能一次多工 session）。book=開啟中的分頁；每分頁一個並存 PTY + 各自 buffer。
    @Published var cliSessionBook = TatwoNativeCLISessionBook() {
        didSet { persistCLISessionBook() }
    }
    @Published internal(set) var cliTabBuffers: [UUID: [TatwoTerminalLine]] = [:]
    @Published internal(set) var cliTabStatuses: [UUID: String] = [:]
    /// 每個 CLI 分頁一個終端把手。預設 PTY 真終端，pipe 版留作 fallback（見 CLITerminalBackend）。
    var cliTerminals: [UUID: TatwoCLITerminalHandle] = [:]
    var cliTerminalEngines: [UUID: TatwoNativeCLISessionBook.Engine] = [:]
    static let cliSessionBookDefaultsKey = "tatwo.cliSessionBook.v1"
    @Published var lastClaudeRouteReceiptStatus: String = "round18 route receipt 待觸發"
    @Published var pluginRegistryBook: TatwoPluginRegistryBookV1 = TatwoPluginRegistryBookV1()
    @Published internal(set) var latestLedgerActivityByThreadID: [String: Date] = [:]
    @Published var selectedWorkOSContract: TatwoWorkOSContractV1?
    @Published var selectedGoalRecord: TatwoStoredGoalRun?
    /// Verified once from current-session.json + canonical GoalRun storage.
    /// It may only attach to a Codex mirror row whose durable cwd metadata is
    /// exactly the App-owned Tatwo chat-workspace.
    var verifiedCurrentSessionBundle: ChatVerifiedCurrentSessionBundle?
    var currentSessionPointerPresent = false
    /// A canonical Goal/pointer mutation already committed, but the matching
    /// Chat document update has not yet reached durable storage. New Goal
    /// creation retries persistence first and otherwise fails closed.
    var workOSBindingPersistencePending = false
    /// A durable row-mutation intent could not be reconciled exactly. Keep Goal
    /// creation fail-closed until a later cold start can prove and apply it.
    var workOSBindingMutationRecoveryBlocked = false
    /// The exact row owned by the blocked durable intent. The model-wide
    /// mutation gate remains fail-closed, but row-local UI must not pollute
    /// unrelated work-scoped threads.
    var workOSBindingMutationRecoveryIntent:
        WorkOSBindingMutationIntentV1?
    /// 上方目標狀態列的暫停旗標（人類主動；UI 層標記）。
    @Published var activeGoalPaused = false
    @Published var selectedDispatchRecords: [TatwoDispatchRecord] = [] {
        didSet {
            guard selectedDispatchRecords != oldValue else { return }
            recordSelectedDispatchRemoteJobs(selectedDispatchRecords)
        }
    }
    var nativeTerminalReceipts:
        [String: (receiptID: String, outputRef: String)] = [:]
    /// /issue 執行後請求打開懸浮資訊卡（view 端消費後重置）。
    @Published var requestOpenInfoCard = false
    /// Issue List 支線等待佇列持久化（app-support/issue-list.json）。
    let issueListStore = TatwoIssueListStore()
    /// 佇列快照（資訊卡 Issue List 區讀）。
    @Published var issueListEntries: [TatwoIssueListEntryV1] = []
    /// 全域模式（卡片標頭切換鈕；預設只看本 thread／本專案）。
    @Published var issueListShowsGlobal = false
    /// @ 搜尋點選後釘在資訊卡的單筆 issue（跨 thread 檢視用；✕ 解除）。
    @Published var focusedIssueEntryID: String?
    /// @ 搜尋清單鍵盤高亮 index（↑↓ 移動、Enter 釘選；prompt 改動即清）。
    @Published var issueMentionSelectedIndex: Int?
    /// 封存 thread 時偵測到等待中 issue → 彈詢問；(threadRef, 標題, 筆數)。
    @Published var pendingArchiveIssuePrompt: (
        threadRef: String,
        threadID: UUID,
        projectID: UUID?,
        title: String,
        count: Int
    )?
    /// 跑過 /issue 後才在資訊卡顯示 Issues 區塊（含 0 筆空狀態）。
    @Published var issueProjectionRan = false
    /// /issue 最近一次投影結果（供右側資訊卡讀，不進 thread 訊息流）。
    @Published var lastIssueProjection: [TatwoIssueProjectionV1] = []
    @Published var selectedWorkOSStateMessage: String = "Work OS contract 待建立"
    @Published var gatewayLiveStatus: TatwoGatewayLiveStatus?
    @Published internal(set) var selectedGatewayCooldownProjection: TatwoGatewayCooldownProjectionV1
    @Published internal(set) var handoffStatus: String = "交接包待命"
    @Published internal(set) var activeGoalClock = Date()
    @Published var pendingHandoffByThreadID: [UUID: ChatHandoffEnvelope] = [:]

    let assistantTranscriptCache = TatwoAssistantTranscriptCache()
    let runner: ChatCLIProcessRunner
    let nativeRunner: any ChatNativeAgentRunning
    let miniMaxRunner: any MiniMaxChatRunning
    let dispatchService: any ChatDispatchService
    let runtimeEventReducer: any ChatRuntimeEventReducer
    let runnerAuthorityDiscoverer: any ChatRunnerAuthorityDiscovering
    let processStorageLayout: TatwoChatProcessStorageLayout?
    let appMCPRuntimeProvider:
        @MainActor () -> TatwoAppMCPRuntimeState
    let computerHostApprovalLeaseIssuer:
        @MainActor (
            _ contractID: String,
            _ workspaceRoot: String
        ) throws -> TatwoHostApprovalLeaseV1
    let computerHostExecutor:
        @MainActor (
            _ contractID: String,
            _ workspaceRoot: String,
            _ action: TatwoComputerActionKind,
            _ value: String
        ) throws -> TatwoComputerHostReceiptV1
    let cancellationDurability:
        ChatCancellationDurabilityCoordinator
    var durableCancellationRecord: ChatDurableCancellationRecord?
    let imageAssetStore = TatwoImageAssetStore()
    let store: TatwoNativeChatStore
    let defersColdStartHydration: Bool
    let coldStartEnvironment: [String: String]
    let coldStartFixtureRequested: Bool
    let coldStartInitialStoreLoadBarrier:
        (@Sendable () async throws -> Void)?
    let coldStartHydrationTimeoutNanoseconds: UInt64
    var coldStartHydrationTask: Task<Void, Never>?
    var coldStartHydrationTimeoutTask: Task<Void, Never>?
    var coldStartHydrationAttempt: UInt64 = 0
    var coldStartRunnerAuthoritySnapshot:
        ChatRunnerAuthoritySnapshot?
    let runnerRuntimeSweepGate: ChatCLIRuntimeSweepGate
    let chatCLIRuntimeRootURL: URL
    let nativeAgentJournalDirectoryURL: URL
    let usesInjectedNativeRunner: Bool
    let usesInjectedMiniMaxRunner: Bool
    var isApplyingInitialStorePayload = false
    let composerDraftStore: TatwoChatComposerDraftStore
    let chatTranscriptJournalStore: ChatTranscriptJournalDiskStore
    let codexAppStateBridge: TatwoCodexAppStateBridge?
    let codexMirrorCacheRootURL: URL
    let codexProjectSyncEnabled: Bool
    let preferenceStore: TatwoPreferenceStore
    let pluginRegistryStore: TatwoPluginRegistryStore
    let goalRunStore: TatwoGoalRunStore
    let dispatchRegistry: TatwoDispatchRegistry
    let planWorkOSNextResolver: ChatPlanWorkOSNextResolver
    let nativeDevelopmentReceiptSubmitter:
        ChatNativeDevelopmentReceiptSubmitting
    let authorityBootstrapModel = TatwoAppAuthorityBootstrapModel()
    let remoteBorrowAuthorizationStore: TatwoRemoteBorrowAuthorizationStore
    let pendingRemoteTargetStore: ChatPendingRemoteTargetDiskStore
    let remoteTurnDispatcher: any ChatRemoteTurnDispatching
    let remoteProjectionProcessID: String
    let gatewayCooldownStore: TatwoGatewayCooldownStore
    let plgChainStore: TatwoPLGChainStore
    var nativeTerminal: TatwoNativeTerminalSession?
    var nativeTerminalSelectionID: String?
    var activeAssistantID: ChatMessage.ID?
    var activeTurnLifecycle: TatwoChatTurnLifecycle?
    var activeTurnDispatchSnapshot: ChatTurnDispatchSnapshot?
    /// Immutable execution provenance for the physical turn currently owning
    /// the runner. Command/activity journal events and the final result are
    /// stamped from this one value so they cannot disagree.
    internal var activeTurnExecutionProvenance:
        ChatTurnExecutionProvenance?
    internal var pendingNativeDevelopmentDispatch: TatwoDispatchRecord?
    internal var pendingSingleModelGoalDispatch: TatwoDispatchRecord?
    internal var singleModelGoalActivationInFlight = false
    internal var lastNativeRuntimeStartBlocker: String?
    internal(set) var lastNativeDevelopmentReceiptBridgeFailure:
        String?
    var activeNativeDevelopmentDispatch:
        (
            runID: String,
            contractID: String,
            dispatchID: String,
            modelID: String
        )?
    internal var activeSingleModelGoalDispatch:
        (
            runID: String,
            contractID: String,
            dispatchID: String,
            runnerInstanceID: UUID,
            observedToolUse: Bool
        )?
    internal var singleModelGoalDispatchContractIDByDispatchID:
        [String: String] = [:]
    internal var singleModelGoalRunnerStartReceiptByDispatchID:
        [String: UUID] = [:]
    internal var singleModelGoalDeferredStartAwaitingDispatchIDs:
        Set<String> = []
    var pendingNativeDevelopmentAutoFollowup:
        (contractID: String, completedModelID: String)?
    var consumedBlockedTerminalFailureIdempotencyKeys: Set<String> = []
    var activeGatewayContinuationTurn:
        ChatGatewayContinuationTurnState?
    var activeGatewayStaleHandleFallback:
        ChatGatewayContinuationFallbackCoordinator?
    var activeGatewayFallbackTurnInputs:
        ChatGatewayFallbackTurnInputs?
    /// In-memory stable/tail ledger for the active assistant stream. Tail never
    /// goes through `persistSelectedThreadMessages` / store.save.
    var streamLedger = StreamTranscriptLedger()
    var userStopRequested = false
    var cliRunnersBySessionKey: [String: ChatCLIProcessRunner] = [:]
    var nativeRunnersBySessionKey: [String: any ChatNativeAgentRunning] = [:]
    var miniMaxRunnersBySessionKey: [String: any MiniMaxChatRunning] = [:]
    var sessionKeyByRunID: [String: String] = [:]
    var parkedTurnBySessionKey: [String: ChatParkedTurnRuntime] = [:]
    var transcriptMutationReference: TatwoNativeChatSessionReference?
    var computerHostBindingSlot = ChatComputerHostTurnBindingSlot()
    var activeBrowserAgentPageBinding:
        TatwoBrowserCommittedPageBindingV1?
    var computerHostAuthoritySnapshotsByRunID:
        [String: ChatComputerHostAuthoritySnapshot] = [:]
    var computerAutoContinuationBudget =
        ChatComputerAutoContinuationBudget()
    var pendingComputerAutoContinuation: String?
    var requestedComputerPermissions: Set<TatwoComputerHostPermission> = []
    var planQuestionStreamParser = TatwoPlanQuestionStreamParser()
    /// Held separately until model output becomes a real Plan transcript item.
    /// This prevents an empty plan canvas from appearing at command submission.
    var pendingPlanObjectives: [UUID: String] = [:]
    var planClarificationRoundCountByThread: [UUID: Int] = [:]
    var terminalPlanTurnAssistantMessageIDs: Set<ChatMessage.ID> = []
    /// Immutable source-turn authority frozen at send time. Completion must
    /// match the same thread, user row, assistant row and starting artifact
    /// before it may revise Plan state.
    var activePlanTurnBinding: ChatPlanTurnBinding?
    var messageCache: [TatwoNativeChatSessionReference: [ChatMessage]] = [:]
    var transcriptMessagesLiveRevision: UInt64 = 0
    var transcriptMessagesDocumentRevision: UInt64 = 0
    let transcriptProjectionCache = ChatTranscriptProjectionCache()
    private var transcriptPerformanceCacheResetCancellable: AnyCancellable?
    let cliRuntimeEnabled: Bool
    /// 快照匯出用：開一個「看得到但不真的 forkpty」的 CLI 分頁，讓標題列與浮動光可入鏡。
    /// env 沒設就完全不生效，真實執行零行為差異。
    let exportCLITabFixtureEnabled: Bool
    lazy var initialStoreLoadController =
        TatwoLatestAsyncLoadController<ChatInitialStoreLoadOutcome>
    { [weak self] isLoading in
        self?.isLoadingStore = isLoading
    }
    var selectedWorkOSStateLoadTask: Task<Void, Never>?
    var selectedWorkOSStateLoadGeneration: UUID?
    var codexMirrorLoadTask: Task<Void, Never>?
    var cliSessionReloadTask: Task<Void, Never>?
    var selectedDispatchPersistenceTask: Task<Void, Never>?
    var runnerStateReconcileTasksByRunID: [String: Task<Void, Never>] = [:]
    var runnerStateReconcileGenerationsByRunID: [String: UUID] = [:]
    var pendingRemoteTurnTask: Task<Void, Never>?
    var pendingRemoteTurnGeneration: UInt64 = 0
    var pendingRemoteTurnCancellationFence: ChatRemoteTurnCancellationFence?
    var pendingRemoteTurnClaim: ChatPendingRemoteTargetV1?
    var confirmedPlanConfirmationGeneration: UInt64 = 0
    var activeConfirmedPlanConfirmationGeneration: UInt64?
    var confirmedPlanDeferredStartBoundaryHandle:
        ConfirmedPlanDeferredStartBoundaryHandle?
    var composerDraftsBySessionKey: [String: String] = [:]
    var composerDraftDirtySessionKeys: Set<String> = []
    var composerDraftAcknowledgedMessageIDBySessionKey: [String: String] = [:]
    var composerDraftPersistenceTask: Task<Void, Never>?
    var isRestoringComposerDraft = false
    var didBindInitialComposerSelection = false
    static let composerDraftDebounceNanoseconds: UInt64 = 450_000_000
    nonisolated(unsafe) var activeGoalTimer: Timer?
    var lastSelectedWorkOSAutoRefreshAt: Date?
    static let selectedWorkOSAutoRefreshInterval: TimeInterval = 2
    var snapshotLoopsOverride: TatwoNativeThreadLoopsConfig?
    var planArtifactStore: TatwoPlanArtifactDiskStore?
    var exportChatTranscriptFixtureContext:
        (historyRows: [ChatMessage], threadID: UUID, startedAt: Date)?
    static let cancellationBlockedNotice =
        "取消受阻：系統尚未能確認背景執行程序已停止。為避免重複執行，這個聊天暫時鎖定；請重試取消。"
    static let cancellationRetryNotice =
        "正在重試取消；在正式終止確認前，這個聊天仍保持鎖定。"

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
        store injectedStore: TatwoNativeChatStore? = nil,
        codexAppStateBridge injectedCodexAppStateBridge:
            TatwoCodexAppStateBridge? = nil,
        composerDraftStore injectedComposerDraftStore:
            TatwoChatComposerDraftStore? = nil,
        transcriptJournalStore injectedTranscriptJournalStore:
            ChatTranscriptJournalDiskStore? = nil,
        processStorageLayout injectedProcessStorageLayout:
            TatwoChatProcessStorageLayout? = nil,
        goalRunStore injectedGoalRunStore: TatwoGoalRunStore? = nil,
        plgChainStore injectedPLGChainStore: TatwoPLGChainStore? = nil,
        dispatchRegistry injectedDispatchRegistry: TatwoDispatchRegistry? = nil,
        planWorkOSNextResolver injectedPlanWorkOSNextResolver:
            @escaping ChatPlanWorkOSNextResolver = {
                request,
                store,
                registry,
                scenarioBook in
                try ChatPlanWorkOSLocalActionBridge.resolveNext(
                    request: request,
                    store: store,
                    registry: registry,
                    scenarioBook: scenarioBook)
            },
        preferenceStore injectedPreferenceStore:
            TatwoPreferenceStore? = nil,
        pluginRegistryStore injectedPluginRegistryStore:
            TatwoPluginRegistryStore? = nil,
        gatewayCooldownStore injectedGatewayCooldownStore:
            TatwoGatewayCooldownStore? = nil,
        remoteBorrowAuthorizationStore injectedRemoteBorrowAuthorizationStore:
            TatwoRemoteBorrowAuthorizationStore? = nil,
        pendingRemoteTargetStore injectedPendingRemoteTargetStore:
            ChatPendingRemoteTargetDiskStore? = nil,
        remoteTurnDispatcher injectedRemoteTurnDispatcher:
            any ChatRemoteTurnDispatching = ChatUnavailableRemoteTurnDispatcher(),
        remoteProjectionProcessID injectedRemoteProjectionProcessID: String =
            ChatTranscriptJournalAdapter.remoteProjectionProcessID,
        runnerAuthorityDiscoverer injectedRunnerAuthorityDiscoverer:
            any ChatRunnerAuthorityDiscovering =
                ChatUnknownRunnerAuthorityDiscoverer(),
        cancellationStateStore injectedCancellationStateStore:
            (any ChatCancellationStateStoring)? = nil,
        nativeDevelopmentReceiptSubmitter injectedNativeDevelopmentReceiptSubmitter:
            @escaping ChatNativeDevelopmentReceiptSubmitting = {
                goalID,
                contractID,
                loopID,
                receiptID,
                receiptKind,
                satisfiesRequirementID,
                store in
                WorkOSFactory.submitReceipt(
                    goalID: goalID,
                    contractID: contractID,
                    loopID: loopID,
                    receiptID: receiptID,
                    receiptKind: receiptKind,
                    satisfiesRequirementID: satisfiesRequirementID,
                    store: store)
            },
        nativeRunner injectedNativeRunner:
            (any ChatNativeAgentRunning)? = nil,
        miniMaxRunner injectedMiniMaxRunner:
            (any MiniMaxChatRunning)? = nil,
        dispatchService injectedDispatchService:
            any ChatDispatchService = DefaultChatDispatchService(),
        runtimeEventReducer injectedRuntimeEventReducer:
            any ChatRuntimeEventReducer = DefaultChatRuntimeEventReducer(),
        chatRuntimeRootURL injectedChatRuntimeRootURL: URL? = nil,
        appMCPRuntimeProvider injectedAppMCPRuntimeProvider:
        @escaping @MainActor () -> TatwoAppMCPRuntimeState = {
            .notStarted
        },
        computerHostApprovalLeaseIssuer
            injectedComputerHostApprovalLeaseIssuer:
            @escaping @MainActor (
                _ contractID: String,
                _ workspaceRoot: String
            ) throws -> TatwoHostApprovalLeaseV1 = {
                contractID,
                workspaceRoot in
                try TatwoHostApprovalStore.default().issue(
                    contractID: contractID,
                    workspaceRoot: workspaceRoot,
                    allowedActions: [.computerUse],
                    ttl: 180)
            },
        computerHostExecutor injectedComputerHostExecutor:
            @escaping @MainActor (
                _ contractID: String,
                _ workspaceRoot: String,
                _ action: TatwoComputerActionKind,
                _ value: String
            ) throws -> TatwoComputerHostReceiptV1 = {
                contractID,
                workspaceRoot,
                action,
                value in
                let approvalStore = TatwoHostApprovalStore.default()
                let lease = try approvalStore.issue(
                    contractID: contractID,
                    workspaceRoot: workspaceRoot,
                    allowedActions: [.computerUse],
                    ttl: 60)
                defer { try? approvalStore.revoke(id: lease.id) }
                return try TatwoComputerHost(
                    approvalStore: approvalStore
                ).execute(
                    contractID: contractID,
                    leaseID: lease.id,
                    workspaceRoot: workspaceRoot,
                    action: action,
                    value: value)
            },
        coldStartInitialStoreLoadBarrier:
            (@Sendable () async throws -> Void)? = nil,
        coldStartHydrationTimeoutNanoseconds: UInt64 =
            15_000_000_000
    ) {
        self.processStorageLayout = injectedProcessStorageLayout
        // CLI runtime（真 zsh 終端）預設對真實使用者開啟；測試環境預設關以免生程序；
        // env 顯式覆蓋：="1" 強制開、="0" 強制關。
        let cliRuntimeFlag = environment["TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME"]
        let isTestEnvForCLI = environment["XCTestConfigurationFilePath"] != nil
        self.cliRuntimeEnabled = cliRuntimeFlag == "1" || (cliRuntimeFlag != "0" && !isTestEnvForCLI)
        self.exportCLITabFixtureEnabled =
            environment["TATWO_ULTRAWORK_EXPORT_CHAT_MODE"]?.lowercased() == "cli"
        if let rawWorkdir = environment["TATWO_ULTRAWORK_CHAT_WORKDIR"], !rawWorkdir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let configuredWorkdir = rawWorkdir.trimmingCharacters(in: .whitespacesAndNewlines)
            self.workspacePath = configuredWorkdir
            self.configuredChatWorkdirOverride = configuredWorkdir
        }
        // 資料安全鐵律：CHAT_FIXTURE 是拋棄式測試資料，絕不可寫到真實 store。
        // 一旦設了 fixture env，就把 store 導到隔離臨時路徑，任何持久化都只落在 temp。
        let exportGoldenScene =
            TatwoExportChatGoldenScene.resolve(environment: environment)
        let completionReportFixtureActive =
            environment[
                "TATWO_ULTRAWORK_CHAT_COMPLETION_REPORT_FIXTURE"] == "1"
        let chatFixtureActive = ["chat-transcript"]
            .contains(environment["TATWO_ULTRAWORK_CHAT_FIXTURE"] ?? "")
            || exportGoldenScene != nil
            || completionReportFixtureActive
        self.defersColdStartHydration =
            Self.shouldDeferColdStartHydration(environment: environment)
        self.coldStartEnvironment = environment
        self.coldStartFixtureRequested = chatFixtureActive
        self.coldStartInitialStoreLoadBarrier =
            coldStartInitialStoreLoadBarrier
        self.coldStartHydrationTimeoutNanoseconds =
            max(1_000_000, coldStartHydrationTimeoutNanoseconds)
        if let injectedStore {
            self.store = injectedStore
        } else if chatFixtureActive {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("tatwo-fixture-store-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("native-chat-threads.json")
            self.store = TatwoNativeChatStore(url: tmp, fallbackURLs: [])
        } else {
            self.store = TatwoNativeChatStore.defaultStore(environment: environment)
        }
        self.composerDraftStore = injectedComposerDraftStore
            ?? TatwoChatComposerDraftStore.colocated(with: self.store.url)
        self.chatTranscriptJournalStore = injectedTranscriptJournalStore
            ?? ChatTranscriptJournalDiskStore(
                fileURL: self.store.url.deletingLastPathComponent()
                    .appendingPathComponent("chat-transcript-journal-v1.json"))
        if self.defersColdStartHydration {
            self.chatTranscriptJournal = ChatTranscriptJournalV1()
            self.chatTranscriptJournalPersistenceAllowed = false
            self.chatTranscriptJournalRecoveryPending = false
        } else {
            do {
                self.chatTranscriptJournal =
                    try self.chatTranscriptJournalStore.load()
            } catch {
                self.chatTranscriptJournal = ChatTranscriptJournalV1()
                self.chatTranscriptJournalPersistenceAllowed = false
                self.chatTranscriptJournalRecoveryPending = true
                fputs(
                    "tatwo_chat_transcript_journal_load_blocked=\(TatwoPrivacyRedactor.redacted(error.localizedDescription))\n",
                    stderr)
            }
        }
        self.plgChainStore = injectedPLGChainStore
            ?? TatwoPLGChainStore.defaultStore(
                environment: environment,
                baseDirectory: self.store.url.deletingLastPathComponent())
        self.preferenceStore = injectedPreferenceStore
            ?? TatwoPreferenceStore.defaultStore(environment: environment)
        let codexMirrorDisabled = environment["TATWO_ULTRAWORK_CHAT_CODEX_MIRROR"] == "0" || environment["TATWO_ULTRAWORK_CHAT_CODEX_MIRROR_DISABLED"] == "1"
        let codexProjectSyncDisabled = environment["TATWO_ULTRAWORK_CHAT_CODEX_PROJECT_SYNC"] == "0"
            || environment["TATWO_ULTRAWORK_CHAT_CODEX_PROJECT_SYNC_DISABLED"] == "1"
        self.codexMirrorCacheRootURL =
            TatwoCodexAppStateBridge.defaultMirrorCacheRoot(
                environment: environment)
        if let injectedCodexAppStateBridge {
            self.codexAppStateBridge = injectedCodexAppStateBridge
        } else if injectedStore == nil, !codexMirrorDisabled, environment["XCTestConfigurationFilePath"] == nil {
            self.codexAppStateBridge = TatwoCodexAppStateBridge(
                sourcePaths: .defaultPaths(environment: environment),
                maxThreadRows: 140,
                maxThreadsPerProject: 12,
                maxStandaloneThreads: 10)
        } else {
            self.codexAppStateBridge = nil
        }
        self.codexProjectSyncEnabled = injectedStore == nil
            && !codexMirrorDisabled
            && !codexProjectSyncDisabled
            && environment["XCTestConfigurationFilePath"] == nil
        self.pluginRegistryStore = injectedPluginRegistryStore
            ?? TatwoPluginRegistryStore.defaultStore(environment: environment)
        self.goalRunStore = injectedGoalRunStore
            ?? TatwoGoalRunStore.default(environment: environment)
        self.planArtifactStore = TatwoPlanArtifactDiskStore(
            directoryURL: self.goalRunStore.directoryURL.appendingPathComponent(
                "plan-artifacts",
                isDirectory: true))
        self.dispatchRegistry = injectedDispatchRegistry
            ?? TatwoDispatchRegistry(directoryURL: self.goalRunStore.directoryURL)
        self.planWorkOSNextResolver = injectedPlanWorkOSNextResolver
        self.nativeDevelopmentReceiptSubmitter =
            injectedNativeDevelopmentReceiptSubmitter
        if let injectedRemoteBorrowAuthorizationStore {
            self.remoteBorrowAuthorizationStore = injectedRemoteBorrowAuthorizationStore
        } else if chatFixtureActive || injectedStore != nil {
            // Fixtures and explicitly injected stores keep approvals colocated.
            self.remoteBorrowAuthorizationStore = .production(
                stateRoot: self.store.url.deletingLastPathComponent()
            )
        } else {
            // Direct model composition follows the same bundle-trusted root
            // decision as AppShell. The exact production bundle ignores layout
            // overrides; staging/non-App processes remain isolated.
            self.remoteBorrowAuthorizationStore = .production(
                stateRoot: TatwoChatProcessCompositionResolver.stateRoot(
                    environment: environment)
            )
        }
        self.pendingRemoteTargetStore = injectedPendingRemoteTargetStore
            ?? ChatPendingRemoteTargetDiskStore(
                fileURL: self.store.url.deletingLastPathComponent()
                    .appendingPathComponent("pending-remote-target-v1.json"))
        self.remoteTurnDispatcher = injectedRemoteTurnDispatcher
        self.remoteProjectionProcessID =
            injectedRemoteProjectionProcessID.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
            ? ChatTranscriptJournalAdapter.remoteProjectionProcessID
            : injectedRemoteProjectionProcessID
        self.runnerAuthorityDiscoverer = injectedRunnerAuthorityDiscoverer
        self.dispatchService = injectedDispatchService
        self.runtimeEventReducer = injectedRuntimeEventReducer
        let runnerRuntimeSweepGate = ChatCLIRuntimeSweepGate()
        if self.defersColdStartHydration {
            // ChatCLIProcessRunner normally discovers durable authority and
            // launches its maintenance sweep from init. Hold that gate until
            // the post-first-frame hydration has published its one authority
            // snapshot on MainActor.
            _ = runnerRuntimeSweepGate.begin()
        }
        self.runnerRuntimeSweepGate = runnerRuntimeSweepGate
        let chatCLIRuntimeRootURL =
            injectedChatRuntimeRootURL
            ?? injectedProcessStorageLayout?.chatRuntimeRootURL
            ?? self.store.url.deletingLastPathComponent()
                .appendingPathComponent(
                    "chat-cli-runtime-v1",
                    isDirectory: true)
        self.chatCLIRuntimeRootURL = chatCLIRuntimeRootURL
        self.runner = ChatCLIProcessRunner(
            runnerAuthority:
                injectedRunnerAuthorityDiscoverer
                as? any ChatRunnerAuthorityRecording,
            runtimeGovernor: .shared,
            runtimeRootURL: chatCLIRuntimeRootURL,
            runtimeSweepGate: runnerRuntimeSweepGate)
        let nativeJournalDirectory =
            self.store.url.deletingLastPathComponent()
                .appendingPathComponent(
                    "chat-native-agent-runtime-v1",
                    isDirectory: true)
        self.nativeAgentJournalDirectoryURL = nativeJournalDirectory
        self.usesInjectedNativeRunner = injectedNativeRunner != nil
        if let injectedNativeRunner {
            self.nativeRunner = injectedNativeRunner
        } else if TatwoNativeAgentRunnerBuildConfiguration
            .useGovernedDevSessionRunner
        {
            self.nativeRunner = GovernedDevSessionRunner(
                journalDirectoryURL: nativeJournalDirectory,
                environment: environment)
        } else {
            self.nativeRunner = ChatNativeAgentRunner(
                approvalStore: TatwoHostApprovalStore.default(
                    environment: environment),
                journalDirectoryURL: nativeJournalDirectory)
        }
        self.usesInjectedMiniMaxRunner = injectedMiniMaxRunner != nil
        self.miniMaxRunner = injectedMiniMaxRunner
            ?? MiniMaxChatRunner(
                client: MiniMaxChatClient(
                    environment: environment))
        self.appMCPRuntimeProvider = injectedAppMCPRuntimeProvider
        self.computerHostApprovalLeaseIssuer =
            injectedComputerHostApprovalLeaseIssuer
        self.computerHostExecutor = injectedComputerHostExecutor
        let configuredComputerSteps = environment[
            "TATWO_COMPUTER_MAX_AUTO_STEPS"
        ].flatMap(Int.init) ?? 15
        self.computerAutoContinuationBudget =
            ChatComputerAutoContinuationBudget(
                maximumSteps: configuredComputerSteps)
        self.cancellationDurability = ChatCancellationDurabilityCoordinator(
            store: injectedCancellationStateStore
                ?? ChatCancellationStateDiskStore(
                    fileURL: self.store.url.deletingLastPathComponent()
                        .appendingPathComponent(
                            "chat-cancellation-lock-v1.json")))
        self.gatewayCooldownStore = injectedGatewayCooldownStore
            ?? TatwoGatewayCooldownStore(
                directoryURL: self.goalRunStore.directoryURL)
        self.selectedGatewayCooldownProjection = gatewayCooldownStore.projection(
            modelID: "gpt-5.5")
        self.accountName = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        self.coworkTemplates = TatwoCoworkTemplateFactory.templates(from: scenarioConfigBook)
        self.selectedCoworkTemplateID = coworkTemplates.first?.id
        if let rawSkin = environment["TATWO_ULTRAWORK_CHAT_SKIN"], let skin = ChatSkin(rawValue: rawSkin) ?? ChatSkin.allCases.first(where: { $0.shortTitle.lowercased() == rawSkin.lowercased() }) {
            self.skin = skin
        }
        // EXPORT_CHAT_MODE 是匯出專用捷徑：一個 env 同時決定分頁模式與 CLI 空分頁 fixture，
        // 主導做快照自驗時不必記兩個變數。一般執行走既有的 CHAT_MODE。
        if let rawMode = environment["TATWO_ULTRAWORK_EXPORT_CHAT_MODE"]
            ?? environment["TATWO_ULTRAWORK_CHAT_MODE"],
           let mode = ChatRunMode(rawValue: rawMode) ?? ChatRunMode.allCases.first(where: { $0.rawValue.lowercased() == rawMode.lowercased() }) {
            self.mode = mode
        }
        if let rawModel = environment["TATWO_ULTRAWORK_CHAT_MODEL"] {
            let resolved = ChatRouteChoice.resolve(rawModel)
            if ChatRouteChoice.all.contains(where: { $0.id == resolved.id }) {
                self.selectedModel = resolved.id
                self.engine = resolved.engine
                if ["sonnet4.6", "sonnet-4-6", "claude-sonnet-4-6"].contains(rawModel.lowercased()) {
                    self.composerHint = "舊 Sonnet 4.6 名稱已相容映射到 canonical sonnet5 route。"
                }
            } else if ["haiku4.6", "haiku-4-6", "claude-haiku-4-6"].contains(rawModel.lowercased()) {
                self.composerHint = "Haiku 4.6 目前未獲供應商授權，已 fail closed；請改選實際可用的 haiku4.5。"
            }
        }
        if let rawPreset = environment["TATWO_ULTRAWORK_CHAT_PERMISSION_PRESET"],
           let preset = TatwoPermissionPreset(rawValue: rawPreset) {
            self.permissionPreset = preset
            if let mapped = preset.codexSandboxMode {
                self.sandboxMode = mapped
            }
        }
        if let rawEffort = environment["TATWO_ULTRAWORK_CHAT_REASONING_EFFORT"],
           let effort = TatwoCodexReasoningEffort(rawValue: rawEffort),
           routeChoice.allowedEfforts.contains(effort) {
            self.selectedEffort = effort
        }
        applyExportOnlyLoopOverride(environment: environment)
        Self.automationInstance = self
        if self.defersColdStartHydration {
            coldStartHydrationState = .notScheduled
        } else {
            do {
                _ = try store.migrateToUnifiedLedger()
            } catch {
                fputs(
                    "tatwo_unified_session_migration_failed=\(TatwoPrivacyRedactor.redacted(error.localizedDescription))\n",
                    stderr
                )
            }
            reconcileColdStartTranscriptOrphans()
            restoreDurableCancellationLock()
            if self.coldStartFixtureRequested {
                isApplyingInitialStorePayload = true
                installChatTranscriptFixtureIfRequested(
                    environment: environment)
                isApplyingInitialStorePayload = false
                isLoadingStore = false
                coldStartHydrationState = .completed
            } else {
                coldStartHydrationState = .loadingStore
                do {
                    let payload = try Self.loadInitialStorePayload(
                        environment: environment,
                        store: store,
                        workOSBindingMutationIntentStore:
                            workOSBindingMutationIntentStore,
                        composerDraftStore: composerDraftStore,
                        codexAppStateBridge: codexAppStateBridge,
                        preferenceStore: preferenceStore,
                        pluginRegistryStore: pluginRegistryStore,
                        goalRunStore: goalRunStore,
                        codexMirrorCacheRootURL: codexMirrorCacheRootURL)
                    isApplyingInitialStorePayload = true
                    applyInitialStoreLoad(
                        payload,
                        environment: environment)
                    isApplyingInitialStorePayload = false
                    isLoadingStore = false
                    coldStartHydrationState = .completed
                } catch {
                    isApplyingInitialStorePayload = false
                    isLoadingStore = false
                    coldStartHydrationState = .failed(
                        reason: "initial-store-load-failed:"
                            + TatwoPrivacyRedactor.redacted(
                                error.localizedDescription))
                }
            }
        }
        if let rawPrompt = environment["TATWO_ULTRAWORK_CHAT_PROMPT"] {
            self.prompt = rawPrompt
        }
        ChatTranscriptPerformanceCacheCoordinator
            .activateMemoryPressureMonitoring()
        transcriptPerformanceCacheResetCancellable =
            NotificationCenter.default.publisher(
                for: ChatTranscriptPerformanceCacheCoordinator
                    .resetNotification
            )
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.transcriptProjectionCache.reset()
                    self?.assistantTranscriptCache.removeAll()
                }
            }
        refreshGatewayCooldownProjection()
        TatwoAppManagementMCP.installComputerHandler {
            [weak self] arguments in
            guard let self else {
                return TatwoMCPToolCallResult(
                    tool: "tatwo.computer.execute",
                    ok: false,
                    payload: nil,
                    error: "computer_turn_unavailable",
                    failureKind: .contract,
                    hostMutationAllowed: false)
            }
            return self.executeMCPComputerCall(arguments: arguments)
        }
        TatwoAppManagementMCP.installBrowserGrantHandler {
            [weak self] arguments in
            guard let self else {
                throw TatwoBrowserSecurityError.invalidGrant
            }
            return try self.issueBrowserAgentGrantForMCP(
                arguments: arguments)
        }
        Task { @MainActor [weak self] in
            if !completionReportFixtureActive {
                self?.refreshGitBranch()
            }
            guard self?.cliRuntimeEnabled == true else { return }
            self?.reloadCLISessions()
            if self?.mode == .cli {
                self?.ensureNativeTerminal()
            }
        }
    }

    /// loops 團隊（主導/副審/sub 模型），供收合與展開展示，不只摘要。
    struct LoopsTeamDisplay: Equatable {
        var lead: [String] = []
        var reviewer: [String] = []
        var sub: [String] = []
        var isEmpty: Bool { lead.isEmpty && reviewer.isEmpty && sub.isEmpty }
    }

    enum ThreadLocation {
        case standalone(Int)
        case project(projectIndex: Int, threadIndex: Int)
    }

    struct PromptCollaborationIntent {
        var mode: WorkModeID?
        var primaryModelID: String?
        var secondaryModelID: String?
        var preserveSingleRouteID: String?
    }

    struct PromptModelMention {
        let modelID: String
        let range: Range<String.Index>
    }

    static let confirmedPlanComputerHostBindingBlocker =
        "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
        + " blocker_class=binding_failed"
        + " authority_source=app_mcp_runtime"

    static let confirmedPlanComputerHostApprovalBlocker =
        "Computer Host 尚未就緒：執行授權建立失敗。"
        + " blocker_class=approval_failed"
        + " authority_source=computer_host_approval"

    /// 匯出快照時填進終端窗格的假轉錄。帶 SGR 色碼，讓彩字在 PNG 上看得出來。
    static let exportCLITabFixtureTranscript = """
    \u{1B}[36mtatwo\u{1B}[0m ~ % ls
    \u{1B}[34mApps\u{1B}[0m  \u{1B}[34mPackages\u{1B}[0m  \u{1B}[34mTools\u{1B}[0m  Package.swift  README.md
    \u{1B}[36mtatwo\u{1B}[0m ~ % swift build
    \u{1B}[32mBuild complete!\u{1B}[0m
    \u{1B}[36mtatwo\u{1B}[0m ~ %
    """

    struct CurrentSessionThreadTarget {
        let projectID: UUID?
        let threadID: UUID
    }

    enum CurrentSessionAttachResult {
        case notApplicable
        case attached
        case quarantined
        /// 2026-08-21 使用者裁決「每個對話各自一個 Work OS session」：
        /// 磁碟上的 current-session 指標屬於**另一個** Chat row。這一列
        /// 只是「尚未持有 session」，不是完整性事故——它可以自建自己的
        /// Goal。舊行為把這種情況一律隔離，等於開了第二個 ultrawork
        /// 對話就被永久鎖死（使用者實機撞到）。
        case ownedByAnotherThread

        /// 這一列沒有接上 current-session，但也沒有事故：selection 時
        /// 應照自己的 thread 綁定投影 Work OS 狀態。
        var allowsLocalWorkOSStateProjection: Bool {
            switch self {
            case .notApplicable, .ownedByAnotherThread: return true
            case .attached, .quarantined: return false
            }
        }
    }

    struct WorkOSBindingIdentity: Equatable {
        let contractID: String
        let goalID: String
    }

    enum CurrentSessionRebindPolicy {
        case ordinary
        case confirmedGoalRevision(
            expectedPredecessor: WorkOSBindingIdentity)

        var expectedRevisionPredecessor: WorkOSBindingIdentity? {
            guard case .confirmedGoalRevision(let expected) = self else {
                return nil
            }
            return expected
        }

        var isConfirmedGoalRevision: Bool {
            guard case .confirmedGoalRevision = self else { return false }
            return true
        }
    }

    enum ExplicitTerminalCurrentSessionRecoveryResult {
        case notApplicable
        case recovered
        case quarantined
    }

    nonisolated static let canonicalNativeDevelopmentRouteBinding =
        WorkOSRouteBindingOverride(
            primaryModelID:
                TatwoNativeDevelopmentDispatchCoordinator.solModelID,
            secondaryModelID: "opus-5")

    nonisolated static let
        canonicalFableGrokNativeDevelopmentRouteBinding =
            WorkOSRouteBindingOverride(
                primaryModelID: "fable-5",
                secondaryModelID: "grok-build")

    struct RuntimeWorkspaceResolution {
        let url: URL
        let skipGitRepoCheck: Bool
    }

    deinit {
        activeGoalTimer?.invalidate()
        codexMirrorLoadTask?.cancel()
        nativeTerminal?.terminate()
        nativeRunner.terminate()
        miniMaxRunner.terminate()
        runner.terminate()
    }
}

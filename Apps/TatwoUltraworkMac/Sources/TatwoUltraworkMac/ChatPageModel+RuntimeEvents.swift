import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    func resolvedRuntimeWorkspace() -> RuntimeWorkspaceResolution {
        if mode == .chat, isSelectedThreadStandalone {
            if let configuredChatWorkdirOverride {
                let configured = URL(fileURLWithPath: configuredChatWorkdirOverride)
                    .standardizedFileURL
                if !Self.isUnsafeChatWorkspaceRoot(configured) {
                    return RuntimeWorkspaceResolution(
                        url: configured,
                        skipGitRepoCheck: !Self.looksLikeGitWorkTree(configured))
                }
            }
            let fallback = Self.safeChatWorkspaceURL()
            Self.ensureDirectoryExists(fallback)
            return RuntimeWorkspaceResolution(url: fallback, skipGitRepoCheck: true)
        }

        let rawPath = (mode == .chat ? (selectedThreadProject?.workdir ?? workspacePath) : workspacePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatePath = rawPath.isEmpty ? FileManager.default.currentDirectoryPath : rawPath
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL

        guard mode == .chat else {
            return RuntimeWorkspaceResolution(url: candidate, skipGitRepoCheck: false)
        }

        guard !Self.isUnsafeChatWorkspaceRoot(candidate) else {
            let fallback = Self.safeChatWorkspaceURL()
            Self.ensureDirectoryExists(fallback)
            return RuntimeWorkspaceResolution(url: fallback, skipGitRepoCheck: true)
        }

        return RuntimeWorkspaceResolution(
            url: candidate,
            skipGitRepoCheck: !Self.looksLikeGitWorkTree(candidate))
    }

    private static func isUnsafeChatWorkspaceRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path == "/"
            || path == "/private"
            || path == "/System"
            || path == "/Users"
            || path == "/Volumes"
            || path == home
    }

    private static func looksLikeGitWorkTree(_ url: URL) -> Bool {
        let fm = FileManager.default
        var current = url.standardizedFileURL
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
    }

    nonisolated static func safeChatWorkspaceURL() -> URL {
        TatwoRuntimeLayout.applicationSupportRoot()
            .appendingPathComponent("chat-workspace", isDirectory: true)
    }

    private static func ensureDirectoryExists(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func isLikelyImagePath(_ path: String) -> Bool {
        TatwoImageAssetStore.isImageCandidatePath(path)
    }

    static func gatewayDirectAdapterScriptURL() -> URL {
        Bundle.module.url(
            forResource: "tatwo-direct-gateway-chat",
            withExtension: "mjs"
        ) ?? Bundle.module.resourceURL!
            .appendingPathComponent("tatwo-direct-gateway-chat.mjs")
    }

    static func computerHostMCPAdapterScriptURL() -> URL {
        Bundle.module.url(
            forResource: "tatwo-computer-mcp",
            withExtension: "mjs"
        ) ?? Bundle.module.resourceURL!
            .appendingPathComponent("tatwo-computer-mcp.mjs")
    }

    static func appManagementMCPAdapterScriptURL() -> URL {
        Bundle.module.url(
            forResource: "tatwo-app-mcp",
            withExtension: "mjs"
        ) ?? Bundle.module.resourceURL!
            .appendingPathComponent("tatwo-app-mcp.mjs")
    }

    // Receipt-only privacy projection. Runtime Claude prompts must receive the
    // real absolute image path through TatwoChatCommandPlanner plus --add-dir;
    // feeding this redacted value back into a CLI prompt makes the image unreadable.
    private static func claudeAttachmentMention(for path: String, relativeTo cwd: URL) -> String {
        let fileURL = URL(fileURLWithPath: path)
        let cwdPath = cwd.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath == cwdPath {
            return "@."
        }
        let prefix = cwdPath.hasSuffix("/") ? cwdPath : cwdPath + "/"
        if filePath.hasPrefix(prefix) {
            return "@" + String(filePath.dropFirst(prefix.count))
        }
        return "@" + redactedPath(filePath)
    }

    func appendRound18ClaudeRouteReceipt(command: ChatCLICommand) {
        guard command.engine == .claude else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let attachmentMentions = droppedPaths
            .filter(Self.isLikelyImagePath)
            .map { Self.claudeAttachmentMention(for: $0, relativeTo: command.workingDirectory) }
        let promptMarker = attachmentMentions.isEmpty ? "<turn redacted>" : "<turn redacted; image attachments \(attachmentMentions.joined(separator: ", "))>"
        let argvWithoutPrompt = ([command.executable] + command.arguments.dropLast()).joined(separator: " ")
        let spawnLine = Self.redactedPath(argvWithoutPrompt) + " " + promptMarker + (command.standardInputFromDevNull ? " < /dev/null" : "")
        let block = """

        ## Claude route spawn receipt

        - timestamp: \(now)
        - contractID: `contract-xl-ui-ux-e1e8071d82db`
        - mode: `\(mode.rawValue)`
        - selectedModel: `\(selectedModel)`
        - engine: `Claude`
        - workingDirectory: `\(Self.redactedPath(command.workingDirectory.path))`
        - spawnCommand: `\(spawnLine)`
        - imagePathForwarding: `\(attachmentMentions.isEmpty ? "none" : attachmentMentions.joined(separator: ", "))`
        - privacy: user turn body redacted; local image paths are repo-relative when possible.

        """
        do {
            let header = """
            # Claude route spawn journal

            - storage: TATWO App Support
            - privacy: prompt bodies are redacted.

            """
            try ChatRouteReceiptJournal().append(
                header: header,
                entry: block)
            lastClaudeRouteReceiptStatus =
                "Claude route journal 已寫入 App Support"
        } catch {
            lastClaudeRouteReceiptStatus =
                "route journal 寫入失敗：\(error.localizedDescription)"
        }
    }


    func consumeLegacyRuntimeEvent(
        _ event: ChatCLIEvent,
        runID: String
    ) {
        withTurnRuntime(for: runID) {
            handle(event, runID: runID)
        }
    }

    func consumeNativeRuntimeEvent(
        _ event: ChatCLIEvent,
        runID: String
    ) {
        withTurnRuntime(for: runID) {
            handleNative(event, runID: runID)
        }
    }

    func consumeBuiltInDirectRuntimeEvent(
        _ event: ChatCLIEvent,
        runID: String
    ) {
        withTurnRuntime(for: runID) {
            handleBuiltInDirect(event, runID: runID)
        }
    }

    private func handle(_ event: ChatCLIEvent, runID: String) {
        switch event {
        case .exit, .failure, .runtimeFailure:
            break
        default:
            guard activeTurnLifecycle?.shouldAcceptNonTerminalEvent(runID: runID) == true else {
                return
            }
        }
        switch event {
        case .output(let text):
            if let intent = TatwoComputerToolIntentParser.parse(text) {
                let visibleText = TatwoComputerToolIntentParser.removingIntent(from: text)
                if !visibleText.isEmpty {
                    appendPlanAwareAssistantOutput(visibleText)
                    recordLiveWork(status: "writing|\(Self.activityDetail(from: visibleText) ?? "模型回覆")")
                }
                switch computerHostBindingSlot.binding(for: runID)?
                    .decision.route ?? .none
                {
                case .embeddedIntent:
                    executeComputerIntent(intent, runID: runID)
                case .mcp:
                    appendMessage(ChatMessage(
                        role: .system,
                        text: "Computer Host 未執行：本輪已鎖定 MCP 路徑，忽略 legacy embedded intent。",
                        status: "computer route blocked",
                        eventKind: .failure))
                case .none:
                    appendMessage(ChatMessage(
                        role: .system,
                        text: "Computer Host 未執行：本輪沒有已授權的 Computer Host 路徑。",
                        status: "computer route blocked",
                        eventKind: .failure))
                }
            } else {
                let projection =
                    ChatRuntimeTextHumanizer.projectedOutput(text)
                let alreadyVisible = projection.collapsedDiagnostic
                    && activeAssistantID.flatMap { id in
                        messages.first(where: { $0.id == id })?.text
                    }?.contains(projection.text) == true
                if !alreadyVisible {
                    appendPlanAwareAssistantOutput(projection.text)
                }
                if projection.isBlocker {
                    updateActiveStatus("blocked")
                }
                recordLiveWork(
                    status: projection.collapsedDiagnostic
                        ? "route-blocked|詳細技術訊息已收合"
                        : "writing|\(Self.activityDetail(from: text) ?? "模型回覆")")
            }
        case .raw(let text):
            if let request = TatwoChatMCPApprovalRequest(
                diagnosticText: text)
            {
                // 工程 B：訊息帶 status "tool approval required"，ChatBubble
                // 依此渲染「允許此工具」一鍵放行鈕（見 allowMCPTool(named:)）。
                appendMessage(ChatMessage(
                    role: .system,
                    text: request.userMessage,
                    status: "tool approval required",
                    eventKind: .failure))
                updateActiveStatus("blocked")
                recordLiveWork(
                    status: "route-blocked|等待工具授權")
                return
            }
            // Raw stdout belongs to the legacy CLI terminal surface. Chat-mode
            // routes are expected to be structured JSON; if a non-CLI route
            // leaks raw process text, keep the transcript Codex-like and show
            // only compact activity/failure state instead of dumping terminal
            // noise into the conversation.
            if mode == .cli {
                appendAssistant(text + "\n", kind: .raw)
            } else {
                updateActiveActivity(status: "working")
                recordLiveWork(status: "working|接收結構化工作事件")
            }
        case .diagnostic:
            updateActiveActivity(status: "checking")
            recordLiveWork(status: "checking")
        case .toolUse(let activity):
            if let context = activeSingleModelGoalDispatch,
               context.runID == runID,
               !context.observedToolUse
            {
                activeSingleModelGoalDispatch = (
                    runID: context.runID,
                    contractID: context.contractID,
                    dispatchID: context.dispatchID,
                    runnerInstanceID: context.runnerInstanceID,
                    observedToolUse: true)
            }
            let status = Self.compactToolUseStatus(from: activity.text, rawType: activity.rawType)
            updateActiveActivity(status: status)
            recordLiveWork(status: status)
        case .thinking(let activity):
            let status = "thinking"
            updateActiveActivity(status: status)
            recordLiveWork(status: status)
            appendThinkingTimeline(runID: runID)
            recordTranscriptReasoning(activity, runID: runID)
        case .reconnectProgress(let progress):
            let attempt = "\(progress.attempt)/\(progress.maximumAttempts)"
            updateActiveActivity(
                status: "reconnecting|連線中斷，正在續接 \(attempt)")
            recordLiveWork(
                status: "reconnecting|正在重連 \(attempt)")
        case .activity(let activity):
            guard activity.turnID == activeAssistantID else { return }
            chatActivityFeedReducer.reduce(activity)
            chatActivityFeed = chatActivityFeedReducer.feed
            if recordTranscriptActivity(activity, runID: runID) {
                demoteEphemeralActivityPlaceholder(turnID: activity.turnID)
            }
        case .session(let engine, let id):
            let activeRuntimeAdapter = activeAssistantID.flatMap { assistantID in
                messages.first(where: { $0.id == assistantID })?
                    .runtimeAdapterID
            }.flatMap(TatwoChatRuntimeAdapter.init(rawValue:))
            let sessionID: String?
            if activeRuntimeAdapter == .grokCLI {
                sessionID = TatwoChatCommandPlanner
                    .sanitizedGrokResumeSessionID(id)
            } else {
                switch engine {
                case .codex:
                    sessionID = TatwoChatCommandPlanner.sanitizedCodexResumeSessionID(id)
                case .claude:
                    sessionID = TatwoChatCommandPlanner.sanitizedClaudeResumeSessionID(id)
                }
            }
            guard let id = sessionID else {
                updateActiveActivity(status: "thinking")
                recordLiveWork(status: "thinking")
                return
            }
            if activeRuntimeAdapter != .grokCLI {
                switch engine {
                case .codex: codexSessionID = id
                case .claude: claudeSessionID = id
                }
            }
            updateSelectedThreadPreview(
                selectedThread?.lastPreview ?? "session resumed",
                sessionID: id,
                sessionEngine: engine,
                runtimeAdapter: activeRuntimeAdapter)
            recordLiveWork(status: "session|\(engine == .codex ? "Codex session" : "Claude session")")
        case .gatewayContinuation(let receipt):
            guard var continuation = activeGatewayContinuationTurn,
                  continuation.runID == runID,
                  receipt.promotableHandle(
                    matching: continuation.request) != nil
            else {
                return
            }
            if let existing = continuation.receipt,
               existing != receipt
            {
                continuation.receipt = nil
            } else {
                continuation.receipt = receipt
            }
            activeGatewayContinuationTurn = continuation
        case .nativeTerminalReceipt:
            // Native-agent terminal receipts are consumed only by
            // `handleNative`; legacy CLI routes must not project them.
            break
        case .exit(let status):
            let executionEvidenceMissing =
                status == 0
                && activeSingleModelGoalDispatch?.runID == runID
                && activeSingleModelGoalDispatch?.observedToolUse == false
            guard settleSingleModelGoalDispatch(
                runID: runID,
                succeeded: status == 0 && !executionEvidenceMissing,
                errorCode: executionEvidenceMissing
                    ? "operational_failure"
                    : nil,
                errorMessage: executionEvidenceMissing
                    ? "Single-model runner exited successfully without tool execution evidence"
                    : status == 0
                        ? nil
                        : "Single-model runner exited with status \(status)")
            else { return }
            let formalStatus: Int32 =
                executionEvidenceMissing ? 1 : status
            guard acceptFormalTerminalEvent(
                runID: runID,
                status: formalStatus)
            else { return }
            if executionEvidenceMissing {
                finishFailureTurn(
                    runID: runID,
                    message:
                        "執行未完成：本輪沒有工具執行證據，Goal 保持未完成。",
                    activityFallback: "未執行")
            } else {
                finishExitedTurn(status: status)
            }
        case .failure(let message):
            if beginGatewayStaleHandleFallbackIfNeeded(
                message: message,
                runID: runID)
            {
                return
            }
            guard let status = formalRunnerStatus(runID: runID) else { return }
            guard settleSingleModelGoalDispatch(
                runID: runID,
                succeeded: false,
                errorMessage: message)
            else { return }
            guard acceptFormalTerminalEvent(runID: runID, status: status) else { return }
            finishFailureTurn(
                message: "啟動失敗：\(message)",
                activityFallback: "啟動失敗")
        case .runtimeFailure(let message):
            if consumeBlockedTerminalFailureSignal(
                runID: runID,
                eventMessage: message)
            {
                return
            }
            if beginGatewayStaleHandleFallbackIfNeeded(
                message: message,
                runID: runID)
            {
                return
            }
            guard let status = formalRunnerStatus(runID: runID) else { return }
            guard settleSingleModelGoalDispatch(
                runID: runID,
                succeeded: false,
                errorMessage: message)
            else { return }
            guard acceptFormalTerminalEvent(runID: runID, status: status) else { return }
            if userStopRequested {
                finishExitedTurn(status: status)
            } else {
                finishFailureTurn(
                    message: message,
                    activityFallback: "執行失敗")
            }
        }
    }

    private func handleNative(_ event: ChatCLIEvent, runID: String) {
        guard activeTurnLifecycle?.runID == runID else { return }
        switch event {
        case .output(let text):
            appendPlanAwareAssistantOutput(text)
            recordLiveWork(
                status: "writing|\(Self.activityDetail(from: text) ?? "模型回覆")")
        case .toolUse(let activity):
            let status = Self.compactToolUseStatus(
                from: activity.text, rawType: activity.rawType)
            updateActiveActivity(status: status)
            recordLiveWork(status: status)
        case .thinking(let activity):
            let status = "thinking"
            updateActiveActivity(status: status)
            recordLiveWork(status: status)
            appendThinkingTimeline(runID: runID)
            recordTranscriptReasoning(activity, runID: runID)
        case .nativeTerminalReceipt(let receiptID, let outputRef):
            guard !receiptID.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty,
                !outputRef.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
            else { return }
            nativeTerminalReceipts[runID] = (
                receiptID: receiptID,
                outputRef: outputRef)
        case .exit(let status):
            if status == 0,
               activeNativeDevelopmentDispatch?.runID == runID,
               nativeTerminalReceipts[runID] == nil
            {
                guard settleNativeDevelopmentDispatch(
                    runID: runID,
                    succeeded: false,
                    errorCode: "native_terminal_receipt_missing",
                    message:
                        "Native agent exited successfully without a terminal receipt")
                else { return }
                guard acceptFormalTerminalEvent(runID: runID, status: 1)
                else { return }
                finishFailureTurn(
                    runID: runID,
                    message:
                        "Native agent did not produce a verifiable terminal receipt",
                    activityFallback: "缺少完成收據")
                return
            }
            guard settleNativeDevelopmentDispatch(
                runID: runID,
                succeeded: status == 0,
                errorCode: status == 0
                    ? nil : (status == 130
                        ? "native_cancelled" : "native_exit_\(status)"),
                message: status == 0
                    ? nil : "Native agent exited with status \(status)")
            else { return }
            guard acceptFormalTerminalEvent(runID: runID, status: status)
            else { return }
            finishExitedTurn(status: status)
        case .failure(let message), .runtimeFailure(let message):
            guard settleNativeDevelopmentDispatch(
                runID: runID,
                succeeded: false,
                errorCode: nativeDevelopmentFailureCode(message: message),
                message: message)
            else { return }
            finishFailureTurn(
                runID: runID,
                message: message,
                activityFallback: "Native agent 執行失敗")
        case .diagnostic:
            updateActiveActivity(status: "checking")
        case .activity(let activity):
            guard activity.turnID == activeAssistantID else { return }
            chatActivityFeedReducer.reduce(activity)
            chatActivityFeed = chatActivityFeedReducer.feed
        case .raw, .reconnectProgress, .session, .gatewayContinuation:
            break
        }
    }

    private func handleBuiltInDirect(
        _ event: ChatCLIEvent,
        runID: String
    ) {
        switch event {
        case .exit, .failure, .runtimeFailure:
            break
        default:
            guard activeTurnLifecycle?
                .shouldAcceptNonTerminalEvent(runID: runID) == true
            else { return }
        }
        switch event {
        case .output(let text):
            if let intent = TatwoComputerToolIntentParser.parse(text) {
                let visibleText =
                    TatwoComputerToolIntentParser.removingIntent(from: text)
                if !visibleText.isEmpty {
                    appendAssistant(visibleText, kind: .message)
                }
                if computerHostBindingSlot.binding(for: runID)?
                    .decision.route == .embeddedIntent
                {
                    executeComputerIntent(intent, runID: runID)
                } else {
                    appendMessage(ChatMessage(
                        role: .system,
                        text: "Computer Host 未執行：本輪沒有已授權的 embedded-intent 路徑。",
                        status: "computer route blocked",
                        eventKind: .failure))
                }
            } else {
                appendAssistant(text, kind: .message)
            }
            recordLiveWork(
                status:
                    "writing|\(Self.activityDetail(from: text) ?? "模型回覆")")
        case .diagnostic:
            updateActiveActivity(status: "checking")
            recordLiveWork(status: "checking")
        case .exit(let status):
            guard acceptFormalTerminalEvent(
                runID: runID,
                status: status)
            else { return }
            finishExitedTurn(status: status)
        case .failure(let message), .runtimeFailure(let message):
            guard acceptFormalTerminalEvent(
                runID: runID,
                status: 1)
            else { return }
            finishFailureTurn(
                runID: runID,
                message: message,
                activityFallback: "執行失敗")
        case .raw, .toolUse, .thinking, .reconnectProgress,
             .activity, .session, .gatewayContinuation,
             .nativeTerminalReceipt:
            break
        }
    }

    private func nativeDevelopmentFailureCode(message: String) -> String {
        let exactCode =
            TatwoNativeDevelopmentDispatchCoordinator
                .grokDevAttestationUnverifiedErrorCode
        let normalized = message.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard normalized
            == "Governed development session failed: \(exactCode)"
        else {
            return "native_runtime_failure"
        }
        return exactCode
    }

    @discardableResult
    private func settleSingleModelGoalDispatch(
        runID: String,
        succeeded: Bool,
        errorCode: String? = nil,
        errorMessage: String?
    ) -> Bool {
        guard let context = activeSingleModelGoalDispatch,
              context.runID == runID
        else { return true }
        do {
            if succeeded {
                let evidenceID =
                    "chat-turn-\(activeAssistantID ?? runID)"
                _ = try TatwoGoalRunDispatchLifecycle.update(
                    contractID: context.contractID,
                    dispatchID: context.dispatchID,
                    status: .completed,
                    receiptID: evidenceID,
                    outputRef: "tatwo-chat://\(evidenceID)",
                    goalStore: goalRunStore,
                    dispatchRegistry: dispatchRegistry)
                _ = try TatwoGoalRunDispatchLifecycle.finalize(
                    contractID: context.contractID,
                    goalStore: goalRunStore,
                    dispatchRegistry: dispatchRegistry)
                convergeSingleModelCompletedCycleIfNeeded(
                    contractID: context.contractID,
                    evidenceID: evidenceID)
            } else {
                _ = try TatwoGoalRunDispatchLifecycle.update(
                    contractID: context.contractID,
                    dispatchID: context.dispatchID,
                    status: .failed,
                    failureClass: .terminal,
                    errorCode:
                        errorCode ?? "single_model_runner_failed",
                    errorMessage:
                        errorMessage ?? "Single-model runner failed",
                    goalStore: goalRunStore,
                    dispatchRegistry: dispatchRegistry)
            }
            clearSingleModelGoalDispatchRuntimeState(
                dispatchID: context.dispatchID,
                preserveRunnerStartReceipt: true)
            refreshSelectedWorkOSState(contractID: context.contractID)
            return true
        } catch {
            activeSingleModelGoalDispatch = nil
            quarantineSelectedWorkOSState(
                "單模型 Goal ledger 更新失敗；不可發布成功："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func convergeSingleModelCompletedCycleIfNeeded(
        contractID: String,
        evidenceID: String? = nil
    ) -> Bool {
        let trimmedContractID = contractID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmedContractID.isEmpty else { return false }
        do {
            let goal = try goalRunStore.requireIssuedContract(
                trimmedContractID)
            guard goal.mode == .s,
                  goal.status == .awaitingNextCycle,
                  goal.statusReason?.hasPrefix("dispatch_cycle_finalized:") == true
            else { return false }
            let contract = try WorkOSFactory.storedContractProjection(
                contractID: trimmedContractID,
                fallbackMode: goal.mode,
                fallbackScenarioProfileID: goal.scenario,
                fallbackObjective: goal.objective,
                scenarioBook: scenarioConfigBook,
                store: goalRunStore)
            let run = try dispatchRegistry.run(
                forContractID: trimmedContractID)
            let completedLead = run?.records.first {
                $0.status == .completed && $0.identity == .lead
            }
            let sealID = goal.latestDispatchCycleSealID
                ?? run?.sealID
                ?? ""
            let cycleEpoch = goal.latestDispatchCycleEpoch ?? 1
            let resolvedEvidenceID =
                evidenceID
                ?? completedLead?.receiptID
                ?? completedLead?.id
                ?? "cycle-\(cycleEpoch)"
            let issued = Dictionary(
                uniqueKeysWithValues: contract.receiptRequirements.map {
                    ($0.id, $0)
                })
            var evidence: [(requirementID: String, receiptID: String)] = []
            if issued["contract-id"] != nil {
                evidence.append(("contract-id", contract.contractID))
            }
            if issued["mode-budget"] != nil {
                evidence.append((
                    "mode-budget",
                    "mode:\(goal.mode.rawValue):scenario:\(goal.scenario):epoch:\(cycleEpoch)"
                ))
            }
            if issued["identity-bindings"] != nil,
               let digest = goal.issuedIdentityBindingsDigest,
               !digest.isEmpty
            {
                evidence.append((
                    "identity-bindings",
                    digest
                ))
            }
            if issued["goal-cycle-seal"] != nil, !sealID.isEmpty {
                evidence.append(("goal-cycle-seal", sealID))
            }
            if issued["plan-loop-goal-mainline"] != nil {
                evidence.append((
                    "plan-loop-goal-mainline",
                    "\(contract.mainlineLoop.id):\(completedLead?.id ?? resolvedEvidenceID)"
                ))
            }
            if issued["plan-loop-goal-branch"] != nil,
               contract.domainLoops.isEmpty
            {
                evidence.append((
                    "plan-loop-goal-branch",
                    "s-mainline-only:\(contract.contractID):no-domain-loops"
                ))
            }
            if issued["local-check"] != nil {
                evidence.append(("local-check", resolvedEvidenceID))
            }
            if issued["s-no-sub"] != nil {
                let identities = Set((run?.records ?? []).map(\.identity))
                if identities.isSubset(of: [.lead]) {
                    evidence.append((
                        "s-no-sub",
                        "s-no-sub:\(contract.contractID):seal:\(sealID)"
                    ))
                }
            }
            if issued["cleanup-inventory"] != nil {
                let inventory =
                    PostValidationCleanupInventoryFactory.noCandidateInventory(
                        runID: sealID.isEmpty ? resolvedEvidenceID : sealID,
                        validatedGoalID: contract.goalID,
                        validatedContractID: contract.contractID,
                        mustKeep: [
                            "dispatch-output:\(resolvedEvidenceID)",
                        ],
                        summary:
                            "單模型 cycle 已封存；工作產物列為 mustKeep，刪除仍需人工核准。")
                let evidenceRoot = goalRunStore.directoryURL
                    .appendingPathComponent(
                        "cycle-evidence",
                        isDirectory: true)
                    .appendingPathComponent(
                        contract.contractID,
                        isDirectory: true)
                try FileManager.default.createDirectory(
                    at: evidenceRoot,
                    withIntermediateDirectories: true)
                let markdownURL = evidenceRoot.appendingPathComponent(
                    "cleanup-inventory.md")
                try PostValidationCleanupInventoryFactory.markdownBody(
                    for: inventory
                ).write(to: markdownURL, atomically: true, encoding: .utf8)
                evidence.append((
                    "cleanup-inventory",
                    "cleanup-inventory:\(inventory.markdownSHA256)"
                ))
            }
            for item in evidence {
                guard let requirement = issued[item.requirementID],
                      requirement.requiredForPass
                else { continue }
                let result = WorkOSFactory.submitReceipt(
                    goalID: contract.goalID,
                    contractID: contract.contractID,
                    loopID: contract.mainlineLoop.id,
                    receiptID: item.receiptID,
                    receiptKind: requirement.kind,
                    satisfiesRequirementID: requirement.id,
                    store: goalRunStore)
                if !result.ok {
                    fputs(
                        "tatwo_single_model_receipt_bridge_failed=\(requirement.id):\(result.decision.code)\n",
                        stderr)
                }
            }
            _ = try WorkOSFactory.closeGoal(
                goalID: contract.goalID,
                contractID: contract.contractID,
                mode: goal.mode,
                scenarioProfileID: goal.scenario,
                objective: goal.objective,
                suppliedReceiptIDs: [],
                store: goalRunStore,
                dispatchRegistry: dispatchRegistry)
            return true
        } catch {
            fputs(
                "tatwo_single_model_goal_judge_failed=\(TatwoPrivacyRedactor.redacted(error.localizedDescription))\n",
                stderr)
            return false
        }
    }

    @discardableResult
    private func settleNativeDevelopmentDispatch(
        runID: String,
        succeeded: Bool,
        errorCode: String?,
        message: String?
    ) -> Bool {
        guard let context = activeNativeDevelopmentDispatch,
              context.runID == runID
        else { return true }
        do {
            if succeeded {
                guard let terminal = nativeTerminalReceipts[runID] else {
                    throw TatwoNativeDevelopmentDispatchSettlementError
                        .terminalReceiptMissing
                }
                let completed =
                    try TatwoNativeDevelopmentDispatchCoordinator.complete(
                    contractID: context.contractID,
                    dispatchID: context.dispatchID,
                    receiptID: terminal.receiptID,
                    outputRef: terminal.outputRef,
                    goalStore: goalRunStore,
                    dispatchRegistry: dispatchRegistry)
                submitNativeDevelopmentExecutionReceipts(
                    context: context,
                    terminal: terminal,
                    completedDispatch: completed)
                _ = sealCompletedNativeDevelopmentCycleIfReady()
            } else {
                _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
                    contractID: context.contractID,
                    dispatchID: context.dispatchID,
                    errorCode: errorCode ?? "native_runtime_failure",
                    message: message ?? "Native agent failed",
                    goalStore: goalRunStore,
                    dispatchRegistry: dispatchRegistry)
            }
            nativeTerminalReceipts.removeValue(forKey: runID)
            activeNativeDevelopmentDispatch = nil
            refreshSelectedWorkOSState(contractID: context.contractID)
            if succeeded,
               selectedWorkOSContract?.contractID == context.contractID,
               selectedWorkOSContract?.scenario
                == TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
               TatwoGatewayDispatchCatalog.normalize(context.modelID)
                == TatwoGatewayDispatchCatalog.normalize("fable-5")
            {
                pendingNativeDevelopmentAutoFollowup = (
                    contractID: context.contractID,
                    completedModelID: context.modelID)
            } else if !succeeded {
                pendingNativeDevelopmentAutoFollowup = nil
            }
            return true
        } catch {
            nativeTerminalReceipts.removeValue(forKey: runID)
            activeNativeDevelopmentDispatch = nil
            quarantineSelectedWorkOSState(
                "Native dispatch ledger 更新失敗；不可發布成功："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
            finishFailureTurn(
                runID: runID,
                message: "Native dispatch ledger reconciliation required",
                activityFallback: "Ledger 更新失敗")
            return false
        }
    }

    /// M4b receipt bridge: only real dispatch/artifact evidence may satisfy
    /// these four exact requirements. Human/plan/contract/cycle semantics stay
    /// outside the bridge.
    private func submitNativeDevelopmentExecutionReceipts(
        context: (
            runID: String,
            contractID: String,
            dispatchID: String,
            modelID: String
        ),
        terminal: (receiptID: String, outputRef: String),
        completedDispatch: TatwoDispatchRecord
    ) {
        lastNativeDevelopmentReceiptBridgeFailure = nil
        guard completedDispatch.status == .completed,
              completedDispatch.id == context.dispatchID,
              completedDispatch.contractID == context.contractID,
              completedDispatch.receiptID == terminal.receiptID,
              completedDispatch.outputRef == terminal.outputRef
        else {
            recordNativeDevelopmentReceiptBridgeFailure(
                "completed_dispatch_evidence_mismatch")
            return
        }
        let contract: TatwoWorkOSContractV1
        do {
            contract = try WorkOSFactory.storedContractProjection(
                contractID: context.contractID,
                fallbackMode: .xxl,
                fallbackScenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLSolOpusScenarioID,
                store: goalRunStore)
        } catch {
            recordNativeDevelopmentReceiptBridgeFailure(
                "issued_contract_projection_failed:"
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
            return
        }
        let issuedRequirements = Dictionary(
            uniqueKeysWithValues: contract.receiptRequirements.map {
                ($0.id, $0)
            })
        var evidence: [(requirementID: String, receiptID: String)] = [
            (
                requirementID: "dispatch-liveness",
                receiptID: terminal.receiptID
            ),
            (
                requirementID: "goal-tracker",
                receiptID: completedDispatch.id
            ),
        ]
        if let artifactEvidence = nativeDevelopmentEvidenceArtifact(
            at: terminal.outputRef,
            context: context,
            terminalReceiptID: terminal.receiptID
        ) {
            if artifactEvidence.provesSandbox {
                evidence.append(
                    (
                        requirementID: "sandbox",
                        receiptID: terminal.outputRef
                    ))
            }
            if artifactEvidence.provesRollback {
                evidence.append(
                    (
                        requirementID: "rollback",
                        receiptID: terminal.outputRef
                    ))
            }
        }

        for item in evidence {
            guard let requirement = issuedRequirements[item.requirementID],
                  requirement.requiredForPass
            else { continue }
            let result = nativeDevelopmentReceiptSubmitter(
                contract.goalID,
                contract.contractID,
                contract.mainlineLoop.id,
                item.receiptID,
                requirement.kind,
                requirement.id,
                goalRunStore)
            guard result.ok else {
                recordNativeDevelopmentReceiptBridgeFailure(
                    "\(requirement.id):\(result.decision.code)")
                continue
            }
        }
    }

    /// Decode and bind the exact M4a evidence artifact, then evaluate sandbox
    /// and rollback independently. A valid isolated worktree may prove sandbox
    /// even when the artifact's git/base-commit evidence cannot prove rollback.
    private func nativeDevelopmentEvidenceArtifact(
        at outputRef: String,
        context: (
            runID: String,
            contractID: String,
            dispatchID: String,
            modelID: String
        ),
        terminalReceiptID: String
    ) -> (provesSandbox: Bool, provesRollback: Bool)? {
        guard outputRef.hasPrefix("/") else { return nil }
        let artifactURL = URL(fileURLWithPath: outputRef)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: artifactURL.path),
              let data = try? Data(contentsOf: artifactURL)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let artifact = try? decoder.decode(
            GovernedDevSessionArtifactV1.self,
            from: data),
              artifact.schema == "GovernedDevSessionArtifactV1",
              artifact.runID == context.runID,
              artifact.dispatchID == context.dispatchID,
              artifact.contractID == context.contractID,
              TatwoGatewayDispatchCatalog.normalize(artifact.modelID)
                == TatwoGatewayDispatchCatalog.normalize(context.modelID),
              artifact.terminalReceiptID == terminalReceiptID
        else { return nil }
        let repositoryRoot = URL(
            fileURLWithPath: artifact.repositoryRoot,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let worktree = URL(
            fileURLWithPath: artifact.worktreePath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let worktreesRoot = repositoryRoot.appendingPathComponent(
            ".worktrees",
            isDirectory: true
        ).standardizedFileURL.path + "/"
        let repositoryGitEvidence = repositoryRoot.appendingPathComponent(
            ".git",
            isDirectory: true)
        let worktreeGitEvidence = worktree.appendingPathComponent(
            ".git",
            isDirectory: false)
        let provesSandbox =
            worktree.path != repositoryRoot.path
            && worktree.path.hasPrefix(worktreesRoot)
            && FileManager.default.fileExists(atPath: worktree.path)
        let provesRollback =
            FileManager.default.fileExists(
                atPath: repositoryGitEvidence.path)
            && FileManager.default.fileExists(
                atPath: worktreeGitEvidence.path)
            && nativeDevelopmentGitObjectIDIsValid(artifact.baseCommit)
            && artifact.preRunDigest.headCommit == artifact.baseCommit
            && nativeDevelopmentGitObjectIDIsValid(
                artifact.postRunDigest.headCommit)
            && nativeDevelopmentSHA256IsValid(
                artifact.preRunDigest.statusPorcelainSHA256)
            && nativeDevelopmentSHA256IsValid(
                artifact.postRunDigest.statusPorcelainSHA256)
        return (provesSandbox, provesRollback)
    }

    private func nativeDevelopmentGitObjectIDIsValid(
        _ value: String
    ) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy(\.isHexDigit)
    }

    private func nativeDevelopmentSHA256IsValid(
        _ value: String
    ) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private func recordNativeDevelopmentReceiptBridgeFailure(
        _ failure: String
    ) {
        let redacted = TatwoPrivacyRedactor.redacted(failure)
        lastNativeDevelopmentReceiptBridgeFailure = redacted
        fputs(
            "tatwo_native_development_receipt_bridge_failed=\(redacted)\n",
            stderr)
    }

    /// Seal only the exact required native-development lanes for the current
    /// cycle, then delegate the state transition and locking to the canonical
    /// lifecycle.
    @discardableResult
    func sealCompletedNativeDevelopmentCycleIfReady() -> Bool {
        guard let contractID = Self.normalizedNonEmpty(
            activeNativeDevelopmentDispatch?.contractID
                ?? selectedWorkOSContract?.contractID
                ?? selectedThread?.workOSContractID)
        else { return false }
        do {
            let contract = try WorkOSFactory.storedContractProjection(
                contractID: contractID,
                fallbackMode: .xxl,
                fallbackScenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLSolOpusScenarioID,
                store: goalRunStore)
            let requiredSourceSlotIDs: [String]
            switch contract.scenario {
            case TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID:
                requiredSourceSlotIDs = [
                    TatwoNativeDevelopmentDispatchCoordinator
                        .solExecutorSourceSlotID,
                ]
            case TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID:
                requiredSourceSlotIDs = [
                    TatwoNativeDevelopmentDispatchCoordinator
                        .fableExecutorSourceSlotID,
                    TatwoNativeDevelopmentDispatchCoordinator
                        .grokExecutorSourceSlotID,
                ]
            default:
                return false
            }
            guard let run = try dispatchRegistry.run(
                forContractID: contractID)
            else { return false }
            let cycleEpoch = run.activeCycleEpoch ?? 1
            let cycleRecords = run.records.filter {
                $0.resolvedCycleEpoch == cycleEpoch
            }
            guard !cycleRecords.isEmpty,
                  cycleRecords.allSatisfy({ $0.status == .completed }),
                  requiredSourceSlotIDs.allSatisfy({ sourceSlotID in
                      let latest = cycleRecords
                          .filter { $0.sourceSlotID == sourceSlotID }
                          .max {
                              if $0.resolvedAttempt != $1.resolvedAttempt {
                                  return $0.resolvedAttempt
                                      < $1.resolvedAttempt
                              }
                              if $0.updatedAt != $1.updatedAt {
                                  return $0.updatedAt < $1.updatedAt
                              }
                              return $0.id < $1.id
                          }
                      return latest?.status == .completed
                  })
            else {
                if cycleRecords.contains(where: {
                    $0.sourceSlotID
                        == TatwoNativeDevelopmentDispatchCoordinator
                            .grokExecutorSourceSlotID
                        && $0.status == .failed
                        && $0.failureReceipt?.errorCode
                            == TatwoNativeDevelopmentDispatchCoordinator
                                .grokDevAttestationUnverifiedErrorCode
                }) {
                    fputs(
                        "tatwo_native_development_cycle_not_sealed="
                            + TatwoNativeDevelopmentDispatchCoordinator
                                .grokDevAttestationUnverifiedErrorCode
                            + "\n",
                        stderr)
                }
                return false
            }
            _ = try TatwoGoalRunDispatchLifecycle.finalize(
                contractID: contractID,
                goalStore: goalRunStore,
                dispatchRegistry: dispatchRegistry)
            refreshSelectedWorkOSState(contractID: contractID)
            return true
        } catch {
            fputs(
                "tatwo_native_development_cycle_finalize_failed="
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription)
                    + "\n",
                stderr)
            return false
        }
    }

    /// 本輪 dispatch 已封存、goal 停在人門時，UI 才提供「開啟下一輪」。
    var canAdvanceNativeDevelopmentCycle: Bool {
        guard let record = selectedGoalRecord,
              record.status == .humanGate
                  || record.status == .awaitingNextCycle,
              let scenario = selectedWorkOSContract?.scenario
        else { return false }
        return [
            TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID,
            TatwoScenarioConfigDefaults.nativeDevelopmentXXLFableGrokScenarioID,
        ].contains(scenario)
    }

    /// Human/UI callable boundary for opening the next immutable dispatch
    /// cycle. Settlement never invokes this method automatically.
    @discardableResult
    func advanceNativeDevelopmentCycle() -> Bool {
        guard let contractID = Self.normalizedNonEmpty(
            selectedWorkOSContract?.contractID
                ?? selectedThread?.workOSContractID)
        else { return false }
        do {
            let contract = try WorkOSFactory.storedContractProjection(
                contractID: contractID,
                fallbackMode: .xxl,
                fallbackScenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLSolOpusScenarioID,
                store: goalRunStore)
            guard [
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
            ].contains(contract.scenario) else {
                return false
            }
            let goal = try goalRunStore.requireIssuedContract(contractID)
            guard let sealID = goal.latestDispatchCycleSealID else {
                return false
            }
            _ = try TatwoGoalRunDispatchLifecycle.advanceCycle(
                contractID: contractID,
                expectedSealID: sealID,
                goalStore: goalRunStore,
                dispatchRegistry: dispatchRegistry)
            refreshSelectedWorkOSState(contractID: contractID)
            return true
        } catch {
            fputs(
                "tatwo_native_development_cycle_advance_failed="
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription)
                    + "\n",
                stderr)
            return false
        }
    }

    /// A real wrapper exit can make the assistant turn durably terminal even
    /// while descendant convergence and runner authority remain unresolved.
    /// This consumes only the runner's matching typed signal. It never records
    /// formal runner terminal authority, resolves cancellation durability, or
    /// enables reclaim/queued work.
    @discardableResult
    func consumeBlockedTerminalFailureSignal(
        runID: String,
        eventMessage: String
    ) -> Bool {
        let diagnostics = runner.diagnosticsSnapshot
        guard let signal = diagnostics.blockedTerminalFailureSignal,
              diagnostics.lifecycleRunID == runID,
              signal.runID == runID,
              eventMessage == signal.message,
              signal.authorityRemainsBlocked,
              !signal.reclaimAllowed
        else {
            return false
        }
        guard let lifecycle = activeTurnLifecycle,
              lifecycle.runID == runID
        else {
            // The typed signal belongs to this callback but not the active UI
            // turn. Consume it as stale rather than applying it elsewhere.
            return true
        }
        let idempotencyKey = signal.idempotencyKey
        guard !consumedBlockedTerminalFailureIdempotencyKeys.contains(
            idempotencyKey)
        else {
            return true
        }

        clearCancellationBlockedPresentation()
        let terminalMessage = preparedBlockedTerminalFailureAssistantMessage(
            signal.message,
            assistantID: lifecycle.assistantID)
        guard commitTranscriptTerminalMessage(terminalMessage) else {
            cancellationBlockedReason =
                "blocked-terminal-failure-persistence-failed"
            isRunning = true
            flashComposerHint(
                "Runner 已回報本輪失敗，但 canonical transcript journal 尚未落盤；聊天維持鎖定並會重試。")
            return true
        }
        consumedBlockedTerminalFailureIdempotencyKeys.insert(
            idempotencyKey)

        activeGatewayContinuationTurn = nil
        _ = streamLedger.replaceTailContent(terminalMessage.text)
        _ = try? streamLedger.promoteTail()
        activeAssistantID = nil
        cacheSelectedSessionMessages()
        clearActiveComputerHostLease(runID: runID)
        recordLiveWork(
            status:
                "failed|runner authority unresolved · reclaim blocked",
            isTerminal: true)
        cancellationBlockedReason = signal.convergenceBlockReason
        // Assistant publication is complete, but the global execution lock and
        // lifecycle remain active until formal authority/reclaim proof arrives.
        isRunning = true
        activeTurnDispatchSnapshot = nil
        return true
    }

    private func preparedBlockedTerminalFailureAssistantMessage(
        _ failure: String,
        assistantID: String
    ) -> ChatMessage {
        let visibleFailure =
            ChatRuntimeTextHumanizer.failureSummary(failure)
        if let current = messages.first(where: {
            $0.id == assistantID
        }) {
            var candidate = current
            if !candidate.text.contains(visibleFailure) {
                let separator = candidate.text.isEmpty ? "" : "\n\n"
                candidate.text += separator + visibleFailure
            }
            candidate.status = "failed"
            candidate.modelID = activeTurnAttributionModelID(
                fallback: candidate)
            candidate.eventKind = .failure
            return candidate
        }
        return ChatMessage(
            id: assistantID,
            role: .assistant,
            text: visibleFailure,
            status: "failed",
            modelID: activeTurnAttributionModelID(),
            eventKind: .failure)
    }

    private func formalRunnerStatus(runID: String) -> Int32? {
        let snapshot = processRunnerBound(to: runID).lifecycleSnapshot
        guard snapshot?.runID == runID else { return nil }
        return snapshot?.formalExitStatus
    }

    func acceptFormalTerminalEvent(runID: String, status: Int32) -> Bool {
        guard var lifecycle = activeTurnLifecycle else { return false }
        guard lifecycle.recordFormalTerminalEvent(runID: runID, status: status) else { return false }
        activeTurnLifecycle = lifecycle
        return true
    }

    func finishExitedTurn(status: Int32) {
        let terminalRunID = activeTurnLifecycle?.runID
        let terminalPlanAssistantMessageID =
            activePlanTurnBinding?.assistantMessageID
        let isTerminalPlanClarification =
            terminalPlanAssistantMessageID.map(
                terminalPlanTurnAssistantMessageIDs.contains) ?? false
        defer {
            if let terminalPlanAssistantMessageID {
                terminalPlanTurnAssistantMessageIDs.remove(
                    terminalPlanAssistantMessageID)
            }
        }
        flushPlanQuestionStream()
        if let terminalRunID {
            cancelRunnerStateReconciler(for: terminalRunID)
        }
        clearCancellationBlockedPresentation()
        let wasUserStop = userStopRequested
        let terminalMessage = preparedExitedAssistantMessage(
            status: status,
            wasUserInitiatedStop: wasUserStop)
        let terminalAssistantStatus = terminalMessage?.status
        if let terminalMessage,
           !commitTranscriptTerminalMessage(terminalMessage)
        {
            abortUndurableTerminalPublication()
            return
        }
        if status == 0,
           !wasUserStop,
           let terminalMessage,
           let planTurnBinding = activePlanTurnBinding
        {
            if isTerminalPlanClarification {
                consumePendingPlanQuestions(
                    assistantMessageID: terminalMessage.id)
            }
            updatePlanArtifactFromCompletedResponse(
                terminalMessage.text,
                threadID: planTurnBinding.threadID,
                assistantMessageID: terminalMessage.id,
                planTurnBinding: planTurnBinding,
                isTerminalClarificationCompletion:
                    isTerminalPlanClarification)
        }
        activePlanTurnBinding = nil
        if let terminalRunID,
           terminalMessage != nil,
           ChatAssistantTerminalStatusPolicy.allowsContinuationPromotion(
            exitStatus: status,
            wasUserInitiatedStop: wasUserStop,
            assistantStatus: terminalAssistantStatus)
        {
            promoteGatewayContinuationIfEligible(runID: terminalRunID)
        } else {
            activeGatewayContinuationTurn = nil
        }
        resolveDurableCancellationAfterFormalTerminal()
        userStopRequested = false
        isRunning = false
        refreshGitBranch()
        reloadCLISessions()
        finishActiveAssistant(
            exitStatus: status,
            wasUserInitiatedStop: wasUserStop)
        clearActiveComputerHostLease(runID: terminalRunID)
        recordLiveWork(
            status: ChatAssistantTerminalStatusPolicy.liveWorkStatus(
                exitStatus: status,
                wasUserInitiatedStop: wasUserStop,
                assistantStatus: terminalAssistantStatus),
            isTerminal: true)
        activeTurnLifecycle = nil
        activeTurnDispatchSnapshot = nil
        resetGatewayStaleHandleFallbackState()
        applyPendingModelSelectionIfPossible()
        restoreDurableCancellationLock()
        if !isRunning, isForegroundTurnMutation {
            if !startPendingComputerAutoContinuationIfPossible(),
               !startPendingNativeDevelopmentAutoFollowupIfPossible()
            {
                startNextChatIfNeeded()
            }
        }
    }

    @discardableResult
    private func startPendingNativeDevelopmentAutoFollowupIfPossible()
        -> Bool
    {
        guard let followup = pendingNativeDevelopmentAutoFollowup else {
            return false
        }
        pendingNativeDevelopmentAutoFollowup = nil
        guard !isRunning,
              pendingNativeDevelopmentDispatch == nil,
              let contract = selectedWorkOSContract,
              contract.contractID == followup.contractID,
              contract.scenario
                == TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
              TatwoGatewayDispatchCatalog.normalize(
                followup.completedModelID)
                == TatwoGatewayDispatchCatalog.normalize("fable-5")
        else {
            flashComposerHint(
                "Grok 4.6 未自動啟動：Fable 完成後的 Goal／Contract 狀態已改變。")
            return false
        }

        let modelID = "grok-build"
        let task = nativeDevelopmentLaneTask(
            modelID: modelID,
            objective: contract.objective)
        setSingleModel(modelID, syncCollaborationLead: false)
        guard TatwoGatewayDispatchCatalog.normalize(
            currentTurnDispatchRoute().canonicalModelSlug)
            == TatwoGatewayDispatchCatalog.normalize(modelID)
        else {
            flashComposerHint(
                "Grok 4.6 未自動啟動：exact route 未能切換，已停止而沒有 fallback。")
            return false
        }
        guard beginSelectedNativeDevelopmentDispatch(
            subtask: task,
            selectedModelID: modelID)
        else {
            return false
        }
        let dispatchID = pendingNativeDevelopmentDispatch?.id
        prompt = task
        submitCurrentChatTurn(applyPromptCollaboration: false)
        if let dispatchID,
           pendingNativeDevelopmentDispatch?.id == dispatchID
        {
            failPendingNativeDevelopmentDispatchStart(
                dispatchID: dispatchID,
                message:
                    "Fable 已完成，但 Grok 原生 runner 未取得執行權；第二 lane 已 fail closed。")
            flashComposerHint(
                "Grok 4.6 原生 runner 未啟動；dispatch 已標記失敗。")
            return false
        }
        guard isRunning else {
            flashComposerHint(
                "Grok 4.6 原生 runner 未進入 running；沒有留下假執行狀態。")
            return false
        }
        flashComposerHint(
            "Fable receipt 已完成 → Grok 4.6 High 已自動進入 running")
        return true
    }

    func finishFailureTurn(
        runID: String? = nil,
        message: String,
        activityFallback: String
    ) {
        let terminalRunID = runID ?? activeTurnLifecycle?.runID
        if let terminalRunID {
            cancelRunnerStateReconciler(for: terminalRunID)
        }
        clearCancellationBlockedPresentation()
        let terminalMessage = preparedFailureAssistantMessage(message)
        guard commitTranscriptTerminalMessage(terminalMessage) else {
            abortUndurableTerminalPublication()
            return
        }
        activeGatewayContinuationTurn = nil
        pendingComputerAutoContinuation = nil
        resolveDurableCancellationAfterFormalTerminal()
        userStopRequested = false
        isRunning = false
        refreshGitBranch()
        reloadCLISessions()
        _ = streamLedger.replaceTailContent(terminalMessage.text)
        _ = try? streamLedger.promoteTail()
        activeAssistantID = nil
        cacheSelectedSessionMessages()
        clearActiveComputerHostLease(runID: terminalRunID)
        recordLiveWork(
            status: "failed|\(Self.activityDetail(from: message) ?? activityFallback)",
            isTerminal: true)
        activeTurnLifecycle = nil
        activeTurnDispatchSnapshot = nil
        resetGatewayStaleHandleFallbackState()
        applyPendingModelSelectionIfPossible()
        restoreDurableCancellationLock()
        if !isRunning,
           isForegroundTurnMutation,
           !isStartingQueuedChatTurn
        {
            startNextChatIfNeeded()
        }
    }

    private func preparedExitedAssistantMessage(
        status: Int32,
        wasUserInitiatedStop: Bool
    ) -> ChatMessage? {
        guard let activeAssistantID,
              let current = messages.first(where: { $0.id == activeAssistantID })
        else {
            return nil
        }
        var candidate = current
        let wasStopped = wasUserInitiatedStop
        let hasNoVisibleReply =
            ChatAssistantTerminalVisibilityPolicy.hasNoUserVisibleReply(
                text: candidate.text,
                eventKind: candidate.eventKind,
                planQuestions: candidate.planQuestions)

        if hasNoVisibleReply {
            if status == 0 || wasStopped {
                return nil
            } else {
                candidate.eventKind = .failure
                candidate.status = "failed \(status)"
                candidate.text = "模型路線中斷，未收到完整回覆。"
            }
        } else {
            candidate.eventKind =
                ChatAssistantTerminalVisibilityPolicy.resolvedEventKind(
                    currentEventKind: candidate.eventKind,
                    planQuestions: candidate.planQuestions)
            candidate.status = ChatAssistantTerminalStatusPolicy.resolvedStatus(
                exitStatus: status,
                wasUserInitiatedStop: wasStopped,
                currentStatus: candidate.status)
        }
        candidate.eventKind = ChatAssistantTerminalStatusPolicy.resolvedEventKind(
            exitStatus: status,
            wasUserInitiatedStop: wasStopped,
            currentEventKind: candidate.eventKind)
        if ChatGatewayDegradedNoticePolicy.shouldMarkRouteBlocked(
            exitStatus: status,
            wasUserInitiatedStop: wasStopped,
            assistantText: candidate.text)
        {
            candidate.status = "route-blocked"
            candidate.eventKind = .failure
        }
        candidate.modelID = activeTurnAttributionModelID(fallback: candidate)
        return candidate
    }

    private func preparedFailureAssistantMessage(_ failure: String) -> ChatMessage {
        let visibleFailure =
            ChatRuntimeTextHumanizer.failureSummary(failure)
        if let activeAssistantID,
           let current = messages.first(where: { $0.id == activeAssistantID })
        {
            var candidate = current
            if !candidate.text.contains(visibleFailure) {
                let separator = candidate.text.isEmpty ? "" : "\n\n"
                candidate.text += separator + visibleFailure
            }
            candidate.status = "failed"
            candidate.modelID = activeTurnAttributionModelID(
                fallback: candidate)
            candidate.eventKind = .failure
            return candidate
        }
        return ChatMessage(
            role: .assistant,
            text: visibleFailure,
            status: "failed",
            modelID: activeTurnAttributionModelID(),
            eventKind: .failure)
    }

    private func abortUndurableTerminalPublication() {
        let terminalRunID = activeTurnLifecycle?.runID
        if let terminalRunID {
            cancelRunnerStateReconciler(for: terminalRunID)
        }
        resolveDurableCancellationAfterFormalTerminal()
        isRunning = false
        userStopRequested = false
        streamLedger.discardTail()
        if let activeAssistantID,
           let index = messages.firstIndex(where: { $0.id == activeAssistantID })
        {
            messages.remove(at: index)
        }
        activeAssistantID = nil
        cacheSelectedSessionMessages()
        clearActiveComputerHostLease(runID: terminalRunID)
        activeTurnLifecycle = nil
        activeTurnDispatchSnapshot = nil
        activeGatewayContinuationTurn = nil
        resetGatewayStaleHandleFallbackState()
        applyPendingModelSelectionIfPossible()
        if !chatQueue.isEmpty {
            chatQueuePaused = true
        }
        flashComposerHint("本輪終止但 canonical transcript journal 無法落盤；未發布終止訊息。")
    }

    private func promoteGatewayContinuationIfEligible(runID: String) {
        defer { activeGatewayContinuationTurn = nil }
        guard allowColdStartDocumentMutation() else { return }
        guard let continuation = activeGatewayContinuationTurn,
              continuation.runID == runID,
              let receipt = continuation.receipt
        else {
            return
        }
        var candidate = document
        guard TatwoNativeSessionTree.promoteGatewayConversationHandle(
            request: continuation.request,
            receipt: receipt,
            in: &candidate)
        else {
            return
        }
        document = candidate
        publishDocumentChangeAndPersist()
    }

    private func resetGatewayStaleHandleFallbackState() {
        activeGatewayStaleHandleFallback = nil
        activeGatewayFallbackTurnInputs = nil
    }

    @discardableResult
    private func beginGatewayStaleHandleFallbackIfNeeded(
        message: String,
        runID: String
    ) -> Bool {
        guard !userStopRequested,
              activeTurnLifecycle?.runID == runID
        else { return false }
        var coordinator = activeGatewayStaleHandleFallback
            ?? ChatGatewayContinuationFallbackCoordinator()
        let request = activeGatewayContinuationTurn?.request
        let presentation = coordinator.evaluateFailure(
            message: message,
            request: request)
        activeGatewayStaleHandleFallback = coordinator
        if coordinator.staleHandleCleared {
            clearStaleGatewayConversationHandleIfNeeded(request: request)
        }
        switch presentation {
        case .notHandleError:
            return false
        case .failedRow:
            return false
        case .retryHandleless:
            return relaunchActiveTurnWithoutContinuationHandle(
                previousRunID: runID)
        }
    }

    private func clearStaleGatewayConversationHandleIfNeeded(
        request: TatwoGatewayContinuationRequestV1?
    ) {
        guard let request, allowColdStartDocumentMutation() else { return }
        var candidate = document
        guard TatwoNativeSessionTree.clearGatewayConversationHandle(
            matching: request,
            in: &candidate)
        else { return }
        document = candidate
        publishDocumentChangeAndPersist()
    }

    private func relaunchActiveTurnWithoutContinuationHandle(
        previousRunID: String
    ) -> Bool {
        guard let inputs = activeGatewayFallbackTurnInputs,
              let assistantID = activeAssistantID,
              assistantID == inputs.assistantTurnID
        else { return false }
        clearActiveComputerHostLease(runID: previousRunID)
        cancelRunnerStateReconciler(for: previousRunID)
        let runID = UUID().uuidString
        guard let computerHostBinding = prepareComputerHostBinding(
            runID: runID,
            dispatchSnapshot: inputs.dispatchSnapshot)
        else {
            return false
        }
        guard computerHostBindingSlot.install(computerHostBinding) else {
            revokeComputerHostLease(in: computerHostBinding)
            return false
        }
        let historyExcludingCurrentUser: [TatwoNativeChatStoredMessage] = {
            let withoutAssistant = messages.filter { $0.id != assistantID }
            guard let lastUser = withoutAssistant.lastIndex(where: {
                $0.role == .user
            }) else {
                return withoutAssistant.map(\.storedRecord)
            }
            return withoutAssistant.enumerated().compactMap { index, message in
                index == lastUser ? nil : message.storedRecord
            }
        }()
        let rebuiltTurn = turnWithThreadTranscriptContext(
            inputs.commandBaseTurn,
            transcriptMessages: historyExcludingCurrentUser,
            dispatchSnapshot: inputs.dispatchSnapshot)
        let command = buildCommand(
            turn: rebuiltTurn,
            visibleTurn: inputs.visibleTurn,
            droppedPaths: inputs.attachmentPaths,
            dispatchSnapshot: inputs.dispatchSnapshot,
            computerHostBinding: computerHostBinding,
            runID: runID,
            turnID: assistantID)
        activeGatewayContinuationTurn =
            command.gatewayContinuationRequest.map {
                ChatGatewayContinuationTurnState(
                    runID: runID,
                    request: $0,
                    receipt: nil)
            }
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].text = ""
            messages[index].status =
                ChatPageAssistantTextAppendPolicy.pendingInFlightStatus
            messages[index].eventKind = .message
        }
        streamLedger = StreamTranscriptLedger()
        if let fragmentID = UUID(uuidString: assistantID) {
            _ = streamLedger.beginTail(content: "", id: fragmentID)
        } else {
            _ = streamLedger.beginTail(content: "")
        }
        isRunning = true
        sessionKeyByRunID[runID] = currentSessionStableKey()
        activeTurnDispatchSnapshot = inputs.dispatchSnapshot
        recordLiveWork(status: "working")
        lastCommand = command.display
        let runnerIdentity = dispatchService.startRuntime(
            model: self,
            command: command,
            nativePrompt: rebuiltTurn,
            dispatchSnapshot: inputs.dispatchSnapshot,
            runID: runID,
            activityTurnID: assistantID,
            allowsNativeGovernanceFallback: false,
            nativeGovernanceFallbackCommand: nil
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runtimeEventReducer.reduce(
                    event,
                    runID: runID,
                    runtimeAdapter: command.runtimeAdapter,
                    model: self)
            }
        }
        guard let runnerIdentity else {
            return false
        }
        activeTurnLifecycle = TatwoChatTurnLifecycle(
            runID: runID,
            assistantID: assistantID,
            runnerInstanceID: runnerIdentity.instanceID,
            runnerRevision: runnerIdentity.revision)
        if [.codexExec, .claudeCLI, .grokCLI, .gatewayDirect]
            .contains(command.runtimeAdapter)
        {
            startRunnerStateReconciler(for: assistantID, runID: runID)
        }
        return true
    }

    private func executeComputerIntent(
        _ intent: TatwoComputerActionV1,
        runID: String
    ) {
        defer { clearActiveComputerHostLease(runID: runID) }
        guard let binding = computerHostBindingSlot.binding(for: runID),
              binding.decision.route == .embeddedIntent
        else {
            appendMessage(ChatMessage(
                role: .system,
                text: "Computer Host 未執行：embedded intent 與本輪 execution route 不符。",
                status: "computer route blocked",
                eventKind: .failure))
            return
        }
        guard binding.decision.isAuthorized else {
            appendMessage(ChatMessage(
                role: .system,
                text: "Computer Host 未執行：本輪使用者沒有要求操作電腦。",
                status: "computer blocked",
                eventKind: .failure))
            return
        }
        guard let contractID = binding.contractID,
              let mainlineLoopID = binding.mainlineLoopID,
              let workspace = binding.workspaceRoot
        else {
            appendMessage(ChatMessage(
                role: .system,
                text: "Computer Host 未執行：缺少本輪 Work OS contract。",
                status: "computer blocked",
                eventKind: .failure))
            return
        }
        if let missingPermission = TatwoComputerHost.missingPermission(for: intent.action) {
            let permissionName: String
            let settingsPath: String
            switch missingPermission {
            case .accessibility:
                permissionName = "輔助使用"
                settingsPath = "系統設定 → 隱私權與安全性 → 輔助使用"
            case .screenRecording:
                permissionName = "螢幕與系統音訊錄製"
                settingsPath = "系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製"
            }
            let firstRequest = requestedComputerPermissions.insert(missingPermission).inserted
            if firstRequest {
                let granted = TatwoComputerHost.requestSystemPermission(missingPermission)
                if !granted, let settingsURL = missingPermission.systemSettingsURL {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            let requestStatus = firstRequest
                ? "已要求 macOS 系統授權"
                : "macOS 系統授權仍未開啟；不會重複彈出授權提示"
            appendMessage(ChatMessage(
                role: .system,
                text: """
                Computer Host 未執行：Tatwo Ultrawork 尚未取得 macOS「\(permissionName)」權限。
                \(requestStatus)。請在 \(settingsPath) 開啟 Tatwo Ultrawork。macOS 若要求，請重新開啟 App 後再試。
                """,
                status: "computer permission required",
                eventKind: .failure))
            return
        }
        guard TatwoComputerApprovalPolicy.evaluate(
            userRequestedComputerUse: binding.decision.userRequested,
            hasValidContract: true,
            requiredSystemPermissionGranted: true) == .allowedOnce
        else {
            appendMessage(ChatMessage(
                role: .system,
                text: "Computer Host 未執行：本輪指令、Work OS contract 或 macOS 系統授權條件不完整。",
                status: "computer blocked",
                eventKind: .failure))
            return
        }

        do {
            let receipt = try computerHostExecutor(
                contractID,
                workspace,
                intent.action,
                intent.value)
            let receiptID = "computer-\(UUID().uuidString.lowercased())"
            _ = try? goalRunStore.appendReceipt(
                contractID: contractID,
                receiptID: receiptID,
                kind: "computer-host",
                loopID: mainlineLoopID)
            let artifact = receipt.artifactRelativePath.map { " · artifact \($0)" } ?? ""
            appendMessage(ChatMessage(
                role: .system,
                text: "Tatwo Computer Host：\(receipt.ok ? "完成" : "失敗") \(receipt.action.rawValue)\(artifact) · receipt \(receiptID)",
                status: receipt.ok ? "computer receipt" : "computer failed",
                eventKind: receipt.ok ? .message : .failure))
            refreshSelectedWorkOSState(contractID: contractID)
            guard receipt.ok else { return }
            guard computerAutoContinuationBudget.consumeStep() else {
                appendMessage(ChatMessage(
                    role: .system,
                    text: "Computer-use 自動續步已達上限 \(computerAutoContinuationBudget.maximumSteps)，已停止。",
                    status: "computer step limit",
                    eventKind: .failure))
                return
            }
            if computerAutoContinuationBudget.isExhausted {
                appendMessage(ChatMessage(
                    role: .system,
                    text: "Computer-use 自動續步已達上限 \(computerAutoContinuationBudget.maximumSteps)，已停止。",
                    status: "computer step limit",
                    eventKind: .failure))
                return
            }
            let absoluteArtifact = receipt.artifactRelativePath.map {
                URL(fileURLWithPath: workspace)
                    .appendingPathComponent($0).standardizedFileURL.path
            }
            pendingComputerAutoContinuation = """
                [Tatwo Computer Host observation — continue the same user-requested computer-use turn]
                completedStep=\(computerAutoContinuationBudget.completedSteps)
                action=\(receipt.action.rawValue)
                result=\(receipt.result)
                artifactRelativePath=\(receipt.artifactRelativePath ?? "none")
                artifactAbsolutePath=\(absoluteArtifact ?? "none")
                Inspect the result above. If another visible computer action is needed, emit exactly one TATWO_COMPUTER_ACTION. Otherwise answer naturally and end the turn.
                """
        } catch {
            let blocker =
                "Computer Host 執行失敗；本輪未完成操作。"
                + " blocker_class=host_execution_failed"
                + " authority_source=computer_host_runtime"
            appendMessage(ChatMessage(
                role: .system,
                text: blocker,
                status: "computer blocked",
                eventKind: .failure))
            flashComposerHint(blocker)
        }
    }

    func executeMCPComputerCall(
        arguments: [String: JSONValue]
    ) -> TatwoMCPToolCallResult {
        let initial = TatwoMCPRegistry.call(
            tool: "tatwo.computer.execute",
            arguments: arguments)
        guard !initial.ok,
              ["approval_required", "approval_expired"]
                .contains(initial.error ?? ""),
              let requestedRunID = arguments["runID"]?.stringValue,
              let requestedContractID = arguments["contractID"]?.stringValue,
              let workspace = arguments["workspaceRoot"]?.stringValue,
              let binding = computerHostBindingSlot.binding(
                for: requestedRunID)
        else { return initial }

        let renewal = ChatComputerLeaseRenewalContext(
            requestedRunID: requestedRunID,
            activeRunID: activeTurnLifecycle?.runID,
            requestedContractID: requestedContractID,
            activeContractID: binding.contractID,
            contractIsValid:
                (try? goalRunStore.requireIssuedContract(
                    requestedContractID)) != nil,
            turnIsRunning: isRunning,
            userInterrupted: userStopRequested)
        guard renewal.mayRenew,
              workspace == binding.workspaceRoot
        else { return initial }

        do {
            let approvalStore = TatwoHostApprovalStore.default()
            let lease = try approvalStore.issue(
                contractID: requestedContractID,
                workspaceRoot: workspace,
                allowedActions: [.computerUse],
                ttl: 180)
            var retryArguments = arguments
            retryArguments["leaseID"] = .string(lease.id)
            let renewalReceiptID =
                "computer-lease-\(UUID().uuidString.lowercased())"
            _ = try? goalRunStore.appendReceipt(
                contractID: requestedContractID,
                receiptID: renewalReceiptID,
                kind: "computer-host-lease-renewal",
                loopID: binding.mainlineLoopID)
            let retried = TatwoMCPRegistry.call(
                tool: "tatwo.computer.execute",
                arguments: retryArguments)
            refreshSelectedWorkOSState(contractID: requestedContractID)
            return retried
        } catch {
            return TatwoMCPToolCallResult(
                tool: "tatwo.computer.execute",
                ok: false,
                payload: nil,
                error: TatwoPrivacyRedactor.redacted(
                    error.localizedDescription),
                failureKind: .contract,
                hostMutationAllowed: false)
        }
    }
}

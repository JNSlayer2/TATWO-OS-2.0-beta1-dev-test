import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    @discardableResult
    func startPendingComputerAutoContinuationIfPossible() -> Bool {
        guard let continuation = pendingComputerAutoContinuation else {
            return false
        }
        pendingComputerAutoContinuation = nil
        guard !isRunning, !userStopRequested else { return false }
        prompt = continuation
        submitCurrentChatTurn(
            suppressUserEcho: true,
            computerAutoContinuation: true)
        return isRunning
    }

    func prepareComputerHostBinding(
        runID: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot
    ) -> ChatComputerHostTurnBinding? {
        let decision = dispatchSnapshot.computerHostDecision
        guard decision.isAuthorized else {
            return ChatComputerHostTurnBinding(
                runID: runID,
                sessionID:
                    selectedThreadID?.uuidString.lowercased() ?? "",
                decision: decision,
                contractID: nil,
                mainlineLoopID: nil,
                workspaceRoot: nil,
                lease: nil,
                appMCPEndpoint: nil)
        }

        let route = ChatRouteChoice.resolve(dispatchSnapshot.routeID)
        guard let contractID = dispatchSnapshot.contractID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !contractID.isEmpty,
              let selectedContract = selectedWorkOSContract,
              selectedContract.contractID == contractID,
              let threadContractID = selectedThread?.workOSContractID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              threadContractID == contractID,
              (try? goalRunStore.requireIssuedContract(contractID)) != nil
        else {
            appendMessage(ChatMessage(
                role: .system,
                text: "Computer Host 尚未就緒：缺少可驗證且與本輪 snapshot 一致的 Work OS contract。",
                status: "computer blocked",
                eventKind: .failure))
            return nil
        }

        let workspace = resolvedRuntimeWorkspace().url.path
        if decision.route == .embeddedIntent {
            guard freezeComputerHostAuthoritySnapshot(
                runID: runID,
                contractID: contractID,
                selectedContract: selectedContract)
            else { return nil }
            return ChatComputerHostTurnBinding(
                runID: runID,
                sessionID:
                    selectedThreadID?.uuidString.lowercased() ?? "",
                decision: decision,
                contractID: contractID,
                mainlineLoopID: selectedContract.mainlineLoop.id,
                workspaceRoot: workspace,
                lease: nil,
                appMCPEndpoint: nil)
        }

        guard decision.route == .mcp,
              route.engine == .claude,
              route.canonicalModelSlug != "fable-5"
        else {
            appendMessage(ChatMessage(
                role: .system,
                text: "Computer Host 尚未就緒：本輪 route 與 App MCP 執行契約不相容。",
                status: "computer blocked",
                eventKind: .failure))
            return nil
        }
        let appMCPState = appMCPRuntimeProvider()
        guard case .ready(let endpoint) = appMCPState else {
            let blocker = Self.confirmedPlanComputerHostBindingBlocker
            appendMessage(ChatMessage(
                role: .assistant,
                text: blocker,
                status: "computer blocked",
                eventKind: .failure))
            flashComposerHint(blocker)
            return nil
        }
        do {
            let lease = try computerHostApprovalLeaseIssuer(
                contractID,
                workspace)
            guard freezeComputerHostAuthoritySnapshot(
                runID: runID,
                contractID: contractID,
                selectedContract: selectedContract)
            else {
                try? TatwoHostApprovalStore.default().revoke(id: lease.id)
                return nil
            }
            return ChatComputerHostTurnBinding(
                runID: runID,
                sessionID:
                    selectedThreadID?.uuidString.lowercased() ?? "",
                decision: decision,
                contractID: contractID,
                mainlineLoopID: selectedContract.mainlineLoop.id,
                workspaceRoot: workspace,
                lease: lease,
                appMCPEndpoint: endpoint)
        } catch {
            let blocker = Self.confirmedPlanComputerHostApprovalBlocker
            appendMessage(ChatMessage(
                role: .assistant,
                text: blocker,
                status: "computer blocked",
                eventKind: .failure))
            flashComposerHint(blocker)
            return nil
        }
    }

    private func freezeComputerHostAuthoritySnapshot(
        runID: String,
        contractID: String,
        selectedContract: TatwoWorkOSContractV1
    ) -> Bool {
        guard computerHostAuthoritySnapshotsByRunID[runID] == nil,
              let snapshot = currentComputerHostAuthoritySnapshot(
                expectedContractID: contractID),
              snapshot.goalID == selectedContract.goalID,
              snapshot.goalHash
                == TatwoObjectiveIdentity.make(
                    selectedContract.objective).objectiveHash
        else {
            appendMessage(ChatMessage(
                role: .system,
                text:
                    "Computer Host 尚未就緒：thread、selected contract、Goal store"
                    + " 或 Plan snapshot 不一致；已 fail closed，未啟動 runner。",
                status: "computer blocked",
                eventKind: .failure))
            return false
        }
        computerHostAuthoritySnapshotsByRunID[runID] = snapshot
        return true
    }

    func computerHostAuthorityBlocker(
        runID: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot
    ) -> String? {
        guard dispatchSnapshot.computerHostDecision.isAuthorized else {
            return nil
        }
        guard let expectedContractID = Self.normalizedNonEmpty(
            dispatchSnapshot.contractID)
        else {
            return "computer_host_contract_snapshot_missing"
        }
        guard let frozen = computerHostAuthoritySnapshotsByRunID[runID]
        else {
            return "computer_host_authority_snapshot_missing"
        }
        guard frozen.contractID == expectedContractID else {
            return "computer_host_contract_snapshot_mismatch"
        }
        guard let current = currentComputerHostAuthoritySnapshot(
            expectedContractID: expectedContractID)
        else {
            return "computer_host_authority_snapshot_unverifiable"
        }
        guard current == frozen else {
            return
                "computer_host_authority_snapshot_changed"
                + " contractID=\(expectedContractID)"
                + " goalHash=\(frozen.goalHash)"
                + " planHash=\(frozen.planHash)"
        }
        return nil
    }

    private func currentComputerHostAuthoritySnapshot(
        expectedContractID: String
    ) -> ChatComputerHostAuthoritySnapshot? {
        guard let selectedContract = selectedWorkOSContract,
              selectedContract.contractID == expectedContractID,
              let thread = selectedThread,
              Self.normalizedNonEmpty(thread.workOSContractID)
                == expectedContractID,
              Self.normalizedNonEmpty(thread.workOSGoalID)
                == selectedContract.goalID,
              let storedGoal = try? goalRunStore.requireIssuedContract(
                expectedContractID),
              storedGoal.goalID == selectedContract.goalID
        else { return nil }
        let selectedGoalHash =
            TatwoObjectiveIdentity.make(
                selectedContract.objective).objectiveHash
        let storedGoalHash =
            TatwoObjectiveIdentity.make(storedGoal.objective).objectiveHash
        guard selectedGoalHash == storedGoalHash else { return nil }

        let planHash: String
        if let threadID = selectedThreadID,
           let artifact =
            activePlanArtifact?.threadID == threadID
                ? activePlanArtifact
                : try? planArtifactStore?.load(threadID: threadID),
           let canonical = try? artifact.canonicalJSONData()
        {
            planHash = TatwoArtifactReviewHasher.sha256(
                String(decoding: canonical, as: UTF8.self))
        } else {
            planHash = TatwoArtifactReviewHasher.sha256(
                "no-plan|\(expectedContractID)|\(selectedContract.goalID)")
        }
        return ChatComputerHostAuthoritySnapshot(
            contractID: expectedContractID,
            goalID: storedGoal.goalID,
            goalHash: storedGoalHash,
            planHash: planHash)
    }

    func revokeComputerHostLease(
        in binding: ChatComputerHostTurnBinding
    ) {
        computerHostAuthoritySnapshotsByRunID.removeValue(
            forKey: binding.runID)
        if let lease = binding.lease {
            try? TatwoHostApprovalStore.default().revoke(id: lease.id)
        }
    }

    func clearActiveComputerHostLease(runID: String? = nil) {
        let targetRunID = runID ?? activeTurnLifecycle?.runID
        guard let targetRunID, !targetRunID.isEmpty,
              let binding = computerHostBindingSlot.take(runID: targetRunID)
        else { return }
        revokeComputerHostLease(in: binding)
    }

    private static func compactThinkingStatus(from text: String, rawType: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "thinking" }
        let lower = trimmed.lowercased()
        let raw = rawType?.lowercased() ?? ""
        if lower.contains("compact") || lower.contains("壓縮") { return activityStatus("compacting-context", detail: activityDetail(from: trimmed)) }
        if raw.contains("approval_request") || raw.contains("request_user_input") || raw.contains("elicitation_request") || lower.contains("approval_request") || lower.contains("request_user_input") {
            return "waiting"
        }
        if raw.contains("mcp_startup_update") || lower.contains("mcp_startup") {
            return "checking"
        }
        if raw.contains("remote_task_created") || lower.contains("remote_task") {
            return "working"
        }
        if raw.contains("undo_started") || lower.contains("undo") || lower.contains("復原") || lower.contains("還原") {
            return "undoing"
        }
        if raw.contains("turn_aborted") {
            return "stopped"
        }
        if raw.contains("collab_waiting") || lower.contains("collab_waiting") || lower.contains("collab_agent_waiting") { return "waiting-collab" }
        if raw.contains("collab_agent") || raw.contains("collab_resume") || raw.contains("collab_close") || lower.contains("collab_agent") { return "collaborating" }
        if lower.contains("inspect") || lower.contains("read") || lower.contains("open") || lower.contains("檢視") || lower.contains("讀取") {
            return activityStatus("inspecting", detail: activityDetail(from: trimmed))
        }
        if lower.contains("plan") || lower.contains("規劃") { return activityStatus("planning", detail: activityDetail(from: trimmed)) }
        if lower.contains("debug") || lower.contains("除錯") { return activityStatus("debugging", detail: activityDetail(from: trimmed)) }
        if lower.contains("search") || lower.contains("grep") || lower.contains("rg ") || lower.contains("搜尋") {
            return activityStatus("searching", detail: activityDetail(from: trimmed))
        }
        return "thinking"
    }

    static func compactToolUseStatus(from text: String, rawType: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "working" }
        let lower = trimmed.lowercased()
        let raw = rawType?.lowercased() ?? ""
        let detail = activityDetail(from: trimmed)
        if raw.contains("view_image_tool_call") {
            return activityStatus("viewing", detail: detail)
        }
        if raw.contains("terminal_interaction") {
            return activityStatus("running-command", detail: detail)
        }
        if lower.contains("swift build") || lower.contains("xcodebuild") {
            return activityStatus("building", detail: detail)
        }
        if lower.contains("swift test") || lower.contains(" test ") || lower.hasPrefix("test ") {
            return activityStatus("testing", detail: detail)
        }
        if lower.contains("patch_apply") || lower.contains("apply_patch") || lower.contains("applied patch") || lower.contains("checking patch") || lower.contains("edit") || lower.contains("write") || lower.contains("修改") {
            return activityStatus("editing", detail: detail)
        }
        if lower.contains("computer_use") || lower.contains("computer-use") {
            return activityStatus("using-computer", detail: detail)
        }
        if lower.contains("screenshot") || lower.contains("view_image") || lower.contains("image") || lower.contains("截圖") {
            return activityStatus("viewing", detail: detail)
        }
        if raw.contains("mcp_tool_call") || raw.contains("dynamic_tool_call") || lower.contains("mcp_tool_call") || lower.contains("dynamic_tool_call") || lower.contains("tool_call") {
            return activityStatus("calling-tool", detail: detail)
        }
        if lower.contains("web_search") || lower.contains("search") || lower.contains("rg ") || lower.contains("grep ") || lower.contains("find ") {
            return activityStatus("searching", detail: detail)
        }
        if lower.contains("web") || lower.contains("browser") || lower.contains("open ") || lower.contains("browse") {
            return activityStatus("browsing", detail: detail)
        }
        if lower.contains("node_repl") || lower.contains("exec_command") || lower.contains("shell") || lower.contains("command") {
            return activityStatus("running-command", detail: detail)
        }
        if lower.contains("git ")
            || lower.contains("git_") {
            return activityStatus("checking", detail: detail)
        }
        if looksLikeToolActivityName(trimmed) {
            return activityStatus("calling-tool", detail: detail)
        }
        return "working"
    }

    private static func looksLikeToolActivityName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...80).contains(trimmed.count), !trimmed.contains(" "), !trimmed.contains("/") else { return false }
        guard trimmed.range(of: #"^[A-Za-z][A-Za-z0-9_.:-]*$"#, options: .regularExpression) != nil else { return false }
        return trimmed.contains(".") || trimmed.contains("_") || trimmed.contains(":")
    }

    private static func activityStatus(_ base: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return base }
        return "\(base)|\(detail)"
    }

    static func activityDetail(from text: String) -> String? {
        var value = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        guard !value.isEmpty else { return nil }

        if let path = firstActivityPath(in: value) {
            return compactActivityDetail(path)
        }
        if value.lowercased().contains("swift build") {
            if let product = firstRegexCapture(pattern: #"--product\s+([A-Za-z0-9_.-]+)"#, in: value) {
                return compactActivityDetail(product)
            }
            return "swift build"
        }
        if value.lowercased().contains("swift test") {
            if let filter = firstRegexCapture(pattern: #"--filter\s+([A-Za-z0-9_./:-]+)"#, in: value) {
                return compactActivityDetail(filter)
            }
            return "swift test"
        }
        if let quoted = firstRegexCapture(pattern: #""([^"]{3,80})""#, in: value) ?? firstRegexCapture(pattern: #"'([^']{3,80})'"#, in: value) {
            return compactActivityDetail(quoted)
        }
        let stripped = value
            .replacingOccurrences(of: "codex/event/", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count <= 42, !stripped.contains("{"), !stripped.contains(":") {
            return compactActivityDetail(stripped)
        }
        return nil
    }

    private static func firstActivityPath(in value: String) -> String? {
        let pattern = #"(?:(?:[A-Za-z0-9_. -]+/)+)?[A-Za-z0-9_. -]+\.(?:swift|md|json|js|ts|tsx|py|sh|txt|plist|yml|yaml|toml|css|html)"#
        return firstRegexCapture(pattern: pattern, in: value)
    }

    private static func compactActivityDetail(_ detail: String) -> String {
        var value = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("/") {
            value = URL(fileURLWithPath: value).lastPathComponent
        }
        if value.count > 44 {
            return String(value.prefix(41)) + "…"
        }
        return value
    }

    private static func firstRegexCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        let captureIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let swiftRange = Range(match.range(at: captureIndex), in: text) else { return nil }
        return String(text[swiftRange])
    }

    func recordLiveWork(
        status: String,
        isTerminal: Bool = false
    ) {
        let parts = status.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts.first ?? "working")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let detail = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let presentation: (label: String, systemImage: String) = switch key {
        case "sent": ("已送出", "paperplane.fill")
        case "queued": ("插話已排隊", "text.badge.plus")
        case "thinking": ("分析中", "brain.head.profile")
        case "planning": ("規劃中", "point.3.connected.trianglepath.dotted")
        case "inspecting": ("檢查中", "magnifyingglass")
        case "searching": ("搜尋中", "magnifyingglass.circle")
        case "debugging": ("除錯中", "ladybug")
        case "editing": ("修改中", "pencil.line")
        case "building": ("建置中", "hammer")
        case "testing": ("測試中", "checkmark.seal")
        case "browsing": ("瀏覽中", "globe")
        case "viewing": ("查看中", "eye")
        case "calling-tool": ("呼叫工具", "wrench.and.screwdriver")
        case "running-command": ("執行命令", "terminal")
        case "checking": ("確認中", "checklist")
        case "reconnecting": ("重新連線中", "arrow.triangle.2.circlepath")
        case "session": ("建立 session", "link")
        case "writing": ("撰寫回覆", "text.cursor")
        case "completed": ("本輪完成", "checkmark.circle.fill")
        case "blocked", "route-blocked": ("本輪受阻", "exclamationmark.octagon.fill")
        case "stopped": ("已停止", "stop.circle.fill")
        case "failed": ("執行失敗", "exclamationmark.triangle.fill")
        default: ("工作中", "sparkles")
        }
        let next = ChatLiveWorkActivity(
            label: presentation.label,
            detail: detail?.isEmpty == false ? detail : nil,
            systemImage: presentation.systemImage,
            isTerminal: isTerminal)
        if let last = liveWorkActivities.last,
           !last.isTerminal,
           last.label == next.label,
           last.detail == next.detail {
            liveWorkActivities[liveWorkActivities.count - 1] = next
        } else {
            liveWorkActivities.append(next)
        }
        if liveWorkActivities.count > 6 {
            liveWorkActivities.removeFirst(liveWorkActivities.count - 6)
        }
    }

    private var activeAssistantHasNoUserVisibleReply: Bool {
        guard let activeAssistantID, let index = messages.firstIndex(where: { $0.id == activeAssistantID }) else { return true }
        return ChatAssistantTerminalVisibilityPolicy.hasNoUserVisibleReply(
            text: messages[index].text,
            eventKind: messages[index].eventKind,
            planQuestions: messages[index].planQuestions)
    }

    func activeTurnAttributionModelID(
        fallback message: ChatMessage? = nil
    ) -> String? {
        let persistedMessage = message ?? activeAssistantID.flatMap { assistantID in
            messages.first(where: { $0.id == assistantID })
        }
        return ChatActiveTurnRouteAttributionPolicy.modelID(
            dispatchSnapshot: activeTurnDispatchSnapshot,
            activeMessage: persistedMessage)
    }

    func finishActiveAssistant(
        exitStatus status: Int32,
        wasUserInitiatedStop: Bool = false
    ) {
        guard let activeAssistantID, let index = messages.firstIndex(where: { $0.id == activeAssistantID }) else {
            streamLedger.discardTail()
            return
        }
        let wasStopped = wasUserInitiatedStop
        if activeAssistantHasNoUserVisibleReply {
            if status == 0 || wasStopped {
                // Codex App does not turn a successful-but-empty activity
                // placeholder into a fake assistant answer. User cancel of a
                // still-pending row should also vanish — the user already
                // pressed Stop, so keep the empty breathing placeholder out.
                streamLedger.discardTail()
                messages.remove(at: index)
                self.activeAssistantID = nil
                cacheSelectedSessionMessages()
                return
            }
            // Non-zero without visible reply: do not promote partial
            // stream body; write a terminal stable line only.
            streamLedger.discardTail()
            messages[index].eventKind =
                ChatAssistantTerminalStatusPolicy.resolvedEventKind(
                    exitStatus: status,
                    wasUserInitiatedStop: wasStopped,
                    currentEventKind: .message)
            messages[index].status = "failed \(status)"
            messages[index].text = "模型路線中斷，未收到完整回覆。"
            _ = streamLedger.beginTail(content: messages[index].text)
            _ = try? streamLedger.promoteTail()
        } else {
            // Visible body completed (or user stop with visible partial they saw):
            // atomically promote tail → stable, then persist.
            messages[index].status = ChatAssistantTerminalStatusPolicy.resolvedStatus(
                exitStatus: status,
                wasUserInitiatedStop: wasStopped,
                currentStatus: messages[index].status)
            messages[index].eventKind =
                ChatAssistantTerminalStatusPolicy.resolvedEventKind(
                    exitStatus: status,
                    wasUserInitiatedStop: wasStopped,
                    currentEventKind:
                        ChatAssistantTerminalVisibilityPolicy.resolvedEventKind(
                            currentEventKind: messages[index].eventKind,
                            planQuestions: messages[index].planQuestions))
            _ = streamLedger.replaceTailContent(messages[index].text)
            _ = try? streamLedger.promoteTail()
        }
        messages[index].modelID = activeTurnAttributionModelID(
            fallback: messages[index])
        self.activeAssistantID = nil
        cacheSelectedSessionMessages()
    }

    func appendAssistant(_ text: String, kind: TatwoNativeChatEventKind) {
        guard !text.isEmpty else { return }
        let isTerminalKind = kind == .failure
        if let activeAssistantID, let index = messages.firstIndex(where: { $0.id == activeAssistantID }) {
            if kind == .message {
                if messages[index].eventKind == .thinking || messages[index].eventKind == .toolUse {
                    messages[index].text = ""
                    _ = streamLedger.replaceTailContent("")
                }
                messages[index].eventKind = .message
            }
            if ChatPageAssistantTextAppendPolicy.isPendingPlaceholderBody(
                messages[index].text)
            {
                messages[index].text = text
            } else {
                // Codex/Claude streams deliver whole message items; a second
                // item (commentary before tools, then the answer) must start a
                // new paragraph instead of gluing onto the previous sentence.
                let needsParagraphBreak = kind == .message
                    && !messages[index].text.isEmpty
                    && !(messages[index].text.last?.isNewline ?? true)
                messages[index].appendTranscriptText(
                    (needsParagraphBreak ? "\n\n" : "") + text)
            }
            if kind == .message,
               !ChatPageAssistantTextAppendPolicy.isPendingPlaceholderBody(
                messages[index].text),
               messages[index].status
                == ChatPageAssistantTextAppendPolicy.pendingInFlightStatus
            {
                messages[index].status = "streaming"
            }
            if kind != .message {
                messages[index].eventKind = kind
            }
            messages[index].modelID = activeTurnAttributionModelID(
                fallback: messages[index])
            // Live stream body accumulates as tail only (memory).
            _ = streamLedger.appendTailChunk(text)
            if isTerminalKind {
                messages[index].status = messages[index].status ?? "failed"
                _ = streamLedger.replaceTailContent(messages[index].text)
                _ = try? streamLedger.promoteTail()
            }
        } else {
            let messageID = UUID().uuidString
            let message = ChatMessage(
                id: messageID,
                role: .assistant,
                text: ChatPageAssistantTextAppendPolicy.appending(text, to: ""),
                status: isTerminalKind ? "failed" : "stream",
                modelID: activeTurnAttributionModelID(),
                eventKind: kind,
                turnID: messageID)
            activeAssistantID = message.id
            messages.append(message)
            if let fragmentID = UUID(uuidString: message.id) {
                _ = streamLedger.beginTail(content: text, id: fragmentID)
            } else {
                _ = streamLedger.beginTail(content: text)
            }
            if isTerminalKind {
                _ = try? streamLedger.promoteTail()
            }
        }
        cacheSelectedSessionMessages()
        // Tail must not hit disk; only promoted/terminal stable content persists.
        if isTerminalKind || !isRunning {
            persistSelectedThreadMessages()
        }
    }

    func appendPlanAwareAssistantOutput(_ text: String) {
        guard activePlanTurnBinding != nil else {
            appendAssistant(text, kind: .message)
            return
        }
        let result = planQuestionStreamParser.consume(text)
        if !result.visibleText.isEmpty {
            appendAssistant(result.visibleText, kind: .message)
        }
        attachPlanQuestions(result.questions)
    }

    func flushPlanQuestionStream() {
        let result = planQuestionStreamParser.consume("", isFinal: true)
        if !result.visibleText.isEmpty {
            appendAssistant(result.visibleText, kind: .message)
        }
        attachPlanQuestions(result.questions)
    }

    private func attachPlanQuestions(_ questions: [PlanQuestionV1]) {
        guard !questions.isEmpty,
              let activeAssistantID,
              let index = messages.firstIndex(where: {
                  $0.id == activeAssistantID
              })
        else { return }
        let existing = Set(messages[index].planQuestions.map(\.id))
        messages[index].planQuestions.append(
            contentsOf: questions.filter { !existing.contains($0.id) })
        cacheSelectedSessionMessages()
    }

    func appendThinkingTimeline(runID: String) {
        guard activeTurnLifecycle?.runID == runID,
              let activeAssistantID
        else { return }
        let status = "thinking"
        if let index = messages.lastIndex(where: {
            $0.role == .assistant
                && $0.eventKind == .thinking
                && $0.turnID == activeAssistantID
        }) {
            // Provider reasoning is never copied into ChatMessage.text. N
            // deltas update the same folded row, which also keeps Copy from
            // exposing raw chain-of-thought.
            messages[index].text = ""
            messages[index].status = status
            messages[index].modelID = activeTurnAttributionModelID(
                fallback: messages[index])
        } else {
            messages.append(ChatMessage(
                role: .assistant,
                text: "",
                status: status,
                modelID: activeTurnAttributionModelID(),
                eventKind: .thinking,
                turnID: activeAssistantID))
        }
        cacheSelectedSessionMessages()
    }

    func updateActiveActivity(status: String) {
        guard let activeAssistantID, let index = messages.firstIndex(where: { $0.id == activeAssistantID }) else {
            let messageID = UUID().uuidString
            let message = ChatMessage(
                id: messageID,
                role: .assistant,
                text: "",
                status: status,
                modelID: activeTurnAttributionModelID(),
                eventKind: .message,
                turnID: messageID)
            activeAssistantID = message.id
            if let fragmentID = UUID(uuidString: message.id) {
                _ = streamLedger.beginTail(content: "", id: fragmentID)
            } else {
                _ = streamLedger.beginTail(content: "")
            }
            messages.append(message)
            cacheSelectedSessionMessages()
            // In-flight activity placeholder stays memory-only.
            return
        }
        messages[index].status = status
        if messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages[index].eventKind = .message
        }
        messages[index].modelID = activeTurnAttributionModelID(
            fallback: messages[index])
        cacheSelectedSessionMessages()
        // Status-only stream updates never promote / never persist.
    }

    /// Once the structured activity is durably journaled, the empty assistant
    /// stream placeholder must become inert. The canonical activity row remains
    /// visible; keeping both would render the same tool/thinking step twice.
    func demoteEphemeralActivityPlaceholder(turnID: String) {
        guard activeAssistantID == turnID,
              let index = messages.firstIndex(where: { $0.id == turnID }),
              messages[index].text.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
        else { return }
        messages[index].status = "streaming"
        messages[index].eventKind = .message
        messages[index].turnID = turnID
        cacheSelectedSessionMessages()
    }

    func updateActiveStatus(_ status: String) {
        guard let activeAssistantID, let index = messages.firstIndex(where: { $0.id == activeAssistantID }) else { return }
        let compactStatus: String
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "terminated":
            compactStatus = "stopped"
        case "diagnostic", "ignored transient session":
            compactStatus = "checking"
        default:
            compactStatus = status
        }
        messages[index].status = compactStatus
        cacheSelectedSessionMessages()
        let lowered = compactStatus.lowercased()
        let isTerminal =
            lowered == "stopped"
            || lowered.hasPrefix("failed")
            || lowered.hasPrefix("error")
            || lowered == "terminated"
        if isTerminal {
            // Terminal status without exit path still needs a promote so the
            // final row can land; unfinished activity words stay tail-only.
            if streamLedger.hasTail {
                _ = streamLedger.replaceTailContent(messages[index].text)
                _ = try? streamLedger.promoteTail()
            }
            persistSelectedThreadMessages()
        }
    }

    func startActiveGoalTimerIfNeeded() {
        guard shouldShowActiveGoalInlineCard else {
            stopActiveGoalTimer()
            return
        }
        guard activeGoalTimer == nil else { return }
        activeGoalClock = Date()
        activeGoalTimer?.invalidate()
        activeGoalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldShowActiveGoalInlineCard else { return }
                self.activeGoalClock = Date()
                self.refreshSelectedWorkOSStateForExternalChanges(
                    now: self.activeGoalClock)
                if Int(self.activeGoalClock.timeIntervalSince1970) % 5 == 0 {
                    self.refreshGatewayCooldownProjection(now: self.activeGoalClock)
                }
            }
        }
    }

    func stopActiveGoalTimer() {
        activeGoalTimer?.invalidate()
        activeGoalTimer = nil
    }

    func resumeQueuedChatTurns() {
        guard !chatQueue.isEmpty else { return }
        chatQueuePaused = false
        startNextChatIfNeeded()
    }

    func startNextChatIfNeeded() {
        guard !isRunning, !chatQueuePaused, !chatQueue.isEmpty else { return }
        let next = chatQueue.removeFirst()
        guard next.threadID == selectedThreadID,
              next.discussionID == selectedDiscussionID
        else {
            flashComposerHint("插話佇列屬於原 session；目前已切換，保留等待你回原串執行。")
            chatQueue.insert(next, at: 0)
            chatQueuePaused = true
            return
        }
        let suppressUserEcho =
            queuedUserEchoSuppressionMessageIDs.contains(next.messageID)
        if !suppressUserEcho {
            guard let index = messages.firstIndex(where: {
                $0.id == next.messageID
            }) else {
                chatQueue.insert(next, at: 0)
                chatQueuePaused = true
                flashComposerHint(
                    "佇列啟動失敗：找不到對應的 canonical user message。")
                return
            }
            var updated = messages[index]
            updated.status = nil
            guard recordCanonicalMessage(updated) else {
                chatQueue.insert(next, at: 0)
                chatQueuePaused = true
                flashComposerHint(
                    "佇列啟動失敗：canonical transcript journal 無法落盤。")
                return
            }
            persistSelectedThreadMessages()
        }
        let transcriptBeforeQueuedTurn = ChatQueueContextPolicy.transcriptForExecution(
            messages: messages,
            currentMessageID: next.messageID,
            pendingMessageIDs: Set(chatQueue.map(\.messageID)))
        mode = .chat
        queuedUserEchoSuppressionMessageIDs.remove(next.messageID)
        isStartingQueuedChatTurn = true
        let started = startTurn(
            displayTurn: next.displayTurn,
            commandTurn: turnWithThreadTranscriptContext(
                next.commandBaseTurn,
                transcriptMessages: transcriptBeforeQueuedTurn,
                dispatchSnapshot: next.dispatchSnapshot),
            visibleTurn: next.visibleTurn,
            attachmentPaths: next.attachmentPaths,
            previewTurn: next.preview,
            dispatchSnapshot: next.dispatchSnapshot,
            userMessageAlreadyAppended: true,
            sourceUserMessageID: next.messageID,
            commandBaseTurn: next.commandBaseTurn)
        isStartingQueuedChatTurn = false
        if started {
            settleQueuedPlanClarificationStart(messageID: next.messageID)
        } else {
            restoreQueuedPlanClarificationAfterStartFailure(
                messageID: next.messageID)
            startNextChatIfNeeded()
        }
    }

    nonisolated static func parseGitNumstat(
        _ output: String
    ) -> [String: (additions: Int, deletions: Int)] {
        var result: [String: (additions: Int, deletions: Int)] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(
                separator: "\t",
                maxSplits: 2,
                omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let path = String(fields[2])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let additions = Int(fields[0]) ?? 0
            let deletions = Int(fields[1]) ?? 0
            result[path] = (additions, deletions)
        }
        return result
    }

    nonisolated static func readGitChangedFileSummary(
        workdir: String,
        changedPaths: [String]
    ) -> [ChatGitChangedFileSummary] {
        guard !changedPaths.isEmpty else { return [] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--no-optional-locks",
            "-C", workdir,
            "-c", "core.quotepath=false",
            "diff", "--numstat", "--no-ext-diff", "HEAD", "--",
        ]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        process.standardOutput = pipe
        process.standardError = Pipe()
        let numstat: [String: (additions: Int, deletions: Int)]
        do {
            try process.run()
            process.waitUntilExit()
            let raw = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
            numstat = process.terminationStatus == 0
                ? parseGitNumstat(raw)
                : [:]
        } catch {
            numstat = [:]
        }
        return changedPaths.prefix(200).map { path in
            let counts = numstat[path] ?? (0, 0)
            return ChatGitChangedFileSummary(
                path: path,
                additions: counts.additions,
                deletions: counts.deletions)
        }
    }

    nonisolated static func readGitChangedFiles(workdir: String) -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", workdir, "status", "--porcelain=v1", "--untracked-files=all"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { return [] }
            return TatwoCoworkGitStatusParser.changedPaths(fromPorcelain: raw)
        } catch {
            return []
        }
    }

    nonisolated static func compactChangedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: "/")
        }
        return trimmed
    }

    private static func readWhoami(environment: [String: String]) -> String {
        environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
    }

    nonisolated static func readGitBranch(workdir: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workdir, "symbolic-ref", "-q", "--short", "HEAD"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "—" : raw
        } catch {
            return "—"
        }
    }

    nonisolated static func loadCLISessionSnapshots(workspacePath: String) -> [ChatCLISessionSnapshot] {
        var snapshots: [ChatCLISessionSnapshot] = []
        snapshots.append(contentsOf: loadRecentRolloutSnapshots())
        if snapshots.isEmpty {
            snapshots.append(ChatCLISessionSnapshot(
                id: "empty-cli-state",
                title: "尚無最近 session",
                detail: "掃描 Codex sessions rollout 近 48 小時",
                updatedAt: Date(),
                rawPreview: """
                # read-only terminal
                No recent Codex rollout JSONL was found in the local sessions roots.
                cwd=\(redactedPath(workspacePath))
                """,
                isRunning: false))
        }
        return Array(snapshots.prefix(18))
    }

    nonisolated private static func loadRecentRolloutSnapshots() -> [ChatCLISessionSnapshot] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-172_800)
        var files: [URL] = []
        let calendar = Calendar(identifier: .gregorian)
        for home in TatwoCodexSessionActivitySource.defaultCodexHomeCandidates() {
            let root = home.appendingPathComponent("sessions", isDirectory: true)
            for offset in 0...2 {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
                let dir = root
                    .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
                let found = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
                files.append(contentsOf: found.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" })
            }
        }
        var seen = Set<String>()
        let recentFiles = files.compactMap { url -> (url: URL, modified: Date)? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified >= cutoff
            else { return nil }
            return (url, modified)
        }
        .sorted { $0.modified > $1.modified }
        .prefix(24)

        return recentFiles.compactMap { pair -> ChatCLISessionSnapshot? in
            let url = pair.url
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return rolloutSnapshot(url: url, cutoff: cutoff)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    nonisolated private static func rolloutSnapshot(url: URL, cutoff: Date) -> ChatCLISessionSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              modified >= cutoff,
              let lines = rolloutLinePrefix(url: url, maxLines: 120)
        else { return nil }
        var cwd = ""
        var model = "codex-session"
        var provider = ""
        var originator = ""
        var eventTypes: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            eventTypes.append(type)
            guard let payload = object["payload"] as? [String: Any] else { continue }
            if type == "session_meta" {
                cwd = (payload["cwd"] as? String) ?? cwd
                originator = (payload["originator"] as? String) ?? originator
                provider = (payload["model_provider"] as? String) ?? provider
            } else if type == "turn_context" {
                model = (payload["model"] as? String) ?? model
                cwd = (payload["cwd"] as? String) ?? cwd
            }
        }
        let displayID = String(url.deletingPathExtension().lastPathComponent.suffix(8))
        let title = "\(model) · rollout …\(displayID)"
        let detail = "\(relativeTimeString(modified)) · \(URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? "local" : URL(fileURLWithPath: cwd).lastPathComponent)"
        let tailTypes = Array(eventTypes.suffix(14)).enumerated().map { index, type in
            String(format: "%02d  %@", index + 1, type)
        }.joined(separator: "\n")
        let raw = """
        # rollout stream preview (redacted; no full prompt/log persisted)
        file=rollout-…\(displayID).jsonl
        provider=\(provider.isEmpty ? "unknown" : provider)
        originator=\(originator.isEmpty ? "unknown" : originator)
        cwd=\(redactedPath(cwd))
        modified=\(ISO8601DateFormatter().string(from: modified))

        recent event types:
        \(tailTypes.isEmpty ? "—" : tailTypes)
        """
        return ChatCLISessionSnapshot(id: url.standardizedFileURL.path, title: title, detail: detail, updatedAt: modified, rawPreview: raw, isRunning: false)
    }

    nonisolated private static func rolloutLinePrefix(url: URL, maxLines: Int, maxBytes: Int = 256 * 1024) -> [String]? {
        guard maxLines > 0,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        var data = Data()
        var newlineCount = 0
        let chunkSize = 16 * 1024
        while data.count < maxBytes && newlineCount < maxLines {
            let remaining = maxBytes - data.count
            guard remaining > 0,
                  let chunk = try? handle.read(upToCount: min(chunkSize, remaining)),
                  !chunk.isEmpty
            else { break }
            newlineCount += chunk.reduce(0) { count, byte in count + (byte == 10 ? 1 : 0) }
            data.append(chunk)
        }

        guard !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map(String.init)
    }

    nonisolated static func redactedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "—" }
        var value = path
        for home in [NSHomeDirectory(), ProcessInfo.processInfo.environment["HOME"]].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            value = value.replacingOccurrences(of: home, with: "~")
        }
        value = value.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
        value = value.replacingOccurrences(of: #"/(?:private/)?var/folders/[^\s]+"#, with: "/var/folders/…", options: .regularExpression)
        if value.hasPrefix("/Volumes/") {
            let parts = value.split(separator: "/").map(String.init)
            value = parts.suffix(2).joined(separator: "/")
        }
        return value
    }

    private static func engineLaunchHint(_ engine: TatwoNativeCLIEngine?) -> String {
        switch engine {
        case .codex: return "codex 引擎 session：執行 `codex` 啟動 Codex CLI"
        case .claude: return "claude 引擎 session：執行 `claude` 啟動 Claude CLI"
        case .grok: return "grok 引擎 session：執行 `grok-isolated` 啟動 Grok（隔離）"
        case .openclaw: return "openclaw 引擎 session：執行 `openclaw` 操作 gateway"
        case .sandbox, .none: return "sandbox 引擎 session：純 zsh，直接跑命令"
        }
    }

    static func terminalSeed(selection: ChatCLISessionSnapshot?, workdir: String, engine: TatwoNativeCLIEngine?) -> String {
        let title = selection?.title ?? "No selected session"
        let detail = selection?.detail ?? "no session metadata"
        let preview = selection?.rawPreview ?? "# no session selected"
        let engineTag = engine?.rawValue ?? "sandbox"
        return """
        \u{001B}[36mTatwo Native Terminal · engine=\(engineTag)\u{001B}[0m
        selected=\u{001B}[33m\(title)\u{001B}[0m
        detail=\(detail)
        cwd=\(redactedPath(workdir))
        input=direct stdin · buffer throttled · ANSI basic colors · $TATWO_CLI_ENGINE=\(engineTag)

        \u{001B}[90m--- selected session preview ---\u{001B}[0m
        \(preview)
        \u{001B}[90m--- interactive shell output ---\u{001B}[0m
        \u{001B}[32m\(engineLaunchHint(engine))\u{001B}[0m

        """
    }

    nonisolated private static func relativeTimeString(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "剛剛" }
        if seconds < 3600 { return "\(seconds / 60)分前" }
        if seconds < 86_400 { return "\(seconds / 3600)小時前" }
        return "\(seconds / 86_400)天前"
    }
}

import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    func allowMCPTool(named tool: String) {
        // 2026-08-23 補完：也接受內建工具（「先問我」檔位的 Write/Bash 等）。
        guard tool.hasPrefix("mcp__") || Self.allowableBuiltinTools.contains(tool),
              let threadID = selectedThreadID else { return }
        threadAllowedMCPTools[threadID, default: []].insert(tool)
        if tool == "Write" {
            // 檔案寫入一體：Write 放行連帶 Edit，免得下一步又被擋一次。
            threadAllowedMCPTools[threadID, default: []].insert("Edit")
        }
        // 2026-08-23 使用者裁決：「重送的白癡交互」不可以——放行後直接
        // 自動重試上一句，不要使用者手動重貼。
        guard let lastUserPrompt = messages.last(where: { $0.role == .user })?.text,
              !lastUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            appendMessage(ChatMessage(
                role: .system,
                text: "已允許工具 \(tool)（本討論串有效）。",
                status: "tool approved",
                eventKind: .message))
            return
        }
        // 2026-08-23 使用者裁決二修：「按允許就是允許了，不要再重發一次」——
        // 續跑不重貼使用者的話（suppressUserEcho），transcript 只看到
        // 授權確認＋模型接著完成。
        appendMessage(ChatMessage(
            role: .system,
            text: "已允許工具 \(tool)，繼續執行。",
            status: "tool approved",
            eventKind: .message))
        prompt = lastUserPrompt
        submitCurrentChatTurn(suppressUserEcho: true)
    }

    func answerPlanQuestion(_ answer: PlanQuestionAnswerV1) {
        answerPlanQuestions([answer])
    }

    func answerPlanQuestions(_ answers: [PlanQuestionAnswerV1]) {
        let answerBlocks = answers.compactMap { answer -> String? in
        let questionID = answer.questionID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let other = answer.otherText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selections = answer.selectedOptions.filter {
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !questionID.isEmpty,
              answer.skipped || !selections.isEmpty || other?.isEmpty == false
            else { return nil }
        let selectionLines = selections.map { option in
            let detail = option.detail.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "- \(option.label)"
                : "- \(option.label): \(detail)"
        }.joined(separator: "\n")
        return """
            questionID=\(questionID)
            skipped=\(answer.skipped ? "true" : "false")
            selectedOptions:
            \(selectionLines.isEmpty ? "- none" : selectionLines)
            other=\(other?.isEmpty == false ? other! : "none")
            """
        }
        guard !answerBlocks.isEmpty else { return }
        if completePlanQuestionFixtureLocallyIfNeeded(
            answers: answers)
        {
            return
        }
        guard let threadID = selectedThreadID else { return }
        guard let sourceAssistantMessage = messages.last(where: {
            $0.role == .assistant && !$0.planQuestions.isEmpty
        }) else { return }
        guard let sourceSnapshot = planClarificationSourceSnapshot(
            threadID: threadID,
            sourceAssistantMessage: sourceAssistantMessage)
        else { return }
        let acceptedRound =
            planClarificationRoundCountByThread[threadID, default: 0] + 1
        let forceFinal =
            ChatPlanClarificationContinuationPolicy.shouldFinalize(
                answers: answers,
                acceptedRound: acceptedRound)
        prompt = ChatPlanClarificationContinuationPolicy.continuationPrompt(
            answerBlocks: answerBlocks,
            originalObjective:
                planClarificationObjective(threadID: threadID),
            forceFinal: forceFinal)
        let wasRunning = isRunning
        guard submitCurrentChatTurn(suppressUserEcho: true) else {
            // The answer card remains authoritative until a continuation turn
            // is actually accepted. Never leak the internal envelope into the
            // composer after a failed send.
            restorePlanClarificationSource(sourceSnapshot)
            prompt = ""
            return
        }
        if wasRunning, let queuedMessageID = chatQueue.last?.messageID {
            // Queue admission is not runner admission. Hide the answered card
            // while it waits, but defer the accepted-round transition until
            // dequeue-time startTurn succeeds. If that start fails, the exact
            // source questions are restored for a retry.
            queuedPlanClarificationSettlements[queuedMessageID] =
                ChatQueuedPlanClarificationSettlement(
                    source: sourceSnapshot,
                    acceptedRound: acceptedRound)
            consumePendingPlanQuestions(
                assistantMessageID: sourceAssistantMessage.id)
            return
        }
        planClarificationRoundCountByThread[threadID] = acceptedRound
        consumePendingPlanQuestions(
            assistantMessageID: sourceAssistantMessage.id)
    }

    func consumePendingPlanQuestions(
        assistantMessageID: ChatMessage.ID? = nil
    ) {
        guard let assistantIndex = messages.lastIndex(where: {
            $0.role == .assistant
                && !$0.planQuestions.isEmpty
                && (assistantMessageID == nil || $0.id == assistantMessageID)
        }) else { return }
        messages[assistantIndex].planQuestions = []
        guard let threadID = selectedThreadID else { return }
        messageCache[
            TatwoNativeChatSessionReference(kind: .thread, id: threadID)
        ] = messages
        persistSelectedThreadMessages()
    }

    private func planClarificationSourceSnapshot(
        threadID: UUID,
        sourceAssistantMessage: ChatMessage
    ) -> ChatPlanClarificationSourceSnapshot? {
        guard let sourceIndex = messages.lastIndex(where: {
            $0.id == sourceAssistantMessage.id
                && $0.role == .assistant
        }) else { return nil }
        return ChatPlanClarificationSourceSnapshot(
            threadID: threadID,
            message: sourceAssistantMessage,
            originalIndex: sourceIndex,
            previousMessageID:
                sourceIndex > messages.startIndex
                ? messages[messages.index(before: sourceIndex)].id
                : nil,
            nextMessageID:
                messages.index(after: sourceIndex) < messages.endIndex
                ? messages[messages.index(after: sourceIndex)].id
                : nil)
    }

    func settleQueuedPlanClarificationStart(
        messageID: ChatMessage.ID
    ) {
        guard let settlement =
                queuedPlanClarificationSettlements.removeValue(
                    forKey: messageID)
        else { return }
        planClarificationRoundCountByThread[settlement.source.threadID] = max(
            planClarificationRoundCountByThread[
                settlement.source.threadID,
                default: 0],
            settlement.acceptedRound)
    }

    func restoreQueuedPlanClarificationAfterStartFailure(
        messageID: ChatMessage.ID
    ) {
        guard let settlement =
                queuedPlanClarificationSettlements.removeValue(
                    forKey: messageID)
        else { return }
        guard restorePlanClarificationSource(settlement.source) else { return }
        flashComposerHint(
            "Plan 續跑未啟動；澄清卡已恢復，可直接重試。")
    }

    @discardableResult
    private func restorePlanClarificationSource(
        _ snapshot: ChatPlanClarificationSourceSnapshot
    ) -> Bool {
        guard selectedThreadID == snapshot.threadID else { return false }

        let matchingIndices = messages.indices.filter {
            messages[$0].id == snapshot.message.id
        }
        if let sourceIndex = matchingIndices.first {
            if messages[sourceIndex].role == .assistant {
                messages[sourceIndex].planQuestions =
                    snapshot.message.planQuestions
            } else {
                messages[sourceIndex] = snapshot.message
            }
            for duplicateIndex in matchingIndices.dropFirst().reversed() {
                messages.remove(at: duplicateIndex)
            }
        } else {
            let insertionIndex: Int
            if let nextMessageID = snapshot.nextMessageID,
               let nextIndex = messages.firstIndex(where: {
                   $0.id == nextMessageID
               })
            {
                insertionIndex = nextIndex
            } else if let previousMessageID = snapshot.previousMessageID,
                      let previousIndex = messages.lastIndex(where: {
                          $0.id == previousMessageID
                      })
            {
                insertionIndex = messages.index(after: previousIndex)
            } else if let laterFailureIndex = messages.firstIndex(where: {
                $0.role == .assistant
                    && $0.eventKind == .failure
                    && $0.createdAt >= snapshot.message.createdAt
            }) {
                insertionIndex = laterFailureIndex
            } else {
                insertionIndex = min(snapshot.originalIndex, messages.endIndex)
            }
            messages.insert(snapshot.message, at: insertionIndex)
        }

        messageCache[
            TatwoNativeChatSessionReference(
                kind: .thread,
                id: snapshot.threadID)
        ] = messages
        persistSelectedThreadMessages()
        return true
    }

    private func planClarificationObjective(threadID: UUID) -> String? {
        let storedArtifact =
            activePlanArtifact?.threadID == threadID
            ? activePlanArtifact
            : try? planArtifactStore?.load(threadID: threadID)
        let boundUserTurn = messages.reversed().first(where: {
            $0.role == .user
                && !ChatPlanClarificationContinuationPolicy
                    .isClarificationEnvelope($0.text)
        })?.text
        return ChatPlanClarificationContinuationPolicy.recoveredObjective(
            bindingObjective: nil,
            pendingObjective: pendingPlanObjectives[threadID],
            existingObjective: storedArtifact?.objective,
            boundUserTurn: boundUserTurn)
    }

    /// The export fixture is a UI rehearsal, not a model-routing test. Finish
    /// its question flow locally so interacting with the staging card cannot
    /// accidentally start a real Codex/Claude/Grok runner.
    private func completePlanQuestionFixtureLocallyIfNeeded(
        answers: [PlanQuestionAnswerV1]
    ) -> Bool {
        let planFixtureScene = coldStartEnvironment[
            "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE"
        ]
        guard coldStartEnvironment["TATWO_ULTRAWORK_CHAT_FIXTURE"]
                == "chat-transcript",
              ["questions", "questions-zh-hant"].contains(planFixtureScene),
              let threadID = selectedThreadID
        else {
            return false
        }
        let usesTraditionalChinese = planFixtureScene == "questions-zh-hant"

        var sourceAssistantMessageID: String?
        if let assistantIndex = messages.lastIndex(where: {
            $0.role == .assistant && !$0.planQuestions.isEmpty
        }) {
            sourceAssistantMessageID = messages[assistantIndex].id
            messages[assistantIndex].planQuestions = []
            messages[assistantIndex].status = nil
            messages[assistantIndex].text =
                usesTraditionalChinese
                ? "我已依照你的回答更新計畫。"
                : "I updated the plan from your clarification answers."
        }
        messageCache[
            TatwoNativeChatSessionReference(kind: .thread, id: threadID)
        ] = messages
        persistSelectedThreadMessages()

        pendingPlanObjectives[threadID] =
            pendingPlanObjectives[threadID]
            ?? (usesTraditionalChinese
                ? "規劃一個安全的中文專案匯入流程"
                : "Design a safe project import flow")
        let selectedLabels = answers
            .flatMap { answer in
                let optionLabels = answer.selectedOptions.map(\.label)
                let other = answer.otherText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return optionLabels
                    + (other?.isEmpty == false ? [other!] : [])
            }
            .joined(separator: ", ")
        let clarificationLines = answers.map { answer in
            let label: String
            switch answer.questionID {
            case "import-scope":
                label = "Import scope"
            case "validation":
                label = "Validation paths"
            case "import-scope-zh-hant":
                label = "匯入範圍"
            case "validation-zh-hant":
                label = "驗證路徑"
            default:
                label = answer.questionID
            }
            let other = answer.otherText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let values = answer.selectedOptions.map(\.label)
                + (other?.isEmpty == false ? [other!] : [])
            let rendered = answer.skipped
                ? (usesTraditionalChinese ? "略過" : "Skipped")
                : (values.isEmpty
                    ? (usesTraditionalChinese ? "未回答" : "No answer")
                    : values.joined(
                        separator: usesTraditionalChinese ? "、" : ", "))
            return usesTraditionalChinese
                ? "- \(label)：\(rendered)"
                : "- \(label): \(rendered)"
        }.joined(separator: "\n")
        let response: String
        if usesTraditionalChinese {
            response = """
                # 計畫

                ## 背景

                保持現有專案資料來源的權威性，並確保匯入流程可以復原。

                ## 釐清結果

                \(clarificationLines)

                ## 實作步驟

                1. 驗證所選資料夾與匯入範圍。
                2. 預覽中繼資料與選定的驗證路徑（\(selectedLabels.isEmpty ? "未選擇" : selectedLabels)）。
                3. 使用者明確確認後才寫入。

                ## 驗證

                覆蓋選定的介面與資料保存路徑、取消操作、格式錯誤資料，以及重新啟動後的復原。
                """
        } else {
            response = """
                # Plan

                ## Context

                Keep the existing project store authoritative and make the import \
                flow reversible.

                ## Clarifications

                \(clarificationLines)

                ## Implementation

                1. Validate the selected folder and import scope.
                2. Preview the metadata and selected validation paths \
                (\(selectedLabels.isEmpty ? "none selected" : selectedLabels)).
                3. Persist only after explicit confirmation.

                ## Validation

                Exercise the selected UI and persistence paths, cancellation, \
                malformed metadata, and restart recovery.
                """
        }
        updatePlanArtifactFromCompletedResponse(
            response,
            threadID: threadID,
            assistantMessageID: sourceAssistantMessageID)
        prompt = ""
        isRunning = false
        activeAssistantID = nil
        activePlanTurnBinding = nil
        return true
    }

    func handlePlanQuestionAnswerNotification(_ notification: Notification) {
        if let batch = notification.object as? PlanQuestionResponseBatchV1 {
            answerPlanQuestions(batch.answers)
        } else if let answer = notification.object as? PlanQuestionAnswerV1 {
            answerPlanQuestion(answer)
        }
    }

    var planFlowSelectionProjection: PlanFlowSelectionProjectionV1? {
        guard let selection = activePlanArtifact?.planFlowSelection else {
            return nil
        }
        return PlanFlowSelectionProjectionV1(
            selection: selection,
            missingSelections: selection.missingSelections)
    }

    func updatePlanFlowSelection(
        _ selection: TatwoPlanArtifactV1.PlanFlowSelectionV1
    ) {
        guard var artifact = activePlanArtifact else { return }
        artifact.planFlowSelection = selection
        artifact.updateDiscussion(
            objective: artifact.objective,
            sections: artifact.sections)
        _ = persistPlanArtifact(artifact)
    }

    func isMCPToolAllowed(_ tool: String) -> Bool {
        selectedThreadID.map {
            threadAllowedMCPTools[$0]?.contains(tool) == true
        } ?? false
    }
}

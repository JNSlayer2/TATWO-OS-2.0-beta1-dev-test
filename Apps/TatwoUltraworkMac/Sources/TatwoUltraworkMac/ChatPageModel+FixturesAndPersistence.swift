import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    func installChatTranscriptFixtureIfRequested(environment: [String: String]) {
        let goldenScene =
            TatwoExportChatGoldenScene.resolve(environment: environment)
        let completionReportFixture =
            environment[
                "TATWO_ULTRAWORK_CHAT_COMPLETION_REPORT_FIXTURE"] == "1"
        guard environment["TATWO_ULTRAWORK_CHAT_FIXTURE"] == "chat-transcript"
                || goldenScene != nil
                || completionReportFixture
        else { return }
        let workdir = URL(fileURLWithPath: workspacePath.isEmpty ? FileManager.default.currentDirectoryPath : workspacePath)
        let template = coworkTemplates.first { $0.id == selectedCoworkTemplateID } ?? coworkTemplates.first
        let fixtureLoopsConfig = environment["TATWO_ULTRAWORK_CHAT_FIXTURE_COLLAB"] == "1"
            ? template.map { loopsConfig(for: $0) }
            : nil
        let startedAt = Date().addingTimeInterval(-420)
        let rows: [ChatMessage]
        if completionReportFixture {
            let completedAssistantID = "fixture-completion-assistant"
            rows = [
                ChatMessage(
                    id: "fixture-completion-user",
                    role: .user,
                    text:
                        "把思考與工具步驟收納成 Codex App 的交互，完成後顯示本輪工作報告。",
                    eventKind: .message,
                    createdAt: startedAt),
                ChatMessage(
                    id: "fixture-completion-thinking",
                    role: .assistant,
                    text: "比對完成訊息、思考收納與工作報告的層級",
                    status: "completed|比對 Codex App 完成交互",
                    modelID: "gpt-5.6-sol",
                    eventKind: .thinking,
                    turnID: completedAssistantID,
                    createdAt: startedAt.addingTimeInterval(12)),
                ChatMessage(
                    id: "fixture-completion-tool",
                    role: .assistant,
                    text:
                        "swift test --filter ChatPlanThoughtPresentationTests",
                    status: "completed|驗證思考收納與完成報告",
                    modelID: "gpt-5.6-sol",
                    eventKind: .toolUse,
                    turnID: completedAssistantID,
                    createdAt: startedAt.addingTimeInterval(24)),
                ChatMessage(
                    id: completedAssistantID,
                    role: .assistant,
                    text:
                        "已完成。思考與工具步驟會集中收納；工作完成後，回答下方直接顯示本輪編輯檔案與增減行數。",
                    status: "done",
                    modelID: "gpt-5.6-sol",
                    eventKind: .message,
                    turnID: completedAssistantID,
                    createdAt: startedAt.addingTimeInterval(36)),
            ]
        } else {
            rows = [
            ChatMessage(
                id: "fixture-chat-user",
                role: .user,
                text: "N10：把 Chat 分頁拉近 Codex App；只保留有實際用途的 UI。",
                status: nil,
                eventKind: .message,
                createdAt: startedAt),
            ChatMessage(
                id: "fixture-chat-assistant",
                role: .assistant,
                text: "已收斂到 Codex-parity：左列 hover、右側 Thread 卡、底部 composer 維持同一層級；60fps 只轉成語義深度與 hover，不新增 3D 裝飾。",
                status: "done",
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(42)),
            ChatMessage(
                id: "fixture-chat-tool",
                role: .assistant,
                text: "swift build --product TatwoUltraworkMac\nBuild complete · no Swift warning promoted to error in this pass",
                status: "tool",
                eventKind: .toolUse,
                createdAt: startedAt.addingTimeInterval(90)),
            ChatMessage(
                id: "fixture-chat-thinking",
                role: .assistant,
                text: "UI loop: transcript rows should stay narrower than the window, align with the composer, and avoid duplicating right-card metadata.",
                status: "folded",
                eventKind: .thinking,
                createdAt: startedAt.addingTimeInterval(120)),
            ChatMessage(
                id: "fixture-chat-user-2",
                role: .user,
                text: "歷史 minimap 的預覽筐要浮在 hover 那一格旁邊。",
                status: nil,
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(150)),
            ChatMessage(
                id: "fixture-chat-assistant-2",
                role: .assistant,
                text: "已改：預覽筐垂直對齊該格中心並夾在可視範圍內；格子加寬到 9、hover 有高亮膠囊與橫向長出特效。",
                status: "done",
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(180)),
            ChatMessage(
                id: "fixture-chat-user-3",
                role: .user,
                text: "順便確認 fable5 牛皮紙材質在這裡也一致。",
                status: nil,
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(210)),
            ChatMessage(
                id: "fixture-chat-assistant-3",
                role: .assistant,
                text: "matertheme 分支正確：aurora 玻璃、fable5 啞光牛皮紙，minimap 刻度與預覽筐都吃 brandAccent。",
                status: "done",
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(240)),
            ChatMessage(
                id: "fixture-chat-user-4",
                role: .user,
                text: "最後看一下整體節奏。",
                status: nil,
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(270)),
            ChatMessage(
                id: "fixture-chat-assistant-4",
                role: .assistant,
                text: "節奏 OK：首句與交通燈有 50pt 區隔、composer 貼底、右列收納。",
                status: "done",
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(300)),
            ChatMessage(
                id: "fixture-chat-timeline-reasoning",
                role: .assistant,
                text: "把模型思考與執行步驟收進同一條可展開 timeline。",
                status: "completed|整合模型思考與執行步驟",
                modelID: "gpt-5.6-sol",
                eventKind: .thinking,
                turnID: TatwoChatTranscriptFixtureState.activeInlineMessageID,
                createdAt: startedAt.addingTimeInterval(310)),
            ChatMessage(
                id: "fixture-chat-timeline-command",
                role: .assistant,
                text: "swift test --filter ChatInlineWorkTimelinePresentationTests",
                status: "completed|swift test --filter ChatInlineWorkTimelinePresentationTests",
                modelID: "gpt-5.6-sol",
                eventKind: .toolUse,
                turnID: TatwoChatTranscriptFixtureState.activeInlineMessageID,
                createdAt: startedAt.addingTimeInterval(320)),
            ChatMessage(
                id: TatwoChatTranscriptFixtureState.activeInlineMessageID,
                role: .assistant,
                text: "",
                status: "thinking|檢查完成後的自動收納",
                modelID: "gpt-5.6-sol",
                eventKind: .message,
                turnID: TatwoChatTranscriptFixtureState.activeInlineMessageID,
                createdAt: startedAt.addingTimeInterval(330))
            ]
        }
        // #16 demo loops sessions（收納串雛形自驗）：監工繼承 thread 主導。
        let demoSupervisor = fixtureLoopsConfig?.primaryModelID ?? "fable5"
        let demoReviewer = fixtureLoopsConfig?.secondaryModelID ?? "gpt-5.6-terra"
        var loopRunning = TatwoLoopsSupervisorRule.make(
            parentSupervisorModelID: demoSupervisor,
            parentKind: .thread, parentID: UUID(), projectID: UUID(),
            title: "minimap 收斂 loop",
            plg: TatwoLoopsPLG(
                plan: "把歷史 minimap 的預覽筐貼到 hover 那一格旁邊，格子加寬並加交互特效。",
                loops: "主導：\(TatwoChatRouteProfile.resolve(demoSupervisor).displayName)／副審：\(TatwoChatRouteProfile.resolve(demoReviewer).displayName) 帶 2 sub",
                goal: "render 實證預覽筐位置正確、fable5 材質一致。"),
            reviewerModelID: demoReviewer)
        loopRunning.status = .running
        loopRunning.cycles = [TatwoLoopsCycleProgress(round: 2, totalRounds: 3, producedCount: 6, verifiedCount: 4, blockedCount: 1)]
        loopRunning.subAgents = [
            TatwoLoopsSubAgent(id: UUID(), label: "sub·render", modelID: "gpt-5.6-sol", status: .passed),
            TatwoLoopsSubAgent(id: UUID(), label: "sub·tooltip-pos", modelID: "gpt-5.6-sol", status: .running)
        ]
        loopRunning.messages = [
            TatwoLoopsMessage(id: UUID(), role: "supervisor", authorModelID: demoSupervisor, text: "sub 們把 tooltip offset 對齊 tick 中心，回報 render。", createdISO: ""),
            TatwoLoopsMessage(id: UUID(), role: "sub", authorModelID: "gpt-5.6-sol", text: "render 已確認：預覽筐貼在 hover 格旁。", createdISO: "")
        ]
        // 真實多 sub loop（fable5 監工並行派 3× gpt-5.6-sol 盤點 #16 交付，唯讀零改動）。
        var loopPlanned = TatwoLoopsSupervisorRule.make(
            parentSupervisorModelID: demoSupervisor,
            parentKind: .thread, parentID: UUID(), projectID: UUID(),
            title: "盤點 #16 交付 loop（3 sub 並行）",
            plg: TatwoLoopsPLG(
                plan: "盤點 #16 loops 交付的型別／UI／測試三面。",
                loops: "主導：\(TatwoChatRouteProfile.resolve(demoSupervisor).displayName) → 3× gpt-5.6-sol 並行 sub",
                goal: "各 sub 回可查證收據，監工交叉彙整。"),
            reviewerModelID: nil)
        loopPlanned.status = .passed
        loopPlanned.cycles = [TatwoLoopsCycleProgress(round: 1, totalRounds: 1, producedCount: 3, verifiedCount: 3, blockedCount: 0)]
        loopPlanned.subAgents = [
            TatwoLoopsSubAgent(id: UUID(), label: "sub·型別", modelID: "gpt-5.6-sol", status: .passed),
            TatwoLoopsSubAgent(id: UUID(), label: "sub·UI", modelID: "gpt-5.6-sol", status: .passed),
            TatwoLoopsSubAgent(id: UUID(), label: "sub·測試", modelID: "gpt-5.6-sol", status: .passed)
        ]
        loopPlanned.messages = [
            TatwoLoopsMessage(id: UUID(), role: "supervisor", authorModelID: demoSupervisor, text: "並行派 3 sub：型別／UI／測試盤點，各回收據。", createdISO: ""),
            TatwoLoopsMessage(id: UUID(), role: "sub", authorModelID: "gpt-5.6-sol", text: "型別：9 public 型別、51 API；前 7 型別全 Codable/Sendable/Equatable/Hashable/Identifiable。", createdISO: ""),
            TatwoLoopsMessage(id: UUID(), role: "sub", authorModelID: "gpt-5.6-sol", text: "UI：6 區（收納列/PLG/cycles/訊息串/發話/動作）、4 角色、訊息封頂 40。", createdISO: ""),
            TatwoLoopsMessage(id: UUID(), role: "sub", authorModelID: "gpt-5.6-sol", text: "測試：16 tests（Core 8 + Planner 8），涵蓋監工不變/fold/briefing/round。", createdISO: ""),
            TatwoLoopsMessage(id: UUID(), role: "supervisor", authorModelID: demoSupervisor, text: "三面交叉一致，無擴權、全唯讀。多 sub 協作正常，收單。", createdISO: "")
        ]

        let thread = TatwoNativeChatThread(
            id: TatwoChatTranscriptFixtureState.threadID,
            title: completionReportFixture
                ? "Codex 完成交互驗收"
                : "N10 transcript visual check",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            createdAt: startedAt,
            updatedAt: Date(),
            isPinned: true,
            lastPreview: completionReportFixture
                ? "思考收納與完成報告"
                : "Codex-parity transcript rows",
            loopsConfig: fixtureLoopsConfig,
            threadPluginIDs: ["chatgpt-pro-mcp"],
            discussions: [],
            loopsSessions: [loopRunning, loopPlanned],
            messages: rows.map(\.storedRecord))
        let standaloneThread = TatwoNativeChatThread(
            id: UUID(uuidString: "74D801D4-5E43-4E6E-B247-78BC7E6D8E5E")!,
            title: "一般 thread smoke",
            createdAt: startedAt.addingTimeInterval(-180),
            updatedAt: startedAt.addingTimeInterval(-60),
            lastPreview: "不屬於任何 project 的一般聊天",
            messages: [
                ChatMessage(
                    id: "fixture-standalone-user",
                    role: .user,
                    text: "一般 thread 不應該塞進專案底下。",
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(-180)
                ).storedRecord
            ])
        var fixtureThreads = [thread]
        if environment["TATWO_ULTRAWORK_CHAT_ARCHIVED_FIXTURE"] == "1" {
            fixtureThreads.append(TatwoNativeChatThread(
                title: "N10 archived restore target",
                createdAt: startedAt.addingTimeInterval(-240),
                updatedAt: Date().addingTimeInterval(-120),
                isArchived: true,
                lastPreview: "Soft archived; restore path proof",
                loopsConfig: fixtureLoopsConfig))
        }
        let project = TatwoNativeChatProject(
            name: completionReportFixture
                ? "Tatwo Codex parity fixture"
                : "Tatwo UI loop fixture",
            workdir: workdir.path,
            isExpanded: true,
            threads: fixtureThreads)
        document = TatwoNativeChatStoreDocument(threads: [standaloneThread], projects: [project])
        migrateLegacyDocumentTranscriptsIfNeeded()
        reconcileColdStartTranscriptOrphans(
            authority: coldStartRunnerAuthoritySnapshot)
        selectedProjectID = project.id
        selectedThreadID = thread.id
        switch ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_LOOP_EXPAND"] {
        case "1": selectedLoopsSessionID = loopRunning.id
        case "2": selectedLoopsSessionID = loopPlanned.id
        default: break
        }
        // #16 /plg demo（headless 自驗）：多主導→對抗→授權→執行 分支。
        // "planning" → 停在 Plan 討論相位（驗證確認計畫按鈕）；"1" → 走到執行分支。
        let plgDemo = environment["TATWO_ULTRAWORK_PLG_DEMO"]
        if plgDemo == "planning" {
            let pnow = Self.plgISO()
            let prun = TatwoPLGRunFactory.make(
                objective: "重構 tab 系統對齊 Codex App（Plan 討論中）",
                contractID: "demo-plg-c", goalID: "demo-plg-g",
                leadModelIDs: ["fable5", "gpt-5.6-sol"],
                subModelIDs: ["gpt-5.6-sol", "gpt-5.6-terra"], nowISO: pnow)
            activePLGRun = prun  // 停在 .planning
        } else if plgDemo == "1" {
            let pnow = Self.plgISO()
            var prun = TatwoPLGRunFactory.make(
                objective: "重構 tab 系統對齊 Codex App",
                contractID: "demo-plg-c", goalID: "demo-plg-g",
                leadModelIDs: ["fable5", "gpt-5.6-sol"],
                subModelIDs: ["gpt-5.6-sol", "gpt-5.6-terra"], nowISO: pnow)
            if let t = try? TatwoPLGOrchestrator.advanceFromPlanning(prun, expectedRevision: prun.revision, eventID: UUID()) { prun = t.run }
            if let t = try? TatwoPLGOrchestrator.setAdversarialConclusion("app=console／單一 ledger／身份組非寫死 定案", in: prun, expectedRevision: prun.revision, eventID: UUID()) { prun = t.run }
            let rc = TatwoPLGHumanAuthReceipt(
                receiptID: "demo-ungoverned-human-auth",
                actor: "human",
                issuedISO: pnow,
                expiresISO: Self.plgISO(3600),
                scope: "execute",
                contractID: "demo-plg-c")
            if let t = try? TatwoPLGOrchestrator.authorize(receipt: rc, nowISO: pnow, in: prun, expectedRevision: prun.revision, eventID: UUID()) { prun = t.run }
            let leftObjective = "左列 hover 收納重構"
            let leftPlanSlice = "[ui] 左列資訊層級、hover 收納與點擊區驗證"
            let leftSourceLoopID = "demo-loop-ui-left"
            let leftDomainLoopID = TatwoPLGOrchestrator.makeDomainLoopID(
                contractID: prun.contractID,
                domain: .ui,
                sourceLoopID: leftSourceLoopID)
            let leftTests = ["demo visual smoke"]
            let leftReceipt = TatwoPLGDomainReceipt(
                domainLoopID: leftDomainLoopID,
                objectiveHash: TatwoObjectiveIdentity.make(leftObjective).objectiveHash,
                inputsDigest: TatwoArtifactReviewHasher.sha256(leftPlanSlice),
                artifactsDigest: TatwoPLGOrchestrator.makeArtifactsDigest(
                    testsRun: leftTests),
                verdict: .pass,
                testsRun: leftTests)
            let rightObjective = "右側 Thread 卡對齊"
            let rightPlanSlice = "[code] Thread 卡 layout 與狀態投影"
            let rightSourceLoopID = "demo-loop-code-right"
            prun.branchGoals = [
                TatwoPLGBranchGoal(
                    objective: leftObjective,
                    subLabel: "sub·左列",
                    subBindingID: "role-sub-gpt-5.6-sol",
                    status: .passed,
                    reason: nil,
                    attempt: 1,
                    deadlineISO: nil,
                    reportedToMainline: true,
                    domainLoopID: leftDomainLoopID,
                    domain: .ui,
                    sourceLoopID: leftSourceLoopID,
                    ownerIdentity: .sub,
                    planSlice: leftPlanSlice,
                    domainReceipt: leftReceipt),
                TatwoPLGBranchGoal(
                    objective: rightObjective,
                    subLabel: "sub·右卡",
                    subBindingID: "role-sub-gpt-5.6-terra",
                    status: .running,
                    reason: nil,
                    attempt: 1,
                    deadlineISO: nil,
                    reportedToMainline: false,
                    domainLoopID: TatwoPLGOrchestrator.makeDomainLoopID(
                        contractID: prun.contractID,
                        domain: .code,
                        sourceLoopID: rightSourceLoopID),
                    domain: .code,
                    sourceLoopID: rightSourceLoopID,
                    ownerIdentity: .sub,
                    planSlice: rightPlanSlice,
                    domainReceipt: nil)
            ]
            activePLGRun = prun
        }
        workspacePath = workdir.path
        mode = .chat
        let exportEffort = selectedEffort
        selectedModel = "gpt-5.5"
        if routeChoice.allowedEfforts.contains(exportEffort) {
            selectedEffort = exportEffort
        }
        prompt = ""
        messages = rows
        messageCache[TatwoNativeChatSessionReference(kind: .thread, id: thread.id)] = rows
        replaySelectedTranscriptMessages()
        // Canonical reconnect correctly seals out any persisted in-flight
        // status.  This export-only fixture must then restore a memory-only
        // active tail so snapshots exercise the real Codex-style inline
        // activity row and Stop affordance instead of an inert ellipsis.
        // Export-only state overlay (TATWO_ULTRAWORK_CHAT_FIXTURE_STATE) may
        // terminally update that same identity for negative-state screenshots.
        messages = rows
        messageCache[TatwoNativeChatSessionReference(kind: .thread, id: thread.id)] = rows
        activeAssistantID = completionReportFixture
            ? nil
            : TatwoChatTranscriptFixtureState.activeInlineMessageID
        isRunning = !completionReportFixture
        gitChangedFileCount = 0
        gitChangedFilePreview = []
        gitChangedFiles = []
        gitChangedLineAdditions = 0
        gitChangedLineDeletions = 0
        if environment["TATWO_ULTRAWORK_CHAT_FIXTURE_GOAL"] == "1" {
            ensureSelectedThreadWorkOSContract(
                objectiveHint: rows.first(where: { $0.role == .user })?.text,
                allowCreateIfUnbound: true)
        } else {
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            selectedWorkOSStateMessage = "fixture chat 無自動 GoalRun；送出 chat request 後才建立"
        }
        if completionReportFixture {
            gitBranch = "integ/browser-converge-20260831"
            gitChangedFiles = [
                ChatGitChangedFileSummary(
                    path:
                        "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageLeafViews.swift",
                    additions: 18,
                    deletions: 17),
                ChatGitChangedFileSummary(
                    path:
                        "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/ChatPlanThoughtPresentationTests.swift",
                    additions: 5,
                    deletions: 1),
            ]
            gitChangedFileCount = 2
            gitChangedFilePreview =
                gitChangedFiles.map { Self.compactChangedPath($0.path) }
            gitChangedLineAdditions = 23
            gitChangedLineDeletions = 18
        } else {
            exportChatTranscriptFixtureContext = (
                historyRows: rows,
                threadID: thread.id,
                startedAt: startedAt)
            applyExportOnlyChatTranscriptFixtureState(
                TatwoChatTranscriptFixtureState.resolve(
                    environment[
                        TatwoChatTranscriptFixtureState.environmentKey]))
        }
        if let goldenScene {
            applyExportOnlyChatGoldenScene(
                goldenScene,
                projectThread: thread,
                orphanThread: standaloneThread,
                startedAt: startedAt)
        }
        applyExportOnlyPlanParityFixtureIfRequested(
            environment: environment,
            threadID: thread.id,
            startedAt: startedAt)
        if !completionReportFixture {
            refreshGitBranch()
        }
    }

    /// Static UI-only scenes for /plan parity review. They never dispatch a
    /// model and remain inside the fixture store selected above.
    private func applyExportOnlyPlanParityFixtureIfRequested(
        environment: [String: String],
        threadID: UUID,
        startedAt: Date
    ) {
        guard let scene = environment[
            "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !scene.isEmpty
        else { return }

        setPlanModeEnabled(true)
        let usesTraditionalChinese = scene == "questions-zh-hant"
        let user = ChatMessage(
            id: "fixture-plan-user",
            role: .user,
            text: usesTraditionalChinese
                ? "/plan 規劃一個安全的中文專案匯入流程，包含驗證、復原與使用者確認，只做規劃不要修改檔案"
                : "/plan Design a safe project import flow",
            eventKind: .message,
            createdAt: startedAt)
        activePlanArtifact = nil
        activePlanTurnBinding = nil
        activeAssistantID = nil

        switch scene {
        case "writing":
            let assistantID = "fixture-plan-writing"
            messages = [
                user,
                ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    text: "",
                    status: "streaming",
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(1)),
            ]
            activeAssistantID = assistantID
            pendingPlanObjectives[threadID] =
                "Design a safe project import flow"
            activePlanTurnBinding = ChatPlanTurnBinding(
                threadID: threadID,
                sourceUserMessageID: user.id,
                assistantMessageID: assistantID,
                objectiveCandidate:
                    "Design a safe project import flow",
                startingPlanID: nil,
                startingObjective: nil,
                startingArtifactUpdatedAt: nil)
            isRunning = true

        case "summary":
            messages = [
                user,
                ChatMessage(
                    id: "fixture-plan-summary-assistant",
                    role: .assistant,
                    text: "I drafted the implementation plan.",
                    status: nil,
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(2)),
            ]
            activePlanArtifact = TatwoPlanArtifactV1(
                threadID: threadID,
                objective: "Design a safe project import flow",
                sections: [
                    .init(
                        title: "Context",
                        body:
                            "Keep the existing project store authoritative and avoid changing credentials or live sessions."),
                    .init(
                        title: "Implementation",
                        body:
                            "1. Validate the selected folder.\n2. Preview imported metadata.\n3. Commit only after confirmation."),
                    .init(
                        title: "Validation",
                        body:
                            "Exercise cancellation, duplicate imports, malformed metadata, and restart recovery."),
                ],
                sourceAssistantMessageID:
                    "fixture-plan-summary-assistant")
            isRunning = false

        case "long-summary":
            messages = [
                user,
                ChatMessage(
                    id: "fixture-plan-long-summary-assistant",
                    role: .assistant,
                    text: "I drafted the implementation plan.",
                    status: nil,
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(2)),
            ]
            activePlanArtifact = TatwoPlanArtifactV1(
                threadID: threadID,
                objective: "Design a safe project import flow",
                sections: [
                    .init(
                        title: "Context",
                        body:
                            "Keep the existing project store authoritative and avoid changing credentials or live sessions."),
                    .init(
                        title: "Implementation",
                        body: (1...48).map {
                            "\($0). Validate import checkpoint \($0)."
                        }.joined(separator: "\n")),
                    .init(
                        title: "Validation",
                        body:
                            "Exercise cancellation, duplicate imports, malformed metadata, and restart recovery."),
                    .init(
                        title: "Rollback",
                        body:
                            "Restore the previous project snapshot without overwriting backups."),
                ],
                sourceAssistantMessageID:
                    "fixture-plan-long-summary-assistant")
            isRunning = false

        case "anchor-failure":
            messages = [
                user,
                ChatMessage(
                    id: "fixture-plan-summary-assistant",
                    role: .assistant,
                    text: "I drafted the implementation plan.",
                    status: nil,
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(2)),
                ChatMessage(
                    id: "fixture-plan-retry-user",
                    role: .user,
                    text: "/plan Refine the validation details",
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(3)),
                ChatMessage(
                    id: "fixture-plan-failed-assistant",
                    role: .assistant,
                    text: "The model request failed.",
                    status: "failed",
                    eventKind: .failure,
                    createdAt: startedAt.addingTimeInterval(4)),
            ]
            activePlanArtifact = TatwoPlanArtifactV1(
                threadID: threadID,
                objective: "Design a safe project import flow",
                sections: [
                    .init(
                        title: "Validation",
                        body:
                            "Exercise cancellation, malformed metadata, and restart recovery."),
                ],
                sourceAssistantMessageID:
                    "fixture-plan-summary-assistant")
            isRunning = false

        case "existing-plan-writing":
            let writingAssistantID =
                "fixture-plan-existing-artifact-writing-assistant"
            messages = [
                user,
                ChatMessage(
                    id: "fixture-plan-summary-assistant",
                    role: .assistant,
                    text: "I drafted the implementation plan.",
                    status: nil,
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(2)),
                ChatMessage(
                    id: "fixture-plan-follow-up-user",
                    role: .user,
                    text: "/plan Refine the validation details",
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(3)),
                ChatMessage(
                    id: writingAssistantID,
                    role: .assistant,
                    text: "",
                    status: "streaming",
                    eventKind: .message,
                    createdAt: startedAt.addingTimeInterval(4)),
            ]
            activePlanArtifact = TatwoPlanArtifactV1(
                threadID: threadID,
                objective: "Design a safe project import flow",
                sections: [
                    .init(
                        title: "Validation",
                        body:
                            "Exercise cancellation, malformed metadata, and restart recovery."),
                ],
                sourceAssistantMessageID:
                    "fixture-plan-summary-assistant")
            activeAssistantID = writingAssistantID
            pendingPlanObjectives[threadID] =
                "Refine the validation details"
            activePlanTurnBinding = ChatPlanTurnBinding(
                threadID: threadID,
                sourceUserMessageID: "fixture-plan-follow-up-user",
                assistantMessageID: writingAssistantID,
                objectiveCandidate: "Refine the validation details",
                startingPlanID: activePlanArtifact?.planID,
                startingObjective: activePlanArtifact?.objective,
                startingArtifactUpdatedAt:
                    activePlanArtifact?.updatedAt)
            isRunning = true

        case "questions":
            pendingPlanObjectives[threadID] =
                "Design a safe project import flow"
            messages = [
                user,
                ChatMessage(
                    id: "fixture-plan-questions-assistant",
                    role: .assistant,
                    text: "",
                    status: "waiting",
                    eventKind: .message,
                    planQuestions: [
                        PlanQuestionV1(
                            id: "import-scope",
                            question: "Which import scope should the plan target?",
                            options: [
                                .init(
                                    label: "Current project",
                                    detail: "Keep the change narrow and reversible."),
                                .init(
                                    label: "All projects",
                                    detail: "Broader migration with more validation."),
                            ]),
                        PlanQuestionV1(
                            id: "validation",
                            question: "Which validation paths are required?",
                            options: [
                                .init(
                                    label: "UI flow",
                                    detail: "Cover visible import interactions."),
                                .init(
                                    label: "Persistence",
                                    detail: "Cover restart and durable state."),
                                .init(
                                    label: "Recovery",
                                    detail: "Cover cancellation and malformed data."),
                            ],
                            allowsMultipleSelections: true),
                    ],
                    createdAt: startedAt.addingTimeInterval(2)),
            ]
            isRunning = false

        case "questions-zh-hant":
            pendingPlanObjectives[threadID] =
                "規劃一個安全的中文專案匯入流程"
            messages = [
                user,
                ChatMessage(
                    id: "fixture-plan-questions-zh-hant-assistant",
                    role: .assistant,
                    text: "",
                    status: "waiting",
                    eventKind: .message,
                    planQuestions: [
                        PlanQuestionV1(
                            id: "import-scope-zh-hant",
                            question: "這份計畫要處理哪個匯入範圍？",
                            options: [
                                .init(
                                    label: "目前專案",
                                    detail: "維持範圍精簡且容易復原。"),
                                .init(
                                    label: "所有專案",
                                    detail: "涵蓋較廣的遷移範圍並增加驗證。"),
                            ]),
                        PlanQuestionV1(
                            id: "validation-zh-hant",
                            question: "需要涵蓋哪些驗證路徑？",
                            options: [
                                .init(
                                    label: "介面流程",
                                    detail: "驗證使用者看得到的匯入互動。"),
                                .init(
                                    label: "資料保存",
                                    detail: "驗證重新啟動與持久狀態。"),
                                .init(
                                    label: "復原流程",
                                    detail: "驗證取消操作與格式錯誤資料。"),
                            ],
                            allowsMultipleSelections: true),
                    ],
                    createdAt: startedAt.addingTimeInterval(2)),
            ]
            isRunning = false

        case "contract":
            pendingPlanObjectives[threadID] =
                "Design a safe project import flow"
            messages = [
                user,
                ChatMessage(
                    id: "fixture-plan-contract-assistant",
                    role: .assistant,
                    text: "",
                    status: "waiting",
                    eventKind: .message,
                    planQuestions: [
                        PlanQuestionV1(
                            id: "import-scope-contract",
                            question: "Which import scope should the plan target?",
                            options: [
                                .init(
                                    label: "Current project (Recommended)",
                                    detail: "Keep the change narrow and reversible."),
                                .init(
                                    label: "All projects",
                                    detail: "Broader migration with more validation."),
                            ],
                            allowsOtherResponse: false),
                    ],
                    createdAt: startedAt.addingTimeInterval(2)),
            ]
            isRunning = false

        default:
            return
        }

        let reference = TatwoNativeChatSessionReference(
            kind: .thread,
            id: threadID)
        messageCache[reference] = messages
    }

    private func applyExportOnlyChatGoldenScene(
        _ scene: TatwoExportChatGoldenScene,
        projectThread: TatwoNativeChatThread,
        orphanThread: TatwoNativeChatThread,
        startedAt: Date
    ) {
        let projectReference = TatwoNativeChatSessionReference(
            kind: .thread,
            id: projectThread.id)
        let sceneRows = Self.exportGoldenRows(
            for: scene,
            startedAt: startedAt)

        selectedProjectID = scene == .orphan ? nil : selectedProjectID
        selectedThreadID =
            scene == .orphan ? orphanThread.id : projectThread.id
        let reference = scene == .orphan
            ? TatwoNativeChatSessionReference(
                kind: .thread,
                id: orphanThread.id)
            : projectReference
        messages = sceneRows
        messageCache[reference] = sceneRows
        activeAssistantID = scene.isFrozenInFlight
            ? sceneRows.last(where: { $0.role == .assistant })?.id
            : nil
        isRunning = scene.isFrozenInFlight
        liveWorkActivities = []
        composerHint = nil
        prompt = ""

        if scene == .plg {
            let objective = "以 PLG 收斂 Chat 場景注入與視覺金樣"
            if let thread = selectedThread {
                let context = selectedThreadWorkOSContext(
                    thread: thread,
                    objectiveHint: objective)
                if let contract = try? WorkOSFactory.projectContract(
                    mode: context.mode,
                    scenarioProfileID: context.scenario,
                    objective: context.objective,
                    catalog: .defaults,
                    scenarioBook: scenarioConfigBook,
                    routeBindingOverride: workOSRouteBindingOverride(
                        for: thread.loopsConfig))
                {
                    _ = updateSelectedThreadWorkOSMetadata(
                        goalID: contract.goalID,
                        contractID: contract.contractID,
                        objectiveIdentity:
                            TatwoObjectiveIdentity.make(contract.objective))
                    selectedWorkOSContract = contract
                    selectedWorkOSStateMessage =
                        "export-only PLG 金樣 · Goal 已綁定"
                }
            }
        } else {
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            selectedWorkOSStateMessage = scene == .orphan
                ? "一般聊天 · 無 Goal"
                : "C0 金樣場景 · export-only"
        }
        if scene == .engineSwitch {
            selectedModel = "sonnet5"
            engine = ChatRouteChoice.resolve("sonnet5").engine
        }
    }

    private static func exportGoldenRows(
        for scene: TatwoExportChatGoldenScene,
        startedAt: Date
    ) -> [ChatMessage] {
        func row(
            _ suffix: String,
            _ role: ChatMessageRole,
            _ text: String,
            status: String? = nil,
            offset: TimeInterval
        ) -> ChatMessage {
            ChatMessage(
                id: "g3-\(scene.rawValue)-\(suffix)",
                role: role,
                text: text,
                status: status,
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(offset))
        }

        switch scene {
        case .send:
            return [
                row("user", .user, "請確認這則訊息已送出，並回覆可驗收結果。", offset: 0),
                row("assistant", .assistant, "已收到並完成回覆；本回合有可見輸出與完成狀態。", status: "done", offset: 18),
            ]
        case .stream:
            return [
                row("user", .user, "串流整理目前的 Chat 金樣捕捉條件。", offset: 0),
                row("assistant", .assistant, "正在整理：場景固定、viewport 固定、PNG bytes hash 固定…", status: "writing|串流回覆中", offset: 14),
            ]
        case .stop:
            return [
                row("user", .user, "開始盤點，但我會在中途停止。", offset: 0),
                row("partial", .assistant, "已盤點場景注入與尺寸守門；sidecar 驗證尚未完成。", status: "cancelled|使用者已停止", offset: 12),
            ]
        case .resume:
            return [
                row("user-1", .user, "先完成第一段盤點。", offset: 0),
                row("assistant-1", .assistant, "第一段已完成：確認沿用同一 thread 與 execution spine。", status: "done", offset: 12),
                row("user-2", .user, "在同一個 thread 繼續。", offset: 22),
                row("assistant-2", .assistant, "已從原進度續跑，沒有建立新的 thread。", status: "done", offset: 36),
            ]
        case .slash:
            return [
                row("user", .user, "/plan 檢查 11 場景視覺金樣", offset: 0),
                row("assistant", .assistant, "Plan 已建立：注入、捕捉、hash、manifest、獨立驗證。", status: "done", offset: 14),
            ]
        case .plg:
            return [
                row("user", .user, "/plg 清償 G3-1 視覺債", offset: 0),
                row("assistant", .assistant, "Plan：建立 export-only 場景；Loops：捕捉 11 張；Goal：PNG 與 sidecar hash 全部鎖定。", status: "planning|PLG 已綁定 Goal", offset: 16),
            ]
        case .engineSwitch:
            return [
                row("user-1", .user, "先用 gpt-5.6-sol 檢查注入層。", offset: 0),
                row("assistant-1", .assistant, "注入守門完成，thread transcript 保持連續。", status: "done", offset: 12),
                row("user-2", .user, "同一 thread 切換到 Sonnet 5 做視覺副審。", offset: 22),
                row("assistant-2", .assistant, "已切換引擎；沿用原 thread 與既有訊息。", status: "done", offset: 34),
            ]
        case .reattach:
            return [
                row("user", .user, "重新掛接仍在執行的金樣捕捉。", offset: 0),
                row("assistant", .assistant, "已重掛同一工作；保留先前輸出，不重放已完成副作用。", status: "waiting|已重掛 · 執行中", offset: 15),
            ]
        case .coldStart:
            return [
                row("user", .user, "從 durable 狀態恢復這個 Chat。", offset: 0),
                row("assistant", .assistant, "冷啟動恢復完成：thread、訊息與上次可續跑位置已還原。", status: "done", offset: 16),
            ]
        case .orphan:
            return [
                row("user", .user, "這是沒有 Goal 的一般閒聊，可以正常存在嗎？", offset: 0),
                row("assistant", .assistant, "可以。一般聊天不需要 Goal，也不會被 PLG spine 閘誤殺。", status: "done", offset: 14),
            ]
        case .queuedTurn:
            return [
                row("user-1", .user, "先執行第一個回合。", offset: 0),
                row("assistant-1", .assistant, "第一個回合正在產生可驗收輸出…", status: "writing|第 1 回合執行中", offset: 12),
                row("user-2", .user, "接著再驗證 sidecar hash。", status: "queued|已排入第 2 回合", offset: 18),
            ]
        }
    }

    /// Export tests call this repeatedly to prove one journal-projected remote
    /// row survives running → terminal → relaunch without another dispatch.
    @discardableResult
    func applyExportOnlyChatTranscriptFixtureState(
        _ state: TatwoChatTranscriptFixtureState
    ) -> Bool {
        guard let fixture = exportChatTranscriptFixtureContext else {
            return false
        }
        let historyRows = fixture.historyRows
        let threadID = fixture.threadID
        let startedAt = fixture.startedAt
        let reference = TatwoNativeChatSessionReference(kind: .thread, id: threadID)
        let activeAt = startedAt.addingTimeInterval(330)
        let remoteAt = startedAt.addingTimeInterval(340)

        switch state {
        case .active:
            guard installFixtureRemoteLifecycle(
                threadID: threadID,
                attempt: 1,
                terminalOutcome: nil,
                occurredAt: remoteAt),
                publishFixtureRemoteTranscript(
                reference: reference,
                isRunning: true)
            else { return false }
            liveWorkActivities = []
            prompt = ""
            composerHint = nil

        case .failed:
            guard installFixtureRemoteLifecycle(
                threadID: threadID,
                attempt: 1,
                terminalOutcome: .failed,
                occurredAt: remoteAt),
                publishFixtureRemoteTranscript(
                reference: reference,
                isRunning: false)
            else { return false }
            liveWorkActivities = []
            prompt = ""
            composerHint = nil

        case .cancelled:
            guard installFixtureRemoteLifecycle(
                threadID: threadID,
                attempt: 1,
                terminalOutcome: .cancelled,
                occurredAt: remoteAt),
                publishFixtureRemoteTranscript(
                reference: reference,
                isRunning: false)
            else { return false }
            liveWorkActivities = []
            prompt = ""
            composerHint = nil

        case .disconnected:
            // Degraded reconnecting: still an in-flight activity on the same
            // identity, never a terminal failed/cancelled claim.
            var rows = historyRows
            upsertStableActiveInline(
                in: &rows,
                text: "連線中斷，正在重連（第 2/5 次）；仍在接續原工作。",
                status: "reconnecting 2/5|連線中斷，正在續接原工作",
                eventKind: .message,
                createdAt: activeAt)
            publishFixtureTranscript(
                rows,
                reference: reference,
                activeAssistantID: TatwoChatTranscriptFixtureState.activeInlineMessageID,
                isRunning: true)
            liveWorkActivities = []
            prompt = ""
            composerHint = nil

        case .reconnected:
            // Recovered continuation on the same item id — no second row.
            var rows = historyRows
            upsertStableActiveInline(
                in: &rows,
                text: "已重連並接續先前上下文：繼續盤點 Chat 動態與 composer 層級，未另開新回合。",
                status: nil,
                eventKind: .message,
                createdAt: activeAt)
            publishFixtureTranscript(
                rows,
                reference: reference,
                activeAssistantID: nil,
                isRunning: false)
            liveWorkActivities = []
            prompt = ""
            composerHint = nil

        case .acceptedRelaunch:
            // Standalone export is self-contained; a sequential test reaches
            // the same terminal item idempotently after `.failed`.
            guard installFixtureRemoteLifecycle(
                threadID: threadID,
                attempt: 1,
                terminalOutcome: .failed,
                occurredAt: remoteAt),
                installFixtureRemoteLifecycle(
                threadID: threadID,
                attempt: 2,
                terminalOutcome: nil,
                occurredAt: remoteAt.addingTimeInterval(20))
            else { return false }
            do {
                let restored = try ChatTranscriptJournalV1.restoring(
                    from: chatTranscriptJournal.encodedSnapshot())
                let persisted = try chatTranscriptJournalStore.saveMerging(restored)
                replaceChatTranscriptJournal(persisted)
            } catch {
                reportFixtureRemotePersistenceFailure(error)
                return false
            }
            guard publishFixtureRemoteTranscript(
                reference: reference,
                isRunning: true)
            else { return false }
            liveWorkActivities = []
            prompt = ""
            composerHint = nil
            updateSelectedThreadPreview(
                "遠端工作已送達 · Fixture Mac mini",
                sessionID: nil)
        }
        return true
    }

    private func upsertStableActiveInline(
        in rows: inout [ChatMessage],
        text: String,
        status: String?,
        eventKind: TatwoNativeChatEventKind,
        createdAt: Date
    ) {
        let existing = rows.first(where: {
            $0.id == TatwoChatTranscriptFixtureState.activeInlineMessageID
        })
        let updated = ChatMessage(
            id: TatwoChatTranscriptFixtureState.activeInlineMessageID,
            role: .assistant,
            text: text,
            status: status,
            modelID: existing?.modelID,
            eventKind: eventKind,
            turnID: existing?.turnID,
            createdAt: createdAt)
        if let index = rows.firstIndex(where: {
            $0.id == TatwoChatTranscriptFixtureState.activeInlineMessageID
        }) {
            rows[index] = updated
        } else {
            rows.append(updated)
        }
    }

    private func publishFixtureTranscript(
        _ rows: [ChatMessage],
        reference: TatwoNativeChatSessionReference,
        activeAssistantID: ChatMessage.ID?,
        isRunning: Bool
    ) {
        messages = rows
        messageCache[reference] = rows
        self.activeAssistantID = activeAssistantID
        self.isRunning = isRunning
    }

    private func publishFixtureRemoteTranscript(
        reference: TatwoNativeChatSessionReference,
        isRunning: Bool
    ) -> Bool {
        let remoteItemIDs = Set(
            chatTranscriptJournal
                .orderedItems(threadID: reference.stableKey)
                .filter { $0.kind == .remoteJob }
                .map(\.id))
        refreshSelectedTranscriptProjection(from: chatTranscriptJournal)
        let remoteRows = messages.filter { remoteItemIDs.contains($0.id) }
        guard !remoteRows.isEmpty else { return false }
        activeAssistantID = isRunning ? remoteRows.first?.id : nil
        self.isRunning = isRunning
        messageCache[reference] = messages
        return true
    }

    @discardableResult
    private func installFixtureRemoteLifecycle(
        threadID: UUID,
        attempt: UInt64,
        terminalOutcome: ChatRemoteJobTerminalOutcome?,
        occurredAt: Date
    ) -> Bool {
        guard chatTranscriptJournalPersistenceAllowed else { return false }
        let reference = TatwoNativeChatSessionReference(kind: .thread, id: threadID)
        var journal = chatTranscriptJournal
        _ = ChatTranscriptJournalAdapter.append(
            remoteJob: Self.fixtureRemoteProjection(
                attempt: attempt,
                terminalOutcome: nil,
                occurredAt: occurredAt),
            threadID: reference.stableKey,
            to: &journal)
        if let terminalOutcome {
            _ = ChatTranscriptJournalAdapter.append(
                remoteJob: Self.fixtureRemoteProjection(
                    attempt: attempt,
                    terminalOutcome: terminalOutcome,
                    occurredAt: occurredAt.addingTimeInterval(10)),
                threadID: reference.stableKey,
                to: &journal)
        }
        do {
            let persisted = try chatTranscriptJournalStore.saveMerging(journal)
            replaceChatTranscriptJournal(persisted)
            return true
        } catch {
            reportFixtureRemotePersistenceFailure(error)
            return false
        }
    }

    private func reportFixtureRemotePersistenceFailure(_ error: Error) {
        fputs(
            "tatwo_export_fixture_remote_persistence_failed=\(TatwoPrivacyRedactor.redacted(error.localizedDescription))\n",
            stderr)
    }

    private static func fixtureRemoteProjection(
        attempt: UInt64,
        terminalOutcome: ChatRemoteJobTerminalOutcome?,
        occurredAt: Date
    ) -> ChatRemoteJobProjection {
        let remoteStatus: TatwoLoopJobStatusV1
        let status: TatwoDispatchStatus
        let errorMessage: String?
        switch terminalOutcome {
        case .failed:
            remoteStatus = .failed
            status = .failed
            errorMessage = "遠端執行器安全結束，未產生可驗收結果"
        case .cancelled:
            remoteStatus = .cancelled
            status = .failed
            errorMessage = "已由本機取消遠端工作"
        case nil:
            remoteStatus = .running
            status = .running
            errorMessage = nil
        }
        let record = TatwoDispatchRecord(
            id: terminalOutcome == nil
                ? "fixture-remote-attempt-\(attempt)-running"
                : "fixture-remote-attempt-\(attempt)-\(terminalOutcome!.rawValue)",
            contractID: "contract-fixture",
            goalID: "goal-fixture",
            bindingID: "binding-fixture",
            sourceSlotID: "slot-fixture",
            identity: .sub,
            modelID: "gpt-5.6-sol",
            subtask: "export-only remote lifecycle evidence",
            logicalDispatchID: TatwoChatTranscriptFixtureState.remoteLogicalKey,
            attempt: Int(attempt),
            status: status,
            startedAt: occurredAt.addingTimeInterval(-20),
            updatedAt: occurredAt,
            receiptID: "fixture-remote-receipt",
            outputRef: nil,
            errorMessage: errorMessage,
            remoteJobID: TatwoChatTranscriptFixtureState.remoteJobID,
            originDeviceID: "fixture-origin-device",
            targetDeviceID: "fixture-remote-device",
            remoteStatus: remoteStatus,
            remoteJobDigest:
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            remoteDispatchNonce: "fixture-remote-dispatch-nonce",
            consumedResultDigest: nil)
        return ChatRemoteJobReducer.project([record]).first!
    }

    @discardableResult
    func persistStore() -> Bool {
        guard allowColdStartDocumentMutation() else { return false }
        let snapshot = legacyTranscriptMigrationCompleted
            ? ChatTranscriptJournalAdapter.removingLegacyTranscriptPayloads(from: document)
            : document
        do {
            try store.save(snapshot)
            chatStorePersistenceWarning = nil
            workOSBindingPersistencePending = false
            return true
        } catch TatwoNativeChatStoreError.migrationRequired {
            let warning = """
                Chat 儲存已停止：偵測到兩份內容不同的舊 Chat 資料，App 不會猜哪份正確或互相覆寫。請先人工備份、比對並選定要保留的版本。
                """
            if chatStorePersistenceWarning != warning {
                chatStorePersistenceWarning = warning
                flashComposerHint(warning)
            }
            return false
        } catch {
            let warning =
                "Chat 尚未安全儲存；目前視窗內容仍保留。請保留視窗後重試："
                + TatwoPrivacyRedactor.redacted(error.localizedDescription)
            if chatStorePersistenceWarning != warning {
                chatStorePersistenceWarning = warning
                flashComposerHint(warning)
            }
            return false
        }
    }

    /// Keep every keystroke in memory immediately, while coalescing device-local
    /// file writes so the synchronized native Chat document is never used for
    /// unfinished composer text.
    func scheduleComposerDraftPersistence() {
        guard !isRestoringComposerDraft, let reference = selectedSessionReference else {
            return
        }
        setComposerDraft(prompt, for: reference)
        composerDraftPersistenceTask?.cancel()
        composerDraftPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.composerDraftDebounceNanoseconds)
            } catch {
                return
            }
            self?.flushComposerDraftCache()
        }
    }

    func restoreComposerDraftForCurrentSession() {
        guard let reference = selectedSessionReference else { return }
        let stored = composerDraftsBySessionKey[reference.stableKey] ?? ""
        if !didBindInitialComposerSelection, stored.isEmpty, !prompt.isEmpty {
            didBindInitialComposerSelection = true
            setComposerDraft(prompt, for: reference)
            scheduleComposerDraftPersistence()
            return
        }
        didBindInitialComposerSelection = true
        composerDraftPersistenceTask?.cancel()
        composerDraftPersistenceTask = nil
        isRestoringComposerDraft = true
        prompt = stored
        isRestoringComposerDraft = false
    }

    /// Reconcile only against canonical user-message identity and chronology.
    /// Text equality is intentionally irrelevant: a user may legitimately
    /// retype the same prompt after an earlier accepted send.
    func composerDraftsDiscardingCanonicallyAcceptedRows(
        _ drafts: [String: String],
        updatedAtBySessionKey: [String: Date],
        acknowledgedMessageIDBySessionKey: [String: String]
    ) -> (
        drafts: [String: String],
        acknowledgedMessageIDs: [String: String],
        didChangeDocument: Bool
    ) {
        var result = drafts
        var acknowledgedMessageIDs = acknowledgedMessageIDBySessionKey
        var didChangeDocument = false
        for sessionKey in drafts.keys {
            guard let latestAcceptedMessage =
                latestCanonicalUserMessage(sessionKey: sessionKey)
            else { continue }
            if acknowledgedMessageIDs[sessionKey] == latestAcceptedMessage.id {
                continue
            }
            guard let draftUpdatedAt = updatedAtBySessionKey[sessionKey],
                  draftUpdatedAt != .distantPast
            else { continue }
            if latestAcceptedMessage.createdAt >= draftUpdatedAt {
                result.removeValue(forKey: sessionKey)
                didChangeDocument = true
            }
            if acknowledgedMessageIDs[sessionKey] != latestAcceptedMessage.id {
                acknowledgedMessageIDs[sessionKey] = latestAcceptedMessage.id
                didChangeDocument = true
            }
        }
        return (result, acknowledgedMessageIDs, didChangeDocument)
    }

    private func latestCanonicalUserMessage(sessionKey: String) -> ChatMessage? {
        ChatTranscriptJournalAdapter.projectedMessages(
            threadID: sessionKey,
            from: chatTranscriptJournal
        ).last(where: { $0.role == .user })
    }

    private func refreshComposerDraftAcceptanceMarkersForDirtySessions() {
        for sessionKey in composerDraftDirtySessionKeys {
            guard let latestAcceptedMessage =
                latestCanonicalUserMessage(sessionKey: sessionKey)
            else { continue }
            composerDraftAcknowledgedMessageIDBySessionKey[sessionKey] =
                latestAcceptedMessage.id
        }
    }

    @discardableResult
    func flushCurrentComposerDraft() -> Bool {
        composerDraftPersistenceTask?.cancel()
        composerDraftPersistenceTask = nil
        if let reference = selectedSessionReference {
            setComposerDraft(prompt, for: reference)
        }
        return flushComposerDraftCache()
    }

    /// Clear only after the canonical user row has been accepted. Sibling
    /// thread/discussion drafts remain untouched.
    @discardableResult
    func clearComposerDraftAfterAcceptedSubmission() -> Bool {
        isRestoringComposerDraft = true
        prompt = ""
        isRestoringComposerDraft = false
        composerDraftPersistenceTask?.cancel()
        composerDraftPersistenceTask = nil
        if let reference = selectedSessionReference {
            composerDraftsBySessionKey.removeValue(forKey: reference.stableKey)
            composerDraftDirtySessionKeys.insert(reference.stableKey)
        }
        return flushComposerDraftCache()
    }

    private func setComposerDraft(
        _ draft: String,
        for reference: TatwoNativeChatSessionReference
    ) {
        if draft.isEmpty {
            composerDraftsBySessionKey.removeValue(forKey: reference.stableKey)
        } else {
            composerDraftsBySessionKey[reference.stableKey] = draft
        }
        composerDraftDirtySessionKeys.insert(reference.stableKey)
    }

    @discardableResult
    private func flushComposerDraftCache() -> Bool {
        refreshComposerDraftAcceptanceMarkersForDirtySessions()
        do {
            try composerDraftStore.save(
                composerDraftsBySessionKey,
                refreshedSessionKeys: composerDraftDirtySessionKeys,
                acknowledgedAcceptedMessageIDBySessionKey:
                    composerDraftAcknowledgedMessageIDBySessionKey)
            composerDraftDirtySessionKeys.removeAll()
            composerDraftPersistenceWarning = nil
            return true
        } catch {
            let warning =
                "草稿尚未安全儲存；文字仍保留在目前視窗，下一次輸入、切換或關閉時會重試。"
            composerDraftPersistenceWarning = warning
            flashComposerHint(warning)
            return false
        }
    }

    func persistSelectedDiscussionID(_ discussionID: UUID?) {
        guard allowColdStartDocumentMutation() else { return }
        guard document.selectedDiscussionID != discussionID else { return }
        document.selectedDiscussionID = discussionID
        persistStore()
    }

    @discardableResult
    func publishDocumentChangeAndPersist() -> Bool {
        guard allowColdStartDocumentMutation() else { return false }
        // Mutating nested thread/project structs does not trigger @Published
        // on `document`; reassign the value after the mutation so the visible
        // Chat controls (especially Ultrawork level and right Thread card)
        // update immediately instead of only after relaunch.
        let updatedDocument = document
        document = updatedDocument
        return persistStore()
    }

    func preserveCurrentMessages() {
        guard let reference = selectedSessionReference else { return }
        messageCache[reference] = messages
        persistSelectedThreadMessages()
    }

    /// Persists the selected canonical Tatwo session. A discussion owns its
    /// own transcript; selecting or sending inside it must never overwrite the
    /// parent thread's message array.
    ///
    /// Unfinished stream tails (assistant + in-flight status) are sealed out
    /// here and again inside `TatwoNativeChatStore.save`.
    func persistSelectedThreadMessages() {
        if chatTranscriptJournalPersistenceAllowed,
           !legacyTranscriptMigrationCompleted
        {
            // A blocked migration must leave the legacy payload byte-for-byte
            // available for a later retry. New sends are already durable in
            // the journal and are merged for presentation until migration can
            // complete.
            return
        }
        if let mutationReference = transcriptMutationReference {
            let stored = TatwoChatTranscriptPresentation.retainedPersistableSuffix(
                messages,
                limit: 120
            ) {
                !$0.isTranscriptNoise
                    && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.status != nil)
                    && !ChatStreamPersistence.isInFlightStoredMessage($0.storedRecord)
            }
                .map(\.storedRecord)
            let newMessages = ChatStreamPersistence.persistableStoredMessages(Array(stored))
            messageCache[mutationReference] = messages
            replaceEphemeralTranscriptProjection(
                newMessages,
                reference: mutationReference)
            return
        }
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        let stored = TatwoChatTranscriptPresentation.retainedPersistableSuffix(
            messages,
            limit: 120
        ) {
            !$0.isTranscriptNoise
                && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.status != nil)
                && !ChatStreamPersistence.isInFlightStoredMessage($0.storedRecord)
        }
            .map(\.storedRecord)
        let newMessages = ChatStreamPersistence.persistableStoredMessages(Array(stored))
        if let discussionID = selectedDiscussionID {
            guard let index = thread.discussions.firstIndex(where: { $0.id == discussionID }) else { return }
            // A transient empty UI buffer must not erase a durable child
            // transcript during route/session reload races.
            if newMessages.isEmpty, !thread.discussions[index].messages.isEmpty {
                return
            }
            guard newMessages != thread.discussions[index].messages else { return }
            thread.discussions[index].messages = newMessages
            thread.updatedAt = Date()
            replaceThread(thread, at: location)
            publishDocumentChangeAndPersist()
            return
        }
        // 防呆：model.messages 暫時空掉(切模型/reload race)但 thread 已有訊息時，
        // 絕不用 nil/空 覆蓋既有訊息 → 避免 transcript 閃空與已存訊息被清。
        let persistedMessages = newMessages.isEmpty ? nil : newMessages
        if persistedMessages == nil, (thread.messages?.isEmpty == false) {
            return
        }
        // #位移修：只在訊息真的變動才 bump updatedAt（否則單純切走/切回會讓 thread 跳到清單頂端）。
        guard persistedMessages != thread.messages else { return }
        thread.messages = persistedMessages
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        publishDocumentChangeAndPersist()
    }

    func mutateSelectedThread(_ update: (inout TatwoNativeChatThread) -> Void) {
        guard allowColdStartDocumentMutation() else { return }
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        update(&thread)
        replaceThread(thread, at: location)
        publishDocumentChangeAndPersist()
    }


    func mutateSelectedDiscussion(_ update: (inout TatwoNativeDiscussion) -> Void) {
        guard allowColdStartDocumentMutation() else { return }
        guard
            let location = selectedThreadLocation(),
            let discussionID = selectedDiscussionID
        else { return }
        var thread = thread(at: location)
        guard let index = thread.discussions.firstIndex(where: { $0.id == discussionID }) else { return }
        update(&thread.discussions[index])
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        publishDocumentChangeAndPersist()
    }

    func renameSelectedThread(to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateSelectedThread { thread in
            thread.title = String(trimmed.prefix(80))
            thread.updatedAt = Date()
        }
    }

    private static func storedMessages(from thread: TatwoNativeChatThread?) -> [ChatMessage] {
        guard let records = thread?.messages, !records.isEmpty else { return [] }
        return records.map(ChatMessage.init(stored:))
    }

    func parkedSessionMessages(
        for reference: TatwoNativeChatSessionReference
    ) -> [ChatMessage] {
        if let cached = messageCache[reference], !cached.isEmpty {
            return cached
        }
        guard chatTranscriptJournalPersistenceAllowed else { return [] }
        return ChatTranscriptJournalAdapter.projectedMessages(
            threadID: reference.stableKey,
            from: chatTranscriptJournal)
    }

    // 選 session 載入訊息：快取為「空陣列(非 nil)」時也要回退到已存訊息，
    // 否則 `cache ?? stored` 會回傳空陣列 → transcript 空掉(內文消失)。
    func loadedMessagesForSelection(threadID: UUID, thread: TatwoNativeChatThread?) -> [ChatMessage] {
        loadedMessagesForSelection(
            reference: TatwoNativeChatSessionReference(kind: .thread, id: threadID),
            stored: thread?.messages ?? [])
    }

    func loadedMessagesForSelection(
        reference: TatwoNativeChatSessionReference,
        stored: [TatwoNativeChatStoredMessage]
    ) -> [ChatMessage] {
        // Reconnect: durable store is already sealed, but cache may still hold
        // a live tail from the current process — keep cache for live UI only
        // when this session is actively streaming; otherwise restore stable only.
        let source: [ChatMessage]
        if sessionIsActivelyStreaming(reference),
           let cached = messageCache[reference],
           !cached.isEmpty
        {
            source = cached
        } else if chatTranscriptJournalPersistenceAllowed {
            let canonical = ChatTranscriptJournalAdapter.projectedMessages(
                threadID: reference.stableKey,
                from: chatTranscriptJournal)
            let stableLegacy = ChatStreamPersistence.reconnectStoredMessages(stored)
            if canonical.isEmpty {
                if let cached = messageCache[reference], !cached.isEmpty {
                    source = ChatStreamPersistence.reconnectStoredMessages(
                        cached.map(\.storedRecord)
                    ).map(ChatMessage.init(stored:))
                } else {
                    source = stableLegacy.map(ChatMessage.init(stored:))
                }
            } else {
                source = legacyTranscriptMigrationCompleted
                    ? canonical
                    : ChatTranscriptJournalAdapter.mergingCanonicalProjection(
                        canonical,
                        withLegacy: stableLegacy)
            }
        } else {
            source = ChatStreamPersistence.reconnectStoredMessages(stored)
                .map(ChatMessage.init(stored:))
        }
        return source.map { message in
            var migrated = message
            migrated.text = ChatAttachmentTranscript.migratingLegacyImageMarkers(
                in: message.text,
                imageStore: imageAssetStore)
            return migrated
        }
    }

    @discardableResult
    func appendMessage(_ message: ChatMessage, persist: Bool = true) -> Bool {
        if persist {
            guard recordCanonicalMessage(message) else { return false }
            persistSelectedThreadMessages()
            return true
        }
        messages.append(message)
        cacheSelectedSessionMessages()
        return true
    }

    func cacheSelectedSessionMessages() {
        if let reference = transcriptMutationReference ?? selectedSessionReference {
            messageCache[reference] = messages
        }
    }

    func applyCanonicalTranscriptProjection(
        _ rows: [ChatMessage],
        reference: TatwoNativeChatSessionReference
    ) {
        messageCache[reference] = rows
        guard selectedSessionReference == reference else { return }
        messages = rows
        if chatTranscriptJournalPersistenceAllowed,
           !legacyTranscriptMigrationCompleted
        {
            return
        }
        replaceEphemeralTranscriptProjection(
            rows.map(\.storedRecord),
            reference: reference)
    }

    /// Keeps old session-tree consumers working from an in-memory projection.
    /// `persistStore()` strips these rows after the one-time migration gate, so
    /// the journal remains the only durable transcript.
    func replaceEphemeralTranscriptProjection(
        _ records: [TatwoNativeChatStoredMessage],
        reference: TatwoNativeChatSessionReference
    ) {
        guard coldStartDocumentMutationAllowed else { return }
        switch reference.kind {
        case .thread:
            if let index = document.threads.firstIndex(where: { $0.id == reference.id }) {
                document.threads[index].messages = records
            } else {
                for projectIndex in document.projects.indices {
                    if let threadIndex = document.projects[projectIndex].threads
                        .firstIndex(where: { $0.id == reference.id })
                    {
                        document.projects[projectIndex].threads[threadIndex].messages = records
                        break
                    }
                }
            }
        case .discussion:
            if Self.replaceDiscussionProjection(
                records,
                discussionID: reference.id,
                threads: &document.threads)
            {
                break
            }
            for projectIndex in document.projects.indices {
                if Self.replaceDiscussionProjection(
                    records,
                    discussionID: reference.id,
                    threads: &document.projects[projectIndex].threads)
                {
                    break
                }
            }
        }
        let updatedDocument = document
        document = updatedDocument
    }

    private static func replaceDiscussionProjection(
        _ records: [TatwoNativeChatStoredMessage],
        discussionID: UUID,
        threads: inout [TatwoNativeChatThread]
    ) -> Bool {
        for threadIndex in threads.indices {
            guard let discussionIndex = threads[threadIndex].discussions
                .firstIndex(where: { $0.id == discussionID })
            else { continue }
            threads[threadIndex].discussions[discussionIndex].messages = records
            return true
        }
        return false
    }

    func updateSelectedThreadPreview(
        _ preview: String,
        sessionID: String?,
        sessionEngine: ChatEngine? = nil,
        runtimeAdapter: TatwoChatRuntimeAdapter? = nil
    ) {
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = Self.persistableSessionID(sessionID).map {
            TatwoNativeAdapterSessionHandle(
                adapterID: (runtimeAdapter ?? routeChoice.runtimeAdapter).rawValue,
                modelID: routeChoice.id,
                providerSessionID: $0)
        }
        if let discussionID = selectedDiscussionID,
           let discussionIndex = thread.discussions.firstIndex(where: { $0.id == discussionID }) {
            if !trimmed.isEmpty {
                thread.discussions[discussionIndex].lastPreview = String(trimmed.prefix(120))
            }
            if let handle {
                thread.discussions[discussionIndex].adapterSessionHandles =
                    TatwoNativeSessionTree.upserting(
                        handle,
                        into: thread.discussions[discussionIndex].adapterSessionHandles)
            }
            thread.updatedAt = Date()
            replaceThread(thread, at: location)
            publishDocumentChangeAndPersist()
            return
        }
        if thread.title == "新聊天", !trimmed.isEmpty {
            thread.title = String(trimmed.prefix(34))
        }
        if !trimmed.isEmpty { thread.lastPreview = String(trimmed.prefix(120)) }
        if let sessionID = Self.persistableSessionID(sessionID),
           runtimeAdapter != .grokCLI {
            switch sessionEngine {
            case .codex:
                thread.codexCLISessionID = sessionID
                if !Self.isCodexAppMirrorThread(thread) {
                    thread.codexSessionID = sessionID
                }
            case .claude:
                thread.claudeSessionID = sessionID
            case nil:
                break
            }
            thread.cliSessionID = sessionID
        }
        if let handle {
            thread.adapterSessionHandles = TatwoNativeSessionTree.upserting(
                handle,
                into: thread.adapterSessionHandles)
        }
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        publishDocumentChangeAndPersist()
    }

    func updateSelectedThreadLoopsConfig(_ loopsConfig: TatwoNativeThreadLoopsConfig, syncSingleModelFromLead: Bool = true) {
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        var bindingMutationIntent: WorkOSBindingMutationIntentV1?
        let previousLoopsConfig = thread.loopsConfig
        let preservesIssuedContract =
            thread.workOSContractID != nil
            && Self.canReuseIssuedContract(
                from: previousLoopsConfig,
                to: loopsConfig)
        if previousLoopsConfig == loopsConfig {
            if preservesIssuedContract {
                selectedWorkOSStateMessage = "協作設定未改變；現有 GoalRun 與 Work OS contract 保留"
            }
            if syncSingleModelFromLead {
                syncSingleModelFromCollaborationLead(loopsConfig)
            }
            return
        }
        let boundContractID = Self.normalizedNonEmpty(thread.workOSContractID)
        let boundGoalID = Self.normalizedNonEmpty(thread.workOSGoalID)
        if !preservesIssuedContract,
           boundContractID == nil,
           boundGoalID == nil,
           let invalidation = thread.bindingInvalidation {
            let invalidationProjectID = projectID(for: location)
            guard invalidation.schema
                    == "TatwoNativeThreadBindingInvalidationV1",
                  invalidation.reason == .loopsConfigChanged,
                  invalidation.threadID == thread.id,
                  invalidation.projectID == invalidationProjectID,
                  invalidation.expectedSuccessor == nil,
                  invalidation.authorityProvenance
                    == bindingAuthorityProvenance(
                        for: thread,
                        projectID: invalidationProjectID),
                  thread.selectedThreadWorkOSContext == nil,
                  thread.activePLGRunProjection == nil,
                  invalidation.desiredLoopsConfigSHA256
                    == TatwoNativeThreadBindingInvalidationV1
                        .loopsConfigSHA256(thread.loopsConfig)
            else {
                selectedWorkOSStateMessage =
                    "協作綁定無法更新：既有失效標記不符合可重定向條件，已保留原設定。"
                return
            }
            do {
                if let durableIntent =
                    try workOSBindingMutationIntentStore.load()
                {
                    let predecessorGoal = try goalRunStore
                        .requireIssuedContract(
                            durableIntent.oldContractID)
                    guard Self
                            .workOSBindingMutationPredecessorIsExactlySuperseded(
                                predecessorGoal,
                                for: durableIntent),
                          Self.bindingInvalidationMatchesIntentEpisode(
                        invalidation,
                        intent: durableIntent,
                        thread: thread,
                        document: document,
                        predecessorGoal: predecessorGoal,
                        standaloneWorkspacePath:
                            Self.safeChatWorkspaceURL()
                                .standardizedFileURL.path,
                        expectedDesiredLoopsConfigSHA256:
                            TatwoNativeThreadBindingInvalidationV1
                                .loopsConfigSHA256(
                                    durableIntent
                                        .desiredLoopsConfig),
                        requiresCurrentLoopsAsPrevious: false)
                    else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    bindingMutationIntent = durableIntent
                }
            } catch {
                selectedWorkOSStateMessage =
                    "協作綁定無法更新：durable mutation intent 與既有失效標記不一致，已保留原設定。"
                return
            }
            guard let retargeted =
                invalidation.retargetingDesiredLoopsConfig(loopsConfig)
            else {
                selectedWorkOSStateMessage =
                    "協作綁定無法更新：既有失效標記無法安全重定向，已保留原設定。"
                return
            }
            thread.bindingInvalidation = retargeted
        }
        if !preservesIssuedContract,
           boundContractID != nil || boundGoalID != nil {
            guard let contractID = boundContractID,
                  let goalID = boundGoalID
            else {
                selectedWorkOSStateMessage =
                    "協作綁定無法更新：舊 Goal／Contract 綁定不完整，已保留原設定。"
                return
            }
            let intent = makeWorkOSBindingMutationIntent(
                for: thread,
                at: location,
                oldContractID: contractID,
                oldGoalID: goalID,
                desiredLoopsConfig: loopsConfig)
            do {
                try workOSBindingMutationIntentStore.create(intent)
                bindingMutationIntent = intent
                let invalidation = try makeThreadBindingInvalidation(
                    id: intent.id,
                    reason: .loopsConfigChanged,
                    for: thread,
                    at: location,
                    oldContractID: contractID,
                    oldGoalID: goalID,
                    desiredLoopsConfig: loopsConfig)
                guard persistThreadBindingInvalidation(
                    invalidation,
                    for: &thread,
                    at: location)
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try supersedePristineCurrentGoalBinding(
                    for: thread,
                    expectedContractID: contractID)
            } catch {
                discardWorkOSBindingMutationIntentIfUncommitted(intent)
                rollbackUncommittedThreadBindingInvalidation(
                    for: &thread,
                    at: location)
                selectedWorkOSStateMessage = supersessionFailureMessage(
                    prefix: "協作綁定無法更新",
                    error: error)
                return
            }
        }
        if !preservesIssuedContract {
            invalidatePendingRemoteTargetForSelectedSession()
        }
        thread.loopsConfig = loopsConfig
        if !preservesIssuedContract {
            thread.workOSGoalID = nil
            thread.workOSContractID = nil
            thread.selectedThreadWorkOSContext = nil
            thread.activePLGRunProjection = nil
        }
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        let persisted = publishDocumentChangeAndPersist()
        if preservesIssuedContract {
            selectedWorkOSStateMessage = "協作設定未改變；現有 GoalRun 與 Work OS contract 保留"
        } else {
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .none
            if persisted {
                finishWorkOSBindingMutationIntent(bindingMutationIntent)
                selectedWorkOSStateMessage = "協作綁定已更新；舊 contract 已失效，送出 chat request 後建立精準綁定的新 revision"
            } else {
                workOSBindingPersistencePending = true
                selectedWorkOSStateMessage =
                    "舊 Goal 已安全取消，但新協作設定尚未寫入磁碟；已停止建立新 Goal，並會自動重試儲存。"
            }
        }
        if syncSingleModelFromLead {
            syncSingleModelFromCollaborationLead(loopsConfig)
        }
    }

    /// Development-shaped `/plg` requests bind the App-owned native Sol/Opus
    /// topology before authority bootstrap and contract issuance. Ordinary
    /// PLG requests keep the scenario selected by the user.
    @discardableResult
    func prepareNativeDevelopmentScenarioForPLGIfNeeded(
        objective: String,
        synchronizePlanRoute: Bool = true
    ) async -> Bool {
        let decision = TatwoChatCommandPlanner.nativeDevelopmentDecision(
            currentVisibleTurn: objective,
            mode: .chat,
            interactionMode: .plan,
            scenarioPhase: .plan,
            contractStatus: .planned)
        guard decision.requested else { return true }

        let normalizedObjective = objective.lowercased()
        let usesFableGrok =
            normalizedObjective.contains("fable")
            && normalizedObjective.contains("grok")
        let scenarioID = usesFableGrok
            ? TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID
            : TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID
        if selectedThread?.loopsConfig?.scenarioID == scenarioID {
            return true
        }
        let scenarioConfigStore = TatwoScenarioConfigStore.defaultStore()
        let scenarioConfigResult = await Task.detached(
            priority: .userInitiated
        ) {
            Result {
                try scenarioConfigStore.load().normalizedForCurrentDefaults()
            }
        }.value
        switch scenarioConfigResult {
        case let .success(book):
            scenarioConfigBook = book
            coworkTemplates = TatwoCoworkTemplateFactory.templates(from: book)
        case let .failure(error):
            plgError =
                "PLG blocked：Scenario 設定無法讀取或更新（\(error.localizedDescription)）"
            flashComposerHint(
                "PLG 未啟動：Scenario 設定準備失敗；狀態已保留，可重試。")
            return false
        }
        if let boundThread = selectedThread {
            let boundContractID = Self.normalizedNonEmpty(
                boundThread.workOSContractID)
            let boundGoalID = Self.normalizedNonEmpty(
                boundThread.workOSGoalID)
            if boundContractID != nil || boundGoalID != nil {
                guard let boundContractID, boundGoalID != nil else {
                    plgError =
                        "PLG blocked：目前 thread 的舊 Goal／Contract 綁定不完整。"
                    flashComposerHint(
                        "PLG 未啟動：舊 Goal／Contract 綁定不完整。")
                    return false
                }
                do {
                    if try !releaseFailedNativeDevelopmentGoalForNewMainChat(
                        thread: boundThread,
                        expectedContractID: boundContractID,
                        replacementObjective: objective)
                    {
                        try supersedePristineCurrentGoalBinding(
                            for: boundThread,
                            expectedContractID: boundContractID)
                    }
                } catch {
                    plgError = supersessionFailureMessage(
                        prefix: "PLG blocked",
                        error: error)
                    flashComposerHint(
                        "PLG 未啟動：舊 Goal 已開始工作或 current-session 已改變。")
                    return false
                }
                let previousThreadID = boundThread.id
                newChat()
                guard selectedThreadID != previousThreadID,
                      selectedThread != nil
                else {
                    plgError =
                        "PLG blocked：無法建立新的主 Chat 承接原生開發 Goal。"
                    flashComposerHint(
                        "PLG 未啟動：新的主 Chat 建立失敗。")
                    return false
                }
            }
        }
        guard let template = coworkTemplates.first(where: {
            $0.scenarioID == scenarioID
        }) else {
            plgError =
                "PLG blocked：找不到指定的 exact 原生開發 Scenario。"
            flashComposerHint(
                "PLG 未啟動：原生開發 Scenario 不可用。")
            return false
        }

        selectedCoworkTemplateID = template.id
        updateSelectedThreadLoopsConfig(
            loopsConfig(for: template, mode: .xxl),
            syncSingleModelFromLead: synchronizePlanRoute)
        guard selectedThread?.loopsConfig?.scenarioID == scenarioID else {
            plgError =
                "PLG blocked：原生開發 Scenario 未能安全寫入目前 thread。"
            flashComposerHint(
                "PLG 未啟動：原生開發 Scenario 綁定失敗。")
            return false
        }
        let planModelID = usesFableGrok
            ? "fable-5"
            : TatwoNativeDevelopmentDispatchCoordinator.solModelID
        if synchronizePlanRoute {
            setSingleModel(planModelID, syncCollaborationLead: false)
            guard TatwoGatewayDispatchCatalog.normalize(
                currentTurnDispatchRoute().canonicalModelSlug)
                == TatwoGatewayDispatchCatalog.normalize(planModelID)
            else {
                plgError =
                    "PLG blocked：exact 原生 Plan route 未能啟用。"
                flashComposerHint(
                    "PLG 未啟動：exact 原生 route 綁定失敗。")
                return false
            }
        }
        return true
    }

    /// A materially different native-development `/goal` must not be trapped
    /// behind an earlier dispatch failure. Once the old Goal is durably blocked
    /// by an exact failed dispatch and no dispatch remains active, finalize it
    /// as failed, clear only its exact current-session pointer, and leave the
    /// old Chat row/receipts untouched for audit history.
    private func releaseFailedNativeDevelopmentGoalForNewMainChat(
        thread: TatwoNativeChatThread,
        expectedContractID contractID: String,
        replacementObjective: String
    ) throws -> Bool {
        guard let goalID = Self.normalizedNonEmpty(thread.workOSGoalID) else {
            throw TatwoSessionAttachmentError.callerExpectationMismatch(
                "goalID")
        }
        var goalRecord = try goalRunStore.requireIssuedContract(contractID)
        guard goalRecord.goalID == goalID else {
            throw TatwoSessionAttachmentError.pointerGoalRunMismatch(
                "selected_thread")
        }
        let oldObjectiveHash =
            TatwoObjectiveIdentity.make(goalRecord.objective).objectiveHash
        let replacementObjectiveHash =
            TatwoObjectiveIdentity.make(replacementObjective).objectiveHash
        guard oldObjectiveHash != replacementObjectiveHash else {
            return false
        }

        switch goalRecord.status {
        case .blocked:
            goalRecord =
                try TatwoNativeDevelopmentDispatchCoordinator
                    .finalizeBlockedGoalForReplacement(
                        contractID: contractID,
                        goalID: goalID,
                        goalStore: goalRunStore,
                        dispatchRegistry: dispatchRegistry)
        case .failed, .cancelled, .passed, .rollbackRequired:
            break
        case .planned, .dispatching, .running, .succeeded, .humanGate,
             .awaitingNextCycle, .superseded:
            return false
        }

        let sessionStore = TatwoSessionStore(
            directoryURL: goalRunStore.directoryURL)
        if let snapshot = try sessionStore.snapshotCurrent() {
            guard snapshot.pointer.contractID == contractID,
                  snapshot.pointer.goalID == goalID
            else {
                throw TatwoSessionMutationError.currentSessionChanged
            }
            let ownerVerification = currentSessionOwnerVerification(
                for: thread,
                projectID: selectedProjectID,
                pointerSchema: snapshot.pointer.schema)
            _ = try sessionStore.compareAndClearCurrent(
                snapshot: snapshot,
                ownerVerification: ownerVerification,
                expectedContractID: contractID,
                expectedGoalID: goalID,
                expectedMode: goalRecord.mode,
                expectedScenario: goalRecord.scenario,
                expectedObjective: goalRecord.objective,
                scenarioBook: scenarioConfigBook,
                goalStore: goalRunStore)
        }
        currentSessionPointerPresent = false
        verifiedCurrentSessionBundle = nil
        selectedWorkOSContract = nil
        selectedGoalRecord = nil
        selectedDispatchRecords = []
        activePLGRun = nil
        appliedPLGEventIDs = []
        plgAuthorityState = .none
        selectedWorkOSStateMessage =
            "舊原生開發 Goal 已保留為失敗證據；新的主 Chat 將承接不同目標。"
        return true
    }

    static func canReuseIssuedContract(
        from previous: TatwoNativeThreadLoopsConfig?,
        to next: TatwoNativeThreadLoopsConfig
    ) -> Bool {
        guard let previous else { return false }
        return previous.scenarioID == next.scenarioID
            && previous.mode == next.mode
            && effectiveWorkOSRouteBindingOverride(for: previous)
                == effectiveWorkOSRouteBindingOverride(for: next)
    }

    nonisolated static func effectiveWorkOSRouteBindingOverride(
        for config: TatwoNativeThreadLoopsConfig
    ) -> WorkOSRouteBindingOverride? {
        let explicit = WorkOSRouteBindingOverride(
            primaryModelID: config.primaryModelID,
            secondaryModelID: config.secondaryModelID)
        if config.mode == .xxl,
           config.scenarioID
            == TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
           explicit.isEmpty
        {
            return canonicalNativeDevelopmentRouteBinding
        }
        if config.mode == .xxl,
           config.scenarioID
            == TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID,
           explicit.isEmpty
        {
            return canonicalFableGrokNativeDevelopmentRouteBinding
        }
        return explicit.isEmpty ? nil : explicit
    }

    nonisolated static func effectiveWorkOSRouteBindingOverride(
        mode: WorkModeID,
        scenarioID: String,
        explicit: WorkOSRouteBindingOverride?
    ) -> WorkOSRouteBindingOverride? {
        if mode == .xxl,
           scenarioID
            == TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
           explicit == nil || explicit?.isEmpty == true
        {
            return canonicalNativeDevelopmentRouteBinding
        }
        if mode == .xxl,
           scenarioID
            == TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID,
           explicit == nil || explicit?.isEmpty == true
        {
            return canonicalFableGrokNativeDevelopmentRouteBinding
        }
        guard let explicit, !explicit.isEmpty else { return nil }
        return explicit
    }

    nonisolated static func workOSRouteBindingPreservesContract(
        mode: WorkModeID,
        scenarioID: String,
        issuedOverride: WorkOSRouteBindingOverride?,
        loopsConfig: TatwoNativeThreadLoopsConfig
    ) -> Bool {
        effectiveWorkOSRouteBindingOverride(
            mode: mode,
            scenarioID: scenarioID,
            explicit: issuedOverride)
            == effectiveWorkOSRouteBindingOverride(for: loopsConfig)
    }

    func workOSRouteBindingOverride(
        for config: TatwoNativeThreadLoopsConfig?
    ) -> WorkOSRouteBindingOverride? {
        guard let config else { return nil }
        let override = WorkOSRouteBindingOverride(
            primaryModelID: config.primaryModelID,
            secondaryModelID: config.secondaryModelID)
        return override.isEmpty ? nil : override
    }
}

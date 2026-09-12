import Foundation
import XCTest

@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

/// 2026-08-28 staging69 / runtime-63 live 失敗的負向重現。
///
/// 主線在 PLG thread（`contract-s-daily-5369608c892b`，Ultrawork S／主導
/// gpt-5.6-terra）按【確認計畫，進入分工】，Loops 工作區顯示「執行受阻」、
/// lead failed、無 runtime receipt：
///
///     statusReason = dispatch_failed:dispatch-binding-general-s-terra-plan-lead-0-…
///     errorMessage = gateway_error: Goal 已確認，但單模型 runner 未取得執行權；派工已 fail closed。
///
/// 磁碟證據定位了兩個獨立缺陷：
///
/// D1 `chat-transcript-journal-v1.json` 在失敗時完全沒被寫入 → 本輪在
///    `startTurn` append canonical user message **之前**就被擋掉。而
///    `state/current-session.json` 的 ownerBinding 是**另一條** Chat row
///    （Goal thread `71d76ff1…` / `contract-s-daily-348bc63d25f6`，01:40 取得
///    指標），PLG thread 的合約 01:38 就已簽發。只要第二個 Ultrawork 對話拿走
///    current-session 指標，第一條對話就再也送不出任何 Work OS 回合。
///
/// D2 live 01:38 的那一輪（`/goal` 純聊天分支）在 PLG run 還停在 planning
///    相位時送出，`currentChatInteractionMode` 因此判成 plan、argv 走
///    `-s read-only`，terra 回「目前權限不足，本回合未執行。」——沙盒三檔
///    永遠不會出現。確認鍵這條路徑必須反過來鎖死：dispatch 一旦開出去，送給
///    runner 的 argv 就要帶 workspace-write，否則 D1 修好也只是換一種空轉。
@MainActor
final class ChatPLGSingleModelExecutionAuthorityTests: XCTestCase {
    /// D1：指標屬於另一條真實 Chat row 時，本列仍必須能用自己的既有合約派工。
    func testConfirmationStartsLeadDispatchWhileAnotherThreadHoldsSessionPointer()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            fixture.plgContract.contractID,
            model.selectedWorkOSStateMessage)

        model.activePLGRun = Self.leadAdversarialRun(
            contract: fixture.plgContract)

        XCTAssertTrue(
            model.confirmPLGPlanAndStartLoops(restoreProjection: false),
            "confirm 失敗：hint=\(model.composerHint ?? "nil")"
                + " state=\(model.selectedWorkOSStateMessage)")
        XCTAssertEqual(
            try fixture.goalStore
                .requireIssuedContract(fixture.plgContract.contractID)
                .status,
            .running,
            model.composerHint ?? "goal 未進入 running")
        XCTAssertTrue(
            model.selectedDispatchRecords.contains {
                $0.identity == .lead && $0.status == .running
            },
            "確認鍵必須留下 lead-bound 的 running runtime receipt")
        try await fixture.awaitRunnerStart()
        XCTAssertEqual(
            fixture.dispatch.startCount,
            1,
            "runner 未起跑：isRunning=\(model.isRunning)")
        XCTAssertFalse(
            model.composerHint?.hasPrefix(
                "單模型 runner 未啟動；dispatch 已標記失敗") == true,
            model.composerHint ?? "")
    }

    /// D1 的精確斷言：`submitCurrentChatTurn` 之前的 Work OS 關卡本身要放行。
    /// 修復前這裡會回 false 並把 state 打成「…已隔離…」。
    func testExistingContractStaysReusableWhenPointerBelongsToAnotherThread()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model

        // 與 live submitCurrentChatTurn 同一組參數：只沿用、不新建、不比對
        // objective。
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: Self.confirmedPlanExecutionTurn),
            model.selectedWorkOSStateMessage)
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            fixture.plgContract.contractID)
        XCTAssertFalse(
            model.selectedWorkOSStateMessage.contains("已隔離"),
            model.selectedWorkOSStateMessage)
    }

    /// D2：確認後真正送出的 runner 指令必須帶 workspace-write，
    /// 不得沿用 Plan 相位的唯讀沙盒（live 01:38 就是 `-s read-only`，
    /// terra 直接回「目前權限不足，本回合未執行。」）。
    func testConfirmedExecutionTurnDispatchesWithWorkspaceWriteSandbox()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        model.activePLGRun = Self.leadAdversarialRun(
            contract: fixture.plgContract)

        XCTAssertTrue(
            model.confirmPLGPlanAndStartLoops(restoreProjection: false),
            model.composerHint ?? "confirm 未通過")
        try await fixture.awaitRunnerStart()
        let arguments = try XCTUnwrap(fixture.dispatch.lastCommand?.arguments)
        XCTAssertTrue(
            arguments.contains("workspace-write"),
            "已確認計畫的執行回合必須拿到 workspace-write：\(arguments)")
        XCTAssertFalse(
            arguments.contains("read-only"),
            "執行階段不得沿用 Plan 相位的唯讀沙盒：\(arguments)")
    }

    /// 2026-08-28 live r11（thread r11／contract-s-daily-656cd1f98f4c）的負向重現。
    ///
    /// 主線這次走的是「`/plan` 討論 → 加號【交給 Work OS Loops】→ PLG 卡
    /// 【確認計畫，進入分工】」。`createAndDispatchLoopFromPrompt` 只建 PLG run，
    /// **不會**關掉 thread 的 Plan 模式，於是確認後的執行回合仍以 Plan
    /// interaction semantics 起跑：
    ///
    ///     spawn-C9D17C78-…jsonl  argc=32   （workspace-write 應為 34）
    ///     dispatch errorMessage  operational_failure: Single-model runner
    ///                            exited successfully without tool execution evidence
    ///     terra 回覆              blocker_class=tool_unavailable
    ///                            authority_source=runner（要求 /plan off）
    ///
    /// 三條斷言各自對應一個 live 症狀：離開 Plan 模式、argv 拿到
    /// workspace-write、turn 不再被注入 Plan mode contract。
    func testConfirmationLeavesPlanInteractionModeAndDispatchesWorkspaceWrite()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        // live 前提：thread 由 `/plan` 進入 Plan 模式，而「加號→交給 Work OS
        // Loops」建立的 PLG run 不會關掉它。
        model.setPlanModeEnabled(true)
        XCTAssertTrue(
            model.isPlanModeEnabled,
            "fixture 前提不成立：thread 未進入 Plan 模式")
        model.activePLGRun = Self.leadAdversarialRun(
            contract: fixture.plgContract)

        XCTAssertTrue(
            model.confirmPLGPlanAndStartLoops(restoreProjection: false),
            model.composerHint ?? "confirm 未通過")
        XCTAssertFalse(
            model.isPlanModeEnabled,
            "人門確認＝Plan interaction semantics 的終點；dispatch 開出去後"
                + "這個 thread 不得仍停在 Plan 模式")
        try await fixture.awaitRunnerStart()
        let command = try XCTUnwrap(fixture.dispatch.lastCommand)
        XCTAssertTrue(
            command.arguments.contains("workspace-write"),
            "已確認計畫的執行回合必須拿到 workspace-write：\(command.arguments)")
        XCTAssertFalse(
            command.arguments.contains("read-only"),
            "執行階段不得沿用 Plan 模式的唯讀沙盒（live argc=32）："
                + "\(command.arguments)")
        let turn = try XCTUnwrap(
            command.standardInputUTF8,
            "codex-exec 回合必須有 stdin turn")
        XCTAssertFalse(
            turn.contains("planMode=active"),
            "執行回合不得再被注入 Hidden Codex-style Plan mode contract")
        XCTAssertFalse(
            turn.contains("Do not execute commands"),
            "執行回合不得再被注入 Plan mode 的禁止執行條款")
    }

    /// 2026-08-28 formal App live regression：Work OS contract 的 objective
    /// 為持久化／展示用途而把絕對路徑遮成 `<local-path>`，但 PLG seed 的
    /// `planSummary` 仍保留使用者已確認的精確沙盒路徑。確認鍵若拿 contract
    /// objective 當 runner prompt，terra 只能 fail closed 要求補路徑。
    func testConfirmationDispatchesExactConfirmedPlanInsteadOfRedactedContractObjective()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        let exactTarget =
            "\(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/session-main-plan-plg-terra-r2"
        var run = Self.leadAdversarialRun(contract: fixture.plgContract)
        run.planSummary =
            "PLAN CONFIRMED. Execute exactly the approved stats plan. "
            + "The only task-output path is \(exactTarget)."
        model.activePLGRun = run

        XCTAssertTrue(
            fixture.plgContract.objective.contains("<local-path>"),
            "fixture 必須重現 contract objective 已遮蔽絕對路徑")
        XCTAssertTrue(
            model.confirmPLGPlanAndStartLoops(restoreProjection: false),
            model.composerHint ?? "confirm 未通過")
        try await fixture.awaitRunnerStart()
        let turn = try XCTUnwrap(fixture.dispatch.lastCommand?.standardInputUTF8)
        XCTAssertTrue(
            turn.contains(exactTarget),
            "runner 必須收到 PLG seed 中已確認的精確輸出路徑：\(turn)")
        XCTAssertFalse(
            turn.contains("task-output path is <local-path>"),
            "執行 prompt 不得退回持久化 contract 的隱私遮罩：\(turn)")
    }

    /// A fresh model instance reading the same durable registry must not mint a
    /// second logical dispatch for whitespace-equivalent work.
    func testSingleModelDispatchIsDurablyIdempotentAcrossModelInstances()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let subtask = "Execute the confirmed plan and run tests."
        XCTAssertTrue(
            fixture.model.beginSingleModelGoalDispatch(subtask: subtask),
            fixture.model.composerHint ?? "first dispatch failed")

        let firstRun = try XCTUnwrap(
            try fixture.model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID))
        XCTAssertEqual(firstRun.records.count, 1)
        let first = try XCTUnwrap(firstRun.records.first)
        XCTAssertTrue(
            first.resolvedLogicalDispatchID.hasPrefix(
                "logical-chat-single-"))

        let freshRegistry = TatwoDispatchRegistry(
            directoryURL: fixture.goalStore.directoryURL)
        let freshDispatch = PLGAuthorityRecordingDispatchService()
        let fresh = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatPLGSingleModelExecutionAuthorityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: fixture.root.appendingPathComponent(
                    "fresh-native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: fixture.root.appendingPathComponent(
                    "fresh-journal.json")),
            goalRunStore: fixture.goalStore,
            plgChainStore: TatwoPLGChainStore(
                directory: fixture.root.appendingPathComponent(
                    "fresh-plg-chains"),
                anchorAuthority: PLGAuthorityTestAnchorAuthority()),
            dispatchRegistry: freshRegistry,
            nativeRunner: PLGAuthorityNoopNativeRunner(),
            dispatchService: freshDispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        fresh.document = fixture.model.document
        fresh.selectStandaloneThread(fixture.plgThreadID)
        fresh.selectedModel = "gpt-5.6-terra"
        fresh.selectedWorkOSContract = fixture.plgContract
        var duplicateRun = Self.leadAdversarialRun(
            contract: fixture.plgContract)
        duplicateRun.planSummary =
            "  Execute   the confirmed plan\nand run tests.  "
        fresh.activePLGRun = duplicateRun

        XCTAssertFalse(
            fresh.confirmPLGPlanAndStartLoops(
                restoreProjection: false))
        XCTAssertTrue(
            fresh.composerHint?.contains("已有 durable dispatch") == true,
            fresh.composerHint ?? "missing duplicate-dispatch hint")
        XCTAssertEqual(
            freshDispatch.startCount,
            0,
            "fresh model must not start a second physical runner")
        XCTAssertNil(fresh.pendingSingleModelGoalDispatch)
        XCTAssertEqual(fresh.selectedDispatchRecords.count, 1)
        XCTAssertEqual(fresh.selectedGoalRecord?.status, .running)

        let readback = try XCTUnwrap(
            try freshRegistry.run(
                forContractID: fixture.plgContract.contractID))
        XCTAssertEqual(readback.records.count, 1)
        XCTAssertEqual(
            readback.records.first?.resolvedLogicalDispatchID,
            first.resolvedLogicalDispatchID)
    }

    /// A submit acknowledgement can move the row out of the in-memory pending
    /// slot before the caller observes that no runner remained active. Durable
    /// settlement must still find the record by ID and fail it.
    func testGoalSingleModelPathSettlesAcceptedButNotRunningDispatch()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        XCTAssertTrue(
            model.beginSingleModelGoalDispatch(
                subtask: "accepted turn without a running runner"))
        let dispatchID = try XCTUnwrap(
            model.pendingSingleModelGoalDispatch?.id)

        // Same shape as submit accepting the turn and moving pending state into
        // a runtime context before the outer workflow sees `isRunning == false`.
        model.pendingSingleModelGoalDispatch = nil
        model.isRunning = false

        XCTAssertFalse(
            model.settleAcceptedSingleModelGoalDispatchStart(
                dispatchID: dispatchID,
                message: "accepted but runner never entered running"))
        let record = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID)?
                .records.first(where: { $0.id == dispatchID }))
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(
            record.failureReceipt?.errorCode,
            "single_model_runner_not_started")
        XCTAssertNil(model.pendingSingleModelGoalDispatch)
    }

    /// `isRunning` is presentation state, not a runner receipt. A runner may
    /// synchronously finish/reset that flag after returning a real instance ID;
    /// the accepted settlement must still trust the start receipt and must not
    /// consume a retry attempt.
    func testRunnerStartReceiptSurvivesFastIsRunningReset()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        fixture.dispatch.clearsRunningBeforeReturningIdentity = true
        model.activePLGRun = Self.leadAdversarialRun(
            contract: fixture.plgContract)

        XCTAssertTrue(
            model.confirmPLGPlanAndStartLoops(restoreProjection: false),
            model.composerHint ?? "runner start receipt was not accepted")
        try await fixture.awaitRunnerStart()
        XCTAssertEqual(fixture.dispatch.startCount, 1)
        XCTAssertFalse(
            model.isRunning,
            "fixture must clear the UI boolean before startRuntime returns")
        let run = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID))
        XCTAssertEqual(run.records.count, 1)
        XCTAssertEqual(run.records.first?.status, .running)
        XCTAssertNil(run.records.first?.failureReceipt)
        XCTAssertTrue(
            model.singleModelGoalRunnerStartReceiptByDispatchID.isEmpty,
            "outer accepted-settlement must consume the short-lived receipt")
        XCTAssertTrue(
            model.singleModelGoalDeferredStartAwaitingDispatchIDs.isEmpty,
            "deferred accepted-settlement must consume its dispatch marker")
    }

    func testRunnerNotStartedFailureMintsOneBoundRetryAttempt()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        let subtask = "retry the same confirmed single-model goal"

        XCTAssertTrue(
            model.beginSingleModelGoalDispatch(subtask: subtask))
        let firstID = try XCTUnwrap(
            model.pendingSingleModelGoalDispatch?.id)
        model.failPendingSingleModelGoalDispatch(
            dispatchID: firstID,
            message: "runner did not start")

        let first = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID)?
                .records.first(where: { $0.id == firstID }))
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(
            first.resolvedAttempt,
            1,
            "first physical dispatch must consume attempt 1")
        XCTAssertEqual(first.failureReceipt?.failureClass, .retryable)
        XCTAssertEqual(
            first.failureReceipt?.errorCode,
            "single_model_runner_not_started")
        let blockedGoal = try fixture.goalStore.requireIssuedContract(
            fixture.plgContract.contractID)
        XCTAssertEqual(
            blockedGoal.status,
            .blocked,
            "first retryable failure must leave GoalRun blocked, not terminal; "
                + "actual reason=\(blockedGoal.statusReason ?? "nil")")

        XCTAssertTrue(
            model.beginSingleModelGoalDispatch(subtask: subtask),
            model.composerHint ?? "retry should mint a fresh attempt")
        let secondID = try XCTUnwrap(
            model.pendingSingleModelGoalDispatch?.id)
        XCTAssertNotEqual(secondID, firstID)

        let retryRun = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID))
        XCTAssertEqual(retryRun.records.count, 2)
        let second = try XCTUnwrap(
            retryRun.records.first(where: { $0.id == secondID }))
        XCTAssertEqual(
            second.resolvedLogicalDispatchID,
            first.resolvedLogicalDispatchID)
        XCTAssertEqual(second.supersedes, first.id)
        XCTAssertEqual(second.resolvedAttempt, 2)
        XCTAssertEqual(second.status, .running)

        model.failPendingSingleModelGoalDispatch(
            dispatchID: secondID,
            message: "second runner did not start")
        let failedBeforeExhaustion =
            try fixture.goalStore.requireIssuedContract(
                fixture.plgContract.contractID)
        let ledgerBeforeExhaustion = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID))
        XCTAssertEqual(
            failedBeforeExhaustion.statusReason,
            "dispatch_failed:\(secondID):class=retryable:attempt=2")
        XCTAssertFalse(
            model.beginSingleModelGoalDispatch(subtask: subtask),
            "retry cap must not mint an unbounded third physical attempt")
        let cappedRun = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID))
        XCTAssertEqual(cappedRun.records.count, 2)
        let exhaustedGoal = try fixture.goalStore.requireIssuedContract(
            fixture.plgContract.contractID)
        XCTAssertEqual(exhaustedGoal.status, .failed)
        XCTAssertEqual(
            exhaustedGoal.statusReason,
            "dispatch_failed:\(secondID):class=retryable:attempt=2;"
                + "single_model_retry_exhausted:\(secondID)")
        var normalizedExhaustedGoal = exhaustedGoal
        normalizedExhaustedGoal.statusReason =
            failedBeforeExhaustion.statusReason
        normalizedExhaustedGoal.updatedAt =
            failedBeforeExhaustion.updatedAt
        XCTAssertEqual(
            normalizedExhaustedGoal,
            failedBeforeExhaustion,
            "failed refinement may change only statusReason and updatedAt")
        XCTAssertEqual(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID),
            ledgerBeforeExhaustion,
            "retry exhaustion must not mutate the durable dispatch ledger")
        XCTAssertEqual(
            try fixture.goalStore.markDispatchRetryExhausted(
                contractID: fixture.plgContract.contractID,
                dispatchID: secondID),
            exhaustedGoal,
            "the exact preserved reason chain must be idempotent")
        XCTAssertTrue(
            model.composerHint?.contains("Retry budget exhausted") == true,
            model.composerHint ?? "missing retry-budget failure")
        XCTAssertTrue(
            model.composerHint?.contains("重新確認計畫") == true,
            model.composerHint ?? "missing operator recovery action")
        XCTAssertTrue(
            model.composerHint?.contains("Goal revision/contract") == true,
            model.composerHint ?? "missing new revision/contract requirement")
        XCTAssertTrue(
            model.composerHint?.contains("不會自動沿用舊 logical ID") == true,
            model.composerHint ?? "missing old logical-ID warning")
    }

    func testRetryAttemptPolicyRejectsLowerCapAndAllowsExplicitHigherCap()
        throws
    {
        XCTAssertThrowsError(
            try TatwoGoalRunStore.validatedDispatchRetryAttemptCap(
                TatwoGoalRunStore.dispatchRetryAttemptCap - 1)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .dispatchRetryAttemptCapBelowSettlementFloor(
                    requested:
                        TatwoGoalRunStore.dispatchRetryAttemptCap - 1,
                    floor: TatwoGoalRunStore.dispatchRetryAttemptCap))
        }
        XCTAssertEqual(
            try TatwoGoalRunStore.validatedDispatchRetryAttemptCap(
                TatwoGoalRunStore.dispatchRetryAttemptCap),
            TatwoGoalRunStore.dispatchRetryAttemptCap)
        XCTAssertEqual(
            try TatwoGoalRunStore.validatedDispatchRetryAttemptCap(3),
            3,
            "an explicit higher retry ceiling remains a supported policy")
    }

    func testRetryExhaustionMovesBlockedGoalToFailedWithoutMutatingLedger()
        async throws
    {
        let fixture = try await makeRetryExhaustionFixture()
        var blocked = fixture.failedGoal
        blocked.status = .blocked
        blocked.statusReason = "runner_start_recovery_pending"
        try writeGoalRecord(blocked, to: fixture.chat.goalStore)
        let ledgerBefore = try XCTUnwrap(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID))

        let exhausted = try fixture.chat.goalStore.markDispatchRetryExhausted(
            contractID: fixture.chat.plgContract.contractID,
            dispatchID: fixture.secondID)

        XCTAssertEqual(exhausted.status, .failed)
        XCTAssertEqual(
            exhausted.statusReason,
            "runner_start_recovery_pending;"
                + "single_model_retry_exhausted:\(fixture.secondID)")
        var normalized = exhausted
        normalized.status = blocked.status
        normalized.statusReason = blocked.statusReason
        normalized.updatedAt = blocked.updatedAt
        XCTAssertEqual(
            normalized,
            blocked,
            "blocked transition may change only status, statusReason, and updatedAt")
        XCTAssertEqual(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID),
            ledgerBefore,
            "GoalRun settlement must leave the authoritative ledger byte-semantics unchanged")
        XCTAssertEqual(
            try fixture.chat.goalStore.markDispatchRetryExhausted(
                contractID: fixture.chat.plgContract.contractID,
                dispatchID: fixture.secondID),
            exhausted,
            "blocked-origin exhaustion must remain idempotent after it becomes failed")
        XCTAssertEqual(
            try fixture.chat.goalStore.requireIssuedContract(
                fixture.chat.plgContract.contractID),
            exhausted)
        XCTAssertEqual(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID),
            ledgerBefore,
            "the idempotent second call must not mutate either durable store")
    }

    func testRetryExhaustionRejectsIllegalGoalStatusWithoutMutation()
        async throws
    {
        let fixture = try await makeRetryExhaustionFixture()
        var running = fixture.failedGoal
        running.status = .running
        running.statusReason = "runner_still_active"
        try writeGoalRecord(running, to: fixture.chat.goalStore)
        let ledgerBefore = try XCTUnwrap(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID))

        XCTAssertThrowsError(
            try fixture.chat.goalStore.markDispatchRetryExhausted(
                contractID: fixture.chat.plgContract.contractID,
                dispatchID: fixture.secondID)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .illegalStatusTransition(
                    from: .running,
                    to: .failed,
                    authority: "single_model_retry_exhausted"))
        }
        XCTAssertEqual(
            try fixture.chat.goalStore.requireIssuedContract(
                fixture.chat.plgContract.contractID),
            running)
        XCTAssertEqual(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID),
            ledgerBefore)

        var cancelled = fixture.failedGoal
        cancelled.status = .cancelled
        cancelled.statusReason = "operator_cancelled"
        try writeGoalRecord(cancelled, to: fixture.chat.goalStore)
        XCTAssertThrowsError(
            try fixture.chat.goalStore.markDispatchRetryExhausted(
                contractID: fixture.chat.plgContract.contractID,
                dispatchID: fixture.secondID)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .illegalStatusTransition(
                    from: .cancelled,
                    to: .failed,
                    authority: "single_model_retry_exhausted"))
        }
        XCTAssertEqual(
            try fixture.chat.goalStore.requireIssuedContract(
                fixture.chat.plgContract.contractID),
            cancelled)
        XCTAssertEqual(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID),
            ledgerBefore)
    }

    func testRetryExhaustionRejectsInvalidDurableLedgerWithoutMutation()
        async throws
    {
        let fixture = try await makeRetryExhaustionFixture()
        let store = fixture.chat.goalStore
        let registry = fixture.chat.model.dispatchRegistry
        let contractID = fixture.chat.plgContract.contractID
        let originalGoal = fixture.failedGoal
        let originalRun = fixture.dispatchRun
        let target = try XCTUnwrap(
            originalRun.records.first {
                $0.id == fixture.secondID
            })

        func assertRejected(
            _ expected: TatwoGoalRunStoreError,
            dispatchID: String = ""
        ) throws {
            let goalBefore = try store.requireIssuedContract(contractID)
            let ledgerBefore = try registry.run(forContractID: contractID)
            XCTAssertThrowsError(
                try store.markDispatchRetryExhausted(
                    contractID: contractID,
                    dispatchID: dispatchID.isEmpty
                        ? fixture.secondID
                        : dispatchID)
            ) { error in
                XCTAssertEqual(error as? TatwoGoalRunStoreError, expected)
            }
            XCTAssertEqual(
                try store.requireIssuedContract(contractID),
                goalBefore)
            XCTAssertEqual(
                try registry.run(forContractID: contractID),
                ledgerBefore)
        }

        let missingRoot = fixture.chat.root.appendingPathComponent(
            "missing-dispatch-ledger",
            isDirectory: true)
        let missingStore = TatwoGoalRunStore(directoryURL: missingRoot)
        try writeGoalRecord(originalGoal, to: missingStore)
        XCTAssertThrowsError(
            try missingStore.markDispatchRetryExhausted(
                contractID: contractID,
                dispatchID: fixture.secondID)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .dispatchRetryExhaustionRunMissing(
                    contractID: contractID))
        }
        XCTAssertEqual(
            try missingStore.requireIssuedContract(contractID),
            originalGoal)
        XCTAssertNil(
            try TatwoDispatchRegistry(directoryURL: missingRoot)
                .run(forContractID: contractID))

        let runURL = dispatchRunURL(
            contractID: contractID,
            store: store)
        let unreadableLedger = Data("{not-json".utf8)
        try unreadableLedger.write(to: runURL, options: [.atomic])
        let goalBeforeUnreadable =
            try store.requireIssuedContract(contractID)
        XCTAssertThrowsError(
            try store.markDispatchRetryExhausted(
                contractID: contractID,
                dispatchID: fixture.secondID)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .dispatchRetryExhaustionRunUnreadable(
                    contractID: contractID))
        }
        XCTAssertEqual(
            try store.requireIssuedContract(contractID),
            goalBeforeUnreadable)
        XCTAssertEqual(try Data(contentsOf: runURL), unreadableLedger)
        try writeDispatchRun(originalRun, to: store)

        try assertRejected(
            .dispatchRetryExhaustionDispatchMatchCount(
                contractID: contractID,
                dispatchID: "dispatch-not-in-ledger",
                count: 0),
            dispatchID: "dispatch-not-in-ledger")

        var duplicateRun = originalRun
        duplicateRun.records.append(target)
        try writeDispatchRun(duplicateRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionDispatchMatchCount(
                contractID: contractID,
                dispatchID: fixture.secondID,
                count: 2))

        var runningRun = originalRun
        runningRun.records[
            try XCTUnwrap(
                runningRun.records.firstIndex {
                    $0.id == fixture.secondID
                })
        ].status = .running
        try writeDispatchRun(runningRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionDispatchNotFailed(status: .running))

        var completedRun = originalRun
        completedRun.records[
            try XCTUnwrap(
                completedRun.records.firstIndex {
                    $0.id == fixture.secondID
                })
        ].status = .completed
        try writeDispatchRun(completedRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionDispatchNotFailed(status: .completed))

        try writeDispatchRun(originalRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionAttemptBelowCap(
                attempt: 1,
                cap: TatwoGoalRunStore.dispatchRetryAttemptCap),
            dispatchID: fixture.firstID)

        for failureClass in [
            TatwoDispatchFailureClass.terminal,
            .unknown,
        ] {
            var classifiedRun = originalRun
            let index = try XCTUnwrap(
                classifiedRun.records.firstIndex {
                    $0.id == fixture.secondID
                })
            let receipt = try XCTUnwrap(
                classifiedRun.records[index].failureReceipt)
            classifiedRun.records[index].failureReceipt =
                TatwoDispatchFailureReceipt(
                    failureClass: failureClass,
                    errorCode: receipt.errorCode,
                    httpStatus: receipt.httpStatus,
                    operatorMessage: receipt.operatorMessage,
                    rawErrorDigest: receipt.rawErrorDigest,
                    backendRequestID: receipt.backendRequestID,
                    backendResponseID: receipt.backendResponseID,
                    occurredAt: receipt.occurredAt)
            try writeDispatchRun(classifiedRun, to: store)
            try assertRejected(
                .dispatchRetryExhaustionFailureNotRetryable(
                    failureClass: failureClass))
        }

        var recordContractMismatchRun = originalRun
        let targetIndex = try XCTUnwrap(
            recordContractMismatchRun.records.firstIndex {
                $0.id == fixture.secondID
            })
        recordContractMismatchRun.records[targetIndex] =
            TatwoDispatchRecord(
                schema: target.schema,
                id: target.id,
                contractID: "contract-record-mismatch",
                goalID: target.goalID,
                bindingID: target.bindingID,
                sourceSlotID: target.sourceSlotID,
                identity: target.identity,
                modelID: target.modelID,
                subtask: target.subtask,
                logicalDispatchID: target.logicalDispatchID,
                supersedes: target.supersedes,
                attempt: target.attempt,
                cycleEpoch: target.cycleEpoch,
                status: target.status,
                startedAt: target.startedAt,
                updatedAt: target.updatedAt,
                receiptID: target.receiptID,
                outputRef: target.outputRef,
                errorMessage: target.errorMessage,
                failureReceipt: target.failureReceipt,
                remoteJobID: target.remoteJobID,
                originDeviceID: target.originDeviceID,
                targetDeviceID: target.targetDeviceID,
                remoteStatus: target.remoteStatus,
                remoteJobDigest: target.remoteJobDigest,
                remoteDispatchNonce: target.remoteDispatchNonce,
                consumedResultDigest: target.consumedResultDigest,
                remoteProjectionSequence: target.remoteProjectionSequence)
        try writeDispatchRun(recordContractMismatchRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionDispatchContractMismatch(
                expected: contractID,
                actual: "contract-record-mismatch"))

        var staleCycleRun = originalRun
        staleCycleRun.activeCycleEpoch =
            target.resolvedCycleEpoch + 1
        try writeDispatchRun(staleCycleRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionCycleMismatch(
                expected: target.resolvedCycleEpoch + 1,
                actual: target.resolvedCycleEpoch))

        var supersededRun = originalRun
        let liveSuperseding = TatwoDispatchRecord(
            id: "dispatch-live-superseding-attempt",
            contractID: contractID,
            goalID: target.goalID,
            bindingID: target.bindingID,
            sourceSlotID: target.sourceSlotID,
            identity: target.identity,
            modelID: target.modelID,
            subtask: target.subtask,
            logicalDispatchID: target.logicalDispatchID,
            supersedes: target.id,
            attempt: target.resolvedAttempt + 1,
            cycleEpoch: target.cycleEpoch,
            status: .running,
            startedAt: target.updatedAt,
            updatedAt: target.updatedAt)
        supersededRun.records.append(liveSuperseding)
        try writeDispatchRun(supersededRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionLiveSupersedingDispatch(
                dispatchID: target.id,
                supersedingDispatchID: liveSuperseding.id))

        var transitiveSupersededRun = originalRun
        var terminalIntermediate = liveSuperseding
        terminalIntermediate.status = .failed
        terminalIntermediate.failureReceipt = target.failureReceipt
        let transitiveLiveSuperseding = TatwoDispatchRecord(
            id: "dispatch-live-transitive-superseding-attempt",
            contractID: contractID,
            goalID: target.goalID,
            bindingID: target.bindingID,
            sourceSlotID: target.sourceSlotID,
            identity: target.identity,
            modelID: target.modelID,
            subtask: target.subtask,
            logicalDispatchID: target.logicalDispatchID,
            supersedes: terminalIntermediate.id,
            attempt: terminalIntermediate.resolvedAttempt + 1,
            cycleEpoch: target.cycleEpoch,
            status: .queued,
            startedAt: target.updatedAt,
            updatedAt: target.updatedAt)
        transitiveSupersededRun.records.append(terminalIntermediate)
        transitiveSupersededRun.records.append(transitiveLiveSuperseding)
        try writeDispatchRun(transitiveSupersededRun, to: store)
        try assertRejected(
            .dispatchRetryExhaustionLiveSupersedingDispatch(
                dispatchID: target.id,
                supersedingDispatchID: transitiveLiveSuperseding.id))

        try writeDispatchRun(originalRun, to: store)
        let mismatchedRun = TatwoStoredDispatchRun(
            schema: originalRun.schema,
            contractID: "contract-ledger-mismatch",
            executionManifest: originalRun.executionManifest,
            executionManifestSHA256:
                originalRun.executionManifestSHA256,
            manifestEntryIDs: originalRun.manifestEntryIDs,
            records: originalRun.records,
            updatedAt: originalRun.updatedAt,
            sealID: originalRun.sealID,
            sealedAt: originalRun.sealedAt,
            sealedRecordIDs: originalRun.sealedRecordIDs,
            sealedGoalID: originalRun.sealedGoalID,
            activeCycleEpoch: originalRun.activeCycleEpoch,
            cycleSeals: originalRun.cycleSeals)
        try writeDispatchRun(
            mismatchedRun,
            to: store,
            fileContractID: contractID)
        try assertRejected(
            .dispatchRetryExhaustionRunContractMismatch(
                expected: contractID,
                actual: mismatchedRun.contractID))

        try writeDispatchRun(originalRun, to: store)
        try writeGoalRecord(originalGoal, to: store)
    }

    func testRetryExhaustionRejectsUnrelatedFailedReasonWithoutMutation()
        async throws
    {
        let fixture = try await makeRetryExhaustionFixture()
        var unrelatedFailure = fixture.failedGoal
        unrelatedFailure.statusReason =
            "authority_violation:host_executor_missing"
        try writeGoalRecord(
            unrelatedFailure,
            to: fixture.chat.goalStore)
        let ledgerBefore = try XCTUnwrap(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID))
        let expectedReason =
            "dispatch_failed:\(fixture.secondID):"
            + "class=retryable:attempt=2"

        XCTAssertThrowsError(
            try fixture.chat.goalStore.markDispatchRetryExhausted(
                contractID: fixture.chat.plgContract.contractID,
                dispatchID: fixture.secondID)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .dispatchRetryExhaustionReasonMismatch(
                    expected: expectedReason,
                    actual: unrelatedFailure.statusReason))
        }
        XCTAssertEqual(
            try fixture.chat.goalStore.requireIssuedContract(
                fixture.chat.plgContract.contractID),
            unrelatedFailure)
        XCTAssertEqual(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: fixture.chat.plgContract.contractID),
            ledgerBefore)
    }

    func testRetryExhaustionReadbackMismatchRollsBackExactGoalSnapshot()
        async throws
    {
        let fixture = try await makeRetryExhaustionFixture()
        let contractID = fixture.chat.plgContract.contractID
        let originalGoal = fixture.failedGoal
        let ledgerBefore = fixture.dispatchRun
        var injectedDrift = originalGoal
        injectedDrift.statusReason = "injected_post_write_drift"
        injectedDrift.updatedAt = Date(
            timeIntervalSince1970:
                originalGoal.updatedAt.timeIntervalSince1970 + 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let driftData = try encoder.encode(injectedDrift)
        let goalURL = goalRunURL(
            contractID: contractID,
            store: fixture.chat.goalStore)
        let rollbackStore = TatwoGoalRunStore(
            directoryURL: fixture.chat.goalStore.directoryURL,
            dispatchRetryExhaustionPostWriteHook: {
                try driftData.write(to: goalURL, options: [.atomic])
            })

        XCTAssertThrowsError(
            try rollbackStore.markDispatchRetryExhausted(
                contractID: contractID,
                dispatchID: fixture.secondID)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .dispatchRetryExhaustionReadbackMismatch(
                    contractID: contractID))
        }
        XCTAssertEqual(
            try rollbackStore.requireIssuedContract(contractID),
            originalGoal,
            "readback mismatch must compensate back to the exact locked snapshot")
        XCTAssertEqual(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: contractID),
            ledgerBefore,
            "readback compensation must not mutate the dispatch ledger")
    }

    func testRetryExhaustionRollbackMapsTypedStoreErrorToRollbackFailed()
        async throws
    {
        let fixture = try await makeRetryExhaustionFixture()
        let contractID = fixture.chat.plgContract.contractID
        let originalGoal = fixture.failedGoal
        let ledgerBefore = fixture.dispatchRun
        var injectedDrift = originalGoal
        injectedDrift.statusReason = "injected_post_write_drift"
        injectedDrift.updatedAt = Date(
            timeIntervalSince1970:
                originalGoal.updatedAt.timeIntervalSince1970 + 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let driftData = try encoder.encode(injectedDrift)
        let goalURL = goalRunURL(
            contractID: contractID,
            store: fixture.chat.goalStore)
        let rollbackStore = TatwoGoalRunStore(
            directoryURL: fixture.chat.goalStore.directoryURL,
            dispatchRetryExhaustionPostWriteHook: {
                try driftData.write(to: goalURL, options: [.atomic])
            },
            dispatchRetryExhaustionRollbackReadbackHook: {
                throw TatwoGoalRunStoreError.unregisteredContract(
                    "injected-rollback-readback")
            })

        XCTAssertThrowsError(
            try rollbackStore.markDispatchRetryExhausted(
                contractID: contractID,
                dispatchID: fixture.secondID)
        ) { error in
            XCTAssertEqual(
                error as? TatwoGoalRunStoreError,
                .dispatchRetryExhaustionRollbackFailed(
                    contractID: contractID))
        }
        XCTAssertEqual(
            try rollbackStore.requireIssuedContract(contractID),
            originalGoal,
            "rollback write completed before the injected typed readback error")
        XCTAssertEqual(
            try fixture.chat.model.dispatchRegistry.run(
                forContractID: contractID),
            ledgerBefore,
            "rollback failure classification must not mutate the dispatch ledger")
    }

    func testFailureSettlementAfterThreadSwitchUsesOriginContractLedger()
        async throws
    {
        let fixture = try await makeTwoUltraworkChatFixture()
        let model = fixture.model
        let subtask = "settle this dispatch against its originating contract"

        XCTAssertTrue(model.beginSingleModelGoalDispatch(subtask: subtask))
        let dispatchID = try XCTUnwrap(
            model.pendingSingleModelGoalDispatch?.id)
        model.selectStandaloneThread(fixture.goalThreadID)
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            fixture.pointerHolderContract.contractID)
        let pointerHolderRunBeforeSettlement = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.pointerHolderContract.contractID),
            "formal contract issuance must already persist its execution manifest")
        XCTAssertTrue(
            pointerHolderRunBeforeSettlement.records.isEmpty,
            "pointer-holder ledger must have no dispatch records before settlement")

        model.failPendingSingleModelGoalDispatch(
            dispatchID: dispatchID,
            message: "runner failed after the visible thread changed")

        let originRecord = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.plgContract.contractID)?
                .records.first(where: { $0.id == dispatchID }))
        XCTAssertEqual(originRecord.status, .failed)
        XCTAssertEqual(
            originRecord.failureReceipt?.errorCode,
            "single_model_runner_not_started")
        let pointerHolderRunAfterSettlement = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: fixture.pointerHolderContract.contractID),
            "settlement must not remove the selected contract ledger")
        XCTAssertEqual(
            pointerHolderRunAfterSettlement,
            pointerHolderRunBeforeSettlement,
            "settlement must not create or mutate the selected contract ledger")
        XCTAssertTrue(
            pointerHolderRunAfterSettlement.records.isEmpty,
            "settlement must not append a dispatch record to the selected ledger")
        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(
                fixture.pointerHolderContract.contractID).status,
            .planned)

        model.selectStandaloneThread(fixture.plgThreadID)
        XCTAssertNil(model.pendingSingleModelGoalDispatch)
        XCTAssertNil(
            model.singleModelGoalDispatchContractIDByDispatchID[dispatchID])
    }

    // MARK: - fixture

    private struct TwoUltraworkChatFixture {
        let root: URL
        let model: ChatPageModel
        let goalStore: TatwoGoalRunStore
        let dispatch: PLGAuthorityRecordingDispatchService
        let plgThreadID: UUID
        let goalThreadID: UUID
        let plgContract: TatwoWorkOSContractV1
        let pointerHolderContract: TatwoWorkOSContractV1

        /// 送出後 runner 由 pending-remote claim 之後才非同步起跑。
        @MainActor
        func awaitRunnerStart() async throws {
            for _ in 0..<200 where dispatch.startCount == 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private struct RetryExhaustionFixture {
        let chat: TwoUltraworkChatFixture
        let firstID: String
        let secondID: String
        let failedGoal: TatwoStoredGoalRun
        let dispatchRun: TatwoStoredDispatchRun
    }

    private func makeRetryExhaustionFixture() async throws
        -> RetryExhaustionFixture
    {
        let chat = try await makeTwoUltraworkChatFixture()
        let model = chat.model
        let subtask = "prepare authoritative retry exhaustion fixture"
        XCTAssertTrue(model.beginSingleModelGoalDispatch(subtask: subtask))
        let firstID = try XCTUnwrap(
            model.pendingSingleModelGoalDispatch?.id)
        model.failPendingSingleModelGoalDispatch(
            dispatchID: firstID,
            message: "first runner did not start")
        XCTAssertTrue(model.beginSingleModelGoalDispatch(subtask: subtask))
        let secondID = try XCTUnwrap(
            model.pendingSingleModelGoalDispatch?.id)
        model.failPendingSingleModelGoalDispatch(
            dispatchID: secondID,
            message: "second runner did not start")
        let failedGoal = try chat.goalStore.requireIssuedContract(
            chat.plgContract.contractID)
        let dispatchRun = try XCTUnwrap(
            try model.dispatchRegistry.run(
                forContractID: chat.plgContract.contractID))
        XCTAssertEqual(failedGoal.status, .failed)
        XCTAssertEqual(
            dispatchRun.records.first(where: { $0.id == secondID })?
                .failureReceipt?.failureClass,
            .retryable)
        XCTAssertEqual(
            dispatchRun.records.first(where: { $0.id == secondID })?
                .resolvedAttempt,
            2)
        return RetryExhaustionFixture(
            chat: chat,
            firstID: firstID,
            secondID: secondID,
            failedGoal: failedGoal,
            dispatchRun: dispatchRun)
    }

    private func writeGoalRecord(
        _ record: TatwoStoredGoalRun,
        to store: TatwoGoalRunStore
    ) throws {
        let url = goalRunURL(
            contractID: record.contractID,
            store: store)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    private func writeDispatchRun(
        _ run: TatwoStoredDispatchRun,
        to store: TatwoGoalRunStore,
        fileContractID: String? = nil
    ) throws {
        let url = dispatchRunURL(
            contractID: fileContractID ?? run.contractID,
            store: store)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: url, options: [.atomic])
    }

    private func goalRunURL(
        contractID: String,
        store: TatwoGoalRunStore
    ) -> URL {
        store.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
            .appendingPathComponent(
                "\(contractID).json",
                isDirectory: false)
    }

    private func dispatchRunURL(
        contractID: String,
        store: TatwoGoalRunStore
    ) -> URL {
        store.directoryURL
            .appendingPathComponent("dispatches", isDirectory: true)
            .appendingPathComponent(
                "\(contractID).json",
                isDirectory: false)
    }

    /// 兩條 Ultrawork S／terra 對話：先建 PLG thread（合約較早），再建第二條
    /// Goal thread，讓 current-session 指標落在**後者**——與 runtime-63
    /// 磁碟狀態同形。
    private func makeTwoUltraworkChatFixture() async throws -> TwoUltraworkChatFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-plg-s-authority-\(UUID().uuidString)",
                isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let dispatch = PLGAuthorityRecordingDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatPLGSingleModelExecutionAuthorityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: PLGAuthorityTestAnchorAuthority()),
            nativeRunner: PLGAuthorityNoopNativeRunner(),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())

        // runtime-63 同形：兩條 tatwo-user-owned Chat row，各自 Ultrawork S
        // ／daily／主導 gpt-5.6-terra。
        let plgThread = TatwoNativeChatThread(
            title: "/plan Node.js",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            loopsConfig: Self.singleTerraLoopsConfig)
        let goalThread = TatwoNativeChatThread(
            title: "/plan Python",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            loopsConfig: Self.singleTerraLoopsConfig)
        model.document = TatwoNativeChatStoreDocument(
            threads: [plgThread, goalThread])
        model.selectedModel = "gpt-5.6-terra"

        model.selectStandaloneThread(plgThread.id)
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: Self.plgObjective,
                requireObjectiveMatch: true,
                allowCreateIfUnbound: true,
                automaticallyBootstrapUserOwnedAuthority: true),
            model.selectedWorkOSStateMessage)
        let plgContract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertEqual(plgContract.mode, .s)
        XCTAssertFalse(
            ChatPageModel.isExactNativeDevelopmentScenario(
                plgContract.scenario))

        model.selectStandaloneThread(goalThread.id)
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint:
                    "執行目前 thread 已確認的 Python Plan：只在沙盒建立三個檔案",
                requireObjectiveMatch: true,
                allowCreateIfUnbound: true,
                automaticallyBootstrapUserOwnedAuthority: true),
            model.selectedWorkOSStateMessage)
        let pointerHolderContract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertNotEqual(
            pointerHolderContract.contractID,
            plgContract.contractID)

        // live 前提：磁碟指標屬於後建立的那條 Chat row。
        let pointer = try XCTUnwrap(
            try TatwoSessionStore(directoryURL: goalStore.directoryURL)
                .snapshotCurrent()?.pointer)
        XCTAssertEqual(
            pointer.contractID,
            pointerHolderContract.contractID,
            "fixture 前提不成立：current-session 指標不在第二條對話上")

        // 主線的實機動作：從側欄切回較早的 PLG thread，等非同步 Work OS
        // 投影載入完成。
        model.selectStandaloneThread(plgThread.id)
        for _ in 0..<200
        where model.selectedWorkOSContract?.contractID
            != plgContract.contractID
        {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            plgContract.contractID,
            model.selectedWorkOSStateMessage)

        return TwoUltraworkChatFixture(
            root: root,
            model: model,
            goalStore: goalStore,
            dispatch: dispatch,
            plgThreadID: plgThread.id,
            goalThreadID: goalThread.id,
            plgContract: plgContract,
            pointerHolderContract: pointerHolderContract)
    }

    /// 逐字取自 runtime-63 dispatch record 的 subtask 頭三行（`confirmedPlanExecutionPrompt`）。
    private static let confirmedPlanExecutionTurn = """
        依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃、不要只重述計畫。
        必須使用可用工具在目前工作目錄完成要求的檔案修改，並實際執行計畫中的測試或驗證。
        若受到權限、環境或需求阻塞，請明確回報阻塞；沒有工具執行與驗證證據時不得宣稱完成。
        """

    private static let plgObjective =
        "執行目前 thread 已確認的 Node.js Plan：只在 "
        + "\(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/session-main-plan-plg-terra-r2"
        + " 建立三個檔案"

    private static let singleTerraLoopsConfig = TatwoNativeThreadLoopsConfig(
        scenarioID: "daily",
        mode: .s,
        identitySummary: "Plan:主導=gpt-5.6-terra；Goal:驗收=gpt-5.6-terra",
        tokenBudget: "S 小修：gpt-5.6-terra 主線-only。",
        primaryModelID: "gpt-5.6-terra",
        secondaryModelID: nil)

    private static func leadAdversarialRun(
        contract: TatwoWorkOSContractV1
    ) -> TatwoPLGRun {
        var run = TatwoPLGRunFactory.make(
            objective: contract.objective,
            contractID: contract.contractID,
            goalID: contract.goalID,
            leadModelIDs: contract.identityBindings
                .filter { $0.identity == .lead }
                .compactMap(\.modelID),
            subModelIDs: [],
            nowISO: "2026-08-28T02:26:00Z")
        run.phase = .leadAdversarial
        return run
    }
}

private struct PLGAuthorityTestAnchorAuthority: TatwoPLGAnchorAuthority {
    func sign(_ material: String) -> String {
        "chat-plg-single-model-test-anchor|\(material)"
    }

    func verify(_ signature: String, material: String) -> Bool {
        signature == sign(material)
    }
}

private final class PLGAuthorityNoopNativeRunner:
    ChatNativeAgentRunning,
    @unchecked Sendable
{
    func start(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        ChatRunnerAttemptIdentity(
            runID: request.runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
    }

    func terminate() {}
}

@MainActor
private final class PLGAuthorityRecordingDispatchService: ChatDispatchService {
    private(set) var startCount = 0
    private(set) var lastCommand: ChatCLICommand?
    var clearsRunningBeforeReturningIdentity = false
    private var callback: (@Sendable (ChatCLIEvent) -> Void)?

    func startRuntime(
        model: ChatPageModel,
        command: ChatCLICommand,
        nativePrompt: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        runID: String,
        activityTurnID: String,
        allowsNativeGovernanceFallback: Bool,
        nativeGovernanceFallbackCommand: ChatCLICommand?,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        startCount += 1
        lastCommand = command
        callback = onEvent
        let identity = ChatRunnerAttemptIdentity(
            runID: runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
        if clearsRunningBeforeReturningIdentity {
            model.isRunning = false
        }
        return identity
    }

    func emit(_ event: ChatCLIEvent) {
        callback?(event)
    }
}

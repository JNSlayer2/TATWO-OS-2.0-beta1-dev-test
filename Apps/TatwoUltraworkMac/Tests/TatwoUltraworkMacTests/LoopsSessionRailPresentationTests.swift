import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class LoopsSessionRailPresentationTests: XCTestCase {
    func testPlanningPreviewDoesNotImplyRuntimeStarted() {
        let session = makeSession()
        let truth = TatwoLoopsDispatchPlanner.runtimeTruth(session: session)

        XCTAssertEqual(truth.state, .planningPreview)
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.statusLabel(for: truth),
            "規劃預覽")
        XCTAssertTrue(
            LoopsSessionPresentationPolicy.statusSummary(for: truth)
                .contains("尚未啟動"))
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.workerSummary(
                session: session,
                truth: truth),
            "尚無 runtime agent")
        XCTAssertTrue(
            LoopsSessionPresentationPolicy.nextStep(for: truth)
                .contains("送交 Work OS"))
        XCTAssertFalse(
            LoopsSessionPresentationPolicy.shouldShowCycles(for: session))
    }

    func testUnboundRunningMarkerStaysPlanningOnly() {
        var session = makeSession()
        session.status = .running
        let truth = TatwoLoopsDispatchPlanner.runtimeTruth(session: session)

        XCTAssertEqual(truth.state, .planningPreview)
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.statusLabel(for: truth),
            "規劃預覽")
        XCTAssertTrue(
            LoopsSessionPresentationPolicy.statusSummary(for: truth)
                .contains("尚未啟動"))
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.workerSummary(
                session: session,
                truth: truth),
            "尚無 runtime agent")
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.agentTone(
                status: .running,
                truth: truth),
            .muted)
    }

    func testAgentToneDoesNotClaimActiveOrVerifiedWithoutRuntimeEvidence() {
        let planningTruth = TatwoLoopsDispatchPlanner.runtimeTruth(
            session: makeSession())

        XCTAssertEqual(
            LoopsSessionPresentationPolicy.agentTone(
                status: .planned,
                truth: planningTruth),
            .muted)
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.agentTone(
                status: .running,
                truth: planningTruth),
            .muted)
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.agentTone(
                status: .passed,
                truth: planningTruth),
            .muted)

        let receiptGatedTruth = TatwoLoopsRuntimeTruthSummary(
            state: .receiptGated,
            headline: "已有產出",
            dispatchLabel: "等待收據",
            runtimeReceiptLabel: "無 runtime receipt",
            nextAction: "補齊收據",
            plannedAgentCount: 0,
            activeAgentCount: 0,
            producedArtifactCount: 1,
            verifiedArtifactCount: 1,
            blockedArtifactCount: 0,
            runtimeReceiptCount: 0,
            countsAsRuntimeProgress: true)
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.agentTone(
                status: .passed,
                truth: receiptGatedTruth),
            .warning)
    }

    func testSubmissionAndPlanningConversationLabelsArePlainLanguage() {
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.submissionLabel(isDispatching: false),
            "送交 Work OS")
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.submissionLabel(isDispatching: true),
            "送交中…")
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.planningConversationTitle,
            "規劃筆記")
    }

    func testCollapsedDensityStays48PointsForFiveAndTwentyRows() {
        for rowCount in [5, 20] {
            let rowIDs = (0..<rowCount).map { _ in UUID() }
            let collapsedHeights = rowIDs.map { _ in
                LoopsSessionRailDensityPolicy.collapsedRowHeight
            }

            XCTAssertEqual(collapsedHeights.count, rowCount)
            XCTAssertEqual(
                collapsedHeights,
                Array(repeating: CGFloat(48), count: rowCount))
        }
    }

    func testOnlySelectedLoopRowExpandsAcrossTwentyRows() {
        let rowIDs = (0..<20).map { _ in UUID() }
        let selectedID = rowIDs[11]

        let expandedRows = rowIDs.filter {
            LoopsSessionRailDensityPolicy.isExpanded(
                rowID: $0,
                selectedID: selectedID)
        }

        XCTAssertEqual(expandedRows, [selectedID])
        XCTAssertFalse(
            rowIDs.contains {
                LoopsSessionRailDensityPolicy.isExpanded(
                    rowID: $0,
                    selectedID: nil)
            })
    }

    func testCompactRowsShowOwnerAndPlainLanguageProgress() {
        var session = makeSession()
        session.subAgents = [
            TatwoLoopsSubAgent(
                label: "builder",
                modelID: "gpt-5.6-sol",
                status: .planned),
            TatwoLoopsSubAgent(
                label: "reviewer",
                modelID: "gpt-5.4",
                status: .planned),
        ]
        let planningTruth = TatwoLoopsDispatchPlanner.runtimeTruth(session: session)

        XCTAssertEqual(
            LoopsSessionPresentationPolicy.compactOwnerLabel(session: session),
            "監工 fable5")
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.compactProgressLabel(
                session: session,
                truth: planningTruth),
            "預計 2 個角色")

        XCTAssertEqual(
            LoopsSessionPresentationPolicy.compactProgressLabel(
                session: session,
                truth: makeTruth(state: .dispatched)),
            "已送交，等待開始")
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.compactProgressLabel(
                session: session,
                truth: makeTruth(
                    state: .running,
                    activeAgentCount: 2)),
            "2 個執行中")
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.compactProgressLabel(
                session: session,
                truth: makeTruth(
                    state: .receiptGated,
                    producedArtifactCount: 5,
                    verifiedArtifactCount: 3,
                    runtimeReceiptCount: 1)),
            "已驗證 3/5")
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.compactProgressLabel(
                session: session,
                truth: makeTruth(
                    state: .blocked,
                    blockedArtifactCount: 1)),
            "1 項卡關")
    }

    func testNestedDisclosuresResetWhenSwitchingToAnotherLoop() {
        var firstRow = LoopsSessionDisclosureState(
            cycleHistoryExpanded: true,
            configurationExpanded: true,
            planningConversationExpanded: true)
        var secondRow = LoopsSessionDisclosureState()

        firstRow.rowExpansionChanged(to: false)
        secondRow.rowExpansionChanged(to: true)

        XCTAssertEqual(firstRow, LoopsSessionDisclosureState())
        XCTAssertEqual(secondRow, LoopsSessionDisclosureState())
    }

    func testSourceKeepsDetailsCollapsedAndHidesEmptyCycles() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LoopsSessionRail.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            source.contains(
                "@State private var disclosureState = LoopsSessionDisclosureState()"))
        XCTAssertTrue(source.contains("disclosureState.rowExpansionChanged(to: expanded)"))
        XCTAssertTrue(source.contains("guard !isExpanded else { return }"))
        XCTAssertFalse(source.contains("secondaryPlanningExpanded"))
        XCTAssertTrue(
            source.contains(
                "if LoopsSessionPresentationPolicy.shouldShowCycles(for: session)"))
        XCTAssertTrue(source.contains(#"title: "完整規劃與配置""#))
        XCTAssertTrue(source.contains(#"TextField("新增規劃筆記…""#))
        XCTAssertTrue(source.contains(#"detail: "\(sessions.count) 條 · 點擊一列展開""#))
        XCTAssertTrue(source.contains("struct LoopsAccordionRowLabel"))
        XCTAssertTrue(
            source.contains(
                "static let collapsedRowHeight: CGFloat = 48"))
        XCTAssertTrue(
            source.contains(
                "minHeight: LoopsSessionRailDensityPolicy.collapsedRowHeight"))
        XCTAssertTrue(
            source.contains(
                "maxHeight: LoopsSessionRailDensityPolicy.collapsedRowHeight"))
        let rowLabel = try XCTUnwrap(
            source.slice(
                from: "private struct LoopsAccordionRowLabel",
                through: "struct LoopsSessionRail"))
        XCTAssertGreaterThanOrEqual(
            rowLabel.components(separatedBy: ".lineLimit(1)").count - 1,
            3)
        XCTAssertGreaterThanOrEqual(
            rowLabel.components(separatedBy: ".truncationMode(.tail)").count - 1,
            2)
        XCTAssertFalse(source.contains("summary: goalSummary"))
        XCTAssertTrue(
            source.contains(
                "LoopsSessionPresentationPolicy.compactOwnerLabel(session: session)"))
        XCTAssertTrue(
            source.contains(
                "LoopsSessionPresentationPolicy.compactProgressLabel("))
        XCTAssertTrue(
            source.contains(
                "isExpanded: LoopsSessionRailDensityPolicy.isExpanded("))
        XCTAssertFalse(
            source.contains("isExpanded: selectedID == session.id"))
        XCTAssertTrue(source.contains("toggleCurrentWork()"))
        XCTAssertTrue(source.contains("toggleLiveDetails()"))
        XCTAssertTrue(source.contains("onSelect: { selectSession(session.id) }"))
        XCTAssertTrue(source.contains(#""放大為全寬 Loops 工作區""#))
        XCTAssertTrue(source.contains(#""縮回並排顯示""#))
        XCTAssertFalse(source.contains(#""派工 sub""#))
        XCTAssertFalse(source.contains("supervisorLockBadge"))
    }

    func testFourteenCyclesStayBehindTheirOwnCollapsedDisclosure() throws {
        var session = makeSession()
        session.cycles = (1...14).map { round in
            TatwoLoopsCycleProgress(
                round: round,
                totalRounds: 14,
                producedCount: round,
                verifiedCount: max(round - 1, 0),
                blockedCount: 0)
        }
        let state = LoopsSessionDisclosureState()

        XCTAssertTrue(
            LoopsSessionPresentationPolicy.shouldShowCycles(for: session))
        XCTAssertFalse(state.cycleHistoryExpanded)
        XCTAssertEqual(
            LoopsSessionPresentationPolicy.compactProgressLabel(
                session: session,
                truth: TatwoLoopsDispatchPlanner.runtimeTruth(session: session)),
            "已有 14 輪規劃，尚未送交")

        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LoopsSessionRail.swift"),
            encoding: .utf8)
        let configuration = try XCTUnwrap(
            source.slice(
                from: "private var configurationDisclosure",
                through: "private var cycleHistoryDisclosure"))
        XCTAssertFalse(configuration.contains("cyclesViz"))

        let cycleDisclosure = try XCTUnwrap(
            source.slice(
                from: "private var cycleHistoryDisclosure",
                through: "private var planningConversationDisclosure"))
        XCTAssertTrue(
            cycleDisclosure.contains(
                "DisclosureGroup(isExpanded: $disclosureState.cycleHistoryExpanded)"))
        XCTAssertTrue(cycleDisclosure.contains("cyclesViz"))
        XCTAssertTrue(cycleDisclosure.contains(#"title: "輪次進度""#))
        XCTAssertTrue(cycleDisclosure.contains("compactCycleSummary"))
    }

    func testAccordionSelectionAllowsOnlyOneExpandedRowAndSecondClickCollapsesIt() {
        let first = UUID()
        let second = UUID()

        let opened = LoopsSessionSelectionPolicy.toggledSelection(
            current: nil,
            tapped: first)
        let switched = LoopsSessionSelectionPolicy.toggledSelection(
            current: opened,
            tapped: second)
        let collapsed = LoopsSessionSelectionPolicy.toggledSelection(
            current: switched,
            tapped: second)

        XCTAssertEqual(opened, first)
        XCTAssertEqual(switched, second)
        XCTAssertNil(collapsed)
    }

    func testChatPageWiresRailSelectionToModelAccordionReducer() throws {
        let source = try ChatSourceFamily.read("ChatPage.swift")

        XCTAssertTrue(source.contains("model.selectLoopsSession($0)"))
        XCTAssertTrue(
            source.contains(
                "canonicalGoalRecord: model.selectedGoalRecord"))
    }

    func testSupersededCanonicalGoalUsesHistoricalNotBlockedPresentation() {
        let goal = TatwoStoredGoalRun(
            goalID: "old-goal",
            contractID: "old-contract",
            mode: .xxl,
            scenario: "coding",
            objective: "old objective",
            status: .superseded,
            issuedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20))
        let dispatch = TatwoDispatchRecord(
            id: "old-failure",
            contractID: goal.contractID,
            bindingID: "old-worker",
            sourceSlotID: "slot",
            identity: .sub,
            modelID: "gpt-5.6-sol",
            subtask: "historical",
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 10),
            errorMessage: "historical failure")
        let lane = TatwoGoalRunLaneAggregator.aggregate(
            goalRecords: [goal],
            dispatchRuns: [
                TatwoStoredDispatchRun(
                    contractID: goal.contractID,
                    records: [dispatch],
                    updatedAt: dispatch.updatedAt)
            ],
            observedAt: Date(timeIntervalSince1970: 30)
        ).lanes[0]

        XCTAssertEqual(lane.state, .superseded)
        XCTAssertEqual(lane.blockers, [])
        XCTAssertEqual(lane.cost.dispatchAttemptCount, 1)
        XCTAssertEqual(
            lane.identityGroups.first?.failedWorkerCount,
            1)
        XCTAssertEqual(
            LoopsCanonicalGoalPresentationPolicy.status(lane).label,
            "已由新版取代")
        XCTAssertNotEqual(
            LoopsCanonicalGoalPresentationPolicy.status(lane).label,
            "執行受阻")
    }

    func testTopLevelAccordionRowsCollapseOtherExpandedContent() throws {
        var state = LoopsSessionRailAccordionState()

        XCTAssertTrue(state.toggleCurrentWork())
        XCTAssertEqual(
            state,
            LoopsSessionRailAccordionState(
                currentWorkExpanded: true,
                liveDetailsExpanded: false,
                archivedExpanded: false))

        XCTAssertTrue(state.toggleLiveDetails())
        XCTAssertEqual(
            state,
            LoopsSessionRailAccordionState(
                currentWorkExpanded: false,
                liveDetailsExpanded: true,
                archivedExpanded: false))

        XCTAssertTrue(state.setArchivedExpanded(true))
        XCTAssertEqual(
            state,
            LoopsSessionRailAccordionState(
                currentWorkExpanded: false,
                liveDetailsExpanded: false,
                archivedExpanded: true))

        state.sessionSelected()
        XCTAssertEqual(state, LoopsSessionRailAccordionState())

        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LoopsSessionRail.swift"),
            encoding: .utf8)

        let selection = try XCTUnwrap(
            source.slice(
                from: "private func selectSession",
                through: "private func toggleCurrentWork"))
        XCTAssertTrue(selection.contains("accordionState.sessionSelected()"))

        let currentWork = try XCTUnwrap(
            source.slice(
                from: "private func toggleCurrentWork",
                through: "private func toggleLiveDetails"))
        XCTAssertTrue(
            currentWork.contains(
                "let willExpand = accordionState.toggleCurrentWork()"))
        XCTAssertTrue(currentWork.contains("if willExpand, let selectedID"))
        XCTAssertTrue(currentWork.contains("onSelect(selectedID)"))

        let live = try XCTUnwrap(
            source.slice(
                from: "private func toggleLiveDetails",
                through: "private func setArchivedExpanded"))
        XCTAssertTrue(
            live.contains(
                "let willExpand = accordionState.toggleLiveDetails()"))
        XCTAssertTrue(live.contains("if willExpand, let selectedID"))
        XCTAssertTrue(live.contains("onSelect(selectedID)"))

        let archived = try XCTUnwrap(
            source.slice(
                from: "private func setArchivedExpanded",
                through: "private func runtimeColor"))
        XCTAssertTrue(
            archived.contains(
                "let willExpand = accordionState.setArchivedExpanded(expanded)"))
        XCTAssertTrue(archived.contains("if willExpand, let selectedID"))
        XCTAssertTrue(archived.contains("onSelect(selectedID)"))
        XCTAssertTrue(
            source.contains(
                ".onChange(of: selectedID) { _, newSelection in"))
        XCTAssertTrue(source.contains("accordionState.sessionSelected()"))
    }

    func testHumanPlanningInputCannotMasqueradeAsSupervisorModel() throws {
        let chatSource = try ChatSourceFamily.read("ChatPage.swift")
        let workflowSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            chatSource.contains("model.appendHumanLoopNote(id, text: text)"))
        let humanAPI = try XCTUnwrap(
            workflowSource.slice(
                from: "func appendHumanLoopNote",
                through: "private func appendLoopMessage"))
        XCTAssertTrue(humanAPI.contains(#"role: "human""#))
        XCTAssertTrue(humanAPI.contains("authorModelID: nil"))
        XCTAssertFalse(humanAPI.contains(#"role: "supervisor""#))
    }

    func testRailUsesOneCanonicalRuntimeCardAndRecoverableArchive() throws {
        let railSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LoopsSessionRail.swift"),
            encoding: .utf8)
        let workflowSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)

        // 2026-08-21 修約：舊裁定「PLG 進行中不畫 liveRows」被使用者回饋
        // 推翻（看不到 sub 實際運作）；實況列自此無條件渲染。
        XCTAssertTrue(
            railSource.contains("if !liveRows.isEmpty {"))
        XCTAssertTrue(railSource.contains(#"title: "目前工作""#))
        XCTAssertTrue(
            railSource.contains(
                #"title: plgRun == nil ? "Loops" : "規劃草稿""#))
        XCTAssertTrue(railSource.contains(#"title: "已封存""#))
        XCTAssertTrue(railSource.contains("showArchiveConfirmation = true"))
        XCTAssertTrue(railSource.contains(#"Button("還原")"#))

        XCTAssertTrue(workflowSource.contains("session.archivedISO ="))
        XCTAssertTrue(workflowSource.contains("session.archivedISO = nil"))
        XCTAssertFalse(
            workflowSource.slice(
                from: "func archiveLoopsSession",
                through: "func restoreLoopsSession")?
                .contains("removeAll") ?? true)
    }

    func testArchiveMetadataRoundTripsWithoutLosingPlanningContent() throws {
        var session = makeSession()
        session.archivedISO = "2026-08-02T12:00:00Z"

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(TatwoLoopsSession.self, from: data)

        XCTAssertTrue(decoded.isArchived)
        XCTAssertEqual(decoded.archivedISO, "2026-08-02T12:00:00Z")
        XCTAssertEqual(decoded.plg, session.plg)
        XCTAssertEqual(decoded.messages, session.messages)
        XCTAssertEqual(decoded.cycles, session.cycles)
    }

    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    private func makeSession() -> TatwoLoopsSession {
        let parentID = UUID()
        return TatwoLoopsSupervisorRule.make(
            parentSupervisorModelID: "fable-5",
            parentKind: .thread,
            parentID: parentID,
            projectID: parentID,
            title: "Loops UI",
            plg: TatwoLoopsPLG(
                plan: "先盤點，再規劃。",
                loops: "Work OS 負責正式派發。",
                goal: "讓 Loops 清楚可操作。"),
            reviewerModelID: "gpt-5.6-sol")
    }

    // MARK: 2026-08-21 Loops 面板重設計（使用者：「配色不協調 而且看不到
    // sub 實際的運作情況」）

    /// 語意色收斂：面板不得再用原生 .green/.orange/.red/.cyan/.blue/.purple
    /// ——狀態一律走 loopsPositive/loopsCaution/loopsCritical/brandAccent。
    func testLoopsSurfacesUseSemanticStatusTokensNotRawSystemColors() throws {
        for filename in ["LoopsSessionRail.swift", "PLGFlowCard.swift"] {
            let source = try String(contentsOf: appSourceFileURL(filename))
            for raw in [
                "return .green", "return .orange", "return .red",
                "return .cyan", "return .blue", "return .purple",
                "Color.green", "Color.orange", "Color.red",
                "color: .green", "color: .orange", "color: .red",
                ".foregroundStyle(.orange)", ".foregroundStyle(.red",
            ] {
                XCTAssertFalse(
                    source.contains(raw),
                    "\(filename) 仍在用原生色 `\(raw)`；請改語意 token")
            }
            XCTAssertTrue(
                source.contains("LiquidGlassTokens.loopsPositive")
                    || source.contains("LiquidGlassTokens.loopsCaution"))
        }
    }

    /// sub 實況：PLG 進行中也要畫 liveRows（舊裁定只給總數已推翻），
    /// 且列內要有模型人話名與已跑多久。
    func testSubLiveRowsRenderDuringPLGWithElapsedTime() throws {
        let source = try String(
            contentsOf: appSourceFileURL("LoopsSessionRail.swift"))
        XCTAssertTrue(
            source.contains("if !liveRows.isEmpty {"),
            "liveRows 不得再被 plgRun != nil 整段抑制")
        XCTAssertFalse(
            source.contains("if plgRun == nil, !liveRows.isEmpty {"))
        XCTAssertTrue(
            source.contains(
                "accordionState.liveDetailsExpanded || plgRun != nil"),
            "PLG 進行中 sub 實況必須直接攤開")
        XCTAssertTrue(
            source.contains(
                "TatwoChatRouteProfile.resolve(row.modelID).displayName"))
        XCTAssertTrue(source.contains("func subLiveRow("))
    }

    func testElapsedLabelFormatsHumanReadableDurations() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            LoopsSessionRail.elapsedLabel(
                since: base, now: base.addingTimeInterval(42)),
            "已跑 42 秒")
        XCTAssertEqual(
            LoopsSessionRail.elapsedLabel(
                since: base, now: base.addingTimeInterval(150)),
            "已跑 2 分")
        XCTAssertEqual(
            LoopsSessionRail.elapsedLabel(
                since: base, now: base.addingTimeInterval(3_900)),
            "已跑 1 小時 5 分")
        XCTAssertEqual(
            LoopsSessionRail.elapsedLabel(
                since: base.addingTimeInterval(10), now: base),
            "已跑 0 秒",
            "時鐘倒退不得出現負數")
    }

    /// 失敗類提示要停留夠久（7 秒），資訊類維持 2.4 秒。
    @MainActor
    func testComposerHintDurationScalesWithSeverity() {
        XCTAssertEqual(
            ChatPageModel.composerHintDisplayDuration(
                for: "GPT-5.6 Sol 原生派工失敗：binding missing"),
            7.0)
        XCTAssertEqual(
            ChatPageModel.composerHintDisplayDuration(
                for: "Work OS continuity 已隔離：owner 不一致"),
            7.0)
        XCTAssertEqual(
            ChatPageModel.composerHintDisplayDuration(
                for: "已離開 Plan 模式"),
            2.4)
    }

    private func appSourceFileURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TatwoUltraworkMac")
            .appendingPathComponent(filename)
    }

    private func makeTruth(
        state: TatwoLoopsRuntimeTruthState,
        activeAgentCount: Int = 0,
        producedArtifactCount: Int = 0,
        verifiedArtifactCount: Int = 0,
        blockedArtifactCount: Int = 0,
        runtimeReceiptCount: Int = 0
    ) -> TatwoLoopsRuntimeTruthSummary {
        TatwoLoopsRuntimeTruthSummary(
            state: state,
            headline: "摘要",
            dispatchLabel: "已送交",
            runtimeReceiptLabel: "收據摘要",
            nextAction: "下一步",
            plannedAgentCount: 0,
            activeAgentCount: activeAgentCount,
            producedArtifactCount: producedArtifactCount,
            verifiedArtifactCount: verifiedArtifactCount,
            blockedArtifactCount: blockedArtifactCount,
            runtimeReceiptCount: runtimeReceiptCount,
            countsAsRuntimeProgress: state != .planningPreview
                && state != .notDispatched)
    }
}

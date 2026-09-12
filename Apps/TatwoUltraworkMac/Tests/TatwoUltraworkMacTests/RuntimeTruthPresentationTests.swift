import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class RuntimeTruthPresentationTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    func testPlannedLoopsAgentsAndCyclesRemainPlanningPreview() {
        let parentID = UUID()
        var session = TatwoLoopsSupervisorRule.make(
            parentSupervisorModelID: "gpt-5.6-sol",
            parentKind: .thread,
            parentID: parentID,
            projectID: parentID,
            title: "Truth preview",
            plg: TatwoLoopsPLG(plan: "plan", loops: "loops", goal: "goal"),
            reviewerModelID: nil)
        session.subAgents = [
            TatwoLoopsSubAgent(
                label: "builder",
                modelID: "gpt-5.6-sol",
                status: .planned)
        ]
        session.cycles = [
            TatwoLoopsCycleProgress(
                round: 1,
                totalRounds: 3,
                producedCount: 0,
                verifiedCount: 0,
                blockedCount: 0)
        ]

        let truth = TatwoLoopsDispatchPlanner.runtimeTruth(session: session)

        XCTAssertEqual(truth.state, .notDispatched)
        XCTAssertEqual(truth.headline, "規劃預覽")
        XCTAssertTrue(truth.dispatchLabel.contains("尚未派發"))
        XCTAssertEqual(truth.runtimeReceiptLabel, "無 runtime receipt")
        XCTAssertFalse(truth.countsAsRuntimeProgress)
    }

    func testLoopsSelectionKeepsAtMostOneExpandedAndRetapCollapsesIt() {
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

    func testPLGPhaseCannotClaimExecutionWithoutDispatchRecords() {
        let run = makeRun(phase: .executingLoops)

        let truth = TatwoPLGGovernance.executionTruth(
            run: run,
            dispatchRecords: [])

        XCTAssertEqual(truth.state, .notDispatched)
        XCTAssertEqual(truth.headline, "PLG 規劃預覽")
        XCTAssertTrue(truth.dispatchLabel.contains("尚未派發"))
        XCTAssertEqual(truth.runtimeReceiptLabel, "無 runtime receipt")
        XCTAssertFalse(truth.countsAsRuntimeProgress)
    }

    func testPLGOnlyShowsRunningAndReceiptAfterRuntimeLedgerEvidence() {
        let run = makeRun(phase: .executingLoops)
        let running = record(status: .running)
        let runningTruth = TatwoPLGGovernance.executionTruth(
            run: run,
            dispatchRecords: [running])

        XCTAssertEqual(runningTruth.state, .running)
        XCTAssertEqual(runningTruth.runningDispatchCount, 1)
        XCTAssertEqual(runningTruth.runtimeReceiptCount, 0)
        XCTAssertTrue(runningTruth.runtimeReceiptLabel.contains("無 runtime receipt"))

        let completed = record(status: .completed, receiptID: "runtime-receipt-1")
        let completedTruth = TatwoPLGGovernance.executionTruth(
            run: run,
            dispatchRecords: [completed])

        XCTAssertEqual(completedTruth.state, .receiptGated)
        XCTAssertEqual(completedTruth.terminalDispatchCount, 1)
        XCTAssertEqual(completedTruth.verifiedDispatchCount, 0)
        XCTAssertEqual(completedTruth.runtimeReceiptCount, 1)
        XCTAssertTrue(completedTruth.runtimeReceiptLabel.contains("1 份 runtime receipt"))
    }

    func testQueuedAndVerifiedRemainDistinctInPLGProjection() {
        let run = makeRun(phase: .executingLoops)
        let queuedTruth = TatwoPLGGovernance.executionTruth(
            run: run,
            dispatchRecords: [record(status: .queued)])
        let verifiedTruth = TatwoPLGGovernance.executionTruth(
            run: run,
            dispatchRecords: [record(status: .verified, receiptID: "receipt-verified")])

        XCTAssertEqual(queuedTruth.state, .dispatched)
        XCTAssertEqual(queuedTruth.terminalDispatchCount, 0)
        XCTAssertEqual(queuedTruth.verifiedDispatchCount, 0)

        XCTAssertEqual(verifiedTruth.state, .receiptGated)
        XCTAssertEqual(verifiedTruth.terminalDispatchCount, 0)
        XCTAssertEqual(verifiedTruth.verifiedDispatchCount, 1)
    }

    func testChatLoopsAndPLGViewsConsumeRuntimeTruthAPIs() throws {
        let loops = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LoopsSessionRail.swift")
        let plg = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift")
        let chat = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift")
        let scenario = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPage.swift")
        let scenarioLeaf = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPageLeafViews.swift")
        let ultraLeaf = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageLeafViews.swift")

        XCTAssertTrue(loops.contains("TatwoLoopsDispatchPlanner.runtimeTruth(session: session)"))
        XCTAssertTrue(loops.contains("規劃預覽 · 尚未派發 · 無 runtime receipt"))
        XCTAssertFalse(loops.contains(#"case .planned: return "待執行""#))
        XCTAssertFalse(loops.contains(#"case .planned: return "規劃""#))

        XCTAssertTrue(plg.contains("TatwoPLGGovernance.executionTruth("))
        XCTAssertTrue(plg.contains("var dispatchRecords: [TatwoDispatchRecord] = []"))
        XCTAssertTrue(plg.contains("executionTruth.runtimeReceiptCount == 0"))
        XCTAssertFalse(plg.contains(#"case .planned: return "[佇列中]""#))

        XCTAssertTrue(
            chat.contains(
                "model.selectedDispatchRuntimeProjection.canonicalRecords"))
        let workflows = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift")
        XCTAssertTrue(
            workflows.contains(
                "let projection = selectedDispatchRuntimeProjection"))
        XCTAssertTrue(
            workflows.contains(
                "return projection.canonicalRecords"))
        let planningRows = try XCTUnwrap(
            loops.slice(
                from: "private var sessionRows",
                through: "private var archivedSessionsSection"))
        XCTAssertFalse(planningRows.contains("plgDispatchRecords"))
        XCTAssertTrue(scenario.contains("contract.showLoopsProjection.presentationLabel"))
        XCTAssertTrue(scenario.contains("contract.showLoopsProjection.dispatchSummary"))
        XCTAssertTrue(scenario.contains("contract.showLoopsProjection.runtimeReceiptSummary"))
        XCTAssertTrue(scenarioLeaf.contains("receipt requirements"))
        XCTAssertTrue(ultraLeaf.contains("Text(snapshot.plainSummary)"))
    }

    func testLoopsPlanningNotesUseHumanOnlyPublicAPI() throws {
        let chat = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift")
        let workflows = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift")

        XCTAssertTrue(chat.contains("model.appendHumanLoopNote(id, text: text)"))
        XCTAssertFalse(chat.contains("model.appendLoopMessage("))
        XCTAssertTrue(workflows.contains("func appendHumanLoopNote(_ id: UUID, text: String)"))
        XCTAssertTrue(
            workflows.contains(
                #"appendLoopMessage(id, role: "human", authorModelID: nil, text: text)"#))
        XCTAssertTrue(workflows.contains("private func appendLoopMessage("))
    }

    func testLegacySucceededGoalIsPresentedAsAwaitingJudgment() throws {
        let chatModel = try ChatSourceFamily.read("ChatPageModel.swift")
        let loopMap = try readSource(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/WorkOSDeepLoopMap.swift")

        XCTAssertTrue(chatModel.contains(#"return "執行完成，等待驗收""#))
        XCTAssertFalse(chatModel.contains(#"return "執行已成功""#))
        XCTAssertTrue(loopMap.contains(#"case .succeeded: return "Loops 完成，待驗收""#))
        XCTAssertTrue(loopMap.contains("case .succeeded: return .orange"))
        XCTAssertFalse(loopMap.contains(#"case .succeeded: return "執行成功""#))
    }

    private func makeRun(phase: TatwoPLGPhase) -> TatwoPLGRun {
        TatwoPLGRun(
            goalID: "goal-runtime-truth",
            contractID: "contract-runtime-truth",
            revision: 0,
            phase: phase,
            leadBindings: [],
            subBindings: [],
            planSummary: "Plan only",
            adversarialConclusion: nil,
            humanAuth: nil,
            branchGoals: [],
            mainlineGoalMet: nil)
    }

    private func record(
        status: TatwoDispatchStatus,
        receiptID: String? = nil
    ) -> TatwoDispatchRecord {
        TatwoDispatchRecord(
            id: "dispatch-\(status.rawValue)",
            contractID: "contract-runtime-truth",
            bindingID: "binding-runtime-truth",
            sourceSlotID: "slot-runtime-truth",
            identity: .sub,
            modelID: "gpt-5.6-sol",
            subtask: "Runtime truth test",
            status: status,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
            receiptID: receiptID)
    }

    private func readSource(_ relativePath: String) throws -> String {
        try ChatSourceFamily.read(url: repoRoot.appendingPathComponent(relativePath))
    }
}

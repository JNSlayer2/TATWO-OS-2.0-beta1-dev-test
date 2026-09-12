import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

/// CLI 左列 session 樹：投影、chat→CLI 綁定、詳情讀取、裝置欄位 fallback。
final class CLISessionTreeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        id: String,
        binding: String,
        status: TatwoDispatchStatus,
        contractID: String = "contract-chat",
        goalID: String? = "goal-from-chat",
        updatedAgo: TimeInterval = 60,
        startedAgo: TimeInterval = 300,
        identity: IdentityKind = .sub,
        modelID: String = "gpt-5.6-sol",
        subtask: String = "chat 派工子任務",
        outputRef: String? = nil,
        receiptID: String? = nil,
        errorMessage: String? = nil
    ) -> TatwoDispatchRecord {
        TatwoDispatchRecord(
            id: id,
            contractID: contractID,
            goalID: goalID,
            bindingID: binding,
            sourceSlotID: "slot-\(binding)",
            identity: identity,
            modelID: modelID,
            subtask: subtask,
            status: status,
            startedAt: now.addingTimeInterval(-startedAgo),
            updatedAt: now.addingTimeInterval(-updatedAgo),
            receiptID: receiptID,
            outputRef: outputRef,
            errorMessage: errorMessage)
    }

    private func run(
        contractID: String = "contract-chat",
        records: [TatwoDispatchRecord],
        sealID: String? = nil
    ) -> TatwoStoredDispatchRun {
        TatwoStoredDispatchRun(
            contractID: contractID,
            records: records,
            updatedAt: now,
            sealID: sealID)
    }

    // MARK: - Tree projection

    func testProjectionIncludesActiveAndRecentCompletedWithinOneHour() {
        let rows = CLILoopsTreePolicy.project(
            from: [run(records: [
                record(id: "r-run", binding: "b1", status: .running, updatedAgo: 30),
                record(id: "r-queue", binding: "b2", status: .queued, updatedAgo: 40),
                record(id: "r-done", binding: "b3", status: .completed, updatedAgo: 600),
                record(
                    id: "r-old",
                    binding: "b4",
                    status: .completed,
                    updatedAgo: CLILoopsTreePolicy.recentCompletedWindow + 120)
            ])],
            now: now)

        XCTAssertEqual(Set(rows.map(\.id)), ["r-run", "r-queue", "r-done"])
        XCTAssertEqual(rows.first?.id, "r-run", "running 應排在最前")
        XCTAssertTrue(rows.contains(where: { $0.id == "r-done" && !$0.isActive }))
        XCTAssertFalse(rows.contains(where: { $0.id == "r-old" }))
    }

    func testDeviceLabelFallsBackToLocalWhenFieldsMissing() {
        let rows = CLILoopsTreePolicy.project(
            from: [run(records: [record(id: "r1", binding: "b1", status: .running)])],
            now: now)
        XCTAssertEqual(rows.first?.deviceLabel, "本機")
        XCTAssertFalse(rows.first?.isRemoteDevice ?? true)
    }

    func testDeviceLabelUsesTargetDeviceWhenPresent() {
        let rows = CLILoopsTreePolicy.project(
            from: [run(records: [record(id: "r1", binding: "b1", status: .running)])],
            now: now,
            deviceFieldsByRecordID: [
                "r1": CLILoopDeviceFields(
                    originDeviceID: "mini",
                    targetDeviceID: "macbook")
            ])
        XCTAssertEqual(rows.first?.deviceLabel, "macbook")
        XCTAssertTrue(rows.first?.isRemoteDevice ?? false)
        XCTAssertNotEqual(rows.first?.deviceLabel, "本機")
    }

    func testSourceThreadLabelFromGoalOrContract() {
        let rows = CLILoopsTreePolicy.project(
            from: [run(records: [
                record(id: "r1", binding: "b1", status: .running, goalID: "goal-1")
            ])],
            now: now,
            sourceThreadByGoalID: ["goal-1": "閉環驗證 thread"])
        XCTAssertEqual(rows.first?.sourceThreadLabel, "閉環驗證 thread")
    }

    // MARK: - chat → CLI closed loop

    /// chat／Ultrawork 寫入同一 registry 的派工，零 CLI 設定即出現在段二。
    func testChatDispatchedRecordsProjectIntoLoopsSectionWithoutCLIConfig() {
        // 模擬 chat 派工：帶 goalID + contractID（Work OS chat 路徑會寫）。
        let chatRun = run(
            contractID: "contract-xl-coding-chat",
            records: [
                record(
                    id: "dispatch-chat-1",
                    binding: "sub-0",
                    status: .running,
                    contractID: "contract-xl-coding-chat",
                    goalID: "goal-xl-coding-chat",
                    identity: .sub,
                    modelID: "grok-4.6",
                    subtask: "WS2 CLI 左列閉環")
            ])

        let rows = CLILoopsTreePolicy.projectChatDispatchedLoops(
            from: [chatRun],
            now: now,
            sourceThreadByGoalID: ["goal-xl-coding-chat": "XL coding thread"])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "dispatch-chat-1")
        XCTAssertEqual(rows[0].contractID, "contract-xl-coding-chat")
        XCTAssertEqual(rows[0].goalID, "goal-xl-coding-chat")
        XCTAssertEqual(rows[0].identity, "sub")
        XCTAssertEqual(rows[0].sourceThreadLabel, "XL coding thread")
        XCTAssertTrue(rows[0].isActive)
    }

    func testVerifierIdentityAlsoProjectsFromChatDispatch() {
        let rows = CLILoopsTreePolicy.projectChatDispatchedLoops(
            from: [run(records: [
                record(
                    id: "v1",
                    binding: "verifier-0",
                    status: .queued,
                    identity: .verifier,
                    modelID: "claude-fable-5",
                    subtask: "副審")
            ])],
            now: now)
        XCTAssertEqual(rows.first?.identity, "verifier")
        XCTAssertEqual(rows.first?.status, .queued)
    }

    // MARK: - Detail binding / read

    func testDetailBindsTimelineAndOutputFromDispatchRecords() {
        let records = [
            record(
                id: "r-old",
                binding: "b1",
                status: .queued,
                updatedAgo: 200,
                startedAgo: 200),
            record(
                id: "r-new",
                binding: "b1",
                status: .running,
                updatedAgo: 20,
                startedAgo: 200,
                outputRef: "sha256:abc",
                receiptID: "receipt-9")
        ]
        let detail = CLILoopDetailReader.detail(
            forRecordID: "r-new",
            runs: [run(records: records)],
            now: now)

        let snapshot = try? XCTUnwrap(detail)
        XCTAssertEqual(snapshot?.row.id, "r-new")
        XCTAssertEqual(snapshot?.timeline.count, 2)
        XCTAssertEqual(snapshot?.timeline.map(\.status), [.queued, .running])
        XCTAssertTrue(snapshot?.outputText.contains("outputRef: sha256:abc") == true)
        XCTAssertTrue(snapshot?.outputText.contains("receiptID: receipt-9") == true)
        XCTAssertEqual(snapshot?.canStop, true)
    }

    func testDetailCanStopFalseWhenCompleted() {
        let detail = CLILoopDetailReader.detail(
            forRecordID: "done",
            runs: [run(records: [
                record(id: "done", binding: "b1", status: .completed, updatedAgo: 30)
            ])],
            now: now)
        XCTAssertEqual(detail?.canStop, false)
        XCTAssertEqual(detail?.row.status, .completed)
    }

    func testDetailReturnsNilForUnknownRecord() {
        let detail = CLILoopDetailReader.detail(
            forRecordID: "missing",
            runs: [run(records: [record(id: "r1", binding: "b1", status: .running)])],
            now: now)
        XCTAssertNil(detail)
    }

    // MARK: - Raw JSON device fields

    func testDeviceFieldReaderExtractsOptionalDeviceIDs() throws {
        let json = """
        {
          "schema": "TatwoStoredDispatchRunV1",
          "contractID": "c1",
          "records": [
            {
              "id": "rec-remote",
              "originDeviceID": "device-mini",
              "targetDeviceID": "device-book"
            },
            {
              "id": "rec-local",
              "modelID": "x"
            }
          ]
        }
        """.data(using: .utf8)!

        let fields = CLIDispatchDeviceFieldReader.fieldsByRecordID(in: json)
        XCTAssertEqual(fields["rec-remote"]?.originDeviceID, "device-mini")
        XCTAssertEqual(fields["rec-remote"]?.targetDeviceID, "device-book")
        XCTAssertNil(fields["rec-local"])
    }

    // MARK: - Fixture → tree rows (export path)

    func testFixtureKindOneIncludesRemoteTargetDeviceRow() throws {
        let snapshot = try XCTUnwrap(TatwoLoopsActivityFixture.snapshot(kind: "1", now: now))
        let rows = CLILoopsTreePolicy.rows(fromActivityRows: snapshot.rows)
        let remote = rows.first(where: { $0.id == "fixture-remote" })
        XCTAssertNotNil(remote)
        XCTAssertEqual(
            remote?.targetDeviceID,
            TatwoLoopsActivityFixture.fixtureRemoteTargetDeviceID)
        XCTAssertTrue(remote?.isRemoteDevice == true)
        XCTAssertNotEqual(remote?.deviceLabel, "本機")
    }

    func testActivityRowsWithoutDeviceStillLocal() {
        let row = TatwoLoopsActivityRow(
            id: "x",
            contractID: "c",
            bindingID: "b",
            identity: "sub",
            modelID: "m",
            subtask: "",
            queued: false,
            startedAt: now,
            updatedAt: now)
        let tree = CLILoopsTreePolicy.rows(fromActivityRows: [row])
        XCTAssertEqual(tree.first?.deviceLabel, "本機")
    }
}

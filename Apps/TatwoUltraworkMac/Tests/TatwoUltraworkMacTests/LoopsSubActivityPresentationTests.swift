import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class LoopsSubActivityPresentationTests: XCTestCase {
    func testMonitorAdapterDoesNotLeakRowsFromAnotherContract() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            row(id: "current", contractID: "contract-a", now: now),
            row(id: "foreign", contractID: "contract-b", now: now)
        ]

        let presentation = TatwoLoopsActivityPolicy.subActivityPresentation(
            rows: rows,
            currentContractID: "contract-a",
            phase: .running,
            now: now)

        guard case .rows(let presented) = presentation else {
            return XCTFail("Expected current-contract row")
        }
        XCTAssertEqual(presented.map(\.id), ["current"])
    }

    private func row(id: String, contractID: String, now: Date) -> TatwoLoopsActivityRow {
        TatwoLoopsActivityRow(
            id: id,
            contractID: contractID,
            bindingID: "binding-\(id)",
            identity: "builder",
            modelID: "gpt-5.6-sol",
            subtask: "實作資料聚合",
            queued: false,
            startedAt: now.addingTimeInterval(-90),
            updatedAt: now.addingTimeInterval(-5))
    }
}

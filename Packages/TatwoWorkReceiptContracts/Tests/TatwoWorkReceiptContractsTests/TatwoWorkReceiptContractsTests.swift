import Foundation
import XCTest
@testable import TatwoWorkReceiptContracts

final class TatwoWorkReceiptContractsTests: XCTestCase {
    func testReceiptMetadataContainsStableSyncIdentifiers() throws {
        let metadata = TatwoWorkReceiptMetadataV1(
            receiptID: "receipt-001",
            schema: "TatwoDeploymentReceiptV1",
            version: 1,
            correlationID: "goal-001",
            createdAt: Date(timeIntervalSince1970: 123),
            sourceDeviceID: "device-macbook"
        )

        XCTAssertEqual(metadata.receiptID, "receipt-001")
        XCTAssertEqual(metadata.schema, "TatwoDeploymentReceiptV1")
        XCTAssertEqual(metadata.version, 1)
        XCTAssertEqual(metadata.correlationID, "goal-001")
        XCTAssertEqual(metadata.sourceDeviceID, "device-macbook")

        let encoded = try JSONEncoder().encode(metadata)
        XCTAssertEqual(try JSONDecoder().decode(TatwoWorkReceiptMetadataV1.self, from: encoded), metadata)
    }

    func testGoalRunProjectionContainsValuesOnly() throws {
        let projection = TatwoGoalRunProjectionV1(
            goalRunID: "goal-001",
            objective: "Bootstrap modules safely",
            status: .running,
            phase: "apply",
            progressCompleted: 2,
            progressTotal: 5,
            issueIDs: ["issue-1", "issue-2"],
            updatedAt: Date(timeIntervalSince1970: 200),
            receiptMetadata: makeMetadata()
        )

        XCTAssertEqual(projection.goalRunID, "goal-001")
        XCTAssertEqual(projection.status, .running)
        XCTAssertEqual(projection.progressCompleted, 2)
        XCTAssertEqual(projection.progressTotal, 5)
        XCTAssertEqual(projection.issueIDs, ["issue-1", "issue-2"])

        let encoded = try JSONEncoder().encode(projection)
        XCTAssertEqual(try JSONDecoder().decode(TatwoGoalRunProjectionV1.self, from: encoded), projection)
    }

    func testIssueQueueProjectionPreservesDeterministicOrderingAndNoStoreBehavior() throws {
        let low = TatwoIssueProjectionV1(
            issueID: "issue-2",
            goalRunID: "goal-001",
            title: "Document boundary",
            status: .queued,
            priority: .normal,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let high = TatwoIssueProjectionV1(
            issueID: "issue-1",
            goalRunID: "goal-001",
            title: "Verify rollback isolation",
            status: .blocked,
            priority: .critical,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let queue = TatwoIssueQueueProjectionV1(
            queueID: "bootstrap",
            issues: [high, low],
            projectedAt: Date(timeIntervalSince1970: 40),
            receiptMetadata: makeMetadata()
        )

        XCTAssertEqual(queue.issues.map(\.issueID), ["issue-1", "issue-2"])
        XCTAssertEqual(queue.issues.map(\.priority), [.critical, .normal])

        let encoded = try JSONEncoder().encode(queue)
        XCTAssertEqual(try JSONDecoder().decode(TatwoIssueQueueProjectionV1.self, from: encoded), queue)
    }

    private func makeMetadata() -> TatwoWorkReceiptMetadataV1 {
        TatwoWorkReceiptMetadataV1(
            receiptID: "receipt-001",
            schema: "TatwoProjectionReceiptV1",
            version: 1,
            correlationID: "goal-001",
            createdAt: Date(timeIntervalSince1970: 1),
            sourceDeviceID: "device-macbook"
        )
    }
}

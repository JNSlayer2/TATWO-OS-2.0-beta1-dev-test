import XCTest

@testable import TatwoUltraworkCore

final class CleanupInventoryTests: XCTestCase {
  func testWriterCreatesMarkdownAndJSONReviewBundleWithoutDeletingCandidates() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-cleanup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let inventory = PostValidationCleanupInventoryFactory.make(
      runID: "run-1",
      validatedGoalID: "goal-1",
      validatedContractID: "contract-1",
      candidateFiles: [
        PostValidationCleanupCandidateV1(
          id: "tmp-1",
          relativePath: ".tatwo-ultrawork/tmp/render-cache",
          origin: "UI smoke test cache",
          removalReason: "驗收後不再需要的中間輸出",
          producedByReceiptID: "visual-evidence",
          safeToRemove: true,
          deletionRisk: "低；已保留 summary 與 final receipt")
      ],
      mustKeep: ["summary.json", "總評分報告.md"],
      summary: "驗收通過後盤點可刪檔案，供未來清理前確認來源與合理性。")

    let result = try PostValidationCleanupInventoryWriter.write(inventory, root: root)

    XCTAssertFalse(result.dryRun)
    XCTAssertEqual(result.candidateCount, 1)
    XCTAssertEqual(result.mustKeepCount, 2)
    XCTAssertTrue(result.deletionRequiresHumanApproval)

    let markdownURL = root.appendingPathComponent(inventory.markdownPath, isDirectory: false)
    let jsonURL = root.appendingPathComponent("\(inventory.trashBundlePath)/cleanup-inventory.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))

    let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
    XCTAssertTrue(markdown.contains("# TATWO 驗收後待刪檔案盤點"))
    XCTAssertTrue(markdown.contains("UI smoke test cache"))
    XCTAssertTrue(markdown.contains("真正移除前必須由人類確認"))
  }

  func testWriterDryRunDoesNotCreateReviewBundle() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-cleanup-dry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let inventory = PostValidationCleanupInventoryFactory.noCandidateInventory(
      runID: "run-2",
      validatedGoalID: "goal-2",
      validatedContractID: "contract-2")

    let result = try PostValidationCleanupInventoryWriter.write(inventory, root: root, dryRun: true)

    XCTAssertTrue(result.dryRun)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(inventory.trashBundlePath, isDirectory: true).path))
  }
}

import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoIssueListStoreTests: XCTestCase {
  func testLegacyIssueJSONDecodesWithoutImageAssets() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-issue-legacy-\(UUID().uuidString)", isDirectory: true)
    let store = TatwoIssueListStore(rootURL: root)
    let file = root.appendingPathComponent("issue-list.json")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    [{
      "id": "legacy",
      "title": "舊 issue",
      "body": "沒有圖片欄位",
      "sourceType": "chat",
      "sourceReference": "Chat",
      "status": "queued",
      "createdAt": "2026-07-22T00:00:00Z",
      "updatedAt": "2026-07-22T00:00:00Z"
    }]
    """.data(using: .utf8)!.write(to: file)

    let entry = try XCTUnwrap(store.load().first)
    XCTAssertEqual(entry.imageAssetPaths, [])
  }

  func testImageAssetPathsPersistAsSafeRelativeNames() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-issue-images-\(UUID().uuidString)", isDirectory: true)
    let store = TatwoIssueListStore(rootURL: root)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let entry = store.capture(
      title: "圖片 issue",
      body: "測試",
      sourceType: .chat,
      sourceReference: "Chat")

    store.updateImageAssetPaths(
      id: entry.id,
      imageAssetPaths: ["abc.png", "/private/should-not-persist.png", "../escape.png", "abc.png"])

    XCTAssertEqual(store.load().first?.imageAssetPaths, ["abc.png"])
  }
}

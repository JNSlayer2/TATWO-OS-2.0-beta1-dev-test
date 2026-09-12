import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class DeviceSyncPeerInventoryTests: XCTestCase {
  func testIngestKeepsPeerReportedValuesAndDoesNotSeedMissingFields() throws {
    let root = temporaryDirectory("ingest-real")
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = root.appendingPathComponent("inventory", isDirectory: true)
    let devices = root.appendingPathComponent("devices", isDirectory: true)
    let storeURL = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)

    let reportedAt = Date(timeIntervalSince1970: 1_786_665_600)
    try writeJSON(
      """
      {
        "schema": "TatwoDevicePeerInventoryV1",
        "deviceID": "macbook-air",
        "hardwareModel": "Mac15,12",
        "chipName": "Apple M3",
        "ramTotalBytes": 17179869184,
        "cpuPercent": 27.4,
        "memoryPressureLevel": "warn",
        "activeLoopCount": 2,
        "timestamp": "2026-08-14T02:00:00Z"
      }
      """,
      to: channel.appendingPathComponent("macbook-air.json"))
    try writeJSON(
      """
      {
        "schema": "TatwoDevicePeerInventoryV1",
        "deviceID": "sparse-mini",
        "timestamp": "2026-08-14T02:00:00Z"
      }
      """,
      to: channel.appendingPathComponent("sparse-mini.json"))
    try writeJSON(
      """
      {
        "name": "MacBook Air",
        "role": "secondary",
        "deviceId": "macbook-air",
        "deviceID": "macbook-air",
        "enrolledAt": "2026-07-28T00:00:00Z"
      }
      """,
      to: devices.appendingPathComponent("MacBook.json"))

    let store = TatwoDevicePeerInventoryStore(storeURL: storeURL, now: { reportedAt })
    let records = try store.ingest(
      channelInventoryDirectory: channel,
      registeredDevicesDirectory: devices)

    XCTAssertEqual(records.map(\.deviceID), ["macbook-air", "sparse-mini"])
    let book = try XCTUnwrap(records.first { $0.deviceID == "macbook-air" })
    XCTAssertEqual(book.registeredName, "MacBook Air")
    XCTAssertEqual(book.hardwareModel, "Mac15,12")
    XCTAssertEqual(book.chipName, "Apple M3")
    XCTAssertEqual(book.ramTotalBytes, 17_179_869_184)
    XCTAssertEqual(book.cpuPercent, 27.4)
    XCTAssertEqual(book.memoryPressureLevel, .warn)
    XCTAssertEqual(book.activeLoopCount, 2)
    XCTAssertEqual(book.timestamp, ISO8601DateFormatter().date(from: "2026-08-14T02:00:00Z"))

    let sparse = try XCTUnwrap(records.first { $0.deviceID == "sparse-mini" })
    XCTAssertNil(sparse.hardwareModel)
    XCTAssertNil(sparse.chipName)
    XCTAssertNil(sparse.ramTotalBytes)
    XCTAssertNil(sparse.cpuPercent)
    XCTAssertNil(sparse.memoryPressureLevel)
    XCTAssertNil(sparse.activeLoopCount)
    XCTAssertNil(sparse.registeredName)

    XCTAssertEqual(
      store.record(deviceID: nil, displayName: "MacBook Air")?.deviceID,
      "macbook-air")
    XCTAssertEqual(
      TatwoDevicePeerInventoryStore.match(
        records: records,
        deviceID: "macbook-air",
        displayName: "ignored")?.chipName,
      "Apple M3")
  }

  func testIngestRejectsFilenameMismatchAndDoesNotReplaceNewerRecord() throws {
    let root = temporaryDirectory("ingest-reject")
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = root.appendingPathComponent("inventory", isDirectory: true)
    let storeURL = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)

    try writeJSON(
      """
      {
        "schema": "TatwoDevicePeerInventoryV1",
        "deviceID": "peer-a",
        "hardwareModel": "Mac16,1",
        "timestamp": "2026-08-14T03:00:00Z"
      }
      """,
      to: channel.appendingPathComponent("peer-a.json"))

    let now = Date(timeIntervalSince1970: 1_786_669_200)
    let store = TatwoDevicePeerInventoryStore(storeURL: storeURL, now: { now })
    XCTAssertEqual(try store.ingest(channelInventoryDirectory: channel).count, 1)

    try writeJSON(
      """
      {
        "schema": "TatwoDevicePeerInventoryV1",
        "deviceID": "peer-a",
        "hardwareModel": "SHOULD-NOT-WIN",
        "timestamp": "2026-08-14T01:00:00Z"
      }
      """,
      to: channel.appendingPathComponent("peer-a.json"))
    try writeJSON(
      """
      {
        "schema": "TatwoDevicePeerInventoryV1",
        "deviceID": "other-device",
        "hardwareModel": "Mac14,2",
        "timestamp": "2026-08-14T03:00:00Z"
      }
      """,
      to: channel.appendingPathComponent("wrong-name.json"))
    try writeJSON(
      """
      {
        "schema": "NotInventory",
        "deviceID": "bad-schema",
        "timestamp": "2026-08-14T03:00:00Z"
      }
      """,
      to: channel.appendingPathComponent("bad-schema.json"))

    let records = try store.ingest(channelInventoryDirectory: channel)
    XCTAssertEqual(records.map(\.deviceID), ["peer-a"])
    XCTAssertEqual(records[0].hardwareModel, "Mac16,1")

    XCTAssertThrowsError(
      try TatwoDevicePeerInventoryStore.decodeReport(
        from: Data(
          """
          {
            "schema": "TatwoDevicePeerInventoryV1",
            "deviceID": "other-device",
            "timestamp": "2026-08-14T03:00:00Z"
          }
          """.utf8),
        fileName: "wrong-name.json")
    ) { error in
      XCTAssertEqual(
        error as? TatwoDevicePeerInventoryIngestError,
        .filenameDeviceIDMismatch(file: "wrong-name.json", deviceID: "other-device"))
    }
  }

  func testStalenessKeepsTimestampAndMarksAfterThirtyMinutes() {
    let now = Date(timeIntervalSince1970: 1_786_680_000)
    let fresh = now.addingTimeInterval(-29 * 60)
    let exact = now.addingTimeInterval(-30 * 60)
    let stale = now.addingTimeInterval(-31 * 60)

    XCTAssertFalse(TatwoDevicePeerInventoryStalenessV1.isStale(timestamp: fresh, now: now))
    XCTAssertFalse(TatwoDevicePeerInventoryStalenessV1.isStale(timestamp: exact, now: now))
    XCTAssertTrue(TatwoDevicePeerInventoryStalenessV1.isStale(timestamp: stale, now: now))
    XCTAssertEqual(
      TatwoDevicePeerInventoryStalenessV1.updatedLabel(timestamp: fresh, now: now),
      "更新於 29 分前")
    XCTAssertEqual(
      TatwoDevicePeerInventoryStalenessV1.updatedLabel(timestamp: stale, now: now),
      "更新於 31 分前")
    XCTAssertEqual(
      TatwoDevicePeerInventoryStalenessV1.minutesAgo(timestamp: now, now: now),
      0)
  }

  private func writeJSON(_ json: String, to url: URL) throws {
    try json.data(using: .utf8)?.write(to: url)
  }

  private func temporaryDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-peer-inventory-\(label)-\(UUID().uuidString)")
  }
}

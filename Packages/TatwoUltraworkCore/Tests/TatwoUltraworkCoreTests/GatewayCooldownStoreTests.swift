import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class GatewayCooldownStoreTests: XCTestCase {
  func testPersistentCooldownSurvivesStoreRecreationAndRequiresProbeAfterMargin() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("cooldowns", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = TatwoGatewayCooldownRecordV1(
      provider: "haiku-4-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2026-07-15T00:00:00Z",
      resetAtUTC: "2026-07-15T00:01:00Z",
      sourceEventID: "event-1",
      contractID: "contract-1")
    try JSONEncoder().encode(record).write(
      to: directory.appendingPathComponent("haiku-4-5-model.json"),
      options: .atomic)

    let blocked = TatwoGatewayCooldownStore(directoryURL: root).projection(
      modelID: "haiku-4-5",
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T00:01:30Z")))
    XCTAssertEqual(blocked.state, .blocked)
    XCTAssertFalse(blocked.dispatchAllowed)

    let relaunched = TatwoGatewayCooldownStore(directoryURL: root).projection(
      modelID: "haiku-4-5",
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T00:02:01Z")))
    XCTAssertEqual(relaunched.state, .requiresProbe)
    XCTAssertFalse(relaunched.dispatchAllowed)
  }

  func testClockRollbackFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("cooldowns", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = TatwoGatewayCooldownRecordV1(
      provider: "fable-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2026-07-15T08:00:00Z",
      resetAtUTC: "2026-07-15T08:20:00Z",
      sourceEventID: "event-rollback",
      contractID: "contract-1")
    try JSONEncoder().encode(record).write(
      to: directory.appendingPathComponent("fable-5-model.json"),
      options: .atomic)

    let projection = TatwoGatewayCooldownStore(directoryURL: root).projection(
      modelID: "fable5",
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T07:59:59Z")))
    XCTAssertEqual(projection.code, "cooldown_blocked_clock_rollback")
    XCTAssertFalse(projection.dispatchAllowed)
  }

  func testPartialClearMarkersFailClosed() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("cooldowns", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("fable-5-model.json")
    let now = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-15T08:22:00Z"))

    let clearedWithoutProbe = TatwoGatewayCooldownRecordV1(
      provider: "fable-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2026-07-15T08:00:00Z",
      resetAtUTC: "2026-07-15T08:20:00Z",
      sourceEventID: "event-partial-cleared",
      contractID: "contract-1",
      clearedAtUTC: "2026-07-15T08:22:00Z")
    try JSONEncoder().encode(clearedWithoutProbe).write(to: file, options: .atomic)
    XCTAssertFalse(
      TatwoGatewayCooldownStore(directoryURL: root)
        .projection(modelID: "fable5", now: now)
        .dispatchAllowed)

    let probeWithoutClear = TatwoGatewayCooldownRecordV1(
      provider: "fable-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2026-07-15T08:00:00Z",
      resetAtUTC: "2026-07-15T08:20:00Z",
      sourceEventID: "event-partial-probe",
      contractID: "contract-1",
      probeAttemptedAtUTC: "2026-07-15T08:21:30Z",
      probeSucceededAtUTC: "2026-07-15T08:21:31Z")
    try JSONEncoder().encode(probeWithoutClear).write(to: file, options: .atomic)
    XCTAssertFalse(
      TatwoGatewayCooldownStore(directoryURL: root)
        .projection(modelID: "fable5", now: now)
        .dispatchAllowed)
  }
}

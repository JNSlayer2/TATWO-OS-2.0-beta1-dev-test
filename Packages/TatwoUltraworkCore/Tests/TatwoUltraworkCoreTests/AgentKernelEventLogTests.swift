import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class AgentKernelEventLogTests: XCTestCase {
  func testLeaseIsCreateOnlyAndCanBeReacquiredAfterRelease() throws {
    let root = temporaryDirectory()
    let store = AgentKernelEventLog(root: root)

    try store.acquireLease(runID: "run")
    XCTAssertThrowsError(try store.acquireLease(runID: "run")) { error in
      XCTAssertEqual(error as? AgentKernelStoreError, .leaseHeld)
    }

    try store.releaseLease(runID: "run")
    XCTAssertNoThrow(try store.acquireLease(runID: "run"))
  }

  func testAppendRequiresMonotonicSequences() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    try store.append(event(sequence: 1))

    XCTAssertThrowsError(try store.append(event(sequence: 3))) { error in
      XCTAssertEqual(error as? AgentKernelStoreError, .sequenceMismatch)
    }
  }

  func testReadRejectsSchemaMismatch() throws {
    let root = temporaryDirectory()
    let store = AgentKernelEventLog(root: root)
    try store.append(event(sequence: 1))
    let logURL = root.appendingPathComponent("run/events.jsonl")
    var line = try String(contentsOf: logURL, encoding: .utf8)
    line = line.replacingOccurrences(
      of: "\"schemaVersion\":1",
      with: "\"schemaVersion\":999")
    try Data(line.utf8).write(to: logURL)

    XCTAssertThrowsError(try store.read(runID: "run")) { error in
      XCTAssertEqual(error as? AgentKernelStoreError, .schemaMismatch)
    }
  }

  func testReadRejectsAnyCorruptJSONLLine() throws {
    let root = temporaryDirectory()
    let store = AgentKernelEventLog(root: root)
    try store.append(event(sequence: 1))
    let logURL = root.appendingPathComponent("run/events.jsonl")
    let handle = try FileHandle(forWritingTo: logURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{broken}\n".utf8))
    try handle.close()

    XCTAssertThrowsError(try store.read(runID: "run")) { error in
      XCTAssertEqual(error as? AgentKernelStoreError, .corrupt)
    }
  }

  func testFullScanRejectsMiddleTruncationEvenWhenLastLineIsValid() throws {
    let root = temporaryDirectory()
    let store = AgentKernelEventLog(root: root)
    try store.append(event(sequence: 1))
    try store.append(event(sequence: 2))
    try store.append(event(sequence: 3))
    try mutateLine(root: root, index: 1) { String($0.prefix(12)) }
    XCTAssertThrowsError(try store.lastEvent(runID: "run")) {
      XCTAssertEqual($0 as? AgentKernelStoreError, .corrupt)
    }
  }

  func testFullScanRejectsValidJSONWithWrongEventHash() throws {
    let root = temporaryDirectory()
    let store = AgentKernelEventLog(root: root)
    try store.append(event(sequence: 1))
    try store.append(event(sequence: 2))
    try mutateLine(root: root, index: 0) {
      $0.replacingOccurrences(of: "\"eventHash\":\"", with: "\"eventHash\":\"bad")
    }
    XCTAssertThrowsError(try store.read(runID: "run")) {
      XCTAssertEqual($0 as? AgentKernelStoreError, .corrupt)
    }
  }

  func testFullScanRejectsDuplicateAndSkippedSequence() throws {
    for replacement in [1, 4] {
      let root = temporaryDirectory()
      let store = AgentKernelEventLog(root: root)
      try store.append(event(sequence: 1))
      try store.append(event(sequence: 2))
      try store.append(event(sequence: 3))
      try mutateLine(root: root, index: 1) {
        $0.replacingOccurrences(
          of: "\"eventSequence\":2",
          with: "\"eventSequence\":\(replacement)")
          .replacingOccurrences(
            of: "\"runSequence\":2",
            with: "\"runSequence\":\(replacement)")
      }
      XCTAssertThrowsError(try store.read(runID: "run")) {
        XCTAssertEqual($0 as? AgentKernelStoreError, .corrupt)
      }
    }
  }

  func testRecoverablePrefixStopsAtLastValidCheckpoint() throws {
    let root = temporaryDirectory()
    let store = AgentKernelEventLog(root: root)
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    try run.commitCheckpoint(
      .init(completedStep: 7, messages: ["safe"], toolResults: []))
    try run.stop(reason: .humanDisabled)
    try mutateLine(root: root, index: 2) {
      $0.replacingOccurrences(of: "\"eventHash\":\"", with: "\"eventHash\":\"bad")
    }

    let recovery = try run.recover()
    XCTAssertEqual(recovery.checkpoint?.completedStep, 7)
    XCTAssertEqual(recovery.nextStep, 8)
  }

  func testSnapshotMustMatchLastCommittedEvent() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    try store.append(event(sequence: 1))
    let inconsistent = AgentKernelSnapshot(
      runID: "run",
      lastEventSequence: 0,
      checkpoint: nil)

    XCTAssertThrowsError(try store.saveSnapshot(inconsistent)) { error in
      XCTAssertEqual(error as? AgentKernelStoreError, .sequenceMismatch)
    }
  }

  func testThousandAppendsKeepJSONLInodeAndGrowIncrementally() throws {
    let root = temporaryDirectory()
    let store = AgentKernelEventLog(root: root)
    try store.append(event(sequence: 1))
    let logURL = root.appendingPathComponent("run/events.jsonl")
    let initial = try fileIdentityAndSize(logURL)

    for sequence in 2...1_000 {
      try store.append(event(sequence: sequence))
    }

    let final = try fileIdentityAndSize(logURL)
    XCTAssertEqual(final.identity, initial.identity)
    XCTAssertGreaterThan(final.size, initial.size)
    XCTAssertEqual(try store.read(runID: "run").count, 1_000)
  }

  private func event(sequence: Int) -> AgentKernelEvent {
    AgentKernelEvent(
      runID: "run",
      runSequence: sequence,
      eventSequence: sequence,
      occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
      payload: sequence == 1 ? .runStarted : .stopped(reason: "test"))
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private func mutateLine(
    root: URL,
    index: Int,
    transform: (String) -> String
  ) throws {
    let url = root.appendingPathComponent("run/events.jsonl")
    var lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    lines[index] = transform(lines[index])
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
  }

  private func fileIdentityAndSize(_ url: URL) throws -> (identity: UInt64, size: UInt64) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (
      attributes[.systemFileNumber] as! UInt64,
      attributes[.size] as! UInt64)
  }
}

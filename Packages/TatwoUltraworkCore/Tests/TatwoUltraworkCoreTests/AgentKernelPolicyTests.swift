import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class AgentKernelPolicyTests: XCTestCase {
  func testAllStopConditionsAreFirstClass() {
    let policy = AgentKernelStopPolicy(
      ttl: 60,
      tokenBudget: 100,
      consecutiveFailureLimit: 3)
    XCTAssertEqual(
      policy.reason(startedAt: .distantPast, now: Date(), usage: 0, failures: 0, disabled: false),
      .ttlExpired)
    XCTAssertEqual(
      policy.reason(startedAt: Date(), now: Date(), usage: 101, failures: 0, disabled: false),
      .tokenBudgetExceeded)
    XCTAssertEqual(
      policy.reason(startedAt: Date(), now: Date(), usage: 0, failures: 3, disabled: false),
      .consecutiveFailureLimit)
    XCTAssertEqual(
      policy.reason(startedAt: Date(), now: Date(), usage: 0, failures: 0, disabled: true),
      .humanDisabled)
  }

  func testApprovalPersistsAndResolvesAcrossRecovery() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    try run.requestApproval(id: "approval")
    XCTAssertEqual(try run.recover().pendingApprovalID, "approval")

    try run.resolveApproval(id: "approval")
    XCTAssertNil(try run.recover().pendingApprovalID)
  }

  func testThreeTransportsNormalizeReliableUsage() {
    let reports: [AgentTransportUsageReport] = [
      .codex(inputTokens: 2, outputTokens: 3),
      .claude(inputTokens: 4, outputTokens: 5),
      .grok(inputTokens: 6, outputTokens: 7),
    ]
    XCTAssertEqual(
      reports.map(\.canonical),
      [
        .init(source: .reported, input: 2, output: 3),
        .init(source: .reported, input: 4, output: 5),
        .init(source: .reported, input: 6, output: 7),
      ])
  }

  func testUsageSourcesAreNotConflatedAndUnavailableHasReason() throws {
    XCTAssertEqual(
      AgentTransportUsageReport.codex(
        source: .measured, inputTokens: 8, outputTokens: 9).canonical,
      .init(source: .measured, input: 8, output: 9))
    XCTAssertEqual(
      AgentTransportUsageReport.claude(
        source: .estimated, inputTokens: 10, outputTokens: 11).canonical,
      .init(source: .estimated, input: 10, output: 11))
    XCTAssertEqual(
      AgentTransportUsageReport.grok(
        source: .unavailable, inputTokens: nil, outputTokens: nil,
        unavailableReason: "stream omitted usage").canonical,
      .init(
        source: .unavailable, input: nil, output: nil,
        unavailableReason: "stream omitted usage"))
  }

  func testMissingReliableUsageFailsClosed() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()

    XCTAssertThrowsError(
      try run.recordUsage(.codex(inputTokens: nil, outputTokens: nil))) { error in
        XCTAssertEqual(error as? AgentKernelRunError, .usageUnavailable)
      }
    XCTAssertTrue(
      try store.read(runID: "run").contains {
        $0.payload == .usageReported(
          .init(
            source: .unavailable, input: nil, output: nil,
            unavailableReason: "missing token counts"))
      })
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }
}

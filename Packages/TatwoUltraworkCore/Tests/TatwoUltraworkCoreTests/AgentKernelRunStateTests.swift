import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class AgentKernelRunStateTests: XCTestCase {
  func testRecoveryStartsAfterLastCommittedCheckpoint() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    try run.commitCheckpoint(
      AgentKernelCheckpoint(
        completedStep: 4,
        messages: ["m"],
        toolResults: []))

    let recovery = try run.recover()

    XCTAssertEqual(recovery.nextStep, 5)
    XCTAssertEqual(recovery.checkpoint?.completedStep, 4)
  }

  func testCompletedInvocationIsDeduplicatedAfterRecovery() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    try run.beginInvocation(id: "call-1", sideEffecting: true)
    try run.completeInvocation(id: "call-1")

    XCTAssertEqual(
      try run.recover().disposition(for: "call-1"),
      .alreadyCompleted)
  }

  func testAlreadyCompletedSkipsOnlyWhenArgsResultAndArtifactsMatch() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    XCTAssertEqual(
      try run.beginVerifiedInvocation(
        id: "call-1",
        sideEffecting: true,
        argsHash: "args-a",
        expectedResultDigest: "result-a",
        expectedArtifactDigests: ["artifact-a"]),
      .execute)
    try run.completeInvocation(
      id: "call-1",
      resultDigest: "result-a",
      artifactDigests: ["artifact-a"])

    XCTAssertEqual(
      try run.beginVerifiedInvocation(
        id: "call-1",
        sideEffecting: true,
        argsHash: "args-a",
        expectedResultDigest: "result-a",
        expectedArtifactDigests: ["artifact-a"]),
      .skipVerified)

    for mismatch in [
      ("args-b", "result-a", ["artifact-a"]),
      ("args-a", "result-b", ["artifact-a"]),
      ("args-a", "result-a", ["artifact-b"]),
    ] {
      XCTAssertThrowsError(
        try run.beginVerifiedInvocation(
          id: "call-1",
          sideEffecting: true,
          argsHash: mismatch.0,
          expectedResultDigest: mismatch.1,
          expectedArtifactDigests: mismatch.2)
      ) { error in
        XCTAssertEqual(
          error as? AgentKernelRunError,
          .completedInvocationEvidenceMismatch("call-1"))
      }
    }
  }

  func testUncommittedSideEffectingInvocationBecomesOutcomeUnknown() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    try run.beginInvocation(id: "call-1", sideEffecting: true)

    let recovery = try run.recover()

    XCTAssertEqual(recovery.disposition(for: "call-1"), .outcomeUnknown)
    XCTAssertTrue(
      try store.read(runID: "run").contains {
        $0.payload == .invocationOutcomeUnknown(id: "call-1")
      })
  }

  func testUncommittedReadOnlyInvocationCanRetry() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    try run.beginInvocation(id: "call-1", sideEffecting: false)

    XCTAssertEqual(
      try run.recover().disposition(for: "call-1"),
      .retryAllowed)
  }

  func testOutcomeUnknownDecisionTreeFailsClosed() throws {
    XCTAssertEqual(
      AgentOutcomeUnknownResolver.resolve(
        originalInvocationID: "call-1",
        retrySafe: false,
        reconciliation: .provenNotExecuted,
        newInvocationID: { "call-2" }),
      .executeNew(invocationID: "call-2"))

    XCTAssertEqual(
      AgentOutcomeUnknownResolver.resolve(
        originalInvocationID: "call-1",
        retrySafe: true,
        reconciliation: .stillUnknown,
        newInvocationID: { "unused" }),
      .retrySame(invocationID: "call-1"))

    XCTAssertEqual(
      AgentOutcomeUnknownResolver.resolve(
        originalInvocationID: "call-1",
        retrySafe: false,
        reconciliation: .provenExecuted,
        newInvocationID: { "unused" }),
      .acceptReconciledExecution(invocationID: "call-1"))

    XCTAssertEqual(
      AgentOutcomeUnknownResolver.resolve(
        originalInvocationID: "call-1",
        retrySafe: false,
        reconciliation: .stillUnknown,
        newInvocationID: { "unused" }),
      .pendingHumanGate(invocationID: "call-1"))
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

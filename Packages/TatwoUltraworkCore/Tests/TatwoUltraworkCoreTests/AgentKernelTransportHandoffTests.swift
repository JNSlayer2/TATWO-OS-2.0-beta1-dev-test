import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class AgentKernelTransportHandoffTests: XCTestCase {
  func testTransportCannotChangeMidTurn() throws {
    let run = AgentKernelRun(
      runID: "run",
      store: AgentKernelEventLog(root: temporaryDirectory()))
    try run.start()
    try run.attestTurn(
      requested: "codex",
      actual: "codex",
      effort: "high")

    XCTAssertThrowsError(try run.changeTransport(to: "claude")) { error in
      XCTAssertEqual(error as? AgentKernelRunError, .notAtTurnBoundary)
    }
  }

  func testBoundaryHandoffCarriesMessagesAndToolResults() throws {
    let store = AgentKernelEventLog(root: temporaryDirectory())
    let run = AgentKernelRun(runID: "run", store: store)
    try run.start()
    try run.attestTurn(
      requested: "codex",
      actual: "codex",
      effort: "high")
    let checkpoint = AgentKernelCheckpoint(
      completedStep: 1,
      messages: ["user", "assistant"],
      toolResults: [
        TatwoNativeToolResultRecord(
          callID: "tool-1",
          output: "ok"),
      ])
    try run.commitCheckpoint(checkpoint)

    let carrier = try run.changeTransport(to: "claude")

    XCTAssertEqual(carrier, checkpoint)
    XCTAssertEqual(
      try store.read(runID: "run").last?.payload,
      .transportChanged(from: "codex", to: "claude"))
  }

  func testEveryCompletedTurnRequiresAttestation() throws {
    let run = AgentKernelRun(
      runID: "run",
      store: AgentKernelEventLog(root: temporaryDirectory()))
    try run.start()
    try run.commitCheckpoint(
      AgentKernelCheckpoint(
        completedStep: 1,
        messages: [],
        toolResults: []))

    XCTAssertThrowsError(try run.changeTransport(to: "grok")) { error in
      XCTAssertEqual(error as? AgentKernelRunError, .missingTurnAttestation)
    }
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

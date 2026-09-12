import Foundation
import Testing
@testable import TatwoUltraworkCore

@Suite("SessionProtocolV1 semantic contract")
struct SessionProtocolV1SemanticTests {
  @Test("canonical envelope kinds and Tatwo methods are stable")
  func canonicalVocabulary() {
    #expect(SessionProtocolV1.EnvelopeKind.allCases == [
      .request, .notification, .serverRequest, .response,
    ])
    #expect(SessionProtocolV1.Method.threadStarted.rawValue == "tatwo.thread.started")
    #expect(SessionProtocolV1.Method.turnStarted.rawValue == "tatwo.turn.started")
    #expect(SessionProtocolV1.Method.itemDelta.rawValue == "tatwo.item.delta")
    #expect(SessionProtocolV1.Method.approvalRequested.rawValue == "tatwo.approval.requested")
  }

  @Test("payloads use semantic thread turn item approval and run-state records")
  func semanticPayloads() {
    let thread = SessionProtocolV1.Thread(id: "thread-1")
    let turn = SessionProtocolV1.Turn(id: "turn-1", threadID: thread.id)
    let item = SessionProtocolV1.Item(
      id: "item-1",
      turnID: turn.id,
      kind: .message,
      delta: "hello")
    let approval = SessionProtocolV1.Approval(
      id: "approval-1",
      runID: "run-1",
      status: .requested)
    let runState = SessionProtocolV1.RunState(
      runID: "run-1",
      phase: .awaitingApproval)

    #expect(thread.id == "thread-1")
    #expect(turn.threadID == thread.id)
    #expect(item.kind == .message)
    #expect(approval.status == .requested)
    #expect(runState.phase == .awaitingApproval)
  }

  @Test("vendor names are confined to adapter metadata")
  func adapterMetadataBoundary() {
    let metadata = SessionProtocolV1.AdapterMetadata(
      source: "app-server",
      vendor: "Codex",
      vendorMethod: "turn/started")
    #expect(metadata.vendor == "Codex")
    #expect(SessionProtocolV1.Method.allCases.allSatisfy { $0.rawValue.hasPrefix("tatwo.") })
  }
}

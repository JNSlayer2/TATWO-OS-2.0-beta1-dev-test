import Testing
@testable import TatwoUltraworkCore

@Suite("SessionProtocolV1 shared consumers")
struct SessionProtocolV1ConsumerTests {
  @Test("kernel driver and chat projection consume the same three fixtures")
  func sharedFixture() throws {
    let fixtures = [
      try SessionProtocolV1.Envelope.notification(
        method: .turnStarted,
        payload: SessionProtocolV1.Turn(id: "turn-1", threadID: "thread-1")),
      try SessionProtocolV1.Envelope.notification(
        method: .itemDelta,
        payload: SessionProtocolV1.Item(
          id: "item-1", turnID: "turn-1", kind: .message, delta: "hello")),
      try SessionProtocolV1.Envelope.notification(
        method: .approvalRequested,
        payload: SessionProtocolV1.Approval(
          id: "approval-1", runID: "run-1", status: .requested)),
    ]

    var driver = SessionProtocolV1.KernelDriverConsumer()
    var projection = SessionProtocolV1.ChatProjectionReducer()
    for fixture in fixtures {
      try driver.consume(fixture)
      try projection.consume(fixture)
    }

    #expect(driver.activeTurnID == "turn-1")
    #expect(driver.itemDeltas["item-1"] == "hello")
    #expect(driver.kernelEvents == [.approvalRequested(id: "approval-1")])
    #expect(projection.activeTurnID == driver.activeTurnID)
    #expect(projection.visibleItems == ["item-1": "hello"])
    #expect(projection.pendingApprovalIDs == ["approval-1"])
  }
}

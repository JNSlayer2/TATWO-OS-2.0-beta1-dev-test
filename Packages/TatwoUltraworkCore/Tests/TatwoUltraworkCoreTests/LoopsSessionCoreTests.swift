import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class LoopsSessionCoreTests: XCTestCase {
  func testMakeForcesSupervisorInheritanceFromParent() {
    let session = makeSession(
      parentSupervisorModelID: "gpt-5.6-sol",
      parentKind: .mainChat)

    XCTAssertEqual(session.supervisorModelID, "gpt-5.6-sol")
    XCTAssertEqual(session.status, .planned)
    XCTAssertTrue(session.subAgents.isEmpty)
    XCTAssertTrue(session.cycles.isEmpty)
    XCTAssertTrue(session.messages.isEmpty)
    XCTAssertFalse(session.createdISO.isEmpty)
  }

  func testSupervisorRemainsConsistentAcrossMainChatThreadAndLoopLayers() {
    let projectID = UUID()
    let mainChatID = UUID()
    let threadID = UUID()
    let supervisorModelID = "fable5"

    let loopFromMainChat = TatwoLoopsSupervisorRule.make(
      parentSupervisorModelID: supervisorModelID,
      parentKind: .mainChat,
      parentID: mainChatID,
      projectID: projectID,
      title: "Main chat loop",
      plg: samplePLG,
      reviewerModelID: "gpt-5.6-sol")
    let loopFromThread = TatwoLoopsSupervisorRule.make(
      parentSupervisorModelID: loopFromMainChat.supervisorModelID,
      parentKind: .thread,
      parentID: threadID,
      projectID: projectID,
      title: "Thread loop",
      plg: samplePLG,
      reviewerModelID: nil)

    XCTAssertEqual(loopFromMainChat.supervisorModelID, supervisorModelID)
    XCTAssertEqual(loopFromThread.supervisorModelID, supervisorModelID)
    XCTAssertEqual(loopFromMainChat.projectID, loopFromThread.projectID)
    XCTAssertEqual(loopFromMainChat.parentKind, .mainChat)
    XCTAssertEqual(loopFromThread.parentKind, .thread)
  }

  func testDiscussionLoopRetainsParentSessionIdentityAndSupervisorInheritance() {
    let discussionID = UUID()
    let session = TatwoLoopsSupervisorRule.make(
      parentSupervisorModelID: "fable5",
      parentKind: .discussion,
      parentID: discussionID,
      projectID: UUID(),
      title: "Discussion loop",
      plg: samplePLG,
      reviewerModelID: "gpt-5.6-sol")

    XCTAssertEqual(session.parentKind, .discussion)
    XCTAssertEqual(session.parentID, discussionID)
    XCTAssertEqual(session.supervisorModelID, "fable5")
    XCTAssertTrue(
      TatwoLoopsSupervisorRule.validateInheritance(
        child: session,
        parentSupervisorModelID: "fable5"))
  }

  func testValidateInheritanceRejectsDecodedSupervisorMismatch() throws {
    let session = makeSession(parentSupervisorModelID: "fable5")
    let mismatched = try replacingSupervisor(
      in: session,
      with: "gpt-5.6-sol")

    XCTAssertTrue(
      TatwoLoopsSupervisorRule.validateInheritance(
        child: session,
        parentSupervisorModelID: "fable5"))
    XCTAssertFalse(
      TatwoLoopsSupervisorRule.validateInheritance(
        child: mismatched,
        parentSupervisorModelID: "fable5"))
  }

  func testReviewerMayBeAbsent() {
    let session = makeSession(
      parentSupervisorModelID: "fable5",
      reviewerModelID: nil)

    XCTAssertNil(session.reviewerModelID)
  }

  func testSubAgentsAndCycleProgressRetainVisualizationFields() {
    var session = makeSession(parentSupervisorModelID: "fable5")
    let subAgent = TatwoLoopsSubAgent(
      id: UUID(),
      label: "Verifier A",
      modelID: "gpt-5.6-sol",
      status: .running)
    let progress = TatwoLoopsCycleProgress(
      round: 2,
      totalRounds: 5,
      producedCount: 8,
      verifiedCount: 6,
      blockedCount: 1)

    session.subAgents = [subAgent]
    session.cycles = [progress]

    XCTAssertEqual(session.subAgents[0].label, "Verifier A")
    XCTAssertEqual(session.subAgents[0].modelID, "gpt-5.6-sol")
    XCTAssertEqual(session.subAgents[0].status, .running)
    XCTAssertEqual(session.cycles[0].round, 2)
    XCTAssertEqual(session.cycles[0].totalRounds, 5)
    XCTAssertEqual(session.cycles[0].producedCount, 8)
    XCTAssertEqual(session.cycles[0].verifiedCount, 6)
    XCTAssertEqual(session.cycles[0].blockedCount, 1)
  }

  func testSessionCodableRoundTripPreservesCompleteData() throws {
    var session = makeSession(
      parentSupervisorModelID: "fable5",
      parentKind: .thread,
      reviewerModelID: "gpt-5.6-sol")
    session.status = .blocked
    session.subAgents = [
      TatwoLoopsSubAgent(
        id: UUID(),
        label: "Sub 1",
        modelID: "grok-4",
        status: .passed)
    ]
    session.cycles = [
      TatwoLoopsCycleProgress(
        round: 1,
        totalRounds: 3,
        producedCount: 4,
        verifiedCount: 4,
        blockedCount: 0)
    ]
    session.messages = [
      TatwoLoopsMessage(
        id: UUID(),
        role: "supervisor",
        authorModelID: "fable5",
        text: "Start round one.",
        createdISO: "2026-07-13T10:00:00Z"),
      TatwoLoopsMessage(
        id: UUID(),
        role: "human",
        authorModelID: nil,
        text: "Continue.",
        createdISO: "2026-07-13T10:01:00Z"),
    ]

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(TatwoLoopsSession.self, from: data)

    XCTAssertEqual(decoded, session)
  }

  func testStatusSupportsPlannedRunningBlockedRollbackAndPassedTransitions() {
    var session = makeSession(parentSupervisorModelID: "fable5")

    XCTAssertEqual(session.status, .planned)
    session.status = .running
    XCTAssertEqual(session.status, .running)
    session.status = .blocked
    XCTAssertEqual(session.status, .blocked)
    session.status = .rollbackRequired
    XCTAssertEqual(session.status, .rollbackRequired)
    session.status = .passed
    XCTAssertEqual(session.status, .passed)
  }

  func testAllCoreValueTypesExposeRequiredProtocolConformances() {
    let plg = samplePLG
    let parentKind = TatwoLoopsParentKind.mainChat
    let status = TatwoLoopsStatus.running
    let subAgent = TatwoLoopsSubAgent(
      id: UUID(),
      label: "Sub",
      modelID: "gpt-5.6-sol",
      status: status)
    let progress = TatwoLoopsCycleProgress(
      round: 1,
      totalRounds: 1,
      producedCount: 1,
      verifiedCount: 1,
      blockedCount: 0)
    let message = TatwoLoopsMessage(
      id: UUID(),
      role: "reviewer",
      authorModelID: "gpt-5.6-sol",
      text: "Pass.",
      createdISO: "2026-07-13T10:00:00Z")
    let session = makeSession(parentSupervisorModelID: "fable5")

    assertCoreConformances(plg)
    assertCoreConformances(parentKind)
    assertCoreConformances(status)
    assertCoreConformances(subAgent)
    assertCoreConformances(progress)
    assertCoreConformances(message)
    assertCoreConformances(session)
  }

  private var samplePLG: TatwoLoopsPLG {
    TatwoLoopsPLG(
      plan: "Define the data contract.",
      loops: "Run bounded review cycles.",
      goal: "Produce verified progress receipts.")
  }

  private func makeSession(
    parentSupervisorModelID: String,
    parentKind: TatwoLoopsParentKind = .mainChat,
    reviewerModelID: String? = "gpt-5.6-sol"
  ) -> TatwoLoopsSession {
    TatwoLoopsSupervisorRule.make(
      parentSupervisorModelID: parentSupervisorModelID,
      parentKind: parentKind,
      parentID: UUID(),
      projectID: UUID(),
      title: "Loops session",
      plg: samplePLG,
      reviewerModelID: reviewerModelID)
  }

  private func replacingSupervisor(
    in session: TatwoLoopsSession,
    with supervisorModelID: String
  ) throws -> TatwoLoopsSession {
    let data = try JSONEncoder().encode(session)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["supervisorModelID"] = supervisorModelID
    let modifiedData = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(TatwoLoopsSession.self, from: modifiedData)
  }

  private func assertCoreConformances<T>(_ value: T)
  where T: Codable & Sendable & Equatable & Identifiable {
    _ = value.id
  }
}

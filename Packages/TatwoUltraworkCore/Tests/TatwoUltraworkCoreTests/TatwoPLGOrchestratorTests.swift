import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoPLGOrchestratorTests: XCTestCase {
  private let now = "2026-07-13T10:00:00Z"

  func testSingleLeadPlanningRequiresLeadReviewBeforeHumanAuthorization() throws {
    let run = makeRun()
    let eventID = UUID()

    let transition = try TatwoPLGOrchestrator.advanceFromPlanning(
      run,
      expectedRevision: 0,
      eventID: eventID)

    XCTAssertEqual(transition.run.phase, .leadAdversarial)
    XCTAssertEqual(transition.run.revision, 1)
    XCTAssertEqual(transition.event.eventID, eventID)
    XCTAssertEqual(transition.event.kind, .planningAdvanced)
    XCTAssertEqual(transition.event.atRevision, 1)
  }

  func testMultiLeadPlanningUsesAdversarialPhase() throws {
    let transition = try TatwoPLGOrchestrator.advanceFromPlanning(
      makeRun(leadCount: 2),
      expectedRevision: 0,
      eventID: UUID())

    XCTAssertEqual(transition.run.phase, .leadAdversarial)
  }

  func testEveryTransitionRejectsStaleRevisionBeforeMutation() {
    assertThrows(.staleRevision(expected: 7, actual: 0)) {
      try TatwoPLGOrchestrator.advanceFromPlanning(
        makeRun(),
        expectedRevision: 7,
        eventID: UUID())
    }
  }

  func testPlanningFailsClosedWithoutLeadIdentityBinding() {
    let run = makeRun(
      leadBindings: [binding(id: "not-lead", identity: .sub)])

    assertThrows(.leadBindingRequired) {
      try TatwoPLGOrchestrator.advanceFromPlanning(
        run,
        expectedRevision: 0,
        eventID: UUID())
    }
  }

  func testPlanningFailsClosedWhenBranchBindingIsMissing() {
    let run = makeRun(subBindings: [])

    assertThrows(.bindingNotFound("sub-0")) {
      try TatwoPLGOrchestrator.advanceFromPlanning(
        run,
        expectedRevision: 0,
        eventID: UUID())
    }
  }

  func testPlanningFailsClosedWhenBranchBindingIsNotSubIdentity() {
    let run = makeRun(
      subBindings: [binding(id: "sub-0", identity: .verifier)])

    assertThrows(
      .bindingIdentityMismatch(
        bindingID: "sub-0",
        expected: .sub,
        actual: .verifier)
    ) {
      try TatwoPLGOrchestrator.advanceFromPlanning(
        run,
        expectedRevision: 0,
        eventID: UUID())
    }
  }

  func testBranchStoresBindingIDAndResolverProvidesRuntimeModelBinding() throws {
    let run = makeRun()

    let resolved = try TatwoPLGOrchestrator.resolveSubBinding(
      for: run.branchGoals[0],
      in: run)

    XCTAssertEqual(run.branchGoals[0].subBindingID, "sub-0")
    XCTAssertEqual(resolved.id, "sub-0")
    XCTAssertEqual(resolved.modelID, "bound-sub-0")
  }

  func testAdversarialConclusionProducesProjectableEvent() throws {
    let planning = try TatwoPLGOrchestrator.advanceFromPlanning(
      makeRun(leadCount: 2),
      expectedRevision: 0,
      eventID: UUID())

    let transition = try TatwoPLGOrchestrator.setAdversarialConclusion(
      "All verifier findings accepted.",
      in: planning.run,
      expectedRevision: 1,
      eventID: UUID())

    XCTAssertEqual(transition.run.adversarialConclusion, "All verifier findings accepted.")
    XCTAssertEqual(transition.run.phase, .awaitingHumanAuth)
    XCTAssertEqual(transition.run.revision, 2)
  }

  func testAdversarialConclusionRejectsEmptyModelOutput() throws {
    let planning = try TatwoPLGOrchestrator.advanceFromPlanning(
      makeRun(),
      expectedRevision: 0,
      eventID: UUID())

    assertThrows(.adversarialConclusionRequired) {
      try TatwoPLGOrchestrator.setAdversarialConclusion(
        " \n ",
        in: planning.run,
        expectedRevision: 1,
        eventID: UUID())
    }
  }

  func testAuthorizeRejectsReceiptForDifferentContract() throws {
    let awaiting = try awaitingRun()
    let receipt = validReceipt(contractID: "other-contract")

    assertThrows(.authInvalid) {
      try TatwoPLGOrchestrator.authorize(
        receipt: receipt,
        nowISO: now,
        in: awaiting,
        expectedRevision: awaiting.revision,
        eventID: UUID())
    }
  }

  func testAuthorizeRejectsExpiredReceipt() throws {
    let awaiting = try awaitingRun()
    let receipt = validReceipt(expiresISO: now)

    assertThrows(.authInvalid) {
      try TatwoPLGOrchestrator.authorize(
        receipt: receipt,
        nowISO: now,
        in: awaiting,
        expectedRevision: awaiting.revision,
        eventID: UUID())
    }
  }

  func testAuthorizeRejectsReceiptIssuedInFuture() throws {
    let awaiting = try awaitingRun()
    let receipt = validReceipt(issuedISO: "2026-07-13T10:00:01Z")

    assertThrows(.authInvalid) {
      try TatwoPLGOrchestrator.authorize(
        receipt: receipt,
        nowISO: now,
        in: awaiting,
        expectedRevision: awaiting.revision,
        eventID: UUID())
    }
  }

  func testValidReceiptIsRequiredToEnterExecutingLoops() throws {
    let awaiting = try awaitingRun()
    let receipt = validReceipt()

    let transition = try TatwoPLGOrchestrator.authorize(
      receipt: receipt,
      nowISO: now,
      in: awaiting,
      expectedRevision: awaiting.revision,
      eventID: UUID())

    XCTAssertEqual(transition.run.phase, .executingLoops)
    XCTAssertEqual(transition.run.humanAuth, receipt)
  }

  func testExpiredStoredReceiptFailsClosedDuringBranchReport() {
    let run = makeRun(
      phase: .executingLoops,
      humanAuth: validReceipt(expiresISO: now))

    assertThrows(.authInvalid) {
      try TatwoPLGOrchestrator.reportBranch(
        id: run.branchGoals[0].id,
        status: .passed,
        reason: nil,
        nowISO: now,
        in: run,
        expectedRevision: 0,
        eventID: UUID())
    }
  }

  func testAddBranchGoalsAppendsThroughEventAndIncrementsRevision() throws {
    var run = executingRun()
    run.subBindings.append(binding(id: "sub-1", identity: .sub))
    let branch = branchGoal(index: 1)
    let eventID = UUID()

    let transition = try TatwoPLGOrchestrator.addBranchGoals(
      [branch],
      in: run,
      expectedRevision: run.revision,
      eventID: eventID)

    XCTAssertEqual(transition.run.branchGoals, run.branchGoals + [branch])
    XCTAssertEqual(transition.run.revision, run.revision + 1)
    XCTAssertEqual(transition.event.eventID, eventID)
    XCTAssertEqual(transition.event.kind, .branchesAdded)
    XCTAssertEqual(transition.event.payload, .branchesAdded([branch]))
    XCTAssertEqual(
      try TatwoPLGOrchestrator.project(transition.event, onto: run),
      transition.run)
  }

  func testAddBranchGoalsRejectsBranchWithoutDomainLoopBinding() {
    let run = executingRun(branchCount: 0)
    var runWithSub = run
    runWithSub.subBindings = [binding(id: "sub-0", identity: .sub)]

    XCTAssertThrowsError(
      try TatwoPLGOrchestrator.addBranchGoals(
        [branchGoal(index: 0, includeDomainBinding: false)],
        in: runWithSub,
        expectedRevision: runWithSub.revision,
        eventID: UUID()))
  }

  func testAddBranchGoalsRejectsNonExecutingLoopsPhase() {
    let run = makeRun()

    assertThrows(.invalidPhase(expected: .executingLoops, actual: .planning)) {
      try TatwoPLGOrchestrator.addBranchGoals(
        [branchGoal(index: 0)],
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testAddBranchGoalsRejectsMissingSubBindingID() {
    let run = executingRun()

    assertThrows(.bindingNotFound("sub-missing")) {
      try TatwoPLGOrchestrator.addBranchGoals(
        [branchGoal(index: 1, subBindingID: "sub-missing")],
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testAddBranchGoalsRejectsEmptyBranches() {
    let run = executingRun()

    assertThrows(.branchGoalsRequired) {
      try TatwoPLGOrchestrator.addBranchGoals(
        [],
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testAddBranchGoalsRequiresExpectedRevision() {
    let run = executingRun()

    assertThrows(.staleRevision(expected: 7, actual: run.revision)) {
      try TatwoPLGOrchestrator.addBranchGoals(
        [branchGoal(index: 0)],
        in: run,
        expectedRevision: 7,
        eventID: UUID())
    }
  }

  func testOutOfOrderBranchReportsAreAccepted() throws {
    var run = executingRun(branchCount: 3)

    run = try report(run.branchGoals[2].id, .passed, in: run).run
    run = try report(run.branchGoals[0].id, .passed, in: run).run
    run = try report(run.branchGoals[1].id, .blocked, reason: "needs fix", in: run).run

    XCTAssertEqual(run.branchGoals.map(\.status), [.passed, .blocked, .passed])
    XCTAssertEqual(run.branchGoals[1].reason, "needs fix")
  }

  func testRepeatedReportForSameBranchOverwritesIdempotently() throws {
    var run = executingRun()
    let branchID = run.branchGoals[0].id

    run = try report(branchID, .blocked, reason: "first", in: run).run
    run = try report(branchID, .passed, reason: "fixed", in: run).run

    XCTAssertEqual(run.branchGoals.count, 1)
    XCTAssertEqual(run.branchGoals[0].status, .passed)
    XCTAssertEqual(run.branchGoals[0].reason, "fixed")
    XCTAssertEqual(run.branchGoals[0].attempt, 0)
  }

  func testBlockedBranchCannotAdvanceToReporting() throws {
    var run = executingRun()
    run = try report(run.branchGoals[0].id, .blocked, reason: "blocked", in: run).run

    assertThrows(.branchGoalsNotPassed) {
      try TatwoPLGOrchestrator.advanceToReporting(
        run,
        nowISO: now,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testBlockedBranchCanReplanAndIncrementAttempt() throws {
    var run = executingRun()
    let branchID = run.branchGoals[0].id
    run = try report(branchID, .blocked, reason: "first failure", in: run).run

    let transition = try TatwoPLGOrchestrator.replanBranch(
      id: branchID,
      reason: "retry with verifier guidance",
      deadlineISO: "2026-07-14T10:00:00Z",
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())

    let branch = transition.run.branchGoals[0]
    XCTAssertEqual(branch.status, .planned)
    XCTAssertEqual(branch.reason, "retry with verifier guidance")
    XCTAssertEqual(branch.attempt, 1)
    XCTAssertEqual(branch.deadlineISO, "2026-07-14T10:00:00Z")
    XCTAssertFalse(branch.reportedToMainline)
  }

  func testAttemptAtMaximumAutomaticallyEscalatesInsteadOfReplanning() throws {
    var run = executingRun()
    let branchID = run.branchGoals[0].id
    run.branchGoals[0].status = .blocked
    run.branchGoals[0].attempt = run.branchGoals[0].maxAttempts
    XCTAssertEqual(run.branchGoals[0].maxAttempts, 3)

    let transition = try TatwoPLGOrchestrator.replanBranch(
      id: branchID,
      reason: "retry budget exhausted",
      deadlineISO: nil,
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())

    XCTAssertEqual(transition.event.kind, .branchEscalated)
    XCTAssertEqual(transition.run.branchGoals[0].status, .blocked)
    XCTAssertTrue(transition.run.branchGoals[0].escalated)
    XCTAssertEqual(transition.run.phase, .rollbackRequired)
  }

  func testExpiredBranchDeadlineAutomaticallyEscalates() throws {
    var run = executingRun()
    let branchID = run.branchGoals[0].id
    run.branchGoals[0].status = .blocked
    run.branchGoals[0].deadlineISO = "2026-07-13T09:59:59Z"

    let transition = try TatwoPLGOrchestrator.replanBranch(
      id: branchID,
      reason: "deadline expired",
      deadlineISO: "2026-07-14T10:00:00Z",
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())

    XCTAssertEqual(transition.event.kind, .branchEscalated)
    XCTAssertEqual(transition.run.branchGoals[0].status, .blocked)
    XCTAssertTrue(transition.run.branchGoals[0].escalated)
  }

  func testEscalatedBranchCannotReplan() throws {
    var run = executingRun()
    let branchID = run.branchGoals[0].id
    run.branchGoals[0].status = .blocked
    run.branchGoals[0].escalated = true

    assertThrows(.branchAlreadyEscalated(branchID)) {
      try TatwoPLGOrchestrator.replanBranch(
        id: branchID,
        reason: "must wait for human gate",
        deadlineISO: nil,
        nowISO: now,
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testReplanRejectsNonBlockedBranch() {
    let run = executingRun()

    assertThrows(.branchNotBlocked(run.branchGoals[0].id)) {
      try TatwoPLGOrchestrator.replanBranch(
        id: run.branchGoals[0].id,
        reason: "not allowed",
        deadlineISO: nil,
        nowISO: now,
        in: run,
        expectedRevision: 0,
        eventID: UUID())
    }
  }

  func testBlockedBranchCanEscalateToHumanGate() throws {
    var run = executingRun()
    let branchID = run.branchGoals[0].id
    run = try report(branchID, .blocked, reason: "cannot recover", in: run).run

    let transition = try TatwoPLGOrchestrator.escalateBranch(
      id: branchID,
      reason: "human decision required",
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())

    XCTAssertEqual(transition.run.phase, .rollbackRequired)
    XCTAssertEqual(transition.run.branchGoals[0].status, .blocked)
    XCTAssertTrue(transition.run.branchGoals[0].escalated)
  }

  func testAllPassedBranchesCanAdvanceThroughReporting() throws {
    var run = executingRun(branchCount: 2)
    for branchID in run.branchGoals.map(\.id) {
      run = try report(branchID, .passed, in: run).run
    }

    let reporting = try TatwoPLGOrchestrator.advanceToReporting(
      run,
      nowISO: now,
      expectedRevision: run.revision,
      eventID: UUID())
    let checking = try TatwoPLGOrchestrator.advanceToMainlineCheck(
      reporting.run,
      expectedRevision: reporting.run.revision,
      eventID: UUID())

    XCTAssertEqual(reporting.run.phase, .branchesReporting)
    XCTAssertEqual(checking.run.phase, .mainlineGoalCheck)
  }

  func testPassedBranchCannotReturnToMainlineWithoutDomainReceipt() throws {
    var run = executingRun()
    run.branchGoals[0].status = .passed
    run.branchGoals[0].reportedToMainline = true
    run.branchGoals[0].domainReceipt = nil

    XCTAssertThrowsError(
      try TatwoPLGOrchestrator.advanceToReporting(
        run,
        nowISO: now,
        expectedRevision: run.revision,
        eventID: UUID()))
  }

  func testPassedBranchReportRequiresMatchingDomainReceipt() {
    let run = executingRun()
    let branch = run.branchGoals[0]

    assertThrows(.branchDomainReceiptRequired(branch.id)) {
      try TatwoPLGOrchestrator.reportBranch(
        id: branch.id,
        status: .passed,
        reason: nil,
        nowISO: now,
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }

    var mismatched = validDomainReceipt(for: branch)
    mismatched.domainLoopID = "dloop-mismatch"
    assertThrows(.branchDomainReceiptMismatch(branch.id)) {
      try TatwoPLGOrchestrator.reportBranch(
        id: branch.id,
        status: .passed,
        reason: nil,
        domainReceipt: mismatched,
        nowISO: now,
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testReportRejectsForgedDigests() {
    let run = executingRun()
    let branch = run.branchGoals[0]

    var wrongInputs = validDomainReceipt(for: branch)
    wrongInputs.inputsDigest = TatwoArtifactReviewHasher.sha256("forged inputs")
    assertThrows(.branchDomainReceiptMismatch(branch.id)) {
      try TatwoPLGOrchestrator.reportBranch(
        id: branch.id,
        status: .passed,
        reason: nil,
        domainReceipt: wrongInputs,
        nowISO: now,
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }

    var wrongArtifacts = validDomainReceipt(for: branch)
    wrongArtifacts.artifactsDigest = TatwoArtifactReviewHasher.sha256("forged artifacts")
    assertThrows(.branchDomainReceiptMismatch(branch.id)) {
      try TatwoPLGOrchestrator.reportBranch(
        id: branch.id,
        status: .passed,
        reason: nil,
        domainReceipt: wrongArtifacts,
        nowISO: now,
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testReceiptPresentationDoesNotShowGreenPassForBlockedOrFail() throws {
    let missingRun = executingRun()

    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: missingRun.branchGoals[0],
        in: missingRun),
      .blocked)

    var failRun = executingRun()
    var failedReceipt = validDomainReceipt(for: failRun.branchGoals[0])
    failedReceipt.verdict = .fail
    failRun = try TatwoPLGOrchestrator.reportBranch(
      id: failRun.branchGoals[0].id,
      status: .blocked,
      reason: "verifier fail",
      domainReceipt: failedReceipt,
      nowISO: now,
      in: failRun,
      expectedRevision: failRun.revision,
      eventID: UUID()).run
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: failRun.branchGoals[0],
        in: failRun),
      .fail)

    var blockedRun = executingRun()
    var blockedReceipt = validDomainReceipt(for: blockedRun.branchGoals[0])
    blockedReceipt.verdict = .blocked
    blockedRun = try TatwoPLGOrchestrator.reportBranch(
      id: blockedRun.branchGoals[0].id,
      status: .blocked,
      reason: "waiting",
      domainReceipt: blockedReceipt,
      nowISO: now,
      in: blockedRun,
      expectedRevision: blockedRun.revision,
      eventID: UUID()).run
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: blockedRun.branchGoals[0],
        in: blockedRun),
      .blocked)

    var forgedRun = executingRun()
    var forgedReceipt = validDomainReceipt(for: forgedRun.branchGoals[0])
    forgedReceipt.inputsDigest = TatwoArtifactReviewHasher.sha256("stale")
    forgedRun.branchGoals[0].domainReceipt = forgedReceipt
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: forgedRun.branchGoals[0],
        in: forgedRun),
      .blocked)

    var passRun = executingRun()
    passRun = try TatwoPLGOrchestrator.reportBranch(
      id: passRun.branchGoals[0].id,
      status: .passed,
      reason: nil,
      domainReceipt: validDomainReceipt(for: passRun.branchGoals[0]),
      nowISO: now,
      in: passRun,
      expectedRevision: passRun.revision,
      eventID: UUID()).run
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: passRun.branchGoals[0],
        in: passRun),
      .pass)
  }

  func testBranchReportEventProjectsDomainReceipt() throws {
    let run = executingRun()
    let branch = run.branchGoals[0]
    let receipt = validDomainReceipt(for: branch)

    let transition = try TatwoPLGOrchestrator.reportBranch(
      id: branch.id,
      status: .passed,
      reason: nil,
      domainReceipt: receipt,
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())

    XCTAssertEqual(transition.run.branchGoals[0].domainReceipt, receipt)
    XCTAssertEqual(
      try TatwoPLGOrchestrator.project(transition.event, onto: run),
      transition.run)
  }

  func testRequestRollbackCreatesRollbackEvent() throws {
    let run = executingRun()

    let transition = try TatwoPLGOrchestrator.requestRollback(
      reason: "Verifier found unsafe state.",
      in: run,
      expectedRevision: 0,
      eventID: UUID())

    XCTAssertEqual(transition.run.phase, .rollbackRequired)
    XCTAssertEqual(transition.event.kind, .rollbackRequested)
  }

  func testMainlineGoalFailureRequiresRollback() throws {
    let run = makeRun(
      phase: .mainlineGoalCheck,
      revision: 9,
      humanAuth: validReceipt())

    let transition = try TatwoPLGOrchestrator.setMainlineGoalMet(
      false,
      in: run,
      expectedRevision: 9,
      eventID: UUID())

    XCTAssertEqual(transition.run.mainlineGoalMet, false)
    XCTAssertEqual(transition.run.phase, .rollbackRequired)
    XCTAssertEqual(transition.run.revision, 10)
  }

  func testMainlineGoalSuccessCannotBeProjectedByPLGAppStateMachine() {
    let run = makeRun(
      phase: .mainlineGoalCheck,
      revision: 9,
      humanAuth: validReceipt())

    assertThrows(.workOSCloseRequired) {
      try TatwoPLGOrchestrator.setMainlineGoalMet(
        true,
        in: run,
        expectedRevision: 9,
        eventID: UUID())
    }
  }

  func testTransitionRunIsExactlyProjectionOfItsEvent() throws {
    let run = makeRun()
    let transition = try TatwoPLGOrchestrator.advanceFromPlanning(
      run,
      expectedRevision: 0,
      eventID: UUID())

    let projected = try TatwoPLGOrchestrator.project(
      transition.event,
      onto: run)

    XCTAssertEqual(projected, transition.run)
  }

  func testPublicStateAndEventTypesRoundTripCodableAndHashable() throws {
    let run = makeRun()
    let event = TatwoPLGEvent(
      eventID: UUID(),
      kind: .rollbackRequested,
      atRevision: 1,
      payload: .rollback(reason: "test"))
    let transition = TatwoPLGTransition(run: run, event: event)

    assertCodableEquatableHashableSendable(run)
    assertCodableEquatableHashableSendable(event)
    assertCodableEquatableHashableSendable(transition)
    assertCodableEquatableHashableSendable(validReceipt())
    assertCodableEquatableHashableSendable(validDomainReceipt(for: run.branchGoals[0]))
  }

  func testLegacyBranchGoalDecodesWithoutPolicyDFields() throws {
    let id = UUID()
    let json = """
      {
        "id":"\(id.uuidString)",
        "objective":"Legacy branch",
        "subLabel":"Legacy sub",
        "subBindingID":"sub-0",
        "status":"planned",
        "attempt":0,
        "maxAttempts":3,
        "reportedToMainline":false,
        "escalated":false
      }
      """

    let decoded = try JSONDecoder().decode(
      TatwoPLGBranchGoal.self,
      from: Data(json.utf8))

    XCTAssertEqual(decoded.status, .blocked)
    XCTAssertFalse(decoded.reportedToMainline)
    XCTAssertTrue(decoded.reason?.contains("Policy D migration quarantine") == true)
    XCTAssertNil(decoded.domainLoopID)
    XCTAssertNil(decoded.domain)
    XCTAssertNil(decoded.planSlice)
    XCTAssertNil(decoded.domainReceipt)
  }

  func testDecodedIncompleteOrForgedPolicyDBranchIsQuarantined() throws {
    var forged = makeRun(
      phase: .branchesReporting,
      revision: 8,
      humanAuth: validReceipt())
    forged.branchGoals[0].status = .passed
    forged.branchGoals[0].reportedToMainline = true
    var receipt = validDomainReceipt(for: forged.branchGoals[0])
    receipt.inputsDigest = TatwoArtifactReviewHasher.sha256("forged snapshot")
    forged.branchGoals[0].domainReceipt = receipt

    let data = try JSONEncoder().encode(forged)
    let decoded = try JSONDecoder().decode(TatwoPLGRun.self, from: data)
    let branch = try XCTUnwrap(decoded.branchGoals.first)

    XCTAssertEqual(branch.status, .blocked)
    XCTAssertFalse(branch.reportedToMainline)
    XCTAssertNil(branch.domainReceipt)
    XCTAssertTrue(branch.reason?.contains("Policy D migration quarantine") == true)
  }

  func testDecodedSelfConsistentAuthoritySealIsQuarantinedUntilTrustedReplay() throws {
    var passed = executingRun()
    passed = try TatwoPLGOrchestrator.reportBranch(
      id: passed.branchGoals[0].id,
      status: .passed,
      reason: nil,
      domainReceipt: validDomainReceipt(for: passed.branchGoals[0]),
      nowISO: now,
      in: passed,
      expectedRevision: passed.revision,
      eventID: UUID()).run

    let decoded = try JSONDecoder().decode(
      TatwoPLGRun.self,
      from: JSONEncoder().encode(passed))
    let branch = try XCTUnwrap(decoded.branchGoals.first)

    XCTAssertEqual(branch.status, .blocked)
    XCTAssertFalse(branch.reportedToMainline)
    XCTAssertNil(branch.domainReceipt)
    XCTAssertTrue(
      branch.reason?.contains("untrusted decoded authority") == true)
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(for: branch, in: decoded),
      .blocked)
  }

  func testReceiptPresentationRejectsDuplicateAndNonMemberBranches() throws {
    var passed = executingRun()
    passed = try TatwoPLGOrchestrator.reportBranch(
      id: passed.branchGoals[0].id,
      status: .passed,
      reason: nil,
      domainReceipt: validDomainReceipt(for: passed.branchGoals[0]),
      nowISO: now,
      in: passed,
      expectedRevision: passed.revision,
      eventID: UUID()).run

    var duplicated = passed
    duplicated.branchGoals.append(passed.branchGoals[0])
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: duplicated.branchGoals[0],
        in: duplicated),
      .blocked)

    var other = executingRun()
    other = try TatwoPLGOrchestrator.reportBranch(
      id: other.branchGoals[0].id,
      status: .passed,
      reason: nil,
      domainReceipt: validDomainReceipt(for: other.branchGoals[0]),
      nowISO: now,
      in: other,
      expectedRevision: other.revision,
      eventID: UUID()).run
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: other.branchGoals[0],
        in: passed),
      .blocked)
  }

  func testDirectMutationCannotAdvanceForgedSnapshot() {
    var forged = makeRun(
      phase: .branchesReporting,
      revision: 8,
      humanAuth: validReceipt())
    forged.branchGoals[0].status = .passed
    forged.branchGoals[0].reportedToMainline = true
    var receipt = validDomainReceipt(for: forged.branchGoals[0])
    receipt.artifactsDigest = TatwoArtifactReviewHasher.sha256("forged snapshot")
    forged.branchGoals[0].domainReceipt = receipt

    assertThrows(.branchDomainReceiptMismatch(forged.branchGoals[0].id)) {
      try TatwoPLGOrchestrator.advanceToMainlineCheck(
        forged,
        expectedRevision: forged.revision,
        eventID: UUID())
    }
  }

  func testReplanCreatesFreshLoopIdentityAndCannotReusePriorReceipt() throws {
    var run = executingRun()
    let branchID = run.branchGoals[0].id
    let priorSourceLoopID = try XCTUnwrap(run.branchGoals[0].sourceLoopID)
    let priorDomainLoopID = try XCTUnwrap(run.branchGoals[0].domainLoopID)
    var failedReceipt = validDomainReceipt(for: run.branchGoals[0])
    failedReceipt.verdict = .fail

    run = try TatwoPLGOrchestrator.reportBranch(
      id: branchID,
      status: .blocked,
      reason: "verifier rejected",
      domainReceipt: failedReceipt,
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID()).run

    let replanned = try TatwoPLGOrchestrator.replanBranch(
      id: branchID,
      reason: "new branch instance",
      deadlineISO: nil,
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID()).run
    let branch = replanned.branchGoals[0]

    XCTAssertNotEqual(branch.sourceLoopID, priorSourceLoopID)
    XCTAssertNotEqual(branch.domainLoopID, priorDomainLoopID)
    XCTAssertNil(branch.domainReceipt)
    XCTAssertFalse(branch.reportedToMainline)
    assertThrows(.branchDomainReceiptMismatch(branchID)) {
      try TatwoPLGOrchestrator.reportBranch(
        id: branchID,
        status: .passed,
        reason: nil,
        domainReceipt: validDomainReceipt(for: run.branchGoals[0]),
        nowISO: now,
        in: replanned,
        expectedRevision: replanned.revision,
        eventID: UUID())
    }
  }

  func testDuplicateSourceLoopIDIsRejectedBeforeBranchesCanReport() {
    var run = executingRun(branchCount: 0)
    run.subBindings = [
      binding(id: "sub-0", identity: .sub),
      binding(id: "sub-1", identity: .sub)
    ]
    let sourceLoopID = "loop-code-authoritative"
    let first = branchGoal(index: 0, sourceLoopID: sourceLoopID)
    let second = branchGoal(index: 1, sourceLoopID: sourceLoopID)

    assertThrows(.duplicateSourceLoopID(sourceLoopID)) {
      try TatwoPLGOrchestrator.addBranchGoals(
        [first, second],
        in: run,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  func testForgedGeneratedDomainLoopIDIsRejectedBeforeReporting() {
    var run = executingRun()
    run.branchGoals[0].domainLoopID = TatwoPLGOrchestrator.makeDomainLoopID(
      contractID: run.contractID,
      domain: .ui,
      sourceLoopID: "different-source-loop")

    assertThrows(.branchDomainLoopIDMismatch(run.branchGoals[0].id)) {
      try TatwoPLGOrchestrator.advanceToReporting(
        run,
        nowISO: now,
        expectedRevision: run.revision,
        eventID: UUID())
    }
  }

  private func awaitingRun() throws -> TatwoPLGRun {
    let planning = try TatwoPLGOrchestrator.advanceFromPlanning(
      makeRun(),
      expectedRevision: 0,
      eventID: UUID())
    return try TatwoPLGOrchestrator.setAdversarialConclusion(
      "Lead review completed.",
      in: planning.run,
      expectedRevision: planning.run.revision,
      eventID: UUID()).run
  }

  private func executingRun(branchCount: Int = 1) -> TatwoPLGRun {
    makeRun(
      phase: .executingLoops,
      humanAuth: validReceipt(),
      branchCount: branchCount)
  }

  private func report(
    _ id: UUID,
    _ status: TatwoLoopsStatus,
    reason: String? = nil,
    in run: TatwoPLGRun
  ) throws -> TatwoPLGTransition {
    try TatwoPLGOrchestrator.reportBranch(
      id: id,
      status: status,
      reason: reason,
      domainReceipt: status == .passed
        ? run.branchGoals.first(where: { $0.id == id }).map(validDomainReceipt)
        : nil,
      nowISO: now,
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())
  }

  private func makeRun(
    phase: TatwoPLGPhase = .planning,
    revision: Int = 0,
    humanAuth: TatwoPLGHumanAuthReceipt? = nil,
    leadCount: Int = 1,
    branchCount: Int = 1,
    leadBindings: [WorkOSIdentityBinding]? = nil,
    subBindings: [WorkOSIdentityBinding]? = nil
  ) -> TatwoPLGRun {
    let resolvedLeadBindings = leadBindings ?? (0..<leadCount).map {
      binding(id: "lead-\($0)", identity: .lead)
    }
    let resolvedSubBindings = subBindings ?? (0..<branchCount).map {
      binding(id: "sub-\($0)", identity: .sub)
    }

    return TatwoPLGRun(
      id: UUID(),
      goalID: "goal-16",
      contractID: "contract-16",
      revision: revision,
      phase: phase,
      leadBindings: resolvedLeadBindings,
      subBindings: resolvedSubBindings,
      planSummary: "Build the pure PLG state machine.",
      adversarialConclusion: nil,
      humanAuth: humanAuth,
      branchGoals: (0..<branchCount).map { index in
        TatwoPLGBranchGoal(
          id: UUID(),
          objective: "Branch \(index)",
          subLabel: "Sub \(index)",
          subBindingID: "sub-\(index)",
          status: .planned,
          reason: nil,
          attempt: 0,
          deadlineISO: nil,
          reportedToMainline: false,
          domainLoopID: domainLoopID(index: index),
          domain: domain(index: index),
          sourceLoopID: sourceLoopID(index: index),
          ownerIdentity: .sub,
          planSlice: planSlice(index: index),
          domainReceipt: nil)
      },
      mainlineGoalMet: nil)
  }

  private func branchGoal(
    index: Int,
    subBindingID: String? = nil,
    includeDomainBinding: Bool = true,
    sourceLoopID: String? = nil
  ) -> TatwoPLGBranchGoal {
    let resolvedSourceLoopID = sourceLoopID ?? self.sourceLoopID(index: index)
    return TatwoPLGBranchGoal(
      id: UUID(),
      objective: "Branch \(index)",
      subLabel: "Sub \(index)",
      subBindingID: subBindingID ?? "sub-\(index)",
      status: .planned,
      reason: nil,
      attempt: 0,
      deadlineISO: nil,
      reportedToMainline: false,
      domainLoopID: includeDomainBinding
        ? TatwoPLGOrchestrator.makeDomainLoopID(
          contractID: "contract-16",
          domain: domain(index: index),
          sourceLoopID: resolvedSourceLoopID)
        : nil,
      domain: includeDomainBinding ? domain(index: index) : nil,
      sourceLoopID: includeDomainBinding ? resolvedSourceLoopID : nil,
      ownerIdentity: includeDomainBinding ? .sub : nil,
      planSlice: includeDomainBinding ? planSlice(index: index) : nil,
      domainReceipt: nil)
  }

  private func domain(index: Int) -> TatwoPLGDomain {
    [.ui, .code, .ops][index % 3]
  }

  private func domainLoopID(index: Int) -> String {
    TatwoPLGOrchestrator.makeDomainLoopID(
      contractID: "contract-16",
      domain: domain(index: index),
      sourceLoopID: sourceLoopID(index: index))
  }

  private func sourceLoopID(index: Int) -> String {
    "source-loop-\(index)"
  }

  private func planSlice(index: Int) -> String {
    "\(domain(index: index).plainName): Branch \(index)"
  }

  private func validDomainReceipt(
    for branch: TatwoPLGBranchGoal
  ) -> TatwoPLGDomainReceipt {
    let testsRun = ["swift test --filter TatwoPLGOrchestratorTests"]
    return TatwoPLGDomainReceipt(
      domainLoopID: branch.domainLoopID ?? "",
      objectiveHash: TatwoObjectiveIdentity.make(branch.objective).objectiveHash,
      inputsDigest: TatwoArtifactReviewHasher.sha256(branch.planSlice ?? ""),
      artifactsDigest: TatwoPLGOrchestrator.makeArtifactsDigest(
        testsRun: testsRun),
      verdict: .pass,
      testsRun: testsRun)
  }

  private func validReceipt(
    contractID: String = "contract-16",
    issuedISO: String = "2026-07-13T09:00:00Z",
    expiresISO: String = "2026-07-13T11:00:00Z"
  ) -> TatwoPLGHumanAuthReceipt {
    TatwoPLGHumanAuthReceipt(
      receiptID: "plg-human-auth-test",
      actor: "human-owner",
      issuedISO: issuedISO,
      expiresISO: expiresISO,
      scope: "execute-loops",
      contractID: contractID)
  }

  private func binding(
    id: String,
    identity: IdentityKind
  ) -> WorkOSIdentityBinding {
    WorkOSIdentityBinding(
      id: id,
      identity: identity,
      label: id,
      engineID: nil,
      modelID: "bound-\(id)",
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "slot-\(id)",
      bindingRule: "test binding")
  }

  private func assertThrows(
    _ expected: TatwoPLGError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> TatwoPLGTransition
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      XCTAssertEqual(error as? TatwoPLGError, expected, file: file, line: line)
    }
  }

  private func assertCodableEquatableHashableSendable<T>(
    _ value: T,
    file: StaticString = #filePath,
    line: UInt = #line
  ) where T: Codable & Equatable & Hashable & Sendable {
    do {
      let data = try JSONEncoder().encode(value)
      let decoded = try JSONDecoder().decode(T.self, from: data)
      XCTAssertEqual(decoded, value, file: file, line: line)
      XCTAssertEqual(decoded.hashValue, value.hashValue, file: file, line: line)
    } catch {
      XCTFail("Codable round trip failed: \(error)", file: file, line: line)
    }
  }
}

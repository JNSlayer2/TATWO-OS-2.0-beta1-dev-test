import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoBrowserActionPlanCoreTests: XCTestCase {
  func testScrollProposalIsLowRiskAndDoesNotRequireActionGate() {
    let plan = propose([
      .init(id: "scroll-1", intent: .scroll(direction: .down, distance: 480))
    ])

    XCTAssertEqual(plan.steps.map(\.id), ["scroll-1"])
    XCTAssertEqual(plan.steps[0].risk, .lowInteraction)
    XCTAssertEqual(plan.steps[0].gateRequirement, .none)
    XCTAssertNil(plan.steps[0].blocker)
    XCTAssertTrue(plan.gatedStepIDs.isEmpty)
  }

  func testOrdinaryClickRequiresPerActionApproval() {
    let plan = propose([
      .init(id: "click-1", intent: .click(targetID: "docs-link"))
    ])

    XCTAssertEqual(plan.steps[0].risk, .lowInteraction)
    XCTAssertEqual(plan.steps[0].gateRequirement, .perActionApproval)
    XCTAssertEqual(plan.gatedStepIDs, ["click-1"])
  }

  func testOrdinaryTypeProposalStoresOnlyRedactedInputDescriptor() {
    let input = TatwoBrowserActionPlanInput(
      redactedSummary: "search text (12 chars)",
      characterCount: 12,
      sensitivity: .ordinary)
    let plan = propose([
      .init(id: "type-1", intent: .typeText(targetID: "search", input: input))
    ])

    XCTAssertEqual(plan.steps[0].risk, .lowInteraction)
    XCTAssertEqual(plan.steps[0].gateRequirement, .perActionApproval)
    XCTAssertEqual(plan.steps[0].intent, .typeText(targetID: "search", input: input))
  }

  func testSensitiveTypeProposalRequiresWarningGate() {
    let input = TatwoBrowserActionPlanInput(
      redactedSummary: "password (redacted)",
      characterCount: 20,
      sensitivity: .password)
    let plan = propose([
      .init(id: "type-password", intent: .typeText(targetID: "password", input: input))
    ])

    XCTAssertEqual(plan.steps[0].risk, .sensitiveInput)
    XCTAssertEqual(plan.steps[0].gateRequirement, .perActionApprovalWithWarning)
  }

  func testTargetRiskHintsEscalateClickRiskAndGate() {
    let observation = makeObservation(targets: [
      target("publish", risks: [.externalSideEffect]),
      target("delete", risks: [.irreversible])
    ])

    let plan = TatwoBrowserActionPlanner.propose(
      observation: observation,
      requests: [
        .init(id: "publish-click", intent: .click(targetID: "publish")),
        .init(id: "delete-click", intent: .click(targetID: "delete"))
      ])

    XCTAssertEqual(plan.steps[0].risk, .externalSideEffect)
    XCTAssertEqual(plan.steps[0].gateRequirement, .perActionApprovalWithWarning)
    XCTAssertEqual(plan.steps[1].risk, .irreversible)
    XCTAssertEqual(plan.steps[1].gateRequirement, .perActionApprovalWithWarning)
    XCTAssertEqual(plan.highestRisk, .irreversible)
  }

  func testForbiddenTargetProducesBlockedStepRatherThanExecutableProposal() {
    let observation = makeObservation(targets: [
      target("captcha", risks: [.forbidden])
    ])

    let plan = TatwoBrowserActionPlanner.propose(
      observation: observation,
      requests: [
        .init(id: "captcha-click", intent: .click(targetID: "captcha"))
      ])

    XCTAssertEqual(plan.steps[0].risk, .forbidden)
    XCTAssertEqual(plan.steps[0].gateRequirement, .forbidden)
    XCTAssertEqual(plan.steps[0].blocker, .forbiddenTarget)
    XCTAssertEqual(plan.blockedStepIDs, ["captcha-click"])
    XCTAssertTrue(plan.gatedStepIDs.isEmpty)
  }

  func testMissingHiddenAndDisabledTargetsFailClosed() {
    let observation = makeObservation(targets: [
      target("hidden", isVisible: false),
      target("disabled", isEnabled: false)
    ])

    let plan = TatwoBrowserActionPlanner.propose(
      observation: observation,
      requests: [
        .init(id: "missing-click", intent: .click(targetID: "missing")),
        .init(id: "hidden-click", intent: .click(targetID: "hidden")),
        .init(id: "disabled-type", intent: .typeText(
          targetID: "disabled",
          input: .init(
            redactedSummary: "text (4 chars)",
            characterCount: 4,
            sensitivity: .ordinary)))
      ])

    XCTAssertEqual(
      plan.steps.map(\.blocker),
      [.targetMissing, .targetNotVisible, .targetDisabled])
    XCTAssertEqual(plan.steps.map(\.gateRequirement), [.forbidden, .forbidden, .forbidden])
    XCTAssertEqual(plan.blockedStepIDs, ["missing-click", "hidden-click", "disabled-type"])
  }

  func testPlanPreservesObservationBindingAndRequestOrder() {
    let observation = makeObservation()
    let requests: [TatwoBrowserActionPlanRequest] = [
      .init(id: "scroll", intent: .scroll(direction: .down, distance: 320)),
      .init(id: "click", intent: .click(targetID: "docs-link")),
      .init(
        id: "type",
        intent: .typeText(
          targetID: "search",
          input: .init(
            redactedSummary: "query (8 chars)",
            characterCount: 8,
            sensitivity: .ordinary)))
    ]

    let plan = TatwoBrowserActionPlanner.propose(
      observation: observation,
      requests: requests)

    XCTAssertEqual(plan.sessionID, observation.sessionID)
    XCTAssertEqual(plan.observationID, observation.observationID)
    XCTAssertEqual(plan.origin, observation.origin)
    XCTAssertEqual(plan.documentFingerprint, observation.documentFingerprint)
    XCTAssertEqual(plan.steps.map(\.id), ["scroll", "click", "type"])
    XCTAssertEqual(plan.gatedStepIDs, ["click", "type"])
  }

  func testPlanTypesHaveCodableValueSemantics() throws {
    let plan = propose([
      .init(id: "scroll", intent: .scroll(direction: .up, distance: 200)),
      .init(id: "click", intent: .click(targetID: "docs-link"))
    ])
    var copy = plan
    copy = TatwoBrowserActionPlanner.propose(
      observation: makeObservation(),
      requests: [
        .init(id: "scroll", intent: .scroll(direction: .down, distance: 200))
      ])

    XCTAssertNotEqual(copy, plan)

    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(TatwoBrowserActionPlan.self, from: data)
    XCTAssertEqual(decoded, plan)
  }

  private func propose(
    _ requests: [TatwoBrowserActionPlanRequest]
  ) -> TatwoBrowserActionPlan {
    TatwoBrowserActionPlanner.propose(
      observation: makeObservation(),
      requests: requests)
  }

  private func makeObservation(
    targets: [TatwoBrowserActionPlanTarget]? = nil
  ) -> TatwoBrowserActionPlanObservation {
    TatwoBrowserActionPlanObservation(
      sessionID: "browser-session",
      observationID: "observation-7",
      origin: "https://example.com:443",
      documentFingerprint: "document-sha256",
      targets: targets ?? [
        target("docs-link"),
        target("search"),
        target("password", risks: [.sensitiveInput])
      ])
  }

  private func target(
    _ id: String,
    isVisible: Bool = true,
    isEnabled: Bool = true,
    risks: Set<TatwoBrowserActionPlanTargetRisk> = []
  ) -> TatwoBrowserActionPlanTarget {
    TatwoBrowserActionPlanTarget(
      id: id,
      role: "button",
      accessibleName: id,
      isVisible: isVisible,
      isEnabled: isEnabled,
      risks: risks)
  }
}

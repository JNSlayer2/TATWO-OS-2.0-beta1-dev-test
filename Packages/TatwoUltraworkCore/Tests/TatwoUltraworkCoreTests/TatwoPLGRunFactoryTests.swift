import XCTest

@testable import TatwoUltraworkCore

final class TatwoPLGRunFactoryTests: XCTestCase {
  func testMakeCreatesSingleLeadPlanningRun() {
    let run = TatwoPLGRunFactory.make(
      objective: "Bridge thread config",
      contractID: "contract-17",
      goalID: "goal-17",
      leadModelIDs: ["gpt-custom"],
      subModelIDs: [],
      nowISO: "2026-07-13T10:00:00Z")

    XCTAssertEqual(run.goalID, "goal-17")
    XCTAssertEqual(run.contractID, "contract-17")
    XCTAssertEqual(run.planSummary, "Bridge thread config")
    XCTAssertEqual(run.phase, .planning)
    XCTAssertEqual(run.revision, 0)
    XCTAssertEqual(run.leadBindings.count, 1)
    XCTAssertEqual(run.leadBindings[0].id, "role-lead-gpt-custom")
    XCTAssertEqual(run.leadBindings[0].identity, .lead)
    XCTAssertEqual(run.leadBindings[0].modelID, "gpt-custom")
    XCTAssertEqual(run.leadBindings[0].engineID, .modelGateway)
    XCTAssertFalse(run.leadBindings[0].canMutateHost)
    XCTAssertEqual(run.branchGoals, [])
  }

  func testMakeCreatesSubBindingsFromSuppliedModelIDs() {
    let run = TatwoPLGRunFactory.make(
      objective: "Bridge thread config",
      contractID: "contract-17",
      goalID: "goal-17",
      leadModelIDs: [],
      subModelIDs: ["sub-alpha", "sub-beta"],
      nowISO: "2026-07-13T10:00:00Z")

    XCTAssertEqual(run.subBindings.map(\.id), [
      "role-sub-sub-alpha",
      "role-sub-sub-beta",
    ])
    XCTAssertEqual(run.subBindings.map(\.identity), [.sub, .sub])
    XCTAssertEqual(run.subBindings.compactMap(\.modelID), ["sub-alpha", "sub-beta"])
    XCTAssertEqual(run.subBindings.compactMap(\.engineID), [.modelGateway, .modelGateway])
    XCTAssertTrue(run.subBindings.allSatisfy { $0.authority == .brainOnly })
    XCTAssertTrue(run.subBindings.allSatisfy { !$0.canMutateHost })
  }

  func testClaudeFamilyModelIDsInferClaudeEngineCaseInsensitively() {
    let modelIDs = [
      "Fable-5",
      "claude-opus-4",
      "SONNET-next",
      "team-haiku",
    ]
    let run = TatwoPLGRunFactory.make(
      objective: "Bridge thread config",
      contractID: "contract-17",
      goalID: "goal-17",
      leadModelIDs: [],
      subModelIDs: modelIDs,
      nowISO: "2026-07-13T10:00:00Z")

    XCTAssertEqual(run.subBindings.compactMap(\.engineID), [
      .claude,
      .claude,
      .claude,
      .claude,
    ])
  }

  func testMultipleLeadModelsCreateMultipleLeadBindingsInInputOrder() {
    let run = TatwoPLGRunFactory.make(
      objective: "Bridge thread config",
      contractID: "contract-17",
      goalID: "goal-17",
      leadModelIDs: ["lead-one", "lead-two", "lead-three"],
      subModelIDs: [],
      nowISO: "2026-07-13T10:00:00Z")

    XCTAssertEqual(run.leadBindings.compactMap(\.modelID), [
      "lead-one",
      "lead-two",
      "lead-three",
    ])
    XCTAssertEqual(run.leadBindings.map(\.identity), [.lead, .lead, .lead])
  }

  func testMultipleLeadBindingsMarkRunAsMultiLead() {
    let run = TatwoPLGRunFactory.make(
      objective: "Bridge thread config",
      contractID: "contract-17",
      goalID: "goal-17",
      leadModelIDs: ["lead-one", "lead-two"],
      subModelIDs: [],
      nowISO: "2026-07-13T10:00:00Z")

    XCTAssertTrue(run.isMultiLead)
  }

  func testMakeLeavesRuntimeOnlyStateUninitialized() {
    let run = TatwoPLGRunFactory.make(
      objective: "Bridge thread config",
      contractID: "contract-17",
      goalID: "goal-17",
      leadModelIDs: ["lead-one"],
      subModelIDs: ["sub-one"],
      nowISO: "2026-07-13T10:00:00Z")

    XCTAssertNil(run.adversarialConclusion)
    XCTAssertNil(run.humanAuth)
    XCTAssertTrue(run.branchGoals.isEmpty)
    XCTAssertNil(run.mainlineGoalMet)
  }

  func testBindingMetadataUsesSuppliedModelsAndCreationTime() {
    let nowISO = "2031-02-03T04:05:06Z"
    let run = TatwoPLGRunFactory.make(
      objective: "Arbitrary objective",
      contractID: "arbitrary-contract",
      goalID: "arbitrary-goal",
      leadModelIDs: ["vendor-lead-x"],
      subModelIDs: ["vendor-sub-y"],
      nowISO: nowISO)

    XCTAssertEqual(run.leadBindings[0].label, "vendor-lead-x")
    XCTAssertEqual(run.subBindings[0].label, "vendor-sub-y")
    XCTAssertEqual(run.leadBindings[0].sourceSlotID, "thread-config-lead")
    XCTAssertEqual(run.subBindings[0].sourceSlotID, "thread-config-sub")
    XCTAssertTrue(run.leadBindings[0].bindingRule.contains(nowISO))
    XCTAssertTrue(run.subBindings[0].bindingRule.contains(nowISO))
  }
}

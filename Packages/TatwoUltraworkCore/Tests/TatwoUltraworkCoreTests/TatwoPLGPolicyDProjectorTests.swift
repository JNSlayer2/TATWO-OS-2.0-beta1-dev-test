import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoPLGPolicyDProjectorTests: XCTestCase {
  func testExactAndNativeDevelopmentXXLBranchesResolveIssuedBindingsAndCanExecute()
    throws
  {
    for scenarioID in [
      TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLFableGrokScenarioID,
    ] {
      let contract = try WorkOSFactory.projectContract(
        mode: .xxl,
        scenarioProfileID: scenarioID,
        objective: "XXL PLG binding closure \(scenarioID)")
      var projected = TatwoPLGPolicyDProjector.project(
        run: run(for: contract),
        contract: contract,
        goalRecord: nil)
      let requiredSourceLoopIDs = Set(
        contract.domainLoops
          .filter { $0.requiredReceipts.contains(where: \.requiredForPass) }
          .map(\.id))
      let requiredBranches = projected.branchGoals.filter {
        $0.sourceLoopID.map(requiredSourceLoopIDs.contains) == true
      }
      let allBindings = projected.leadBindings + projected.subBindings
      let activatedByID = Dictionary(
        uniqueKeysWithValues:
          contract.loopGovernorDecision.activatedBindings.map { ($0.id, $0) })

      XCTAssertFalse(requiredBranches.isEmpty, scenarioID)
      XCTAssertEqual(
        requiredBranches.count,
        requiredSourceLoopIDs.count,
        scenarioID)
      for branch in requiredBranches {
        XCTAssertEqual(
          branch.status,
          .planned,
          "\(scenarioID): \(branch.reason ?? branch.objective)")
        XCTAssertFalse(branch.subBindingID.hasPrefix("unassigned-"), scenarioID)
        let issued = try XCTUnwrap(
          allBindings.first { $0.id == branch.subBindingID })
        XCTAssertEqual(issued.identity, branch.ownerIdentity, scenarioID)
        let activated = try XCTUnwrap(activatedByID[issued.sourceSlotID])
        XCTAssertTrue(activated.enabled, scenarioID)
        XCTAssertNotEqual(activated.dynamicActivation, .disabled, scenarioID)
        XCTAssertEqual(activated.phase, .loops, scenarioID)
        XCTAssertTrue(
          activated.boundModelIDs.contains {
            TatwoGatewayDispatchCatalog.normalize($0)
              == TatwoGatewayDispatchCatalog.normalize(issued.modelID ?? "")
          },
          scenarioID)
      }

      projected = try TatwoPLGOrchestrator.advanceFromPlanning(
        projected,
        expectedRevision: projected.revision,
        eventID: UUID()).run
      projected = try TatwoPLGOrchestrator.setAdversarialConclusion(
        "required branches and issued loop bindings verified",
        in: projected,
        expectedRevision: projected.revision,
        eventID: UUID()).run
      projected = try TatwoPLGOrchestrator.authorize(
        receipt: TatwoPLGHumanAuthReceipt(
          receiptID: "human-confirm",
          actor: "user",
          issuedISO: "2026-08-17T10:00:00Z",
          expiresISO: "2026-08-17T11:00:00Z",
          scope: "execute confirmed plan",
          contractID: contract.contractID),
        nowISO: "2026-08-17T10:30:00Z",
        in: projected,
        expectedRevision: projected.revision,
        eventID: UUID()).run
      XCTAssertEqual(projected.phase, .executingLoops, scenarioID)
    }
  }

  func testProjectionDoesNotMintPassFromSubmittedIDs() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D metadata containment")
    let receiptIDs = Set(
      contract.domainLoops
        .flatMap(\.requiredReceipts)
        .filter(\.requiredForPass)
        .map(\.id))
    let record = storedGoal(
      for: contract,
      receiptIDs: receiptIDs)

    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: record)

    XCTAssertEqual(projected.branchGoals.count, contract.domainLoops.count)
    XCTAssertTrue(projected.branchGoals.allSatisfy { $0.domainReceipt == nil })
    XCTAssertTrue(projected.branchGoals.allSatisfy { !$0.reportedToMainline })
    XCTAssertTrue(projected.branchGoals.allSatisfy { $0.status != .passed })
    XCTAssertTrue(
      projected.branchGoals
        .filter { branch in
          contract.domainLoops.first(where: { $0.id == branch.sourceLoopID })?
            .requiredReceipts.contains(where: \.requiredForPass) == true
        }
        .allSatisfy {
          $0.reason?.localizedCaseInsensitiveContains("metadata-only") == true
        })
  }

  func testProjectionIsInvariantToBindingOrderAndBlocksAmbiguity() throws {
    let generated = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D deterministic identity routing")
    let canonicalSub = WorkOSIdentityBinding(
      id: "canonical-sub",
      identity: .sub,
      label: "canonical sub",
      engineID: nil,
      modelID: "canonical",
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "canonical",
      bindingRule: "deterministic test")
    let base = replacing(
      generated,
      identityBindings:
        generated.identityBindings.filter { $0.identity != .sub }
        + [canonicalSub])
    let reversed = replacing(
      base,
      identityBindings: Array(base.identityBindings.reversed()))

    let first = TatwoPLGPolicyDProjector.project(
      run: run(for: base),
      contract: base,
      goalRecord: nil)
    let second = TatwoPLGPolicyDProjector.project(
      run: run(for: reversed),
      contract: reversed,
      goalRecord: nil)

    XCTAssertEqual(projectionMap(first), projectionMap(second))

    let withoutSub = replacing(
      base,
      identityBindings: base.identityBindings.filter { $0.identity != .sub })
    let unassigned = TatwoPLGPolicyDProjector.project(
      run: run(for: withoutSub),
      contract: withoutSub,
      goalRecord: nil)
    XCTAssertTrue(
      unassigned.branchGoals
        .filter { $0.ownerIdentity == .sub }
        .allSatisfy {
          $0.status == .blocked
            && $0.reason?.localizedCaseInsensitiveContains("unassigned") == true
        })

    let duplicateSub = WorkOSIdentityBinding(
      id: "duplicate-sub",
      identity: .sub,
      label: "duplicate sub",
      engineID: nil,
      modelID: "duplicate",
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "duplicate",
      bindingRule: "negative test")
    let ambiguousContract = replacing(
      base,
      identityBindings: base.identityBindings + [duplicateSub])
    let ambiguous = TatwoPLGPolicyDProjector.project(
      run: run(for: ambiguousContract),
      contract: ambiguousContract,
      goalRecord: nil)
    XCTAssertTrue(
      ambiguous.branchGoals
        .filter { $0.ownerIdentity == .sub }
        .allSatisfy {
          $0.status == .blocked
            && $0.reason?.localizedCaseInsensitiveContains("ambiguous") == true
        })
  }

  func testUnsupportedDomainRemainsVisibleAndBlocked() throws {
    let base = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D unsupported domain")
    let unsupported = DomainLoop(
      id: "loop-custom-visible",
      domain: .custom,
      title: "Custom Loop",
      ownerIdentity: .sub,
      allowedTools: [],
      sandboxType: .tempWorkspace,
      requiredReceipts: [],
      status: .planned,
      autonomyLevel: "test",
      mergeBackRule: "test")
    let contract = replacing(
      base,
      domainLoops: base.domainLoops + [unsupported])

    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    let branch = try XCTUnwrap(
      projected.branchGoals.first { $0.sourceLoopID == unsupported.id })

    XCTAssertEqual(projected.branchGoals.count, contract.domainLoops.count)
    XCTAssertEqual(branch.status, .blocked)
    XCTAssertFalse(branch.reportedToMainline)
    XCTAssertNil(branch.domainReceipt)
    XCTAssertTrue(
      branch.reason?.localizedCaseInsensitiveContains("unsupported") == true)
  }

  func testUnsupportedCustomDomainCannotAdvanceFromPlanning() throws {
    let base = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D custom domain planning gate")
    let unsupported = DomainLoop(
      id: "loop-custom-planning-gate",
      domain: .custom,
      title: "Custom Loop",
      ownerIdentity: .sub,
      allowedTools: [],
      sandboxType: .tempWorkspace,
      requiredReceipts: [],
      status: .planned,
      autonomyLevel: "test",
      mergeBackRule: "test")
    let contract = replacing(
      base,
      domainLoops: [unsupported])
    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    let branch = try XCTUnwrap(
      projected.branchGoals.first { $0.sourceLoopID == unsupported.id })

    XCTAssertThrowsError(
      try TatwoPLGOrchestrator.advanceFromPlanning(
        projected,
        expectedRevision: projected.revision,
        eventID: UUID())
    ) { error in
      XCTAssertEqual(
        error as? TatwoPLGError,
        .bindingNotFound(branch.subBindingID))
    }
  }

  func testUnsupportedDomainSeedRoundTripsThroughAnchoredReplay() throws {
    let base = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D unsupported domain replay")
    let unsupported = DomainLoop(
      id: "loop-custom-replay",
      domain: .custom,
      title: "Custom Loop",
      ownerIdentity: .sub,
      allowedTools: [],
      sandboxType: .tempWorkspace,
      requiredReceipts: [],
      status: .planned,
      autonomyLevel: "test",
      mergeBackRule: "test")
    let contract = replacing(
      base,
      domainLoops: base.domainLoops + [unsupported])
    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-policy-d-replay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: PolicyDTestAnchorAuthority())

    let decoded = try JSONDecoder().decode(
      TatwoPLGRun.self,
      from: JSONEncoder().encode(projected))
    for (index, pair) in zip(
      projected.branchGoals,
      decoded.branchGoals
    ).enumerated() where pair.0 != pair.1 {
      print("branch[\(index)] original=\(pair.0)")
      print("branch[\(index)] decoded=\(pair.1)")
    }
    XCTAssertEqual(decoded, projected)

    try store.begin(run: projected)
    let replayed = try store.replay(
      contractID: projected.contractID,
      goalID: projected.goalID,
      runID: projected.id)

    XCTAssertEqual(replayed.run, projected)
  }

  func testUnsupportedDomainDecodeQuarantinesAuthorityBearingLookalikes() throws {
    let base = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D unsupported domain authority quarantine")
    let unsupported = DomainLoop(
      id: "loop-custom-authority",
      domain: .custom,
      title: "Custom Loop",
      ownerIdentity: .sub,
      allowedTools: [],
      sandboxType: .tempWorkspace,
      requiredReceipts: [],
      status: .planned,
      autonomyLevel: "test",
      mergeBackRule: "test")
    let contract = replacing(
      base,
      domainLoops: base.domainLoops + [unsupported])
    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    let encoded = try JSONEncoder().encode(projected)

    let mutations: [(String, (inout [String: Any]) -> Void)] = [
      ("passed", { $0["status"] = "passed" }),
      ("reported", { $0["reportedToMainline"] = true }),
      ("revision", { $0["authorityRevision"] = 1 }),
      ("seal", { $0["authoritySeal"] = "forged-authority-seal" }),
    ]

    for (label, mutate) in mutations {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      var branches = try XCTUnwrap(
        object["branchGoals"] as? [[String: Any]])
      let index = try XCTUnwrap(
        branches.firstIndex {
          ($0["reason"] as? String)?
            .localizedCaseInsensitiveContains("unsupported domain") == true
        })
      mutate(&branches[index])
      object["branchGoals"] = branches

      let decoded = try JSONDecoder().decode(
        TatwoPLGRun.self,
        from: JSONSerialization.data(withJSONObject: object))
      let branch = try XCTUnwrap(
        decoded.branchGoals.first {
          $0.objective == unsupported.title
        },
        "missing mutated branch for \(label)")

      XCTAssertEqual(decoded.phase, .rollbackRequired, label)
      XCTAssertEqual(branch.status, .blocked, label)
      XCTAssertFalse(branch.reportedToMainline, label)
      XCTAssertNil(branch.domainReceipt, label)
      XCTAssertNil(branch.authorityRevision, label)
      XCTAssertNil(branch.authoritySeal, label)
      XCTAssertTrue(
        branch.reason?
          .localizedCaseInsensitiveContains("migration quarantine") == true,
        label)
    }
  }

  func testUnsupportedDomainSeedTamperingFailsAnchoredReplay() throws {
    let base = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D unsupported domain tamper rejection")
    let unsupported = DomainLoop(
      id: "loop-custom-tamper",
      domain: .custom,
      title: "Custom Loop",
      ownerIdentity: .sub,
      allowedTools: [],
      sandboxType: .tempWorkspace,
      requiredReceipts: [],
      status: .planned,
      autonomyLevel: "test",
      mergeBackRule: "test")
    let contract = replacing(
      base,
      domainLoops: base.domainLoops + [unsupported])
    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-policy-d-tamper-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: PolicyDTestAnchorAuthority())
    try store.begin(run: projected)

    let url = store.storageURL(
      contractID: projected.contractID,
      goalID: projected.goalID,
      runID: projected.id)
    var line = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url))
        as? [String: Any])
    var seed = try XCTUnwrap(line["seed"] as? [String: Any])
    var storedRun = try XCTUnwrap(seed["run"] as? [String: Any])
    var branches = try XCTUnwrap(
      storedRun["branchGoals"] as? [[String: Any]])
    let index = try XCTUnwrap(
      branches.firstIndex {
        ($0["reason"] as? String)?
          .localizedCaseInsensitiveContains("unsupported domain") == true
      })
    branches[index]["reason"] =
      "unsupported domain：tampered reason with preserved blocked shape"
    storedRun["branchGoals"] = branches
    seed["run"] = storedRun
    line["seed"] = seed
    var tampered = try JSONSerialization.data(withJSONObject: line)
    tampered.append(0x0A)
    try tampered.write(to: url, options: .atomic)

    XCTAssertThrowsError(
      try store.replay(
        contractID: projected.contractID,
        goalID: projected.goalID,
        runID: projected.id)
    ) { error in
      XCTAssertEqual(
        error as? TatwoPLGChainStoreError,
        .invalidSeed)
    }
  }

  func testSameDomainAndTitleDifferentLoopInstancesHaveDistinctDomainLoopIDs() throws {
    let base = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D loop identity")
    let loops = [
      domainLoop(id: "loop-code-instance-a", title: "Same title"),
      domainLoop(id: "loop-code-instance-b", title: "Same title")
    ]
    let contract = replacing(base, domainLoops: loops)

    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)

    XCTAssertEqual(projected.branchGoals.count, 2)
    XCTAssertEqual(Set(projected.branchGoals.compactMap(\.sourceLoopID)).count, 2)
    XCTAssertEqual(Set(projected.branchGoals.compactMap(\.domainLoopID)).count, 2)
  }

  func testDuplicateSourceAndGeneratedIDsAreBlockedBeforeReporting() throws {
    let base = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D duplicate loop identity")
    let duplicateID = "loop-code-duplicate"
    let contract = replacing(
      base,
      domainLoops: [
        domainLoop(id: duplicateID, title: "First"),
        domainLoop(id: duplicateID, title: "Second")
      ])

    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)

    XCTAssertEqual(projected.branchGoals.count, 2)
    XCTAssertTrue(projected.branchGoals.allSatisfy { $0.status == .blocked })
    XCTAssertTrue(projected.branchGoals.allSatisfy { !$0.reportedToMainline })
    XCTAssertTrue(
      projected.branchGoals.allSatisfy {
        $0.reason?.localizedCaseInsensitiveContains("duplicate source") == true
      })
  }

  func testGeneralXXLBuiltInDomainsAdvanceAndReplayPlanningEvent() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "general-xxl-fable5-sol",
      objective: "PLG built-in domain bridge")
    let projected = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)

    let expectedDomains = Set(
      contract.domainLoops
        .map(\.domain)
        .filter { $0 != .custom })
    XCTAssertTrue(expectedDomains.contains(.debug))
    XCTAssertEqual(
      Set(projected.branchGoals.compactMap { $0.domain?.workOSDomain }),
      expectedDomains)
    XCTAssertTrue(
      projected.branchGoals.allSatisfy {
        $0.reason?.localizedCaseInsensitiveContains("unsupported domain") != true
      })

    let transition = try TatwoPLGOrchestrator.advanceFromPlanning(
      projected,
      expectedRevision: projected.revision,
      eventID: UUID())
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-policy-d-planning-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: PolicyDTestAnchorAuthority())
    try store.begin(run: projected)

    let replayed = try store.append(
      transition: transition,
      from: projected)

    XCTAssertEqual(replayed.run.phase, .leadAdversarial)
    XCTAssertEqual(replayed.run.revision, 1)
    XCTAssertEqual(replayed.appliedEventIDs, [transition.event.eventID])
  }

  func testLegacyUnsupportedBuiltInProjectionMigratesBeforePlanningAdvance() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "general-xxl-fable5-sol",
      objective: "PLG legacy built-in domain migration")
    let canonical = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    var legacy = canonical
    for index in legacy.branchGoals.indices
      where legacy.branchGoals[index].domain == .debug
    {
      legacy.branchGoals[index].domain = nil
      legacy.branchGoals[index].status = .blocked
      legacy.branchGoals[index].reason =
        "unsupported domain：debug；loop 保留顯示但不可回報。"
    }
    let migrated = TatwoPLGPolicyDProjector.project(
      run: legacy,
      contract: contract,
      goalRecord: nil)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-policy-d-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: PolicyDTestAnchorAuthority())
    try store.begin(run: legacy)

    let migration = try TatwoPLGOrchestrator.migratePlanningProjection(
      to: migrated.branchGoals,
      in: legacy,
      expectedRevision: legacy.revision,
      eventID: UUID())
    let migratedReplay = try store.append(
      transition: migration,
      from: legacy)
    let advance = try TatwoPLGOrchestrator.advanceFromPlanning(
      migratedReplay.run,
      expectedRevision: migratedReplay.run.revision,
      eventID: UUID())
    let advancedReplay = try store.append(
      transition: advance,
      from: migratedReplay.run)

    XCTAssertEqual(advancedReplay.run.phase, .leadAdversarial)
    XCTAssertEqual(advancedReplay.run.revision, 2)
    XCTAssertEqual(
      Set(advancedReplay.run.branchGoals.compactMap { $0.domain?.workOSDomain }),
      Set(contract.domainLoops.map(\.domain)))
    XCTAssertEqual(
      advancedReplay.appliedEventIDs,
      [migration.event.eventID, advance.event.eventID])
  }

  func testPlanningProjectionMigrationRejectsBranchContentRewrite() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "general-xxl-fable5-sol",
      objective: "PLG migration content integrity")
    let canonical = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    var legacy = canonical
    let debugIndex = try XCTUnwrap(
      legacy.branchGoals.firstIndex { $0.domain == .debug })
    legacy.branchGoals[debugIndex].domain = nil
    legacy.branchGoals[debugIndex].status = .blocked
    legacy.branchGoals[debugIndex].reason =
      "unsupported domain：debug；loop 保留顯示但不可回報。"
    var rewritten = TatwoPLGPolicyDProjector.project(
      run: legacy,
      contract: contract,
      goalRecord: nil).branchGoals
    let migratedDebugIndex = try XCTUnwrap(
      rewritten.firstIndex {
        $0.sourceLoopID == legacy.branchGoals[debugIndex].sourceLoopID
      })
    rewritten[migratedDebugIndex].objective = "forged replacement objective"

    XCTAssertThrowsError(
      try TatwoPLGOrchestrator.migratePlanningProjection(
        to: rewritten,
        in: legacy,
        expectedRevision: legacy.revision,
        eventID: UUID())
    ) { error in
      XCTAssertEqual(error as? TatwoPLGError, .eventPayloadMismatch)
    }
  }

  func testProjectionRefreshIsIdempotentForUnchangedContract() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D unchanged refresh")
    let first = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    let second = TatwoPLGPolicyDProjector.project(
      run: first,
      contract: contract,
      goalRecord: nil)

    XCTAssertEqual(second, first)
    XCTAssertEqual(
      second.branchGoals.map(\.id),
      first.branchGoals.map(\.id))
  }

  func testProjectionRefreshInvalidatesOnlyChangedPlanIdentity() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D explicit replan")
    let first = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    let originalLoop = try XCTUnwrap(contract.domainLoops.first)
    let changedLoop = DomainLoop(
      id: originalLoop.id,
      domain: originalLoop.domain,
      title: "\(originalLoop.title) — revised",
      ownerIdentity: originalLoop.ownerIdentity,
      allowedTools: originalLoop.allowedTools,
      sandboxType: originalLoop.sandboxType,
      requiredReceipts: originalLoop.requiredReceipts,
      status: originalLoop.status,
      autonomyLevel: originalLoop.autonomyLevel,
      mergeBackRule: originalLoop.mergeBackRule,
      cycleIndex: originalLoop.cycleIndex + 1)
    let changedContract = replacing(
      contract,
      domainLoops: [changedLoop] + Array(contract.domainLoops.dropFirst()))
    let second = TatwoPLGPolicyDProjector.project(
      run: first,
      contract: changedContract,
      goalRecord: nil)
    let originalBranch = try XCTUnwrap(
      first.branchGoals.first { $0.sourceLoopID == originalLoop.id })
    let changedBranch = try XCTUnwrap(
      second.branchGoals.first { $0.sourceLoopID == changedLoop.id })

    XCTAssertNotEqual(changedBranch.id, originalBranch.id)
    XCTAssertNil(changedBranch.domainReceipt)
    XCTAssertFalse(changedBranch.reportedToMainline)
  }

  func testBindingReplacementInvalidatesPriorBranchAuthority() throws {
    let contract = try singleLoopContract(
      bindingID: "binding-a",
      requiredReceipts: [receiptRequirement(id: "receipt-a")])
    let verified = try verifiedPassingRun(for: contract)
    let original = try XCTUnwrap(verified.branchGoals.first)
    let replacement = WorkOSIdentityBinding(
      id: "binding-b",
      identity: .sub,
      label: "replacement sub",
      engineID: nil,
      modelID: "replacement-model",
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "replacement-slot",
      bindingRule: "replacement test")
    let changed = replacing(
      contract,
      identityBindings:
        contract.identityBindings.filter { $0.identity == .lead }
        + [replacement])

    let projected = TatwoPLGPolicyDProjector.project(
      run: verified,
      contract: changed,
      goalRecord: nil)
    let branch = try XCTUnwrap(projected.branchGoals.first)

    XCTAssertEqual(branch.subBindingID, replacement.id)
    XCTAssertNotEqual(branch.id, original.id)
    XCTAssertNil(branch.domainReceipt)
    XCTAssertFalse(branch.reportedToMainline)
    XCTAssertFalse(
      TatwoPLGOrchestrator.branchPresentation(
        for: branch,
        in: projected).isVerifiedPass)
  }

  func testRequiredReceiptPolicyChangeInvalidatesPriorBranchAuthority() throws {
    let contract = try singleLoopContract(
      bindingID: "binding-receipt-policy",
      requiredReceipts: [receiptRequirement(id: "receipt-old")])
    let verified = try verifiedPassingRun(for: contract)
    let original = try XCTUnwrap(verified.branchGoals.first)
    let loop = try XCTUnwrap(contract.domainLoops.first)
    let changedLoop = DomainLoop(
      id: loop.id,
      domain: loop.domain,
      title: loop.title,
      ownerIdentity: loop.ownerIdentity,
      allowedTools: loop.allowedTools,
      sandboxType: loop.sandboxType,
      requiredReceipts: [receiptRequirement(id: "receipt-new")],
      status: loop.status,
      autonomyLevel: loop.autonomyLevel,
      mergeBackRule: loop.mergeBackRule,
      cycleIndex: loop.cycleIndex)
    let changed = replacing(contract, domainLoops: [changedLoop])

    let projected = TatwoPLGPolicyDProjector.project(
      run: verified,
      contract: changed,
      goalRecord: nil)
    let branch = try XCTUnwrap(projected.branchGoals.first)

    XCTAssertNotEqual(branch.id, original.id)
    XCTAssertNotEqual(branch.planSlice, original.planSlice)
    XCTAssertNil(branch.domainReceipt)
    XCTAssertFalse(branch.reportedToMainline)
  }

  func testDuplicateLoopsCannotReuseVerifiedMemberIdentity() throws {
    let contract = try singleLoopContract(
      bindingID: "binding-duplicate",
      requiredReceipts: [receiptRequirement(id: "receipt-duplicate")])
    let verified = try verifiedPassingRun(for: contract)
    let loop = try XCTUnwrap(contract.domainLoops.first)
    let duplicated = replacing(contract, domainLoops: [loop, loop])

    let projected = TatwoPLGPolicyDProjector.project(
      run: verified,
      contract: duplicated,
      goalRecord: nil)

    XCTAssertEqual(projected.branchGoals.count, 2)
    XCTAssertEqual(Set(projected.branchGoals.map(\.id)).count, 2)
    XCTAssertTrue(projected.branchGoals.allSatisfy { $0.status == .blocked })
    XCTAssertTrue(projected.branchGoals.allSatisfy { $0.domainReceipt == nil })
    XCTAssertTrue(
      projected.branchGoals.allSatisfy {
        !TatwoPLGOrchestrator.branchPresentation(
          for: $0,
          in: projected).isVerifiedPass
      })
  }

  private func projectionMap(
    _ run: TatwoPLGRun
  ) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: run.branchGoals.compactMap { branch in
        guard let sourceLoopID = branch.sourceLoopID else { return nil }
        return (
          sourceLoopID,
          [
            branch.subBindingID,
            branch.domainLoopID ?? "",
            branch.status.rawValue,
            branch.reason ?? ""
          ].joined(separator: "|"))
      })
  }

  private func run(for contract: TatwoWorkOSContractV1) -> TatwoPLGRun {
    TatwoPLGRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      revision: 0,
      phase: .planning,
      leadBindings: contract.identityBindings.filter { $0.identity == .lead },
      subBindings: contract.identityBindings.filter { $0.identity != .lead },
      planSummary: contract.objective,
      adversarialConclusion: nil,
      humanAuth: nil,
      branchGoals: [],
      mainlineGoalMet: nil)
  }

  private func storedGoal(
    for contract: TatwoWorkOSContractV1,
    receiptIDs: Set<String>
  ) -> TatwoStoredGoalRun {
    TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      status: .running,
      receipts: receiptIDs.sorted().map {
        TatwoStoredReceipt(
          receiptID: $0,
          kind: "domain_loop",
          loopID: contract.mainlineLoop.id)
      })
  }

  private func domainLoop(
    id: String,
    title: String
  ) -> DomainLoop {
    DomainLoop(
      id: id,
      domain: .code,
      title: title,
      ownerIdentity: .sub,
      allowedTools: [],
      sandboxType: .tempWorkspace,
      requiredReceipts: [],
      status: .planned,
      autonomyLevel: "test",
      mergeBackRule: "test")
  }

  private func singleLoopContract(
    bindingID: String,
    requiredReceipts: [WorkOSReceiptRequirement]
  ) throws -> TatwoWorkOSContractV1 {
    let generated = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "Policy D authority invalidation")
    let lead = try XCTUnwrap(
      generated.identityBindings.first { $0.identity == .lead })
    let sub = WorkOSIdentityBinding(
      id: bindingID,
      identity: .sub,
      label: bindingID,
      engineID: nil,
      modelID: "model-\(bindingID)",
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "slot-\(bindingID)",
      bindingRule: "policy D test")
    let loop = DomainLoop(
      id: "loop-policy-d-authority",
      domain: .code,
      title: "Policy D authority branch",
      ownerIdentity: .sub,
      allowedTools: ["swift-test"],
      sandboxType: .tempWorkspace,
      requiredReceipts: requiredReceipts,
      status: .planned,
      autonomyLevel: "test",
      mergeBackRule: "return to lead")
    return replacing(
      generated,
      domainLoops: [loop],
      identityBindings: [lead, sub])
  }

  private func receiptRequirement(
    id: String
  ) -> WorkOSReceiptRequirement {
    WorkOSReceiptRequirement(
      id: id,
      title: id,
      kind: "test",
      requiredForPass: true,
      plainPurpose: "Policy identity test")
  }

  private func verifiedPassingRun(
    for contract: TatwoWorkOSContractV1
  ) throws -> TatwoPLGRun {
    var initial = TatwoPLGPolicyDProjector.project(
      run: run(for: contract),
      contract: contract,
      goalRecord: nil)
    initial.phase = .executingLoops
    initial.humanAuth = TatwoPLGHumanAuthReceipt(
      receiptID: "policy-d-test-human-auth",
      actor: "human",
      issuedISO: "2026-07-15T14:00:00Z",
      expiresISO: "2026-07-15T16:00:00Z",
      scope: "execute",
      contractID: contract.contractID)
    let branch = try XCTUnwrap(initial.branchGoals.first)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-policy-d-chain-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: PolicyDTestAnchorAuthority())
    try store.begin(run: initial)
    let tests = ["swift test --filter TatwoPLGPolicyDProjectorTests"]
    let receipt = TatwoPLGDomainReceipt(
      domainLoopID: try XCTUnwrap(branch.domainLoopID),
      objectiveHash: TatwoObjectiveIdentity.make(branch.objective).objectiveHash,
      inputsDigest: TatwoArtifactReviewHasher.sha256(
        try XCTUnwrap(branch.planSlice)),
      artifactsDigest: TatwoPLGOrchestrator.makeArtifactsDigest(
        testsRun: tests),
      verdict: .pass,
      testsRun: tests)
    let transition = try TatwoPLGOrchestrator.reportBranch(
      id: branch.id,
      status: .passed,
      reason: nil,
      domainReceipt: receipt,
      nowISO: "2026-07-15T15:00:00Z",
      in: initial,
      expectedRevision: initial.revision,
      eventID: UUID())
    return try store.append(
      transition: transition,
      from: initial).run
  }

  private func replacing(
    _ contract: TatwoWorkOSContractV1,
    domainLoops: [DomainLoop]? = nil,
    identityBindings: [WorkOSIdentityBinding]? = nil
  ) -> TatwoWorkOSContractV1 {
    TatwoWorkOSContractV1(
      schema: contract.schema,
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      goalCyclePolicy: contract.goalCyclePolicy,
      planLoopGoalProtocol: contract.planLoopGoalProtocol,
      goalRun: contract.goalRun,
      loopGovernorDecision: contract.loopGovernorDecision,
      mainlineLoop: contract.mainlineLoop,
      domainLoops: domainLoops ?? contract.domainLoops,
      identityBindings: identityBindings ?? contract.identityBindings,
      sandboxPolicy: contract.sandboxPolicy,
      receiptRequirements: contract.receiptRequirements,
      stopRules: contract.stopRules,
      showLoopsProjection: contract.showLoopsProjection,
      configStage: contract.configStage,
      gatewayRouteReservations: contract.gatewayRouteReservations,
      nextAction: contract.nextAction,
      failClosedRules: contract.failClosedRules)
  }
}

private struct PolicyDTestAnchorAuthority: TatwoPLGAnchorAuthority {
  func sign(_ material: String) throws -> String {
    TatwoArtifactReviewHasher.sha256("policy-d-test|\(material)")
  }

  func verify(_ signature: String, material: String) throws -> Bool {
    signature == (try sign(material))
  }
}

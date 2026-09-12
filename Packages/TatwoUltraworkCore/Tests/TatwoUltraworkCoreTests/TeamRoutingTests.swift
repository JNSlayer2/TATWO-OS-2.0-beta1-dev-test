import XCTest

@testable import TatwoUltraworkCore

final class TeamRoutingTests: XCTestCase {
  func testModelTraitTableContainsReadableStrengthsAndWeaknesses() throws {
    let traits = TeamRoutingCatalog.modelTraits
    let ids = Set(traits.map(\.id))

    XCTAssertTrue(ids.contains("gpt-5.5"))
    XCTAssertTrue(ids.contains("opus-5"))
    XCTAssertTrue(ids.contains("sonnet-5"))
    XCTAssertTrue(ids.contains("minimax-m3"))
    XCTAssertTrue(ids.contains("grok-build"))
    XCTAssertTrue(ids.contains("chatgpt-pro-mcp"))

    let gpt = try XCTUnwrap(traits.first { $0.id == "gpt-5.5" })
    XCTAssertTrue(gpt.strengths.contains { $0.contains("主控") || $0.contains("架構") })
    XCTAssertTrue(gpt.weaknesses.contains { $0.contains("UI") || $0.contains("過度保守") })
    XCTAssertGreaterThanOrEqual(gpt.scores.coding, 4)

    let sonnet = try XCTUnwrap(traits.first { $0.id == "sonnet-5" })
    XCTAssertGreaterThanOrEqual(sonnet.scores.coding, 5)
    XCTAssertGreaterThanOrEqual(sonnet.scores.reviewStrictness, 5)
    XCTAssertEqual(sonnet.defaultAuthority, .patchProposal)
    XCTAssertFalse(sonnet.canDirectlyMutateHost)
    XCTAssertTrue(sonnet.bestRoles.contains { $0.contains("工程") || $0.contains("測試") })

    let minimax = try XCTUnwrap(traits.first { $0.id == "minimax-m3" })
    XCTAssertGreaterThanOrEqual(minimax.scores.bulkThroughput, 5)
    XCTAssertLessThanOrEqual(minimax.scores.reviewStrictness, 3)
    XCTAssertFalse(minimax.canDirectlyMutateHost)
  }

  func testTraitScoringStandardBoardContainsRequestedDimensions() throws {
    let dimensions = TatwoIdentityCatalog.traitDimensions
    let titles = Set(dimensions.map(\.title))

    XCTAssertEqual(dimensions.count, 24)
    XCTAssertTrue(titles.contains("代碼架構工整"))
    XCTAssertTrue(titles.contains("代碼語法一致性"))
    XCTAssertTrue(titles.contains("任務宏觀架構理解"))
    XCTAssertTrue(titles.contains("幻覺度控制"))
    XCTAssertTrue(titles.contains("Token 消耗"))
    XCTAssertTrue(titles.contains("多模協作能力"))
    XCTAssertTrue(titles.contains("3D建模與空間比例"))
    XCTAssertTrue(titles.contains("整合資訊與預判能力"))
    XCTAssertTrue(titles.contains("圓融度"))
  }

  func testEveryModelTraitExplainsFailureModeAndVerificationRule() throws {
    for trait in TeamRoutingCatalog.modelTraits {
      XCTAssertFalse(
        trait.plainFailureMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "\(trait.id) must explain where it fails")
      XCTAssertFalse(
        trait.verificationRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "\(trait.id) must explain how Tatwo verifies it")
      XCTAssertFalse(
        trait.verificationRule.contains("自己說了算"), "\(trait.id) verification cannot be self-approval"
      )
      XCTAssertFalse(
        trait.calibrationNotes.isEmpty, "\(trait.id) must carry observed collaboration calibration")
      XCTAssertTrue(
        trait.calibrationNotes.allSatisfy {
          !$0.observedPattern.isEmpty && !$0.routingImplication.isEmpty
        }, "\(trait.id) calibration notes must map observation to routing")
    }

    let gpt = try XCTUnwrap(TeamRoutingCatalog.modelTraits.first { $0.id == "gpt-5.5" })
    XCTAssertTrue(gpt.plainFailureMode.contains("UI") || gpt.plainFailureMode.contains("保守"))
    XCTAssertTrue(gpt.verificationRule.contains("截圖") || gpt.verificationRule.contains("visual"))
    XCTAssertTrue(
      gpt.calibrationNotes.contains {
        $0.observedPattern.contains("UI") && $0.routingImplication.contains("visual gate")
      })

    let grok = try XCTUnwrap(TeamRoutingCatalog.modelTraits.first { $0.id == "grok-build" })
    XCTAssertTrue(grok.verificationRule.contains("來源") || grok.verificationRule.contains("交叉"))
    XCTAssertTrue(
      grok.calibrationNotes.contains {
        $0.routingImplication.contains("news scout") || $0.routingImplication.contains("反方")
      })
  }

  func testDesignScenarioRecommendsDesignTeamWithVisualGate() throws {
    let recommendation = TeamRoutingCatalog.recommend(mode: .l, scenario: .design)

    XCTAssertEqual(recommendation.schema, "TatwoTeamRecommendationV1")
    XCTAssertEqual(recommendation.leadStrategy.leadModelID, "opus-5")
    XCTAssertEqual(recommendation.primaryTeam.id, "design-team")
    XCTAssertTrue(recommendation.primaryTeam.gates.contains { $0.id == "visual-proof" })
    XCTAssertTrue(recommendation.workflowLoops.contains { $0.id == "visual-loop" })
    XCTAssertTrue(
      recommendation.requiredGates.contains { $0.contains("截圖") || $0.contains("visual") })
  }

  func testDesignTeamDefinesRoleBoundariesThatPreventSelfApproval() throws {
    let designTeam = try XCTUnwrap(TeamRoutingCatalog.teams.first { $0.id == "design-team" })

    XCTAssertTrue(
      designTeam.roleBoundaries.contains {
        $0.roleName == "主控" && $0.owner.contains("GPT") && $0.owner.contains("Opus")
          && $0.cannotDo.contains { $0.contains("final pass") || $0.contains("驗收") }
      })
    XCTAssertTrue(
      designTeam.roleBoundaries.contains {
        $0.roleName == "Scout" && $0.owner.contains("MiniMax")
          && $0.cannotDo.contains { $0.contains("judge") || $0.contains("裁決") }
      })
    XCTAssertTrue(
      designTeam.roleBoundaries.contains {
        $0.roleName == "Verifier"
          && $0.evidenceBeforePass.contains { $0.contains("截圖") || $0.contains("visual diff") }
      })
    XCTAssertTrue(
      designTeam.roleBoundaries.contains {
        $0.roleName == "Judge" && $0.owner.contains("Opus")
          && $0.cannotDo.contains { $0.contains("自己實作") || $0.contains("build") }
      })
  }

  func testCodingScenarioRecommendsCodeTeamAndSeparatesExecutorReviewerJudge() throws {
    let recommendation = TeamRoutingCatalog.recommend(mode: .xl, scenario: .coding)
    let team = recommendation.primaryTeam

    XCTAssertEqual(team.id, "code-team")
    XCTAssertTrue(team.members.contains { $0.modelID == "gpt-5.5" && $0.teamRole.contains("主控") })
    XCTAssertTrue(
      team.members.contains { $0.modelID == "sonnet-5" && $0.teamRole.contains("審稿") })
    XCTAssertTrue(team.members.contains { $0.modelID == "opus-5" && $0.canFinalJudge })
    XCTAssertTrue(team.gates.contains { $0.id == "test-proof" })
  }

  func testTradingTeamIsReadOnlyAndRequiresRiskGate() throws {
    let recommendation = TeamRoutingCatalog.recommend(mode: .l, scenario: .trading)

    XCTAssertEqual(recommendation.primaryTeam.id, "trading-risk-team")
    XCTAssertTrue(recommendation.primaryTeam.readOnlyByDefault)
    XCTAssertTrue(recommendation.primaryTeam.gates.contains { $0.id == "no-live-order" })
    XCTAssertTrue(recommendation.requiredGates.contains { $0.contains("不下單") || $0.contains("風控") })
  }

  func testNoTeamLetsExternalModelDirectlyMutateHost() throws {
    for team in TeamRoutingCatalog.teams {
      for member in team.members {
        XCTAssertFalse(
          member.canDirectlyMutateHost, "\(team.id)/\(member.modelID) must not mutate host directly"
        )
      }
    }
  }

  func testLAndXLRecommendationsAlwaysIncludeStabilityTeamAndLoop() throws {
    for mode in [WorkModeID.l, .xl] {
      for scenario in [ScenarioID.design, .coding, .daily, .modeling] {
        let recommendation = TeamRoutingCatalog.recommend(mode: mode, scenario: scenario)
        let allTeamIDs = Set(
          ([recommendation.primaryTeam] + recommendation.supportingTeams).map(\.id))

        XCTAssertTrue(
          allTeamIDs.contains("stability-team"),
          "\(mode.rawValue)/\(scenario.rawValue) must carry stability team")
        XCTAssertTrue(
          recommendation.workflowLoops.contains { $0.id == "stability-loop" },
          "\(mode.rawValue)/\(scenario.rawValue) must carry stability loop")
      }
    }
  }

  func testWorkflowLoopsDeclareReceiptsAndSandboxPolicy() throws {
    for team in TeamRoutingCatalog.teams {
      for loop in team.loops {
        XCTAssertFalse(
          loop.requiredReceipts.isEmpty, "\(team.id)/\(loop.id) must declare required receipts")
        XCTAssertTrue(
          loop.sandboxPolicy.contains("sandbox") || loop.sandboxPolicy.contains("只讀")
            || loop.sandboxPolicy.contains("不得"),
          "\(team.id)/\(loop.id) must explain sandbox/read-only policy")
        XCTAssertFalse(loop.stopCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  func testStabilityPlanHasCodexDisconnectAcceptanceChecks() throws {
    let plan = IntegrationPlanner.stabilityPlan()
    let guardIDs = Set(plan.guards.map(\.id))
    let ruleIDs = Set(plan.disconnectRules.map(\.id))

    XCTAssertTrue(
      guardIDs.isSuperset(of: [
        "single-provider", "provider-config-receipt", "semantic-sse", "body-cap",
        "app-binary-match", "auth-race", "rollback",
      ]))
    XCTAssertTrue(
      plan.guards.contains {
        $0.id == "provider-config-receipt"
          && $0.verification.contains("codex-model-provider-single-gateway")
      })
    XCTAssertTrue(
      ruleIDs.isSuperset(of: ["backend-notice", "timeouts", "client-cancel", "no-signed-patch"]))
    XCTAssertTrue(
      plan.disconnectRules.allSatisfy {
        !$0.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
  }

  func testMiniMaxIsBulkScoutButNeverFinalJudge() throws {
    for team in TeamRoutingCatalog.teams {
      for member in team.members where member.modelID == "minimax-m3" {
        XCTAssertTrue(member.canBulkScout)
        XCTAssertFalse(member.canFinalJudge)
      }
    }
  }

  func testLeadStrategiesExposeOpusAndGPTAsSeparateDecisionCenters() throws {
    let strategies = TeamRoutingCatalog.leadStrategies
    let ids = Set(strategies.map(\.id))

    XCTAssertTrue(ids.contains("opus-5-lead"))
    XCTAssertTrue(ids.contains("gpt-5.5-lead"))
    XCTAssertTrue(ids.contains("sonnet-5-lead"))
    XCTAssertFalse(strategies.contains { $0.leadModelID == "fable-5" })

    let opus = try XCTUnwrap(strategies.first { $0.id == "opus-5-lead" })
    XCTAssertTrue(opus.plainBestWhen.contains("UI") || opus.plainBestWhen.contains("高風險"))
    XCTAssertTrue(opus.companionEffects.contains { $0.modelID == "gpt-5.5" && $0.roleWhenPaired.contains("落地") })
    XCTAssertTrue(opus.companionEffects.contains { $0.modelID == "sonnet-5" })

    let gpt = try XCTUnwrap(strategies.first { $0.id == "gpt-5.5-lead" })
    XCTAssertTrue(gpt.plainTradeoff.contains("不能自我驗收") || gpt.plainTradeoff.contains("Opus"))
    XCTAssertTrue(gpt.companionEffects.contains { $0.modelID == "opus-5" && $0.roleWhenPaired.contains("驗收") })

    let sonnet = try XCTUnwrap(strategies.first { $0.id == "sonnet-5-lead" })
    XCTAssertEqual(sonnet.leadModelID, "sonnet-5")
    XCTAssertTrue(sonnet.modeFits.contains(.m))
    XCTAssertTrue(sonnet.companionEffects.contains { $0.modelID == "gpt-5.5" && $0.roleWhenPaired.contains("Codex") })
  }

  func testLeadStrategySwitchesByModeAndScenarioInsteadOfAlwaysGPT() throws {
    let mediumCoding = TeamRoutingCatalog.recommend(mode: .m, scenario: .coding)
    let xlCoding = TeamRoutingCatalog.recommend(mode: .xl, scenario: .coding)
    let trading = TeamRoutingCatalog.recommend(mode: .l, scenario: .trading)

    XCTAssertEqual(mediumCoding.leadStrategy.leadModelID, "gpt-5.5")
    let mediumDebugLead = TeamRoutingCatalog.leadStrategy(mode: .m, scenarioProfileID: "debug", scenario: .coding)
    XCTAssertEqual(mediumDebugLead.leadModelID, "sonnet-5")
    XCTAssertEqual(xlCoding.leadStrategy.leadModelID, "opus-5")
    XCTAssertEqual(trading.leadStrategy.leadModelID, "opus-5")
  }


  func testXLRecommendationsCanUseOpusAsLeadInsteadOfOnlyGPT() throws {
    let recommendation = TeamRoutingCatalog.recommend(mode: .xl, scenario: .coding)
    let teams = [recommendation.primaryTeam] + recommendation.supportingTeams
    let opusLeadTeam = try XCTUnwrap(teams.first { $0.id == "opus-review-team" })

    XCTAssertEqual(recommendation.leadStrategy.leadModelID, "opus-5")
    XCTAssertTrue(opusLeadTeam.members.contains { $0.modelID == "opus-5" && $0.teamRole.contains("主導") })
    XCTAssertTrue(
      opusLeadTeam.roleBoundaries.contains {
        $0.roleName.contains("Opus") && $0.owner.contains("Opus 5")
      })
    XCTAssertTrue(
      opusLeadTeam.forbidden.contains { $0.contains("GPT 固定唯一主導") })
  }

  func testGPTControllerIsNotSoleUIVerifier() throws {
    let designTeam = try XCTUnwrap(TeamRoutingCatalog.teams.first { $0.id == "design-team" })

    XCTAssertTrue(
      designTeam.members.contains { $0.modelID == "gpt-5.5" && $0.teamRole.contains("主控") })
    XCTAssertFalse(designTeam.gates.contains { $0.plainRule == "GPT says it looks good" })
    XCTAssertTrue(designTeam.gates.contains { $0.requiredEvidence.contains(.screenshot) })
  }


  func testFable5IsRatedButNotRoutedIntoCollaborationTeams() throws {
    let fable = try XCTUnwrap(TeamRoutingCatalog.modelTraits.first { $0.id == "fable-5" })

    XCTAssertEqual(fable.displayName, "Fable 5")
    XCTAssertTrue(fable.plainSummary.contains("已可"))
    XCTAssertTrue(fable.plainFailureMode.contains("工程"))
    XCTAssertTrue(fable.weaknesses.contains { $0.contains("成本高") })
    XCTAssertTrue(fable.calibrationNotes.contains { $0.id == "fable5-web-arena-v1-20260702" })
    XCTAssertFalse(
      TeamRoutingCatalog.teams.flatMap(\.members).contains { $0.modelID == "fable-5" })
  }

  func testTeamReadinessDashboardKeepsUIAndHostInstallClosed() throws {
    let dashboard = TeamRoutingCatalog.readinessDashboard(mode: .xl, scenario: .coding)

    XCTAssertEqual(dashboard.schema, "TatwoTeamReadinessDashboardV1")
    XCTAssertEqual(dashboard.leadStrategy.leadModelID, "opus-5")
    XCTAssertTrue(dashboard.availableLeadStrategies.contains { $0.leadModelID == "gpt-5.5" })
    XCTAssertTrue(dashboard.uiDeferred)
    XCTAssertFalse(dashboard.hostMutationAllowed)
    XCTAssertFalse(dashboard.hostInstallAllowed)
    XCTAssertGreaterThanOrEqual(dashboard.modelTraits.count, 6)

    let teamIDs = Set(dashboard.selectedTeams.map(\.team.id))
    XCTAssertTrue(teamIDs.contains("code-team"))
    XCTAssertTrue(teamIDs.contains("stability-team"))
    XCTAssertTrue(
      dashboard.scripts.contains { $0.id == "team-dashboard" && $0.hostMutationAllowed == false })
    XCTAssertTrue(
      dashboard.scripts.contains {
        $0.id == "sandbox-check" && $0.command.contains("tatwo-ultrawork-sandbox-check")
      })
    XCTAssertTrue(dashboard.failClosedRules.contains { $0.contains("reviewer_unavailable") })
  }

  func testDashboardReceiptsSeparateDryRunFromLiveHostProof() throws {
    let dashboard = TeamRoutingCatalog.readinessDashboard(mode: .xl, scenario: .design)

    let receiptIDs = Set(dashboard.receipts.map(\.id))
    XCTAssertTrue(
      receiptIDs.isSuperset(of: [
        "sandbox-validated",
        "host-sandbox-rehearsal",
        "host-backup",
        "rollback",
        "live-same-thread",
        "mcp-host-registration",
        "human-approval",
        "visual-proof",
      ]))

    let liveSmoke = try XCTUnwrap(dashboard.receipts.first { $0.id == "live-same-thread" })
    XCTAssertFalse(liveSmoke.dryRunCanSatisfy)
    XCTAssertTrue(liveSmoke.passRule.contains("same-thread-"))

    let mcpHost = try XCTUnwrap(dashboard.receipts.first { $0.id == "mcp-host-registration" })
    XCTAssertFalse(mcpHost.dryRunCanSatisfy)
    XCTAssertTrue(mcpHost.passRule.contains("mcp-host"))
    XCTAssertTrue(dashboard.failClosedRules.contains { $0.contains("mcp-stdio") })
  }

  func testCollaborationEvidenceSeedsKeepQualitativeHumanVerdicts() throws {
    let evidence = TeamRoutingCatalog.collaborationEvidence

    XCTAssertEqual(evidence.count, 3)
    XCTAssertTrue(evidence.allSatisfy { $0.schema == "TatwoCollabEvidenceV1" })
    XCTAssertTrue(evidence.allSatisfy { $0.source == .liveRunHumanVerdict })
    XCTAssertTrue(evidence.allSatisfy { $0.sourceLabel == "使用者實戰評價 2026-07-06" })
    XCTAssertTrue(evidence.allSatisfy { $0.date == "2026-07-06" })

    let pairTie = try XCTUnwrap(evidence.first { $0.id == "gpt55-sonnet5-vs-fable5-20260706" })
    XCTAssertEqual(pairTie.members.map(\.model), ["gpt-5.5", "sonnet-5"])
    XCTAssertEqual(pairTie.strongBaseline, "fable-5 單打")
    XCTAssertEqual(pairTie.weakBaseline, "gpt-5.5＋sonnet-5 協作")
    XCTAssertEqual(pairTie.qualitativeVerdict, "持平")
    XCTAssertEqual(pairTie.deltaDirection, .flat)
    XCTAssertTrue(pairTie.note.contains("持平"))

    let soloWins = try XCTUnwrap(evidence.first { $0.id == "solo-beats-multimodel-20260706" })
    XCTAssertEqual(soloWins.strongBaseline, "fable-5 單打 與 gpt-5.5 單打")
    XCTAssertEqual(soloWins.weakBaseline, "多模型協作")
    XCTAssertEqual(soloWins.qualitativeVerdict, "單打勝")
    XCTAssertEqual(soloWins.deltaDirection, .negative)
    XCTAssertTrue(soloWins.note.contains("多模型協作為紅 delta"))

    let fableLead = try XCTUnwrap(evidence.first { $0.id == "fable5-lead-gpt55-loops-xl-ui-20260706" })
    XCTAssertEqual(fableLead.members.map(\.role), ["主審", "loops 執行"])
    XCTAssertEqual(fableLead.taskClass, "XL UI 16點改造實戰 2026-07-06")
    XCTAssertEqual(fableLead.qualitativeVerdict, "高滿意")
    XCTAssertEqual(fableLead.deltaDirection, .positive)
  }

  func testCollaborationEvidenceDocumentsManualOverExamPriority() throws {
    XCTAssertEqual(TeamRoutingCatalog.collaborationEvidencePriority, ["人工", "考場"])
    XCTAssertTrue(
      TeamRoutingCatalog.collaborationEvidenceUIActionLabel.contains("+人工評分"),
      "Traits UI must keep the same manual-add action wording as trait evidence")
  }
}

import XCTest

@testable import TatwoUltraworkCore

final class HostPreparationTests: XCTestCase {
  func testHostPreflightTemplateIsReadOnlyAndCoversDisconnectRisks() throws {
    let report = HostPreparationFactory.preflightTemplate()

    XCTAssertEqual(report.schema, "TatwoHostPreflightV1")
    XCTAssertTrue(report.readOnly)
    XCTAssertFalse(report.hostMutationAllowed)
    XCTAssertTrue(report.deniedActions.contains { $0.contains("signed Codex App bundle") })
    XCTAssertTrue(report.deniedActions.contains { $0.contains("LaunchAgent") })

    let checkIDs = Set(report.checks.map(\.id))
    XCTAssertTrue(checkIDs.contains("codex-app-bundle"))
    XCTAssertTrue(checkIDs.contains("codex-cli-path"))
    XCTAssertTrue(checkIDs.contains("node"))
    XCTAssertTrue(checkIDs.contains("swift"))
    XCTAssertTrue(checkIDs.contains("codex-model-provider-single-gateway"))
    XCTAssertTrue(checkIDs.contains("model-gateway-health"))
    XCTAssertTrue(checkIDs.contains("codex-app-server-version-source"))
    XCTAssertTrue(checkIDs.contains("fast-defaults"))
    XCTAssertTrue(checkIDs.contains("auto-compact-scope"))

    XCTAssertTrue(report.requiredBeforeHostInstall.contains("host backup receipt"))
    XCTAssertTrue(report.requiredBeforeHostInstall.contains("live same-thread smoke receipt"))
    XCTAssertTrue(report.requiredBeforeHostInstall.contains("host MCP registration smoke receipt"))

    let fast = try XCTUnwrap(report.checks.first { $0.id == "fast-defaults" })
    XCTAssertTrue(fast.verificationHint.contains("service_tier=fast"))
    XCTAssertTrue(fast.verificationHint.contains("不作 Tatwo host install blocker"))
    let provider = try XCTUnwrap(
      report.checks.first { $0.id == "codex-model-provider-single-gateway" })
    XCTAssertTrue(provider.verificationHint.contains("model_provider=model_gateway"))
    XCTAssertTrue(provider.plainWhyItMatters.contains("同 thread"))
  }

  func testBackupPlanIsDryRunByDefaultAndNeverCopiesAuthMaterial() throws {
    let plan = HostPreparationFactory.backupPlan()

    XCTAssertEqual(plan.schema, "TatwoHostBackupPlanV1")
    XCTAssertTrue(plan.dryRun)
    XCTAssertFalse(plan.hostMutationAllowed)
    XCTAssertTrue(plan.humanApprovalRequiredForConfirm)

    let targetIDs = Set(plan.targets.map(\.id))
    XCTAssertTrue(targetIDs.contains("codex-config"))
    XCTAssertTrue(targetIDs.contains("codex-state-db"))
    XCTAssertTrue(targetIDs.contains("codex-models-cache"))
    XCTAssertTrue(targetIDs.contains("codex-global-state"))
    XCTAssertTrue(targetIDs.contains("gateway-launchagent-plist"))

    let commandText = (plan.copyCommands + plan.restoreCommands).joined(separator: "\n")
      .lowercased()
    XCTAssertFalse(commandText.contains("auth.json"))
    XCTAssertFalse(commandText.contains("refresh_token"))
    XCTAssertFalse(commandText.contains("access_token"))
    XCTAssertFalse(commandText.contains("api_key"))
    XCTAssertTrue(plan.deniedContent.contains { $0.contains("auth.json") })
    XCTAssertTrue(plan.deniedContent.contains { $0.contains("raw logs") })
  }

  func testLiveSmokePlanRequiresSameThreadAndMCPRegistrationReceipts() throws {
    let smoke = HostPreparationFactory.liveSmokePlan()

    XCTAssertEqual(smoke.schema, "TatwoHostLiveSmokePlanV1")
    XCTAssertFalse(smoke.hostMutationAllowed)
    XCTAssertTrue(smoke.mustRunAfterBackup)
    XCTAssertTrue(smoke.requiredReceipts.contains("gateway same-thread smoke receipt"))
    XCTAssertTrue(smoke.requiredReceipts.contains("host MCP registration smoke receipt"))
    XCTAssertTrue(smoke.requiredReceipts.contains("doctor --json receipt"))
    XCTAssertTrue(
      smoke.commands.contains { $0.contains("post-update-check") && $0.contains("--full") })
    XCTAssertTrue(smoke.commands.contains { $0.contains("tatwo-host-readiness-gate") })
  }

  func testHostInstallGateFailsClosedUntilAllReceiptsExist() throws {
    let missingRehearsal = HostPreparationFactory.evaluateHostInstall(
      receipts: HostInstallReceiptSet(
        sandboxValidated: true,
        preflightClear: true,
        humanApprovalReceiptID: "human-approval-20260622",
        backupReceiptID: "backup-1234567890ab",
        liveSameThreadSmokeReceiptID: "same-thread-1234567890ab",
        mcpRegistrationSmokeReceiptID: "mcp-host-1234567890ab",
        rollbackReceiptID: "rollback-1234567890ab"
      ))

    XCTAssertFalse(missingRehearsal.hostInstallAllowed)
    XCTAssertTrue(missingRehearsal.blockedBy.contains("host_sandbox_rehearsal_not_observed"))

    let missing = HostPreparationFactory.evaluateHostInstall(
      receipts: HostInstallReceiptSet(
        sandboxValidated: true,
        hostSandboxRehearsalReceiptID: "rehearsal-1234567890ab",
        preflightClear: true,
        humanApprovalReceiptID: "human-approval-20260622",
        backupReceiptID: nil,
        liveSameThreadSmokeReceiptID: nil,
        mcpRegistrationSmokeReceiptID: nil,
        rollbackReceiptID: nil
      ))

    XCTAssertEqual(missing.schema, "TatwoHostInstallGateDecisionV1")
    XCTAssertFalse(missing.hostInstallAllowed)
    XCTAssertFalse(missing.hostMutationPerformed)
    XCTAssertTrue(missing.blockedBy.contains("host_backup_not_observed"))
    XCTAssertTrue(missing.blockedBy.contains("live_same_thread_smoke_not_observed"))
    XCTAssertTrue(missing.nextActions.contains { $0.contains("sandbox") || $0.contains("dry-run") })
  }

  func testHostInstallGateOnlyAllowsAfterReceiptsButStillDoesNotMutate() throws {
    let allowed = HostPreparationFactory.evaluateHostInstall(
      receipts: HostInstallReceiptSet(
        sandboxValidated: true,
        hostSandboxRehearsalReceiptID: "rehearsal-1234567890ab",
        preflightClear: true,
        humanApprovalReceiptID: "human-approval-20260622",
        backupReceiptID: "backup-abcdef123456",
        liveSameThreadSmokeReceiptID: "same-thread-abcdef123456",
        mcpRegistrationSmokeReceiptID: "mcp-host-abcdef123456",
        rollbackReceiptID: "rollback-abcdef123456"
      ))

    XCTAssertTrue(allowed.hostInstallAllowed)
    XCTAssertFalse(allowed.hostMutationPerformed)
    XCTAssertTrue(allowed.blockedBy.isEmpty)
    XCTAssertTrue(allowed.plainSummary.contains("沒有執行任何主機修改"))
  }

  func testHostInstallGateRejectsForgedOrCompatibilityOnlyReceiptIDs() throws {
    let forged = HostPreparationFactory.evaluateHostInstall(
      receipts: HostInstallReceiptSet(
        sandboxValidated: true,
        hostSandboxRehearsalReceiptID: "rehearsal-ok",
        preflightClear: true,
        humanApprovalReceiptID: "human-ok",
        backupReceiptID: "backup-ok",
        liveSameThreadSmokeReceiptID: "same-thread-ok",
        mcpRegistrationSmokeReceiptID: "mcp-stdio-1234567890ab",
        rollbackReceiptID: "rollback-ok"
      ))

    XCTAssertFalse(forged.hostInstallAllowed)
    XCTAssertTrue(forged.blockedBy.contains("invalid_host_sandbox_rehearsal_receipt"))
    XCTAssertTrue(forged.blockedBy.contains("invalid_host_backup_receipt"))
    XCTAssertTrue(forged.blockedBy.contains("invalid_live_same_thread_smoke_receipt"))
    XCTAssertTrue(forged.blockedBy.contains("invalid_mcp_registration_smoke_receipt"))
    XCTAssertTrue(forged.blockedBy.contains("invalid_rollback_receipt"))
    XCTAssertTrue(forged.plainSummary.contains("收據不像正確來源"))
  }

  func testHostInstallReceiptIDsAreRedacted() throws {
    let fakeToken = "sk-" + "abc1234567890"
    let receipts = HostInstallReceiptSet(
      sandboxValidated: true,
      hostSandboxRehearsalReceiptID: "rehearsal-1234567890ab",
      preflightClear: true,
      humanApprovalReceiptID: "/Users/example/.codex/auth.json \(fakeToken)",
      backupReceiptID: "/Volumes/ExampleData/private/backup",
      liveSameThreadSmokeReceiptID: "Authorization: " + "Bearer " + "abcdefghijklmnopqrstuvwxyz",
      mcpRegistrationSmokeReceiptID: "mcp-ok",
      rollbackReceiptID: "rollback-ok"
    )

    let text = try String(data: JSONEncoder().encode(receipts), encoding: .utf8).unwrapped()
    XCTAssertFalse(text.contains("/Users/"))
    XCTAssertFalse(text.contains("/Volumes/"))
    XCTAssertFalse(text.contains("auth.json"))
    XCTAssertFalse(text.contains("sk-abc"))
    XCTAssertFalse(text.contains("Bearer abc"))
  }

  func testHostReceiptFlowExplainsConcreteReceiptsAndKeepsGateClosed() throws {
    let flow = HostPreparationFactory.receiptFlow()

    XCTAssertEqual(flow.schema, "TatwoHostReceiptFlowV1")
    XCTAssertFalse(flow.hostMutationDefault)
    XCTAssertTrue(flow.hostInstallGateIsOnlyDecision)

    let phaseIDs = Set(flow.phases.map(\.id))
    XCTAssertTrue(
      phaseIDs.isSuperset(of: [
        "sandbox-evidence",
        "host-readonly-preflight",
        "host-sandbox-rehearsal",
        "backup-and-rollback",
        "host-smoke",
        "human-gated-install",
      ]))

    let receiptIDs = Set(flow.receiptSpecs.map(\.id))
    XCTAssertTrue(
      receiptIDs.isSuperset(of: [
        "sandbox-validated",
        "host-sandbox-rehearsal",
        "preflight-clear",
        "human-approval",
        "host-backup",
        "same-thread-smoke",
        "mcp-registration-smoke",
        "rollback",
      ]))

    XCTAssertTrue(
      flow.phases.filter { $0.id != "human-gated-install" }.allSatisfy { !$0.mayMutateHost })
    XCTAssertTrue(
      flow.phases.first { $0.id == "human-gated-install" }?.commands.contains {
        $0.contains("host install-gate")
      } == true)
    XCTAssertTrue(flow.receiptSpecs.allSatisfy { $0.blocksHostInstallIfMissing })
    XCTAssertTrue(flow.receiptSpecs.allSatisfy { !$0.cannotContain.isEmpty })
    XCTAssertTrue(flow.stabilityRules.contains { $0.contains("response.in_progress") })
    XCTAssertTrue(
      flow.stabilityRules.contains { $0.contains("不 patch") || $0.contains("signed App") })
    let mcpSpec = try XCTUnwrap(flow.receiptSpecs.first { $0.id == "mcp-registration-smoke" })
    XCTAssertTrue(mcpSpec.acceptedEvidence.contains { $0.contains("mcp-host") })
    XCTAssertTrue(
      mcpSpec.acceptedEvidence.contains { $0.contains("hostRegistrationObserved=true") })
  }
}

extension Optional where Wrapped == String {
  fileprivate func unwrapped(file: StaticString = #filePath, line: UInt = #line) throws -> String {
    guard let self else {
      XCTFail("Expected non-nil string", file: file, line: line)
      throw NSError(domain: "HostPreparationTests", code: 1)
    }
    return self
  }
}

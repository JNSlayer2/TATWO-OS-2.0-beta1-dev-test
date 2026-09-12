import XCTest

@testable import TatwoUltraworkCore

final class OperationalReceiptGateTests: XCTestCase {
  func testHostLiveGoodReceiptPassesOnlyWithRightClassOriginModeAndTerminalEvent() throws {
    let sample = OperationalReceiptSample.make(.hostLiveGood)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .passed, report.reasons.joined(separator: ","))
    XCTAssertTrue(report.hostInstallEvidenceAllowed)
  }

  func testDryRunCannotSatisfyHostLiveSmoke() throws {
    let sample = OperationalReceiptSample.make(.dryRunHostLive)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertTrue(report.reasons.contains("dry_run_cannot_satisfy_host_live"))
    XCTAssertTrue(report.reasons.contains("host_live_required"))
  }

  func testStdioFakeHostCannotSatisfyHostMCPRegistration() throws {
    let sample = OperationalReceiptSample.make(.stdioFakeHost)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertTrue(report.reasons.contains("wrong_transport:mcp_stdio"))
    XCTAssertTrue(report.reasons.contains("mcp_stdio_not_host_registration"))
    XCTAssertTrue(report.reasons.contains("mcp_server_self_report_cannot_prove_host_state"))
    XCTAssertTrue(report.reasons.contains("host_state_not_observed"))
  }

  func testPartialStreamCannotPassEvenIfItHasSameThreadLabels() throws {
    let sample = OperationalReceiptSample.make(.partialStream)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertTrue(report.reasons.contains("result_state_not_pass:partial"))
    XCTAssertTrue(report.reasons.contains("partial_stream_cannot_pass"))
    XCTAssertTrue(
      report.reasons.contains("terminal_event_not_completed:response.output_text.delta"))
  }

  func testDisconnectedAndTimeoutStyleReceiptsDoNotPass() throws {
    let sample = OperationalReceiptSample.make(.disconnected)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertTrue(report.reasons.contains("disconnect_cannot_pass"))
    XCTAssertTrue(report.reasons.contains("terminal_event_not_completed:disconnected"))
    XCTAssertTrue(report.reasons.contains("same_thread_continuity_not_observed"))
  }

  func testRetryStormOrCircuitOpenBlocksInstallEvidence() throws {
    let sample = OperationalReceiptSample.make(.retryStorm)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertTrue(report.reasons.contains("retry_storm_or_circuit_open"))
    XCTAssertTrue(report.reasons.contains("result_state_not_pass:circuit_open"))
  }

  func testOldApprovalEpochFailsAfterModelSwitch() throws {
    let sample = OperationalReceiptSample.make(.oldApprovalEpoch)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertTrue(report.reasons.contains("approval_epoch_stale_after_model_switch"))
    XCTAssertTrue(report.reasons.contains("approval_epoch_mismatch"))
  }

  func testModelTextCannotApproveHostInstall() throws {
    let sample = OperationalReceiptSample.make(.modelTextApproval)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertTrue(report.reasons.contains("wrong_evidence_origin:model_text"))
    XCTAssertTrue(report.reasons.contains("model_text_cannot_approve_install"))
  }

  func testModelTextCannotApproveEvenIfRequirementAccidentallyAllowsModelText() throws {
    let receipt = OperationalReceipt(
      id: "model-text-allowed-by-mistake",
      receiptClass: .humanApproval,
      evidenceOrigin: .modelText,
      executionMode: .hostReadOnly,
      transportKind: .none,
      resultState: .pass,
      terminalEvent: .none,
      approvalEffect: .hostInstall,
      operation: "model text claims approval",
      dryRun: false,
      approvalEpoch: 2,
      currentModelEpoch: 2
    )
    let permissiveRequirement = OperationalReceiptRequirement(
      id: "permissive-test",
      plainPurpose: "Regression: model text must never become host install approval.",
      allowedReceiptClasses: [.humanApproval],
      allowedOrigins: [.humanApproval, .modelText],
      allowedExecutionModes: [.hostReadOnly],
      allowedTransports: [.none],
      requiredApprovalEffect: .hostInstall,
      requiredApprovalEpoch: 2
    )
    let report = OperationalReceiptGate.evaluate(receipt, requirement: permissiveRequirement)

    XCTAssertEqual(report.status, .failed)
    XCTAssertFalse(report.hostInstallEvidenceAllowed)
    XCTAssertFalse(report.reasons.contains("wrong_evidence_origin:model_text"))
    XCTAssertTrue(report.reasons.contains("model_text_cannot_approve_install"))
  }

  func testApprovalEpochWithoutCurrentModelEpochFailsClosed() throws {
    let receipt = OperationalReceipt(
      id: "approval-epoch-without-current-model",
      receiptClass: .humanApproval,
      evidenceOrigin: .humanApproval,
      executionMode: .hostReadOnly,
      transportKind: .none,
      resultState: .pass,
      terminalEvent: .none,
      approvalEffect: .hostInstall,
      operation: "human approved but current model epoch is unknown",
      dryRun: false,
      approvalEpoch: 2,
      currentModelEpoch: nil
    )
    let report = OperationalReceiptGate.evaluate(
      receipt, requirement: .hostInstallApproval(requiredEpoch: 2))

    XCTAssertEqual(report.status, .failed)
    XCTAssertFalse(report.hostInstallEvidenceAllowed)
    XCTAssertTrue(report.reasons.contains("approval_epoch_current_model_unknown"))
    XCTAssertFalse(report.reasons.contains("approval_epoch_stale_after_model_switch"))
  }

  func testHostMCPGoodReceiptRequiresHostObservationNotSelfReport() throws {
    let sample = OperationalReceiptSample.make(.hostMCPGood)
    let report = OperationalReceiptGate.evaluate(sample.receipt, requirement: sample.requirement)

    XCTAssertEqual(report.status, .passed, report.reasons.joined(separator: ","))
    XCTAssertTrue(report.hostInstallEvidenceAllowed)
  }
}

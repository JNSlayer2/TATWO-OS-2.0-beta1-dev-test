import XCTest

@testable import TatwoUltraworkCore

final class ColimaSandboxTests: XCTestCase {
  func testMissingColimaIsOptionalAndDoesNotAllowHostMutation() throws {
    let missing: (String) -> String? = { _ in nil }
    let report = ColimaSandboxFactory.preflight(commandResolver: missing)

    XCTAssertEqual(report.schema, "TatwoColimaPreflightV1")
    XCTAssertFalse(report.available)
    XCTAssertEqual(report.status, .missing)
    XCTAssertEqual(report.severityIfMissing, .medium)
    XCTAssertFalse(report.hostMutationAllowed)
    XCTAssertFalse(report.autoInstallAllowed)
    XCTAssertFalse(report.autoStartAllowed)
    XCTAssertTrue(report.dryRunSupported)
    XCTAssertTrue(report.safetyRules.contains { $0.contains("not a model") || $0.contains("不是") })
  }

  func testDryRunReceiptRedactsPrivateMaterialAndDoesNotExecute() throws {
    let missing: (String) -> String? = { _ in nil }
    let fakeToken = "sk-" + "abc123456789012345"
    let receipt = ColimaSandboxFactory.makeReceipt(
      objective: "check /Users/example/.codex/auth.json /Volumes/ExampleData/private \(fakeToken)",
      mode: .l,
      scenario: .coding,
      dryRun: true,
      allowExecute: false,
      requestedCommands: ["swift test --package-path ."],
      commandResolver: missing
    )
    let text = try String(data: JSONEncoder().encode(receipt), encoding: .utf8).unwrapped()

    XCTAssertEqual(receipt.schema, "TatwoColimaSandboxReceiptV1")
    XCTAssertEqual(receipt.status, .degraded)
    XCTAssertTrue(receipt.dryRun)
    XCTAssertFalse(receipt.executed)
    XCTAssertFalse(receipt.hostMutationAllowed)
    XCTAssertFalse(receipt.available)
    XCTAssertTrue(receipt.plan.blockReasons.contains("colima_or_docker_missing"))
    XCTAssertTrue(
      receipt.plan.deniedMounts.contains { $0.contains("/Users") || $0.contains("$HOME") })
    XCTAssertTrue(receipt.plan.deniedEnvironment.contains("OPENAI_API_KEY"))
    XCTAssertFalse(text.contains("/Users/"))
    XCTAssertFalse(text.contains("/Volumes/"))
    XCTAssertFalse(text.contains("auth.json"))
    XCTAssertFalse(text.contains("sk-abc"))
  }

  func testAvailableButUnapprovedPlanStillDoesNotExecute() throws {
    let available: (String) -> String? = { command in "/usr/local/bin/\(command)" }
    let receipt = ColimaSandboxFactory.makeReceipt(
      objective: "available but dry-run",
      mode: .xl,
      scenario: .coding,
      dryRun: true,
      allowExecute: false,
      requestedCommands: ["swift test --package-path ."],
      commandResolver: available
    )

    XCTAssertTrue(receipt.available)
    XCTAssertEqual(receipt.status, .planned)
    XCTAssertFalse(receipt.executed)
    XCTAssertFalse(receipt.hostMutationAllowed)
    XCTAssertTrue(receipt.plan.blockReasons.contains("dry_run_only"))
    XCTAssertTrue(receipt.plan.blockReasons.contains("execution_not_explicitly_allowed"))
    XCTAssertFalse(receipt.plan.canExecuteNow)
  }

  func testUnallowlistedCommandBlocksExecutionPlan() throws {
    let available: (String) -> String? = { command in "/usr/local/bin/\(command)" }
    let plan = ColimaSandboxFactory.makeRunPlan(
      objective: "unsafe command",
      mode: .l,
      scenario: .coding,
      dryRun: false,
      allowExecute: true,
      requestedCommands: ["cat ~/.codex/auth.json"],
      commandResolver: available
    )

    XCTAssertFalse(plan.canExecuteNow)
    XCTAssertTrue(plan.blockReasons.contains("command_not_allowlisted"))
    XCTAssertFalse(plan.hostMutationAllowed)
  }

  func testExecutablePlanSurfaceDoesNotContainInstallStartOrPullCommands() throws {
    let available: (String) -> String? = { command in "/usr/local/bin/\(command)" }
    let plan = ColimaSandboxFactory.makeRunPlan(
      objective: "safe command surface",
      mode: .l,
      scenario: .coding,
      dryRun: true,
      allowExecute: false,
      requestedCommands: ["swift test --package-path ."],
      commandResolver: available
    )
    let commandSurface = (plan.allowedCommandPrefixes + plan.requestedCommands)
      .joined(separator: "\n")
      .lowercased()

    XCTAssertFalse(commandSurface.contains("colima start"))
    XCTAssertFalse(commandSurface.contains("brew install"))
    XCTAssertFalse(commandSurface.contains("docker pull"))
    XCTAssertFalse(commandSurface.contains("colima delete"))
    XCTAssertTrue(plan.deniedMounts.contains { $0.contains("$HOME") })
    XCTAssertTrue(plan.deniedMounts.contains { $0.contains("/Users") })
    XCTAssertTrue(plan.deniedMounts.contains { $0.contains("/Volumes") })
  }

  func testDoctorDoesNotBlockWhenOnlyColimaIsMissing() throws {
    let report = DoctorReport(
      summary: "Colima optional missing test",
      checks: [
        DoctorCheck(
          id: "core-catalog", title: "core", status: .installed, severity: .critical,
          message: "core loaded"),
        DoctorCheck(
          id: "ui-validation-gate", title: "ui gate", status: .installed, severity: .critical,
          message: "ui gate loaded"),
        DoctorCheck(
          id: "gateway-contract", title: "gateway", status: .installed, severity: .critical,
          message: "gateway evidence observed"),
        DoctorCheck(
          id: "ultrawork-contract", title: "ultrawork", status: .installed, severity: .high,
          message: "workflow evidence observed"),
        DoctorCheck(
          id: "cmd-colima", title: "Colima optional", status: .missing, severity: .medium,
          message: "optional verifier missing")
      ])

    XCTAssertTrue(report.ok)
    XCTAssertTrue(report.coreReady)
    XCTAssertTrue(report.sandboxReady)
    XCTAssertTrue(report.hostReady)
    XCTAssertFalse(report.hostMutationAllowed)
    XCTAssertTrue(report.blockingReasons.isEmpty)
  }
}

extension Optional where Wrapped == String {
  fileprivate func unwrapped(file: StaticString = #filePath, line: UInt = #line) throws -> String {
    guard let self else {
      XCTFail("Expected non-nil string", file: file, line: line)
      throw NSError(domain: "ColimaSandboxTests", code: 1)
    }
    return self
  }
}

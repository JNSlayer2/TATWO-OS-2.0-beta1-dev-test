import CryptoKit
import Foundation

public struct RuntimeCommandCheck: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let command: String
  public let status: InstallState
  public let path: String?
  public let requiredForExecution: Bool
  public let plainStatus: String
  public let remediation: String?

  public init(
    command: String, path: String?, requiredForExecution: Bool, plainStatus: String,
    remediation: String?
  ) {
    self.id = "cmd-\(command)"
    self.command = command
    self.status = path == nil ? .missing : .installed
    self.path = path.map { TatwoPrivacyRedactor.redacted($0) }
    self.requiredForExecution = requiredForExecution
    self.plainStatus = TatwoPrivacyRedactor.redacted(plainStatus)
    self.remediation = remediation.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct ColimaPreflightReport: Codable, Sendable, Equatable {
  public let schema: String
  public let generatedAt: Date
  public let adapterID: String
  public let displayName: String
  public let available: Bool
  public let status: InstallState
  public let severityIfMissing: SafetyLevel
  public let hostMutationAllowed: Bool
  public let autoInstallAllowed: Bool
  public let autoStartAllowed: Bool
  public let dryRunSupported: Bool
  public let commandChecks: [RuntimeCommandCheck]
  public let installHint: String
  public let safetyRules: [String]
  public let nextActions: [String]
  public let plainSummary: String

  public init(
    schema: String = "TatwoColimaPreflightV1",
    generatedAt: Date = Date(),
    adapterID: String = "colima-sandbox-runner",
    displayName: String = "Colima sandbox runner",
    available: Bool,
    status: InstallState,
    severityIfMissing: SafetyLevel,
    hostMutationAllowed: Bool,
    autoInstallAllowed: Bool,
    autoStartAllowed: Bool,
    dryRunSupported: Bool,
    commandChecks: [RuntimeCommandCheck],
    installHint: String,
    safetyRules: [String],
    nextActions: [String],
    plainSummary: String
  ) {
    self.schema = schema
    self.generatedAt = generatedAt
    self.adapterID = adapterID
    self.displayName = displayName
    self.available = available
    self.status = status
    self.severityIfMissing = severityIfMissing
    self.hostMutationAllowed = hostMutationAllowed
    self.autoInstallAllowed = autoInstallAllowed
    self.autoStartAllowed = autoStartAllowed
    self.dryRunSupported = dryRunSupported
    self.commandChecks = commandChecks
    self.installHint = TatwoPrivacyRedactor.redacted(installHint)
    self.safetyRules = safetyRules.map { TatwoPrivacyRedactor.redacted($0) }
    self.nextActions = nextActions.map { TatwoPrivacyRedactor.redacted($0) }
    self.plainSummary = TatwoPrivacyRedactor.redacted(plainSummary)
  }
}

public struct ColimaRunPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let objective: String
  public let mode: WorkModeID
  public let scenario: ScenarioID
  public let dryRun: Bool
  public let allowExecute: Bool
  public let canExecuteNow: Bool
  public let hostMutationAllowed: Bool
  public let requiresHumanApprovalForExecution: Bool
  public let profileName: String
  public let runtime: String
  public let workspacePolicy: [String]
  public let allowedCommandPrefixes: [String]
  public let requestedCommands: [String]
  public let deniedMounts: [String]
  public let deniedEnvironment: [String]
  public let expectedReceipts: [String]
  public let nextActions: [String]
  public let blockReasons: [String]

  public init(
    schema: String = "TatwoColimaRunPlanV1",
    objective: String,
    mode: WorkModeID,
    scenario: ScenarioID,
    dryRun: Bool,
    allowExecute: Bool,
    canExecuteNow: Bool,
    hostMutationAllowed: Bool,
    requiresHumanApprovalForExecution: Bool,
    profileName: String,
    runtime: String,
    workspacePolicy: [String],
    allowedCommandPrefixes: [String],
    requestedCommands: [String],
    deniedMounts: [String],
    deniedEnvironment: [String],
    expectedReceipts: [String],
    nextActions: [String],
    blockReasons: [String]
  ) {
    self.schema = schema
    self.objective = TatwoPrivacyRedactor.redacted(
      objective.trimmingCharacters(in: .whitespacesAndNewlines))
    self.mode = mode
    self.scenario = scenario
    self.dryRun = dryRun
    self.allowExecute = allowExecute
    self.canExecuteNow = canExecuteNow
    self.hostMutationAllowed = hostMutationAllowed
    self.requiresHumanApprovalForExecution = requiresHumanApprovalForExecution
    self.profileName = TatwoPrivacyRedactor.redacted(profileName)
    self.runtime = runtime
    self.workspacePolicy = workspacePolicy.map { TatwoPrivacyRedactor.redacted($0) }
    self.allowedCommandPrefixes = allowedCommandPrefixes
    self.requestedCommands = requestedCommands.map { TatwoPrivacyRedactor.redacted($0) }
    self.deniedMounts = deniedMounts.map { TatwoPrivacyRedactor.redacted($0) }
    self.deniedEnvironment = deniedEnvironment.map { TatwoPrivacyRedactor.redacted($0) }
    self.expectedReceipts = expectedReceipts.map { TatwoPrivacyRedactor.redacted($0) }
    self.nextActions = nextActions.map { TatwoPrivacyRedactor.redacted($0) }
    self.blockReasons = blockReasons.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public enum ColimaReceiptStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case planned
  case degraded
  case blocked
  case passed
}

public struct ColimaSandboxReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let receiptID: String
  public let createdAt: Date
  public let status: ColimaReceiptStatus
  public let dryRun: Bool
  public let executed: Bool
  public let hostMutationAllowed: Bool
  public let available: Bool
  public let objective: String
  public let plan: ColimaRunPlan
  public let preflight: ColimaPreflightReport
  public let evidenceSummary: [String]
  public let failureMode: String?

  public init(
    schema: String = "TatwoColimaSandboxReceiptV1",
    receiptID: String,
    createdAt: Date = Date(),
    status: ColimaReceiptStatus,
    dryRun: Bool,
    executed: Bool,
    hostMutationAllowed: Bool,
    available: Bool,
    objective: String,
    plan: ColimaRunPlan,
    preflight: ColimaPreflightReport,
    evidenceSummary: [String],
    failureMode: String?
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.createdAt = createdAt
    self.status = status
    self.dryRun = dryRun
    self.executed = executed
    self.hostMutationAllowed = hostMutationAllowed
    self.available = available
    self.objective = TatwoPrivacyRedactor.redacted(objective)
    self.plan = plan
    self.preflight = preflight
    self.evidenceSummary = evidenceSummary.map { TatwoPrivacyRedactor.redacted($0) }
    self.failureMode = failureMode.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public enum ColimaSandboxFactory {
  public static let defaultProfileName = "tatwo-ultrawork-sandbox"

  public static let allowedCommandPrefixes: [String] = [
    "swift test",
    "swift build",
    "node scripts/tatwo-ultrawork-mcp-smoke.mjs",
    "node scripts/tatwo-ultrawork-mcp-adversarial-smoke.mjs",
    "node scripts/tatwo-codex-disconnect-guard.mjs",
    "bash scripts/tatwo-ultrawork-sandbox-check.sh",
    "true",
  ]

  public static let deniedMounts: [String] = [
    "$HOME",
    "/Users",
    "whole /Volumes",
    "~/.codex",
    "~/.ssh",
    "browser profiles",
    "Docker socket from host",
  ]

  public static let deniedEnvironment: [String] = [
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "GROK_API_KEY",
    "MINIMAX_API_KEY",
    "Authorization",
    "access_token",
    "refresh_token",
    "SSH_AUTH_SOCK",
  ]

  public static func preflight(commandResolver: ((String) -> String?)? = nil)
    -> ColimaPreflightReport
  {
    let resolver = commandResolver ?? which
    let colimaPath = resolver("colima")
    let dockerPath = resolver("docker")
    let limaPath = resolver("lima")
    let checks = [
      RuntimeCommandCheck(
        command: "colima", path: colimaPath, requiredForExecution: true,
        plainStatus: colimaPath == nil
          ? "Colima CLI not found; adapter stays optional/degraded."
          : "Colima CLI is visible on PATH.", remediation: "Optional: brew install colima"),
      RuntimeCommandCheck(
        command: "docker", path: dockerPath, requiredForExecution: true,
        plainStatus: dockerPath == nil
          ? "Docker client not found; Colima Docker runtime cannot be used."
          : "Docker client is visible on PATH.",
        remediation: "Optional with Docker runtime: brew install docker"),
      RuntimeCommandCheck(
        command: "lima", path: limaPath, requiredForExecution: false,
        plainStatus: limaPath == nil
          ? "Lima CLI not found on PATH; Colima may still manage it internally if installed."
          : "Lima CLI is visible on PATH.",
        remediation: "Usually installed as Colima dependency; no Tatwo auto-install."),
    ]
    let available = colimaPath != nil && dockerPath != nil
    let status: InstallState = available ? .installed : .missing
    return ColimaPreflightReport(
      available: available,
      status: status,
      severityIfMissing: .medium,
      hostMutationAllowed: false,
      autoInstallAllowed: false,
      autoStartAllowed: false,
      dryRunSupported: true,
      commandChecks: checks,
      installHint:
        "Optional verifier only. If you choose it later: brew install colima docker, then start a Tatwo-specific profile manually.",
      safetyRules: [
        "Colima is an L2 runtime adapter/verifier, not a model lane and not a subagent.",
        "Missing Colima must show degraded/optional state, not crash Tatwo doctor or App.",
        "Tatwo never auto-installs or auto-starts Colima; execution needs explicit human approval.",
        "No $HOME, /Users, whole /Volumes, auth/session, SSH agent, browser profile, or token mounts.",
        "Only allowlisted deterministic commands may run; model fan-out stays separately budgeted.",
      ],
      nextActions: available
        ? [
          "Run tatwo-ultrawork colima run --dry-run first.",
          "Only after explicit approval, use a temp workspace copy and allowlisted commands.",
        ]
        : [
          "Keep using existing sandbox checks.",
          "If you want stronger L/XL isolation later, install Colima/Docker manually and rerun preflight.",
        ],
      plainSummary: available
        ? "Colima verifier is available but still gated; Tatwo will not execute it unless explicitly allowed."
        : "Colima verifier is not installed on PATH; Tatwo remains usable and marks this as optional missing."
    )
  }

  public static func makeRunPlan(
    objective: String,
    mode: WorkModeID = .l,
    scenario: ScenarioID = .coding,
    dryRun: Bool = true,
    allowExecute: Bool = false,
    requestedCommands: [String] = [],
    commandResolver: ((String) -> String?)? = nil
  ) -> ColimaRunPlan {
    let preflight = preflight(commandResolver: commandResolver)
    let safeObjective =
      objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Tatwo Colima sandbox verification"
      : objective
    let sanitizedCommands = requestedCommands.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    let commandBlocks = sanitizedCommands.filter { command in
      !allowedCommandPrefixes.contains(where: { command == $0 || command.hasPrefix($0 + " ") })
    }
    var blockReasons: [String] = []
    if !preflight.available { blockReasons.append("colima_or_docker_missing") }
    if dryRun { blockReasons.append("dry_run_only") }
    if !allowExecute { blockReasons.append("execution_not_explicitly_allowed") }
    if !commandBlocks.isEmpty { blockReasons.append("command_not_allowlisted") }
    let canExecute = preflight.available && !dryRun && allowExecute && commandBlocks.isEmpty

    return ColimaRunPlan(
      objective: safeObjective,
      mode: mode,
      scenario: scenario,
      dryRun: dryRun,
      allowExecute: allowExecute,
      canExecuteNow: canExecute,
      hostMutationAllowed: false,
      requiresHumanApprovalForExecution: true,
      profileName: defaultProfileName,
      runtime: "docker via Colima optional profile",
      workspacePolicy: [
        "Copy the target repo into a temporary workspace; do not mount the original repo read-write by default.",
        "Use a Tatwo-specific Colima profile if execution is later approved.",
        "Keep network and image pulls off unless the human explicitly approves that test case.",
        "Clean up temporary workspace/profile evidence after the receipt is written.",
      ],
      allowedCommandPrefixes: allowedCommandPrefixes,
      requestedCommands: sanitizedCommands,
      deniedMounts: deniedMounts,
      deniedEnvironment: deniedEnvironment,
      expectedReceipts: [
        "colima preflight receipt",
        "temporary workspace copy receipt",
        "allowlisted command receipt",
        "cleanup receipt",
        "redaction scan receipt",
      ],
      nextActions: canExecute
        ? [
          "Create temp workspace copy.", "Run allowlisted commands only.",
          "Collect output and cleanup receipts.",
        ]
        : [
          "Treat this as a plan/degraded receipt, not a pass.",
          "Resolve blockReasons before any Colima execution.",
        ],
      blockReasons: blockReasons
    )
  }

  public static func makeReceipt(
    objective: String,
    mode: WorkModeID = .l,
    scenario: ScenarioID = .coding,
    dryRun: Bool = true,
    allowExecute: Bool = false,
    requestedCommands: [String] = [],
    commandResolver: ((String) -> String?)? = nil
  ) -> ColimaSandboxReceipt {
    let preflight = preflight(commandResolver: commandResolver)
    let plan = makeRunPlan(
      objective: objective,
      mode: mode,
      scenario: scenario,
      dryRun: dryRun,
      allowExecute: allowExecute,
      requestedCommands: requestedCommands,
      commandResolver: commandResolver
    )
    let status: ColimaReceiptStatus
    let failureMode: String?
    if plan.canExecuteNow {
      // Swift core intentionally does not perform container side effects.
      // The Node runner may execute later, but the core receipt stays honest.
      status = .planned
      failureMode = "execution_delegated_to_gated_runner"
    } else if preflight.available {
      status = .planned
      failureMode = plan.blockReasons.joined(separator: ",")
    } else {
      status = .degraded
      failureMode = "optional_colima_missing"
    }
    let id = stableReceiptID(
      objective: plan.objective, mode: mode, scenario: scenario, dryRun: dryRun,
      available: preflight.available)
    return ColimaSandboxReceipt(
      receiptID: id,
      status: status,
      dryRun: dryRun,
      executed: false,
      hostMutationAllowed: false,
      available: preflight.available,
      objective: plan.objective,
      plan: plan,
      preflight: preflight,
      evidenceSummary: [
        "Core generated a Colima adapter plan with hostMutationAllowed=false.",
        preflight.available
          ? "Colima/Docker commands are visible; execution still needs explicit approval."
          : "Colima/Docker missing; fallback to existing sandbox checks.",
        "No install, no start, no host config mutation, no secret mount.",
      ],
      failureMode: failureMode
    )
  }

  private static func stableReceiptID(
    objective: String, mode: WorkModeID, scenario: ScenarioID, dryRun: Bool, available: Bool
  ) -> String {
    let input = "\(objective)\n\(mode.rawValue)\n\(scenario.rawValue)\n\(dryRun)\n\(available)"
    let digest = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
      .prefix(12)
    return "colima-\(mode.rawValue.lowercased())-\(scenario.rawValue)-\(digest)"
  }

  private static func which(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "sh", "-c", "command -v '\(command.replacingOccurrences(of: "'", with: "'\\''"))'",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      return output?.isEmpty == false ? output : nil
    } catch {
      return nil
    }
  }
}

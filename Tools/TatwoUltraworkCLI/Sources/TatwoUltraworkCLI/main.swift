import Darwin
import Foundation
import TatwoUltraworkCore

struct JSONEnvelope<T: Encodable>: Encodable {
  let ok: Bool
  let command: String
  let data: T?
  let error: String?
}

struct WorkflowPreview: Encodable {
  let workflow: WorkflowTemplate
  let mermaid: String
}

struct OperationalValidationOutput: Encodable {
  let sampleCase: String?
  let expectedPass: Bool?
  let receipt: OperationalReceipt
  let requirement: OperationalReceiptRequirement
  let report: OperationalGateReport
}

struct TatwoEnrollmentCapabilitiesV1: Encodable {
  let schema = "TatwoEnrollmentCapabilitiesV1"
  let deviceTrustContract = "TatwoDeviceTrustCLI.v1"
  let skilletContract = "TatwoSkilletCLI.v1"
}

struct TatwoSessionRevisionCLIOutputV1: Encodable {
  let schema = "TatwoSessionRevisionCLIOutputV1"
  let transition: TatwoGoalRevisionPromotionResultV1
  let readback: TatwoSessionAttachmentV1
}

struct MCPHTTPCallRequest: Encodable {
  let tool: String
  let arguments: [String: JSONValue]
}

final class LockedMCPResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TatwoMCPToolCallResult?

  func set(_ nextValue: TatwoMCPToolCallResult?) {
    lock.lock()
    value = nextValue
    lock.unlock()
  }

  func get() -> TatwoMCPToolCallResult? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

struct TatwoUltraworkCLI {
  static func main() {
    do {
      try run(Array(CommandLine.arguments.dropFirst()))
    } catch {
      let safeCommand = TatwoPrivacyRedactor.redacted(
        CommandLine.arguments.dropFirst().joined(separator: " "))
      let safeError = TatwoPrivacyRedactor.redacted(error.localizedDescription)
      printJSON(JSONEnvelope<String>(ok: false, command: safeCommand, data: nil, error: safeError))
      Foundation.exit((error as? CLIError)?.exitStatus ?? 1)
    }
  }

  static func run(_ args: [String]) throws {
    guard let first = args.first else {
      printHelp()
      return
    }

    switch first {
    case "doctor":
      let liveGatewayStatus = TatwoGatewayLiveProbe.fetchSynchronously()
      var report = DoctorFactory.staticReport(gatewayLiveStatus: liveGatewayStatus)
      let evidenceDir =
        option("--evidence-dir", in: args)
        ?? ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EVIDENCE_DIR"]
      let checks =
        doctorChecksByApplyingM2Evidence(report.checks, evidenceDir: evidenceDir)
        + environmentChecks()
      report = DoctorReport(summary: report.summary, checks: checks)
      if args.contains("--modules") {
        let modular = try TatwoModularDeploymentCLI.modularDoctor(
          args: args,
          baseDoctor: report)
        let ok = report.ok && modular.moduleReceipt.outcome == .succeeded
        output(modular, command: "doctor --modules", ok: ok)
        if !ok {
          Foundation.exit(3)
        }
      } else {
        output(report, command: "doctor", ok: report.ok)
      }
    case "deploy":
      try TatwoModularDeploymentCLI.deploy(args)
    case "module":
      try TatwoModularDeploymentCLI.module(args)
    case "mode", "modes":
      let subcommand = args.dropFirst().first
      if subcommand == "list" {
        output(TatwoCatalog.defaults.workModes, command: "mode list")
      } else if subcommand == "plan" {
        let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
        let scenario = option("--scenario", in: args)
        output(
          TatwoIdentityCatalog.modePlan(mode: mode, scenarioProfileID: scenario),
          command: "mode plan")
      } else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork mode list --json OR mode plan --mode XL --scenario ui-ux --json")
      }
    case "scenario", "scenarios":
      let subcommand = args.dropFirst().first
      if subcommand == "list" {
        output(TatwoCatalog.defaults.scenarios, command: "scenario list")
      } else if subcommand == "profiles" {
        output(TatwoIdentityCatalog.scenarioProfiles, command: "scenario profiles")
      } else if subcommand == "config" {
        let book = TatwoScenarioConfigStore.loadDefaultStaging()
        output(book, command: "scenario config")
      } else if subcommand == "config-path" {
        output(
          ["path": TatwoScenarioConfigStore.defaultFileURL().path],
          command: "scenario config-path")
      } else if subcommand == "config-add" {
        let displayName = option("--name", in: args) ?? option("--display-name", in: args) ?? "自定義情境"
        let baseScenario = option("--base", in: args).flatMap { try? ScenarioID.parse($0) }
        output(
          try mutateScenarioConfig(contractID: option("--contract", in: args) ?? option("--contractID", in: args)) { book in
            try TatwoScenarioConfigMutator.addCustomScenario(
              to: book,
              displayName: displayName,
              baseScenario: baseScenario)
          },
          command: "scenario config-add")
      } else if subcommand == "config-duplicate" {
        let scenario = try requiredOption("--scenario", in: args)
        output(
          try mutateScenarioConfig(contractID: option("--contract", in: args) ?? option("--contractID", in: args)) { book in
            try TatwoScenarioConfigMutator.duplicateScenario(in: book, scenarioID: scenario)
          },
          command: "scenario config-duplicate")
      } else if subcommand == "config-rename" {
        let scenario = try requiredOption("--scenario", in: args)
        let displayName = try requiredAnyOption(["--name", "--display-name"], in: args)
        output(
          try mutateScenarioConfig(contractID: option("--contract", in: args) ?? option("--contractID", in: args)) { book in
            try TatwoScenarioConfigMutator.renameScenario(
              in: book,
              scenarioID: scenario,
              displayName: displayName)
          },
          command: "scenario config-rename")
      } else if subcommand == "config-delete" {
        let scenario = try requiredOption("--scenario", in: args)
        output(
          try mutateScenarioConfig(contractID: option("--contract", in: args) ?? option("--contractID", in: args)) { book in
            try TatwoScenarioConfigMutator.deleteScenario(in: book, scenarioID: scenario)
          },
          command: "scenario config-delete")
      } else if subcommand == "config-budget" {
        let scenario = try requiredOption("--scenario", in: args)
        let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
        let tokenBudget = try requiredAnyOption(["--token-budget", "--budget"], in: args)
        output(
          try mutateScenarioConfig(contractID: option("--contract", in: args) ?? option("--contractID", in: args)) { book in
            try TatwoScenarioConfigMutator.updateTokenBudget(
              in: book,
              scenarioID: scenario,
              mode: mode,
              tokenBudget: tokenBudget)
          },
          command: "scenario config-budget")
      } else if subcommand == "config-bind" {
        let scenario = try requiredOption("--scenario", in: args)
        let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
        let bindingID = try requiredAnyOption(["--binding", "--binding-id"], in: args)
        let modelIDs = scenarioConfigModels(from: args)
        output(
          try mutateScenarioConfig(contractID: option("--contract", in: args) ?? option("--contractID", in: args)) { book in
            try TatwoScenarioConfigMutator.setBindingModels(
              in: book,
              scenarioID: scenario,
              mode: mode,
              bindingID: bindingID,
              modelIDs: modelIDs)
          },
          command: "scenario config-bind")
      } else if subcommand == "config-responsibility" {
        let scenario = try requiredOption("--scenario", in: args)
        let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
        let bindingID = try requiredAnyOption(["--binding", "--binding-id"], in: args)
        let responsibility = try requiredOption("--responsibility", in: args)
        output(
          try mutateScenarioConfig(contractID: option("--contract", in: args) ?? option("--contractID", in: args)) { book in
            try TatwoScenarioConfigMutator.updateBindingResponsibility(
              in: book,
              scenarioID: scenario,
              mode: mode,
              bindingID: bindingID,
              responsibility: responsibility)
          },
          command: "scenario config-responsibility")
      } else if subcommand == "agents" {
        let scenario = option("--scenario", in: args) ?? "ui-ux"
        guard let profile = TatwoIdentityCatalog.scenarioProfile(scenario) else {
          throw CLIError.usage("Unknown scenario profile: \(scenario)")
        }
        output(profile, command: "scenario agents")
      } else if subcommand == "workflow" {
        let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
        let scenario = option("--scenario", in: args) ?? "ui-ux"
        let objective = option("--objective", in: args) ?? "Tatwo scenario workflow"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        output(
          try ScenarioWorkflowContractFactory.make(
            mode: mode, scenarioProfileID: scenario, objective: objective, scenarioBook: scenarioBook),
          command: "scenario workflow")
      } else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork scenario list|profiles|config|config-path|config-add|config-duplicate|config-rename|config-delete|config-budget|config-bind|config-responsibility|agents|workflow --scenario ui-ux --mode M --json"
        )
      }
    case "capabilities", "capability":
      let subcommand = args.dropFirst().first
      if subcommand == "status" || subcommand == "roots" {
        output(TatwoCapabilityRegistry.status(), command: "capabilities status")
      } else if subcommand == "enrollment" {
        output(
          TatwoEnrollmentCapabilitiesV1(),
          command: "capabilities enrollment")
      } else if subcommand == "bootstrap" {
        let names = (option("--names", in: args) ?? "tatwo-ultrawork")
          .split(separator: ",")
          .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        output(
          try TatwoCapabilityRegistry.bootstrap(names: names),
          command: "capabilities bootstrap")
      } else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork capabilities status|enrollment|bootstrap --names tatwo-ultrawork --json")
      }
    case "skillet":
      try TatwoSkilletCLI.run(args)
    case "device-trust":
      try TatwoDeviceTrustCLI.run(args)
    case "remote-runner":
      try TatwoRemoteRunnerCLI.run(args)
    case "plugins":
      let subcommand = args.dropFirst().first
      if subcommand == "list" {
        output(TatwoPluginRegistryStore.loadDefaultStaging(), command: "plugins list")
      } else if subcommand == "register" {
        let kindRaw = option("--kind", in: args) ?? "mcp"
        guard let kind = RegistryKind(rawValue: kindRaw) else {
          throw CLIError.usage("Unknown plugin registry kind: \(kindRaw)")
        }
        let path = try requiredOption("--path", in: args)
        let purpose = try requiredOption("--purpose", in: args)
        let name = option("--name", in: args)
        output(
          try TatwoPluginRegistryStore.defaultStore().register(
            kind: kind,
            path: path,
            plainPurpose: purpose,
            name: name),
          command: "plugins register")
      } else if subcommand == "claude-export" {
        output(
          try TatwoPluginRegistryStore.defaultStore().exportClaudeMCPConfig(),
          command: "plugins claude-export")
      } else if subcommand == "claude-staging" {
        let target = option("--target", in: args).map { URL(fileURLWithPath: $0) }
        output(
          try TatwoPluginRegistryStore.defaultStore().writeClaudeMCPStaging(to: target),
          command: "plugins claude-staging")
      } else if subcommand == "sync-claude" {
        let target = option("--target", in: args).map { URL(fileURLWithPath: $0) }
        output(
          try TatwoPluginRegistryStore.defaultStore().syncClaudeMCPConfig(targetURL: target),
          command: "plugins sync-claude")
      } else if subcommand == "claude-config-path" {
        output(
          [
            "officialUserConfigPath": TatwoPluginRegistryStore.defaultClaudeConfigURL().path,
            "stagingPath": TatwoPluginRegistryStore.defaultClaudeStagingURL().path,
          ],
          command: "plugins claude-config-path")
      } else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork plugins list|register|claude-export|claude-staging|sync-claude|claude-config-path --json")
      }
    case "routes", "route":
      let subcommand = args.dropFirst().first
      if subcommand == "list" {
        output(TatwoOSModeRouteCatalog.all, command: "routes list")
      } else if subcommand == "plan" {
        output(TatwoOSModeRouteCatalog.installPlan, command: "routes plan")
      } else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork routes list --json OR tatwo-ultrawork routes plan --json")
      }
    case "engine", "engines":
      try handleEngines(args)
    case "identities", "identity":
      guard args.dropFirst().first == "list" else {
        throw CLIError.usage("Use: tatwo-ultrawork identities list --json")
      }
      output(TatwoIdentityCatalog.identityDefinitions, command: "identities list")
    case "traits", "trait":
      guard args.dropFirst().first == "list" else {
        throw CLIError.usage("Use: tatwo-ultrawork traits list --json")
      }
      output(
        EngineTraitSummary(
          schema: "TatwoEngineTraitSummaryV1",
          engines: TatwoIdentityCatalog.engines,
          dimensions: TatwoIdentityCatalog.traitDimensions,
          modelTraits: TeamRoutingCatalog.modelTraits),
        command: "traits list")
    case "ultrawork":
      guard args.dropFirst().first == "topics" else {
        throw CLIError.usage("Use: tatwo-ultrawork ultrawork topics --json")
      }
      output(TatwoIdentityCatalog.ultraworkTopics, command: "ultrawork topics")
    case "mcp":
      try handleMCP(args)
    case "os":
      try handleWorkOS(args)
    case "teams", "team":
      try handleTeams(args)
    case "integration":
      try handleIntegration(args)
    case "colima":
      try handleColima(args)
    case "web-arena":
      try handleWebArena(args)
    case "sandbox-arena", "sandbox-arenas":
      try handleSandboxArena(args)
    case "arena":
      try handleArena(args)
    case "cleanup-inventory":
      try handleCleanupInventory(args)
    case "web-check":
      try handleWebCheck(args)
    case "workflow":
      let subcommand = args.dropFirst().first
      let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
      let scenario = try ScenarioID.parse(option("--scenario", in: args) ?? "coding")
      if subcommand == "preview" {
        let workflow = WorkflowFactory.make(mode: mode, scenario: scenario)
        output(
          WorkflowPreview(workflow: workflow, mermaid: WorkflowFactory.mermaid(workflow)),
          command: "workflow preview")
      } else if subcommand == "run" {
        let objective = option("--objective", in: args) ?? "Tatwo Ultrawork workflow dry run"
        let allowHostMutation = args.contains("--allow-host-mutation")
        let dryRunOnly = args.contains("--dry-run") || !allowHostMutation
        let plan = WorkflowRunFactory.makePlan(
          objective: objective, mode: mode, scenario: scenario, dryRunOnly: dryRunOnly)
        output(plan, command: "workflow run")
      } else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork workflow preview --mode XL --scenario code --json OR tatwo-ultrawork workflow run --mode XL --scenario code --objective '<objective>' --dry-run --json"
        )
      }
    case "handoff":
      guard args.dropFirst().first == "pack" else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork handoff pack --mode XL --scenario code --objective '<objective>' --json"
        )
      }
      let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
      let scenario = try ScenarioID.parse(option("--scenario", in: args) ?? "coding")
      let objective = option("--objective", in: args) ?? "Tatwo Ultrawork handoff"
      output(
        WorkflowRunFactory.makeHandoffPack(objective: objective, mode: mode, scenario: scenario),
        command: "handoff pack")
    case "cross-device-handoff":
      // Cross-device task handoff (5.6-2). Distinct from Work OS session/context
      // `handoff pack` above; do not route these verbs through `handoff`.
      try TatwoHandoffCLI.run(args)
    case "device-control":
      // Device mutual-control artifact tooling (5.6-4). This namespace has no
      // send/enqueue/execute verb; fleet transport remains a separate gate.
      try TatwoDeviceControlCLI.run(args)
    case "install":
      guard args.dropFirst().first == "plan" else {
        throw CLIError.usage("Use: tatwo-ultrawork install plan --json")
      }
      output(WorkflowRunFactory.installPlan(), command: "install plan")
    case "host":
      try handleHost(args)
    case "computer":
      try handleComputer(args)
    case "state":
      try handleState(args)
    case "memory":
      try handleMemory(args)
    case "context":
      try handleContext(args)
    case "sandbox":
      guard args.dropFirst().first == "preflight" else {
        throw CLIError.usage("Use: tatwo-ultrawork sandbox preflight --json")
      }
      output(SandboxPreflightReport.defaults, command: "sandbox preflight")
    case "validate":
      let subcommand = args.dropFirst().first
      if subcommand == "sample-ui" {
        let receipt = sampleUIBuildOnlyReceipt()
        let result = ValidationGate.evaluate(
          receipt, fileSystem: InMemoryEvidenceFileSystem(files: [:]))
        outputGate(result, command: "validate sample-ui")
      } else if subcommand == "sample-operational" {
        let rawCase = option("--case", in: args) ?? "host-live-good"
        guard let sampleCase = OperationalReceiptSampleCase(rawValue: rawCase) else {
          throw CLIError.usage("Unknown operational sample case: \(rawCase)")
        }
        let sample = OperationalReceiptSample.make(sampleCase)
        let report = OperationalReceiptGate.evaluate(
          sample.receipt, requirement: sample.requirement)
        outputOperationalGate(
          OperationalValidationOutput(
            sampleCase: sample.sampleCase.rawValue, expectedPass: sample.expectedPass,
            receipt: sample.receipt, requirement: sample.requirement, report: report),
          command: "validate sample-operational"
        )
      } else if subcommand == "operational-receipt" {
        guard let file = option("--file", in: args) else {
          throw CLIError.usage(
            "Use: tatwo-ultrawork validate operational-receipt --file receipt.json --require host-live-same-thread --json"
          )
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(OperationalReceipt.self, from: data)
        let requirement = try operationalRequirement(
          from: option("--require", in: args) ?? "host-live-same-thread", args: args)
        let report = OperationalReceiptGate.evaluate(receipt, requirement: requirement)
        outputOperationalGate(
          OperationalValidationOutput(
            sampleCase: nil, expectedPass: nil, receipt: receipt, requirement: requirement,
            report: report),
          command: "validate operational-receipt"
        )
      } else if subcommand == "receipt" {
        guard let file = option("--file", in: args) else {
          throw CLIError.usage("Use: tatwo-ultrawork validate receipt --file receipt.json --json")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(ValidationReceipt.self, from: data)
        let result = ValidationGate.evaluate(receipt)
        outputGate(result, command: "validate receipt")
      } else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork validate sample-ui --json OR sample-operational --case partial-stream --json OR operational-receipt --file receipt.json --require host-live-same-thread --json OR receipt --file receipt.json --json"
        )
      }
    case "help", "--help", "-h":
      printHelp()
    default:
      throw CLIError.usage("Unknown command: \(first)")
    }
  }

  static func output<T: Encodable>(_ value: T, command: String, ok: Bool = true) {
    printJSON(JSONEnvelope(ok: ok, command: command, data: value, error: nil))
  }

  static func outputGate(_ result: GateResult, command: String) {
    let passed = result.status == .passed
    printJSON(
      JSONEnvelope(
        ok: passed, command: command, data: result, error: passed ? nil : "validation_failed"))
    if !passed {
      Foundation.exit(3)
    }
  }

  static func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    do {
      let data = try encoder.encode(value)
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
      print("{\"ok\":false,\"error\":\"json_encode_failed\"}")
    }
  }

  static func option(_ name: String, in args: [String]) -> String? {
    if let inline = args.first(where: { $0.hasPrefix(name + "=") }) {
      return String(inline.dropFirst(name.count + 1))
    }
    guard let idx = args.firstIndex(of: name), args.indices.contains(args.index(after: idx)) else {
      return nil
    }
    return args[args.index(after: idx)]
  }

  static func options(_ name: String, in args: [String]) -> [String] {
    var values: [String] = []
    var index = args.startIndex
    while index < args.endIndex {
      let value = args[index]
      if value.hasPrefix(name + "=") {
        values.append(String(value.dropFirst(name.count + 1)))
      } else if value == name {
        let next = args.index(after: index)
        if next < args.endIndex {
          values.append(args[next])
          index = next
        }
      }
      index = args.index(after: index)
    }
    return values
  }

  static func requiredOption(_ name: String, in args: [String]) throws -> String {
    guard let value = option(name, in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      throw CLIError.usage("Missing required option: \(name)")
    }
    return value
  }

  static func requiredAnyOption(_ names: [String], in args: [String]) throws -> String {
    for name in names {
      if let value = option(name, in: args)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      {
        return value
      }
    }
    throw CLIError.usage("Missing required option: \(names.joined(separator: " or "))")
  }

  static func requiredExactlyOneOption(
    _ names: [String],
    in args: [String]
  ) throws -> (name: String, value: String) {
    let present = names.compactMap { name -> (String, String)? in
      guard
        let value = option(name, in: args)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      else { return nil }
      return (name, value)
    }
    guard present.count == 1, let selected = present.first else {
      throw CLIError.usage(
        "Exactly one option is required: \(names.joined(separator: " or "))")
    }
    return selected
  }

  static func requiredCanonicalSessionOwner(
    in args: [String]
  ) throws -> TatwoCanonicalSessionOwnerV1 {
    let provider = try requiredOption("--provider", in: args)
    let ownerSelection = try requiredExactlyOneOption(
      ["--owner-session", "--owner-thread"],
      in: args)
    let workspace = try requiredOption("--workspace", in: args)
    guard NSString(string: workspace).isAbsolutePath else {
      throw CLIError.usage("--workspace must be an absolute path")
    }
    return TatwoCanonicalSessionOwnerV1(
      provider: provider,
      locator:
        ownerSelection.name == "--owner-thread"
        ? .thread(ownerSelection.value)
        : .session(ownerSelection.value),
      workspacePath: workspace)
  }

  /// Explicit operator-only bootstrap for the formal current-session writer.
  ///
  /// Ordinary `beginCurrent` never calls this helper. Each authority artifact
  /// is either created from a completely absent state, or opened through its
  /// existing-only validator. Partial/corrupt state is reported and preserved;
  /// this path never overwrites, truncates, replaces, or repairs a lock.
  static func initializeSessionAuthorityLocksCreateOnly(
    goalStoreRoot: URL,
    contractID: String
  ) throws -> TatwoSessionAuthorityLockBootstrapResultV1 {
    try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: goalStoreRoot,
      contractID: contractID)
  }

  static func beginFormalWorkOSSession(
    args: [String],
    mode: WorkModeID,
    scenario: String,
    objective: String,
    scenarioBook: TatwoScenarioConfigBookV1
  ) throws -> TatwoSessionAttachmentV1 {
    let owner = try requiredCanonicalSessionOwner(in: args)
    let stateRoot = option("--state-root", in: args)
      .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
      ?? TatwoGoalRunStore.default().directoryURL
    let goalStore = TatwoGoalRunStore(directoryURL: stateRoot)
    let dispatchRegistry = TatwoDispatchRegistry(directoryURL: stateRoot)
    let sessionStore = TatwoSessionStore(directoryURL: stateRoot)
    return try WorkOSFactory.beginCanonical(
      mode: mode,
      scenarioProfileID: scenario,
      objective: objective,
      scenarioBook: scenarioBook,
      store: goalStore,
      registry: dispatchRegistry,
      sessionStore: sessionStore,
      owner: owner)
  }

  static func bootstrapFormalWorkOSAuthorityLocksOnly(
    args: [String],
    mode: WorkModeID,
    scenario: String,
    objective: String,
    scenarioBook: TatwoScenarioConfigBookV1
  ) throws -> TatwoSessionAuthorityLockBootstrapResultV1 {
    let stateRoot = option("--state-root", in: args)
      .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
      ?? TatwoGoalRunStore.default().directoryURL
    let contract = try WorkOSFactory.projectContract(
      mode: mode,
      scenarioProfileID: scenario,
      objective: objective,
      scenarioBook: scenarioBook)
    return try initializeSessionAuthorityLocksCreateOnly(
      goalStoreRoot: stateRoot,
      contractID: contract.contractID)
  }

  static func scenarioConfigModels(from args: [String]) -> [String] {
    let rawValues =
      options("--model", in: args)
      + options("--models", in: args)
      + options("--model-id", in: args)
      + options("--model-ids", in: args)
    return rawValues
      .flatMap { $0.split(separator: ",").map(String.init) }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  static func mutateScenarioConfig(
    contractID: String?,
    _ mutate: (TatwoScenarioConfigBookV1) throws -> TatwoScenarioConfigMutationResult
  ) throws -> TatwoScenarioConfigMutationResult {
    // Phase 2: staging-config mutation must run inside a registered OS run (see the MCP
    // helper for why). #2: authorized via the universal chokepoint.
    let toll = TatwoWorkOSChokepoint.authorize(
      contractID: contractID, action: "scenario.config.mutation")
    guard toll.ok else { throw CLIError.usage(toll.message) }
    let store = TatwoScenarioConfigStore.defaultStore()
    let result = try mutate(try store.load())
    try store.save(result.book)
    return result
  }

  static func printHelp() {
    let text = """
      Tatwo Ultrawork v1

      Commands:
        tatwo-ultrawork doctor --json
        tatwo-ultrawork remote-runner start --device-id <runner> --origin-device-id <origin> [--engine sandbox-probe|agent] --json
        tatwo-ultrawork remote-runner start --device-id <runner> --origin-device-id <origin> --bootstrap-only --json
        tatwo-ultrawork remote-runner seal-install --device-id <self> --channel-dir <path> --json
        tatwo-ultrawork remote-runner dispatch --device-id <origin> --target-device-id <target> --logical-job-id <id> --work-path <dir> --contract-id <id> --goal-id <id> --engine-command echo --engine-arg hello [--channel-dir <sealed>] --json
        tatwo-ultrawork remote-runner dispatch ... --task-description '<task>' --agent grok|codex|claude --model-route <route> --readiness-manifest <path> --session-id <session> --grant-id <grant> [--mode S|M|L|XL] --json
        tatwo-ultrawork remote-runner dispatch ... --task-file <path> --agent grok|codex|claude --model-route <route> --readiness-manifest <path> --session-id <session> --grant-id <grant> --json
        tatwo-ultrawork remote-runner fleet register --device-id <target> [--max-concurrent N] [--channel-dir|--fleet-dir] --json
        tatwo-ultrawork remote-runner fleet dispatch --device-id <origin> --target-device-id <target> --session-id <session> --grant-id <grant> --task-file <spec> --agent grok|codex|claude --model-route <route> --contract-id <id> --goal-id <id> [--count N] --json
        tatwo-ultrawork remote-runner fleet tick --device-id <origin> [--lease-seconds N] [--heartbeat-max-age N] --json
        tatwo-ultrawork remote-runner fleet status --device-id <origin> --json
        # Dual-machine order: (1) device-trust init + mutual pin-import (2) both seal-install
        # (3) target start long-running (4) origin dispatch + channel-sync push
        # (5) target executes + channel-sync pull + origin converge
        # crash-after-claim recovery: new jobID + new dispatchNonce, keep logicalJobID
        # (TatwoLoopJobV1.mintRecoveryDispatch). Never re-nonce the same jobID.
        # Fleet: mini-authoritative scheduler; at-least-once exec + exactly-once logical commit
        # Channel sync: scripts/tatwo-remote-channel-sync.sh push|pull (no --delete; no -E)
        tatwo-ultrawork doctor --modules --manifests ./Modules --sandbox-root <isolated-root> --json
        tatwo-ultrawork deploy plan --manifests ./Modules --modules tatwo.app,tatwo.cli --sandbox-root <isolated-root> --json
        tatwo-ultrawork deploy apply --request apply.json --sandbox-root <isolated-root> --execute-bundle-only --json
        tatwo-ultrawork deploy repair --request repair.json --sandbox-root <isolated-root> --execute-bundle-only --json
        tatwo-ultrawork module reset --module tatwo.app --manifests ./Modules --sandbox-root <isolated-root> --execute-reset --json
        tatwo-ultrawork mode list --json
        tatwo-ultrawork mode plan --mode XL --scenario ui-ux --json
        tatwo-ultrawork scenario list --json
        tatwo-ultrawork scenario profiles --json
        tatwo-ultrawork scenario config --json
        tatwo-ultrawork scenario config-add --name '通用 M custom' --base daily --json
        tatwo-ultrawork scenario config-bind --scenario <id> --mode M --binding daily-m-loops-supervisor --models sonnet-5,gpt-5.4 --json
        tatwo-ultrawork scenario agents --scenario ui-ux --json
        tatwo-ultrawork scenario workflow --mode L --scenario ui-ux --objective '<objective>' --json
        tatwo-ultrawork identities list --json
        tatwo-ultrawork traits list --json
        tatwo-ultrawork engine list --json
        tatwo-ultrawork engine capabilities --engine codex --json
        tatwo-ultrawork capabilities enrollment --json
        tatwo-ultrawork ultrawork topics --json
        tatwo-ultrawork mcp manifest --json
        tatwo-ultrawork mcp tools --json
        tatwo-ultrawork mcp client-config --engine generic-cli --json
        tatwo-ultrawork mcp call tatwo.mode.plan --mode XL --scenario ui-ux --json
        tatwo-ultrawork mcp call tatwo.scenario.workflow --mode L --scenario ui-ux --objective '<objective>' --json
        tatwo-ultrawork mcp call tatwo.gateway.dispatch --contract <contractID> --model minimax-m3 --prompt '<subtask>' --dry-run --json
        tatwo-ultrawork mcp call tatwo.sandbox.begin --contract <contractID> --objective '<sandbox objective>' --json
        tatwo-ultrawork os begin --mode XL --scenario ui-ux --objective '<objective>' --provider codex --owner-session <session-or-thread-id> --workspace <absolute-path> [--initialize-authority-locks] --json
        tatwo-ultrawork os next --goal <goalID> --contract <contractID> --mode XL --scenario ui-ux --json
        tatwo-ultrawork os loop status --goal <goalID> --contract <contractID> --mode XL --scenario ui-ux --json
        tatwo-ultrawork os receipt submit --goal <goalID> --contract <contractID> --receipt <receiptID> --kind test --json
        tatwo-ultrawork os goal close --goal <goalID> --contract <contractID> --receipt <id> --json
        tatwo-ultrawork os session start --mode M --scenario coding --objective '<objective>' --provider codex --owner-session <session-or-thread-id> --workspace <absolute-path> [--initialize-authority-locks] --json
        tatwo-ultrawork os session revise --authorization <externally-issued-id> --json
        tatwo-ultrawork os session revision-recovery-plan --successor <planned-contract-id> --thread-id <thread> --turn-id <turn> --event-id <user-event> --human-message-file <path> --legacy-unavailable-evidence-file <path> --legacy-app-version <version> --legacy-app-build <build> --device-id <device> --json
        sudo tatwo-ultrawork os session revision-recovery-enroll --successor <planned-contract-id> --thread-id <thread> --turn-id <turn> --event-id <user-event> --human-message-file <path> --legacy-unavailable-evidence-file <path> --legacy-app-version <version> --legacy-app-build <build> --device-id <device> --json
        tatwo-ultrawork os session attach --contract <contractID> --goal <goalID> --provider <provider> (--owner-session <id>|--owner-thread <id>) --workspace <absolute-path> --json
        tatwo-ultrawork os session stop --provider <provider> (--owner-session <id>|--owner-thread <id>) --workspace <absolute-path> --json
        tatwo-ultrawork host authorize-revision --authorization <app-issued-host-operation-id> --json
        tatwo-ultrawork mcp call tatwo.mode.plan --app-url http://127.0.0.1:17377 --mode XL --scenario ui-ux --json
        tatwo-ultrawork mcp serve --stdio --json
        tatwo-ultrawork mcp serve --port 17377 --json
        tatwo-ultrawork plugins list --json
        tatwo-ultrawork plugins register --kind mcp --name demo --path mcp:demo-server --purpose '<plain purpose>' --json
        tatwo-ultrawork plugins claude-export --json
        tatwo-ultrawork plugins claude-staging --json
        tatwo-ultrawork plugins sync-claude --json
        tatwo-ultrawork routes list --json
        tatwo-ultrawork routes plan --json
        tatwo-ultrawork teams traits --json
        tatwo-ultrawork teams leads --json
        tatwo-ultrawork teams list --json
        tatwo-ultrawork teams recommend --mode L --scenario design --json
        tatwo-ultrawork teams dashboard --mode XL --scenario coding --json
        tatwo-ultrawork integration plan --json
        tatwo-ultrawork integration stability --json
        tatwo-ultrawork integration fugu-policy --json
        tatwo-ultrawork colima preflight --json
        tatwo-ultrawork colima run --mode L --scenario code --objective '<objective>' --dry-run --json
        tatwo-ultrawork web-arena plan --suite v1 --models gpt-5.5,sonnet-5,fable-5,opus-5,minimax-m3 --json
        tatwo-ultrawork web-arena scaffold --suite v1 --models gpt-5.5,sonnet-5,fable-5,opus-5,minimax-m3 --json
        tatwo-ultrawork web-arena run --suite v1 --run 20260702-minimax-m3-web-arena-formal-v1 --models minimax-m3 --live --reasoning xhigh --json
        tatwo-ultrawork web-arena report --run 20260701-web-arena-v1 --json
        tatwo-ultrawork web-arena cleanup --older-than 14d --dry-run --json
        tatwo-ultrawork sandbox-arena list --json
        tatwo-ultrawork sandbox-arena plan --arena all --models gpt-5.5,sonnet-5,fable-5,opus-5,minimax-m3 --json
        tatwo-ultrawork sandbox-arena run --arena code-architecture --run 20260701-sandbox-arena-v1 --json
        tatwo-ultrawork sandbox-arena report --arena debug --run 20260701-sandbox-arena-v1 --json
        tatwo-ultrawork arena plan-loop-goal --json
        tatwo-ultrawork arena goal-cycle assess --cycles 5 --json
        tatwo-ultrawork arena plan-loop-goal score --expected 3 --completed 3 --cycles 5 --sealed --artifacts goal-contract.md,plan.md,loop-ledger.json,mainline-decision.md,final-submission/seal.json,branch-optimization-plan.md,branch-loop-ledger.json,tool-choice-ledger.json,receipt-index.json --tool-choices-registered --json
        tatwo-ultrawork cleanup-inventory write --run <runID> --goal <goalID> --contract <contractID> --candidate '<path>|<origin>|<reason>|<risk>' --keep summary.json --json
        tatwo-ultrawork cleanup-inventory template --run <runID> --goal <goalID> --json
        tatwo-ultrawork cleanup-inventory validate --file .tatwo-ultrawork/待刪垃圾檔案/<runID>/cleanup-inventory.json --json
        tatwo-ultrawork web-check preflight --json
        tatwo-ultrawork web-check plan --target <path-or-url> --mode L --scenario ui-ux --json
        tatwo-ultrawork web-check import --report <report.json> --contract <contractID> --json
        tatwo-ultrawork workflow preview --mode XL --scenario code --json
        tatwo-ultrawork workflow run --mode XL --scenario code --objective '<objective>' --dry-run --json
        tatwo-ultrawork handoff pack --mode XL --scenario code --objective '<objective>' --json
        # Work OS session/context handoff only. Cross-device task handoff (5.6-2) uses:
        tatwo-ultrawork cross-device-handoff pack-create --out <file> --goal-hash <sha256> --plan-hash <sha256> --logical-job <id> --receiver-device <id> [--files <path:sha256,...>] --json
        tatwo-ultrawork cross-device-handoff pack-verify --in <file> --expect-producer <id> --expect-receiver <id> --json
        tatwo-ultrawork cross-device-handoff assess --in <file> --capabilities <json-file> [--out <assessment-file>] --json
        tatwo-ultrawork cross-device-handoff assessment-verify --in <assessment-file> --pack <file> --json
        # Moving primary control to another device uses a separate user-confirmation flow.
        tatwo-ultrawork device-control descriptor-create --out <file> --template-id <id> --argv <executable,arg,...> --allow <pos:regex,...> [--timeout N] [--max-output-bytes N] --json
        tatwo-ultrawork device-control validate --descriptor <file> --invocation '<json-or-@file>' --json
        tatwo-ultrawork device-control dispatch-plan --descriptor <file> --invocation '<json-or-@file>' --target-device <id> [--human-gate <token-file>] --out <job-file> --json
        tatwo-ultrawork device-control result-verify --result <file> --job <file> --json
        tatwo-ultrawork install plan --json
        tatwo-ultrawork host preflight --json
        tatwo-ultrawork host backup-plan --json
        tatwo-ultrawork host live-smoke-plan --json
        tatwo-ultrawork host receipt-flow --json
        tatwo-ultrawork host install-gate --host-rehearsal <id> --json
        node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json
        tatwo-ultrawork state export --json
        tatwo-ultrawork state set-mode --mode M --scenario code --json
        tatwo-ultrawork state plugin --id chatgpt-pro-mcp --action later --json
        tatwo-ultrawork memory add --category failure_mode --summary '<safe summary>' --json
        tatwo-ultrawork memory list --json
        tatwo-ultrawork context policy --json
        tatwo-ultrawork context compress --file build.log --run <runID> --kind auto --json
        tatwo-ultrawork context retrieve --id <ctx-id> --run <runID> --json
        tatwo-ultrawork context stats --json
        tatwo-ultrawork sandbox preflight --json
        tatwo-ultrawork validate sample-ui --json
        tatwo-ultrawork validate sample-operational --case host-live-good --json
        tatwo-ultrawork validate operational-receipt --file receipt.json --require host-live-same-thread --json
        tatwo-ultrawork validate receipt --file receipt.json --json
      """
    print(text)
  }

  static func outputOperationalGate(_ value: OperationalValidationOutput, command: String) {
    let passed = value.report.status == .passed
    printJSON(
      JSONEnvelope(
        ok: passed, command: command, data: value,
        error: passed ? nil : "operational_validation_failed"))
    if !passed {
      Foundation.exit(3)
    }
  }

  static func handleEngines(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "list":
      output(TatwoIdentityCatalog.engines, command: "engine list")
    case "capabilities":
      let raw = option("--engine", in: args) ?? "codex"
      let id = EngineID(rawValue: raw)
      guard let engine = TatwoIdentityCatalog.engine(id) else {
        throw CLIError.usage("Unknown engine: \(raw)")
      }
      output(engine, command: "engine capabilities")
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork engine list --json OR engine capabilities --engine codex --json")
    }
  }

  static func handleMCP(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "tools", "manifest":
      output(TatwoMCPRegistry.manifest, command: "mcp tools")
    case "client-config":
      let engine = option("--engine", in: args) ?? "generic-cli"
      output(TatwoMCPRegistry.clientConfig(for: engine), command: "mcp client-config")
    case "call":
      guard args.count >= 3 else {
        throw CLIError.usage("Use: tatwo-ultrawork mcp call <tool> --json")
      }
      let tool = args[2]
      let mcpArgs = mcpArguments(from: args)
      let result: TatwoMCPToolCallResult
      if let appURL = option("--app-url", in: args)
        ?? ProcessInfo.processInfo.environment["TATWO_APP_MCP_URL"]
      {
        if let appResult = callAppMCP(appURL: appURL, tool: tool, arguments: mcpArgs) {
          result = appResult
        } else if args.contains("--require-app") {
          throw CLIError.usage("App MCP unreachable at \(TatwoPrivacyRedactor.redacted(appURL))")
        } else {
          result = TatwoMCPRegistry.call(tool: tool, arguments: mcpArgs)
        }
      } else {
        result = TatwoMCPRegistry.call(tool: tool, arguments: mcpArgs)
      }
      output(result, command: "mcp call", ok: result.ok)
    case "serve":
      try handleMCPServe(args)
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork mcp manifest|tools --json OR mcp client-config --engine generic-cli --json OR mcp call <tool> --json OR mcp serve --stdio --json"
      )
    }
  }

  static func handleMCPServe(_ args: [String]) throws {
    if args.contains("--stdio") {
      if isatty(STDIN_FILENO) != 0 {
        output(TatwoMCPRegistry.manifest, command: "mcp serve --stdio")
        return
      }
      let input = FileHandle.standardInput.readDataToEndOfFile()
      if input.isEmpty {
        output(TatwoMCPRegistry.manifest, command: "mcp serve --stdio")
        return
      }
      let response = handleStdioMCP(input: input)
      printJSON(response)
      return
    }

    if let port = option("--port", in: args) {
      guard let parsed = UInt16(port) else {
        throw CLIError.usage("Invalid port: \(port)")
      }
      let server = TatwoLocalMCPHTTPServer()
      let actualPort = try server.start(port: parsed)
      output(TatwoLocalMCPHTTPServer.status(for: actualPort), command: "mcp serve --port")
      fflush(stdout)
      RunLoop.current.run()
    }

    throw CLIError.usage(
      "Use: tatwo-ultrawork mcp serve --stdio --json OR --port <local-port> --json")
  }

  static func handleWorkOS(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    let goalID = option("--goal", in: args) ?? option("--goalID", in: args)
    let contractID = option("--contract", in: args) ?? option("--contractID", in: args)
    let inferredContext = WorkOSFactory.inferContext(goalID: goalID, contractID: contractID)
    let mode = try WorkModeID.parse(
      option("--mode", in: args) ?? inferredContext?.mode.rawValue ?? "M")
    let scenario = option("--scenario", in: args) ?? inferredContext?.scenarioProfileID ?? "coding"
    let objective = option("--objective", in: args) ?? "Tatwo Work OS goal"
    let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()

    switch subcommand {
    case "constitution", "agents":
      output(WorkOSEnforcementFactory.constitution(), command: "os constitution")
    case "begin":
      if args.contains("--initialize-authority-locks") {
        output(
          try bootstrapFormalWorkOSAuthorityLocksOnly(
            args: args,
            mode: mode,
            scenario: scenario,
            objective: objective,
            scenarioBook: scenarioBook),
          command: "os begin authority bootstrap")
      } else {
        output(
          try beginFormalWorkOSSession(
            args: args,
            mode: mode,
            scenario: scenario,
            objective: objective,
            scenarioBook: scenarioBook).contract,
          command: "os begin")
      }
    case "dashboard":
      let contract = try WorkOSFactory.storedContractProjection(
        contractID: contractID,
        fallbackMode: mode,
        fallbackScenarioProfileID: scenario,
        fallbackObjective: objective,
        scenarioBook: scenarioBook)
      let storedReceiptIDs: [String]
      if let contractID {
        storedReceiptIDs =
          Array((try? TatwoGoalRunStore.default().submittedReceiptIDs(contractID: contractID)) ?? [])
      } else {
        storedReceiptIDs = []
      }
      output(
        TatwoWorkOSDashboardFactory.make(
          contract: contract,
          submittedReceiptIDs: Array(
            Set(
              options("--receipt", in: args) + options("--receiptID", in: args)
                + options("--receipts", in: args).flatMap { $0.split(separator: ",").map(String.init) }
                + storedReceiptIDs)),
          registry: TatwoDispatchRegistry.default()),
        command: "os dashboard")
    case "enforce":
      let contract =
        contractID == nil
        ? nil
        : try WorkOSFactory.storedContractProjection(
          contractID: contractID,
          fallbackMode: mode,
          fallbackScenarioProfileID: scenario,
          fallbackObjective: objective,
          scenarioBook: scenarioBook)
      let intent = WorkOSAgentActionIntent(
        contractID: contractID,
        identity: parseIdentity(option("--identity", in: args) ?? option("--role", in: args)),
        toolName: option("--tool", in: args) ?? option("--toolName", in: args) ?? "tatwo.os.next",
        requestedMutation: parseMutation(option("--mutation", in: args) ?? option("--requestedMutation", in: args)),
        sourceSurface: parseSurface(option("--surface", in: args) ?? option("--sourceSurface", in: args)),
        receiptID: option("--receipt", in: args) ?? option("--receiptID", in: args))
      let result = WorkOSEnforcementFactory.enforce(intent, contract: contract)
      output(result, command: "os enforce", ok: result.ok)
      if !result.ok { Foundation.exit(3) }
    case "handoff":
      let contract = try WorkOSFactory.storedContractProjection(
        contractID: contractID,
        fallbackMode: mode,
        fallbackScenarioProfileID: scenario,
        fallbackObjective: objective,
        scenarioBook: scenarioBook)
      output(WorkOSEnforcementFactory.handoffPack(contract: contract), command: "os handoff")
    case "next":
      let result = try WorkOSFactory.next(
        goalID: goalID,
        contractID: contractID,
        mode: mode,
        scenarioProfileID: scenario,
        objective: objective,
        scenarioBook: scenarioBook,
        store: TatwoGoalRunStore.default(),
        registry: TatwoDispatchRegistry.default())
      output(result, command: "os next", ok: result.ok)
      if !result.ok { Foundation.exit(3) }
    case "loop":
      guard args.dropFirst().dropFirst().first == "status" else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork os loop status --goal <id> --contract <id> --json")
      }
      let result = try WorkOSFactory.loopStatus(
        goalID: goalID,
        contractID: contractID,
        mode: mode,
        scenarioProfileID: scenario,
        objective: objective,
        scenarioBook: scenarioBook,
        store: TatwoGoalRunStore.default())
      output(result, command: "os loop status", ok: result.ok)
      if !result.ok { Foundation.exit(3) }
    case "receipt":
      guard args.dropFirst().dropFirst().first == "submit" else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork os receipt submit --goal <id> --contract <id> --receipt <id> --kind test --json"
        )
      }
      let result = WorkOSFactory.submitReceipt(
        goalID: goalID,
        contractID: contractID,
        loopID: option("--loop", in: args) ?? option("--loopID", in: args),
        receiptID: option("--receipt", in: args) ?? option("--receiptID", in: args),
        receiptKind: option("--kind", in: args) ?? option("--receiptKind", in: args) ?? "generic",
        store: TatwoGoalRunStore.default())
      output(result, command: "os receipt submit", ok: result.ok)
      if !result.ok { Foundation.exit(3) }
    case "goal":
      guard args.dropFirst().dropFirst().first == "close" else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork os goal close --goal <id> --contract <id> --receipt <id> --json")
      }
      let receiptIDs =
        options("--receipt", in: args) + options("--receiptID", in: args)
        + options("--receipts", in: args).flatMap { $0.split(separator: ",").map(String.init) }
      let goalStore = TatwoGoalRunStore.default()
      let result = try WorkOSFactory.closeGoal(
        goalID: goalID,
        contractID: contractID,
        mode: mode,
        scenarioProfileID: scenario,
        objective: objective,
        suppliedReceiptIDs: receiptIDs,
        scenarioBook: scenarioBook,
        store: goalStore,
        dispatchRegistry: TatwoDispatchRegistry(
          directoryURL: goalStore.directoryURL))
      output(result, command: "os goal close", ok: result.ok)
      if !result.ok { Foundation.exit(3) }
    case "dispatch":
      // B2: record a real sub-dispatch to a gateway model. The Node MCP wrapper (which owns
      // the live HTTP call) brackets its dispatch with `begin`/`update` so the dashboard shows
      // real subs. Fail closed on an unregistered contract before touching the registry.
      guard let sub = args.dropFirst().dropFirst().first,
        ["begin", "update", "finalize", "advance", "list"].contains(sub)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork os dispatch begin|update|finalize|advance|list --contract <id> --json")
      }
      // #2: authorized via the universal chokepoint (contract authentication + dev bypass).
      let dispatchToll = TatwoWorkOSChokepoint.authorize(
        contractID: contractID, action: "os.dispatch.\(sub)")
      guard dispatchToll.ok else { throw CLIError.usage(dispatchToll.message) }
      let dispatchRegistry = TatwoDispatchRegistry.default()
      let goalStore = TatwoGoalRunStore.default()
      switch sub {
      case "begin":
        // B1: derive the S/M/L/XL helper cap from the contract's own mode; registry.begin
        // enforces it as the single sink (so any dispatch path is capped, not just the CLI).
        let capMode = WorkOSFactory.inferContext(goalID: goalID, contractID: contractID)?.mode ?? mode
        let helperCap = TatwoCatalog.defaults.mode(capMode)?.maxHelpers ?? 0
        let record = try TatwoGoalRunDispatchLifecycle.begin(
          contractID: contractID ?? "",
          bindingID: option("--binding", in: args) ?? "",
          sourceSlotID: option("--slot", in: args) ?? option("--sourceSlot", in: args) ?? "",
          identity: parseIdentity(option("--identity", in: args)),
          modelID: option("--model", in: args) ?? "",
          subtask: option("--subtask", in: args) ?? "",
          logicalDispatchID: option("--logical-dispatch", in: args)
            ?? option("--logicalDispatchID", in: args),
          supersedes: option("--supersedes", in: args),
          helperCap: helperCap,
          goalStore: goalStore,
          dispatchRegistry: dispatchRegistry)
        output(record, command: "os dispatch begin")
      case "update":
        let status = TatwoDispatchStatus(rawValue: option("--status", in: args) ?? "") ?? .running
        let record = try TatwoGoalRunDispatchLifecycle.update(
          contractID: contractID ?? "",
          dispatchID: option("--dispatch", in: args) ?? option("--dispatchID", in: args) ?? "",
          status: status,
          receiptID: option("--receipt", in: args) ?? option("--receiptID", in: args),
          outputRef: option("--output-ref", in: args) ?? option("--outputRef", in: args),
          failureClass: option("--failure-class", in: args)
            .flatMap(TatwoDispatchFailureClass.init(rawValue:)),
          errorCode: option("--error-code", in: args),
          httpStatus: option("--http-status", in: args).flatMap(Int.init),
          rawErrorDigest: option("--raw-error-digest", in: args),
          backendRequestID: option("--backend-request-id", in: args),
          backendResponseID: option("--backend-response-id", in: args),
          errorMessage: option("--error", in: args),
          goalStore: goalStore,
          dispatchRegistry: dispatchRegistry)
        output(record, command: "os dispatch update")
      case "finalize":
        let record = try TatwoGoalRunDispatchLifecycle.finalize(
          contractID: contractID ?? "",
          goalStore: goalStore,
          dispatchRegistry: dispatchRegistry)
        output(record, command: "os dispatch finalize")
      case "advance":
        let expectedSealID =
          option("--expected-seal", in: args)
          ?? option("--expectedSealID", in: args)
          ?? ""
        guard !expectedSealID.isEmpty else {
          throw CLIError.usage(
            "Use: tatwo-ultrawork os dispatch advance --contract <id> --expected-seal <seal> --json")
        }
        let record = try TatwoGoalRunDispatchLifecycle.advanceCycle(
          contractID: contractID ?? "",
          expectedSealID: expectedSealID,
          goalStore: goalStore,
          dispatchRegistry: dispatchRegistry)
        output(record, command: "os dispatch advance")
      default:
        let run = try dispatchRegistry.run(forContractID: contractID ?? "")
        output(
          run ?? TatwoStoredDispatchRun(contractID: contractID ?? ""),
          command: "os dispatch list")
      }
    case "recovery":
      guard args.dropFirst().dropFirst().first == "begin" else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork os recovery begin --contract <failed-id> --authorization <token> --reason <text> --adjudication-ref <ref> --json")
      }
      let recoveryToll = TatwoWorkOSChokepoint.authorize(
        contractID: contractID, action: "os.recovery.begin")
      guard recoveryToll.ok else { throw CLIError.usage(recoveryToll.message) }
      let authorization =
        option("--authorization", in: args)
        ?? ProcessInfo.processInfo.environment["TATWO_RECOVERY_AUTH_TOKEN"]
        ?? ""
      let record = try TatwoGoalRunStore.default().createRecovery(
        originalContractID: contractID ?? "",
        authorizationToken: authorization,
        reason: option("--reason", in: args) ?? "operator recovery",
        adjudicationRef: option("--adjudication-ref", in: args) ?? "unspecified")
      output(record, command: "os recovery begin")
    case "cooldown":
      guard let sub = args.dropFirst().dropFirst().first,
        ["block", "clear", "status"].contains(sub)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork os cooldown block|clear|status --contract <id> --json")
      }
      let cooldownToll = TatwoWorkOSChokepoint.authorize(
        contractID: contractID, action: "os.cooldown.\(sub)")
      guard cooldownToll.ok else { throw CLIError.usage(cooldownToll.message) }
      let goalStore = TatwoGoalRunStore.default()
      switch sub {
      case "block":
        let current = try goalStore.requireIssuedContract(contractID ?? "")
        guard current.status == .planned || current.status == .blocked else {
          throw CLIError.usage(
            "Cooldown can only block a planned GoalRun; current=\(current.status.rawValue).")
        }
        let record = try goalStore.updateCooldownStatus(
          contractID: contractID ?? "",
          status: .blocked,
          reason: option("--reason", in: args) ?? "cooldown")
        output(record, command: "os cooldown block")
      case "clear":
        let record = try goalStore.updateCooldownStatus(
          contractID: contractID ?? "",
          status: .planned,
          reason: option("--reason", in: args) ?? "cooldown_cleared")
        output(record, command: "os cooldown clear")
      default:
        output(
          try goalStore.requireIssuedContract(contractID ?? ""),
          command: "os cooldown status")
      }
    case "contract":
      // B2/E: thin wrapper the Node gateway policy calls to prove a contract is registered
      // before a paid dispatch. Throws (non-zero exit) if the contractID was never issued.
      guard args.dropFirst().dropFirst().first == "require" else {
        throw CLIError.usage("Use: tatwo-ultrawork os contract require --contract <id> --json")
      }
      let contractToll = TatwoWorkOSChokepoint.authorize(
        contractID: contractID, action: "os.contract.require")
      guard contractToll.ok else { throw CLIError.usage(contractToll.message) }
      output(
        ["ok": "true", "contractID": contractID ?? "", "chokepoint": contractToll.code],
        command: "os contract require")
    case "session":
      // Q1: persistent OS session — start once, then any terminal (or a Claude Code
      // SessionStart hook) can re-attach via `attach` without re-typing $tatwo-ultrawork.
      guard let sub = args.dropFirst().dropFirst().first,
        [
          "start",
          "status",
          "attach",
          "revise",
          "revision-recovery-plan",
          "revision-recovery-enroll",
          "stop",
        ].contains(sub)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork os session start|status|attach|revise|revision-recovery-plan|revision-recovery-enroll|stop --json"
        )
      }
      let sessionStore = TatwoSessionStore.default()
      switch sub {
      case "start":
        if args.contains("--initialize-authority-locks") {
          output(
            try bootstrapFormalWorkOSAuthorityLocksOnly(
              args: args,
              mode: mode,
              scenario: scenario,
              objective: objective,
              scenarioBook: scenarioBook),
            command: "os session authority bootstrap")
        } else {
          output(
            try beginFormalWorkOSSession(
              args: args,
              mode: mode,
              scenario: scenario,
              objective: objective,
              scenarioBook: scenarioBook),
            command: "os session start")
        }
      case "status":
        if let pointer = try sessionStore.current() {
          // B1/Q1: guard against a stale pointer — verify its contract is still a registered
          // GoalRun before re-attaching (a hook shouldn't resurrect a cleared/expired session).
          let record = (try? TatwoGoalRunStore.default().record(forContractID: pointer.contractID)) ?? nil
          if record != nil {
            output(pointer, command: "os session status")
          } else {
            output(
              ["active": "false", "stale": "true",
               "message": "session pointer is stale (contract no longer registered); run: tatwo-ultrawork os session start"],
              command: "os session status")
          }
        } else {
          output(
              ["active": "false", "message": "no active OS session; run: tatwo-ultrawork os session start"],
              command: "os session status")
          }
      case "attach":
        let owner = try requiredCanonicalSessionOwner(in: args)
        output(
          try sessionStore.attachCurrent(
            ownerVerification: .canonicalV3(owner),
            expectedContractID: contractID,
            expectedGoalID: goalID,
            expectedMode: try option("--mode", in: args).map(WorkModeID.parse),
            expectedScenario: option("--scenario", in: args),
            expectedObjective: option("--objective", in: args),
            scenarioBook: scenarioBook,
            goalStore: TatwoGoalRunStore.default()),
          command: "os session attach")
      case "revise":
        let authorizationID = try requiredOption("--authorization", in: args)
        let transition = try sessionStore.transitionCurrentToPlannedRevision(
          authorizationID: authorizationID,
          goalStore: TatwoGoalRunStore.default(),
          dispatchRegistry: TatwoDispatchRegistry.default())
        guard let transitionOwner = transition.pointer.ownerBinding else {
          throw TatwoSessionAttachmentError.invalidOwnerBinding("missing")
        }
        let readback = try sessionStore.attachCurrent(
          ownerVerification: .legacyV2(
            TatwoSessionOwnerExpectationV1(
              provider: transitionOwner.provider,
              externalProviderSessionID: transitionOwner.sessionID,
              workspacePath: transitionOwner.workspacePath)),
          expectedContractID: transition.successor.contractID,
          expectedGoalID: transition.successor.goalID,
          expectedMode: transition.pointer.mode,
          expectedScenario: transition.pointer.scenario,
          expectedObjective: transition.pointer.objective,
          scenarioBook: scenarioBook,
          goalStore: TatwoGoalRunStore.default())
        output(
          TatwoSessionRevisionCLIOutputV1(
            transition: transition,
            readback: readback),
          command: "os session revise")
      case "revision-recovery-plan":
        try TatwoGoalRevisionRecoveryCLI.preparePlan(args)
      case "revision-recovery-enroll":
        try TatwoGoalRevisionRecoveryCLI.enroll(args)
      default:
        let owner = try requiredCanonicalSessionOwner(in: args)
        if let stopped = try sessionStore.stopCurrent(
          ownerVerification: .canonicalV3(owner),
          goalStore: TatwoGoalRunStore.default())
        {
          output(stopped, command: "os session stop")
        } else {
          output(
            ["active": "false", "message": "no active OS session"],
            command: "os session stop")
        }
      }
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork os begin|dashboard|enforce|handoff|constitution|next|loop status|receipt submit|goal close|dispatch begin|update|finalize|advance|list|recovery begin|cooldown block|clear|status|contract require|session start|status|attach|revise|revision-recovery-plan|revision-recovery-enroll|stop --json"
      )
    }
  }

  static func parseIdentity(_ raw: String?) -> IdentityKind {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "lead", "主導": return .lead
    case "supervisor", "監督", "reviewer", "副審": return .supervisor
    case "consultant", "顧問": return .consultant
    case "sub", "helper": return .sub
    case "news", "消息": return .news
    case "verifier", "驗收", "judge": return .verifier
    default: return .sub
    }
  }

  static func parseMutation(_ raw: String?) -> WorkOSActionMutation {
    let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.flatMap(WorkOSActionMutation.init(rawValue:)) ?? .readOnly
  }

  static func parseSurface(_ raw: String?) -> WorkOSActionSurface {
    let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.flatMap(WorkOSActionSurface.init(rawValue:)) ?? .cli
  }

  static func handleStdioMCP(input: Data) -> TatwoMCPToolCallResult {
    guard
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
    else {
      return TatwoMCPToolCallResult(
        tool: "mcp.stdio", ok: true,
        payload: (try? JSONValue.fromEncodable(TatwoMCPRegistry.manifest)) ?? .null)
    }

    if (object["method"] as? String) == "tools/list" {
      return TatwoMCPToolCallResult(
        tool: "tools/list", ok: true,
        payload: (try? JSONValue.fromEncodable(TatwoMCPRegistry.manifest)) ?? .null)
    }

    let tool =
      (object["tool"] as? String)
      ?? ((object["params"] as? [String: Any])?["name"] as? String)
      ?? (object["name"] as? String)
      ?? "tatwo.identities.list"
    let rawArguments =
      (object["arguments"] as? [String: Any])
      ?? ((object["params"] as? [String: Any])?["arguments"] as? [String: Any])
      ?? [:]
    return TatwoMCPRegistry.call(
      tool: tool, arguments: rawArguments.mapValues { JSONValue.fromAny($0) })
  }

  static func mcpArguments(from args: [String]) -> [String: JSONValue] {
    var arguments = forwardedMCPFlagArguments(from: args)
    if let mode = option("--mode", in: args) { arguments["mode"] = .string(mode) }
    if let scenario = option("--scenario", in: args) { arguments["scenario"] = .string(scenario) }
    if let objective = option("--objective", in: args) {
      arguments["objective"] = .string(objective)
    }
    if let engine = option("--engine", in: args) { arguments["engine"] = .string(engine) }
    if let goal = option("--goal", in: args) ?? option("--goalID", in: args) {
      arguments["goalID"] = .string(goal)
    }
    if let contract = option("--contract", in: args) ?? option("--contractID", in: args) {
      arguments["contractID"] = .string(contract)
    }
    if let loop = option("--loop", in: args) ?? option("--loopID", in: args) {
      arguments["loopID"] = .string(loop)
    }
    if let receipt = option("--receipt", in: args) ?? option("--receiptID", in: args) {
      arguments["receiptID"] = .string(receipt)
    }
    if let receiptKind = option("--kind", in: args) ?? option("--receiptKind", in: args) {
      arguments["receiptKind"] = .string(receiptKind)
    }
    if let toolName = option("--tool", in: args) ?? option("--toolName", in: args) {
      arguments["toolName"] = .string(toolName)
    }
    if let identity = option("--identity", in: args) ?? option("--role", in: args) {
      arguments["identity"] = .string(identity)
    }
    if let mutation = option("--mutation", in: args) ?? option("--requestedMutation", in: args) {
      arguments["mutation"] = .string(mutation)
    }
    if let surface = option("--surface", in: args) ?? option("--sourceSurface", in: args) {
      arguments["surface"] = .string(surface)
    }
    if let suite = option("--suite", in: args) { arguments["suite"] = .string(suite) }
    if let run = option("--run", in: args) ?? option("--runID", in: args) {
      arguments["runID"] = .string(run)
    }
    if let models = option("--models", in: args) { arguments["models"] = .string(models) }
    // `--model` is used by gateway dispatch. Older scenario-config helpers also accepted
    // it as a modelIDs shortcut, so keep the forwarded modelIDs value but expose the
    // singular model key too.
    if let model = option("--model", in: args) { arguments["model"] = .string(model) }
    if let olderThan = option("--older-than", in: args) ?? option("--olderThan", in: args) {
      arguments["olderThan"] = .string(olderThan)
    }
    if args.contains("--dry-run") { arguments["dryRun"] = .bool(true) }
    if let target = option("--target", in: args) { arguments["target"] = .string(target) }
    if let targetKind = option("--target-kind", in: args) ?? option("--targetKind", in: args) {
      arguments["targetKind"] = .string(targetKind)
    }
    if let scanType = option("--scan-type", in: args) ?? option("--scanType", in: args) {
      arguments["scanType"] = .string(scanType)
    }
    if let blocking = option("--blocking", in: args) ?? option("--blocking-policy", in: args)
      ?? option("--blockingPolicy", in: args)
    {
      arguments["blockingPolicy"] = .string(blocking)
    }
    if let report = option("--report", in: args) ?? option("--report-path", in: args)
      ?? option("--reportPath", in: args)
    {
      arguments["reportPath"] = .string(report)
    }
    if let reportJSON = option("--report-json", in: args) ?? option("--reportJSON", in: args) {
      arguments["reportJSON"] = .string(reportJSON)
    }
    if let command = option("--command", in: args) { arguments["command"] = .string(command) }
    let receiptIDs =
      options("--receipt", in: args) + options("--receiptID", in: args)
      + options("--receipts", in: args).flatMap { $0.split(separator: ",").map(String.init) }
    if !receiptIDs.isEmpty {
      arguments["receiptIDs"] = .array(receiptIDs.map { .string($0) })
    }
    if let json = option("--arguments", in: args),
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      for (key, value) in object {
        arguments[key] = JSONValue.fromAny(value)
      }
    }
    return arguments
  }

  static func forwardedMCPFlagArguments(from args: [String]) -> [String: JSONValue] {
    var arguments: [String: JSONValue] = [:]
    var index = args.startIndex
    while index < args.endIndex {
      let raw = args[index]
      guard raw.hasPrefix("--"), raw.count > 2 else {
        index = args.index(after: index)
        continue
      }

      let parsed: (name: String, value: String?)?
      if let equalsIndex = raw.firstIndex(of: "=") {
        let name = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<equalsIndex])
        let value = String(raw[raw.index(after: equalsIndex)...])
        parsed = (name, value)
      } else {
        let name = String(raw.dropFirst(2))
        let nextIndex = args.index(after: index)
        if nextIndex < args.endIndex, !args[nextIndex].hasPrefix("--") {
          parsed = (name, args[nextIndex])
          index = nextIndex
        } else {
          parsed = (name, nil)
        }
      }

      if let parsed,
        !mcpControlFlagNames.contains(parsed.name),
        let key = mcpArgumentKey(for: parsed.name)
      {
        arguments[key] = parsed.value.map(JSONValue.string) ?? .bool(true)
      }
      index = args.index(after: index)
    }
    return arguments
  }

  static func mcpArgumentKey(for rawName: String) -> String? {
    let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    if let alias = mcpArgumentFlagAliases[normalized] { return alias }
    return camelCaseFlagName(normalized)
  }

  static func camelCaseFlagName(_ rawName: String) -> String {
    let parts = rawName.split(separator: "-").map(String.init)
    guard let first = parts.first else { return rawName }
    return parts.dropFirst().reduce(first) { partial, part in
      guard let firstScalar = part.unicodeScalars.first else { return partial }
      let head = String(firstScalar).uppercased()
      let tail = String(part.unicodeScalars.dropFirst())
      return partial + head + tail
    }
  }

  static let mcpControlFlagNames: Set<String> = [
    "json", "app-url", "require-app", "arguments",
  ]

  static let mcpArgumentFlagAliases: [String: String] = [
    "goal": "goalID",
    "goal-id": "goalID",
    "goalID": "goalID",
    "contract": "contractID",
    "contract-id": "contractID",
    "contractID": "contractID",
    "loop": "loopID",
    "loop-id": "loopID",
    "loopID": "loopID",
    "receipt": "receiptID",
    "receipt-id": "receiptID",
    "receiptID": "receiptID",
    "receipt-kind": "receiptKind",
    "receiptKind": "receiptKind",
    "kind": "receiptKind",
    "authorization": "authorizationID",
    "authorization-id": "authorizationID",
    "authorizationID": "authorizationID",
    "tool": "toolName",
    "tool-name": "toolName",
    "toolName": "toolName",
    "role": "identity",
    "requested-mutation": "requestedMutation",
    "requestedMutation": "requestedMutation",
    "source-surface": "sourceSurface",
    "sourceSurface": "sourceSurface",
    "run": "runID",
    "run-id": "runID",
    "runID": "runID",
    "older-than": "olderThan",
    "olderThan": "olderThan",
    "target-kind": "targetKind",
    "targetKind": "targetKind",
    "scan-type": "scanType",
    "scanType": "scanType",
    "blocking-policy": "blockingPolicy",
    "blockingPolicy": "blockingPolicy",
    "report-path": "reportPath",
    "reportPath": "reportPath",
    "report-json": "reportJSON",
    "reportJSON": "reportJSON",
    "base": "baseScenario",
    "base-scenario": "baseScenario",
    "baseScenario": "baseScenario",
    "display-name": "displayName",
    "displayName": "displayName",
    "token-budget": "tokenBudget",
    "tokenBudget": "tokenBudget",
    "binding": "bindingID",
    "binding-id": "bindingID",
    "bindingID": "bindingID",
    "model": "modelIDs",
    "model-id": "modelIDs",
    "model-ids": "modelIDs",
    "modelID": "modelIDs",
    "modelIDs": "modelIDs",
  ]

  static func callAppMCP(
    appURL: String, tool: String, arguments: [String: JSONValue]
  ) -> TatwoMCPToolCallResult? {
    guard let base = URL(string: appURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    let endpoint = base.appendingPathComponent("tools/call")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 2.5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(
      MCPHTTPCallRequest(tool: tool, arguments: arguments))

    let semaphore = DispatchSemaphore(value: 0)
    let output = LockedMCPResultBox()
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      guard
        let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        let data
      else {
        return
      }
      output.set(try? JSONDecoder().decode(TatwoMCPToolCallResult.self, from: data))
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 3.0)
    return output.get()
  }

  static func operationalRequirement(from raw: String, args: [String]) throws
    -> OperationalReceiptRequirement
  {
    switch raw {
    case "host-live-same-thread":
      return .hostLiveSameThread()
    case "mcp-host-registration":
      return .mcpHostRegistration()
    case "host-install-approval":
      let epoch = Int(option("--required-epoch", in: args) ?? "1") ?? 1
      return .hostInstallApproval(requiredEpoch: epoch)
    case "sandbox-operational":
      return .sandboxOperational()
    default:
      throw CLIError.usage("Unknown operational requirement: \(raw)")
    }
  }

  static func handleHost(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "executor-plan":
      output(TatwoHostExecutorPlanV1(), command: "host executor-plan")
    case "authorize-revision":
      let authorizationID = try requiredOption("--authorization", in: args)
      output(
        try TatwoHostApprovalStore.default().issueHostOperationBound(
          authorizationID: authorizationID,
          sessionStore: TatwoSessionStore.default()),
        command: "host authorize-revision")
    case "authorize":
      guard args.contains("--human-approved") else {
        throw CLIError.usage(
          "This action can change files or run commands on this Mac. "
            + "After the user confirms, add --human-approved.")
      }
      guard
        let contractID = option("--contract", in: args),
        let workspace = option("--workspace", in: args)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork host authorize --contract <id> --workspace <path> --actions read_file,write_file,run_command,rollback --human-approved --json")
      }
      let actions = (option("--actions", in: args) ?? "")
        .split(separator: ",")
        .compactMap {
          TatwoHostActionKind(
            rawValue: String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }
      guard !actions.isEmpty else {
        throw CLIError.usage("At least one valid --actions value is required.")
      }
      let ttl = Double(option("--ttl-seconds", in: args) ?? "1800") ?? 1800
      output(
        try TatwoHostApprovalStore.default().issue(
          contractID: contractID, workspaceRoot: workspace,
          allowedActions: actions, ttl: ttl),
        command: "host authorize")
    case "revoke":
      guard let leaseID = option("--lease", in: args) else {
        throw CLIError.usage("Use: tatwo-ultrawork host revoke --lease <id> --json")
      }
      try TatwoHostApprovalStore.default().revoke(id: leaseID)
      output(
        JSONValue.object(["ok": .bool(true), "leaseID": .string(leaseID)]),
        command: "host revoke")
    case "cleanup-leases":
      output(
        try TatwoHostApprovalStore.default().cleanupExpired(),
        command: "host cleanup-leases")
    case "read":
      guard
        let contractID = option("--contract", in: args),
        let leaseID = option("--lease", in: args),
        let workspace = option("--workspace", in: args),
        let relativePath = option("--path", in: args)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork host read --contract <id> --lease <id> --workspace <path> --path <relative> --json")
      }
      output(
        try TatwoHostExecutor.default().readFile(
          contractID: contractID, leaseID: leaseID, workspaceRoot: workspace,
          relativePath: relativePath),
        command: "host read")
    case "write":
      guard
        let contractID = option("--contract", in: args),
        let leaseID = option("--lease", in: args),
        let workspace = option("--workspace", in: args),
        let relativePath = option("--path", in: args)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork host write --contract <id> --lease <id> --workspace <path> --path <relative> --content-file <file> --json")
      }
      let content: String
      if let contentFile = option("--content-file", in: args) {
        content = try String(contentsOfFile: contentFile, encoding: .utf8)
      } else if let inlineContent = option("--content", in: args) {
        content = inlineContent
      } else {
        throw CLIError.usage("Host write requires --content-file or --content.")
      }
      output(
        try TatwoHostExecutor.default().writeFile(
          contractID: contractID, leaseID: leaseID, workspaceRoot: workspace,
          relativePath: relativePath, content: content),
        command: "host write")
    case "run":
      guard
        let contractID = option("--contract", in: args),
        let leaseID = option("--lease", in: args),
        let workspace = option("--workspace", in: args),
        let executable = option("--executable", in: args)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork host run --contract <id> --lease <id> --workspace <path> --executable <path> --argv-json '[\"arg\"]' --json")
      }
      let argvData = Data((option("--argv-json", in: args) ?? "[]").utf8)
      let argv = try JSONDecoder().decode([String].self, from: argvData)
      #if os(macOS)
      output(
        try TatwoHostExecutor.default().runCommand(
          contractID: contractID, leaseID: leaseID, workspaceRoot: workspace,
          executable: executable, arguments: argv,
          timeout: Double(option("--timeout-seconds", in: args) ?? "120") ?? 120),
        command: "host run")
      #else
      throw TatwoHostExecutorError.unsupportedPlatform
      #endif
    case "rollback":
      guard
        let contractID = option("--contract", in: args),
        let leaseID = option("--lease", in: args),
        let workspace = option("--workspace", in: args),
        let receiptFile = option("--receipt-file", in: args)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork host rollback --contract <id> --lease <id> --workspace <path> --receipt-file <write-receipt.json> --json")
      }
      let decoder = JSONDecoder()
      let receipt = try decoder.decode(
        TatwoHostExecutionReceiptV1.self,
        from: Data(contentsOf: URL(fileURLWithPath: receiptFile)))
      output(
        try TatwoHostExecutor.default().rollback(
          contractID: contractID, leaseID: leaseID, workspaceRoot: workspace,
          writeReceipt: receipt),
        command: "host rollback")
    case "preflight":
      output(HostPreparationFactory.preflightTemplate(), command: "host preflight")
    case "backup-plan":
      output(HostPreparationFactory.backupPlan(), command: "host backup-plan")
    case "live-smoke-plan":
      output(HostPreparationFactory.liveSmokePlan(), command: "host live-smoke-plan")
    case "receipt-flow":
      output(HostPreparationFactory.receiptFlow(), command: "host receipt-flow")
    case "install-gate":
      let receipts = HostInstallReceiptSet(
        sandboxValidated: args.contains("--sandbox-validated"),
        hostSandboxRehearsalReceiptID: option("--host-rehearsal", in: args),
        preflightClear: args.contains("--preflight-clear"),
        humanApprovalReceiptID: option("--human-approval", in: args),
        backupReceiptID: option("--backup-receipt", in: args),
        liveSameThreadSmokeReceiptID: option("--same-thread-smoke", in: args),
        mcpRegistrationSmokeReceiptID: option("--mcp-registration-smoke", in: args),
        rollbackReceiptID: option("--rollback-receipt", in: args)
      )
      let decision = HostPreparationFactory.evaluateHostInstall(receipts: receipts)
      output(decision, command: "host install-gate", ok: decision.hostInstallAllowed)
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork host executor-plan|authorize-revision|authorize|revoke|cleanup-leases|read|write|run|rollback|preflight|backup-plan|live-smoke-plan|receipt-flow|install-gate --json"
      )
    }
  }

  static func handleComputer(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "status":
      output(TatwoComputerHost.status(), command: "computer status")
    case "execute":
      guard
        let contractID = option("--contract", in: args),
        let leaseID = option("--lease", in: args),
        let workspace = option("--workspace", in: args),
        let rawAction = option("--action", in: args),
        let action = TatwoComputerActionKind(rawValue: rawAction)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork computer execute --contract <id> --lease <id> --workspace <path> --action open_app|activate_app|type_text|press_key|screenshot|mouse_move|mouse_click|mouse_double_click|scroll --value <value> --json")
      }
      #if os(macOS)
      output(
        try TatwoComputerHost().execute(
          contractID: contractID,
          leaseID: leaseID,
          workspaceRoot: workspace,
          action: action,
          value: option("--value", in: args) ?? ""),
        command: "computer execute")
      #else
      throw TatwoHostExecutorError.unsupportedPlatform
      #endif
    default:
      throw CLIError.usage("Use: tatwo-ultrawork computer status|execute --json")
    }
  }

  static func handleTeams(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "traits", "trait":
      output(TeamRoutingCatalog.modelTraits, command: "teams traits")
    case "leads", "lead-strategies", "lead":
      output(TeamRoutingCatalog.leadStrategies, command: "teams leads")
    case "list":
      output(TeamRoutingCatalog.teams, command: "teams list")
    case "recommend":
      let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
      let scenario = try ScenarioID.parse(option("--scenario", in: args) ?? "coding")
      output(
        TeamRoutingCatalog.recommend(mode: mode, scenario: scenario), command: "teams recommend")
    case "dashboard", "readiness":
      let mode = try WorkModeID.parse(option("--mode", in: args) ?? "XL")
      let scenario = try ScenarioID.parse(option("--scenario", in: args) ?? "coding")
      output(
        TeamRoutingCatalog.readinessDashboard(mode: mode, scenario: scenario),
        command: "teams dashboard")
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork teams traits|leads|list|recommend|dashboard --mode L --scenario design --json"
      )
    }
  }

  static func handleIntegration(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "plan":
      output(IntegrationPlanner.makePlan(), command: "integration plan")
    case "stability":
      output(IntegrationPlanner.stabilityPlan(), command: "integration stability")
    case "fugu-policy":
      output(IntegrationPlanner.fuguArchitecturePolicy(), command: "integration fugu-policy")
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork integration plan --json OR tatwo-ultrawork integration stability --json OR tatwo-ultrawork integration fugu-policy --json"
      )
    }
  }

  static func handleArena(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "plan-loop-goal", "plg-policy", "policy":
      let action = args.dropFirst(2).first
      if action == "score" || action == "grade" {
        output(planLoopGoalScoreReport(args), command: "arena plan-loop-goal score")
      } else {
        output(
          TatwoArenaPolicyFactory.planLoopGoalProtocol(),
          command: "arena plan-loop-goal policy")
      }
    case "plg-score", "plg-grade":
      output(planLoopGoalScoreReport(args), command: "arena plan-loop-goal score")
    case "goal-cycle":
      let action = args.dropFirst(2).first
      guard action == "assess" || action == nil else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork arena goal-cycle assess --cycles <n> [--sealed] [--hash-changed] --json")
      }
      let cycles = Int(option("--cycles", in: args) ?? option("--goalExecutionCycles", in: args) ?? "0") ?? 0
      let sealed = args.contains("--sealed") || args.contains("--finalSubmissionSealed")
      let hashChanged = args.contains("--hash-changed") || args.contains("--fileHashesChangedAfterSeal")
      output(
        TatwoArenaPolicyFactory.assessGoalCycle(
          goalExecutionCycles: cycles,
          finalSubmissionSealed: sealed,
          fileHashesChangedAfterSeal: hashChanged),
        command: "arena goal-cycle assess")
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork arena plan-loop-goal --json OR arena plan-loop-goal score --expected 3 --completed 3 --cycles 5 --sealed --artifacts <files> --json OR tatwo-ultrawork arena goal-cycle assess --cycles 5 --json")
    }
  }

  static func planLoopGoalScoreReport(_ args: [String]) -> TatwoArenaPlanLoopGoalScoreReport {
    let model = option("--model", in: args) ?? option("--modelSlug", in: args) ?? "unknown"
    let expected = Int(option("--expected", in: args) ?? option("--expectedSandboxTests", in: args) ?? "0") ?? 0
    let completed = Int(option("--completed", in: args) ?? option("--completedSandboxTests", in: args) ?? "0") ?? 0
    let cycles = Int(option("--cycles", in: args) ?? option("--goalExecutionCycles", in: args) ?? "0") ?? 0
    let sealed = args.contains("--sealed") || args.contains("--finalSubmissionSealed")
    let hashChanged = args.contains("--hash-changed") || args.contains("--fileHashesChangedAfterSeal")
    let toolChoicesRegistered =
      args.contains("--tool-choices-registered") || args.contains("--toolChoicesAllRegistered")
    let artifacts =
      options("--artifact", in: args)
      + options("--artifacts", in: args).flatMap { $0.split(separator: ",").map(String.init) }
      + options("--presentArtifacts", in: args).flatMap { $0.split(separator: ",").map(String.init) }
    let missing =
      options("--missing", in: args)
      + options("--missingSandboxTests", in: args).flatMap { $0.split(separator: ",").map(String.init) }
    return TatwoArenaPolicyFactory.scorePlanLoopGoal(
      modelSlug: model,
      expectedSandboxTests: expected,
      completedSandboxTests: completed,
      missingSandboxTests: missing,
      goalExecutionCycles: cycles,
      finalSubmissionSealed: sealed,
      fileHashesChangedAfterSeal: hashChanged,
      presentArtifacts: artifacts,
      toolChoicesAllRegistered: toolChoicesRegistered)
  }

  static func handleCleanupInventory(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    guard subcommand == "write" || subcommand == "template" || subcommand == "validate" else {
      throw CLIError.usage(
        "Use: tatwo-ultrawork cleanup-inventory write --run <runID> --goal <goalID> --candidate '<path>|<origin>|<reason>|<risk>' --json OR cleanup-inventory template --run <runID> --goal <goalID> --json OR cleanup-inventory validate --file <cleanup-inventory.json> --json"
      )
    }

    if subcommand == "validate" {
      guard let file = option("--file", in: args) else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork cleanup-inventory validate --file <cleanup-inventory.json> --json")
      }
      let data = try Data(contentsOf: URL(fileURLWithPath: file))
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let inventory = try decoder.decode(PostValidationCleanupInventoryV1.self, from: data)
      outputGate(
        PostValidationCleanupInventoryGate.evaluate(inventory),
        command: "cleanup-inventory validate")
      return
    }

    guard let runID = option("--run", in: args) ?? option("--runID", in: args) else {
      throw CLIError.usage("cleanup-inventory requires --run <runID>")
    }
    guard let goalID = option("--goal", in: args) ?? option("--goalID", in: args) else {
      throw CLIError.usage("cleanup-inventory requires --goal <goalID>")
    }

    let inventory = PostValidationCleanupInventoryFactory.make(
      runID: runID,
      validatedGoalID: goalID,
      validatedContractID: option("--contract", in: args) ?? option("--contractID", in: args),
      candidateFiles: try cleanupCandidates(from: args),
      mustKeep: options("--keep", in: args) + options("--must-keep", in: args),
      summary: option("--summary", in: args)
        ?? "驗收通過後建立，用於未來刪除前確認來源、用途與移除合理性。")

    if subcommand == "template" || args.contains("--dry-run") {
      output(
        try PostValidationCleanupInventoryWriter.write(
          inventory,
          root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
          dryRun: true),
        command: "cleanup-inventory \(subcommand ?? "template")")
      return
    }

    output(
      try PostValidationCleanupInventoryWriter.write(
        inventory,
        root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)),
      command: "cleanup-inventory write")
  }

  static func cleanupCandidates(from args: [String]) throws -> [PostValidationCleanupCandidateV1] {
    try options("--candidate", in: args).enumerated().map { index, raw in
      let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 4 else {
        throw CLIError.usage(
          "cleanup candidate format: '<path>|<origin>|<reason>|<risk>'")
      }
      let safeToRemove: Bool
      if parts.indices.contains(4) {
        safeToRemove = !["0", "false", "no", "否"].contains(parts[4].lowercased())
      } else {
        safeToRemove = true
      }
      return PostValidationCleanupCandidateV1(
        id: "candidate-\(index + 1)",
        relativePath: parts[0],
        origin: parts[1],
        removalReason: parts[2],
        safeToRemove: safeToRemove,
        deletionRisk: parts[3])
    }
  }

  static func handleWebArena(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    let suite = TatwoWebArenaFactory.suiteFromString(option("--suite", in: args))
    let runID = option("--run", in: args) ?? option("--runID", in: args)
      ?? TatwoWebArenaRuntime.defaultRunID()
    let modelArgs = options("--models", in: args)
    let models = TatwoWebArenaFactory.normalizeModels(
      modelArgs.isEmpty ? TatwoWebArenaFactory.defaultModelSlugs : modelArgs)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    switch subcommand {
    case "plan":
      output(
        TatwoWebArenaFactory.plan(suite: suite, runID: runID, models: models),
        command: "web-arena plan")
    case "scaffold":
      let receipt = try TatwoWebArenaFactory.scaffoldRun(
        root: root, suite: suite, runID: runID, models: models)
      output(receipt, command: "web-arena scaffold")
    case "run":
      guard args.contains("--live") else {
        throw CLIError.usage(
          "web-arena run no longer creates scaffold silently. Use `web-arena scaffold` to build the test folders, or `web-arena run --live --models <model>` to execute real model dispatch."
        )
      }
      guard !modelArgs.isEmpty else {
        throw CLIError.usage(
          "web-arena run --live requires explicit --models <model>; live fan-out is never defaulted."
        )
      }
      let receipt = try TatwoWebArenaFactory.scaffoldRun(
        root: root, suite: suite, runID: runID, models: models)
      _ = receipt
      let runner = root.appendingPathComponent("scripts/tatwo-web-arena-live-runner.mjs")
      guard FileManager.default.fileExists(atPath: runner.path) else {
        throw CLIError.usage("Missing live runner script: \(runner.path)")
      }
      var runnerArgs = [
        "node", runner.path, "--suite", suite.rawValue, "--run", runID, "--models",
        models.joined(separator: ","), "--json",
      ]
      if let cycles = option("--cycles", in: args) {
        runnerArgs += ["--cycles", cycles]
      }
      if let reasoning = option("--reasoning", in: args) ?? option("--reasoning-effort", in: args) {
        runnerArgs += ["--reasoning", reasoning]
      }
      if args.contains("--dry-run") {
        runnerArgs.append("--dry-run")
      }
      let data = try runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: runnerArgs,
        cwd: root)
      let any = try JSONSerialization.jsonObject(with: data)
      output(JSONValue.fromAny(any), command: "web-arena run --live")
    case "report":
      guard let explicitRun = option("--run", in: args) ?? option("--runID", in: args) else {
        throw CLIError.usage("Use: tatwo-ultrawork web-arena report --run <runID> --json")
      }
      output(
        try TatwoWebArenaFactory.writeRunSummaryArtifacts(root: root, runID: explicitRun),
        command: "web-arena report")
    case "cleanup":
      let olderThan = TatwoWebArenaRuntime.parseOlderThanDays(
        option("--older-than", in: args) ?? option("--olderThan", in: args) ?? "14d")
      if args.contains("--execute") {
        throw CLIError.usage(
          "web-arena cleanup v1 is dry-run only. Use --dry-run; real deletion requires a future explicit host-delete command."
        )
      }
      let dryRun = args.contains("--dry-run") || !args.contains("--execute")
      output(
        try TatwoWebArenaFactory.cleanupPlan(
          root: root, olderThanDays: olderThan, dryRun: dryRun),
        command: "web-arena cleanup")
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork web-arena plan|scaffold|run|report|cleanup --suite v1 --models gpt-5.5,sonnet-5,fable-5,opus-5,minimax-m3 --json")
    }
  }

  static func handleSandboxArena(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    let runID = option("--run", in: args) ?? option("--runID", in: args)
      ?? TatwoSandboxArenaFactory.defaultRunID()
    let arenaIDs = TatwoSandboxArenaID.parse(option("--arena", in: args))
    let modelArgs = options("--models", in: args)
    let models = TatwoSandboxArenaFactory.normalizeModels(
      modelArgs.isEmpty ? TatwoSandboxArenaFactory.defaultModelSlugs : modelArgs)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    switch subcommand {
    case "list":
      output(TatwoSandboxArenaFactory.definitions(), command: "sandbox-arena list")
    case "plan":
      if arenaIDs.count == 1, let arena = arenaIDs.first {
        output(
          TatwoSandboxArenaFactory.plan(arena: arena, runID: runID, models: models),
          command: "sandbox-arena plan")
      } else {
        output(
          TatwoSandboxArenaFactory.collectionPlan(arenas: arenaIDs, runID: runID, models: models),
          command: "sandbox-arena plan")
      }
    case "run":
      if arenaIDs.count == 1, let arena = arenaIDs.first {
        output(
          try TatwoSandboxArenaFactory.scaffoldRun(
            root: root, arena: arena, runID: runID, models: models),
          command: "sandbox-arena run")
      } else {
        output(
          try TatwoSandboxArenaFactory.scaffoldCollection(
            root: root, arenas: arenaIDs, runID: runID, models: models),
          command: "sandbox-arena run")
      }
    case "report":
      guard option("--run", in: args) != nil || option("--runID", in: args) != nil else {
        throw CLIError.usage("Use: tatwo-ultrawork sandbox-arena report --arena debug --run <runID> --json")
      }
      let summaries = try arenaIDs.map {
        try TatwoSandboxArenaFactory.writeRunSummaryArtifacts(root: root, arena: $0, runID: runID)
      }
      if summaries.count == 1, let first = summaries.first {
        output(first, command: "sandbox-arena report")
      } else {
        output(summaries, command: "sandbox-arena report")
      }
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork sandbox-arena list|plan|run|report --arena all|code-architecture|debug|research|multimodal|plugin-mcp|writing|3d-modeling --json")
    }
  }

  static func handleWebCheck(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "preflight":
      let root = webCheckRoot()
      let executable = root.appendingPathComponent("bin/tatwo-frontend-doctor")
      let executableExists = FileManager.default.isExecutableFile(atPath: executable.path)
      var parity: TatwoWebCheckRuleParity?
      var degraded: String? = executableExists ? nil : "web-check executable not found"
      if executableExists {
        do {
          let data = try runProcess(
            executableURL: executable, arguments: ["rules", "list", "--json"], cwd: root)
          parity = parseWebCheckRuleParity(data)
        } catch {
          degraded =
            "rules list failed: \(TatwoPrivacyRedactor.redacted(error.localizedDescription))"
        }
      }
      let preflight = TatwoWebCheckFactory.preflight(
        available: executableExists && parity != nil,
        executableHint: "<web-check-root>/bin/tatwo-frontend-doctor",
        rootHint: "TATWO_WEB_CHECK_ROOT or local 前端健檢 root",
        ruleParity: parity,
        degradedReason: degraded)
      output(preflight, command: "web-check preflight", ok: preflight.available)
      if !preflight.available { Foundation.exit(3) }
    case "plan":
      let mode = try WorkModeID.parse(option("--mode", in: args) ?? "L")
      let scenario = option("--scenario", in: args) ?? "ui-ux"
      let target = option("--target", in: args) ?? "<local-frontend-project>"
      let scanType = (option("--scan-type", in: args) ?? option("--scanType", in: args))
        .flatMap(TatwoWebCheckScanType.init(rawValue:))
      let blockingPolicy =
        (option("--blocking", in: args) ?? option("--blocking-policy", in: args)
        ?? option("--blockingPolicy", in: args))
        .flatMap(TatwoWebCheckBlockingPolicy.init(rawValue:))
      output(
        TatwoWebCheckFactory.plan(
          mode: mode,
          scenarioProfileID: scenario,
          target: target,
          scanType: scanType,
          blockingPolicy: blockingPolicy),
        command: "web-check plan")
    case "import":
      guard let reportPath = option("--report", in: args) ?? option("--report-path", in: args)
      else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork web-check import --report report.json --contract <contractID> --json"
        )
      }
      let reportURL = URL(fileURLWithPath: reportPath)
      let data = try Data(contentsOf: reportURL)
      let targetKind =
        (option("--target-kind", in: args) ?? option("--targetKind", in: args))
        .flatMap(TatwoWebCheckTargetKind.init(rawValue:)) ?? .localProject
      let scanType =
        (option("--scan-type", in: args) ?? option("--scanType", in: args))
        .flatMap(TatwoWebCheckScanType.init(rawValue:)) ?? .full
      let blockingPolicy =
        (option("--blocking", in: args) ?? option("--blocking-policy", in: args)
        ?? option("--blockingPolicy", in: args))
        .flatMap(TatwoWebCheckBlockingPolicy.init(rawValue:)) ?? .noNewError
      let command =
        option("--command", in: args)
        ?? "./bin/tatwo-frontend-doctor <local-frontend-project> --json --json-compact --blocking none"
      let result = TatwoWebCheckFactory.importReceipt(
        reportData: data,
        reportPath: reportPath,
        contractID: option("--contract", in: args) ?? option("--contractID", in: args),
        goalID: option("--goal", in: args) ?? option("--goalID", in: args),
        targetKind: targetKind,
        scanType: scanType,
        blockingPolicy: blockingPolicy,
        command: command)
      output(result, command: "web-check import", ok: result.ok)
      if !result.ok { Foundation.exit(3) }
    case "receipt-template":
      let contractID = option("--contract", in: args) ?? option("--contractID", in: args) ?? ""
      let gate = WorkOSFactory.requireContractID(contractID)
      guard gate.ok else {
        output(
          TatwoWebCheckImportResult(
            ok: false,
            receipt: nil,
            decision: gate,
            nextAction: "先建立 Work OS contractID。"),
          command: "web-check receipt-template",
          ok: false)
        Foundation.exit(3)
      }
      output(
        TatwoWebCheckFactory.receiptTemplate(
          contractID: contractID,
          goalID: option("--goal", in: args) ?? option("--goalID", in: args)),
        command: "web-check receipt-template")
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork web-check preflight|plan|import|receipt-template --json")
    }
  }

  static func webCheckRoot() -> URL {
    if let raw = ProcessInfo.processInfo.environment["TATWO_WEB_CHECK_ROOT"],
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: raw, isDirectory: true)
    }
    return URL(fileURLWithPath: ".tatwo-ultrawork/tools/web-check", isDirectory: true)
  }

  static func runProcess(executableURL: URL, arguments: [String], cwd: URL? = nil) throws -> Data {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-cli-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let stdoutURL = tmpDir.appendingPathComponent("stdout.log")
    let stderrURL = tmpDir.appendingPathComponent("stderr.log")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    try process.run()
    process.waitUntilExit()
    try? stdoutHandle.close()
    try? stderrHandle.close()
    let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
    if process.terminationStatus != 0 {
      let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
      let errorText =
        String(data: errorData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
      throw CLIError.usage(TatwoPrivacyRedactor.redacted(errorText))
    }
    return output
  }

  static func parseWebCheckRuleParity(_ data: Data) -> TatwoWebCheckRuleParity? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    func int(_ key: String) -> Int {
      switch object[key] {
      case let value as Int: return value
      case let value as NSNumber: return value.intValue
      case let value as String: return Int(value) ?? 0
      default: return 0
      }
    }
    return TatwoWebCheckRuleParity(
      officialRules: int("totalOfficialRules"),
      implementedSubstitutes: int("implementedOfficialSubstitutes"),
      plannedDetectors: int("plannedOfficialDetectors"),
      activeLocalDetectorIDs: int("activeLocalDetectorIDs") > 0
        ? int("activeLocalDetectorIDs") : nil)
  }

  static func handleColima(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "preflight":
      output(ColimaSandboxFactory.preflight(), command: "colima preflight")
    case "run":
      let mode = try WorkModeID.parse(option("--mode", in: args) ?? "L")
      let scenario = try ScenarioID.parse(option("--scenario", in: args) ?? "coding")
      let objective = option("--objective", in: args) ?? "Tatwo Colima sandbox verification"
      let allowExecute = args.contains("--allow-execute")
      let dryRun = args.contains("--dry-run") || !allowExecute
      let receipt = ColimaSandboxFactory.makeReceipt(
        objective: objective,
        mode: mode,
        scenario: scenario,
        dryRun: dryRun,
        allowExecute: allowExecute,
        requestedCommands: options("--command", in: args)
      )
      output(receipt, command: "colima run", ok: receipt.status != .blocked)
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork colima preflight --json OR tatwo-ultrawork colima run --mode L --scenario code --objective '<objective>' --dry-run --json"
      )
    }
  }

  static func environmentChecks() -> [DoctorCheck] {
    [
      commandCheck(
        "swift", title: "Swift toolchain", severity: .critical,
        remediation: "Install Xcode Command Line Tools"),
      commandCheck(
        "git", title: "Git", severity: .medium, remediation: "Install git for clone/deploy"),
      commandCheck(
        "node", title: "Node", severity: .medium,
        remediation: "Needed for gateway/open-ultrawork tests"),
      commandCheck(
        "codex", title: "Codex CLI", severity: .high,
        remediation: "Required for Codex App/CLI entrypoint"),
      commandCheck(
        "claude", title: "Claude CLI", severity: .medium,
        remediation: "Optional reviewer lane; skip if not installed"),
      commandCheck(
        "grok", title: "Grok CLI", severity: .medium,
        remediation: "Optional news/refutation lane; skip if not installed"),
      commandCheck(
        "colima", title: "Colima optional sandbox runner", severity: .medium,
        remediation:
          "Optional L/XL verifier; install manually only if you want container sandbox checks"),
      commandCheck(
        "docker", title: "Docker client for optional Colima runner", severity: .medium,
        remediation: "Optional with Colima; missing does not block Tatwo core"),
    ]
  }

  static func doctorChecksByApplyingM2Evidence(
    _ checks: [DoctorCheck], evidenceDir explicitEvidenceDir: String?
  ) -> [DoctorCheck] {
    guard let evidenceDir = resolveEvidenceDir(explicitEvidenceDir) else { return checks }
    let hostGate = readJSONObject(
      evidenceDir.appendingPathComponent("host-install-verified-gate.log"))
    let receiptBundle = readJSONObject(
      evidenceDir.appendingPathComponent("host-receipt-bundle.log"))
    let routeGate = readJSONObject(
      evidenceDir.appendingPathComponent("route-live-smoke-receipts.log"))

    let hostGatePassed =
      (hostGate["hostInstallAllowed"] as? Bool) == true
      && ((hostGate["failedCheckIDs"] as? [Any])?.isEmpty ?? false)
      && ((hostGate["blockedBy"] as? [Any])?.isEmpty ?? false)
    let bundleComplete = (receiptBundle["hostInstallEvidenceComplete"] as? Bool) == true
    let routePassed = (routeGate["routeLiveSmokeAllPassed"] as? Bool) == true

    guard hostGatePassed && bundleComplete && routePassed else { return checks }

    return checks.map { check in
      switch check.id {
      case "gateway-contract":
        return DoctorCheck(
          id: check.id,
          title: check.title,
          status: .installed,
          severity: check.severity,
          message:
            "M2 evidence observed: same-thread smoke, route live receipts, backup, rollback, and host MCP registration passed",
          remediation:
            "Keep evidence local and rerun host gate after any gateway/Codex config change"
        )
      case "ultrawork-contract":
        return DoctorCheck(
          id: check.id,
          title: check.title,
          status: .installed,
          severity: check.severity,
          message:
            "M2 evidence observed: S/M/L/XL workflow gates, sandbox-first receipt bundle, and fail-closed route validation are available; fan-out still requires per-run authorization",
          remediation:
            "Use the lowest sufficient mode; L/XL fan-out still needs explicit user approval"
        )
      default:
        return check
      }
    } + [
      DoctorCheck(
        id: "m2-host-verified-gate",
        title: "M2 host verified gate",
        status: .installed,
        severity: .critical,
        message:
          "host-install-verified-gate passed from local evidence bundle; UI/M3 remains blocked until user confirmation",
        remediation: nil
      )
    ]
  }

  static func resolveEvidenceDir(_ explicit: String?) -> URL? {
    let fm = FileManager.default
    if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: explicit, isDirectory: true)
      return fm.fileExists(atPath: url.path) ? url : nil
    }

    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    let pointer = cwd.appendingPathComponent(".tatwo-ultrawork/evidence/.latest-m2")
    if let text = try? String(contentsOf: pointer, encoding: .utf8) {
      let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let url = URL(fileURLWithPath: path, isDirectory: true)
      if fm.fileExists(atPath: url.path) { return url }
    }

    let evidenceRoot = cwd.appendingPathComponent(".tatwo-ultrawork/evidence", isDirectory: true)
    guard
      let entries = try? fm.contentsOfDirectory(
        at: evidenceRoot, includingPropertiesForKeys: [.isDirectoryKey])
    else { return nil }
    return
      entries
      .filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
          && url.lastPathComponent.hasSuffix("-M2")
      }
      .sorted { $0.path < $1.path }
      .last
  }

  static func readJSONObject(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return object
  }

  static func handleState(_ args: [String]) throws {
    let store = TatwoPreferenceStore(fileURL: stateFileURL())
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "export":
      output(try store.load(), command: "state export")
    case "set-mode":
      let mode = try WorkModeID.parse(option("--mode", in: args) ?? "M")
      let scenario = try option("--scenario", in: args).map(ScenarioID.parse)
      output(try store.updateMode(mode, scenario: scenario), command: "state set-mode")
    case "plugin":
      guard let id = option("--id", in: args) else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork state plugin --id chatgpt-pro-mcp --action later --json")
      }
      let actionRaw = option("--action", in: args) ?? "later"
      guard let action = InstallAction(rawValue: actionRaw) else {
        throw CLIError.usage("Unknown install action: \(actionRaw)")
      }
      output(try store.setPluginDecision(pluginID: id, action: action), command: "state plugin")
    default:
      throw CLIError.usage("Use: tatwo-ultrawork state export|set-mode|plugin --json")
    }
  }

  static func handleMemory(_ args: [String]) throws {
    let store = TatwoPreferenceStore(fileURL: stateFileURL())
    let subcommand = args.dropFirst().first
    switch subcommand {
    case "add":
      let categoryRaw =
        option("--category", in: args) ?? SafeMemoryReceipt.Category.failureMode.rawValue
      guard let category = SafeMemoryReceipt.Category(rawValue: categoryRaw) else {
        throw CLIError.usage("Unknown memory category: \(categoryRaw)")
      }
      guard let summary = option("--summary", in: args) else {
        throw CLIError.usage(
          "Use: tatwo-ultrawork memory add --category failure_mode --summary '<safe summary>' --json"
        )
      }
      let tags = (option("--tags", in: args) ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let receipt = SafeMemoryReceipt(
        id: "mem-\(UUID().uuidString.lowercased())", category: category, summary: summary,
        tags: tags)
      output(try store.appendSafeMemory(receipt), command: "memory add")
    case "list":
      output(try store.load().safeMemories, command: "memory list")
    default:
      throw CLIError.usage("Use: tatwo-ultrawork memory add|list --json")
    }
  }

  static func handleContext(_ args: [String]) throws {
    let subcommand = args.dropFirst().first
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    switch subcommand {
    case "policy":
      output(TatwoContextCompressionFactory.policy(), command: "context policy")
    case "compress":
      let text = try contextInputText(args)
      let rawKind = option("--kind", in: args) ?? "auto"
      guard let kind = TatwoContextCompressionKind(rawValue: rawKind) else {
        throw CLIError.usage("Unknown context kind: \(rawKind)")
      }
      let runID = option("--run", in: args) ?? option("--runID", in: args) ?? "manual"
      let maxChars = Int(option("--max-chars", in: args) ?? option("--maxCompressedCharacters", in: args) ?? "")
      let policy = TatwoContextCompressionPolicy(
        maxCompressedCharacters: maxChars ?? TatwoContextCompressionPolicy.default.maxCompressedCharacters,
        maxPreservedDiagnosticLines: Int(option("--max-diagnostic-lines", in: args) ?? "") ?? TatwoContextCompressionPolicy.default.maxPreservedDiagnosticLines,
        maxLineCharacters: Int(option("--max-line-chars", in: args) ?? "") ?? TatwoContextCompressionPolicy.default.maxLineCharacters,
        cacheOriginal: !args.contains("--no-cache"),
        failOnSensitiveContent: !args.contains("--allow-sensitive"),
        redactShareableOutput: !args.contains("--no-redact"))
      let sourceLabel =
        option("--source", in: args)
        ?? option("--file", in: args)
        ?? "stdin-or-inline-context"
      output(
        try TatwoContextCompressionFactory.compress(
          text: text,
          kind: kind,
          sourceLabel: sourceLabel,
          runID: runID,
          root: root,
          policy: policy),
        command: "context compress")
    case "retrieve":
      let id = try requiredOption("--id", in: args)
      let runID = option("--run", in: args) ?? option("--runID", in: args)
      output(
        try TatwoContextCompressionFactory.retrieve(id: id, root: root, runID: runID),
        command: "context retrieve")
    case "stats":
      output(try TatwoContextCompressionFactory.stats(root: root), command: "context stats")
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork context policy|compress|retrieve|stats --json")
    }
  }

  static func contextInputText(_ args: [String]) throws -> String {
    if let file = option("--file", in: args) {
      return try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
    }
    if let text = option("--text", in: args) ?? option("--input", in: args) {
      return text
    }
    if isatty(STDIN_FILENO) == 0 {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      if !data.isEmpty {
        return String(decoding: data, as: UTF8.self)
      }
    }
    throw CLIError.usage(
      "Use: tatwo-ultrawork context compress --file <path> --json OR --text '<context>' --json")
  }

  static func stateFileURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let dir = env["TATWO_ULTRAWORK_STATE_DIR"],
      !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("preferences.json")
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent(".tatwo-ultrawork/state/preferences.json")
  }

  static func commandCheck(
    _ command: String, title: String, severity: SafetyLevel, remediation: String
  ) -> DoctorCheck {
    let found = which(command) != nil
    return DoctorCheck(
      id: "cmd-\(command)", title: title, status: found ? .installed : .missing, severity: severity,
      message: found ? "available on PATH" : "not found on PATH",
      remediation: found ? nil : remediation)
  }

  static func which(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["sh", "-c", "command -v \(shellQuote(command))"]
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

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func sampleUIBuildOnlyReceipt() -> ValidationReceipt {
    ValidationReceipt(
      runID: "sample-ui-build-only",
      objective: "Demonstrate that build pass alone cannot pass UI/UX",
      changedSurface: [.ui],
      acceptanceCriteria: [
        AcceptanceCriterion(
          id: "ui-visible", description: "UI must be proven by screenshot or visual diff")
      ],
      builder: RoleReceipt(
        actorID: "codex-builder", role: .builder, roleSessionID: "builder-1", model: "gpt-5.5",
        summary: "Built the UI"),
      reviewer: RoleReceipt(
        actorID: "peer-reviewer", role: .reviewer, roleSessionID: "reviewer-1", model: "sonnet-5",
        summary: "Needs visual proof"),
      verifier: RoleReceipt(
        actorID: "deterministic-verifier", role: .verifier, roleSessionID: "verifier-1",
        model: "local-tests", summary: "Only build evidence present", evidenceIDs: ["build"]),
      judge: RoleReceipt(
        actorID: "risk-judge", role: .judge, roleSessionID: "judge-1", model: "opus-5",
        summary: "Fail closed until screenshot exists", evidenceIDs: ["build"]),
      build: BuildEvidence(
        status: .passed, command: "swift build", appLaunched: true, processAlive: true,
        evidenceID: "build"),
      visualEvidence: [],
      visualChecklist: [],
      findings: [],
      judgeDecision: JudgeDecision(
        finalVerdict: .passed, resolvedFindingIDs: [], acceptedRiskIDs: [],
        reason: "This intentionally demonstrates the gate failure.")
    )
  }
}

enum CLIError: LocalizedError {
  case usage(String)
  case mergePending(String)
  case mergeConflictUnresolved(String)
  case staleMergeProposal(String)

  var exitStatus: Int32 {
    switch self {
    case .usage:
      return 1
    case .mergePending:
      return 44
    case .mergeConflictUnresolved:
      return 45
    case .staleMergeProposal:
      return 46
    }
  }

  var errorDescription: String? {
    switch self {
    case .usage(let message): return message
    case .mergePending(let message): return message
    case .mergeConflictUnresolved(let message): return message
    case .staleMergeProposal(let message): return message
    }
  }
}

TatwoUltraworkCLI.main()

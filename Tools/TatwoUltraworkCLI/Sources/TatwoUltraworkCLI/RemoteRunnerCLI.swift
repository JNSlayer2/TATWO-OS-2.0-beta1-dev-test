import Foundation
import TatwoDomainContracts
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

enum TatwoRemoteRunnerCLI {
  private struct StartOutput: Encodable {
    let schema = "TatwoRemoteRunnerStartCLIOutputV1"
    let deviceID: String
    let originDeviceID: String
    let pinStoreGeneration: UInt64
    let peerPinCount: Int
    let receiptCount: Int
    let receipts: [ReceiptSummary]
  }

  private struct ReceiptSummary: Encodable {
    let jobID: String
    let status: String
    let failureCode: String?
  }

  private struct BootstrapOnlyOutput: Encodable {
    let schema = "TatwoRemoteRunnerBootstrapCLIOutputV1"
    let deviceID: String
    let originDeviceID: String
    let pinStoreGeneration: UInt64
    let peerPinCount: Int
  }

  private struct DispatchOutput: Encodable {
    let schema = "TatwoRemoteRunnerDispatchCLIOutputV1"
    let jobID: String
    let logicalJobID: String
    let dispatchNonce: String
    let jobCanonicalDigest: String
    let originDeviceID: String
    let targetDeviceID: String
    let channelRoot: String
    let dispatchRecordID: String
    let pinStoreGeneration: UInt64
    let peerPinCount: Int
  }

  private struct ReadinessPublishOutput: Encodable {
    let schema = "TatwoRemoteRunnerReadinessPublishCLIOutputV1"
    let targetDeviceID: String
    let workspaceBindingID: String
    let requestedAgent: String
    let exactModelRouteID: String
    let registryPath: String
    let channelManifestPath: String
    let manifestPath: String?
    let manifest: TatwoRemoteDispatchReadinessManifestV1
  }

  /// Dual-machine enablement order (also in tatwo-remote-channel-sync.sh header).
  static let dualMachineRunbook = """
    Dual-machine remote-loop enablement (fail-closed):
      1. Both hosts: device-trust init + mutual pin-import (already done on pilot hosts)
      2. Both hosts: remote-runner seal-install --device-id <self> --channel-dir <path>
      3. Target: remote-runner start --device-id <target> --origin-device-id <origin> (long-running)
      4. Origin: remote-runner dispatch ... then scripts/tatwo-remote-channel-sync.sh push
      5. Target runner executes; scripts/tatwo-remote-channel-sync.sh pull; origin converge
    Crash-after-claim recovery: mint new jobID + new dispatchNonce; keep logicalJobID \
    (TatwoLoopJobV1.mintRecoveryDispatch). Never re-nonce the same jobID — claim keys are per jobID.
    Transport only moves signed artifacts; trust is signature + pins + high-water, not the pipe.
    """

  static func run(_ args: [String]) throws {
    guard let subcommand = args.dropFirst().first else {
      throw CLIError.usage(
        """
        Use: tatwo-ultrawork remote-runner start|seal-install|readiness|dispatch|result|fleet --device-id <id> ...
        \(dualMachineRunbook)
        Readiness:
          remote-runner readiness publish --device-id <target> --workspace-binding-id <id> \
            --workspace-path <target-local-dir> --agent <grok|codex|claude> \
            --model-route <canonical-route> [--skillet-store <path>] [--manifest-out <path>]
        Fleet (mini scheduler):
          remote-runner fleet register --device-id <target> [--max-concurrent N] [--inflight N] [--channel-dir]
          remote-runner fleet dispatch --device-id <origin> --task-file <spec> --agent <grok|codex|claude> \\
            --model-route <route> --target-device-id <target> --session-id <session> --grant-id <grant> \\
            --contract-id <id> --goal-id <id> [--count N] [--logical-job-id <id>]
          remote-runner fleet tick --device-id <origin> [--lease-seconds N] [--heartbeat-max-age N]
          remote-runner fleet status --device-id <origin> --json
        """)
    }
    switch subcommand {
    case "start":
      try start(args)
    case "seal-install":
      try sealInstall(args)
    case "readiness":
      try readiness(args)
    case "dispatch":
      try dispatch(args)
    case "result":
      try result(args)
    case "fleet":
      try fleet(args)
    case "contract":
      try contract(args)
    default:
      throw CLIError.usage("Unknown remote-runner subcommand: \(subcommand)")
    }
  }

  private struct ResultCLIOutput: Encodable {
    let schema = "TatwoRemoteRunnerResultCLIOutputV1"
    let jobID: String
    let contractID: String?
    let status: String
    let exitCode: Int32?
    let failureCode: String?
    let outputDigest: String?
    let outputBytes: Int
    let outputTruncated: Bool
    let output: String
    let outputEncoding: String
    let requestedCanonicalModelID: String?
    let requestedVendorModelID: String?
    let observedAssistantModelIDs: [String]
    let modelUsageKeys: [String]
    let fallbackEventCount: Int?
    let modelAttestationOutcome: String?
  }

  /// Origin-side read of a target-signed result + verified output artifact.
  ///
  /// ```
  /// tatwo-ultrawork remote-runner result \
  ///   --device-id <origin> --job-id <id> \
  ///   [--contract-id <issued>] [--channel-dir <sealed>] --json
  /// ```
  private static func result(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let jobID = try TatwoUltraworkCLI.requiredOption("--job-id", in: args)
    let contractID =
      TatwoUltraworkCLI.option("--contract-id", in: args)
      ?? TatwoUltraworkCLI.option("--contract", in: args)
    if TatwoUltraworkCLI.option("--pin-store-root", in: args) != nil {
      throw CLIError.usage(
        "remote-runner result refuses --pin-store-root; use canonical device-trust pin-store")
    }
    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    try TatwoLoopProductionRunnerBootstrap.rejectProductionTrustNamespaceOverrides(
      environment: environment)
    try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
      environment: environment)
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      throw TatwoLoopProductionRunnerError.testModeForbidden
    }
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: deviceID)

    // Bootstrap as the origin host (self-as-origin), same gate class as dispatch.
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
      deviceID: deviceID,
      originDeviceID: deviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease)
    let channel = boot.channel
    let job = try channel.job(forJobID: jobID)
    if let contractID {
      let trimmed = contractID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, job.contractID == trimmed else {
        throw CLIError.usage(
          "remote-runner result --contract-id does not match job \(jobID) contract")
      }
    }
    guard let receipt = try channel.resultForAudit(for: jobID) else {
      throw CLIError.usage("remote-runner result: no verified result for job \(jobID)")
    }
    let outputText: String
    let outputDigest: String?
    let outputBytes: Int
    let outputTruncated: Bool
    let encoding: String
    if receipt.outputDigest != nil {
      let artifact = try channel.outputArtifact(for: jobID)
      outputDigest = artifact.outputDigest
      outputBytes = artifact.outputBytes
      outputTruncated = artifact.outputTruncated
      if let utf8 = String(data: artifact.data, encoding: .utf8) {
        outputText = utf8
        encoding = "utf8"
      } else {
        outputText = artifact.data.base64EncodedString()
        encoding = "base64"
      }
    } else {
      outputDigest = nil
      outputBytes = 0
      outputTruncated = false
      outputText = ""
      encoding = "utf8"
    }

    TatwoUltraworkCLI.output(
      ResultCLIOutput(
        jobID: jobID,
        contractID: job.contractID,
        status: receipt.status.rawValue,
        exitCode: receipt.exitCode,
        failureCode: receipt.failureCode,
        outputDigest: outputDigest,
        outputBytes: outputBytes,
        outputTruncated: outputTruncated,
        output: outputText,
        outputEncoding: encoding,
        requestedCanonicalModelID:
          receipt.modelExecutionAttestation?.requestedCanonicalModelID,
        requestedVendorModelID:
          receipt.modelExecutionAttestation?.requestedVendorModelID,
        observedAssistantModelIDs:
          receipt.modelExecutionAttestation?.observedAssistantModelIDs ?? [],
        modelUsageKeys:
          receipt.modelExecutionAttestation?.modelUsageKeys ?? [],
        fallbackEventCount:
          receipt.modelExecutionAttestation?.fallbackEventCount,
        modelAttestationOutcome:
          receipt.modelExecutionAttestation?.outcome.rawValue),
      command: "remote-runner result")
  }

  private struct ContractOutput: Encodable {
    let schema = "TatwoRemoteLoopsContractCLIOutputV1"
    let authority: [String]
    let safetySemantics: [String]
    let trust: [String]
    let enablementOrder: [String]
    let dispatchOrder: [String]
    let fleetCommands: [String]
    let knownLimits: [String]
    let protocolDoc: String
  }

  /// Machine-readable fleet contract. Backs `tatwo_remote_loops_contract` so any
  /// AI can learn the rules without reading the source or re-deriving them.
  private static func contract(_ args: [String]) throws {
    TatwoUltraworkCLI.output(
      ContractOutput(
        authority: [
          "Origin is the only control-plane writer: it schedules, enforces fairness and leases, and arbitrates commits.",
          "Targets take work by their own declared capacity and produce candidate results in an isolated workspace only.",
          "Targets must not self-steal work: file replicas across machines have no global atomic create, so two devices can both win the same claim.",
          "Permanent side effects belong to the origin; a target never writes shared state, pushes a repo, or performs irreversible external actions.",
        ],
        safetySemantics: [
          "at-least-once execution + exactly-once logical commit.",
          "Duplicate execution is allowed; only one commit per logicalJobID is valid.",
          "Later arrivals are recorded as superseded and never overwrite the winner.",
          "An offline origin costs liveness, not safety: no new assignments and no commits, while running targets still finish and seal results.",
          "No scheduler failover: multi-primary scheduling without quorum or external fencing splits the brain.",
        ],
        trust: [
          "Transport confers no trust; it only moves already-signed artifacts.",
          "Trust comes from device pins, signature verification, freshness windows, attempt binding (jobID + dispatchNonce + jobCanonicalDigest), consume high-water, and the Work OS contract gate.",
          "Claims are create-only and never revoked; an expired lease mints a new attempt (new jobID and dispatchNonce, same logicalJobID) instead of releasing the old claim.",
          "Any mismatch fails closed.",
        ],
        enablementOrder: [
          "device-trust init --device-id <self>",
          "device-trust export-identity --device-id <self> --output <file>",
          "exchange identity files out of band, then device-trust pin-import <peer> --fingerprint <sha256-of-file> --device-id <self>",
          "remote-runner seal-install --device-id <self> --channel-dir <path>",
          "target: remote-runner start --device-id <target> --origin-device-id <origin> [--engine agent]",
        ],
        dispatchOrder: [
          "remote-runner dispatch --device-id <origin> --target-device-id <target> --contract-id <issued> --goal-id <issued> --mode <matching> --logical-job-id <id> --work-path <target sandbox> --task-description <prompt> --agent <grok|codex|claude>",
          "scripts/tatwo-remote-channel-sync.sh push --local-channel <origin> --remote-channel <target> --remote-host <user@host>",
          "target runner executes",
          "scripts/tatwo-remote-channel-sync.sh pull ...",
          "remote-runner result --device-id <origin> --job-id <id>",
        ],
        fleetCommands: [
          "remote-runner fleet register --device-id <target> --max-concurrent <n> --channel-dir <sealed>",
          "remote-runner fleet dispatch --device-id <origin> --target-device-id <target> --session-id <session> --grant-id <grant> --task-file <spec> --agent <kind> --model-route <route> --contract-id <id> --goal-id <id> [--count N]",
          "remote-runner fleet tick --device-id <origin> [--lease-seconds N] [--heartbeat-max-age N]",
          "remote-runner fleet status --device-id <origin>",
        ],
        knownLimits: [
          "Scheduler authority is single-host by design; there is no failover.",
          "Replacing the CLI binary invalidates that host's Keychain key ACL, so the host must re-enroll after an update.",
          "Target-side key creation needs a GUI session; over SSH it fails with -25308.",
          "fleet commit is a logical gate, not a host promotion.",
        ],
        protocolDoc: "docs/protocol/REMOTE_COMPUTE_FLEET_V1.md"),
      command: "remote-runner contract")
  }

  private struct SealInstallOutput: Encodable {
    let schema = "TatwoRemoteRunnerSealInstallCLIOutputV1"
    let hostDeviceID: String
    let jobChannelRoot: String
    let stateRoot: String
    let pinStoreRoot: String
    let sealedAt: String
  }

  /// Explicit install-gate: create-only production layout anchor (no pin-store bootstrap).
  private static func sealInstall(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let channelRoot = try TatwoUltraworkCLI.requiredOption("--channel-dir", in: args)
    let environment = ProcessInfo.processInfo.environment
    try TatwoLoopProductionRunnerBootstrap.rejectProductionTrustNamespaceOverrides(
      environment: environment)
    try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
      environment: environment)
    let layout = try TatwoProductionLayoutLock.sealInstallAnchor(
      hostDeviceID: deviceID,
      requestedChannelRoot: URL(fileURLWithPath: channelRoot, isDirectory: true),
      environment: environment,
      installAnchorStore: TatwoProductionInstallAnchorKeychainStore())
    TatwoUltraworkCLI.output(
      SealInstallOutput(
        hostDeviceID: layout.installAnchor.hostDeviceID,
        jobChannelRoot: layout.jobChannelRoot.path,
        stateRoot: layout.stateRoot.path,
        pinStoreRoot: layout.pinStoreRoot.path,
        sealedAt: layout.installAnchor.sealedAt),
      command: "remote-runner seal-install")
  }

  /// Publish a target-local, signed readiness registry entry and portable
  /// manifest.  The target registry retains canonical paths; the manifest
  /// deliberately contains only portable digests and signed scope.
  private static func readiness(_ args: [String]) throws {
    let readinessArgs = Array(args.dropFirst())
    guard readinessArgs.dropFirst().first == "publish" else {
      throw CLIError.usage(
        "Use: remote-runner readiness publish --device-id <target> --workspace-binding-id <id> --workspace-path <target-local-dir> --agent <grok|codex|claude> --model-route <canonical-route> [--skillet-store <path>] [--manifest-out <path>]")
    }

    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: readinessArgs)
    let workspaceBindingID = try TatwoUltraworkCLI.requiredOption(
      "--workspace-binding-id", in: readinessArgs)
    let workspacePath = try TatwoUltraworkCLI.requiredOption(
      "--workspace-path", in: readinessArgs)
    let agentRaw = try TatwoUltraworkCLI.requiredOption("--agent", in: readinessArgs)
    guard let agent = TatwoRemoteAgentKindV1(
      rawValue: agentRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    else {
      throw CLIError.usage(
        "remote-runner readiness publish --agent must be one of: grok, codex, claude")
    }
    let exactModelRouteID = try TatwoUltraworkCLI.requiredOption(
      "--model-route", in: readinessArgs)
    if TatwoUltraworkCLI.option("--pin-store-root", in: readinessArgs) != nil {
      throw CLIError.usage(
        "remote-runner readiness publish refuses --pin-store-root; use canonical device-trust pin-store")
    }

    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: readinessArgs).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    try TatwoLoopProductionRunnerBootstrap.rejectProductionTrustNamespaceOverrides(
      environment: environment)
    try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
      environment: environment)
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      throw TatwoLoopProductionRunnerError.testModeForbidden
    }
    let currentOriginLease = try configuredOriginLease(args: readinessArgs, deviceID: deviceID)
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
      deviceID: deviceID,
      originDeviceID: deviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease)
    guard let stateRoot = boot.lockedStateRoot else {
      throw TatwoLoopProductionRunnerError.layoutLock(
        .installAnchorRejected("missing locked state root for readiness registry"))
    }

    let canonicalSkilletRoot = stateRoot.deletingLastPathComponent()
      .appendingPathComponent("skillet", isDirectory: true)
    if let requestedSkilletRoot = TatwoUltraworkCLI.option(
      "--skillet-store", in: readinessArgs)
    {
      let requested = URL(fileURLWithPath: requestedSkilletRoot, isDirectory: true)
        .standardizedFileURL
      guard requested.path == canonicalSkilletRoot.standardizedFileURL.path else {
        throw CLIError.usage(
          "remote-runner readiness publish refuses non-canonical --skillet-store; use \(canonicalSkilletRoot.path)")
      }
    }
    let skilletRoot = canonicalSkilletRoot
    let skilletValues = try? skilletRoot.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard skilletValues?.isDirectory == true, skilletValues?.isSymbolicLink != true else {
      throw CLIError.usage(
        "remote-runner readiness publish requires the canonical Skillet root directory")
    }
    let entry = try TatwoRemoteDispatchReadinessTargetSnapshotBuilderV1.build(
      workspaceBindingID: workspaceBindingID,
      workspaceURL: URL(fileURLWithPath: workspacePath, isDirectory: true),
      requestedAgent: agent,
      exactModelRouteID: exactModelRouteID,
      targetDeviceID: deviceID,
      agentEngine: .production,
      skilletStore: TatwoSkilletRepositoryStore(rootURL: skilletRoot))
    let store = TatwoRemoteDispatchReadinessRegistryStoreV1.production(
      stateRoot: stateRoot,
      trust: boot.trust)
    let manifest = try store.publish(entry)

    let channelManifestURL = try readinessChannelManifestURL(
      channelRoot: boot.channel.rootURL,
      manifest: manifest)
    try writeReadinessManifest(manifest, to: channelManifestURL)

    let manifestOut = TatwoUltraworkCLI.option("--manifest-out", in: readinessArgs).map {
      URL(fileURLWithPath: $0, isDirectory: false)
    }
    if let manifestOut,
      manifestOut.standardizedFileURL.path
        != channelManifestURL.standardizedFileURL.path
    {
      try writeReadinessManifest(manifest, to: manifestOut)
    }
    TatwoUltraworkCLI.output(
      ReadinessPublishOutput(
        targetDeviceID: deviceID,
        workspaceBindingID: entry.workspaceBindingID,
        requestedAgent: entry.requestedAgent.rawValue,
        exactModelRouteID: entry.exactModelRouteID,
        registryPath: store.registryURL.path,
        channelManifestPath: channelManifestURL.path,
        manifestPath: manifestOut?.path,
        manifest: manifest),
      command: "remote-runner readiness publish")
  }

  private static func readinessChannelManifestURL(
    channelRoot: URL,
    manifest: TatwoRemoteDispatchReadinessManifestV1
  ) throws -> URL {
    guard let requestedAgent = TatwoRemoteAgentKindV1(rawValue: manifest.requestedAgent) else {
      throw CLIError.usage(
        "remote-runner readiness publish produced an invalid agent scope")
    }
    return try readinessChannelManifestURL(
      channelRoot: channelRoot,
      targetDeviceID: manifest.targetDeviceID,
      requestedAgent: requestedAgent,
      exactModelRouteID: manifest.exactModelRouteID)
  }

  private static func readinessChannelManifestURL(
    channelRoot: URL,
    targetDeviceID: String,
    requestedAgent: TatwoRemoteAgentKindV1,
    exactModelRouteID: String
  ) throws -> URL {
    guard TatwoLoopPathComponent.isValid(targetDeviceID),
      TatwoLoopPathComponent.isValid(requestedAgent.rawValue),
      TatwoModelIdentityRegistry.canonicalModelID(
        for: exactModelRouteID) == exactModelRouteID,
      TatwoModelIdentityRegistry.isActiveDispatchEligible(
        exactModelRouteID)
    else {
      throw CLIError.usage(
        "remote-runner readiness publish produced an invalid channel manifest scope")
    }
    let routeDigest = TatwoLoopJobDigest.sha256(
      Data(exactModelRouteID.utf8)
    ).replacingOccurrences(of: "sha256:", with: "")
    let routeComponent = "route-\(routeDigest)"
    guard TatwoLoopPathComponent.isValid(routeComponent) else {
      throw CLIError.usage(
        "remote-runner readiness publish produced an invalid route digest")
    }
    return channelRoot.standardizedFileURL
      .appendingPathComponent("readiness", isDirectory: true)
      .appendingPathComponent("manifests", isDirectory: true)
      .appendingPathComponent(targetDeviceID, isDirectory: true)
      .appendingPathComponent(requestedAgent.rawValue, isDirectory: true)
      .appendingPathComponent("\(routeComponent).json", isDirectory: false)
  }

  private static func writeReadinessManifest(
    _ manifest: TatwoRemoteDispatchReadinessManifestV1,
    to url: URL
  ) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
        throw CLIError.usage(
          "remote-runner readiness publish --manifest-out must be a regular non-symlink file")
      }
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(manifest).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func readReadinessManifest(from url: URL) throws
    -> TatwoRemoteDispatchReadinessManifestV1
  {
    let values = try? url.resourceValues(
      forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
      throw CLIError.usage(
        "remote-runner dispatch --readiness-manifest must be a regular non-symlink file")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(
        TatwoRemoteDispatchReadinessManifestV1.self,
        from: Data(contentsOf: url))
    } catch {
      throw CLIError.usage("remote-runner dispatch --readiness-manifest is invalid JSON")
    }
  }

  private static func start(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let originDeviceID = try TatwoUltraworkCLI.requiredOption("--origin-device-id", in: args)
    // Production refuses pin-store-root override (canonical App Support only).
    if TatwoUltraworkCLI.option("--pin-store-root", in: args) != nil {
      throw CLIError.usage(
        "remote-runner start refuses --pin-store-root; use canonical device-trust pin-store (device-trust init)")
    }
    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let bootstrapOnly = args.contains("--bootstrap-only")
    let engine = try parseStartEngine(TatwoUltraworkCLI.option("--engine", in: args))
    let environment = ProcessInfo.processInfo.environment
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: originDeviceID)

    // Production path: Keychain identity + forced durable pin load.
    // Never routes through scripts/tatwo-loop-runner-driver.swift.
    if bootstrapOnly {
      let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
        deviceID: deviceID,
        originDeviceID: originDeviceID,
        pinStoreRoot: nil,
        channelRoot: channelRoot,
        environment: environment,
        currentOriginLease: currentOriginLease)
      TatwoUltraworkCLI.output(
        BootstrapOnlyOutput(
          deviceID: boot.deviceID,
          originDeviceID: boot.originDeviceID,
          pinStoreGeneration: boot.pinStoreGeneration,
          peerPinCount: boot.peerPinCount),
        command: "remote-runner start --bootstrap-only")
      return
    }

    let (boot, receipts) = try TatwoLoopProductionRunnerBootstrap.start(
      deviceID: deviceID,
      originDeviceID: originDeviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      engine: engine,
      currentOriginLease: currentOriginLease)
    let summary = receipts.map {
      ReceiptSummary(
        jobID: $0.jobID,
        status: $0.status.rawValue,
        failureCode: $0.failureCode)
    }
    TatwoUltraworkCLI.output(
      StartOutput(
        deviceID: boot.deviceID,
        originDeviceID: boot.originDeviceID,
        pinStoreGeneration: boot.pinStoreGeneration,
        peerPinCount: boot.peerPinCount,
        receiptCount: receipts.count,
        receipts: summary),
      command: "remote-runner start")
  }

  /// Default remains sandbox-probe; agent engine only when `--engine agent` is explicit.
  private static func parseStartEngine(_ raw: String?) throws -> any TatwoLoopEngineBinding {
    let value = (raw ?? "sandbox-probe")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    switch value {
    case "", "sandbox-probe", "sandbox_probe", "probe":
      return ProcessEngineBinding.sandboxProbe
    case "agent":
      return TatwoAgentEngineBinding.production
    default:
      throw CLIError.usage(
        "remote-runner start --engine must be one of: sandbox-probe, agent (default: sandbox-probe)")
    }
  }

  /// Origin production dispatch: sealed channel + durable pins + Keychain identity.
  ///
  /// Requires an issued Work OS contract (`tatwo.os.begin`); never synthesizes contract/goal.
  ///
  /// ```
  /// tatwo-ultrawork remote-runner dispatch \
  ///   --device-id <origin> --target-device-id <target> \
  ///   --logical-job-id <id> --work-path <dir> \
  ///   --contract-id <issued> --goal-id <issued> \
  ///   --engine-command echo --engine-arg hello \
  ///   [--channel-dir <sealed>] [--job-id <id>] [--dispatch-nonce <nonce>] \
  ///   [--identity sub] [--mode S|M|L|XL|XXL] \
  ///   [--max-duration-sec N] [--max-output-bytes N] --json
  ///
  /// # .tatwoLoop agent task (target must start with --engine agent).
  /// # The target workspace comes only from the signed readiness registry;
  /// # an origin-local --work-path is ignored for this payload.
  /// tatwo-ultrawork remote-runner dispatch ... \
  ///   --task-description "..." --agent grok \
  ///   # or --task-file /path/to/prompt.txt --agent codex
  /// ```
  private static func dispatch(_ args: [String]) throws {
    let originDeviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let targetDeviceID = try TatwoUltraworkCLI.requiredOption("--target-device-id", in: args)
    let logicalJobID = try TatwoUltraworkCLI.requiredOption("--logical-job-id", in: args)
    let requestedWorkPath = TatwoUltraworkCLI.option("--work-path", in: args)
    // J1: contract/goal must come from tatwo.os.begin — never synthesize from logicalJobID.
    let contractID = try requiredContractID(in: args)
    let goalID = try requiredGoalID(in: args)

    // Production refuses pin-store-root override (canonical App Support only).
    if TatwoUltraworkCLI.option("--pin-store-root", in: args) != nil {
      throw CLIError.usage(
        "remote-runner dispatch refuses --pin-store-root; use canonical device-trust pin-store (device-trust init)")
    }

    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    // Fail closed on test-mode / trust-namespace / layout env overrides (same as start).
    try TatwoLoopProductionRunnerBootstrap.rejectProductionTrustNamespaceOverrides(
      environment: environment)
    try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
      environment: environment)
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      throw TatwoLoopProductionRunnerError.testModeForbidden
    }

    let jobID =
      TatwoUltraworkCLI.option("--job-id", in: args)
      ?? UUID().uuidString
    let dispatchNonce =
      TatwoUltraworkCLI.option("--dispatch-nonce", in: args)
      ?? UUID().uuidString
    let identity = try parseIdentity(
      TatwoUltraworkCLI.option("--identity", in: args) ?? "sub")
    let maxDurationSec =
      Double(TatwoUltraworkCLI.option("--max-duration-sec", in: args) ?? "30") ?? 30
    let maxOutputBytes =
      Int(TatwoUltraworkCLI.option("--max-output-bytes", in: args) ?? "65536") ?? 65_536

    let payload = try buildPayload(
      args: args,
      contractID: contractID,
      goalID: goalID,
      identity: identity)
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: originDeviceID)

    let targetReadinessManifest: TatwoRemoteDispatchReadinessManifestV1?
    let remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1?
    let remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1?
    let workspaceLocator: TatwoRemoteWorkspaceLocatorV1?
    let workPath: String
    switch payload {
    case .shellSafe:
      guard
        let requestedWorkPath,
        !requestedWorkPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CLIError.usage(
          "remote-runner dispatch shell-safe payload requires --work-path")
      }
      targetReadinessManifest = nil
      remoteBorrowInvocation = nil
      remoteDispatchReadiness = nil
      workspaceLocator = nil
      workPath = requestedWorkPath
    case let .tatwoLoop(loop):
      guard let agent = loop.agent, let exactModelRouteID = loop.exactModelRouteID else {
        throw CLIError.usage(
          "remote-runner dispatch tatwo-loop requires --agent and --model-route")
      }
      let manifestPath = try TatwoUltraworkCLI.requiredOption(
        "--readiness-manifest", in: args)
      let sessionID = try TatwoUltraworkCLI.requiredOption("--session-id", in: args)
      let grantID = try TatwoUltraworkCLI.requiredOption("--grant-id", in: args)
      let manifest = try readReadinessManifest(
        from: URL(fileURLWithPath: manifestPath, isDirectory: false))

      // Bootstrap before any channel write so the origin's durable trust pins
      // verify the target-signed manifest and its exact route scope.
      let preflightBoot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
        deviceID: originDeviceID,
        originDeviceID: originDeviceID,
        pinStoreRoot: nil,
        channelRoot: channelRoot,
        environment: environment,
        currentOriginLease: currentOriginLease)
      do {
        try manifest.verify(
          trust: preflightBoot.trust,
          expectedTargetDeviceID: targetDeviceID,
          expectedAgent: agent,
          expectedExactModelRouteID: exactModelRouteID,
          environment: environment)
      } catch let error as TatwoRemoteDispatchReadinessRegistryError {
        throw TatwoLoopProductionRunnerError.workOSContractGate(
          error.errorDescription ?? String(describing: error))
      }

      let challengeNonce = "readiness-\(UUID().uuidString)"
      targetReadinessManifest = manifest
      remoteDispatchReadiness = manifest.binding(challengeNonce: challengeNonce)
      workspaceLocator = TatwoRemoteWorkspaceLocatorV1(
        workspaceBindingID: manifest.workspaceBindingID,
        registryGeneration: manifest.registryGeneration)
      // Kept only as an additive wire-compatibility field. Target execution
      // resolves the signed locator from its own registry and never trusts an
      // origin-local absolute path.
      workPath = ""
      remoteBorrowInvocation = TatwoRemoteBorrowInvocationV1(
        sessionID: sessionID,
        targetDeviceID: targetDeviceID,
        contractID: contractID,
        goalID: goalID,
        mode: .manual,
        risk: .lowRisk,
        grantID: grantID)
    }

    let job = TatwoLoopJobV1(
      jobID: jobID,
      logicalJobID: logicalJobID,
      dispatchNonce: dispatchNonce,
      contractID: contractID,
      goalID: goalID,
      identity: identity,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      remoteBorrowInvocation: remoteBorrowInvocation,
      remoteDispatchReadiness: remoteDispatchReadiness,
      workspaceLocator: workspaceLocator,
      payload: payload,
      workPath: workPath,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: maxDurationSec,
        maxOutputBytes: maxOutputBytes),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date())

    let result = try TatwoLoopProductionRunnerBootstrap.dispatch(
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      job: job,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease,
      targetReadinessManifest: targetReadinessManifest)

    TatwoUltraworkCLI.output(
      DispatchOutput(
        jobID: result.job.jobID,
        logicalJobID: result.job.logicalJobID,
        dispatchNonce: result.job.dispatchNonce,
        jobCanonicalDigest: result.jobCanonicalDigest,
        originDeviceID: result.job.originDeviceID,
        targetDeviceID: result.job.targetDeviceID,
        channelRoot: result.channelRoot,
        dispatchRecordID: result.dispatchRecordID,
        pinStoreGeneration: result.bootstrap.pinStoreGeneration,
        peerPinCount: result.bootstrap.peerPinCount),
      command: "remote-runner dispatch")
  }

  private static func requiredContractID(in args: [String]) throws -> String {
    if let value = TatwoUltraworkCLI.option("--contract-id", in: args)
      ?? TatwoUltraworkCLI.option("--contract", in: args)
    {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw CLIError.usage(
          "remote-runner dispatch requires --contract-id issued by tatwo.os.begin")
      }
      return trimmed
    }
    throw CLIError.usage(
      "remote-runner dispatch requires --contract-id (or --contract) issued by tatwo.os.begin; synthesis is forbidden")
  }

  private static func requiredGoalID(in args: [String]) throws -> String {
    if let value = TatwoUltraworkCLI.option("--goal-id", in: args)
      ?? TatwoUltraworkCLI.option("--goal", in: args)
    {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw CLIError.usage(
          "remote-runner dispatch requires --goal-id issued by tatwo.os.begin")
      }
      return trimmed
    }
    throw CLIError.usage(
      "remote-runner dispatch requires --goal-id (or --goal) issued by tatwo.os.begin; synthesis is forbidden")
  }

  private static func buildPayload(
    args: [String],
    contractID: String,
    goalID: String,
    identity: IdentityKind
  ) throws -> TatwoLoopJobPayloadV1 {
    // Mutually exclusive engine payload families.
    let hasShell = TatwoUltraworkCLI.option("--engine-command", in: args) != nil
    let hasTaskText = TatwoUltraworkCLI.option("--task-description", in: args) != nil
      || TatwoUltraworkCLI.option("--task", in: args) != nil
    let hasTaskFile = TatwoUltraworkCLI.option("--task-file", in: args) != nil
    if hasShell && (hasTaskText || hasTaskFile) {
      throw CLIError.usage(
        "remote-runner dispatch: use either --engine-command (shell-safe) or --task-description/--task-file (tatwo-loop), not both")
    }

    if let commandRaw = TatwoUltraworkCLI.option("--engine-command", in: args) {
      guard let command = TatwoShellSafeCommandV1(rawValue: commandRaw) else {
        throw CLIError.usage(
          "remote-runner dispatch --engine-command must be one of: echo, sleep, true, false")
      }
      let engineArgs = TatwoUltraworkCLI.options("--engine-arg", in: args)
      return .shellSafe(TatwoShellSafePayloadV1(command: command, arguments: engineArgs))
    }

    // .tatwoLoop payload: task text/file + agent (target runs via --engine agent).
    if hasTaskText || hasTaskFile {
      let taskDescription = try resolveTaskDescription(in: args)
      let modeRaw = TatwoUltraworkCLI.option("--mode", in: args) ?? "S"
      guard let mode = TatwoLoopModeV1(rawValue: modeRaw) else {
        throw CLIError.usage(
          "remote-runner dispatch --mode must be one of: S, M, L, XL")
      }
      let agent = try requireAgent(in: args)
      let exactModelRouteID = try TatwoUltraworkCLI.requiredOption(
        "--model-route", in: args)
      return .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: identity,
          mode: mode,
          taskDescription: taskDescription,
          agent: agent,
          exactModelRouteID: exactModelRouteID))
    }

    throw CLIError.usage(
      """
      remote-runner dispatch requires engine payload:
        --engine-command <echo|sleep|true|false> [--engine-arg ...]
        or --task-description <text> | --task-file <path> --agent <grok|codex|claude> --model-route <canonical-route> [--mode S|M|L|XL]
      \(dualMachineRunbook)
      """)
  }

  private static func resolveTaskDescription(in args: [String]) throws -> String {
    if let inline = TatwoUltraworkCLI.option("--task-description", in: args)
      ?? TatwoUltraworkCLI.option("--task", in: args)
    {
      let trimmed = inline.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw CLIError.usage("remote-runner dispatch --task-description must be non-empty")
      }
      guard !trimmed.contains("\0") else {
        throw CLIError.usage("remote-runner dispatch --task-description must not contain NUL")
      }
      return inline
    }
    if let filePath = TatwoUltraworkCLI.option("--task-file", in: args) {
      let url = URL(fileURLWithPath: filePath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw CLIError.usage(
          "remote-runner dispatch --task-file not found: \(filePath)")
      }
      let data = try Data(contentsOf: url)
      guard let text = String(data: data, encoding: .utf8) else {
        throw CLIError.usage(
          "remote-runner dispatch --task-file must be UTF-8 text")
      }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw CLIError.usage("remote-runner dispatch --task-file is empty")
      }
      guard !text.contains("\0") else {
        throw CLIError.usage("remote-runner dispatch --task-file must not contain NUL")
      }
      return text
    }
    throw CLIError.usage(
      "remote-runner dispatch requires --task-description or --task-file for tatwo-loop")
  }

  private static func requireAgent(in args: [String]) throws -> TatwoRemoteAgentKindV1 {
    guard let raw = TatwoUltraworkCLI.option("--agent", in: args)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !raw.isEmpty
    else {
      throw CLIError.usage(
        "remote-runner dispatch tatwo-loop requires --agent <grok|codex|claude>")
    }
    guard let agent = TatwoRemoteAgentKindV1(rawValue: raw) else {
      throw CLIError.usage(
        "remote-runner dispatch --agent must be one of: grok, codex, claude")
    }
    return agent
  }

  private static func parseIdentity(_ raw: String) throws -> IdentityKind {
    guard let identity = IdentityKind(rawValue: raw) else {
      throw CLIError.usage(
        "remote-runner dispatch --identity must be one of: lead, supervisor, consultant, sub, news, verifier")
    }
    return identity
  }

  // MARK: - Fleet (mini scheduler)

  private struct FleetRegisterOutput: Encodable {
    let schema = "TatwoFleetRegisterCLIOutputV1"
    let deviceID: String
    let agents: [String]
    let maxConcurrent: Int
    let inflight: Int
    let lastHeartbeatAt: Date
    let fleetRoot: String
  }

  private struct FleetDispatchOutput: Encodable {
    let schema = "TatwoFleetDispatchCLIOutputV1"
    let logicalJobIDs: [String]
    let count: Int
    let requiredAgent: String?
    let fleetRoot: String
  }

  private struct FleetTickOutput: Encodable {
    let schema = "TatwoFleetTickCLIOutputV1"
    let assigned: Int
    let leaseRecoveries: Int
    let commits: Int
    let superseded: Int
    let pendingRemaining: Int
    let skippedFullCapacity: Int
    let skippedStaleHeartbeat: Int
    let skippedMissingCapability: Int
    let assignmentJobIDs: [String]
    let fleetRoot: String
  }

  /// ```
  /// remote-runner fleet register|dispatch|tick|status ...
  /// ```
  private static func fleet(_ args: [String]) throws {
    // args: remote-runner fleet <sub> ...
    let fleetArgs = Array(args.dropFirst())  // drop "remote-runner"
    guard let action = fleetArgs.dropFirst().first else {
      throw CLIError.usage(
        """
        Use: tatwo-ultrawork remote-runner fleet register|dispatch|tick|status|migrate-seal-v2 ...
        """)
    }
    switch action {
    case "register":
      try fleetRegister(args)
    case "dispatch":
      try fleetDispatch(args)
    case "tick":
      try fleetTick(args)
    case "status":
      try fleetStatus(args)
    case "migrate-seal-v2":
      try fleetMigrateSealV2(args)
    default:
      throw CLIError.usage("Unknown remote-runner fleet subcommand: \(action)")
    }
  }

  private struct FleetMigrateSealV2Output: Encodable {
    let originDeviceID: String
    let migratedCount: Int
    let skippedAlreadyV2: Int
    let receiptPath: String
    let fromSchema: String
    let toSchema: String
    let mixedVersionFleetGate: String
    let fleetRoot: String
  }

  /// Human-gated offline re-sign of legacy V1 envelopes → production V2.
  /// General loaders never dual-read V1; mixed fleets stay fail-closed until this runs.
  /// `--confirm` must equal the plan-bound token (fleet-root + inventory + plan hash).
  /// Pass `--print-confirm` alone to print the required token without migrating.
  private static func fleetMigrateSealV2(_ args: [String]) throws {
    let originDeviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: originDeviceID)
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
      deviceID: originDeviceID,
      originDeviceID: originDeviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease)
    let fleetRoot = try resolveFleetRoot(
      in: args, originDeviceID: originDeviceID, requireBootstrap: false)
    let authorityEpoch =
      UInt64(TatwoUltraworkCLI.option("--authority-epoch", in: args) ?? "1") ?? 1
    let originAuthority = TatwoFleetOriginAuthority(
      originDeviceID: originDeviceID,
      authorityEpoch: authorityEpoch,
      trust: boot.channel.trust,
      highWater: TatwoFleetCachingHighWaterAnchor.production(
        originDeviceID: originDeviceID,
        fleetRoot: fleetRoot))
    let plan = try TatwoFleetSealMigration.buildPlan(
      fleetRoot: fleetRoot, origin: originAuthority)
    let expectedConfirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: fleetRoot,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)
    if args.contains("--print-confirm") {
      struct ConfirmOut: Encodable {
        let confirm: String
        let inventoryDigest: String
        let migrationPlanHash: String
        let candidateCount: Int
      }
      TatwoUltraworkCLI.output(
        ConfirmOut(
          confirm: expectedConfirm,
          inventoryDigest: plan.inventoryDigest,
          migrationPlanHash: plan.migrationPlanHash,
          candidateCount: plan.candidates.count),
        command: "remote-runner fleet migrate-seal-v2 --print-confirm")
      return
    }
    let confirm = try TatwoUltraworkCLI.requiredOption("--confirm", in: args)
    let receipt = try TatwoFleetSealMigration.migrateFleetTree(
      fleetRoot: fleetRoot,
      origin: originAuthority,
      confirm: confirm)
    // Core already wrote the origin-signed receipt via pinned-root fd IO.
    // Never re-resolve receipts/ by pathname and rewrite — that reintroduces
    // mid-path symlink escape after Core returns.
    let receiptRelative =
      TatwoFleetSealMigration.signedCompletionReceiptRelativePath(for: receipt)
    let receiptPath =
      receiptRelative.isEmpty
      ? ""
      : fleetRoot.appendingPathComponent(receiptRelative).path
    TatwoUltraworkCLI.output(
      FleetMigrateSealV2Output(
        originDeviceID: receipt.originDeviceID,
        migratedCount: receipt.migrated.count,
        skippedAlreadyV2: receipt.skippedAlreadyV2,
        receiptPath: receiptPath,
        fromSchema: receipt.fromEnvelopeSchema,
        toSchema: receipt.toEnvelopeSchema,
        mixedVersionFleetGate: "general_loader_v2_only",
        fleetRoot: fleetRoot.path),
      command: "remote-runner fleet migrate-seal-v2")
  }

  /// Target-side device registration + capacity heartbeat (target-signed ingest only).
  /// Detects agent executables via whitelist; does not trust free-form capability claims.
  private static func fleetRegister(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let maxConcurrent =
      Int(TatwoUltraworkCLI.option("--max-concurrent", in: args) ?? "1") ?? 1
    let inflight =
      Int(TatwoUltraworkCLI.option("--inflight", in: args) ?? "0") ?? 0
    let originDeviceID =
      TatwoUltraworkCLI.option("--origin-device-id", in: args) ?? deviceID
    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: originDeviceID)
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
      deviceID: deviceID,
      originDeviceID: originDeviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease)
    let fleetRoot = try resolveFleetRoot(in: args, originDeviceID: deviceID, requireBootstrap: false)
    let authorityEpoch =
      UInt64(TatwoUltraworkCLI.option("--authority-epoch", in: args) ?? "1") ?? 1
    let targetSigner = TatwoFleetTargetSigner(
      trust: boot.channel.trust,
      originDeviceID: originDeviceID,
      authorityEpoch: authorityEpoch)
    let scheduler = TatwoFleetScheduler(
      store: TatwoFleetStore(
        rootURL: fleetRoot,
        originAuthorityProvider: boot.channel.originAuthorityProvider),
      targetSigner: targetSigner)
    let device = try scheduler.registerDevice(
      deviceID: deviceID,
      maxConcurrent: maxConcurrent,
      inflight: inflight)
    TatwoUltraworkCLI.output(
      FleetRegisterOutput(
        deviceID: device.deviceID,
        agents: device.agents.map(\.rawValue),
        maxConcurrent: device.maxConcurrent,
        inflight: device.inflight,
        lastHeartbeatAt: device.lastHeartbeatAt,
        fleetRoot: fleetRoot.path),
      command: "remote-runner fleet register")
  }

  /// Origin-side enqueue only — scheduler tick performs assignment + dispatch path.
  private static func fleetDispatch(_ args: [String]) throws {
    let originDeviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let requestedWorkPath = TatwoUltraworkCLI.option("--work-path", in: args)
    let contractID = try requiredContractID(in: args)
    let goalID = try requiredGoalID(in: args)
    let identity = try parseIdentity(
      TatwoUltraworkCLI.option("--identity", in: args) ?? "sub")
    let count = max(1, Int(TatwoUltraworkCLI.option("--count", in: args) ?? "1") ?? 1)
    let logicalPrefix =
      TatwoUltraworkCLI.option("--logical-job-id", in: args)
      ?? "fleet-\(UUID().uuidString)"
    let maxDurationSec =
      Double(TatwoUltraworkCLI.option("--max-duration-sec", in: args) ?? "30") ?? 30
    let maxOutputBytes =
      Int(TatwoUltraworkCLI.option("--max-output-bytes", in: args) ?? "65536") ?? 65_536
    let payload = try buildPayload(
      args: args,
      contractID: contractID,
      goalID: goalID,
      identity: identity)
    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: originDeviceID)
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
      deviceID: originDeviceID,
      originDeviceID: originDeviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease)
    let fleetRoot = try resolveFleetRoot(
      in: args, originDeviceID: originDeviceID, requireBootstrap: false)
    let authorityEpoch =
      UInt64(TatwoUltraworkCLI.option("--authority-epoch", in: args) ?? "1") ?? 1
    // Production writers must share the same durable (Keychain) high-water as tick/status.
    // File-only anchor is not an anti-rollback boundary under the fleet threat model.
    let originAuthority = TatwoFleetOriginAuthority(
      originDeviceID: originDeviceID,
      authorityEpoch: authorityEpoch,
      trust: boot.channel.trust,
      highWater: TatwoFleetCachingHighWaterAnchor.production(
        originDeviceID: originDeviceID,
        fleetRoot: fleetRoot))
    let scheduler = TatwoFleetScheduler(
      store: TatwoFleetStore(
        rootURL: fleetRoot,
        originAuthority: originAuthority,
        originAuthorityProvider: boot.channel.originAuthorityProvider))
    let remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1?
    let remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1?
    let workspaceLocator: TatwoRemoteWorkspaceLocatorV1?
    let workPath: String
    switch payload {
    case .shellSafe:
      guard
        let requestedWorkPath,
        !requestedWorkPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CLIError.usage(
          "remote-runner fleet dispatch shell-safe payload requires --work-path")
      }
      remoteBorrowInvocation = nil
      remoteDispatchReadiness = nil
      workspaceLocator = nil
      workPath = requestedWorkPath
    case let .tatwoLoop(loop):
      guard let agent = loop.agent, let exactModelRouteID = loop.exactModelRouteID else {
        throw CLIError.usage(
          "remote-runner fleet dispatch tatwo-loop requires --agent and --model-route")
      }
      let targetDeviceID = try TatwoUltraworkCLI.requiredOption(
        "--target-device-id", in: args)
      let sessionID = try TatwoUltraworkCLI.requiredOption("--session-id", in: args)
      let grantID = try TatwoUltraworkCLI.requiredOption("--grant-id", in: args)
      let manifestURL = try readinessChannelManifestURL(
        channelRoot: boot.channel.rootURL,
        targetDeviceID: targetDeviceID,
        requestedAgent: agent,
        exactModelRouteID: exactModelRouteID)
      let manifest = try readReadinessManifest(from: manifestURL)
      do {
        try manifest.verify(
          trust: boot.trust,
          expectedTargetDeviceID: targetDeviceID,
          expectedAgent: agent,
          expectedExactModelRouteID: exactModelRouteID,
          environment: environment)
      } catch let error as TatwoRemoteDispatchReadinessRegistryError {
        throw TatwoLoopProductionRunnerError.workOSContractGate(
          error.errorDescription ?? String(describing: error))
      }
      remoteBorrowInvocation = TatwoRemoteBorrowInvocationV1(
        sessionID: sessionID,
        targetDeviceID: targetDeviceID,
        contractID: contractID,
        goalID: goalID,
        mode: .manual,
        risk: .lowRisk,
        grantID: grantID)
      // Scheduler replaces this template challenge for every physical attempt.
      remoteDispatchReadiness = manifest.binding(
        challengeNonce: "fleet-template-\(UUID().uuidString)")
      workspaceLocator = TatwoRemoteWorkspaceLocatorV1(
        workspaceBindingID: manifest.workspaceBindingID,
        registryGeneration: manifest.registryGeneration)
      workPath = ""
    }
    let jobs = try scheduler.enqueue(
      originDeviceID: originDeviceID,
      logicalJobIDPrefix: logicalPrefix,
      count: count,
      contractID: contractID,
      goalID: goalID,
      identity: identity,
      workPath: workPath,
      payload: payload,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: maxDurationSec,
        maxOutputBytes: maxOutputBytes),
      remoteBorrowInvocation: remoteBorrowInvocation,
      remoteDispatchReadiness: remoteDispatchReadiness,
      workspaceLocator: workspaceLocator)
    let requiredAgent: String?
    switch payload {
    case let .tatwoLoop(loop):
      requiredAgent = loop.agent?.rawValue
    case .shellSafe:
      requiredAgent = nil
    }
    TatwoUltraworkCLI.output(
      FleetDispatchOutput(
        logicalJobIDs: jobs.map(\.logicalJobID),
        count: jobs.count,
        requiredAgent: requiredAgent,
        fleetRoot: fleetRoot.path),
      command: "remote-runner fleet dispatch")
  }

  /// One mini tick: converge results, recover expired leases, assign pending via dispatch path.
  private static func fleetTick(_ args: [String]) throws {
    let originDeviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    if TatwoUltraworkCLI.option("--pin-store-root", in: args) != nil {
      throw CLIError.usage(
        "remote-runner fleet tick refuses --pin-store-root; use canonical device-trust pin-store")
    }
    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    try TatwoLoopProductionRunnerBootstrap.rejectProductionTrustNamespaceOverrides(
      environment: environment)
    try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
      environment: environment)
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      throw TatwoLoopProductionRunnerError.testModeForbidden
    }

    let leaseSeconds =
      Double(TatwoUltraworkCLI.option("--lease-seconds", in: args) ?? "300") ?? 300
    let leaseGrace =
      Double(TatwoUltraworkCLI.option("--lease-grace-seconds", in: args) ?? "30") ?? 30
    let heartbeatMaxAge =
      Double(TatwoUltraworkCLI.option("--heartbeat-max-age", in: args) ?? "90") ?? 90
    let config = TatwoFleetTickConfigV1(
      leaseSeconds: leaseSeconds,
      leaseGraceSeconds: leaseGrace,
      heartbeatMaxAgeSeconds: heartbeatMaxAge)
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: originDeviceID)

    // Bootstrap origin for signed dispatch + result audit probe.
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
      deviceID: originDeviceID,
      originDeviceID: originDeviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease)
    let fleetRoot = TatwoFleetStore.underChannelRoot(
      URL(fileURLWithPath: boot.channel.rootURL.path, isDirectory: true)
    ).rootURL
    // Allow explicit --fleet-dir override for co-located state without channel.
    let resolvedFleetRoot =
      TatwoUltraworkCLI.option("--fleet-dir", in: args).map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? fleetRoot
    let authorityEpoch =
      UInt64(TatwoUltraworkCLI.option("--authority-epoch", in: args) ?? "1") ?? 1
    let originAuthority = TatwoFleetOriginAuthority(
      originDeviceID: originDeviceID,
      authorityEpoch: authorityEpoch,
      trust: boot.channel.trust,
      highWater: TatwoFleetCachingHighWaterAnchor.production(
        originDeviceID: originDeviceID,
        fleetRoot: resolvedFleetRoot))
    let scheduler = TatwoFleetScheduler(
      store: TatwoFleetStore(
        rootURL: resolvedFleetRoot,
        originAuthority: originAuthority,
        originAuthorityProvider: boot.channel.originAuthorityProvider),
      signedJobProbe: { jobID in
        // Fail closed: probe errors and missing jobs must throw (never try? → nil).
        try boot.channel.job(forJobID: jobID)
      })
    let channel = boot.channel

    let tickResult = try scheduler.tick(
      config: config,
      dispatch: { job in
        let targetReadinessManifest: TatwoRemoteDispatchReadinessManifestV1?
        switch job.payload {
        case .shellSafe:
          targetReadinessManifest = nil
        case let .tatwoLoop(loop):
          guard let agent = loop.agent, let exactModelRouteID = loop.exactModelRouteID else {
            throw TatwoLoopProductionRunnerError.workOSContractGate(
              "fleet production dispatch requires an exact agent and model route")
          }
          let manifestURL = try readinessChannelManifestURL(
            channelRoot: boot.channel.rootURL,
            targetDeviceID: job.targetDeviceID,
            requestedAgent: agent,
            exactModelRouteID: exactModelRouteID)
          let manifest = try readReadinessManifest(from: manifestURL)
          // Re-read and validate the sealed current manifest at assignment time.
          // If the target refreshed/replaced it after queueing, fail closed
          // instead of rewriting the job's authorization or workspace binding.
          try manifest.validateCurrentProductionAgentBinding(
            for: job,
            trust: boot.channel.trust,
            environment: environment)
          targetReadinessManifest = manifest
        }
        let dispatched = try TatwoLoopProductionRunnerBootstrap.dispatch(
          originDeviceID: originDeviceID,
          targetDeviceID: job.targetDeviceID,
          job: job,
          pinStoreRoot: nil,
          channelRoot: channelRoot ?? boot.channel.rootURL,
          environment: environment,
          currentOriginLease: currentOriginLease,
          targetReadinessManifest: targetReadinessManifest)
        return TatwoFleetDispatchReceiptV1(
          jobID: dispatched.job.jobID,
          dispatchNonce: dispatched.job.dispatchNonce,
          targetDeviceID: dispatched.job.targetDeviceID,
          jobCanonicalDigest: dispatched.jobCanonicalDigest,
          dispatchRecordID: dispatched.dispatchRecordID)
      },
      resultProbe: { jobID in
        try channel.resultForAudit(for: jobID)
      })

    TatwoUltraworkCLI.output(
      FleetTickOutput(
        assigned: tickResult.assigned.count,
        leaseRecoveries: tickResult.leaseRecoveries.count,
        commits: tickResult.commits.count,
        superseded: tickResult.superseded.count,
        pendingRemaining: tickResult.pendingRemaining,
        skippedFullCapacity: tickResult.skippedFullCapacity,
        skippedStaleHeartbeat: tickResult.skippedStaleHeartbeat,
        skippedMissingCapability: tickResult.skippedMissingCapability,
        assignmentJobIDs: tickResult.assigned.map(\.jobID),
        fleetRoot: resolvedFleetRoot.path),
      command: "remote-runner fleet tick")
  }

  private static func fleetStatus(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let channelRoot = TatwoUltraworkCLI.option("--channel-dir", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let environment = ProcessInfo.processInfo.environment
    let currentOriginLease = try configuredOriginLease(args: args, deviceID: deviceID)
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrapWithKeychain(
      deviceID: deviceID,
      originDeviceID: deviceID,
      pinStoreRoot: nil,
      channelRoot: channelRoot,
      environment: environment,
      currentOriginLease: currentOriginLease)
    let fleetRoot = try resolveFleetRoot(in: args, originDeviceID: deviceID, requireBootstrap: false)
    let authorityEpoch =
      UInt64(TatwoUltraworkCLI.option("--authority-epoch", in: args) ?? "1") ?? 1
    // Production readers must use the same durable high-water as dispatch/tick.
    let originAuthority = TatwoFleetOriginAuthority(
      originDeviceID: deviceID,
      authorityEpoch: authorityEpoch,
      trust: boot.channel.trust,
      highWater: TatwoFleetCachingHighWaterAnchor.production(
        originDeviceID: deviceID,
        fleetRoot: fleetRoot))
    let scheduler = TatwoFleetScheduler(
      store: TatwoFleetStore(
        rootURL: fleetRoot,
        originAuthority: originAuthority,
        originAuthorityProvider: boot.channel.originAuthorityProvider))
    let status = try scheduler.status()
    TatwoUltraworkCLI.output(status, command: "remote-runner fleet status")
  }

  /// Handoff lease configuration. Production callers must provide a registered
  /// domain; omitting it is reserved for explicit test-mode fixtures.
  private static func configuredOriginLease(
    args: [String],
    deviceID: String
  ) throws -> TatwoAuthorityLeaseV1? {
    let environment = ProcessInfo.processInfo.environment
    let rawDomain =
      TatwoUltraworkCLI.option("--handoff-domain-id", in: args)
      ?? environment["TATWO_HANDOFF_DOMAIN_ID"]
    guard let domainID = rawDomain?.trimmingCharacters(in: .whitespacesAndNewlines),
      !domainID.isEmpty
    else {
      return nil
    }
    let authorityRoot: URL
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      if let channel = TatwoUltraworkCLI.option("--channel-dir", in: args)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !channel.isEmpty
      {
        authorityRoot = URL(fileURLWithPath: channel, isDirectory: true)
          .appendingPathComponent("handoff-authority", isDirectory: true)
      } else if let channel = environment["TATWO_ULTRAWORK_JOB_CHANNEL_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !channel.isEmpty
      {
        authorityRoot = URL(fileURLWithPath: channel, isDirectory: true)
          .appendingPathComponent("handoff-authority", isDirectory: true)
      } else {
        throw CLIError.usage(
          "test handoff lease requires --channel-dir or TATWO_ULTRAWORK_JOB_CHANNEL_DIR")
      }
    } else {
      // Production authority registration lives under the same canonical
      // OS-native state root used by the sealed bootstrap layout.  It must
      // never be derived from the job-channel path.
      authorityRoot = TatwoProductionLayoutLock.osNativeStateRoot()
        .appendingPathComponent("handoff-authority", isDirectory: true)
    }
    do {
      try TatwoAuthorityDomainRegistryV1(rootURL: authorityRoot)
        .requireRegistered(domainID: domainID)
    } catch {
      // Registration is a separate human-gated operation.  This path may
      // consume a lease, never create an authority namespace.
      throw CLIError.usage("remote-runner handoff domain is not registered: \(domainID)")
    }
    let rawEpoch =
      TatwoUltraworkCLI.option("--authority-epoch", in: args)
      ?? environment["TATWO_HANDOFF_AUTHORITY_EPOCH"]
      ?? "1"
    let epoch = max(UInt64(rawEpoch) ?? 1, 1)
    let now = Date()
    let metadata = TatwoWorkReceiptMetadataV1(
      receiptID: "handoff-origin-\(domainID)-\(deviceID)",
      schema: "TatwoHandoffLeaseInitialV1",
      version: 1,
      correlationID: domainID,
      createdAt: now,
      sourceDeviceID: deviceID)
    return TatwoAuthorityLeaseV1(
      domainID: domainID,
      holderDeviceID: deviceID,
      epoch: epoch,
      fencingToken: "initial-\(domainID)-\(deviceID)",
      observedAt: now,
      expiresAt: .distantFuture,
      source: .humanConfirmed,
      receiptMetadata: metadata)
  }

  /// Resolve fleet root: `--fleet-dir` > `<channel-dir>/fleet` > bootstrap channel fleet.
  private static func resolveFleetRoot(
    in args: [String],
    originDeviceID: String,
    requireBootstrap: Bool
  ) throws -> URL {
    if let explicit = TatwoUltraworkCLI.option("--fleet-dir", in: args) {
      return URL(fileURLWithPath: explicit, isDirectory: true)
    }
    if let channelDir = TatwoUltraworkCLI.option("--channel-dir", in: args) {
      return TatwoFleetStore.underChannelRoot(
        URL(fileURLWithPath: channelDir, isDirectory: true)
      ).rootURL
    }
    if let env = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_JOB_CHANNEL_DIR"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !env.isEmpty
    {
      return TatwoFleetStore.underChannelRoot(
        URL(fileURLWithPath: env, isDirectory: true)
      ).rootURL
    }
    if requireBootstrap {
      throw CLIError.usage(
        "remote-runner fleet requires --fleet-dir or --channel-dir (or TATWO_ULTRAWORK_JOB_CHANNEL_DIR)")
    }
    // Last resort: under App Support state (register/status offline tools).
    let state = TatwoRuntimeLayout.stateRoot()
    return state.appendingPathComponent("fleet", isDirectory: true)
  }
}

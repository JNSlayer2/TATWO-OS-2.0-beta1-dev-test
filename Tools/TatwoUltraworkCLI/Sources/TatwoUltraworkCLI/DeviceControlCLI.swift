import Foundation
import TatwoUltraworkCore

/// File-only device mutual-control tooling.
///
/// This namespace deliberately has no execute/send/enqueue verb. It creates and
/// verifies signed artifacts which a separately authorized fleet adapter may
/// transport.
enum TatwoDeviceControlCLI {
  private struct DescriptorCreateOutput: Encodable {
    let schema = "TatwoDeviceControlDescriptorCreateCLIOutputV1"
    let outputPath: String
    let targetDeviceID: String
    let templateID: String
    let capabilityVersion: UInt64
    let descriptorDigest: String
    let manifestDigest: String
    let signed: Bool
    let riskClassificationSource = "validator"
  }

  private struct ValidationOutput: Encodable {
    let schema = "TatwoDeviceControlValidationCLIOutputV1"
    let accepted: Bool
    let riskLevel: TatwoMutualControlRiskLevelV1?
    let highRiskCategory: TatwoMutualControlHighRiskCategoryV1?
    let requiresHumanGate: Bool
    let errorCode: TatwoMutualControlErrorCodeV1?
    let detail: String?
    let templateID: String?
    let capabilityVersion: UInt64?
    let descriptorDigest: String?
    let invokeCanonicalDigest: String?
    let resolvedExecutable: String?
    let resolvedArgv: [String]?
  }

  private struct DispatchPlanOutput: Encodable {
    let schema = "TatwoDeviceControlDispatchPlanCLIOutputV1"
    let outputPath: String
    let dispatchID: String
    let jobID: String
    let dispatchNonce: String
    let targetDeviceID: String
    let riskLevel: TatwoMutualControlRiskLevelV1
    let requiresHumanGate: Bool
    let humanGateTokenBound: Bool
    let transported: Bool
    let executed: Bool
  }

  private struct SignedResultFile: Decodable {
    let schema: String?
    let binding: TatwoMutualControlResultBindingV1
    let targetSignature: TatwoDeviceSignatureV1?
  }

  private struct ResultVerifyOutput: Encodable {
    let schema = "TatwoDeviceControlResultVerifyCLIOutputV1"
    let accepted: Bool
    let targetSignatureVerified: Bool
    let attemptBindingVerified: Bool
    let targetDeviceID: String
    let jobID: String
    let dispatchNonce: String
    let receipt: TatwoMutualControlReceiptV1
  }

  static func run(_ args: [String]) throws {
    guard let subcommand = args.dropFirst().first else {
      throw CLIError.usage(usage)
    }
    switch subcommand {
    case "descriptor-create":
      try descriptorCreate(args)
    case "validate":
      try validate(args)
    case "dispatch-plan":
      try dispatchPlan(args)
    case "result-verify":
      try resultVerify(args)
    default:
      throw CLIError.usage(
        "Unknown device-control subcommand: \(subcommand)\n\(usage)")
    }
  }

  private static func descriptorCreate(_ args: [String]) throws {
    let outputPath = try TatwoUltraworkCLI.requiredOption("--out", in: args)
    let templateID = try TatwoUltraworkCLI.requiredOption("--template-id", in: args)
    let argv = try csv(
      TatwoUltraworkCLI.requiredOption("--argv", in: args),
      option: "--argv")
    guard let executable = argv.first, !executable.isEmpty else {
      throw CLIError.usage("--argv must begin with a fixed executable")
    }
    let rawArguments = Array(argv.dropFirst())
    let allowances = try parseAllowances(
      TatwoUltraworkCLI.requiredOption("--allow", in: args),
      argvCount: argv.count)
    let timeout = try positiveDouble(
      TatwoUltraworkCLI.option("--timeout", in: args) ?? "30",
      option: "--timeout")
    let maxOutputBytes = try positiveInt(
      TatwoUltraworkCLI.option("--max-output-bytes", in: args) ?? "65536",
      option: "--max-output-bytes")
    let capabilityVersion = try positiveUInt64(
      TatwoUltraworkCLI.option("--capability-version", in: args) ?? "1",
      option: "--capability-version")

    var template = rawArguments
    var slots: [TatwoMutualControlParamSlotV1] = []
    for allowance in allowances.sorted(by: { $0.position < $1.position }) {
      // Positions use conventional process argv numbering: 0 is executable,
      // therefore an allowed position N maps to argvTemplate[N - 1].
      let name = "arg\(allowance.position)"
      template[allowance.position - 1] = "{\(name)}"
      slots.append(
        TatwoMutualControlParamSlotV1(
          name: name,
          constraint: .regex(allowance.pattern)))
    }

    // Risk fields are intentionally non-authoritative hints. The verifier
    // classifies the executable + resolved argv and upgrades high-risk shapes.
    let descriptor = TatwoDeviceCapabilityDescriptorV1(
      templateID: templateID,
      executable: executable,
      argvTemplate: template,
      paramSlots: slots,
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: timeout,
        maxOutputBytes: maxOutputBytes),
      riskLevel: .normal,
      highRiskCategory: nil,
      sideEffectClass: .readOnly,
      notes: "Risk classification is verifier-owned; caller declarations are not accepted.")
    let trust = try localTrust(args)
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: trust.localIdentity.deviceID,
      capabilityVersion: capabilityVersion,
      descriptors: [descriptor],
      trust: trust)
    try writeJSON(manifest, to: URL(fileURLWithPath: outputPath))
    guard let signedDescriptor = manifest.descriptors.first,
      let descriptorDigest = signedDescriptor.descriptorDigest,
      manifest.producerSignature != nil
    else {
      throw CLIError.usage("signed descriptor manifest creation failed closed")
    }
    TatwoUltraworkCLI.output(
      DescriptorCreateOutput(
        outputPath: URL(fileURLWithPath: outputPath).standardizedFileURL.path,
        targetDeviceID: manifest.targetDeviceID,
        templateID: signedDescriptor.templateID,
        capabilityVersion: manifest.capabilityVersion,
        descriptorDigest: descriptorDigest,
        manifestDigest: manifest.manifestDigest,
        signed: true),
      command: "device-control descriptor-create")
  }

  private static func validate(_ args: [String]) throws {
    let manifest = try read(
      TatwoDeviceCapabilityManifestV1.self,
      from: TatwoUltraworkCLI.requiredOption("--descriptor", in: args))
    let invocation = try readJSONOption(
      TatwoMutualControlInvocationV1.self,
      value: TatwoUltraworkCLI.requiredOption("--invocation", in: args),
      option: "--invocation")
    let result = try validation(
      invocation: invocation,
      manifest: manifest,
      args: args)
    outputValidation(result, command: "device-control validate")
  }

  private static func dispatchPlan(_ args: [String]) throws {
    let outputPath = try TatwoUltraworkCLI.requiredOption("--out", in: args)
    let expectedTarget = try TatwoUltraworkCLI.requiredOption(
      "--target-device", in: args)
    let manifest = try read(
      TatwoDeviceCapabilityManifestV1.self,
      from: TatwoUltraworkCLI.requiredOption("--descriptor", in: args))
    let suppliedInvocation = try readJSONOption(
      TatwoMutualControlInvocationV1.self,
      value: TatwoUltraworkCLI.requiredOption("--invocation", in: args),
      option: "--invocation")
    guard manifest.targetDeviceID == expectedTarget,
      suppliedInvocation.targetDeviceID == expectedTarget
    else {
      throw CLIError.usage(
        "--target-device must match descriptor owner and invocation target")
    }

    let approvalID: String?
    if let tokenPath = TatwoUltraworkCLI.option("--human-gate", in: args) {
      let bytes = try Data(contentsOf: URL(fileURLWithPath: tokenPath))
      guard !bytes.isEmpty else {
        throw CLIError.usage("--human-gate token file must not be empty")
      }
      // Never copy raw approval material into a job. Presence is bound as an
      // opaque digest; expiry/replay/authorization validity remain outside S2.
      approvalID = "sha256:\(TatwoLoopJobChannelTrust.sha256Hex(bytes))"
    } else {
      approvalID = nil
    }
    let invocation = copyInvocation(
      suppliedInvocation,
      // dispatch-plan accepts gate presence only from the explicit token-file
      // option. An invocation-embedded approvalID is never authority.
      approvalID: approvalID)
    let validationResult = try validation(
      invocation: invocation,
      manifest: manifest,
      args: args)
    guard validationResult.accepted else {
      outputValidation(
        validationResult,
        command: "device-control dispatch-plan")
    }
    guard let descriptor = manifest.descriptor(templateID: invocation.templateID) else {
      throw CLIError.usage("validated descriptor disappeared from manifest")
    }
    let dispatch = try TatwoMutualControlDispatchV1.make(
      invocation: invocation,
      validation: validationResult,
      resourceLimits: descriptor.resourceLimits,
      descriptorDigest: validationResult.descriptorDigest,
      leaseDomainBinding: invocation.leaseDomainBinding,
      originAuthorityProvider: TatwoNoLeaseDomainAuthority())
    try writeJSON(dispatch, to: URL(fileURLWithPath: outputPath))
    TatwoUltraworkCLI.output(
      DispatchPlanOutput(
        outputPath: URL(fileURLWithPath: outputPath).standardizedFileURL.path,
        dispatchID: dispatch.dispatchID,
        jobID: dispatch.remoteLoopJob.jobID,
        dispatchNonce: dispatch.remoteLoopJob.dispatchNonce,
        targetDeviceID: dispatch.payload.targetDeviceID,
        riskLevel: dispatch.payload.riskLevel,
        requiresHumanGate: dispatch.payload.requiresHumanGate,
        humanGateTokenBound: dispatch.payload.humanGateToken != nil,
        transported: false,
        executed: false),
      command: "device-control dispatch-plan")
  }

  private static func resultVerify(_ args: [String]) throws {
    let signedResult = try read(
      SignedResultFile.self,
      from: TatwoUltraworkCLI.requiredOption("--result", in: args))
    if let schema = signedResult.schema,
      schema != "TatwoMutualControlSignedResultV1"
    {
      throw CLIError.usage("unsupported signed result wrapper schema: \(schema)")
    }
    let dispatch = try read(
      TatwoMutualControlDispatchV1.self,
      from: TatwoUltraworkCLI.requiredOption("--job", in: args))
    let receipt = try TatwoMutualControlResultRecoveryV1.acceptCompleted(
      dispatch: dispatch,
      binding: signedResult.binding,
      targetSignature: signedResult.targetSignature,
      verifierTrust: try localTrust(args))
    TatwoUltraworkCLI.output(
      ResultVerifyOutput(
        accepted: true,
        targetSignatureVerified: true,
        attemptBindingVerified: true,
        targetDeviceID: dispatch.payload.targetDeviceID,
        jobID: dispatch.remoteLoopJob.jobID,
        dispatchNonce: dispatch.remoteLoopJob.dispatchNonce,
        receipt: receipt),
      command: "device-control result-verify")
  }

  private static func validation(
    invocation: TatwoMutualControlInvocationV1,
    manifest: TatwoDeviceCapabilityManifestV1,
    args: [String]
  ) throws -> TatwoMutualControlValidationResultV1 {
    let trust = try localTrust(args)
    guard let pinned = trust.pinnedIdentities[manifest.targetDeviceID] else {
      throw CLIError.usage(
        "descriptor owner is not pinned in the local device trust store")
    }
    return TatwoMutualControlValidatorV1.validate(
      invocation: invocation,
      manifest: manifest,
      pinnedIdentity: pinned)
  }

  private static func outputValidation(
    _ result: TatwoMutualControlValidationResultV1,
    command: String
  ) -> Never {
    TatwoUltraworkCLI.output(
      ValidationOutput(
        accepted: result.accepted,
        riskLevel: result.riskLevel,
        highRiskCategory: result.highRiskCategory,
        requiresHumanGate: result.requiresHumanGate,
        errorCode: result.errorCode,
        detail: result.detail,
        templateID: result.templateID,
        capabilityVersion: result.capabilityVersion,
        descriptorDigest: result.descriptorDigest,
        invokeCanonicalDigest: result.invokeCanonicalDigest,
        resolvedExecutable: result.resolvedExecutable,
        resolvedArgv: result.resolvedArgv),
      command: command,
      ok: result.accepted)
    Foundation.exit(result.accepted ? 0 : 3)
  }

  private static func copyInvocation(
    _ value: TatwoMutualControlInvocationV1,
    approvalID: String?
  ) -> TatwoMutualControlInvocationV1 {
    TatwoMutualControlInvocationV1(
      schema: value.schema,
      purpose: value.purpose,
      logicalControlID: value.logicalControlID,
      jobID: value.jobID,
      dispatchNonce: value.dispatchNonce,
      sourceDeviceID: value.sourceDeviceID,
      operatorPrincipalID: value.operatorPrincipalID,
      targetDeviceID: value.targetDeviceID,
      templateID: value.templateID,
      capabilityVersion: value.capabilityVersion,
      params: value.params,
      approvalID: approvalID,
      requestedTimeoutSec: value.requestedTimeoutSec,
      requestedMaxOutputBytes: value.requestedMaxOutputBytes,
      invokeCanonicalDigest: value.invokeCanonicalDigest,
      leaseDomainBinding: value.leaseDomainBinding)
  }

  private struct Allowance {
    let position: Int
    let pattern: String
  }

  private static func parseAllowances(
    _ raw: String,
    argvCount: Int
  ) throws -> [Allowance] {
    let entries = try csv(raw, option: "--allow")
    var seen: Set<Int> = []
    return try entries.map { entry in
      guard let separator = entry.firstIndex(of: ":") else {
        throw CLIError.usage("--allow entries must use pos:pattern")
      }
      let positionText = String(entry[..<separator])
      let pattern = String(entry[entry.index(after: separator)...])
      guard let position = Int(positionText),
        position > 0,
        position < argvCount
      else {
        throw CLIError.usage(
          "--allow positions are 1...\(max(0, argvCount - 1)); position 0 is the executable")
      }
      guard !pattern.isEmpty else {
        throw CLIError.usage("--allow regex pattern must not be empty")
      }
      guard seen.insert(position).inserted else {
        throw CLIError.usage("--allow contains duplicate position \(position)")
      }
      return Allowance(position: position, pattern: pattern)
    }
  }

  private static func csv(_ raw: String, option: String) throws -> [String] {
    let values = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !values.isEmpty, !values.contains(where: \.isEmpty) else {
      throw CLIError.usage("\(option) must be a non-empty comma-separated list")
    }
    return values
  }

  private static func positiveDouble(_ value: String, option: String) throws -> Double {
    guard let result = Double(value), result > 0, result.isFinite else {
      throw CLIError.usage("\(option) must be a positive number")
    }
    return result
  }

  private static func positiveInt(_ value: String, option: String) throws -> Int {
    guard let result = Int(value), result > 0 else {
      throw CLIError.usage("\(option) must be a positive integer")
    }
    return result
  }

  private static func positiveUInt64(_ value: String, option: String) throws -> UInt64 {
    guard let result = UInt64(value), result > 0 else {
      throw CLIError.usage("\(option) must be a positive integer")
    }
    return result
  }

  private static func localTrust(_ args: [String]) throws -> TatwoLoopJobChannelTrust {
    let environment = ProcessInfo.processInfo.environment
    let identityURL: URL
    if let explicit = TatwoUltraworkCLI.option("--identity", in: args) {
      identityURL = URL(fileURLWithPath: explicit)
    } else {
      identityURL = TatwoRuntimeLayout.deviceTrustRoot(environment: environment)
        .appendingPathComponent(
          TatwoRuntimeLayout.deviceTrustLocalIdentityFileName,
          isDirectory: false)
    }
    let identity = try read(TatwoDevicePublicIdentityV1.self, from: identityURL.path)
    let privateKeyStore: any TatwoDevicePrivateKeyStore
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1",
      let root = environment["TATWO_DEVICE_TRUST_TEST_KEY_ROOT"],
      !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      privateKeyStore = try TatwoDeviceTestFilePrivateKeyStore(
        rootURL: URL(fileURLWithPath: root, isDirectory: true),
        testModeAuthorized: true,
        environment: environment)
    } else {
      let service = try TatwoDeviceKeychainPrivateKeyStore.configuration(
        environment: environment)
      privateKeyStore = TatwoDeviceKeychainPrivateKeyStore(service: service)
    }
    let storeRoot = TatwoUltraworkCLI.option("--store-root", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? TatwoDeviceTrustPinStore.defaultRoot(environment: environment)
    let authority = TatwoDeviceTrustAuthority(privateKeyStore: privateKeyStore)
    try authority.assertLocalPrivateKey(matches: identity)
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: storeRoot,
      authority: authority,
      localIdentity: identity,
      environment: environment)
    let loaded = try pinStore.load()
    guard loaded.rejectedPinCount == 0, loaded.rejectedRevocationCount == 0 else {
      throw CLIError.usage("device trust pin store contains rejected records")
    }
    var pins = loaded.pins
    pins[identity.deviceID] = try TatwoLoopJobChannelTrust.mergePinnedIdentity(
      existing: pins[identity.deviceID],
      incoming: identity)
    return TatwoLoopJobChannelTrust(
      authority: authority,
      localIdentity: pins[identity.deviceID] ?? identity,
      pinnedIdentities: pins,
      pinStoreGeneration: loaded.storeGeneration,
      durablePinStoreRoot: storeRoot)
  }

  private static func read<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  private static func readJSONOption<T: Decodable>(
    _ type: T.Type,
    value: String,
    option: String
  ) throws -> T {
    let data: Data
    if value.hasPrefix("@") {
      let path = String(value.dropFirst())
      guard !path.isEmpty else {
        throw CLIError.usage("\(option) @file path must not be empty")
      }
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } else {
      guard let inline = value.data(using: .utf8) else {
        throw CLIError.usage("\(option) must be UTF-8 JSON")
      }
      data = inline
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw CLIError.usage("\(option) is not valid inline JSON (or use @<file>): \(error)")
    }
  }

  private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw CLIError.usage("Refusing to replace symbolic-link artifact: \(url.path)")
      }
    }
    try manager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private static let usage = """
    Use (artifact-only; never sends or executes):
      tatwo-ultrawork device-control descriptor-create --out <file> --template-id <id> --argv <executable,arg,...> --allow <pos:regex,...> [--timeout N] [--max-output-bytes N]
      tatwo-ultrawork device-control validate --descriptor <file> --invocation '<json>'
      tatwo-ultrawork device-control dispatch-plan --descriptor <file> --invocation '<json>' --target-device <id> [--human-gate <token-file>] --out <job-file>
      tatwo-ultrawork device-control result-verify --result <TatwoMutualControlSignedResultV1-file> --job <job-file>

    --allow positions use process argv numbering: 0 is the fixed executable;
    allowed positions begin at 1 and become invocation params named arg1, arg2, ...
    --invocation accepts a literal JSON object; @<file> is the explicit file form.
    Optional trust plumbing: --identity <identity.json> --store-root <pin-store>.
    """
}

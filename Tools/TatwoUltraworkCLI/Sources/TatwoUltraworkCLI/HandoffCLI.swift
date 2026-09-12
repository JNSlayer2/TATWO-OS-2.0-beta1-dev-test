import Foundation
import TatwoUltraworkCore

enum TatwoHandoffCLI {
  private struct PackCreateOutput: Encodable {
    let schema = "TatwoHandoffPackCreateCLIOutputV1"
    let outputPath: String
    let packDigest: String
    let producerDeviceID: String
    let receiverDeviceID: String
    let handoffID: String
    let logicalJobID: String
  }

  private struct PackVerifyOutput: Encodable {
    let schema = "TatwoHandoffPackVerifyCLIOutputV1"
    let accepted: Bool
    let packDigest: String?
    let producerDeviceID: String
    let receiverDeviceID: String?
    let verification: TatwoHandoffPackVerificationResultV1
  }

  private struct AssessmentOutput: Encodable {
    let schema = "TatwoHandoffAssessCLIOutputV1"
    let outputPath: String
    let packDigest: String
    let reporterDeviceID: String
    let decision: TatwoHandoffCapabilityDecisionV1
    let assessment: TatwoHandoffAssessmentV1
  }

  private struct AssessmentVerifyOutput: Encodable {
    let schema = "TatwoHandoffAssessmentVerifyCLIOutputV1"
    let accepted: Bool
    let packVerified: Bool
    let packDigestBound: Bool
    let signatureVerified: Bool
    let schemaValid: Bool
    let checksPresent: Bool
    let reportedAtFresh: Bool
    let reporterDeviceID: String?
    let decision: TatwoHandoffCapabilityDecisionV1
  }

  static func run(_ args: [String]) throws {
    guard let subcommand = args.dropFirst().first else {
      throw CLIError.usage(usage)
    }
    switch subcommand {
    case "pack-create":
      try packCreate(args)
    case "pack-verify":
      try packVerify(args)
    case "assess":
      try assess(args)
    case "assessment-verify":
      try assessmentVerify(args)
    default:
      throw CLIError.usage(
        "Unknown cross-device-handoff subcommand: \(subcommand)\n\(usage)")
    }
  }

  private static func packCreate(_ args: [String]) throws {
    let outputPath = try TatwoUltraworkCLI.requiredOption("--out", in: args)
    let goalHash = try normalizedSHA256(
      TatwoUltraworkCLI.requiredOption("--goal-hash", in: args),
      option: "--goal-hash")
    let planHash = try normalizedSHA256(
      TatwoUltraworkCLI.requiredOption("--plan-hash", in: args),
      option: "--plan-hash")
    let logicalJobID = try TatwoUltraworkCLI.requiredOption("--logical-job", in: args)
    let receiverDeviceID = try TatwoUltraworkCLI.requiredOption(
      "--receiver-device", in: args)
    let trust = try localTrust(args)
    let repository = try repositoryState()
    let requiredFiles = try parseFiles(
      TatwoUltraworkCLI.option("--files", in: args))
    let environment = ProcessInfo.processInfo.environment
    let createdAt: Date
    let freshness: TimeInterval
    if TatwoUltraworkCLI.option("--created-at", in: args) != nil
      || TatwoUltraworkCLI.option("--freshness-seconds", in: args) != nil
    {
      guard environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" else {
        throw CLIError.usage(
          "--created-at and --freshness-seconds are test-mode-only options")
      }
      createdAt = try parseDate(
        TatwoUltraworkCLI.option("--created-at", in: args)
          ?? ISO8601DateFormatter().string(from: Date()),
        option: "--created-at")
      freshness = try positiveSeconds(
        TatwoUltraworkCLI.option("--freshness-seconds", in: args) ?? "900",
        option: "--freshness-seconds")
    } else {
      createdAt = Date()
      freshness = 900
    }
    let handoffID = "handoff-\(UUID().uuidString.lowercased())"
    let jobID = "attempt-\(UUID().uuidString.lowercased())"
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let pack = try TatwoHandoffPackV1.make(
      handoffID: handoffID,
      logicalJobID: logicalJobID,
      jobID: jobID,
      dispatchNonce: nonce,
      goal: TatwoHandoffGoalV1(
        goalHash: goalHash,
        description: "Continue cross-device logical job \(logicalJobID)"),
      context: TatwoHandoffContextSummaryV1(
        summary: "Signed minimal handoff context; authoritative details remain hash-bound."),
      plan: TatwoHandoffPlanV1(
        planHash: planHash,
        summary:
          "Verify the handoff package, check whether the receiving device is ready, "
          + "then ask the user before moving primary control."),
      modificationState: TatwoHandoffModificationStateV1(
        branch: repository.branch,
        commit: repository.commit,
        dirty: false,
        treeHash: repository.tree),
      incompleteItems: [
        TatwoHandoffIncompleteItemV1(
          id: "primary-control-transfer-confirmation",
          description:
            "Moving primary control to another device requires user confirmation "
            + "and is not performed by this command.")
      ],
      requiredFiles: requiredFiles,
      sessionRoute: TatwoHandoffSessionRouteV1(
        engine: "tatwo-ultrawork",
        model: "contract-bound",
        route: "native-device-handoff"),
      receiptReferences: [
        TatwoHandoffReceiptReferenceV1(
          receiptID: "goal-contract-\(safePathComponent(logicalJobID))",
          contentHash: goalHash,
          kind: "goal-contract")
      ],
      riskHints: [
        "Primary control has not moved to another device.",
        "The user must confirm before the primary device changes; safety fencing "
          + "must also be active."
      ],
      trust: trust,
      intendedReceiverDeviceID: receiverDeviceID,
      priorOriginDeviceID: trust.localIdentity.deviceID,
      requestedLeaseDomainID: "handoff-\(safePathComponent(logicalJobID))",
      toolchainFingerprint: TatwoUltraworkCLI.option(
        "--toolchain-fingerprint", in: args),
      requiredRunnerIDs: csvOption("--required-runners", in: args),
      requiredLanes: csvOption("--required-lanes", in: args),
      createdAt: createdAt,
      freshnessWindow: freshness)
    try writeJSON(pack, to: URL(fileURLWithPath: outputPath))
    TatwoUltraworkCLI.output(
      PackCreateOutput(
        outputPath: URL(fileURLWithPath: outputPath).standardizedFileURL.path,
        packDigest: pack.packContentHash,
        producerDeviceID: trust.localIdentity.deviceID,
        receiverDeviceID: receiverDeviceID,
        handoffID: handoffID,
        logicalJobID: logicalJobID),
      command: "cross-device-handoff pack-create")
  }

  private static func packVerify(_ args: [String]) throws {
    let input = try TatwoUltraworkCLI.requiredOption("--in", in: args)
    let expectedProducer = try TatwoUltraworkCLI.requiredOption(
      "--expect-producer", in: args)
    let expectedReceiver = try TatwoUltraworkCLI.requiredOption(
      "--expect-receiver", in: args)
    let pack = try read(TatwoHandoffPackV1.self, from: input)
    let result = TatwoHandoffPackV1.verify(
      pack,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: try localTrust(args),
        expectedProducerDeviceID: expectedProducer,
        expectedReceiverDeviceID: expectedReceiver))
    TatwoUltraworkCLI.output(
      PackVerifyOutput(
        accepted: result.valid,
        packDigest: try? pack.canonicalDigest(),
        producerDeviceID: pack.producerDevicePin.deviceID,
        receiverDeviceID: pack.intendedReceiverDeviceID,
        verification: result),
      command: "cross-device-handoff pack-verify",
      ok: result.valid)
    if !result.valid {
      Foundation.exit(3)
    }
  }

  private static func assess(_ args: [String]) throws {
    let input = try TatwoUltraworkCLI.requiredOption("--in", in: args)
    let capabilitiesPath = try TatwoUltraworkCLI.requiredOption(
      "--capabilities", in: args)
    let outputPath =
      TatwoUltraworkCLI.option("--out", in: args) ?? "\(input).assessment.json"
    let pack = try read(TatwoHandoffPackV1.self, from: input)
    let capabilities = try read(
      TatwoHandoffReceiverCapabilitiesV1.self,
      from: capabilitiesPath)
    let trust = try localTrust(args)
    guard trust.localIdentity.deviceID == capabilities.deviceID else {
      throw CLIError.usage(
        "capabilities.deviceID must match the local signing identity")
    }
    let verified = try TatwoVerifiedHandoffPackV1.verifyOrThrow(
      pack: pack,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: trust,
        expectedReceiverDeviceID: capabilities.deviceID))
    let assessment = try TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities
    ).check(
      verifiedPack: verified,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: trust,
        expectedReceiverDeviceID: capabilities.deviceID)
    ).signed(using: trust)
    try writeJSON(assessment, to: URL(fileURLWithPath: outputPath))
    TatwoUltraworkCLI.output(
      AssessmentOutput(
        outputPath: URL(fileURLWithPath: outputPath).standardizedFileURL.path,
        packDigest: verified.packDigest,
        reporterDeviceID: trust.localIdentity.deviceID,
        decision: assessment.decision,
        assessment: assessment),
      command: "cross-device-handoff assess")
  }

  private static func assessmentVerify(_ args: [String]) throws {
    let assessment = try read(
      TatwoHandoffAssessmentV1.self,
      from: TatwoUltraworkCLI.requiredOption("--in", in: args))
    let pack = try read(
      TatwoHandoffPackV1.self,
      from: TatwoUltraworkCLI.requiredOption("--pack", in: args))
    let trust = try localTrust(args)
    let packVerification = TatwoHandoffPackV1.verify(
      pack,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: trust,
        expectedProducerDeviceID: trust.localIdentity.deviceID,
        expectedReceiverDeviceID: pack.intendedReceiverDeviceID))
    let reporter = assessment.reporterSignature?.deviceID
    let binding = assessment.matchesPackBinding(pack)
    let signature = assessment.verifySignature(
      using: trust,
      expectedReporterDeviceID: pack.intendedReceiverDeviceID,
      against: pack)
    let schemaValid = assessment.schema == TatwoHandoffAssessmentV1.schemaName
    let checksPresent = !assessment.checks.isEmpty
    let now = Date()
    let reportedAtAge = now.timeIntervalSince(assessment.reportedAt)
    let reportedAtFresh =
      reportedAtAge >= -TatwoLoopJobChannelTrust.signatureClockSkewSec
      && reportedAtAge
        <= TatwoLoopJobChannelTrust.defaultSignatureMaxAgeSec
          + TatwoLoopJobChannelTrust.signatureClockSkewSec
    let accepted =
      packVerification.valid && binding && signature && schemaValid
      && checksPresent && reportedAtFresh
    TatwoUltraworkCLI.output(
      AssessmentVerifyOutput(
        accepted: accepted,
        packVerified: packVerification.valid,
        packDigestBound: binding,
        signatureVerified: signature,
        schemaValid: schemaValid,
        checksPresent: checksPresent,
        reportedAtFresh: reportedAtFresh,
        reporterDeviceID: reporter,
        decision: assessment.decision),
      command: "cross-device-handoff assessment-verify",
      ok: accepted)
    if !accepted {
      Foundation.exit(3)
    }
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

  private static func parseFiles(
    _ raw: String?
  ) throws -> [TatwoHandoffRequiredFileV1] {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      let path = "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md"
      return [
        TatwoHandoffRequiredFileV1(
          path: path,
          sha256: try headFileSHA256(path: path))
      ]
    }
    return try raw.split(separator: ",").map { entry in
      let text = String(entry)
      guard let separator = text.lastIndex(of: ":") else {
        throw CLIError.usage("--files entries must use path:sha256")
      }
      let path = String(text[..<separator])
      let hash = String(text[text.index(after: separator)...])
      guard !path.isEmpty else {
        throw CLIError.usage("--files entries require a relative path")
      }
      let normalized = try normalizedSHA256(hash, option: "--files")
      let actual = try headFileSHA256(path: path)
      guard normalized == actual else {
        throw CLIError.usage("--files digest does not match local file: \(path)")
      }
      return TatwoHandoffRequiredFileV1(
        path: path,
        sha256: normalized)
    }
  }

  private struct RepositoryState {
    let branch: String
    let commit: String
    let tree: String
  }

  private static func repositoryState() throws -> RepositoryState {
    let dirty = try git(["status", "--porcelain", "--untracked-files=all"])
    guard dirty.isEmpty else {
      throw CLIError.usage(
        "cross-device-handoff pack-create refuses a dirty worktree; archive or commit the work before handoff")
    }
    return RepositoryState(
      branch: try git(["rev-parse", "--abbrev-ref", "HEAD"]),
      commit: try git(["rev-parse", "HEAD"]),
      tree: try git(["rev-parse", "HEAD^{tree}"]))
  }

  private static func git(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? "git read failed"
      throw CLIError.usage("Unable to read repository state: \(detail)")
    }
    return String(
      data: data,
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func headFileSHA256(path: String) throws -> String {
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      throw CLIError.usage("--files paths must be repo-relative")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["show", "HEAD:\(path)"]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CLIError.usage(
        "--files path is not reachable from HEAD: \(path)")
    }
    return TatwoLoopJobChannelTrust.sha256Hex(data)
  }

  private static func normalizedSHA256(_ value: String, option: String) throws -> String {
    let raw = value.hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
    guard raw.count == 64, raw.allSatisfy(\.isHexDigit) else {
      throw CLIError.usage("\(option) must be a 64-character SHA-256 hex digest")
    }
    return raw.lowercased()
  }

  private static func positiveSeconds(_ value: String, option: String) throws -> TimeInterval {
    guard let seconds = TimeInterval(value), seconds > 0,
      seconds <= TatwoHandoffPackV1.maxFreshnessWindowSec
    else {
      throw CLIError.usage("\(option) must be > 0 and <= 86400")
    }
    return seconds
  }

  private static func csvOption(_ option: String, in args: [String]) -> [String]? {
    guard let raw = TatwoUltraworkCLI.option(option, in: args) else { return nil }
    let values = raw.split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    return values.isEmpty ? nil : values
  }

  private static func parseDate(_ value: String, option: String) throws -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else {
      throw CLIError.usage("\(option) must be ISO-8601")
    }
    return date
  }

  private static func safePathComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let normalized = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    let result = String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    return result.isEmpty ? "job" : result
  }

  private static func read<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
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
    Use (cross-device task handoff; not Work OS session/context `handoff pack`):
      tatwo-ultrawork cross-device-handoff pack-create --out <file> --goal-hash <sha> --plan-hash <sha> --logical-job <id> --receiver-device <id> [--files <path:sha,...>]
      tatwo-ultrawork cross-device-handoff pack-verify --in <file> --expect-producer <id> --expect-receiver <id>
      tatwo-ultrawork cross-device-handoff assess --in <file> --capabilities <json-file> [--out <assessment-file>]
      tatwo-ultrawork cross-device-handoff assessment-verify --in <assessment> --pack <file>

    Trust is loaded from the local device-trust identity and durable pin store.
    This CLI intentionally has no lease-transfer subcommand.
    Work OS session/context handoff remains: tatwo-ultrawork handoff pack ...
    """
}

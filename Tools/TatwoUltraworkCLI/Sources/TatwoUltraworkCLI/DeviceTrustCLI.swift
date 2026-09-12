import Foundation
import TatwoUltraworkCore

enum TatwoDeviceTrustCLI {
  private struct VerificationOutput: Encodable {
    let schema = "TatwoDeviceTrustVerificationCLIOutputV1"
    let verified: Bool
    let purpose: String
    let deviceID: String
    let keyID: String
    let keyGeneration: UInt64
    let payloadDigest: String
  }

  private struct RotationOutput: Encodable {
    let schema = "TatwoDeviceTrustRotationCLIOutputV1"
    let identity: TatwoDevicePublicIdentityV1
    let receipt: TatwoDeviceKeyRotationReceiptV1
  }

  private struct RevocationOutput: Encodable {
    let schema = "TatwoDeviceTrustRevocationCLIOutputV1"
    let identity: TatwoDevicePublicIdentityV1
    let receipt: TatwoDeviceKeyRevocationReceiptV1
  }

  private struct ExportIdentityOutput: Encodable {
    let schema = "TatwoDeviceTrustExportIdentityCLIOutputV1"
    let identity: TatwoDevicePublicIdentityV1
    let fingerprint: String
    let publicKeyFingerprint: String
    let outputPath: String
  }

  private struct PinImportOutput: Encodable {
    let schema = "TatwoDeviceTrustPinImportCLIOutputV1"
    let identity: TatwoDevicePublicIdentityV1
    let fingerprint: String
    let publicKeyFingerprint: String
    let storeRoot: String
  }

  private struct ListPinsOutput: Encodable {
    let schema = "TatwoDeviceTrustListPinsCLIOutputV1"
    let storeRoot: String
    let pins: [TatwoDeviceTrustPinListEntryV1]
  }

  private struct IngestRevocationOutput: Encodable {
    let schema = "TatwoDeviceTrustIngestRevocationCLIOutputV1"
    let identity: TatwoDevicePublicIdentityV1
    let receipt: TatwoDeviceKeyRevocationReceiptV1
    let storeRoot: String
  }

  static func run(_ args: [String]) throws {
    guard let subcommand = args.dropFirst().first else {
      throw CLIError.usage(
        "Use: tatwo-ultrawork device-trust init|ensure|assert-local|sign|verify|rotate|verify-rotation|revoke|verify-revocation|export-identity|pin-import|list-pins|ingest-revocation")
    }
    switch subcommand {
    case "init":
      try initializeStore(args)
    case "ensure":
      try ensure(args)
    case "assert-local":
      try assertLocal(args)
    case "sign":
      try sign(args)
    case "verify":
      try verify(args)
    case "rotate":
      try rotate(args)
    case "verify-rotation":
      try verifyRotation(args)
    case "revoke":
      try revoke(args)
    case "verify-revocation":
      try verifyRevocation(args)
    case "export-identity":
      try exportIdentity(args)
    case "pin-import":
      try pinImport(args)
    case "list-pins":
      try listPins(args)
    case "ingest-revocation":
      try ingestRevocation(args)
    default:
      throw CLIError.usage("Unknown device-trust subcommand: \(subcommand)")
    }
  }

  private struct InitOutput: Encodable {
    let schema = "TatwoDeviceTrustInitCLIOutputV1"
    let storeRoot: String
    let storeGeneration: UInt64
    let deviceID: String
  }

  /// Explicit first-time pin-store initialization (anchor + store-meta).
  /// Production remote-runner refuses an uninitialized store.
  private static func initializeStore(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let storeRoot = pinStoreRoot(args)
    let pinStore = try makePinStore(deviceID: deviceID, storeRoot: storeRoot, args: args)
    try pinStore.initializeIfNeeded()
    let generation = try pinStore.currentStoreGeneration()
    TatwoUltraworkCLI.output(
      InitOutput(
        storeRoot: storeRoot.path,
        storeGeneration: generation,
        deviceID: deviceID),
      command: "device-trust init")
  }

  private static func ensure(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let generation = try positiveUInt64(
      TatwoUltraworkCLI.option("--generation", in: args) ?? "1",
      option: "--generation")
    let pinnedAt =
      TatwoUltraworkCLI.option("--pinned-at", in: args) ?? timestamp()
    let identity = try authority().ensureIdentity(
      deviceID: deviceID,
      generation: generation,
      pinnedAt: pinnedAt)
    if let output = TatwoUltraworkCLI.option("--output", in: args) {
      try writeJSON(identity, to: URL(fileURLWithPath: output))
    }
    TatwoUltraworkCLI.output(identity, command: "device-trust ensure")
  }

  private static func assertLocal(_ args: [String]) throws {
    let identity = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--registry", in: args))
    try authority().assertLocalPrivateKey(matches: identity)
    TatwoUltraworkCLI.output(
      VerificationOutput(
        verified: true,
        purpose: "local-private-key-match",
        deviceID: identity.deviceID,
        keyID: identity.keyID,
        keyGeneration: identity.keyGeneration,
        payloadDigest: ""),
      command: "device-trust assert-local")
  }

  private static func sign(_ args: [String]) throws {
    let purpose = try TatwoUltraworkCLI.requiredOption("--purpose", in: args)
    let input = try TatwoUltraworkCLI.requiredOption("--input", in: args)
    let signatureOutput = try TatwoUltraworkCLI.requiredOption(
      "--signature-out",
      in: args)
    let identity = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--registry", in: args))
    let payload = try Data(contentsOf: URL(fileURLWithPath: input))
    let signature = try authority().sign(
      payload: payload,
      purpose: purpose,
      identity: identity,
      signedAt: TatwoUltraworkCLI.option("--signed-at", in: args)
        ?? timestamp())
    try writeJSON(signature, to: URL(fileURLWithPath: signatureOutput))
    TatwoUltraworkCLI.output(signature, command: "device-trust sign")
  }

  private static func verify(_ args: [String]) throws {
    let purpose = try TatwoUltraworkCLI.requiredOption("--purpose", in: args)
    let input = try TatwoUltraworkCLI.requiredOption("--input", in: args)
    let identity = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--registry", in: args))
    let signature = try read(
      TatwoDeviceSignatureV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--signature", in: args))
    let payload = try Data(contentsOf: URL(fileURLWithPath: input))
    try TatwoDeviceTrustAuthority.verify(
      payload: payload,
      purpose: purpose,
      signature: signature,
      pinnedIdentity: identity)
    TatwoUltraworkCLI.output(
      VerificationOutput(
        verified: true,
        purpose: purpose,
        deviceID: identity.deviceID,
        keyID: identity.keyID,
        keyGeneration: identity.keyGeneration,
        payloadDigest: signature.payloadDigest),
      command: "device-trust verify")
  }

  private static func rotate(_ args: [String]) throws {
    let current = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--registry", in: args))
    let result = try authority().rotate(
      identity: current,
      rotatedAt: TatwoUltraworkCLI.option("--rotated-at", in: args)
        ?? timestamp())
    try writeJSON(
      result.identity,
      to: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--identity-out",
          in: args)))
    try writeJSON(
      result.receipt,
      to: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--receipt-out",
          in: args)))
    TatwoUltraworkCLI.output(
      RotationOutput(identity: result.identity, receipt: result.receipt),
      command: "device-trust rotate")
  }

  private static func verifyRotation(_ args: [String]) throws {
    let old = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--old-registry", in: args))
    let receipt = try read(
      TatwoDeviceKeyRotationReceiptV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--receipt", in: args))
    try TatwoDeviceTrustAuthority.verifyRotation(
      receipt,
      oldIdentity: old)
    TatwoUltraworkCLI.output(
      VerificationOutput(
        verified: true,
        purpose: "device-key-rotation",
        deviceID: receipt.deviceID,
        keyID: receipt.newIdentity.keyID,
        keyGeneration: receipt.newIdentity.keyGeneration,
        payloadDigest: receipt.authorization.payloadDigest),
      command: "device-trust verify-rotation")
  }

  private static func revoke(_ args: [String]) throws {
    let target = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption(
        "--target-registry",
        in: args))
    let authorizer = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption(
        "--authorizer-registry",
        in: args))
    let result = try authority().revoke(
      targetIdentity: target,
      authorizedBy: authorizer,
      authorityEpoch: try positiveUInt64(
        try TatwoUltraworkCLI.requiredOption("--authority-epoch", in: args),
        option: "--authority-epoch"),
      reason: try TatwoUltraworkCLI.requiredOption("--reason", in: args),
      revokedAt: TatwoUltraworkCLI.option("--revoked-at", in: args)
        ?? timestamp())
    try writeJSON(
      result.identity,
      to: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--identity-out",
          in: args)))
    try writeJSON(
      result.receipt,
      to: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--receipt-out",
          in: args)))
    TatwoUltraworkCLI.output(
      RevocationOutput(identity: result.identity, receipt: result.receipt),
      command: "device-trust revoke")
  }

  private static func verifyRevocation(_ args: [String]) throws {
    let target = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption(
        "--target-registry",
        in: args))
    let authorizer = try read(
      TatwoDevicePublicIdentityV1.self,
      from: try TatwoUltraworkCLI.requiredOption(
        "--authorizer-registry",
        in: args))
    let receipt = try read(
      TatwoDeviceKeyRevocationReceiptV1.self,
      from: try TatwoUltraworkCLI.requiredOption("--receipt", in: args))
    let epoch = try positiveUInt64(
      try TatwoUltraworkCLI.requiredOption("--authority-epoch", in: args),
      option: "--authority-epoch")
    try TatwoDeviceTrustAuthority.verifyRevocation(
      receipt,
      targetIdentity: target,
      authorizerIdentity: authorizer,
      expectedAuthorityEpoch: epoch)
    TatwoUltraworkCLI.output(
      VerificationOutput(
        verified: true,
        purpose: "device-key-revocation",
        deviceID: target.deviceID,
        keyID: target.keyID,
        keyGeneration: target.keyGeneration,
        payloadDigest: receipt.authorization.payloadDigest),
      command: "device-trust verify-revocation")
  }

  /// Export local public identity JSON + SHA-256 fingerprint of the file bytes.
  private static func exportIdentity(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let generation = try positiveUInt64(
      TatwoUltraworkCLI.option("--generation", in: args) ?? "1",
      option: "--generation")
    let pinnedAt =
      TatwoUltraworkCLI.option("--pinned-at", in: args) ?? timestamp()
    let identity = try authority().ensureIdentity(
      deviceID: deviceID,
      generation: generation,
      pinnedAt: pinnedAt)

    let outputPath: String
    if let explicit = TatwoUltraworkCLI.option("--output", in: args) {
      outputPath = explicit
    } else {
      let root = deviceTrustRoot(args)
      outputPath = root
        .appendingPathComponent(
          TatwoRuntimeLayout.deviceTrustLocalIdentityFileName,
          isDirectory: false)
        .path
    }
    let outputURL = URL(fileURLWithPath: outputPath)
    try writeJSON(identity, to: outputURL)
    let fileData = try Data(contentsOf: outputURL)
    let fingerprint = TatwoDeviceTrustPinStore.sha256Fingerprint(of: fileData)
    let publicKeyFingerprint = try TatwoDeviceTrustPinStore.publicKeyFingerprint(
      of: identity)
    // Also print fingerprint on stderr-style companion line via JSON payload.
    TatwoUltraworkCLI.output(
      ExportIdentityOutput(
        identity: identity,
        fingerprint: fingerprint,
        publicKeyFingerprint: publicKeyFingerprint,
        outputPath: outputURL.path),
      command: "device-trust export-identity")
  }

  /// pin-import <file> --fingerprint <sha256> --device-id <local>
  private static func pinImport(_ args: [String]) throws {
    let file = try positionalFileArgument(in: args, after: "pin-import")
    let fingerprint = try TatwoUltraworkCLI.requiredOption(
      "--fingerprint",
      in: args)
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let storeRoot = pinStoreRoot(args)
    let pinStore = try makePinStore(deviceID: deviceID, storeRoot: storeRoot, args: args)
    let identity = try pinStore.pinImport(
      identityFileURL: URL(fileURLWithPath: file),
      expectedFingerprint: fingerprint)
    let fileData = try Data(contentsOf: URL(fileURLWithPath: file))
    TatwoUltraworkCLI.output(
      PinImportOutput(
        identity: identity,
        fingerprint: TatwoDeviceTrustPinStore.sha256Fingerprint(of: fileData),
        publicKeyFingerprint: try TatwoDeviceTrustPinStore.publicKeyFingerprint(
          of: identity),
        storeRoot: storeRoot.path),
      command: "device-trust pin-import")
  }

  private static func listPins(_ args: [String]) throws {
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let storeRoot = pinStoreRoot(args)
    let pinStore = try makePinStore(deviceID: deviceID, storeRoot: storeRoot, args: args)
    let pins = try pinStore.listPins()
    TatwoUltraworkCLI.output(
      ListPinsOutput(storeRoot: storeRoot.path, pins: pins),
      command: "device-trust list-pins")
  }

  /// ingest-revocation <file> --device-id <local> --authority-epoch N
  private static func ingestRevocation(_ args: [String]) throws {
    let file = try positionalFileArgument(in: args, after: "ingest-revocation")
    let deviceID = try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let epoch = try positiveUInt64(
      try TatwoUltraworkCLI.requiredOption("--authority-epoch", in: args),
      option: "--authority-epoch")
    let storeRoot = pinStoreRoot(args)
    let pinStore = try makePinStore(deviceID: deviceID, storeRoot: storeRoot, args: args)
    let receipt = try read(
      TatwoDeviceKeyRevocationReceiptV1.self,
      from: file)
    let revoked = try pinStore.ingestRevocation(
      receipt,
      expectedAuthorityEpoch: epoch)
    TatwoUltraworkCLI.output(
      IngestRevocationOutput(
        identity: revoked,
        receipt: receipt,
        storeRoot: storeRoot.path),
      command: "device-trust ingest-revocation")
  }

  private static func makePinStore(
    deviceID: String,
    storeRoot: URL,
    args: [String]
  ) throws -> TatwoDeviceTrustPinStore {
    let generation = try positiveUInt64(
      TatwoUltraworkCLI.option("--generation", in: args) ?? "1",
      option: "--generation")
    let pinnedAt =
      TatwoUltraworkCLI.option("--pinned-at", in: args) ?? timestamp()
    let auth = try authority()
    let identity = try auth.ensureIdentity(
      deviceID: deviceID,
      generation: generation,
      pinnedAt: pinnedAt)
    // Always pin self into durable store so revocation authorizer/target can resolve.
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: storeRoot,
      authority: auth,
      localIdentity: identity)
    try pinStore.pin(identity)
    return pinStore
  }

  private static func deviceTrustRoot(_ args: [String]) -> URL {
    if let explicit = TatwoUltraworkCLI.option("--app-support", in: args) {
      return URL(fileURLWithPath: explicit, isDirectory: true)
        .appendingPathComponent(
          TatwoRuntimeLayout.deviceTrustDirectoryName,
          isDirectory: true)
    }
    return TatwoRuntimeLayout.deviceTrustRoot()
  }

  private static func pinStoreRoot(_ args: [String]) -> URL {
    if let explicit = TatwoUltraworkCLI.option("--store-root", in: args) {
      return URL(fileURLWithPath: explicit, isDirectory: true)
    }
    if let appSupport = TatwoUltraworkCLI.option("--app-support", in: args) {
      return URL(fileURLWithPath: appSupport, isDirectory: true)
        .appendingPathComponent(
          TatwoRuntimeLayout.deviceTrustDirectoryName,
          isDirectory: true)
        .appendingPathComponent(
          TatwoRuntimeLayout.deviceTrustPinStoreDirectoryName,
          isDirectory: true)
    }
    return TatwoDeviceTrustPinStore.defaultRoot()
  }

  /// First non-flag token after the subcommand name.
  private static func positionalFileArgument(
    in args: [String],
    after subcommand: String
  ) throws -> String {
    guard let subIndex = args.firstIndex(of: subcommand) else {
      throw CLIError.usage("Missing subcommand \(subcommand)")
    }
    var index = subIndex + 1
    while index < args.count {
      let token = args[index]
      if token.hasPrefix("--") {
        index += 2
        continue
      }
      return token
    }
    throw CLIError.usage(
      "device-trust \(subcommand) requires a file path argument")
  }

  private static func authority() throws -> TatwoDeviceTrustAuthority {
    let environment = ProcessInfo.processInfo.environment
    if environment["TATWO_TEST_MODE"] == "1",
      let root = environment["TATWO_DEVICE_TRUST_TEST_KEY_ROOT"],
      !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return TatwoDeviceTrustAuthority(
        privateKeyStore: try TatwoDeviceTestFilePrivateKeyStore(
          rootURL: URL(fileURLWithPath: root, isDirectory: true),
          testModeAuthorized: true,
          environment: environment))
    }
    let service = try TatwoDeviceKeychainPrivateKeyStore.configuration(
      environment: environment)
    return TatwoDeviceTrustAuthority(
      privateKeyStore: TatwoDeviceKeychainPrivateKeyStore(service: service))
  }

  private static func read<T: Decodable>(
    _ type: T.Type,
    from path: String
  ) throws -> T {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(type, from: data)
  }

  private static func writeJSON<T: Encodable>(
    _ value: T,
    to url: URL
  ) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw CLIError.usage(
          "Refusing to replace a symbolic-link device trust artifact: \(url.path)")
      }
    }
    try manager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
  }

  private static func positiveUInt64(
    _ value: String,
    option: String
  ) throws -> UInt64 {
    guard let result = UInt64(value), result > 0 else {
      throw CLIError.usage("\(option) must be a positive integer")
    }
    return result
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

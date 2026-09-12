import CryptoKit
import Foundation
import TatwoBootstrapCore
import TatwoDeploymentPrimitives
import TatwoModuleContracts
import TatwoUltraworkCore

struct TatwoModularDeployPlanOutputV1: Encodable {
  let schema: String
  let manifestsDirectory: String
  let plan: TatwoBootstrapPlanV1?
  let receipt: TatwoDeploymentReceipt
  let productionMutationAllowed: Bool
}

struct TatwoModularDoctorOutputV1: Encodable {
  let schema: String
  let baseDoctor: DoctorReport
  let moduleReceipt: TatwoDeploymentReceipt
  let moduleSnapshots: [TatwoModuleHealthSnapshotV1]
  let productionMutationAllowed: Bool
}

enum TatwoModularDeploymentCLI {
  static func deploy(_ args: [String]) throws {
    guard let operation = args.dropFirst().first else {
      throw CLIError.usage(
        "Use: tatwo-ultrawork deploy plan|apply|repair --json")
    }
    switch operation {
    case "plan":
      try plan(args)
    case "apply":
      try apply(args)
    case "repair":
      try repair(args)
    default:
      throw CLIError.usage(
        "Use: tatwo-ultrawork deploy plan|apply|repair --json")
    }
  }

  static func module(_ args: [String]) throws {
    guard args.dropFirst().first == "reset" else {
      throw CLIError.usage(
        "Use: tatwo-ultrawork module reset --module <id> --sandbox-root <path> --execute-reset --json")
    }
    let sandboxRoot = try requiredSandboxRoot(args)
    guard args.contains("--execute-reset") else {
      throw CLIError.usage(
        "module reset is fail-closed; pass --execute-reset with an explicit sandbox root")
    }
    let manifests = try loadManifests(args: args, sandboxRoot: sandboxRoot)
    let moduleID = try TatwoModuleIDV1(
      requiredOption("--module", in: args))
    guard let manifest = manifests.first(where: { $0.moduleID == moduleID }) else {
      throw CLIError.usage("Unknown module manifest: \(moduleID.rawValue)")
    }
    let reset = TatwoSandboxModuleResetPort(sandboxRoot: sandboxRoot)
    let core = TatwoBootstrapCore(
      activationPort: RejectingDeploymentPort(),
      resetPort: reset)
    let receipt = core.resetModule(
      TatwoBootstrapResetModuleRequestV1(
        manifest: manifest,
        correlationID: correlationID(args, prefix: "module-reset")))
    outputReceipt(receipt, command: "module reset")
  }

  static func modularDoctor(
    args: [String],
    baseDoctor: DoctorReport
  ) throws -> TatwoModularDoctorOutputV1 {
    let sandboxRoot = option("--sandbox-root", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    let manifests = try loadManifests(args: args, sandboxRoot: sandboxRoot)
    let snapshots = manifests.map(moduleSnapshot)
    let core = TatwoBootstrapCore(
      activationPort: RejectingDeploymentPort(),
      resetPort: RejectingResetPort())
    let receipt = core.doctor(
      TatwoBootstrapDoctorRequestV1(
        manifests: manifests,
        snapshots: snapshots,
        correlationID: correlationID(args, prefix: "module-doctor")))
    return TatwoModularDoctorOutputV1(
      schema: "TatwoModularDoctorOutputV1",
      baseDoctor: baseDoctor,
      moduleReceipt: receipt,
      moduleSnapshots: snapshots,
      productionMutationAllowed: false)
  }

  private static func plan(_ args: [String]) throws {
    let sandboxRoot = option("--sandbox-root", in: args).map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    let manifests = try loadManifests(args: args, sandboxRoot: sandboxRoot)
    let requested = try requestedModuleIDs(args)
    let core = TatwoBootstrapCore(
      activationPort: RejectingDeploymentPort(),
      resetPort: RejectingResetPort())
    let receipt = core.plan(
      TatwoBootstrapPlanRequestV1(
        manifests: manifests,
        requestedModuleIDs: requested,
        correlationID: correlationID(args, prefix: "deploy-plan")))
    let plan = receipt.outcome == .succeeded
      ? try TatwoBootstrapPlanV1(
        manifests: manifests,
        orderedModuleIDs: receipt.orderedModuleIDs)
      : nil
    TatwoUltraworkCLI.output(
      TatwoModularDeployPlanOutputV1(
        schema: "TatwoModularDeployPlanOutputV1",
        manifestsDirectory: manifestsDirectory(args).path,
        plan: plan,
        receipt: receipt,
        productionMutationAllowed: false),
      command: "deploy plan",
      ok: receipt.outcome == .succeeded)
    if receipt.outcome != .succeeded {
      Foundation.exit(3)
    }
  }

  private static func apply(_ args: [String]) throws {
    let sandboxRoot = try requiredSandboxRoot(args)
    guard args.contains("--execute-bundle-only") else {
      throw CLIError.usage(
        "deploy apply is fail-closed; pass --execute-bundle-only with an explicit sandbox root")
    }
    let request: TatwoBootstrapApplyRequestV1 = try decodeRequest(args)
    try validate(request.candidates, sandboxRoot: sandboxRoot)
    let core = realBootstrapCore(
      sandboxRoot: sandboxRoot,
      allowExecutableProbe: args.contains("--allow-executable-health-probe"))
    outputReceipt(core.apply(request), command: "deploy apply")
  }

  private static func repair(_ args: [String]) throws {
    let sandboxRoot = try requiredSandboxRoot(args)
    guard args.contains("--execute-bundle-only") else {
      throw CLIError.usage(
        "deploy repair is fail-closed; pass --execute-bundle-only with an explicit sandbox root")
    }
    let request: TatwoBootstrapRepairRequestV1 = try decodeRequest(args)
    try validate(request.candidates, sandboxRoot: sandboxRoot)
    let core = realBootstrapCore(
      sandboxRoot: sandboxRoot,
      allowExecutableProbe: args.contains("--allow-executable-health-probe"))
    outputReceipt(core.repair(request), command: "deploy repair")
  }

  private static func realBootstrapCore(
    sandboxRoot: URL,
    allowExecutableProbe: Bool
  ) -> TatwoBootstrapCore {
    let service = TatwoBundleActivationService(
      fileSystem: TatwoFoundationBundleFileSystem(),
      verifier: TatwoSHA256BundleVerifier(),
      healthChecker: TatwoSandboxBundleHealthChecker(
        sandboxRoot: sandboxRoot,
        allowExecutableProbe: allowExecutableProbe))
    return TatwoBootstrapCore(
      activationPort: service,
      resetPort: TatwoSandboxModuleResetPort(sandboxRoot: sandboxRoot))
  }

  private static func outputReceipt(
    _ receipt: TatwoDeploymentReceipt,
    command: String
  ) {
    let ok = receipt.outcome == .succeeded
    TatwoUltraworkCLI.output(receipt, command: command, ok: ok)
    if !ok {
      Foundation.exit(3)
    }
  }

  private static func loadManifests(
    args: [String],
    sandboxRoot: URL?
  ) throws -> [TatwoModuleManifestV1] {
    let directory = manifestsDirectory(args)
    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
      throw CLIError.usage("Cannot enumerate manifests directory: \(directory.path)")
    }
    let urls = enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "module.json" }
      .sorted { $0.path < $1.path }
    guard !urls.isEmpty else {
      throw CLIError.usage("No module.json files under \(directory.path)")
    }
    let decoder = JSONDecoder()
    return try urls.map { url in
      let manifest = try decoder.decode(
        TatwoModuleManifestV1.self,
        from: Data(contentsOf: url))
      return try sandboxRoot.map { try expand(manifest, under: $0) } ?? manifest
    }
  }

  private static func expand(
    _ manifest: TatwoModuleManifestV1,
    under sandboxRoot: URL
  ) throws -> TatwoModuleManifestV1 {
    let root = sandboxRoot.standardizedFileURL
    let values = [
      "TATWO_APP_DIR": root.appendingPathComponent("install/apps", isDirectory: true).path,
      "TATWO_BIN_DIR": root.appendingPathComponent("install/bin", isDirectory: true).path,
      "TATWO_MODULE_DIR": root.appendingPathComponent("install/modules", isDirectory: true).path,
      "TATWO_SKILL_DIR": root.appendingPathComponent("install/skills", isDirectory: true).path,
      "TATWO_APP_SUPPORT_DIR": root.appendingPathComponent("app-support", isDirectory: true).path,
      "TATWO_STATE_DIR": root.appendingPathComponent("app-support/state", isDirectory: true).path,
      "TATWO_CACHE_DIR": root.appendingPathComponent("cache", isDirectory: true).path,
    ]
    func location(
      _ descriptor: TatwoModuleLocationDescriptorV1
    ) -> TatwoModuleLocationDescriptorV1 {
      var path = descriptor.path
      for (key, value) in values {
        path = path.replacingOccurrences(of: "${\(key)}", with: value)
      }
      return TatwoModuleLocationDescriptorV1(kind: descriptor.kind, path: path)
    }
    return try TatwoModuleManifestV1(
      moduleID: manifest.moduleID,
      version: manifest.version,
      dependencies: manifest.dependencies,
      locations: TatwoModuleLocationsV1(
        install: location(manifest.locations.install),
        data: location(manifest.locations.data),
        cache: location(manifest.locations.cache)),
      health: manifest.health,
      migration: manifest.migration,
      rollback: manifest.rollback,
      reset: manifest.reset)
  }

  private static func requestedModuleIDs(_ args: [String]) throws -> [TatwoModuleIDV1] {
    let values = options("--module", in: args)
      + (option("--modules", in: args)?
        .split(separator: ",")
        .map(String.init) ?? [])
    return try values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(TatwoModuleIDV1.init)
  }

  private static func manifestsDirectory(_ args: [String]) -> URL {
    if let raw = option("--manifests", in: args) {
      return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }
    return URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true)
      .appendingPathComponent("Modules", isDirectory: true)
      .standardizedFileURL
  }

  private static func requiredSandboxRoot(_ args: [String]) throws -> URL {
    let raw = try requiredOption("--sandbox-root", in: args)
    let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CLIError.usage("sandbox root must already exist: \(root.path)")
    }
    guard root.path != "/", root.path != NSHomeDirectory() else {
      throw CLIError.usage("refusing unsafe sandbox root: \(root.path)")
    }
    return root
  }

  private static func validate(
    _ candidates: [TatwoBootstrapBundleCandidateV1],
    sandboxRoot: URL
  ) throws {
    guard !candidates.isEmpty else {
      throw CLIError.usage("deployment request has no bundle candidates")
    }
    for candidate in candidates {
      let boundary = candidate.stage.boundary
      let boundaryPaths =
        [boundary.installRoot]
        + boundary.stagingRoots
        + boundary.archiveRoots
        + boundary.protectedUserDataRoots
        + boundary.protectedDomainLedgerRoots
      let bundlePaths = [
        candidate.stage.sourceBundle.path,
        candidate.stage.stagedBundle.path,
        candidate.verify.stagedBundle.path,
        candidate.archiveCurrent.currentBundle.path,
        candidate.archiveCurrent.archivedBundle.path,
        candidate.atomicSwap.stagedBundle.path,
        candidate.atomicSwap.activeBundle.path,
        candidate.healthCheck.activeBundle.path,
        candidate.rollbackBundle.archivedBundle.path,
        candidate.rollbackBundle.activeBundle.path,
      ]
      for path in boundaryPaths + bundlePaths {
        guard prospectivePath(path, isInside: sandboxRoot) else {
          throw CLIError.usage(
            "deployment path escapes sandbox root: \(TatwoPrivacyRedactor.redacted(path))")
        }
      }
    }
  }

  fileprivate static func prospectivePath(_ rawPath: String, isInside root: URL) -> Bool {
    let candidate = canonicalProspectiveURL(rawPath)
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    return candidate.path == canonicalRoot
      || candidate.path.hasPrefix(canonicalRoot + "/")
  }

  fileprivate static func canonicalProspectiveURL(_ rawPath: String) -> URL {
    let original = URL(fileURLWithPath: rawPath).standardizedFileURL
    var existing = original
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path),
      existing.path != "/"
    {
      missing.insert(existing.lastPathComponent, at: 0)
      existing.deleteLastPathComponent()
    }
    var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
    for component in missing {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }

  fileprivate static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
    let left = canonicalProspectiveURL(lhs).path
    let right = canonicalProspectiveURL(rhs).path
    return left == right
      || left.hasPrefix(right + "/")
      || right.hasPrefix(left + "/")
  }

  private static func moduleSnapshot(
    _ manifest: TatwoModuleManifestV1
  ) -> TatwoModuleHealthSnapshotV1 {
    let path = manifest.locations.install.path
    let unresolved = path.contains("${")
    let exists = !unresolved && FileManager.default.fileExists(atPath: path)
    let status: TatwoModuleHealthStatusV1
    let detail: String
    switch manifest.health.kind {
    case .none:
      status = exists ? .healthy : .unknown
      detail = exists ? "Install path exists; no active probe required" : "Install path missing"
    case .pathExists:
      status = exists ? .healthy : .unhealthy
      detail = exists ? "Install path exists" : "Install path missing"
    case .executableProbe:
      let executable = exists && executableURL(for: URL(fileURLWithPath: path)) != nil
      status = executable ? .unknown : .unhealthy
      detail = executable
        ? "Executable exists; live execution is not performed by read-only doctor"
        : "Executable path missing"
    case .customAdapter:
      status = .unknown
      detail = exists
        ? "Install path exists; custom health adapter receipt is required"
        : "Install path missing; custom health adapter receipt is required"
    }
    return TatwoModuleHealthSnapshotV1(
      moduleID: manifest.moduleID,
      version: manifest.version,
      status: status,
      observedAt: Date(),
      detail: detail)
  }

  fileprivate static func executableURL(for installURL: URL) -> URL? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: installURL.path,
      isDirectory: &isDirectory)
    else {
      return nil
    }
    if !isDirectory.boolValue {
      return FileManager.default.isExecutableFile(atPath: installURL.path)
        ? installURL
        : nil
    }
    if installURL.pathExtension == "app" {
      let infoURL = installURL.appendingPathComponent("Contents/Info.plist")
      if
        let data = try? Data(contentsOf: infoURL),
        let info = try? PropertyListSerialization.propertyList(
          from: data,
          options: [],
          format: nil) as? [String: Any],
        let executable = info["CFBundleExecutable"] as? String
      {
        let url = installURL
          .appendingPathComponent("Contents/MacOS")
          .appendingPathComponent(executable)
        if FileManager.default.isExecutableFile(atPath: url.path) {
          return url
        }
      }
    }
    return nil
  }

  private static func decodeRequest<T: Decodable>(_ args: [String]) throws -> T {
    let file = try requiredOption("--request", in: args)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
  }

  private static func correlationID(_ args: [String], prefix: String) -> String {
    option("--correlation", in: args)
      ?? "\(prefix)-\(Int(Date().timeIntervalSince1970))"
  }

  private static func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
      return nil
    }
    return args[index + 1]
  }

  private static func options(_ name: String, in args: [String]) -> [String] {
    args.indices.compactMap { index in
      guard args[index] == name, args.indices.contains(index + 1) else { return nil }
      return args[index + 1]
    }
  }

  private static func requiredOption(_ name: String, in args: [String]) throws -> String {
    guard let value = option(name, in: args), !value.isEmpty else {
      throw CLIError.usage("Missing required option: \(name)")
    }
    return value
  }
}

private final class RejectingDeploymentPort: TatwoBootstrapDeploymentPort {
  private func rejected() throws -> Never {
    throw CLIError.usage("deployment effect port is disabled for this command")
  }

  func stage(_ request: TatwoBundleStageRequestV1) throws -> TatwoBundleOperationReceiptV1 {
    try rejected()
  }

  func verify(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleOperationReceiptV1 {
    try rejected()
  }

  func archiveCurrent(
    _ request: TatwoBundleArchiveCurrentRequestV1
  ) throws -> TatwoBundleOperationReceiptV1 {
    try rejected()
  }

  func atomicSwap(
    _ request: TatwoBundleAtomicSwapRequestV1
  ) throws -> TatwoBundleOperationReceiptV1 {
    try rejected()
  }

  func healthCheck(
    _ request: TatwoBundleHealthCheckRequestV1
  ) throws -> TatwoBundleOperationReceiptV1 {
    try rejected()
  }

  func rollbackBundle(
    _ request: TatwoBundleRollbackRequestV1
  ) throws -> TatwoBundleOperationReceiptV1 {
    try rejected()
  }
}

private final class RejectingResetPort: TatwoModuleResetPort {
  func reset(
    _ request: TatwoModuleResetEffectRequestV1
  ) throws -> TatwoModuleResetEffectReceiptV1 {
    throw CLIError.usage("module reset effect port is disabled for this command")
  }
}

private final class TatwoSandboxModuleResetPort: TatwoModuleResetPort {
  private let sandboxRoot: URL

  init(sandboxRoot: URL) {
    self.sandboxRoot = sandboxRoot
  }

  func reset(
    _ request: TatwoModuleResetEffectRequestV1
  ) throws -> TatwoModuleResetEffectReceiptV1 {
    let cache = URL(fileURLWithPath: request.cacheLocation.path, isDirectory: true)
      .standardizedFileURL
    guard TatwoModularDeploymentCLI.prospectivePath(cache.path, isInside: sandboxRoot) else {
      throw CLIError.usage("reset cache path escapes sandbox root")
    }
    for protectedLocation in [request.installLocation, request.dataLocation] {
      guard TatwoModularDeploymentCLI.prospectivePath(
        protectedLocation.path,
        isInside: sandboxRoot)
      else {
        throw CLIError.usage("reset protected path escapes sandbox root")
      }
      guard !TatwoModularDeploymentCLI.pathsOverlap(
        cache.path,
        protectedLocation.path)
      else {
        throw CLIError.usage(
          "reset cache overlaps protected \(protectedLocation.kind.rawValue) path")
      }
    }

    guard request.cacheLocation.kind == .cache,
          request.installLocation.kind == .install,
          request.dataLocation.kind == .userData
    else {
      throw CLIError.usage("reset cache overlaps install path")
    }

    let archiveRoot = sandboxRoot
      .appendingPathComponent(".reset-archive", isDirectory: true)
      .appendingPathComponent(
        "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
        isDirectory: true)
      .appendingPathComponent(request.moduleID.rawValue, isDirectory: true)
    var archived: [TatwoResettableArtifactV1] = []
    let orderedArtifacts = request.artifacts.sorted { lhs, rhs in
      func rank(_ artifact: TatwoResettableArtifactV1) -> Int {
        artifact == .cache ? 1 : 0
      }
      return rank(lhs) < rank(rhs)
    }
    for artifact in orderedArtifacts {
      let source: URL
      switch artifact {
      case .cache:
        source = cache
      case .stagedBundle:
        source = cache.appendingPathComponent("staged-bundle", isDirectory: true)
      case .generatedState:
        source = cache.appendingPathComponent("generated-state", isDirectory: true)
      }
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      try FileManager.default.createDirectory(
        at: archiveRoot,
        withIntermediateDirectories: true)
      let destination = archiveRoot.appendingPathComponent(artifact.rawValue)
      if FileManager.default.fileExists(atPath: destination.path) {
        throw CLIError.usage("reset archive already exists: \(destination.path)")
      }
      try FileManager.default.moveItem(at: source, to: destination)
      archived.append(artifact)
    }
    try FileManager.default.createDirectory(
      at: cache,
      withIntermediateDirectories: true)
    return TatwoModuleResetEffectReceiptV1(
      moduleID: request.moduleID,
      resetArtifacts: archived,
      detail: archived.isEmpty
        ? "No resettable sandbox artifacts were present; user data and domain ledger untouched"
        : "Archived resettable sandbox artifacts: \(archived.map(\.rawValue).joined(separator: ",")); user data and domain ledger untouched")
  }
}

private final class TatwoSHA256BundleVerifier: TatwoBundleVerifierPort {
  func verifyBundle(
    _ request: TatwoBundleVerifyRequestV1
  ) throws -> TatwoBundleVerificationResultV1 {
    let rawDigest = try digest(URL(fileURLWithPath: request.stagedBundle.path))
    let observed = request.expectedArtifactDigest.hasPrefix("sha256:")
      ? "sha256:\(rawDigest)"
      : rawDigest
    return TatwoBundleVerificationResultV1(
      isValid: observed == request.expectedArtifactDigest,
      observedDigest: observed,
      detail: observed == request.expectedArtifactDigest
        ? "SHA-256 artifact digest verified"
        : "SHA-256 artifact digest mismatch")
  }

  private func digest(_ url: URL) throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: url.path,
      isDirectory: &isDirectory)
    else {
      throw CLIError.usage("staged artifact missing: \(url.path)")
    }
    var hasher = SHA256()
    if !isDirectory.boolValue {
      hasher.update(data: try Data(contentsOf: url))
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
      throw CLIError.usage("cannot enumerate staged artifact: \(url.path)")
    }
    let files = enumerator.compactMap { $0 as? URL }
      .filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      }
      .sorted { $0.path < $1.path }
    for file in files {
      let relative = file.path.replacingOccurrences(of: url.path + "/", with: "")
      hasher.update(data: Data(relative.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: try Data(contentsOf: file))
      hasher.update(data: Data([0]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private final class TatwoSandboxBundleHealthChecker: TatwoBundleHealthCheckPort {
  private let sandboxRoot: URL
  private let allowExecutableProbe: Bool

  init(sandboxRoot: URL, allowExecutableProbe: Bool) {
    self.sandboxRoot = sandboxRoot
    self.allowExecutableProbe = allowExecutableProbe
  }

  func healthCheckBundle(
    _ request: TatwoBundleHealthCheckRequestV1
  ) throws -> TatwoBundleHealthCheckResultV1 {
    guard TatwoModularDeploymentCLI.prospectivePath(
      request.activeBundle.path,
      isInside: sandboxRoot)
    else {
      return TatwoBundleHealthCheckResultV1(
        isHealthy: false,
        detail: "Active bundle escaped sandbox root")
    }
    let active = URL(fileURLWithPath: request.activeBundle.path)
    switch request.policy.kind {
    case .none:
      return TatwoBundleHealthCheckResultV1(
        isHealthy: FileManager.default.fileExists(atPath: active.path),
        detail: "No active probe configured; path existence checked")
    case .pathExists:
      let exists = FileManager.default.fileExists(atPath: active.path)
      return TatwoBundleHealthCheckResultV1(
        isHealthy: exists,
        detail: exists ? "Active path exists" : "Active path is missing")
    case .customAdapter:
      return TatwoBundleHealthCheckResultV1(
        isHealthy: false,
        detail: "Custom health adapter receipt is required")
    case .executableProbe:
      guard allowExecutableProbe else {
        return TatwoBundleHealthCheckResultV1(
          isHealthy: false,
          detail: "Executable health probe requires --allow-executable-health-probe")
      }
      guard let executable = TatwoModularDeploymentCLI.executableURL(for: active) else {
        return TatwoBundleHealthCheckResultV1(
          isHealthy: false,
          detail: "No executable found in active bundle")
      }
      return runProbe(
        executable: executable,
        timeout: TimeInterval(request.policy.timeoutSeconds))
    }
  }

  private func runProbe(
    executable: URL,
    timeout: TimeInterval
  ) -> TatwoBundleHealthCheckResultV1 {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      let deadline = Date().addingTimeInterval(max(timeout, 1))
      while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning {
        process.terminate()
        return TatwoBundleHealthCheckResultV1(
          isHealthy: false,
          detail: "Executable health probe timed out")
      }
      return TatwoBundleHealthCheckResultV1(
        isHealthy: process.terminationStatus == 0,
        detail: process.terminationStatus == 0
          ? "Executable --version probe passed"
          : "Executable --version probe failed with exit \(process.terminationStatus)")
    } catch {
      return TatwoBundleHealthCheckResultV1(
        isHealthy: false,
        detail: "Executable health probe failed to start")
    }
  }
}

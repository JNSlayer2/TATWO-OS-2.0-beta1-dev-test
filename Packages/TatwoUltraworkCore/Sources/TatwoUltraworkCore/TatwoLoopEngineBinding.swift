import Foundation
#if os(macOS)
import Darwin
#endif

/// Brand-free engine binding for remote tatwo-loop execution.
/// Concrete CLI / model bindings are out of scope for this round.
///
/// Production callers that already hold a `TatwoBoundWorkPath` must pass it via
/// `run(task:boundWorkPath:caps:shouldCancel:)` so the engine never re-resolves
/// workPath by pathname between sandbox gate and launch.
public protocol TatwoLoopEngineBinding: Sendable {
  func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1
}

/// Exact target-local Skill runtime projection committed by readiness.
///
/// The binding carries the canonical active revision set rather than only a
/// digest so the agent launcher can independently re-read every runtime tree
/// before exposing it inside the isolated HOME.
public struct TatwoActiveSkillLaunchBindingV1: Sendable, Equatable {
  public let expectedActiveSkillSetDigest: String
  public let activeSkillRevisions: [TatwoActiveSkillRevisionV1]
  public let runtimeRootURL: URL

  public init(
    expectedActiveSkillSetDigest: String,
    activeSkillRevisions: [TatwoActiveSkillRevisionV1],
    runtimeRootURL: URL
  ) {
    self.expectedActiveSkillSetDigest = expectedActiveSkillSetDigest
    self.activeSkillRevisions = activeSkillRevisions
    self.runtimeRootURL = runtimeRootURL.standardizedFileURL
  }

  /// Re-read the exact runtime set and return its canonical Skill-set digest.
  public func verifiedRuntimeDigest() throws -> String {
    let canonical = try TatwoActiveSkillSetDigestV1.canonicalDigest(activeSkillRevisions)
    guard canonical == expectedActiveSkillSetDigest else {
      throw TatwoLoopJobStateError.invalidPayload(
        "active Skill revision set does not match readiness digest")
    }

    let declaredRepositories = Set(activeSkillRevisions.map(\.repository))
    let runtimeChildren = try FileManager.default.contentsOfDirectory(
      at: runtimeRootURL,
      includingPropertiesForKeys: [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ],
      options: [])
    var runtimeRepositories = Set<String>()
    for child in runtimeChildren {
      let values = try child.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw TatwoLoopJobStateError.invalidPayload(
          "active Skill runtime contains a symbolic-link repository")
      }
      if values.isDirectory != true {
        guard child.lastPathComponent == ".set-activation.lock",
          values.isRegularFile == true
        else {
          throw TatwoLoopJobStateError.invalidPayload(
            "active Skill runtime contains an unsafe non-directory entry")
        }
        continue
      }
      let skillManifest = child.appendingPathComponent("SKILL.md", isDirectory: false)
      if FileManager.default.fileExists(atPath: skillManifest.path) {
        runtimeRepositories.insert(child.lastPathComponent)
      }
    }
    guard runtimeRepositories == declaredRepositories else {
      throw TatwoLoopJobStateError.invalidPayload(
        "active Skill runtime repository set does not match readiness")
    }

    for revision in activeSkillRevisions {
      let readback = try TatwoSkilletBundleTransport.readRuntimeRepository(
        runtimeRoot: runtimeRootURL,
        repositoryID: revision.repository)
      guard readback.state == .present,
        readback.contentDigest == revision.contentDigest
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "active Skill runtime digest mismatch for \(revision.repository)")
      }
    }
    return canonical
  }
}

extension TatwoLoopEngineBinding {
  /// Convenience for tests / non-production paths: bind pathname once, then run.
  /// Production runner must not use this after an earlier bind — pass the held credential.
  public func run(
    task: TatwoLoopEngineTaskV1,
    workPath: URL,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    let bound = try TatwoBoundWorkPath.bind(workPath)
    return try run(
      task: task,
      boundWorkPath: bound,
      caps: caps,
      shouldCancel: shouldCancel)
  }
}

public struct TatwoLoopEngineTaskV1: Sendable, Equatable {
  public let contractID: String
  public let goalID: String
  public let identity: IdentityKind
  public let mode: TatwoLoopModeV1
  public let taskDescription: String
  public let agent: TatwoRemoteAgentKindV1?
  public let exactModelRouteID: String?
  public let activeSkillBinding: TatwoActiveSkillLaunchBindingV1?

  public init(
    contractID: String,
    goalID: String,
    identity: IdentityKind,
    mode: TatwoLoopModeV1,
    taskDescription: String,
    agent: TatwoRemoteAgentKindV1? = nil,
    exactModelRouteID: String? = nil,
    activeSkillBinding: TatwoActiveSkillLaunchBindingV1? = nil
  ) {
    self.contractID = contractID
    self.goalID = goalID
    self.identity = identity
    self.mode = mode
    self.taskDescription = taskDescription
    self.agent = agent
    self.exactModelRouteID = exactModelRouteID
    self.activeSkillBinding = activeSkillBinding
  }

  public init(
    payload: TatwoLoopPayloadV1,
    activeSkillBinding: TatwoActiveSkillLaunchBindingV1? = nil
  ) {
    self.init(
      contractID: payload.contractID,
      goalID: payload.goalID,
      identity: payload.identity,
      mode: payload.mode,
      taskDescription: payload.taskDescription,
      agent: payload.agent,
      exactModelRouteID: payload.exactModelRouteID,
      activeSkillBinding: activeSkillBinding)
  }
}

public enum TatwoExactModelOutcomeV1: String, Codable, Sendable, Equatable {
  case verifiedExact = "VERIFIED_EXACT"
  case failClosedMismatch = "FAIL_CLOSED_MISMATCH"
  case attestationMissing = "ATTESTATION_MISSING"
}

/// Provider-observed model identity for one completed agent execution.
///
/// Request-side routing is not enough: a vendor CLI may accept an exact model
/// argument and still switch the substantive assistant turn to another model.
/// This receipt therefore records both the requested route and provider output.
public struct TatwoModelExecutionAttestationV1: Codable, Sendable, Equatable {
  public let schema: String
  public let requestedCanonicalModelID: String
  public let requestedVendorModelID: String
  public let observedAssistantModelIDs: [String]
  public let modelUsageKeys: [String]
  public let fallbackEventCount: Int
  public let outcome: TatwoExactModelOutcomeV1

  public init(
    schema: String = "TatwoModelExecutionAttestationV1",
    requestedCanonicalModelID: String,
    requestedVendorModelID: String,
    observedAssistantModelIDs: [String],
    modelUsageKeys: [String],
    fallbackEventCount: Int,
    outcome: TatwoExactModelOutcomeV1
  ) {
    self.schema = schema
    self.requestedCanonicalModelID = requestedCanonicalModelID
    self.requestedVendorModelID = requestedVendorModelID
    self.observedAssistantModelIDs = observedAssistantModelIDs
    self.modelUsageKeys = modelUsageKeys
    self.fallbackEventCount = max(0, fallbackEventCount)
    self.outcome = outcome
  }

  public var isVerifiedExact: Bool {
    schema == "TatwoModelExecutionAttestationV1"
      && outcome == .verifiedExact
      && fallbackEventCount == 0
      && !observedAssistantModelIDs.isEmpty
      && observedAssistantModelIDs.allSatisfy { $0 == requestedVendorModelID }
  }
}

public struct TatwoLoopEngineResultV1: Sendable, Equatable {
  public let exitCode: Int32
  public let outputData: Data
  public let outputTruncated: Bool
  public let timedOut: Bool
  public let cancelled: Bool
  public let failureCode: String?
  public let message: String?
  public let expectedActiveSkillSetDigest: String?
  public let actualLoadedSkillSetDigest: String?
  public let modelExecutionAttestation: TatwoModelExecutionAttestationV1?

  public init(
    exitCode: Int32,
    outputData: Data,
    outputTruncated: Bool = false,
    timedOut: Bool = false,
    cancelled: Bool = false,
    failureCode: String? = nil,
    message: String? = nil,
    expectedActiveSkillSetDigest: String? = nil,
    actualLoadedSkillSetDigest: String? = nil,
    modelExecutionAttestation: TatwoModelExecutionAttestationV1? = nil
  ) {
    self.exitCode = exitCode
    self.outputData = outputData
    self.outputTruncated = outputTruncated
    self.timedOut = timedOut
    self.cancelled = cancelled
    self.failureCode = failureCode
    self.expectedActiveSkillSetDigest = expectedActiveSkillSetDigest
    self.actualLoadedSkillSetDigest = actualLoadedSkillSetDigest
    self.modelExecutionAttestation = modelExecutionAttestation
    self.message = message.map {
      String(TatwoPrivacyRedactor.redacted($0).prefix(512))
    }
  }
}

/// Sandbox unlock policy for tatwo-loop payloads.
/// Requires both `TATWO_ULTRAWORK_TATWO_LOOP_ENABLE=sandbox` and a work path
/// contained in the injected loop sandbox root; either missing keeps execution disabled.
///
/// Loop sandbox root uses `TATWO_ULTRAWORK_LOOP_SANDBOX_ROOT` (not the shipping MCP
/// key `TATWO_ULTRAWORK_SANDBOX_ROOT`). If only the legacy key is set, resolve fails
/// closed with an explicit error — no silent fallback.
public enum TatwoLoopSandboxUnlock: Sendable {
  public static let enableEnvKey = "TATWO_ULTRAWORK_TATWO_LOOP_ENABLE"
  public static let sandboxRootEnvKey = "TATWO_ULTRAWORK_LOOP_SANDBOX_ROOT"
  /// Shipping MCP sandbox key — not valid for remote loops (collision guard).
  public static let legacyMCPSandboxRootEnvKey = "TATWO_ULTRAWORK_SANDBOX_ROOT"
  public static let enableSandboxValue = "sandbox"

  public static func isEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment[enableEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() == enableSandboxValue
  }

  public static func sandboxRootURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    injected: URL? = nil
  ) throws -> URL? {
    if let injected {
      return injected.standardizedFileURL.resolvingSymlinksInPath()
    }
    let newRaw = environment[sandboxRootEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let legacyRaw = environment[legacyMCPSandboxRootEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let hasNew = !(newRaw ?? "").isEmpty
    let hasLegacy = !(legacyRaw ?? "").isEmpty
    if hasLegacy && !hasNew {
      throw TatwoLoopJobStateError.invalidPayload(
        "remote loops require \(sandboxRootEnvKey); \(legacyMCPSandboxRootEnvKey) alone is forbidden (no silent fallback; MCP still uses the legacy key)")
    }
    guard let raw = newRaw, !raw.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: raw, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
  }

  /// True when `workPath` resolves inside `sandboxRoot` after symlink resolution.
  /// Uses path-component boundary checks (not bare `hasPrefix`) so `/sandbox-evil`
  /// cannot match parent `/sandbox`.
  public static func isWorkPathInsideSandbox(
    workPath: URL,
    sandboxRoot: URL?
  ) -> Bool {
    guard let sandboxRoot else { return false }
    let child = workPath.standardizedFileURL.resolvingSymlinksInPath()
    let parent = sandboxRoot.standardizedFileURL.resolvingSymlinksInPath()
    return isResolvedPath(child, inside: parent)
  }

  public static func allowsExecution(
    workPath: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    sandboxRoot: URL? = nil
  ) throws -> Bool {
    guard isEnabled(environment: environment) else { return false }
    let root = try sandboxRootURL(environment: environment, injected: sandboxRoot)
    return isWorkPathInsideSandbox(workPath: workPath, sandboxRoot: root)
  }

  /// Component-boundary containment after both sides are absolute paths.
  public static func isResolvedPath(_ child: URL, inside parent: URL) -> Bool {
    // realpath unifies macOS /var vs /private/var (and other firmlink aliases).
    let childPath = TatwoPathCanonical.filePath(child.path)
    let parentPath = TatwoPathCanonical.filePath(parent.path)
    if childPath == parentPath { return true }
    // Split on "/" so `/sandbox-evil` does not match parent `/sandbox`.
    let parentParts = parentPath.split(separator: "/", omittingEmptySubsequences: true)
    let childParts = childPath.split(separator: "/", omittingEmptySubsequences: true)
    guard childParts.count >= parentParts.count else { return false }
    return childParts.starts(with: parentParts)
  }
}

/// Path string canonicalization for identity comparisons (macOS firmlinks).
enum TatwoPathCanonical {
  /// Prefer `realpath` so `/var/...` and `/private/var/...` compare equal.
  static func filePath(_ path: String) -> String {
    #if os(macOS)
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let ok = path.withCString { cPath in
      realpath(cPath, &buf) != nil
    }
    if ok {
      return String(cString: buf)
    }
    #endif
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  static func urlsEqual(_ a: URL, _ b: URL) -> Bool {
    filePath(a.path) == filePath(b.path)
  }
}

/// Runs a configurable argv template as the tatwo-loop engine.
///
/// Placeholders `{workPath}` / `{taskDescription}` expand to **independent argv
/// elements only** — never into a shell string. Do not put placeholders inside
/// `sh -c` scripts; if a shell is required, pass values via env vars or argv and
/// reference them from a fixed script with no string interpolation of untrusted input.
public struct ProcessEngineBinding: TatwoLoopEngineBinding {
  public let executablePath: String
  public let argumentTemplate: [String]

  /// Default sandbox probe used by remote-loop e2e: `ls <workPath>` via argv
  /// (no shell). Placeholders expand as discrete Process.arguments entries.
  public static let sandboxProbe = ProcessEngineBinding(
    executablePath: "/bin/ls",
    argumentTemplate: ["{workPath}"])

  public init(
    executablePath: String,
    argumentTemplate: [String]
  ) {
    self.executablePath = executablePath
    self.argumentTemplate = argumentTemplate
  }

  public func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    try caps.validate()
    let localCaps = caps.clampedForLocalExecution()
    let bound = boundWorkPath
    // Expand placeholders into argv slots only — never assemble a shell command line.
    // Prefer live F_GETPATH of held fd over stale bind-time pathname.
    let workPathForArgv = (try? bound.currentPathString()) ?? bound.path.path
    let arguments = argumentTemplate.map { token -> String in
      switch token {
      case "{workPath}":
        return workPathForArgv
      case "{taskDescription}":
        return task.taskDescription
      default:
        // Reject tokens that embed placeholders inside larger strings (injection surface).
        if token.contains("{workPath}") || token.contains("{taskDescription}") {
          return token
            .replacingOccurrences(of: "{workPath}", with: "\u{0}")
            .replacingOccurrences(of: "{taskDescription}", with: "\u{0}")
        }
        return token
      }
    }
    if arguments.contains(where: { $0.contains("\u{0}") }) {
      return TatwoLoopEngineResultV1(
        exitCode: -1,
        outputData: Data(),
        failureCode: "invalid_argument_template",
        message: "placeholders must be whole argv elements, not shell-string fragments")
    }

    return try Self.runProcess(
      executablePath: executablePath,
      arguments: arguments,
      boundWorkPath: bound,
      caps: localCaps,
      shouldCancel: shouldCancel)
  }

  /// Shared process runner: posix_spawn with pre-exec process group + dir-fd chdir,
  /// recursive descendant kill, residual fail-closed.
  ///
  /// - Parameter standardInputFileDescriptor: optional already-open read fd for stdin
  ///   (preferred; no pathname re-open). Caller retains ownership; runner dups at spawn.
  /// - Parameter standardInputURL: legacy pathname stdin open (tests only; prefer fd).
  /// - Parameter environment: explicit process environment. When nil, uses fully
  ///   explicit minimal env (never host PATH/SHELL/TMPDIR inheritance).
  /// - Parameter boundWorkPath: directory bound by open fd; launch chdirs via that fd
  ///   (no pathname re-resolution at spawn).
  /// - Parameter postKillWaitSec: bounded wait after kill for process exit (default 5s).
  /// - Parameter testHookAfterAssertBeforeSpawn: test-only seam between final
  ///   work-path recheck and `posix_spawn` (pathname rebind race coverage).
  public static func runProcess(
    executablePath: String,
    arguments: [String],
    currentDirectory: URL? = nil,
    boundWorkPath: TatwoBoundWorkPath? = nil,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool,
    standardInputFileDescriptor: Int32? = nil,
    standardInputURL: URL? = nil,
    environment: [String: String]? = nil,
    postKillWaitSec: TimeInterval = 5,
    testHookAfterAssertBeforeSpawn: (@Sendable () -> Void)? = nil
  ) throws -> TatwoLoopEngineResultV1 {
    let bound: TatwoBoundWorkPath?
    if let boundWorkPath {
      bound = boundWorkPath
    } else if let currentDirectory {
      bound = try TatwoBoundWorkPath.bind(currentDirectory)
    } else {
      bound = nil
    }

    if let bound {
      do {
        try bound.assertUnchanged()
      } catch {
        return TatwoLoopEngineResultV1(
          exitCode: -1,
          outputData: Data(),
          failureCode: "work_path_race",
          message: error.localizedDescription)
      }
    }

    let env = environment
      ?? TatwoAgentLaunchEnvironment.explicitMinimal(executablePath: executablePath)

    #if os(macOS)
    return try runViaPosixSpawn(
      executablePath: executablePath,
      arguments: arguments,
      boundWorkPath: bound,
      environment: env,
      caps: caps,
      shouldCancel: shouldCancel,
      standardInputFileDescriptor: standardInputFileDescriptor,
      standardInputURL: standardInputURL,
      postKillWaitSec: postKillWaitSec,
      testHookAfterAssertBeforeSpawn: testHookAfterAssertBeforeSpawn)
    #else
    return TatwoLoopEngineResultV1(
      exitCode: -1,
      outputData: Data(),
      failureCode: "launch_failed",
      message: "posix_spawn runner requires macOS")
    #endif
  }

  #if os(macOS)
  private static func runViaPosixSpawn(
    executablePath: String,
    arguments: [String],
    boundWorkPath: TatwoBoundWorkPath?,
    environment: [String: String],
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool,
    standardInputFileDescriptor: Int32?,
    standardInputURL: URL?,
    postKillWaitSec: TimeInterval,
    testHookAfterAssertBeforeSpawn: (@Sendable () -> Void)?
  ) throws -> TatwoLoopEngineResultV1 {
    var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
    var attr = posix_spawnattr_t(bitPattern: 0)
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      return failLaunch("posix_spawn_file_actions_init failed")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    guard posix_spawnattr_init(&attr) == 0 else {
      return failLaunch("posix_spawnattr_init failed")
    }
    defer { posix_spawnattr_destroy(&attr) }

    // Process group BEFORE exec (new group = child pid).
    guard posix_spawnattr_setpgroup(&attr, 0) == 0,
      posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)) == 0
    else {
      return failLaunch("posix_spawnattr_setpgroup failed")
    }

    // Bind cwd via held directory fd — never re-resolve pathname at spawn.
    if let boundWorkPath {
      let fd = boundWorkPath.directoryFileDescriptor
      // Deployment target is < macOS 26; use historical _np (same semantics as
      // posix_spawn_file_actions_addfchdir on newer SDKs).
      let fchdirRC = posix_spawn_file_actions_addfchdir_np(&fileActions, fd)
      guard fchdirRC == 0 else {
        return failLaunch("posix_spawn fchdir(fd) failed rc=\(fchdirRC)")
      }
    }

    // stdin: preferred held fd (no pathname re-open), else legacy URL, else /dev/null.
    if let standardInputFileDescriptor, standardInputFileDescriptor >= 0 {
      let rc = posix_spawn_file_actions_adddup2(
        &fileActions, standardInputFileDescriptor, STDIN_FILENO)
      guard rc == 0 else {
        return failLaunch("failed to dup2 stdin fd")
      }
    } else if let standardInputURL {
      // Legacy pathname open — production agent engine must pass a held fd instead.
      let path = standardInputURL.path
      let rc = path.withCString { cPath in
        posix_spawn_file_actions_addopen(
          &fileActions, STDIN_FILENO, cPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW, 0)
      }
      guard rc == 0 else {
        return failLaunch("failed to open stdin file")
      }
    } else {
      let rc = posix_spawn_file_actions_addopen(
        &fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
      guard rc == 0 else {
        return failLaunch("failed to open /dev/null for stdin")
      }
    }

    var stdoutPipe: [Int32] = [0, 0]
    guard pipe(&stdoutPipe) == 0 else {
      return failLaunch("pipe failed")
    }
    let readFD = stdoutPipe[0]
    let writeFD = stdoutPipe[1]
    _ = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
    _ = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)
    _ = posix_spawn_file_actions_addclose(&fileActions, readFD)
    _ = posix_spawn_file_actions_addclose(&fileActions, writeFD)

    // argv
    var argvCStrings: [UnsafeMutablePointer<CChar>?] = []
    argvCStrings.reserveCapacity(arguments.count + 2)
    argvCStrings.append(strdup(executablePath))
    for arg in arguments {
      argvCStrings.append(strdup(arg))
    }
    argvCStrings.append(nil)
    defer {
      for ptr in argvCStrings where ptr != nil {
        free(ptr)
      }
    }

    // envp — fully explicit
    var envCStrings: [UnsafeMutablePointer<CChar>?] = []
    envCStrings.reserveCapacity(environment.count + 1)
    for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
      envCStrings.append(strdup("\(key)=\(value)"))
    }
    envCStrings.append(nil)
    defer {
      for ptr in envCStrings where ptr != nil {
        free(ptr)
      }
    }

    // Test seam: after final assertUnchanged (above) and after file-actions are
    // prepared, but before the child image is created — covers recheck→open race.
    testHookAfterAssertBeforeSpawn?()

    var childPID: pid_t = 0
    let spawnRC = executablePath.withCString { exeC in
      posix_spawn(
        &childPID,
        exeC,
        &fileActions,
        &attr,
        &argvCStrings,
        &envCStrings)
    }
    close(writeFD)
    guard spawnRC == 0, childPID > 0 else {
      close(readFD)
      return failLaunch("posix_spawn failed rc=\(spawnRC)")
    }

    let processID = childPID
    let processGroupEstablished = true
    let effects = LiveProcessControl()
    // Shared with group signal: while group identityMatches+kill(-pgid) holds this
    // lock, waitpid cannot reap the root, so PID/PGID cannot be reused mid-signal.
    let rootLifecycle = RootLifecycleGate()
    // Stable identity of the true spawn — required before any later signal authority.
    let rootIdentity = effects.processIdentity(processID)
    var trackedIdentities: [ProcessIdentity] = []
    if let rootIdentity {
      trackedIdentities.append(rootIdentity)
    }
    let startedAt = Date()
    let maxBytes = caps.maxOutputBytes
    let buffer = ProcessOutputBuffer(maxBytes: maxBytes)

    let trackedLock = NSLock()
    func recordTracked(from result: ResidualScanResult) {
      guard case let .residual(set) = result else { return }
      trackedLock.lock()
      defer { trackedLock.unlock() }
      var byPID = Dictionary(uniqueKeysWithValues: trackedIdentities.map { ($0.pid, $0) })
      for identity in set.killable {
        byPID[identity.pid] = identity
      }
      trackedIdentities = Array(byPID.values)
    }
    func snapshotTracked() -> [ProcessIdentity] {
      trackedLock.lock()
      defer { trackedLock.unlock() }
      return trackedIdentities
    }
    func terminate(
      graceSec: TimeInterval
    ) {
      let tracked = snapshotTracked()
      Self.terminateTree(
        rootPID: processID,
        rootIdentity: rootIdentity,
        processGroupEstablished: processGroupEstablished,
        boundWorkPath: boundWorkPath,
        trackedIdentities: tracked,
        graceSec: graceSec,
        effects: effects,
        rootLifecycle: rootLifecycle)
    }
    /// Reap only under the root lifecycle lock so it cannot interleave with group signal.
    func reapRootNonBlocking() -> (reaped: Bool, status: Int32, echild: Bool) {
      rootLifecycle.withLock {
        var status: Int32 = 0
        let wr = waitpid(processID, &status, WNOHANG)
        if wr == processID {
          return (true, status, false)
        }
        if wr < 0, errno == ECHILD {
          return (false, status, true)
        }
        return (false, status, false)
      }
    }

    let readerQueue = DispatchQueue(label: "tatwo.loop.engine.stdout")
    let readerDone = DispatchSemaphore(value: 0)
    readerQueue.async {
      defer {
        close(readFD)
        readerDone.signal()
      }
      var chunk = [UInt8](repeating: 0, count: 16_384)
      while true {
        let n = read(readFD, &chunk, chunk.count)
        if n <= 0 { break }
        let hitCap = buffer.append(Data(chunk[0..<n]))
        if hitCap {
          terminate(graceSec: 0.25)
        }
      }
    }

    var wasCancelled = false
    var timedOut = false
    let graceSec: TimeInterval = 0.25
    // Capture wait status in the first reap — a second waitpid after natural
    // exit returns ECHILD and would otherwise lose the real exit code
    // (fast successes were misreported as exit_nonzero).
    var exitStatus: Int32 = -1
    var rootExited = false
    var lastTrackAt = Date.distantPast
    while true {
      // Periodically track lineage identities so setsid+chdir("/") daemons seen
      // earlier remain killable/reportable after they escape the process tree.
      // Bound workPath is omitted here: cwd is evidence-only and must not expand
      // signal authority; skipping it also avoids host-wide cwd probes every tick.
      let nowTrack = Date()
      if nowTrack.timeIntervalSince(lastTrackAt) >= 0.1 {
        lastTrackAt = nowTrack
        let midScan = Self.scanResidualDescendants(
          rootPID: processID,
          rootIdentity: rootIdentity,
          processGroupEstablished: processGroupEstablished,
          boundWorkPath: nil,
          trackedIdentities: snapshotTracked(),
          effects: effects)
        recordTracked(from: midScan)
      }

      let reap = reapRootNonBlocking()
      if reap.reaped {
        exitStatus = reap.status
        rootExited = true
        break
      }
      if reap.echild {
        rootExited = true
        break
      }
      if shouldCancel() {
        wasCancelled = true
        terminate(graceSec: graceSec)
        break
      }
      let elapsed = Date().timeIntervalSince(startedAt)
      if elapsed >= caps.maxDurationSec {
        timedOut = true
        terminate(graceSec: graceSec)
        break
      }
      if buffer.isTruncated {
        terminate(graceSec: graceSec)
        break
      }
      Thread.sleep(
        forTimeInterval: min(
          0.01,
          max(0.001, caps.maxDurationSec - elapsed)))
    }

    // Bounded post-kill wait + recursive descendant reaping (only if still live).
    if !rootExited {
      let waitDeadline = Date().addingTimeInterval(max(0.5, postKillWaitSec))
      while Date() < waitDeadline {
        let reap = reapRootNonBlocking()
        if reap.reaped {
          exitStatus = reap.status
          rootExited = true
          break
        }
        if reap.echild {
          rootExited = true
          break
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
    if !rootExited {
      terminate(graceSec: 0.1)
      let hardDeadline = Date().addingTimeInterval(1.0)
      while Date() < hardDeadline {
        let reap = reapRootNonBlocking()
        if reap.reaped {
          exitStatus = reap.status
          rootExited = true
          break
        }
        if reap.echild {
          rootExited = true
          break
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
    _ = readerDone.wait(timeout: .now() + 2)

    // Residual scan: identity-bound lineage + tracked + cwd evidence (cwd never killable).
    let tracked = snapshotTracked()
    let residual = Self.scanResidualDescendants(
      rootPID: processID,
      rootIdentity: rootIdentity,
      processGroupEstablished: processGroupEstablished,
      boundWorkPath: boundWorkPath,
      trackedIdentities: tracked,
      effects: effects)
    recordTracked(from: residual)
    switch residual {
    case .clean:
      break
    case let .failed(reason):
      terminate(graceSec: 0.05)
      let snapshot = buffer.snapshot()
      return TatwoLoopEngineResultV1(
        exitCode: -1,
        outputData: snapshot.data,
        outputTruncated: snapshot.truncated,
        timedOut: timedOut || wasCancelled,
        cancelled: wasCancelled,
        failureCode: "process_residual",
        message: "residual scan failed closed: \(reason)")
    case let .residual(set):
      // cwd-only quarantine is a terminal availability outcome (no signal authority).
      if set.isCwdQuarantineOnly {
        let snapshot = buffer.snapshot()
        let evidenceNote = set.evidenceOnly.prefix(8).map(String.init).joined(separator: ",")
        return TatwoLoopEngineResultV1(
          exitCode: -1,
          outputData: snapshot.data,
          outputTruncated: snapshot.truncated,
          timedOut: timedOut || wasCancelled,
          cancelled: wasCancelled,
          failureCode: "process_cwd_quarantine",
          message:
            "cwd evidence quarantine (no signal authority); human confirm/release required. "
            + "evidence_only=\(evidenceNote)")
      }
      // Always clear lineage/tracked killable, even when anomaly/overflow (R2).
      terminate(graceSec: 0.05)
      let still = Self.scanResidualDescendants(
        rootPID: processID,
        rootIdentity: rootIdentity,
        processGroupEstablished: processGroupEstablished,
        boundWorkPath: boundWorkPath,
        trackedIdentities: snapshotTracked(),
        effects: effects)
      switch still {
      case .clean:
        // Anomaly alone still fails closed for PASS.
        if let anomaly = set.anomaly {
          let snapshot = buffer.snapshot()
          return TatwoLoopEngineResultV1(
            exitCode: -1,
            outputData: snapshot.data,
            outputTruncated: snapshot.truncated,
            timedOut: timedOut || wasCancelled,
            cancelled: wasCancelled,
            failureCode: "process_residual",
            message: anomaly)
        }
        break
      case let .failed(reason):
        let snapshot = buffer.snapshot()
        return TatwoLoopEngineResultV1(
          exitCode: -1,
          outputData: snapshot.data,
          outputTruncated: snapshot.truncated,
          timedOut: timedOut || wasCancelled,
          cancelled: wasCancelled,
          failureCode: "process_residual",
          message: "residual scan failed closed after kill: \(reason)")
      case let .residual(left):
        let snapshot = buffer.snapshot()
        // Best-effort kill only lineage/tracked identities — never cwd-only.
        for identity in left.killable {
          _ = Self.signalResidual(identity: identity, signal: SIGKILL, effects: effects)
        }
        // cwd-only leftover is a terminal quarantine, not an endless residual deadlock.
        if left.isCwdQuarantineOnly {
          let evidenceNote = left.evidenceOnly.prefix(8).map(String.init).joined(separator: ",")
          return TatwoLoopEngineResultV1(
            exitCode: -1,
            outputData: snapshot.data,
            outputTruncated: snapshot.truncated,
            timedOut: timedOut || wasCancelled,
            cancelled: wasCancelled,
            failureCode: "process_cwd_quarantine",
            message:
              "cwd evidence quarantine after lineage clear (no signal authority); "
              + "human confirm/release required. evidence_only=\(evidenceNote)")
        }
        let evidenceNote =
          left.evidenceOnly.isEmpty
          ? ""
          : " evidence_only=\(left.evidenceOnly.prefix(8).map(String.init).joined(separator: ","))"
        let killNote = left.killablePIDs.prefix(8).map(String.init).joined(separator: ",")
        let anomalyNote = left.anomaly.map { " anomaly=\($0)" } ?? set.anomaly.map { " anomaly=\($0)" } ?? ""
        return TatwoLoopEngineResultV1(
          exitCode: -1,
          outputData: snapshot.data,
          outputTruncated: snapshot.truncated,
          timedOut: timedOut || wasCancelled,
          cancelled: wasCancelled,
          failureCode: "process_residual",
          message:
            "descendant residual after kill: killable=\(killNote)\(evidenceNote)\(anomalyNote)")
      }
    }

    if !rootExited {
      // Hand zombie root to the unique late reaper so a slow exit cannot leak
      // forever after this call returns. Reaper only waitpid's parent-owned
      // children (no bare-pid signals).
      LateRootReaper.shared.adopt(
        pid: processID,
        identity: rootIdentity,
        lifecycle: rootLifecycle)
      let snapshot = buffer.snapshot()
      return TatwoLoopEngineResultV1(
        exitCode: -1,
        outputData: snapshot.data,
        outputTruncated: snapshot.truncated,
        timedOut: timedOut || wasCancelled,
        cancelled: wasCancelled,
        failureCode: "process_residual",
        message: "root process did not exit within post-kill wait; adopted by late reaper")
    }

    let snapshot = buffer.snapshot()
    let outputData = snapshot.data
    let wasTruncated = snapshot.truncated
    let termSignal = (exitStatus & 0o177) == 0 ? 0 : (exitStatus & 0o177)
    let code: Int32 =
      termSignal != 0 ? (0 - termSignal) : ((exitStatus >> 8) & 0xff)

    if wasCancelled {
      return TatwoLoopEngineResultV1(
        exitCode: code,
        outputData: outputData,
        outputTruncated: wasTruncated,
        cancelled: true,
        failureCode: "cancelled",
        message: "cancel file signal observed")
    }
    if timedOut {
      return TatwoLoopEngineResultV1(
        exitCode: code,
        outputData: outputData,
        outputTruncated: wasTruncated,
        timedOut: true,
        failureCode: "timeout",
        message: "maxDurationSec exceeded")
    }
    if wasTruncated {
      return TatwoLoopEngineResultV1(
        exitCode: code,
        outputData: outputData,
        outputTruncated: true,
        failureCode: "output_cap",
        message: "maxOutputBytes exceeded; output truncated")
    }
    if code != 0 {
      return TatwoLoopEngineResultV1(
        exitCode: code,
        outputData: outputData,
        failureCode: "exit_nonzero",
        message: "process engine exited non-zero")
    }
    return TatwoLoopEngineResultV1(
      exitCode: code,
      outputData: outputData)
  }

  private static func failLaunch(_ message: String) -> TatwoLoopEngineResultV1 {
    TatwoLoopEngineResultV1(
      exitCode: -1,
      outputData: Data(),
      failureCode: "launch_failed",
      message: message)
  }

  /// Serializes root `waitpid` reap against group `identityMatches + kill(-pgid)`.
  ///
  /// Holding this gate during the group signal keeps a just-exited root as a zombie
  /// until the signal completes, so the PID/PGID cannot be reused mid-window.
  public final class RootLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    public init() {}
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
      lock.lock()
      defer { lock.unlock() }
      return try body()
    }
  }

  /// Unique late reaper for parent-owned roots that outlive the bounded wait.
  ///
  /// Only performs `waitpid` (optionally under the root lifecycle gate). Never
  /// signals by bare pid. Prevents long-lived zombies after engine return.
  public final class LateRootReaper: @unchecked Sendable {
    public static let shared = LateRootReaper()

    private struct Entry {
      let pid: pid_t
      let identity: ProcessIdentity?
      let lifecycle: RootLifecycleGate?
      let adoptedAt: Date
    }

    private let lock = NSLock()
    private var pending: [Entry] = []
    private var threadStarted = false

    private init() {}

    /// Adopt a still-live or zombie child for eventual non-blocking reaping.
    public func adopt(
      pid: pid_t,
      identity: ProcessIdentity?,
      lifecycle: RootLifecycleGate?
    ) {
      guard pid > 1, pid != getpid() else { return }
      lock.lock()
      // Dedup by pid — one pending entry per child.
      if pending.contains(where: { $0.pid == pid }) {
        lock.unlock()
        return
      }
      pending.append(
        Entry(pid: pid, identity: identity, lifecycle: lifecycle, adoptedAt: Date()))
      let needStart = !threadStarted
      if needStart { threadStarted = true }
      lock.unlock()
      if needStart {
        startLoop()
      }
    }

    /// Test/observability: number of unreaped adopted roots.
    public var pendingCount: Int {
      lock.lock(); defer { lock.unlock() }
      return pending.count
    }

    private func startLoop() {
      let thread = Thread { [weak self] in
        while true {
          guard let self else { return }
          self.reapOnce()
          Thread.sleep(forTimeInterval: 0.25)
        }
      }
      thread.name = "tatwo.loop.late-root-reaper"
      thread.qualityOfService = .utility
      thread.start()
    }

    private func reapOnce() {
      lock.lock()
      let snapshot = pending
      lock.unlock()
      guard !snapshot.isEmpty else { return }
      var finished: [pid_t] = []
      for entry in snapshot {
        let reaped = reapEntry(entry)
        if reaped {
          finished.append(entry.pid)
        }
      }
      guard !finished.isEmpty else { return }
      lock.lock()
      pending.removeAll { finished.contains($0.pid) }
      lock.unlock()
    }

    private func reapEntry(_ entry: Entry) -> Bool {
      let body = { () -> Bool in
        var status: Int32 = 0
        let wr = waitpid(entry.pid, &status, WNOHANG)
        if wr == entry.pid { return true }
        if wr < 0, errno == ECHILD { return true }
        return false
      }
      if let lifecycle = entry.lifecycle {
        return lifecycle.withLock(body)
      }
      return body()
    }
  }

  /// Kill process group + scan/kill **identity-bound** residual descendants only.
  ///
  /// cwd-only matches are never signalled here — they remain evidence (quarantine),
  /// never signal authority. `rootIdentity == nil` forbids process-group signals.
  ///
  /// Group signals run under `rootLifecycle` together with all root `waitpid` calls
  /// from the spawn loop so check→kill cannot race a concurrent reap.
  ///
  /// Internal (not private) so tests can exercise the production termination path
  /// with injected `ProcessControlEffects` without Darwin bare-pid kills.
  static func terminateTree(
    rootPID: pid_t,
    rootIdentity: ProcessIdentity?,
    processGroupEstablished: Bool,
    boundWorkPath: TatwoBoundWorkPath?,
    trackedIdentities: [ProcessIdentity],
    graceSec: TimeInterval,
    effects: ProcessControlEffects = LiveProcessControl(),
    rootLifecycle: RootLifecycleGate? = nil
  ) {
    // Same reason the scan refuses these: `kill(-0, …)` and `kill(0, …)` both signal
    // the caller's own process group, so an invalid root here would take down the
    // session that started the job.
    guard rootPID > 1 else { return }

    // Group signal only when spawn-time root identity still matches. Missing identity
    // is fail closed (never the historical "nil means allow" path). Match + group
    // kill share one critical section with waitpid (rootLifecycle).
    func groupSignal(_ signal: Int32) {
      guard processGroupEstablished,
        let rootIdentity,
        rootIdentity.pid > 1
      else { return }
      let body = {
        _ = effects.signalProcessGroup(rootIdentity: rootIdentity, signal)
      }
      if let rootLifecycle {
        rootLifecycle.withLock(body)
      } else {
        // Tests without a shared gate still get atomic match+kill inside effects.
        body()
      }
    }

    groupSignal(SIGTERM)
    if let rootIdentity {
      _ = signalResidual(identity: rootIdentity, signal: SIGTERM, effects: effects)
    }
    // No captured identity: refuse bare pid and group signal authority (PID-reuse).

    let scan = scanResidualDescendants(
      rootPID: rootPID,
      rootIdentity: rootIdentity,
      processGroupEstablished: processGroupEstablished,
      boundWorkPath: boundWorkPath,
      trackedIdentities: trackedIdentities,
      effects: effects)
    signalKillable(from: scan, signal: SIGTERM, effects: effects)

    let graceDeadline = Date().addingTimeInterval(graceSec)
    while Date() < graceDeadline {
      let mid = scanResidualDescendants(
        rootPID: rootPID,
        rootIdentity: rootIdentity,
        processGroupEstablished: processGroupEstablished,
        boundWorkPath: boundWorkPath,
        trackedIdentities: trackedIdentities,
        effects: effects)
      switch mid {
      case .clean:
        if let rootIdentity, effects.identityMatches(rootIdentity) {
          if !effects.isAlive(rootIdentity.pid), !effects.isIndeterminate(rootIdentity.pid) {
            return
          }
        } else if !effects.isAlive(rootPID), !effects.isIndeterminate(rootPID) {
          return
        }
      case .residual, .failed:
        break
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    groupSignal(SIGKILL)
    if let rootIdentity {
      _ = signalResidual(identity: rootIdentity, signal: SIGKILL, effects: effects)
    }
    let last = scanResidualDescendants(
      rootPID: rootPID,
      rootIdentity: rootIdentity,
      processGroupEstablished: processGroupEstablished,
      boundWorkPath: boundWorkPath,
      trackedIdentities: trackedIdentities,
      effects: effects)
    signalKillable(from: last, signal: SIGKILL, effects: effects)
  }

  /// Signal only lineage/tracked killable identities from a scan result.
  /// cwd-only evidence and `.failed` (no killable set) never grant signal authority.
  private static func signalKillable(
    from result: ResidualScanResult,
    signal: Int32,
    effects: ProcessControlEffects
  ) {
    switch result {
    case .clean, .failed:
      return
    case let .residual(set):
      // Overflow anomaly still clears lineage-confirmed killable PIDs (R2).
      for identity in set.killable {
        _ = signalResidual(identity: identity, signal: signal, effects: effects)
      }
    }
  }

  /// Stable process identity (pid + start time) to prevent PID-reuse kills.
  public struct ProcessIdentity: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let startSec: UInt64
    public let startUsec: UInt64

    public init(pid: pid_t, startSec: UInt64, startUsec: UInt64) {
      self.pid = pid
      self.startSec = startSec
      self.startUsec = startUsec
    }
  }

  /// Residual classification: killable lineage vs evidence-only cwd matches.
  public struct ResidualProcessSet: Equatable, Sendable {
    /// pgid/ppid lineage and previously tracked spawn identities — may be signalled.
    public let killable: [ProcessIdentity]
    /// cwd-only matches — never signalled; always block PASS while alive.
    /// Terminal outcome is `process_cwd_quarantine` (human confirm), not endless residual.
    public let evidenceOnly: [pid_t]
    /// Classification anomaly (e.g. over-cap). Fail closed for PASS; does not strip killable.
    public let anomaly: String?

    public init(
      killable: [ProcessIdentity],
      evidenceOnly: [pid_t] = [],
      anomaly: String? = nil
    ) {
      self.killable = killable
      self.evidenceOnly = evidenceOnly
      self.anomaly = anomaly
    }

    public var blocksPass: Bool {
      !killable.isEmpty || !evidenceOnly.isEmpty || anomaly != nil
    }

    /// cwd evidence with no killable lineage — quarantine terminal, no signal authority.
    public var isCwdQuarantineOnly: Bool {
      killable.isEmpty && !evidenceOnly.isEmpty
    }

    public var killablePIDs: [pid_t] { killable.map(\.pid).sorted() }
  }

  /// Result of residual process scan. Scan failure is never treated as "clean".
  public enum ResidualScanResult: Equatable, Sendable {
    case clean
    case residual(ResidualProcessSet)
    case failed(String)

    public var blocksPass: Bool {
      switch self {
      case .clean: return false
      case .residual(let set): return set.blocksPass
      case .failed: return true
      }
    }
  }

  /// One row of the host process table.
  public struct ProcessTableRow: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let pgid: pid_t

    public init(pid: pid_t, ppid: pid_t, pgid: pid_t) {
      self.pid = pid
      self.ppid = ppid
      self.pgid = pgid
    }
  }

  /// Every effect the residual sweep has on the host, behind one seam.
  ///
  /// Classification and signalling used to be fused, so the only way to test the
  /// classifier was to let it signal real processes — which is how a mis-classified
  /// scan SIGKILLed a user's entire login session. Tests inject a synthetic table
  /// and a recording signaller, and therefore cannot signal anything at all.
  public struct ProcessTableError: Error, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
  }

  public protocol ProcessControlEffects: Sendable {
    func processTable() -> Result<[ProcessTableRow], ProcessTableError>
    func isAlive(_ pid: pid_t) -> Bool
    func isIndeterminate(_ pid: pid_t) -> Bool
    /// Start-time identity for `pid`, or nil if unavailable.
    func processIdentity(_ pid: pid_t) -> ProcessIdentity?
    /// True when the live process still matches the recorded identity.
    func identityMatches(_ identity: ProcessIdentity) -> Bool
    /// Signal only when identity still matches. Never signal bare pids.
    @discardableResult func signal(identity: ProcessIdentity, _ signal: Int32) -> Bool
    /// Process-group signal: re-check root identity then `kill(-pgid, signal)`.
    /// Callers must hold `RootLifecycleGate` so waitpid cannot reap between match and kill.
    @discardableResult func signalProcessGroup(rootIdentity: ProcessIdentity, _ signal: Int32)
      -> Bool
  }

  /// Live effects: reads the real process table and sends real signals.
  public struct LiveProcessControl: ProcessControlEffects {
    public init() {}

    public func processTable() -> Result<[ProcessTableRow], ProcessTableError> {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/bin/ps")
      task.arguments = ["-axo", "pid=,ppid=,pgid="]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = FileHandle.nullDevice
      do {
        try task.run()
        task.waitUntilExit()
      } catch {
        return .failure(ProcessTableError("ps launch failed: \(error.localizedDescription)"))
      }
      guard task.terminationStatus == 0 else {
        return .failure(ProcessTableError("ps exited \(task.terminationStatus)"))
      }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let text = String(data: data, encoding: .utf8) else {
        return .failure(ProcessTableError("ps output not utf8"))
      }
      var rows: [ProcessTableRow] = []
      for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        guard parts.count >= 3 else { continue }
        rows.append(ProcessTableRow(pid: parts[0], ppid: parts[1], pgid: parts[2]))
      }
      // An empty process table is impossible on a live host.
      guard !rows.isEmpty else {
        return .failure(ProcessTableError("ps produced no parseable rows"))
      }
      return .success(rows)
    }

    public func isAlive(_ pid: pid_t) -> Bool {
      guard pid > 1 else { return false }
      return kill(pid, 0) == 0
    }

    public func isIndeterminate(_ pid: pid_t) -> Bool {
      guard pid > 1 else { return false }
      return kill(pid, 0) != 0 && errno != ESRCH
    }

    public func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
      ProcessEngineBinding.liveProcessIdentity(pid: pid)
    }

    public func identityMatches(_ identity: ProcessIdentity) -> Bool {
      guard let live = processIdentity(identity.pid) else { return false }
      return live == identity
    }

    @discardableResult
    public func signal(identity: ProcessIdentity, _ signal: Int32) -> Bool {
      // Production chokepoint: never signal without a matching start-time identity.
      guard identity.pid > 1, identity.pid != getpid() else { return false }
      guard identityMatches(identity) else { return false }
      return kill(identity.pid, signal) == 0
    }

    @discardableResult
    public func signalProcessGroup(rootIdentity: ProcessIdentity, _ signal: Int32) -> Bool {
      // Match + group kill are one critical section for the caller (RootLifecycleGate).
      // Never group-signal pid 0/1 or self — those hit the caller's session.
      guard rootIdentity.pid > 1, rootIdentity.pid != getpid() else { return false }
      guard identityMatches(rootIdentity) else { return false }
      return kill(-rootIdentity.pid, signal) == 0
    }
  }

  /// Upper bound on descendants one job may plausibly leak. Exceeding it marks the
  /// classification anomalous (fail closed for PASS) but **does not** strip
  /// lineage-confirmed killable PIDs from the clear set (R2).
  public static let maxPlausibleResidualDescendants = 64

  /// Signal a process only when pid is safe **and** start-time identity still matches.
  ///
  /// Routes through `effects.signal` so tests exercise the production termination
  /// path without Darwin kills. Live effects re-check identity before `kill`.
  /// cwd-only matches never reach this function with signal authority.
  @discardableResult
  public static func signalResidual(
    identity: ProcessIdentity,
    signal: Int32,
    effects: ProcessControlEffects = LiveProcessControl()
  ) -> Bool {
    guard identity.pid > 1, identity.pid != getpid() else { return false }
    return effects.signal(identity: identity, signal)
  }

  /// Legacy guard used by tests: bare-pid signal is refused (no identity).
  /// Production clear paths must use `signalResidual(identity:signal:)`.
  @discardableResult
  public static func signalResidual(_ pid: pid_t, _ signal: Int32) -> Bool {
    // Hard refuse bare pid signalling — prevents PID-reuse and the historical
    // session-wide SIGKILL accident. Callers must pass a ProcessIdentity.
    _ = signal
    guard pid > 1, pid != getpid() else { return false }
    return false
  }

  /// Capture live process start-time identity via libproc.
  public static func liveProcessIdentity(pid: pid_t) -> ProcessIdentity? {
    guard pid > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let wrote = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard wrote == size else { return nil }
    return ProcessIdentity(
      pid: pid,
      startSec: info.pbi_start_tvsec,
      startUsec: info.pbi_start_tvusec)
  }

  /// Enumerate residual processes using **spawn-time root identity**, tracked
  /// identities, identity-bound parent/child edges, and cwd evidence.
  ///
  /// Bare `rootPID`/`PGID` numbers never re-admit authority after the original
  /// identity disappears or is reused. cwd-only is never killable.
  ///
  /// Scan / parse failures return `.failed` (fail closed) — never an empty residual set
  /// that would be mistaken for success after daemonize escapes.
  public static func scanResidualDescendants(
    rootPID: pid_t,
    rootIdentity: ProcessIdentity? = nil,
    processGroupEstablished: Bool,
    boundWorkPath: TatwoBoundWorkPath? = nil,
    trackedIdentities: [ProcessIdentity] = [],
    effects: ProcessControlEffects = LiveProcessControl()
  ) -> ResidualScanResult {
    // A job root is always a real spawned child. 0 and 1 never are, and both are
    // catastrophic if accepted: kill(0, sig) signals the caller's entire process
    // group, and every process on the host reaches 0 or 1 through its ancestry,
    // so either value makes the whole process table look like a descendant.
    //
    // Callers that legitimately have no root must say so via
    // `scanWorkPathResidualsOnly` rather than passing 0 as a sentinel.
    guard rootPID > 1 else {
      return .failed("invalid job root pid \(rootPID)")
    }
    if let rootIdentity, rootIdentity.pid != rootPID {
      return .failed(
        "root identity pid \(rootIdentity.pid) does not match rootPID \(rootPID)")
    }
    return scanResiduals(
      rootPID: rootPID,
      rootIdentity: rootIdentity,
      processGroupEstablished: processGroupEstablished,
      boundWorkPath: boundWorkPath,
      trackedIdentities: trackedIdentities,
      effects: effects)
  }

  /// Scan for residuals anchored only by the bound work directory, with no process
  /// root. Exists so "no root" has an honest spelling — passing 0 to the rooted scan
  /// once classified the entire process table as descendants.
  ///
  /// cwd matches are **evidence only** (never killable).
  public static func scanWorkPathResidualsOnly(
    boundWorkPath: TatwoBoundWorkPath,
    trackedIdentities: [ProcessIdentity] = [],
    effects: ProcessControlEffects = LiveProcessControl()
  ) -> ResidualScanResult {
    scanResiduals(
      rootPID: nil,
      rootIdentity: nil,
      processGroupEstablished: false,
      boundWorkPath: boundWorkPath,
      trackedIdentities: trackedIdentities,
      effects: effects)
  }

  private static func scanResiduals(
    rootPID: pid_t?,
    rootIdentity: ProcessIdentity?,
    processGroupEstablished: Bool,
    boundWorkPath: TatwoBoundWorkPath?,
    trackedIdentities: [ProcessIdentity],
    effects: ProcessControlEffects
  ) -> ResidualScanResult {
    let rows: [ProcessTableRow]
    switch effects.processTable() {
    case let .failure(error):
      return .failed(error.reason)
    case let .success(table):
      rows = table
    }

    // --- Killable authority: only spawn-time / tracked identities + identity edges ---
    // Never seed from a bare reusable rootPID/PGID number.
    var killableByPID: [pid_t: ProcessIdentity] = [:]

    func admit(_ identity: ProcessIdentity) {
      guard identity.pid > 1, identity.pid != getpid() else { return }
      guard effects.identityMatches(identity) else { return }
      killableByPID[identity.pid] = identity
    }

    if let rootIdentity {
      admit(rootIdentity)
    }
    // rootIdentity == nil: no group/root bare-PID authority (fail closed).

    for tracked in trackedIdentities {
      admit(tracked)
    }

    // PGID expansion only while original root identity still matches. Children are
    // captured with their own identity; never re-bind a reused root PID/PGID.
    if processGroupEstablished,
      let rootIdentity,
      effects.identityMatches(rootIdentity)
    {
      for row in rows where row.pgid == rootIdentity.pid && row.pid != rootIdentity.pid && row.pid > 1
      {
        guard row.pid != getpid() else { continue }
        guard effects.isAlive(row.pid) || effects.isIndeterminate(row.pid) else { continue }
        guard let child = effects.processIdentity(row.pid) else { continue }
        // TOCTOU: re-verify root + captured child before admission.
        guard effects.identityMatches(rootIdentity) else { break }
        guard effects.identityMatches(child) else { continue }
        killableByPID[child.pid] = child
      }
    }

    // Walk ppid tree from already-admitted identity parents only.
    // Links through pid 0 and 1 are refused.
    var changed = true
    while changed {
      changed = false
      let parents = killableByPID
      for row in rows {
        guard row.pid > 1, row.ppid > 1, row.pid != getpid() else { continue }
        guard killableByPID[row.pid] == nil else { continue }
        guard let parent = parents[row.ppid] else { continue }
        guard effects.identityMatches(parent) else { continue }
        guard effects.isAlive(row.pid) || effects.isIndeterminate(row.pid) else { continue }
        guard let child = effects.processIdentity(row.pid) else { continue }
        // TOCTOU between table snapshot and identity capture.
        guard effects.identityMatches(parent), effects.identityMatches(child) else { continue }
        killableByPID[child.pid] = child
        changed = true
      }
    }

    // --- Evidence only: cwd match never grants signal authority ---
    var evidenceOnly = Set<pid_t>()
    if let boundWorkPath {
      switch workPathAnchoredPIDs(
        among: rows.map(\.pid),
        boundWorkPath: boundWorkPath,
        excludePID: getpid(),
        effects: effects)
      {
      case let .failed(reason):
        return .failed(reason)
      case let .pids(cwdPIDs):
        for pid in cwdPIDs {
          guard pid > 1, pid != getpid() else { continue }
          guard effects.isAlive(pid) || effects.isIndeterminate(pid) else { continue }
          if killableByPID[pid] == nil {
            evidenceOnly.insert(pid)
          }
        }
      }
    }

    let killable = killableByPID.values.sorted { $0.pid < $1.pid }
    let evidence = evidenceOnly.sorted()
    let totalClassified = killable.count + evidence.count

    if killable.isEmpty && evidence.isEmpty {
      return .clean
    }

    // Cap: classification is untrusted above the limit, but lineage killable is
    // still returned for clearing (R2). Never convert to `.failed` with empty set.
    var anomaly: String?
    if totalClassified > Self.maxPlausibleResidualDescendants
      || killable.count > Self.maxPlausibleResidualDescendants
    {
      anomaly =
        "residual scan produced implausible set of \(totalClassified) classified pids "
        + "(killable=\(killable.count)); lineage clear still authorized"
    }

    return .residual(
      ResidualProcessSet(killable: killable, evidenceOnly: evidence, anomaly: anomaly))
  }

  private enum WorkPathAnchorResult {
    case pids(Set<pid_t>)
    case failed(String)
  }

  /// PIDs whose current working directory matches the held work-path inode.
  /// Evidence only — callers must never signal this set without separate lineage proof.
  private static func workPathAnchoredPIDs(
    among candidatePIDs: [pid_t],
    boundWorkPath: TatwoBoundWorkPath,
    excludePID: pid_t,
    effects: ProcessControlEffects
  ) -> WorkPathAnchorResult {
    // Prefer effects-provided cwd when tests inject a table; live falls back to libproc.
    if let fake = effects as? WorkPathCWDProviding {
      return .pids(fake.workPathMatchingPIDs(among: candidatePIDs, excludePID: excludePID))
    }
    let workPath: String
    do {
      workPath = try boundWorkPath.currentPathString()
    } catch {
      return .failed("work path F_GETPATH failed during residual scan")
    }
    let workPathResolved = URL(fileURLWithPath: workPath).resolvingSymlinksInPath().path
    var matched = Set<pid_t>()
    for pid in candidatePIDs {
      if pid <= 1 || pid == excludePID || pid == getpid() { continue }
      guard let cwd = processCWD(pid: pid) else { continue }
      let cwdResolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
      if cwdResolved == workPathResolved {
        matched.insert(pid)
      }
    }
    return .pids(matched)
  }

  /// Test-only SPI: synthetic cwd membership without real proc_pidinfo.
  /// Not part of the public production effects surface — keep internal so formal
  /// runners cannot accidentally conform and rewrite cwd evidence classification.
  protocol WorkPathCWDProviding {
    func workPathMatchingPIDs(among candidatePIDs: [pid_t], excludePID: pid_t) -> Set<pid_t>
  }

  /// Best-effort process cwd via libproc. Returns nil if unavailable for that pid.
  private static func processCWD(pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
    let wrote = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
    guard wrote == size else { return nil }
    // pvi_cdir.vip_path is a fixed C array.
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
        let s = String(cString: cstr)
        return s.isEmpty ? nil : s
      }
    }
  }
  #endif
}

// MARK: - Agent launch environment

/// Fully explicit minimal environment for agent / engine launches.
///
/// Does **not** inherit host PATH / SHELL / TMPDIR. PATH is only the executable's
/// directory (plus optional extra bin dirs). Isolated HOME is create-only.
public enum TatwoAgentLaunchEnvironment: Sendable {
  /// Host keys that may be copied (narrow; PATH/SHELL/TMP* are NOT copied).
  public static let allowlistKeys: Set<String> = [
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "USER",
    "LOGNAME",
    "TZ",
  ]

  /// Prefixes that must never be inherited (dynamic loader / cross-brand / hooks).
  public static let blockedPrefixes: [String] = [
    "DYLD_",
    "LD_",
    "CODEX_",
    "CLAUDE_",
    "ANTHROPIC_",
    "OPENAI_",
    "GROK_",
    "XAI_",
    "TATWO_AGENT_",
    "NPM_CONFIG_",
    "NODE_OPTIONS",
  ]

  public static let blockedExactKeys: Set<String> = [
    "HOME",
    "PATH",
    "SHELL",
    "TMPDIR",
    "TMP",
    "TEMP",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "SSL_CERT_FILE",
    "CURL_CA_BUNDLE",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
  ]

  /// SIP-protected system binary directories. Fixed here so PATH never reflects
  /// whatever the host environment happened to carry.
  public static let systemBinaryDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

  /// Fully explicit minimal env: PATH is the executable directory plus fixed system
  /// directories; host PATH/SHELL/TMPDIR are never inherited.
  public static func explicitMinimal(
    executablePath: String,
    home: String? = nil,
    tmpDir: String? = nil,
    extra: [String: String] = [:],
    from host: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let exeDir = URL(fileURLWithPath: executablePath)
      .deletingLastPathComponent()
      .standardizedFileURL
      .path
    // PATH is built here rather than inherited: the executable's own directory plus
    // the SIP-protected system directories. Agent CLIs and their scripts legitimately
    // call standard utilities, and a host-supplied PATH is exactly the injection
    // surface this env is meant to remove.
    var env: [String: String] = [
      "PATH": ([exeDir] + Self.systemBinaryDirectories).joined(separator: ":"),
      "LANG": host["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "C",
      "TERM": "dumb",
    ]
    if let home, !home.isEmpty {
      env["HOME"] = home
    }
    if let tmpDir, !tmpDir.isEmpty {
      env["TMPDIR"] = tmpDir
      env["TMP"] = tmpDir
      env["TEMP"] = tmpDir
    }
    // Optional identity keys only if present and not blocked.
    for key in ["USER", "LOGNAME", "TZ", "LC_ALL", "LC_CTYPE"] {
      if let value = host[key], !value.isEmpty, !isBlocked(key) {
        env[key] = value
      }
    }
    for (key, value) in extra {
      guard !isLoaderKey(key) else { continue }
      if key == "HOME" || key == "PATH" || key == "TMPDIR" || key == "TMP" || key == "TEMP"
        || key.hasPrefix("TATWO_ISOLATED_") || key.hasPrefix("XDG_")
      {
        env[key] = value
      } else if !isBlocked(key) {
        env[key] = value
      }
    }
    if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
      env["PATH"] = exeDir
    }
    // Never inherit host SHELL.
    return env.filter { !isLoaderKey($0.key) && $0.key != "SHELL" }
  }

  /// Backward-compatible name: now fully explicit (does not trust host PATH/SHELL/TMPDIR).
  public static func minimalAllowlist(
    from host: [String: String] = ProcessInfo.processInfo.environment,
    extra: [String: String] = [:]
  ) -> [String: String] {
    explicitMinimal(
      executablePath: "/usr/bin/true",
      home: nil,
      tmpDir: nil,
      extra: extra,
      from: host)
  }

  /// Per-agent isolated HOME/config root under a host-controlled base.
  /// Create-only: existing symlink / non-directory / wrong owner → fail closed (throws).
  public static func isolated(
    agent: TatwoRemoteAgentKindV1,
    isolatedHomesRoot: URL,
    executablePath: String,
    activeSkillsRoot: String? = nil,
    expectedActiveSkillSetDigest: String? = nil,
    skillReadbackPath: String? = nil,
    from host: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [String: String] {
    let home = try prepareIsolatedHome(
      agent: agent, isolatedHomesRoot: isolatedHomesRoot)
    let config = try ensureSubdirectory(home.appendingPathComponent("config", isDirectory: true))
    let cache = try ensureSubdirectory(home.appendingPathComponent("cache", isDirectory: true))
    let data = try ensureSubdirectory(home.appendingPathComponent("data", isDirectory: true))
    let tmp = try ensureSubdirectory(home.appendingPathComponent("tmp", isDirectory: true))
    var extra = [
      "HOME": home.path,
      "XDG_CONFIG_HOME": config.path,
      "XDG_CACHE_HOME": cache.path,
      "XDG_DATA_HOME": data.path,
      "TATWO_ISOLATED_AGENT": agent.rawValue,
    ]
    if let activeSkillsRoot {
      extra["TATWO_ACTIVE_SKILLS_ROOT"] = activeSkillsRoot
    }
    if let expectedActiveSkillSetDigest {
      extra["TATWO_ACTIVE_SKILL_SET_DIGEST"] = expectedActiveSkillSetDigest
    }
    if let skillReadbackPath {
      extra["TATWO_ACTIVE_SKILL_READBACK_PATH"] = skillReadbackPath
    }
    return explicitMinimal(
      executablePath: executablePath,
      home: home.path,
      tmpDir: tmp.path,
      extra: extra,
      from: host)
  }

  /// Create-only isolated HOME. Fail closed on symlink / non-dir / unexpected owner.
  public static func prepareIsolatedHome(
    agent: TatwoRemoteAgentKindV1,
    isolatedHomesRoot: URL
  ) throws -> URL {
    try ensureDirectoryCreateOnly(isolatedHomesRoot)
    let home = isolatedHomesRoot
      .appendingPathComponent(agent.rawValue, isDirectory: true)
      .standardizedFileURL
    try ensureDirectoryCreateOnly(home)
    return home
  }

  public static func ensureDirectoryCreateOnly(_ url: URL) throws {
    let path = url.standardizedFileURL.path
    #if os(macOS)
    // Reject if a symlink already occupies the path.
    var st = stat()
    if lstat(path, &st) == 0 {
      if (st.st_mode & S_IFMT) == S_IFLNK {
        throw TatwoLoopJobStateError.invalidPayload(
          "isolated home path is a symlink (fail closed): \(path)")
      }
      if (st.st_mode & S_IFMT) != S_IFDIR {
        throw TatwoLoopJobStateError.invalidPayload(
          "isolated home path is not a directory: \(path)")
      }
      // Owner must be current uid.
      if st.st_uid != getuid() {
        throw TatwoLoopJobStateError.invalidPayload(
          "isolated home not owned by current user: \(path)")
      }
      // Tighten mode to 0700.
      _ = chmod(path, S_IRWXU)
      return
    }
    // Create-only via mkdir; if races to exist, re-validate above rules.
    if mkdir(path, S_IRWXU) != 0 {
      if errno == EEXIST {
        // Re-validate (no symlink follow).
        if lstat(path, &st) != 0 {
          throw TatwoLoopJobStateError.invalidPayload(
            "isolated home create race: \(path)")
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
          throw TatwoLoopJobStateError.invalidPayload(
            "isolated home became symlink: \(path)")
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
          throw TatwoLoopJobStateError.invalidPayload(
            "isolated home not directory after race: \(path)")
        }
        if st.st_uid != getuid() {
          throw TatwoLoopJobStateError.invalidPayload(
            "isolated home wrong owner after race: \(path)")
        }
        return
      }
      throw TatwoLoopJobStateError.invalidPayload(
        "isolated home mkdir failed errno=\(errno) path=\(path)")
    }
    #else
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true)
    #endif
  }

  private static func ensureSubdirectory(_ url: URL) throws -> URL {
    try ensureDirectoryCreateOnly(url)
    return url
  }

  public static func isBlocked(_ key: String) -> Bool {
    if blockedExactKeys.contains(key) { return true }
    if isLoaderKey(key) { return true }
    let upper = key.uppercased()
    for prefix in blockedPrefixes {
      if upper.hasPrefix(prefix) || key.hasPrefix(prefix) { return true }
    }
    return false
  }

  public static func isLoaderKey(_ key: String) -> Bool {
    let upper = key.uppercased()
    return upper.hasPrefix("DYLD_") || upper.hasPrefix("LD_")
  }
}

// MARK: - Bound work path (inode + open directory fd)

/// Work directory bound once by open directory fd + inode so symlink/rename
/// swaps between containment check and process launch fail closed.
/// Launch uses the held fd (`posix_spawn` fchdir) — never re-resolves pathname.
public final class TatwoBoundWorkPath: @unchecked Sendable {
  public let path: URL
  public let fileID: UInt64
  public let deviceID: UInt64
  /// Open `O_DIRECTORY|O_CLOEXEC` descriptor; owned by this object.
  public let directoryFileDescriptor: Int32

  public init(path: URL, fileID: UInt64, deviceID: UInt64, directoryFileDescriptor: Int32) {
    self.path = path
    self.fileID = fileID
    self.deviceID = deviceID
    self.directoryFileDescriptor = directoryFileDescriptor
  }

  deinit {
    #if os(macOS)
    if directoryFileDescriptor >= 0 {
      _ = Darwin.close(directoryFileDescriptor)
    }
    #endif
  }

  /// Current absolute path of the held directory inode (`F_GETPATH`). Prefer this over
  /// the bind-time `path` string after renames.
  public func currentPathString() throws -> String {
    #if os(macOS)
    var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(directoryFileDescriptor, F_GETPATH, &pathBuf) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path F_GETPATH failed errno=\(errno)")
    }
    return String(cString: pathBuf)
    #else
    throw TatwoLoopJobStateError.invalidPayload("work path F_GETPATH requires macOS")
    #endif
  }

  /// Create/truncate a file under the held directory via `openat` + `O_NOFOLLOW`
  /// (no pathname re-resolution of workPath).
  public func writeFile(name: String, data: Data, mode: mode_t = 0o600) throws {
    #if os(macOS)
    guard !name.isEmpty, !name.contains("/"), name != "." && name != ".." else {
      throw TatwoLoopJobStateError.invalidPayload("invalid work-path relative name")
    }
    let fd = name.withCString { cName in
      Darwin.openat(
        directoryFileDescriptor,
        cName,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
        mode)
    }
    guard fd >= 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "openat(write) failed errno=\(errno) name=\(name)")
    }
    defer { _ = Darwin.close(fd) }
    try data.withUnsafeBytes { raw in
      var written = 0
      let total = raw.count
      let base = raw.bindMemory(to: UInt8.self).baseAddress
      while written < total {
        let n = Darwin.write(fd, base?.advanced(by: written), total - written)
        if n < 0 {
          if errno == EINTR { continue }
          throw TatwoLoopJobStateError.invalidPayload(
            "writeat failed errno=\(errno) name=\(name)")
        }
        written += n
      }
    }
    #else
    throw TatwoLoopJobStateError.invalidPayload("openat write requires macOS")
    #endif
  }

  /// Open an existing relative file under the held directory (`O_RDONLY|O_NOFOLLOW|O_CLOEXEC`).
  /// Caller owns the returned fd and must close it.
  public func openFileReadOnly(name: String) throws -> Int32 {
    #if os(macOS)
    guard !name.isEmpty, !name.contains("/"), name != "." && name != ".." else {
      throw TatwoLoopJobStateError.invalidPayload("invalid work-path relative name")
    }
    let fd = name.withCString { cName in
      Darwin.openat(
        directoryFileDescriptor,
        cName,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard fd >= 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "openat(read) failed errno=\(errno) name=\(name)")
    }
    return fd
    #else
    throw TatwoLoopJobStateError.invalidPayload("openat read requires macOS")
    #endif
  }

  /// Absolute path of a relative entry under the held directory (via openat + F_GETPATH).
  public func absolutePath(ofRelative name: String) throws -> String {
    let fd = try openFileReadOnly(name: name)
    defer { _ = Darwin.close(fd) }
    #if os(macOS)
    var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &pathBuf) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "prompt F_GETPATH failed errno=\(errno)")
    }
    return String(cString: pathBuf)
    #else
    throw TatwoLoopJobStateError.invalidPayload("F_GETPATH requires macOS")
    #endif
  }

  /// Open directory, require directory, capture identity via fstat (no path re-walk later).
  public static func bind(_ url: URL) throws -> TatwoBoundWorkPath {
    #if os(macOS)
    let candidate = url.standardizedFileURL
    // Open without following final symlink when possible; O_DIRECTORY requires dir.
    let fd = candidate.path.withCString { cPath in
      Darwin.open(cPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    guard fd >= 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path open(O_DIRECTORY) failed errno=\(errno): \(candidate.path)")
    }
    var st = stat()
    guard fstat(fd, &st) == 0 else {
      _ = Darwin.close(fd)
      throw TatwoLoopJobStateError.invalidPayload(
        "work path fstat failed: \(candidate.path)")
    }
    guard (st.st_mode & S_IFMT) == S_IFDIR else {
      _ = Darwin.close(fd)
      throw TatwoLoopJobStateError.invalidPayload(
        "work path is not a directory: \(candidate.path)")
    }
    let fileID = UInt64(st.st_ino)
    let deviceID = UInt64(st.st_dev)
    guard fileID != 0 else {
      _ = Darwin.close(fd)
      throw TatwoLoopJobStateError.invalidPayload(
        "work path inode unavailable: \(candidate.path)")
    }
    // Path string for audit/argv only (spawn uses fd). Prefer Foundation
    // symlink resolution so callers comparing prompt/work paths stay coherent;
    // assertUnchanged uses F_GETPATH round-trip for replace-race detection.
    let resolvedPath = candidate.resolvingSymlinksInPath()
    return TatwoBoundWorkPath(
      path: resolvedPath,
      fileID: fileID,
      deviceID: deviceID,
      directoryFileDescriptor: fd)
    #else
    throw TatwoLoopJobStateError.invalidPayload("work path bind requires macOS")
    #endif
  }

  /// Re-check held fd identity and namespace binding before launch.
  ///
  /// 1. `fstat(held fd)` must still match bind-time ino/dev (fd still a dir).
  /// 2. `F_GETPATH` + re-open must round-trip to the **same** inode. This
  ///    fails closed when the directory was unlinked and a new directory
  ///    reused the path string (symlink/replace race). Rename of the held
  ///    directory keeps the same inode under a new path and still passes —
  ///    spawn continues to use the held fd, never the old pathname.
  public func assertUnchanged() throws {
    #if os(macOS)
    var st = stat()
    guard fstat(directoryFileDescriptor, &st) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path identity lost (fstat failed) before launch")
    }
    let nowID = UInt64(st.st_ino)
    let nowDev = UInt64(st.st_dev)
    guard nowID == fileID, nowDev == deviceID, (st.st_mode & S_IFMT) == S_IFDIR else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path identity changed before launch (symlink/replace race)")
    }

    // Round-trip via current path of the held inode. Delete+recreate at the
    // old name leaves F_GETPATH pointing at a path that now names a *different*
    // directory; rename updates F_GETPATH and still matches.
    var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(directoryFileDescriptor, F_GETPATH, &pathBuf) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path unlinked or unresolvable before launch (F_GETPATH failed)")
    }
    let pathFd = Darwin.open(pathBuf, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard pathFd >= 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path reopen after F_GETPATH failed errno=\(errno) (replace race)")
    }
    defer { _ = Darwin.close(pathFd) }
    var pathStat = stat()
    guard fstat(pathFd, &pathStat) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path re-fstat failed before launch")
    }
    let pathID = UInt64(pathStat.st_ino)
    let pathDev = UInt64(pathStat.st_dev)
    guard pathID == fileID, pathDev == deviceID, (pathStat.st_mode & S_IFMT) == S_IFDIR else {
      throw TatwoLoopJobStateError.invalidPayload(
        "work path identity changed before launch (symlink/replace race)")
    }
    #else
    throw TatwoLoopJobStateError.invalidPayload("work path assert requires macOS")
    #endif
  }
}

/// Thread-safe bounded stdout collector for process engine runs.
private final class ProcessOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let maxBytes: Int
  private var data = Data()
  private var truncated = false

  init(maxBytes: Int) {
    self.maxBytes = max(1, maxBytes)
  }

  var isTruncated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return truncated
  }

  /// Appends up to remaining capacity. Returns true once the cap is hit.
  @discardableResult
  func append(_ chunk: Data) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if truncated {
      return true
    }
    if data.count >= maxBytes {
      truncated = true
      return true
    }
    let room = maxBytes - data.count
    if chunk.count > room {
      data.append(chunk.prefix(room))
      truncated = true
      return true
    }
    data.append(chunk)
    return false
  }

  func snapshot() -> (data: Data, truncated: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (data, truncated)
  }
}

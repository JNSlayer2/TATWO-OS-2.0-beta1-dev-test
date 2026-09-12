import Foundation
#if canImport(Darwin)
import Darwin
import CryptoKit
#endif

/// Target-local agent CLI engine for `.tatwoLoop` remote compute.
///
/// Launches only absolute-path whitelist entries after resolving the final
/// symlink target and pinning content digest. Prompt text is written under the
/// **held** work-directory fd (`openat`) and stdin is passed as an already-open
/// fd — the engine never re-resolves workPath/prompt by pathname after bind.
/// Explicitly enabled only when the production runner is started with `--engine agent`.
///
/// Threat-model boundary (not defended here — same-user can replace the engine host too):
/// - Whitelist entries under user-writable dirs (e.g. `~/.local/bin/grok`) can be
///   replaced by the same OS user who can also replace `tatwo-ultrawork` itself.
/// - First-seen content-digest pin (TOFU) is not a substitute for install-receipt /
///   code-signature provisioning; re-enrollment is out of scope for this boundary.
public struct TatwoAgentEngineBinding: TatwoLoopEngineBinding {
  public static let promptFileName = "tatwo-agent-prompt.txt"
  public static let auditJournalFileName = "tatwo-agent-engine.journal.jsonl"
  public static let pinStoreFileName = "executable-pins.json"
  public static let activeSkillsProjectionDirectoryName = "active-skills"
  public static let skillReadbackDirectoryName = "skill-readbacks"

  /// Fallback when `task.agent` is nil (tests / single-agent host defaults).
  public let defaultAgent: TatwoRemoteAgentKindV1?
  /// Home used to expand `~/.local/bin/*` whitelist candidates (injectable for tests).
  public let homeDirectoryURL: URL
  /// Short username for `/Users/<me>/.codex/bin/grok-isolated` candidate.
  public let realUserName: String
  /// Root under which each agent gets a fixed isolated HOME/config tree.
  public let isolatedHomesRootURL: URL
  /// Where content-digest pins for authorized executables are stored.
  public let pinStoreURL: URL

  public init(
    defaultAgent: TatwoRemoteAgentKindV1? = nil,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    realUserName: String = NSUserName(),
    isolatedHomesRootURL: URL? = nil,
    pinStoreURL: URL? = nil
  ) {
    self.defaultAgent = defaultAgent
    self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
    self.realUserName = realUserName
    self.isolatedHomesRootURL =
      (isolatedHomesRootURL
        ?? homeDirectoryURL
        .appendingPathComponent(".tatwo-agent-homes", isDirectory: true))
      .standardizedFileURL
    self.pinStoreURL =
      (pinStoreURL
        ?? self.isolatedHomesRootURL.appendingPathComponent(Self.pinStoreFileName))
      .standardizedFileURL
  }

  /// Production default: no forced default agent; payload must declare `agent`.
  public static let production = TatwoAgentEngineBinding()

  /// Resolve the exact CLI model argument for a canonical Work OS route.
  ///
  /// Claude uses vendor full model names so `fable-5` cannot degrade into an
  /// unqualified `claude -p` session or a mutable alias/fallback choice.
  public func exactModelLaunchArgument(
    for agent: TatwoRemoteAgentKindV1,
    exactModelRouteID: String
  ) throws -> String {
    guard
      TatwoModelIdentityRegistry.canonicalModelID(for: exactModelRouteID)
        == exactModelRouteID,
      TatwoModelIdentityRegistry.isActiveDispatchEligible(exactModelRouteID),
      agent.acceptsExactModelRouteID(exactModelRouteID)
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent exact model route \(exactModelRouteID) is invalid for \(agent.rawValue)")
    }
    switch agent {
    case .grok, .codex:
      return exactModelRouteID
    case .claude:
      switch exactModelRouteID {
      case "fable-5": return "claude-fable-5"
      case "opus-5": return "claude-opus-5"
      case "sonnet-5": return "claude-sonnet-5"
      case "haiku-4-5": return "claude-haiku-4-5"
      default:
        throw TatwoLoopJobStateError.invalidPayload(
          "agent exact model route \(exactModelRouteID) has no pinned Claude CLI mapping")
      }
    }
  }

  // MARK: - Whitelist + final target pin

  /// Absolute whitelist *candidates* (logical paths, before symlink resolution).
  public func allowedExecutablePaths() -> [String] {
    let home = homeDirectoryURL
    var paths = [
      home.appendingPathComponent(".local/bin/grok").path,
      home.appendingPathComponent(".local/bin/codex").path,
      home.appendingPathComponent(".local/bin/claude").path,
    ]
    if isSafeUnixUserName(realUserName) {
      paths.append("/Users/\(realUserName)/.codex/bin/grok-isolated")
    }
    return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
  }

  /// Resolve preferred executable: membership on whitelist entry, then pin final target.
  public func resolveExecutablePath(for agent: TatwoRemoteAgentKindV1) -> String? {
    (try? resolvePinnedExecutable(for: agent))?.launchPath
  }

  /// Agents that both resolve on the executable whitelist **and** pass a bounded
  /// transport probe. Used for fleet register/heartbeat capability declaration.
  public func detectCapableAgents() -> [TatwoRemoteAgentKindV1] {
    TatwoRemoteAgentKindV1.allCases.filter { agent in
      guard let path = resolveExecutablePath(for: agent) else { return false }
      do {
        try probeTransport(for: agent, executablePath: path)
        return true
      } catch {
        return false
      }
    }
  }

  /// Bounded transport probe before capability declaration / launch.
  /// Claude must support print mode (`-p`) consuming the task prompt from stdin.
  public func probeTransport(
    for agent: TatwoRemoteAgentKindV1,
    executablePath: String? = nil,
    exactModelRouteID: String? = nil
  ) throws {
    let path = try executablePath ?? resolvePinnedExecutable(for: agent).launchPath
    let exactModelArgument = try exactModelRouteID.map {
      try exactModelLaunchArgument(for: agent, exactModelRouteID: $0)
    }
    switch agent {
    case .grok, .codex:
      // Executable pin is sufficient for these routes today (argv/stdin shapes are fixed).
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw TatwoLoopJobStateError.invalidPayload(
          "agent_transport_unsupported: \(agent.rawValue) not executable at \(path)")
      }
      return
    case .claude:
      try probeClaudeStdinPrintMode(
        executablePath: path,
        exactModelArgument: exactModelArgument)
    }
  }

  /// Fail closed unless Claude transport is **positively proven**.
  ///
  /// Distinguishes:
  /// - unsupported flag / no stdin `-p` → not capable
  /// - auth/network transient after accepting transport → capable (transport proven)
  /// - ambiguous quick non-zero → **not** capable (no false-positive capability)
  private func probeClaudeStdinPrintMode(
    executablePath: String,
    exactModelArgument: String?
  ) throws {
    #if canImport(Darwin)
    // Minimal probe: spawn `claude -p`, feed a tiny stdin body, demand quick exit
    // with positive transport proof (exit 0 or auth/network class stderr).
    let probeTimeoutSec: TimeInterval = 2.0
    let stdinBody = Data("tatwo-claude-transport-probe\n".utf8)
    var stdinPipe: [Int32] = [0, 0]
    var stderrPipe: [Int32] = [0, 0]
    guard pipe(&stdinPipe) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude probe pipe failed")
    }
    guard pipe(&stderrPipe) == 0 else {
      for fd in [stdinPipe[0], stdinPipe[1]] where fd >= 0 { _ = Darwin.close(fd) }
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude probe stderr pipe failed")
    }
    defer {
      for fd in [stdinPipe[0], stdinPipe[1], stderrPipe[0], stderrPipe[1]] where fd >= 0 {
        _ = Darwin.close(fd)
      }
    }
    var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
    var attr = posix_spawnattr_t(bitPattern: 0)
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude probe spawn init failed")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    guard posix_spawnattr_init(&attr) == 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude probe attr init failed")
    }
    defer { posix_spawnattr_destroy(&attr) }
    _ = posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
    // Discard stdout; capture stderr to classify unsupported-flag vs auth/network.
    _ = posix_spawn_file_actions_addopen(
      &fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    _ = posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
    _ = posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1])
    _ = posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])

    var argv: [UnsafeMutablePointer<CChar>?] = [
      strdup(executablePath),
      strdup("-p"),
    ]
    if let exactModelArgument {
      argv.append(strdup("--model"))
      argv.append(strdup(exactModelArgument))
    }
    argv.append(nil)
    defer {
      for p in argv where p != nil { free(p) }
    }
    // Explicit empty-ish environment (PATH only) so probe does not inherit host secrets.
    var env: [UnsafeMutablePointer<CChar>?] = [
      strdup("PATH=/usr/bin:/bin:/usr/local/bin"),
      strdup("HOME=/tmp"),
      nil,
    ]
    defer {
      for p in env where p != nil { free(p) }
    }

    var child: pid_t = 0
    let rc = executablePath.withCString { exe in
      posix_spawn(&child, exe, &fileActions, &attr, &argv, &env)
    }
    Darwin.close(stdinPipe[0])
    stdinPipe[0] = -1
    Darwin.close(stderrPipe[1])
    stderrPipe[1] = -1
    guard rc == 0, child > 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude probe spawn rc=\(rc)")
    }
    // Feed probe body then close stdin so `cat`-style fakes and real CLIs can finish.
    _ = stdinBody.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return write(stdinPipe[1], base, stdinBody.count)
    }
    Darwin.close(stdinPipe[1])
    stdinPipe[1] = -1

    // Drain stderr concurrently (bounded) so a chatty CLI cannot block on a full pipe.
    let stderrBox = ProbeByteBox()
    let stderrDone = DispatchSemaphore(value: 0)
    let stderrReadFD = stderrPipe[0]
    stderrPipe[0] = -1
    DispatchQueue.global(qos: .utility).async {
      defer {
        _ = Darwin.close(stderrReadFD)
        stderrDone.signal()
      }
      var chunk = [UInt8](repeating: 0, count: 2_048)
      var total = 0
      while total < 16_384 {
        let n = read(stderrReadFD, &chunk, chunk.count)
        if n <= 0 { break }
        stderrBox.append(Data(chunk[0..<n]))
        total += n
      }
    }

    let deadline = Date().addingTimeInterval(probeTimeoutSec)
    var status: Int32 = 0
    var exited = false
    while Date() < deadline {
      let wr = waitpid(child, &status, WNOHANG)
      if wr == child {
        exited = true
        break
      }
      if wr < 0, errno == ECHILD {
        exited = true
        break
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    if !exited {
      // Identity-bound kill only: capture start time, refuse bare pid after mismatch.
      if let identity = ProcessEngineBinding.liveProcessIdentity(pid: child),
        identity.pid == child
      {
        _ = ProcessEngineBinding.signalResidual(identity: identity, signal: SIGKILL)
      }
      // Bounded re-wait only — never hang the probe on a stuck waitpid(0).
      let killDeadline = Date().addingTimeInterval(0.5)
      while Date() < killDeadline {
        let wr = waitpid(child, &status, WNOHANG)
        if wr == child || (wr < 0 && errno == ECHILD) {
          exited = true
          break
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
      if !exited {
        // Parent-owned child: hand to unique late reaper (waitpid only, no bare kill).
        ProcessEngineBinding.LateRootReaper.shared.adopt(
          pid: child,
          identity: ProcessEngineBinding.liveProcessIdentity(pid: child),
          lifecycle: nil)
      }
      _ = stderrDone.wait(timeout: .now() + 0.2)
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude -p stdin probe timed out")
    }
    _ = stderrDone.wait(timeout: .now() + 0.2)
    let stderrText = String(data: stderrBox.data, encoding: .utf8) ?? ""
    try Self.evaluateClaudeProbeOutcome(status: status, stderrText: stderrText)
    #else
    throw TatwoLoopJobStateError.invalidPayload(
      "agent_transport_unsupported: claude probe requires Darwin")
    #endif
  }

  /// Classify Claude probe exit. Capability is declared only on positive proof.
  static func evaluateClaudeProbeOutcome(status: Int32, stderrText: String) throws {
    let termSignal = status & 0o177
    if termSignal != 0, termSignal != 0x7f {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude probe terminated by signal \(termSignal)")
    }
    let exitCode = (status >> 8) & 0xff
    if exitCode == 0 {
      // Positive proof: accepted `-p` and drained promptly.
      return
    }
    let lowered = stderrText.lowercased()
    // Unsupported transport / flag — hard not-capable.
    let unsupportedMarkers = [
      "unknown option",
      "unrecognized option",
      "invalid option",
      "illegal option",
      "unexpected argument",
      "usage:",
      "error: unexpected",
      "not a valid",
      "unknown command",
    ]
    if unsupportedMarkers.contains(where: { lowered.contains($0) }) {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent_transport_unsupported: claude rejects -p/stdin transport")
    }
    // Auth / network class: transport path was accepted; transient failure is OK.
    let authNetworkMarkers = [
      "auth",
      "unauthoriz",
      "login",
      "api key",
      "apikey",
      "token",
      "network",
      "connection",
      "econn",
      "timed out",
      "timeout",
      "rate limit",
      "403",
      "401",
      "502",
      "503",
      "enotfound",
      "could not connect",
      "certificate",
    ]
    if authNetworkMarkers.contains(where: { lowered.contains($0) }) {
      return
    }
    // Ambiguous non-zero: do not claim capability (closes quick non-zero false positive).
    throw TatwoLoopJobStateError.invalidPayload(
      "agent_transport_unsupported: claude probe exit \(exitCode) without transport proof")
  }

  #if canImport(Darwin)
  private final class ProbeByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data {
      lock.lock(); defer { lock.unlock() }
      return storage
    }
    func append(_ chunk: Data) {
      lock.lock(); defer { lock.unlock() }
      storage.append(chunk)
    }
  }
  #endif

  /// Full pin: whitelist path → realpath final target → content digest (create-on-first / verify).
  public func resolvePinnedExecutable(for agent: TatwoRemoteAgentKindV1) throws
    -> TatwoAgentExecutablePinV1
  {
    let allowed = Set(allowedExecutablePaths())
    let candidates = preferredCandidates(for: agent)
    var lastError: Error?
    for raw in candidates {
      let whitelistPath = URL(fileURLWithPath: raw).standardizedFileURL.path
      guard allowed.contains(whitelistPath) else { continue }
      do {
        return try authorizeExecutable(
          whitelistPath: whitelistPath, agent: agent)
      } catch {
        lastError = error
        continue
      }
    }
    if let lastError { throw lastError }
    throw TatwoLoopJobStateError.invalidPayload(
      "agent \(agent.rawValue) executable missing or outside absolute-path whitelist")
  }

  /// Authorize whitelist path: resolve final target, verify/create digest pin, recheck at call site.
  public func authorizeExecutable(
    whitelistPath: String,
    agent: TatwoRemoteAgentKindV1
  ) throws -> TatwoAgentExecutablePinV1 {
    let finalTarget = try Self.finalTargetPath(of: whitelistPath)
    // Final target must also resolve as the same realpath as the whitelist entry itself
    // (blocks symlink that escapes to unapproved binary).
    let allowedFinals = try allowedExecutablePaths().compactMap { path -> String? in
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      return try? Self.finalTargetPath(of: path)
    }
    guard allowedFinals.contains(finalTarget) else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent executable final target not in approved set: \(finalTarget)")
    }
    guard FileManager.default.isExecutableFile(atPath: finalTarget) else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent executable not executable: \(finalTarget)")
    }
    let digest = try Self.contentDigest(of: finalTarget)
    let pin = TatwoAgentExecutablePinV1(
      agent: agent.rawValue,
      whitelistPath: whitelistPath,
      finalTargetPath: finalTarget,
      contentDigest: digest,
      recordedAt: Date())
    try upsertPin(pin)
    return pin
  }

  /// Re-verify pin at launch (content replace / symlink retarget → fail closed).
  public func revalidatePin(_ pin: TatwoAgentExecutablePinV1) throws {
    let finalNow = try Self.finalTargetPath(of: pin.whitelistPath)
    guard finalNow == pin.finalTargetPath else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent executable final target changed; re-authorize required "
          + "(was \(pin.finalTargetPath), now \(finalNow))")
    }
    let digestNow = try Self.contentDigest(of: finalNow)
    guard digestNow == pin.contentDigest else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent executable content digest mismatch; explicit re-authorization required "
          + "(pin \(pin.contentDigest) vs \(digestNow))")
    }
  }

  public static func finalTargetPath(of path: String) throws -> String {
    // Single canonical form (realpath) so pin identity and tests agree on
    // /var vs /private/var firmlink aliases.
    let resolved = TatwoPathCanonical.filePath(path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir),
      !isDir.boolValue
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "executable path missing or directory: \(path)")
    }
    return resolved
  }

  public static func contentDigest(of path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    #if canImport(CryptoKit)
    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "sha256:\(hex)"
    #else
    return TatwoLoopJobDigest.sha256(data)
    #endif
  }

  private func preferredCandidates(for agent: TatwoRemoteAgentKindV1) -> [String] {
    let home = homeDirectoryURL
    switch agent {
    case .grok:
      var list: [String] = []
      if isSafeUnixUserName(realUserName) {
        let isolated = "/Users/\(realUserName)/.codex/bin/grok-isolated"
        if FileManager.default.isExecutableFile(atPath: isolated) {
          list.append(isolated)
        }
      }
      list.append(home.appendingPathComponent(".local/bin/grok").path)
      return list
    case .codex:
      return [home.appendingPathComponent(".local/bin/codex").path]
    case .claude:
      return [home.appendingPathComponent(".local/bin/claude").path]
    }
  }

  private func isSafeUnixUserName(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\0"),
      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
    else {
      return false
    }
    return true
  }

  // MARK: Pin store

  private func loadPins() throws -> [TatwoAgentExecutablePinV1] {
    guard FileManager.default.fileExists(atPath: pinStoreURL.path) else { return [] }
    let data = try Data(contentsOf: pinStoreURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([TatwoAgentExecutablePinV1].self, from: data)
  }

  private func upsertPin(_ pin: TatwoAgentExecutablePinV1) throws {
    var pins = (try? loadPins()) ?? []
    if let idx = pins.firstIndex(where: {
      $0.agent == pin.agent && $0.whitelistPath == pin.whitelistPath
    }) {
      let prior = pins[idx]
      guard prior.finalTargetPath == pin.finalTargetPath,
        prior.contentDigest == pin.contentDigest
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "agent executable pin mismatch for \(pin.agent); explicit re-authorization required "
            + "(stored \(prior.contentDigest) vs \(pin.contentDigest))")
      }
      return
    }
    pins.append(pin)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(pins)
    try FileManager.default.createDirectory(
      at: pinStoreURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try TatwoAtomicFile.write(data, to: pinStoreURL)
  }

  // MARK: - Run

  public func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    try caps.validate()
    let localCaps = caps.clampedForLocalExecution()
    // Production path: use the runner-held bound credential. Do NOT re-bind by pathname.
    let bound = boundWorkPath
    let workForAudit: URL
    do {
      try bound.assertUnchanged()
      workForAudit = URL(fileURLWithPath: try bound.currentPathString(), isDirectory: true)
    } catch {
      return auditAndFail(
        work: bound.path,
        code: "work_path_bind_failed",
        message: error.localizedDescription)
    }

    guard let agent = task.agent ?? defaultAgent else {
      return auditAndFail(
        work: workForAudit,
        code: "agent_unspecified",
        message: "tatwo-loop agent engine requires task.agent or binding defaultAgent")
    }
    guard let exactModelRouteID = task.exactModelRouteID else {
      return auditAndFail(
        work: workForAudit,
        code: "agent_model_route_required",
        message: "tatwo-loop agent engine requires task.exactModelRouteID",
        agent: agent)
    }
    let exactModelArgument: String
    do {
      exactModelArgument = try exactModelLaunchArgument(
        for: agent,
        exactModelRouteID: exactModelRouteID)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: "agent_model_route_invalid",
        message: error.localizedDescription,
        agent: agent)
    }

    let pin: TatwoAgentExecutablePinV1
    do {
      pin = try resolvePinnedExecutable(for: agent)
      try revalidatePin(pin)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: "agent_executable_not_allowed",
        message: error.localizedDescription,
        agent: agent)
    }

    let isolatedEnv: [String: String]
    var expectedActiveSkillSetDigest: String?
    var skillReadbackURL: URL?
    var activeSkillBinding: TatwoActiveSkillLaunchBindingV1?
    var activeSkillsProjectionURL: URL?
    do {
      var activeSkillsRoot: String?
      if let binding = task.activeSkillBinding {
        let verifiedDigest = try binding.verifiedRuntimeDigest()
        let projection = try projectActiveSkills(
          binding,
          agent: agent,
          verifiedDigest: verifiedDigest)
        activeSkillsRoot = projection.root.path
        expectedActiveSkillSetDigest = verifiedDigest
        skillReadbackURL = projection.readback
        activeSkillBinding = binding
        activeSkillsProjectionURL = projection.root
      }
      isolatedEnv = try TatwoAgentLaunchEnvironment.isolated(
        agent: agent,
        isolatedHomesRoot: isolatedHomesRootURL,
        executablePath: pin.launchPath,
        activeSkillsRoot: activeSkillsRoot,
        expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
        skillReadbackPath: skillReadbackURL?.path)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: task.activeSkillBinding == nil
          ? "isolated_home_failed"
          : "agent_skill_projection_failed",
        message: error.localizedDescription,
        agent: agent,
        executablePath: pin.launchPath)
    }

    // Capability declaration and launch both require a bounded transport probe.
    // Executable presence alone is not enough (e.g. Claude without stdin `-p`).
    do {
      try probeTransport(
        for: agent,
        executablePath: pin.launchPath,
        exactModelRouteID: exactModelRouteID)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: "agent_transport_unsupported",
        message: error.localizedDescription,
        agent: agent,
        executablePath: pin.launchPath)
    }

    // Prompt is created under the held dir fd (openat); never pathname write of workPath.
    let promptBytes = Data(task.taskDescription.utf8)
    do {
      try bound.writeFile(name: Self.promptFileName, data: promptBytes)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: "prompt_write_failed",
        message: error.localizedDescription,
        agent: agent,
        executablePath: pin.launchPath)
    }

    // Open prompt via openat under the held dir fd. All agent routes consume this
    // credential as inherited stdin and/or `/dev/fd/N` — never a re-resolved pathname.
    let promptFD: Int32
    do {
      promptFD = try bound.openFileReadOnly(name: Self.promptFileName)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: "prompt_write_failed",
        message: error.localizedDescription,
        agent: agent,
        executablePath: pin.launchPath)
    }
    defer {
      if promptFD >= 0 {
        _ = Darwin.close(promptFD)
      }
    }

    // Clear FD_CLOEXEC so non-stdin routes can open `/dev/fd/N` after spawn inherits it.
    let flags = fcntl(promptFD, F_GETFD)
    if flags >= 0 {
      _ = fcntl(promptFD, F_SETFD, flags & ~FD_CLOEXEC)
    }

    let launch: LaunchPlan
    do {
      launch = try buildLaunch(
        agent: agent,
        exactModelRouteID: exactModelRouteID,
        exactModelArgument: exactModelArgument,
        executablePath: pin.launchPath,
        promptFileDescriptor: promptFD)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: "agent_launch_fd_required",
        message: error.localizedDescription,
        agent: agent,
        executablePath: pin.launchPath)
    }

    appendAudit(
      work: workForAudit,
      code: "agent_launch",
      agent: agent,
      executablePath: pin.launchPath,
      detail:
        "argv_count=\(launch.arguments.count) prompt_fd=\(promptFD) "
        + "stdin=\(launch.usesStdinPrompt) digest=\(pin.contentDigest) "
        + "model_route=\(launch.exactModelRouteID) model_arg=\(launch.modelArgument)"
    )

    // TOCTOU fence: work path identity (fd) must be unchanged at launch.
    do {
      try bound.assertUnchanged()
      try revalidatePin(pin)
    } catch {
      return auditAndFail(
        work: workForAudit,
        code: "work_path_race",
        message: error.localizedDescription,
        agent: agent,
        executablePath: pin.launchPath)
    }

    // No --cwd / -C pathname: posix_spawn fchdir uses the held directory fd.
    // Prompt never re-enters argv as an absolute path (stdin or /dev/fd/N only).
    let processResult = try ProcessEngineBinding.runProcess(
      executablePath: launch.executablePath,
      arguments: launch.arguments,
      boundWorkPath: bound,
      caps: localCaps,
      shouldCancel: shouldCancel,
      standardInputFileDescriptor: launch.usesStdinPrompt ? promptFD : nil,
      environment: isolatedEnv)
    let attestedProcessResult: TatwoLoopEngineResultV1
    if agent == .claude, processResult.failureCode == nil {
      let observation = observeClaudeStream(
        processResult.outputData,
        requestedCanonicalModelID: exactModelRouteID,
        requestedVendorModelID: exactModelArgument)
      let attestation = observation.attestation
      guard attestation.isVerifiedExact else {
        let detail =
          "requested=\(exactModelRouteID)/\(exactModelArgument) "
          + "observed=\(attestation.observedAssistantModelIDs.joined(separator: ",")) "
          + "usage=\(attestation.modelUsageKeys.joined(separator: ",")) "
          + "fallbacks=\(attestation.fallbackEventCount) "
          + "outcome=\(attestation.outcome.rawValue)"
        appendAudit(
          work: workForAudit,
          code: attestation.outcome == .attestationMissing
            ? "agent_model_attestation_missing"
            : "agent_model_route_mismatch",
          agent: agent,
          executablePath: pin.launchPath,
          detail: detail)
        return TatwoLoopEngineResultV1(
          exitCode: -1,
          outputData: Data(),
          outputTruncated: processResult.outputTruncated,
          timedOut: processResult.timedOut,
          cancelled: processResult.cancelled,
          failureCode: attestation.outcome == .attestationMissing
            ? "agent_model_attestation_missing"
            : "agent_model_route_mismatch",
          message: detail,
          modelExecutionAttestation: attestation)
      }
      appendAudit(
        work: workForAudit,
        code: "agent_model_attestation_verified",
        agent: agent,
        executablePath: pin.launchPath,
        detail:
          "requested=\(exactModelRouteID)/\(exactModelArgument) "
          + "observed=\(attestation.observedAssistantModelIDs.joined(separator: ",")) "
          + "usage=\(attestation.modelUsageKeys.joined(separator: ","))")
      attestedProcessResult = TatwoLoopEngineResultV1(
        exitCode: processResult.exitCode,
        outputData: observation.finalOutput,
        outputTruncated: processResult.outputTruncated,
        timedOut: processResult.timedOut,
        cancelled: processResult.cancelled,
        failureCode: processResult.failureCode,
        message: processResult.message,
        modelExecutionAttestation: attestation)
    } else {
      attestedProcessResult = processResult
    }
    guard let expectedActiveSkillSetDigest,
      let skillReadbackURL,
      let activeSkillBinding,
      let projection = activeSkillsProjectionURL
    else {
      return attestedProcessResult
    }
    _ = skillReadbackURL

    do {
      let loadedDigest = try projectedSkillSetDigest(
        projection: projection,
        binding: activeSkillBinding,
        expectedDigest: expectedActiveSkillSetDigest,
        agent: agent)
      return TatwoLoopEngineResultV1(
        exitCode: attestedProcessResult.exitCode,
        outputData: attestedProcessResult.outputData,
        outputTruncated: attestedProcessResult.outputTruncated,
        timedOut: attestedProcessResult.timedOut,
        cancelled: attestedProcessResult.cancelled,
        failureCode: attestedProcessResult.failureCode,
        message: attestedProcessResult.message,
        expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
        actualLoadedSkillSetDigest: loadedDigest,
        modelExecutionAttestation: attestedProcessResult.modelExecutionAttestation)
    } catch let error as SkillProjectionDigestMismatch {
      return TatwoLoopEngineResultV1(
        exitCode: -1,
        outputData: attestedProcessResult.outputData,
        outputTruncated: attestedProcessResult.outputTruncated,
        timedOut: attestedProcessResult.timedOut,
        cancelled: attestedProcessResult.cancelled,
        failureCode: "agent_skill_projection_mismatch",
        message: error.localizedDescription,
        expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
        actualLoadedSkillSetDigest: error.actualDigest,
        modelExecutionAttestation: attestedProcessResult.modelExecutionAttestation)
    } catch {
      return TatwoLoopEngineResultV1(
        exitCode: -1,
        outputData: attestedProcessResult.outputData,
        outputTruncated: attestedProcessResult.outputTruncated,
        timedOut: attestedProcessResult.timedOut,
        cancelled: attestedProcessResult.cancelled,
        failureCode: "agent_skill_projection_mutated",
        message: error.localizedDescription,
        expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
        modelExecutionAttestation: attestedProcessResult.modelExecutionAttestation)
    }
  }

  private struct ClaudeStreamObservation {
    let attestation: TatwoModelExecutionAttestationV1
    let finalOutput: Data
  }

  /// Parse Claude's provider stream instead of trusting the request-side
  /// `--model` argument. Internal helper usage may appear in `modelUsage`; only
  /// exact route models are treated as substantive model switches, while every
  /// assistant event must still be authored by the requested vendor model.
  private func observeClaudeStream(
    _ data: Data,
    requestedCanonicalModelID: String,
    requestedVendorModelID: String
  ) -> ClaudeStreamObservation {
    var observedAssistantModels: [String] = []
    var modelUsageKeys: [String] = []
    var fallbackEventCount = 0
    var finalResult = ""

    for rawLine in data.split(separator: 0x0A) {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(rawLine))
          as? [String: Any],
        let type = object["type"] as? String
      else {
        continue
      }
      switch type {
      case "assistant":
        if let message = object["message"] as? [String: Any],
          let model = normalizedClaudeModelID(message["model"] as? String),
          !observedAssistantModels.contains(model)
        {
          observedAssistantModels.append(model)
        }
      case "result":
        if let result = object["result"] as? String, !result.isEmpty {
          finalResult = result
        }
        if let usage = object["modelUsage"] as? [String: Any] {
          for rawKey in usage.keys.sorted() {
            guard let key = normalizedClaudeModelID(rawKey) else { continue }
            if !modelUsageKeys.contains(key) {
              modelUsageKeys.append(key)
            }
          }
        }
      case "fallback":
        fallbackEventCount += 1
      case "system":
        let subtype = String(describing: object["subtype"] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        if subtype == "model_refusal_fallback" || subtype == "fallback" {
          fallbackEventCount += 1
        }
      default:
        continue
      }
    }

    let primaryRouteModels: Set<String> = [
      "claude-fable-5",
      "claude-opus-5",
      "claude-sonnet-5",
      "claude-haiku-4-5",
    ]
    let unexpectedAssistant = observedAssistantModels.contains {
      $0 != requestedVendorModelID
    }
    let unexpectedPrimaryUsage = modelUsageKeys.contains {
      primaryRouteModels.contains($0) && $0 != requestedVendorModelID
    }
    let outcome: TatwoExactModelOutcomeV1
    if observedAssistantModels.isEmpty || finalResult.isEmpty {
      outcome = .attestationMissing
    } else if unexpectedAssistant || unexpectedPrimaryUsage || fallbackEventCount > 0 {
      outcome = .failClosedMismatch
    } else {
      outcome = .verifiedExact
    }
    let attestation = TatwoModelExecutionAttestationV1(
      requestedCanonicalModelID: requestedCanonicalModelID,
      requestedVendorModelID: requestedVendorModelID,
      observedAssistantModelIDs: observedAssistantModels,
      modelUsageKeys: modelUsageKeys,
      fallbackEventCount: fallbackEventCount,
      outcome: outcome)
    return ClaudeStreamObservation(
      attestation: attestation,
      finalOutput: Data(finalResult.utf8))
  }

  private func normalizedClaudeModelID(_ rawValue: String?) -> String? {
    let value = (rawValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !value.isEmpty else { return nil }
    if let bracket = value.firstIndex(of: "[") {
      return String(value[..<bracket])
    }
    return value
  }

  private struct SkillProjectionDigestMismatch: LocalizedError {
    let actualDigest: String
    let expectedDigest: String

    var errorDescription: String? {
      "active Skill projection digest \(actualDigest) does not match readiness \(expectedDigest)"
    }
  }

  private func projectedSkillSetDigest(
    projection: URL,
    binding: TatwoActiveSkillLaunchBindingV1,
    expectedDigest: String,
    agent: TatwoRemoteAgentKindV1,
    requireNativeSkillsLink: Bool = true
  ) throws -> String {
    if requireNativeSkillsLink {
      try assertNativeSkillsLink(
        home: projection.deletingLastPathComponent().deletingLastPathComponent(),
        agent: agent,
        projection: projection)
    }

    let declaredRepositories = Set(binding.activeSkillRevisions.map(\.repository))
    let children = try FileManager.default.contentsOfDirectory(
      at: projection,
      includingPropertiesForKeys: [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ],
      options: [])
    for child in children {
      let values = try child.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw TatwoLoopJobStateError.invalidPayload(
          "active Skill projection contains a symbolic link")
      }
      if child.lastPathComponent == ".set-activation.lock" {
        guard values.isRegularFile == true else {
          throw TatwoLoopJobStateError.invalidPayload(
            "active Skill projection lock is not a regular file")
        }
        continue
      }
      guard values.isDirectory == true,
        declaredRepositories.contains(child.lastPathComponent)
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "active Skill projection contains repositories outside readiness")
      }
    }

    var projectedRevisions: [TatwoActiveSkillRevisionV1] = []
    projectedRevisions.reserveCapacity(binding.activeSkillRevisions.count)
    for revision in binding.activeSkillRevisions {
      let readback = try TatwoSkilletBundleTransport.readRuntimeRepository(
        runtimeRoot: projection,
        repositoryID: revision.repository)
      guard readback.state == .present, let contentDigest = readback.contentDigest else {
        throw TatwoLoopJobStateError.invalidPayload(
          "active Skill projection is missing \(revision.repository)")
      }
      projectedRevisions.append(
        TatwoActiveSkillRevisionV1(
          repository: revision.repository,
          revision: revision.revision,
          contentDigest: contentDigest))
    }

    let actualDigest = try TatwoActiveSkillSetDigestV1.canonicalDigest(projectedRevisions)
    guard actualDigest == expectedDigest else {
      throw SkillProjectionDigestMismatch(
        actualDigest: actualDigest,
        expectedDigest: expectedDigest)
    }
    return actualDigest
  }

  private func projectActiveSkills(
    _ binding: TatwoActiveSkillLaunchBindingV1,
    agent: TatwoRemoteAgentKindV1,
    verifiedDigest: String
  ) throws -> (root: URL, readback: URL) {
    let home = try TatwoAgentLaunchEnvironment.prepareIsolatedHome(
      agent: agent,
      isolatedHomesRoot: isolatedHomesRootURL)
    let projectionRoot = home.appendingPathComponent(
      Self.activeSkillsProjectionDirectoryName,
      isDirectory: true)
    try TatwoAgentLaunchEnvironment.ensureDirectoryCreateOnly(projectionRoot)
    let projection = projectionRoot.appendingPathComponent(
      "\(verifiedDigest)-\(UUID().uuidString)",
      isDirectory: true)
    try TatwoAgentLaunchEnvironment.ensureDirectoryCreateOnly(projection)

    for revision in binding.activeSkillRevisions {
      let source = binding.runtimeRootURL.appendingPathComponent(
        revision.repository,
        isDirectory: true)
      let destination = projection.appendingPathComponent(
        revision.repository,
        isDirectory: true)
      try copySkillRepository(source: source, destination: destination)
    }

    // Verify both the copied bytes and the source set again. The second source
    // read closes the verify→copy race without exposing a mutable runtime tree.
    _ = try projectedSkillSetDigest(
      projection: projection,
      binding: binding,
      expectedDigest: verifiedDigest,
      agent: agent,
      requireNativeSkillsLink: false)
    guard try binding.verifiedRuntimeDigest() == verifiedDigest else {
      throw TatwoLoopJobStateError.invalidPayload(
        "active Skill runtime changed during immutable projection")
    }

    try installNativeSkillsLink(
      home: home,
      agent: agent,
      projection: projection)

    let readbackDirectory = home.appendingPathComponent(
      Self.skillReadbackDirectoryName,
      isDirectory: true)
    try TatwoAgentLaunchEnvironment.ensureDirectoryCreateOnly(readbackDirectory)
    return (
      projection,
      readbackDirectory.appendingPathComponent(
        "\(UUID().uuidString).sha256",
        isDirectory: false))
  }

  private func copySkillRepository(source: URL, destination: URL) throws {
    let sourceValues = try source.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
      throw TatwoLoopJobStateError.invalidPayload(
        "active Skill source repository is not a regular directory")
    }
    try TatwoAgentLaunchEnvironment.ensureDirectoryCreateOnly(destination)

    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
      at: source,
      includingPropertiesForKeys: Array(keys),
      options: [],
      errorHandler: { _, _ in false })
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "active Skill source repository cannot be enumerated")
    }

    while let item = enumerator.nextObject() as? URL {
      let values = try item.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else {
        throw TatwoLoopJobStateError.invalidPayload(
          "active Skill source contains a symbolic link")
      }
      let relativePath = try relativeSkillPath(item, under: source)
      let target = destination.appendingPathComponent(relativePath, isDirectory: false)
      if values.isDirectory == true {
        try TatwoAgentLaunchEnvironment.ensureDirectoryCreateOnly(target)
      } else if values.isRegularFile == true {
        let parent = target.deletingLastPathComponent()
        try TatwoAgentLaunchEnvironment.ensureDirectoryCreateOnly(parent)
        let data = try Data(contentsOf: item, options: [.uncached])
        try data.write(to: target, options: [.atomic])
        let targetValues = try target.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard targetValues.isRegularFile == true, targetValues.isSymbolicLink != true else {
          throw TatwoLoopJobStateError.invalidPayload(
            "active Skill projection file is not regular")
        }
      } else {
        throw TatwoLoopJobStateError.invalidPayload(
          "active Skill source contains an unsafe non-regular file")
      }
    }
  }

  private func relativeSkillPath(_ item: URL, under root: URL) throws -> String {
    let rootPath = root.standardizedFileURL.path
    let itemPath = item.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard itemPath.hasPrefix(prefix) else {
      throw TatwoLoopJobStateError.invalidPayload(
        "active Skill source escaped repository root")
    }
    let relative = String(itemPath.dropFirst(prefix.count))
    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.isEmpty,
      !relative.hasPrefix("/"),
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "active Skill source contains an unsafe relative path")
    }
    return relative
  }

  private func installNativeSkillsLink(
    home: URL,
    agent: TatwoRemoteAgentKindV1,
    projection: URL
  ) throws {
    let brandDirectoryName: String
    switch agent {
    case .codex: brandDirectoryName = ".codex"
    case .claude: brandDirectoryName = ".claude"
    case .grok: brandDirectoryName = ".grok"
    }
    let brandRoot = home.appendingPathComponent(brandDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: brandRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let link = brandRoot.appendingPathComponent("skills", isDirectory: false)
    if FileManager.default.fileExists(atPath: link.path) {
      let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink == true else {
        throw TatwoLoopJobStateError.invalidPayload(
          "isolated native Skills path conflicts with exact projection")
      }
      if try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        == projection.path
      {
        return
      }
      let replacement = brandRoot.appendingPathComponent(
        ".skills-\(UUID().uuidString)",
        isDirectory: false)
      try FileManager.default.createSymbolicLink(
        at: replacement,
        withDestinationURL: projection)
      if Darwin.rename(replacement.path, link.path) != 0 {
        _ = Darwin.unlink(replacement.path)
        throw TatwoLoopJobStateError.invalidPayload(
          "isolated native Skills projection swap failed")
      }
    } else {
      try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: projection)
    }
  }

  private func assertNativeSkillsLink(
    home: URL,
    agent: TatwoRemoteAgentKindV1,
    projection: URL
  ) throws {
    let brandDirectoryName: String
    switch agent {
    case .codex: brandDirectoryName = ".codex"
    case .claude: brandDirectoryName = ".claude"
    case .grok: brandDirectoryName = ".grok"
    }
    let link = home
      .appendingPathComponent(brandDirectoryName, isDirectory: true)
      .appendingPathComponent("skills", isDirectory: false)
    let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink == true else {
      throw TatwoLoopJobStateError.invalidPayload(
        "isolated native Skills path is not the immutable projection link")
    }
    guard try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        == projection.path
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "isolated native Skills path no longer targets immutable projection")
    }
  }

  // MARK: - Argv construction (no shell)

  private struct LaunchPlan {
    let executablePath: String
    let arguments: [String]
    let usesStdinPrompt: Bool
    let exactModelRouteID: String
    let modelArgument: String
  }

  /// Build argv for the target agent. Prompt content is never shell-interpolated.
  ///
  /// Fail closed: no route may fall back to absolute pathname for prompt or cwd.
  /// cwd is established solely by the held directory fd (`fchdir`); prompt is either
  /// inherited stdin or a controlled inherited `/dev/fd/N` reference.
  private func buildLaunch(
    agent: TatwoRemoteAgentKindV1,
    exactModelRouteID: String,
    exactModelArgument: String,
    executablePath: String,
    promptFileDescriptor: Int32
  ) throws -> LaunchPlan {
    guard promptFileDescriptor >= 0 else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent prompt fd required; pathname prompt is forbidden")
    }
    let devFD = "/dev/fd/\(promptFileDescriptor)"
    // Hard guard: argv must never carry absolute host paths for prompt/cwd rebind.
    func assertNoPathnameRebind(_ args: [String]) throws {
      for arg in args {
        if arg.hasPrefix("/") && !arg.hasPrefix("/dev/fd/") {
          throw TatwoLoopJobStateError.invalidPayload(
            "agent argv pathname rebind forbidden: \(arg)")
        }
        if arg == "--cwd" || arg == "-C" {
          throw TatwoLoopJobStateError.invalidPayload(
            "agent argv must not pass --cwd/-C; cwd is held fd fchdir only")
        }
      }
    }
    let plan: LaunchPlan
    switch agent {
    case .grok:
      // grok --prompt-file /dev/fd/N  (cwd via fchdir; no --cwd)
      plan = LaunchPlan(
        executablePath: executablePath,
        arguments: [
          "--model", exactModelArgument,
          "--prompt-file", devFD,
        ],
        usesStdinPrompt: false,
        exactModelRouteID: exactModelRouteID,
        modelArgument: exactModelArgument)
    case .codex:
      // codex exec -  (prompt via held stdin fd; cwd via fchdir; no -C)
      plan = LaunchPlan(
        executablePath: executablePath,
        arguments: [
          "exec",
          "--model", exactModelArgument,
          "-",
        ],
        usesStdinPrompt: true,
        exactModelRouteID: exactModelRouteID,
        modelArgument: exactModelArgument)
    case .claude:
      // Fail-closed transport: print mode must consume the task prompt from the
      // inherited stdin fd. Never treat "model was asked to Read /dev/fd/N" as
      // transport verification (sandbox/tool may not inherit the fd).
      plan = LaunchPlan(
        executablePath: executablePath,
        arguments: [
          "-p",
          "--model", exactModelArgument,
          "--output-format", "stream-json",
          "--verbose",
          "--no-session-persistence",
        ],
        usesStdinPrompt: true,
        exactModelRouteID: exactModelRouteID,
        modelArgument: exactModelArgument)
    }
    // Grok uses /dev/fd/N; Codex/Claude use stdin. Absolute host pathnames stay forbidden.
    try assertNoPathnameRebind(plan.arguments)
    return plan
  }

  // MARK: - Audit journal

  private func auditAndFail(
    work: URL,
    code: String,
    message: String,
    agent: TatwoRemoteAgentKindV1? = nil,
    executablePath: String? = nil
  ) -> TatwoLoopEngineResultV1 {
    appendAudit(
      work: work,
      code: code,
      agent: agent,
      executablePath: executablePath,
      detail: message)
    return TatwoLoopEngineResultV1(
      exitCode: -1,
      outputData: Data(),
      failureCode: code,
      message: message)
  }

  private func appendAudit(
    work: URL,
    code: String,
    agent: TatwoRemoteAgentKindV1?,
    executablePath: String?,
    detail: String
  ) {
    let entry: [String: String] = [
      "schema": "TatwoAgentEngineJournalEntryV1",
      "code": code,
      "agent": agent?.rawValue ?? "",
      "executablePath": executablePath ?? "",
      "detail": String(TatwoPrivacyRedactor.redacted(detail).prefix(512)),
      "occurredAt": ISO8601DateFormatter().string(from: Date()),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: entry),
      var line = String(data: data, encoding: .utf8)
    else {
      return
    }
    line.append("\n")
    let url = work.appendingPathComponent(Self.auditJournalFileName)
    if FileManager.default.fileExists(atPath: url.path),
      let handle = try? FileHandle(forWritingTo: url)
    {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
    } else {
      try? Data(line.utf8).write(to: url, options: .atomic)
    }
  }
}

/// First-seen content pin for an authorized agent executable final target.
public struct TatwoAgentExecutablePinV1: Codable, Sendable, Equatable {
  public let schema: String
  public let agent: String
  public let whitelistPath: String
  public let finalTargetPath: String
  public let contentDigest: String
  public let recordedAt: Date

  public init(
    schema: String = "TatwoAgentExecutablePinV1",
    agent: String,
    whitelistPath: String,
    finalTargetPath: String,
    contentDigest: String,
    recordedAt: Date
  ) {
    self.schema = schema
    self.agent = agent
    self.whitelistPath = whitelistPath
    self.finalTargetPath = finalTargetPath
    self.contentDigest = contentDigest
    self.recordedAt = recordedAt
  }

  /// Path passed to posix_spawn (final target, not intermediate symlink).
  public var launchPath: String { finalTargetPath }
}

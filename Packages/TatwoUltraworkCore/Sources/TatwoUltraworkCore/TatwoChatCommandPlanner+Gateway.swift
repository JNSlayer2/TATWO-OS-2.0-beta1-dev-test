import CryptoKit
import Darwin
import Foundation

extension TatwoChatCommandPlanner {
  struct GatewayPromptFile {
    let path: String
    let sha256: String
    let utf8Bytes: Int
    let ownership: TatwoChatOwnedTemporaryFile
  }

  static func grokPromptJSON(
    prompt: String,
    imagePaths: [String]
  ) -> String? {
    var blocks: [[String: String]] = [
      [
        "type": "text",
        "text": prompt.isEmpty ? "Describe the attached image." : prompt,
      ]
    ]
    for path in imagePaths {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard let data = try? Data(contentsOf: url),
        !data.isEmpty,
        let mimeType = grokImageMIMEType(for: url)
      else {
        return nil
      }
      blocks.append([
        "type": "image",
        "data": data.base64EncodedString(),
        "mimeType": mimeType,
      ])
    }
    guard JSONSerialization.isValidJSONObject(blocks),
      let data = try? JSONSerialization.data(
        withJSONObject: blocks,
        options: [.sortedKeys, .withoutEscapingSlashes])
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private static func grokImageMIMEType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "png":
      return "image/png"
    case "jpg", "jpeg":
      return "image/jpeg"
    case "gif":
      return "image/gif"
    case "webp":
      return "image/webp"
    default:
      return nil
    }
  }

  typealias GatewayContinuationFile = GatewayPromptFile

  struct GatewayCurrentTurnAuthorityBinding {
    let runID: String
    let turnID: String
    let currentVisibleTurnSHA256: String
    let currentVisibleTurnUTF8Bytes: Int
  }

  static func gatewayCurrentTurnAuthorityBinding(
    runID: String?,
    turnID: String?,
    currentVisibleTurn: String?
  ) -> GatewayCurrentTurnAuthorityBinding? {
    guard let runID = validatedGatewayAuthorityIdentifier(runID),
      let turnID = validatedGatewayAuthorityIdentifier(turnID),
      let currentVisibleTurn,
      !currentVisibleTurn.trimmingCharacters(
        in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    let currentVisibleTurnData = Data(currentVisibleTurn.utf8)
    return GatewayCurrentTurnAuthorityBinding(
      runID: runID,
      turnID: turnID,
      // Hash only the separately retained visible turn. The prompt file
      // contains flattened history and must never become authority input.
      currentVisibleTurnSHA256: sha256Hex(currentVisibleTurnData),
      // Recover the exact visible suffix without trusting prompt markers that
      // untrusted transcript text could forge.
      currentVisibleTurnUTF8Bytes: currentVisibleTurnData.count)
  }

  private static func validatedGatewayAuthorityIdentifier(
    _ value: String?
  ) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 160,
      trimmed.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
        options: .regularExpression) != nil
    else {
      return nil
    }
    return trimmed
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func createGatewayPromptFile(_ prompt: String) -> GatewayPromptFile? {
    let data = Data(prompt.utf8)
    guard !data.isEmpty, data.count <= gatewayPromptMaximumUTF8Bytes else {
      return nil
    }
    let sha256 = sha256Hex(data)
    let temporaryDirectory = FileManager.default.temporaryDirectory

    for _ in 0..<8 {
      let fileURL = temporaryDirectory.appendingPathComponent(
        "\(gatewayPromptFilePrefix)\(UUID().uuidString.lowercased()).txt",
        isDirectory: false)
      let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
      let descriptor = Darwin.open(fileURL.path, flags, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else {
        if errno == EEXIST { continue }
        return nil
      }

      var completed = false
      defer {
        _ = Darwin.close(descriptor)
        if !completed {
          _ = Darwin.unlink(fileURL.path)
        }
      }
      let wroteAllBytes = data.withUnsafeBytes { rawBuffer -> Bool in
        guard let baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
        var offset = 0
        while offset < rawBuffer.count {
          let count = Darwin.write(
            descriptor,
            baseAddress.advanced(by: offset),
            rawBuffer.count - offset)
          if count < 0 {
            if errno == EINTR { continue }
            return false
          }
          guard count > 0 else { return false }
          offset += count
        }
        return true
      }
      var fileInfo = stat()
      guard wroteAllBytes,
        Darwin.fsync(descriptor) == 0,
        Darwin.fstat(descriptor, &fileInfo) == 0,
        fileInfo.st_mode & S_IFMT == S_IFREG
      else {
        return nil
      }
      completed = true
      return GatewayPromptFile(
        path: fileURL.path,
        sha256: sha256,
        utf8Bytes: data.count,
        ownership: TatwoChatOwnedTemporaryFile(
          path: fileURL.path,
          deviceID: UInt64(bitPattern: Int64(fileInfo.st_dev)),
          inode: UInt64(fileInfo.st_ino)))
    }
    return nil
  }

  static func createGatewayContinuationFile(
    _ request: TatwoGatewayContinuationRequestV1
  ) -> GatewayContinuationFile? {
    guard request.isValid else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(request),
      !data.isEmpty,
      data.count <= gatewayContinuationMaximumUTF8Bytes
    else {
      return nil
    }
    return createGatewayOwnedFile(
      data,
      prefix: gatewayContinuationFilePrefix,
      suffix: ".json")
  }

  private static func createGatewayOwnedFile(
    _ data: Data,
    prefix: String,
    suffix: String
  ) -> GatewayPromptFile? {
    guard !data.isEmpty else { return nil }
    let sha256 = sha256Hex(data)
    let temporaryDirectory = FileManager.default.temporaryDirectory

    for _ in 0..<8 {
      let fileURL = temporaryDirectory.appendingPathComponent(
        "\(prefix)\(UUID().uuidString.lowercased())\(suffix)",
        isDirectory: false)
      let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
      let descriptor = Darwin.open(fileURL.path, flags, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else {
        if errno == EEXIST { continue }
        return nil
      }

      var completed = false
      defer {
        _ = Darwin.close(descriptor)
        if !completed {
          _ = Darwin.unlink(fileURL.path)
        }
      }
      let wroteAllBytes = data.withUnsafeBytes { rawBuffer -> Bool in
        guard let baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
        var offset = 0
        while offset < rawBuffer.count {
          let count = Darwin.write(
            descriptor,
            baseAddress.advanced(by: offset),
            rawBuffer.count - offset)
          if count < 0 {
            if errno == EINTR { continue }
            return false
          }
          guard count > 0 else { return false }
          offset += count
        }
        return true
      }
      var fileInfo = stat()
      guard wroteAllBytes,
        Darwin.fsync(descriptor) == 0,
        Darwin.fstat(descriptor, &fileInfo) == 0,
        fileInfo.st_mode & S_IFMT == S_IFREG
      else {
        return nil
      }
      completed = true
      return GatewayPromptFile(
        path: fileURL.path,
        sha256: sha256,
        utf8Bytes: data.count,
        ownership: TatwoChatOwnedTemporaryFile(
          path: fileURL.path,
          deviceID: UInt64(bitPattern: Int64(fileInfo.st_dev)),
          inode: UInt64(fileInfo.st_ino)))
    }
    return nil
  }

  static func claudeMCPConfig(
    appManagementScriptPath: String?,
    appManagementURL: String?,
    computerScriptPath: String?,
    computerURL: String?,
    contractID: String?,
    leaseID: String?,
    runID: String?,
    workspaceRoot: String
  ) -> String? {
    var servers: [String: Any] = [:]
    if let appManagementScriptPath, let appManagementURL {
      servers["tatwo-app"] = [
        "command": "node",
        "args": [appManagementScriptPath],
        "env": ["TATWO_APP_MCP_URL": appManagementURL],
      ]
    }
    if let computerScriptPath, let computerURL, let contractID, let leaseID,
      let runID
    {
      servers["tatwo-computer"] = [
          "command": "node",
          "args": [computerScriptPath],
          "env": [
            "TATWO_COMPUTER_APP_URL": computerURL,
            "TATWO_COMPUTER_CONTRACT_ID": contractID,
            "TATWO_COMPUTER_LEASE_ID": leaseID,
            "TATWO_COMPUTER_RUN_ID": runID,
            "TATWO_COMPUTER_WORKSPACE_ROOT": workspaceRoot,
          ],
      ]
    }
    guard !servers.isEmpty else { return nil }
    let object: [String: Any] = ["mcpServers": servers]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func runtimeAdapterForTurn(
    route: TatwoChatRouteProfile,
    interactionMode: TatwoChatInteractionMode,
    hasImageAttachments: Bool,
    requiresTatwoComputerHost: Bool = false,
    nativeDevelopmentAccess: TatwoNativeDevelopmentAccess = .none,
    preferNativeSubscription: Bool? = nil
  ) -> TatwoChatRuntimeAdapter {
    runtimeRouteDecisionForTurn(
      route: route,
      interactionMode: interactionMode,
      hasImageAttachments: hasImageAttachments,
      requiresTatwoComputerHost: requiresTatwoComputerHost,
      nativeDevelopmentAccess: nativeDevelopmentAccess,
      preferNativeSubscription: preferNativeSubscription).adapter
  }

  public static func runtimeRouteDecisionForTurn(
    route: TatwoChatRouteProfile,
    interactionMode: TatwoChatInteractionMode,
    hasImageAttachments: Bool,
    requiresTatwoComputerHost: Bool = false,
    nativeDevelopmentAccess: TatwoNativeDevelopmentAccess = .none,
    preferNativeSubscription: Bool? = nil
  ) -> TatwoChatRuntimeRouteDecision {
    if preferNativeSubscription == true,
       interactionMode == .standard || interactionMode == .plan,
       !hasImageAttachments,
       !requiresTatwoComputerHost,
       ["gpt-5.6-sol", "opus-5", "fable-5", "grok-build"]
        .contains(route.canonicalModelSlug)
    {
      return .init(adapter: .nativeAgent)
    }
    // A non-nil value is the pre-M2c Work OS governance contract. Only an
    // explicit `true` issued by a real pending PLG dispatch may select the
    // governed nativeAgent route. `nil` is the owner's ordinary Chat
    // workbench and therefore keeps the M2c provider-CLI default even when
    // the visible turn itself asks to read or mutate code.
    if preferNativeSubscription != nil {
      if route.canonicalModelSlug == "minimax-m3" {
        return .init(adapter: .minimaxDirect)
      }
      if route.canonicalModelSlug == "grok-build" {
        return .init(adapter: .grokCLI)
      }
      if route.engine == .claude {
        return .init(adapter: .claudeCLI)
      }
      return .init(adapter: route.runtimeAdapter)
    }
    if route.runtimeAdapter == .gatewayDirect,
       route.engine == .claude,
       interactionMode == .plan || hasImageAttachments || requiresTatwoComputerHost
    {
      return .init(adapter: .claudeCLI)
    }
    if interactionMode == .standard {
      if route.canonicalModelSlug == "minimax-m3" {
        return .init(adapter: .minimaxDirect)
      }
      if route.canonicalModelSlug == "grok-build" { return .init(adapter: .grokCLI) }
      if ["fable-5", "opus-5", "sonnet-5", "haiku-4-5"].contains(route.canonicalModelSlug) {
        return .init(adapter: .claudeCLI)
      }
      if route.canonicalModelSlug.hasPrefix("gpt-") { return .init(adapter: .codexExec) }
    }
    return .init(adapter: route.runtimeAdapter)
  }

  public static func grokExecutablePath(
    bundleURL: URL,
    pathEnvironmentValue: String,
    isExecutableFile: (String) -> Bool = { _ in false }
  ) -> String? {
    if let bundled = bundledExecutablePath(
      for: "grok",
      bundleURL: bundleURL,
      isExecutableFile: isExecutableFile)
    {
      return bundled
    }
    // Development-only fallback. D5 removes this after every installed App
    // is proven self-contained with TatwoGrokVendorRuntime.
    let fallback = resolvedExecutablePath(
      for: "grok",
      pathEnvironmentValue: pathEnvironmentValue,
      isExecutableFile: isExecutableFile)
    return fallback == "grok" ? nil : fallback
  }

  public static func grokIsolatedHomePath(
    environment: [String: String],
    fileManager: FileManager = .default
  ) -> String {
    if let injected = environment["TATWO_NATIVE_GROK_SUBSCRIPTION_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      injected.hasPrefix("/")
    {
      return URL(fileURLWithPath: injected, isDirectory: true)
        .standardizedFileURL.path
    }
    if let appSupport = environment["TATWO_ULTRAWORK_APP_SUPPORT"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      appSupport.hasPrefix("/")
    {
      return URL(fileURLWithPath: appSupport, isDirectory: true)
        .appendingPathComponent("model-subscriptions/grok", isDirectory: true)
        .standardizedFileURL.path
    }
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(
          "Library/Application Support",
          isDirectory: true)
    return applicationSupport
      .appendingPathComponent(
        "Tatwo Ultrawork/model-subscriptions/grok",
        isDirectory: true)
      .standardizedFileURL.path
  }

  public static func isLikelyImagePath(_ path: String) -> Bool {
    if TatwoImageAssetStore.isImageCandidatePath(path) {
      return true
    }
    // UniformTypeIdentifiers can be unavailable in stripped test/runtime
    // environments. Keep the fail-closed attachment gate deterministic so a
    // text-only adapter never silently receives a common image as plain text.
    return Set([
      "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg",
      "png", "tif", "tiff", "webp",
    ]).contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  static func bundledExecutablePath(
    for executable: String,
    bundleURL: URL,
    isExecutableFile: (String) -> Bool
  ) -> String? {
    let helperName: String
    switch executable {
    case "codex":
      helperName = "TatwoSubscriptionRuntime"
    case "claude":
      helperName = "TatwoClaudeSubscriptionRuntime"
    case "grok":
      helperName = "TatwoGrokVendorRuntime"
    default:
      return nil
    }
    let helpers = bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
      .standardizedFileURL
    let bundled = helpers
      .appendingPathComponent(helperName, isDirectory: false)
      .standardizedFileURL
    guard bundled.path.hasPrefix(helpers.path + "/"),
      isExecutableFile(bundled.path)
    else {
      return nil
    }
    return bundled.path
  }

  // Chat/cowork turns spawn `codex`/`claude`/`node` through `/usr/bin/env`,
  // which makes the launcher re-search PATH itself and adds an extra
  // fork+exec hop between this app and the real CLI binary. Resolving the
  // absolute path ourselves (against the exact PATH we already built for the
  // child's environment) lets the caller spawn the real executable directly,
  // removing that indirection as a variable when a GUI-launched turn behaves
  // differently from an identical terminal invocation. Pure/deterministic so
  // it can be unit tested without touching the real filesystem.
  public static func resolvedExecutablePath(
    for executable: String,
    pathEnvironmentValue: String,
    isExecutableFile: (String) -> Bool = { _ in false }
  ) -> String {
    guard !executable.contains("/") else { return executable }
    for segment in pathEnvironmentValue.split(separator: ":", omittingEmptySubsequences: true) {
      guard !segment.isEmpty else { continue }
      let candidate = String(segment) + "/" + executable
      if isExecutableFile(candidate) { return candidate }
    }
    return executable
  }

  public enum AutomaticBridgeRetryPolicy: Sendable, Equatable {
    /// Production default. A command carrying this policy can never create
    /// physical attempt 2, even if the zero-byte checkpoint fires.
    case disabled

    /// Explicit, evidence/config-bound opt-in. The non-empty audit ID is
    /// carried into runtime receipts and authorizes exactly one retry.
    case evidenceGatedSingleRetry(auditID: String)

    public var automaticRetryCount: Int {
      switch self {
      case .disabled:
        return 0
      case .evidenceGatedSingleRetry(let auditID):
        return auditID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? 0
          : 1
      }
    }

    public var auditID: String {
      switch self {
      case .disabled:
        return "default-zero"
      case .evidenceGatedSingleRetry(let auditID):
        let trimmed = auditID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "invalid-empty-audit-id" : trimmed
      }
    }
  }

  // B7 (chat-goalrun-20260708-0935): GUI-spawned `codex exec` chat turns were
  // observed idling with zero stdout bytes for 5+ minutes (every tokio
  // worker parked on a condvar, no network fd ever opened) while an
  // identical argv/env/QoS/stdin-devnull invocation completes in ~4.5s from
  // a terminal, and even from a bare Swift `Process` call outside the .app
  // bundle. B4-B6 already ruled out argv quoting, the `/usr/bin/env` hop,
  // App Nap/QoS, and shell-snapshot forking as the cause, so the remaining
  // variable is specific to being a direct child of this LSUIElement .app
  // bundle. Automatic bridge retry is now default-zero. An auditable
  // per-command `AutomaticBridgeRetryPolicy.evidenceGatedSingleRetry` must
  // explicitly authorize one retry before the evidence gate below can arm.
  // A healthy Codex Chat turn can legitimately stay at zero stdout while the
  // CLI is still reading stdin / loading route context / waiting for the first
  // streamed event.  2026-07-09 live repro: the exact app argv with
  // stdin=/dev/null and plugins disabled returned a valid `thread.started`
  // after ~44s.  Retrying at 25s killed a valid turn and made Chat look broken.
  // Keep this aligned with the Work OS "prove liveness within roughly two
  // minutes" rule instead of treating sub-minute silence as failure.
  public static let zeroByteBridgeCheckpoint: TimeInterval = 120

  // B10 (chat-goalrun-20260708-0935): B9 proved the GUI-launched direct
  // `codex exec` child can sit at 0 stdout long enough that waiting for a
  // retry costs the user a visibly broken turn; one smoke also showed the
  // retry checkpoint was not reliably evidenced. For the single affected
  // route shape (interactive Chat + native Codex exec) start through the
  // already-tested non-`exec` zsh parent immediately, so the real `codex`
  // process is never a direct child of the LSUIElement app. Cowork, CLI,
  // Claude native, and gateway-direct routes keep their native launch path.
  public static func shouldUseInitialBridgeParent(
    mode: TatwoChatCommandMode,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    attempt: Int
  ) -> Bool {
    guard mode == .chat else { return false }
    guard runtimeAdapter == .codexExec else { return false }
    return attempt == 1
  }

  // B11/B17: if changing the immediate parent to zsh is still not enough, use
  // a one-shot launchd submitted job as the process boundary. This is still a
  // temporary, non-persistent job (`launchctl submit`, not a LaunchAgent
  // plist), but the model CLI is spawned by the user's GUI launchd domain
  // instead of by the Tatwo LSUIElement app process tree.
  //
  // B17 extends the same first-principles boundary to native Claude chat:
  // a Sonnet smoke with the exact no-resume argv returned in ~4s from a
  // terminal/minimal-env Process, while the LSUIElement app direct child sat
  // at 0 stdout/stderr until manually killed. That makes process ancestry the
  // next smallest variable to remove; prompt/session/permission flags were
  // already ruled out by the terminal receipt.
  public static func shouldUseLaunchctlSubmitBoundary(
    mode: TatwoChatCommandMode,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    attempt: Int
  ) -> Bool {
    guard mode == .chat else { return false }
    guard runtimeAdapter == .codexExec || runtimeAdapter == .claudeCLI else { return false }
    return attempt == 1
  }

  public static func zeroStdoutExitRuntimeFailureMessage(
    mode: TatwoChatCommandMode,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    terminationStatus: Int32,
    stdoutByteCount: Int,
    hasAssistantVisibleOutput: Bool,
    launchShape: String
  ) -> String? {
    guard mode == .chat else { return nil }
    guard runtimeAdapter == .codexExec || runtimeAdapter == .claudeCLI else { return nil }
    guard terminationStatus == 0 || terminationStatus == 125 else { return nil }
    guard stdoutByteCount == 0 else { return nil }
    guard !hasAssistantVisibleOutput else { return nil }
    if terminationStatus == 125 {
      return "failed Chat route exited 125 with zero stdout bytes via \(launchShape); launchctl job startup was not proven or no exit code was captured. Retry after checking launchctl/job startup, route/session/quota/auth state."
    }
    return "failed Chat route exited 0 with zero stdout bytes via \(launchShape); treating as runtime failure instead of fake completion. Retry after checking launchctl/job startup, route/session/quota/auth state."
  }

  public static let launchctlChatLabelPrefix = "com.tatwo.ultrawork.chat."

  public static func shouldArmZeroByteBridgeRetry(
    mode: TatwoChatCommandMode,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    attempt: Int,
    alreadyBridged: Bool,
    stdoutByteCount: Int,
    elapsedSinceStart: TimeInterval,
    retryPolicy: AutomaticBridgeRetryPolicy = .disabled,
    checkpoint: TimeInterval = zeroByteBridgeCheckpoint
  ) -> Bool {
    guard !alreadyBridged else { return false }
    return shouldAttemptZeroByteBridgeRetry(
      mode: mode,
      runtimeAdapter: runtimeAdapter,
      attempt: attempt,
      stdoutByteCount: stdoutByteCount,
      elapsedSinceStart: elapsedSinceStart,
      retryPolicy: retryPolicy,
      checkpoint: checkpoint)
  }

  public static func shouldAttemptZeroByteBridgeRetry(
    mode: TatwoChatCommandMode,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    attempt: Int,
    stdoutByteCount: Int,
    elapsedSinceStart: TimeInterval,
    retryPolicy: AutomaticBridgeRetryPolicy = .disabled,
    checkpoint: TimeInterval = zeroByteBridgeCheckpoint
  ) -> Bool {
    guard retryPolicy.automaticRetryCount >= attempt else { return false }
    guard mode == .chat else { return false }
    guard runtimeAdapter == .codexExec else { return false }
    guard attempt == 1 else { return false }
    guard stdoutByteCount == 0 else { return false }
    return elapsedSinceStart >= checkpoint
  }

  public static func shouldArmZeroByteFailFast(
    mode: TatwoChatCommandMode,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    attempt: Int,
    launchShape: String,
    retryPolicy: AutomaticBridgeRetryPolicy = .disabled
  ) -> Bool {
    guard mode == .chat else { return false }
    switch runtimeAdapter {
    case .nativeAgent:
      return false
    case .codexExec:
      if attempt == 2 { return true }
      guard attempt == 1,
            launchShape == "launchctl-submit-boundary"
              || launchShape == "bridge-parent-initial"
              || launchShape == "direct"
      else { return false }
      return retryPolicy.automaticRetryCount == 0
    case .claudeCLI:
      // B17: native Claude should stream a system init quickly. If a
      // launchctl-boundary first attempt still produces literally zero
      // stdout bytes past the checkpoint, fail fast instead of letting the
      // generic 10-minute no-output watchdog leave Chat stuck at `...`.
      return attempt == 1 && launchShape == "launchctl-submit-boundary"
    default:
      return false
    }
  }

  // B9 (chat-goalrun-20260708-0935): B8 found that the original
  // `/bin/zsh -c 'exec "$@"' -- <exe> <args...>` bridge did not change
  // anything a stalled turn depends on — `exec` replaces the shell's own
  // process image in place, so the resulting `codex` process keeps the
  // exact same PID *and* PPID the intermediate zsh already had, i.e. it is
  // still a direct child of this .app. This variant instead backgrounds the
  // real command (`"$@" &`), so the exec'd process is a genuinely separate
  // child of the zsh hop — its parent is a plain shell process, not this
  // .app's process directly — while the app-facing zsh process itself stays
  // put for `Process.terminate()`/watchdogs to signal. The trap forwards
  // TERM/INT/HUP to only that child (never to the whole process group), so
  // stopping a turn or the app's own cleanup still reaps the real CLI
  // process instead of orphaning it. Every argument (including free-form
  // chat prompt text) stays a distinct `$@` element — zsh never parses it as
  // shell syntax — so this carries no shell injection risk despite routing
  // through a shell. Pure/deterministic so the exact argv shape is unit
  // testable without spawning a process.
  public static func zeroByteBridgeLaunch(
    executable: String,
    arguments: [String]
  ) -> (executable: String, arguments: [String]) {
    let script = "\"$@\" & child=$!; trap 'kill -TERM \"$child\" 2>/dev/null' TERM INT HUP; wait \"$child\"; exit $?"
    return ("/bin/zsh", ["-c", script, "--", executable] + arguments)
  }

  public static func launchctlSubmitBoundaryLaunch(
    label: String,
    stdoutPath: String,
    stderrPath: String,
    statusPath: String,
    uid: String,
    workingDirectoryPath: String,
    executable: String,
    arguments: [String],
    pollTimeoutSeconds: Int = 900
  ) -> (executable: String, arguments: [String]) {
    let script = """
    label="$1"; stdout="$2"; stderr="$3"; status_file="$4"; uid="$5"; poll_timeout="$6"; shift 6
    working_directory="$1"; shift
    cancel_decision_file="$status_file.cancel-decision"
    terminated=0
    signal_job() { launchctl kill TERM "gui/$uid/$label" >/dev/null 2>&1; }
    bootout_job() { launchctl bootout "gui/$uid/$label" >/dev/null 2>&1; }
    cleanup_only() { signal_job; bootout_job; }
    write_outer_status() { outer_status_tmp="$status_file.outer.$$.tmp"; printf "%s\\n" "$1" > "$outer_status_tmp" 2>/dev/null && mv -f "$outer_status_tmp" "$status_file" 2>/dev/null; }
    wait_for_submitted_status() { attempts=0; while [ "$attempts" -lt 40 ]; do if [ -s "$status_file" ]; then return 0; fi; attempts=$((attempts + 1)); sleep 0.05; done; return 1; }
    onterm() { terminated=1; trap '' TERM INT HUP; cancel_had_formal_success=0; cancel_decision=$(cat "$cancel_decision_file" 2>/dev/null | tr -d '\\r'); if [ "$cancel_decision" = "1" ]; then cancel_had_formal_success=1; fi; signal_job; if wait_for_submitted_status; then submitted_code=$(sed -n '1p' "$status_file" | tr -d '\\r\\n'); if [ "$cancel_had_formal_success" = "1" ]; then if [ "$submitted_code" != "0" ]; then write_outer_status 0; fi; elif [ "$submitted_code" != "143" ]; then write_outer_status 143; fi; else code=143; if [ "$cancel_had_formal_success" = "1" ]; then code=0; fi; write_outer_status "$code"; fi; bootout_job; exit 143; }
    trap onterm TERM INT HUP
    submitted_script='status_file="$1"; cancel_decision_file="$2"; working_directory="$3"; shift 3; cleanup_termination=0; if ! cd -- "$working_directory"; then code=126; status_tmp="$status_file.cwd.$$.tmp"; printf "%s\\n" "$code" > "$status_tmp" 2>/dev/null && mv -f "$status_tmp" "$status_file" 2>/dev/null; exit "$code"; fi; "$@" </dev/null & child=$!; onterm() { cleanup_termination=1; kill -TERM "$child" 2>/dev/null; }; trap onterm TERM INT HUP; wait "$child"; code=$?; if [ "$cleanup_termination" = "1" ]; then cancel_decision=$(cat "$cancel_decision_file" 2>/dev/null | tr -d '"'"'\\r'"'"'); if [ "$cancel_decision" = "1" ]; then code=0; else code=143; fi; fi; printf "%s\\n" "$code" > "$status_file.tmp" 2>/dev/null && mv -f "$status_file.tmp" "$status_file" 2>/dev/null; exit "$code"'
    launchctl submit -l "$label" -o "$stdout" -e "$stderr" -- /bin/sh -c "$submitted_script" sh "$status_file" "$cancel_decision_file" "$working_directory" "$@" || exit $?
    launchctl kickstart "gui/$uid/$label"
    kickstart_code=$?
    if [ "$kickstart_code" -ne 0 ]; then cleanup_only; exit "$kickstart_code"; fi
    if [ "$terminated" = "1" ]; then cleanup_only; exit 143; fi
    started=$(date +%s)
    seen=0
    active_seen=0
    last=""
    zero_pending_since=""
    zero_pending_grace=8
    if [ "$poll_timeout" -lt "$zero_pending_grace" ]; then zero_pending_grace="$poll_timeout"; fi
    while true; do
      if [ -s "$status_file" ]; then
        found=$(sed -n '1p' "$status_file" | tr -d '\\r\\n')
        case "$found" in ''|*[!0-9]*) exit 125 ;; esac
        last="$found"
        break
      fi
      if info=$(launchctl print "gui/$uid/$label" 2>/dev/null); then
        seen=1
      else
        now=$(date +%s)
        if [ "$seen" = "0" ] && [ $((now - started)) -lt 5 ]; then
          sleep 0.05
          continue
        fi
        break
      fi
      # `launchctl print` is a separate observation from the status probe
      # above. The submitted wrapper may publish its authoritative status
      # while `print` is running, so loop back and read it before interpreting
      # an advisory inactive count.
      if [ -s "$status_file" ]; then
        continue
      fi
      active=$(printf '%s\\n' "$info" | awk -F'= ' '/active count =/{print $2; exit}')
      case "$active" in
        ''|*[!0-9]*)
          cleanup_only
          exit 125
          ;;
      esac
      if [ "$active" = "0" ]; then
        now=$(date +%s)
        if [ -z "$zero_pending_since" ]; then
          zero_pending_since="$now"
        fi
        # Time startup convergence from the first trustworthy inactive
        # observation. Wrapper creation may precede the first scheduled
        # `launchctl print` by longer than a small test/diagnostic timeout.
        if [ "$active_seen" = "0" ] && [ $((now - zero_pending_since)) -ge "$poll_timeout" ]; then
          cleanup_only
          exit 124
        fi
        if [ $((now - zero_pending_since)) -ge "$zero_pending_grace" ]; then
          break
        fi
        sleep 0.05
        continue
      fi
      active_seen=1
      zero_pending_since=""
      # `poll_timeout` is a launchd-convergence bound, not a user-turn deadline.
      # A healthy submitted job may run for hours while the App-side inactivity
      # watchdog continues to observe stdout/stderr activity. Never kill an
      # `active count > 0` job merely because total wall-clock time crossed the
      # convergence window.
      sleep 0.2
    done
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1
    if [ -z "$last" ]; then exit 125; fi
    exit "$last"
    """
    return ("/bin/zsh", ["-c", script, "--", label, stdoutPath, stderrPath, statusPath, uid, "\(max(1, pollTimeoutSeconds))", workingDirectoryPath, executable] + arguments)
  }

  public static func launchctlSubmitStaleJobSweepLaunch(
    rootPath: String,
    uid: String,
    currentAppPID: String,
    labelPrefix: String = launchctlChatLabelPrefix
  ) -> (executable: String, arguments: [String]) {
    let script = """
    root="$1"; uid="$2"; current_app_pid="$3"; prefix="$4"
    [ -d "$root" ] || exit 0
    {
      for file in "$root"/spawn-*.jsonl; do
        [ -e "$file" ] || continue
        awk '
          /"launchctlLabel":/ {
            label=$0
            sub(/^.*"launchctlLabel":"?/, "", label)
            sub(/".*$/, "", label)
            pid=$0
            sub(/^.*"pid":"?/, "", pid)
            sub(/".*$/, "", pid)
            if (label != "" && label != "nil") print label "\t" pid
          }
        ' "$file"
      done
      launchctl print "gui/$uid" 2>/dev/null | awk -v prefix="$prefix" '
        index($0, prefix) {
          rest=substr($0, index($0, prefix))
          match(rest, /^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]+/)
          if (RLENGTH > 0) print substr(rest, 1, RLENGTH) "\t"
        }
      '
    } | sort -u | while IFS="$(printf '\\t')" read -r label wrapper_pid; do
      case "$label" in
        "$prefix"*) ;;
        *) continue ;;
      esac
      case "$label" in
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) continue ;;
      esac
      if ! launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        continue
      fi
      case "$wrapper_pid" in
        ''|*[!0123456789]*)
          # Labels discovered only from launchctl print may include a job that
          # was submitted milliseconds ago, before its spawn receipt is fully
          # written. Do not kill ownership-unknown labels from the async
          # pre-turn sweep; a recorded wrapper PID is the ownership receipt.
          continue
          ;;
      esac
      ppid=$(ps -o ppid= -p "$wrapper_pid" 2>/dev/null | tr -d ' ')
      if [ "$ppid" = "$current_app_pid" ]; then
        continue
      fi
      if [ -n "$ppid" ] && [ "$ppid" != "1" ]; then
        continue
      fi
      launchctl kill TERM "gui/$uid/$label" >/dev/null 2>&1
      sleep 0.2
      launchctl bootout "gui/$uid/$label" >/dev/null 2>&1
    done
    exit 0
    """
    return ("/bin/zsh", ["-c", script, "--", rootPath, uid, currentAppPID, labelPrefix])
  }

  public static func redacted(_ text: String) -> String {
    var value = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    value = value.replacingOccurrences(
      of: #"\[Hidden TATWO Ultrawork loopsConfig context[\s\S]*?\[/Hidden TATWO Ultrawork loopsConfig context\]\s*"#,
      with: "<hidden-loops-config> ",
      options: .regularExpression)
    if let home = ProcessInfo.processInfo.environment["HOME"] {
      value = value.replacingOccurrences(of: home, with: "~")
    }
    value = value.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
    value = value.replacingOccurrences(of: #"/(?:private/)?var/folders/[^\s]+"#, with: "/var/folders/…", options: .regularExpression)
    value = value.replacingOccurrences(of: #"/Volumes/[^/\s]+(?:\s[^/\s]+)*/"#, with: "/Volumes/…/", options: .regularExpression)
    return value
  }
}

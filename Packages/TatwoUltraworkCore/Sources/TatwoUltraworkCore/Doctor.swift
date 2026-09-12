import Foundation

public struct DoctorCheck: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let status: InstallState
  public let severity: SafetyLevel
  public let message: String
  public let remediation: String?

  public init(
    id: String, title: String, status: InstallState, severity: SafetyLevel, message: String,
    remediation: String? = nil
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.severity = severity
    self.message = message
    self.remediation = remediation
  }
}

public struct DoctorReport: Codable, Sendable, Equatable {
  public let schema: String
  public let app: String
  public let version: String
  public let generatedAt: Date
  public let summary: String
  public let ok: Bool
  public let coreReady: Bool
  public let sandboxReady: Bool
  public let hostReady: Bool
  public let hostMutationAllowed: Bool
  public let blockingReasons: [String]
  public let checks: [DoctorCheck]

  public init(
    schema: String = "TatwoDoctorReportV1",
    app: String = "Tatwo Ultrawork",
    version: String = "0.1.0",
    generatedAt: Date = Date(),
    summary: String,
    checks: [DoctorCheck]
  ) {
    self.schema = schema
    self.app = app
    self.version = version
    self.generatedAt = generatedAt
    self.summary = summary
    self.checks = checks
    self.coreReady = Self.computeCoreReady(checks)
    self.sandboxReady = Self.computeSandboxReady(checks)
    self.hostReady = Self.computeHostReady(checks)
    self.hostMutationAllowed = false
    self.ok = self.hostReady
    self.blockingReasons = Self.computeBlockingReasons(checks)
  }

  private static func computeCoreReady(_ checks: [DoctorCheck]) -> Bool {
    guard checks.contains(where: { $0.id == "core-catalog" && $0.status == .installed }) else {
      return false
    }
    guard checks.contains(where: { $0.id == "ui-validation-gate" && $0.status == .installed })
    else { return false }
    return !checks.contains { $0.status == .missing && $0.severity == .critical }
  }

  private static func computeSandboxReady(_ checks: [DoctorCheck]) -> Bool {
    computeCoreReady(checks) && !checks.contains { $0.status == .missing && $0.severity >= .high }
  }

  private static func computeHostReady(_ checks: [DoctorCheck]) -> Bool {
    computeSandboxReady(checks)
      && !checks.contains {
        $0.status == .unknown && $0.severity >= .high
      }
  }

  private static func computeBlockingReasons(_ checks: [DoctorCheck]) -> [String] {
    checks.compactMap { check in
      if check.status == .missing && check.severity >= .high {
        return "\(check.id):missing:\(check.message)"
      }
      if check.status == .unknown && check.severity >= .high {
        return "\(check.id):unknown:\(check.message)"
      }
      return nil
    }
  }
}

public enum ChatGPTProMCPDoctorProbe {
  public static func check(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    fileManager: FileManager = .default,
    timeoutSeconds: Int = 12
  ) -> DoctorCheck {
    guard
      let root = candidateRoots(
        environment: environment,
        currentDirectoryPath: currentDirectoryPath
      ).first(where: { hasDoctorScript(at: $0, fileManager: fileManager) })
    else {
      return DoctorCheck(
        id: "chatgpt-pro-mcp",
        title: "ChatGPT Pro MCP",
        status: .missing,
        severity: .critical,
        message: "ChatGPT Pro MCP local repo or npm doctor script was not found",
        remediation:
          "Set CHATGPT_PRO_MCP_ROOT/TATWO_CHATGPT_PRO_MCP_ROOT or place the local chatgpt-pro-mcp repo next to the collaboration workspace")
    }

    return runDoctor(at: root, timeoutSeconds: timeoutSeconds)
  }

  static func candidateRoots(
    environment: [String: String],
    currentDirectoryPath: String
  ) -> [URL] {
    let envCandidates = [
      environment["TATWO_CHATGPT_PRO_MCP_ROOT"],
      environment["CHATGPT_PRO_MCP_ROOT"],
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

    let cwd = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
    let projectRoot = cwd.deletingLastPathComponent().deletingLastPathComponent()
    let localCandidates = [
      cwd.appendingPathComponent("chatgpt-pro-mcp", isDirectory: true),
      cwd.deletingLastPathComponent().appendingPathComponent("chatgpt-pro-mcp", isDirectory: true),
      projectRoot.appendingPathComponent("多模型協作", isDirectory: true)
        .appendingPathComponent("chatgpt-pro-mcp", isDirectory: true),
    ]

    var seen = Set<String>()
    return (envCandidates + localCandidates).filter { url in
      let key = url.standardizedFileURL.path
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
  }

  static func hasDoctorScript(at root: URL, fileManager: FileManager) -> Bool {
    let packageURL = root.appendingPathComponent("package.json")
    guard
      fileManager.fileExists(atPath: packageURL.path),
      let text = try? String(contentsOf: packageURL, encoding: .utf8)
    else { return false }
    return text.contains("\"doctor\"") && text.contains("chatgpt-pro-mcp")
  }

  static func runDoctor(at root: URL, timeoutSeconds: Int) -> DoctorCheck {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.currentDirectoryURL = root
    process.arguments = [
      "perl", "-e", "alarm shift; exec @ARGV", "\(max(timeoutSeconds, 1))",
      "npm", "run", "doctor", "--", "--json",
    ]
    var env = ProcessInfo.processInfo.environment
    env["CHATGPT_PRO_MCP_ALLOW_SUBMIT"] = "0"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return DoctorCheck(
        id: "chatgpt-pro-mcp",
        title: "ChatGPT Pro MCP",
        status: .missing,
        severity: .critical,
        message: "ChatGPT Pro MCP doctor could not start",
        remediation: "Run npm run doctor -- --json inside chatgpt-pro-mcp and fix local Node/npm setup")
    }

    let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let combined = stdoutText + "\n" + stderrText
    let serviceSeen = combined.contains("\"service\": \"chatgpt-pro-mcp\"")
      || combined.contains("\"service\":\"chatgpt-pro-mcp\"")
    let okSeen = combined.contains("\"ok\": true") || combined.contains("\"ok\":true")

    if process.terminationStatus == 0 && serviceSeen && okSeen {
      return DoctorCheck(
        id: "chatgpt-pro-mcp",
        title: "ChatGPT Pro MCP",
        status: .installed,
        severity: .critical,
        message: "local npm doctor passed; Pro MCP is available as guarded research/review lane",
        remediation: nil)
    }

    let timedOut = process.terminationStatus == 14
    return DoctorCheck(
      id: "chatgpt-pro-mcp",
      title: "ChatGPT Pro MCP",
      status: .missing,
      severity: .critical,
      message: timedOut
        ? "ChatGPT Pro MCP doctor timed out"
        : "ChatGPT Pro MCP repo was found but npm doctor did not pass",
      remediation:
        "Run npm run doctor -- --json inside chatgpt-pro-mcp; Tatwo doctor does not mutate login, auth, tokens, or browser profile state")
  }
}

public enum DoctorFactory {
  public static func staticReport(
    catalog: TatwoCatalog = .defaults,
    chatGPTProMCPCheck: DoctorCheck? = nil,
    gatewayLiveStatus: TatwoGatewayLiveStatus? = nil
  ) -> DoctorReport {
    let proMCPCheck = chatGPTProMCPCheck ?? ChatGPTProMCPDoctorProbe.check()
    let gatewayContract = gatewayContractCheck(gatewayLiveStatus)
    let routeHealth = gatewayRouteHealthCheck(gatewayLiveStatus)
    let checks = [
      DoctorCheck(
        id: "core-catalog", title: "核心目錄",
        status: catalog.workModes.count == WorkModeID.allCases.count && catalog.scenarios.count >= 5
          ? .installed : .missing, severity: .critical, message: "S/M/L/XL/XXL、情境、插件 registry 已載入"),
      gatewayContract,
      routeHealth,
      DoctorCheck(
        id: "gateway-thread-continuity", title: "Gateway same-thread continuity", status: .unknown,
        severity: .high,
        message: "direct route smoke 不能證明 Codex App 同一 thread 的跨模型上下文接續",
        remediation: "run the repo same-thread evidence harness; do not treat a new request as same-thread"),
      DoctorCheck(
        id: "ultrawork-contract", title: "Ultrawork contract", status: .unknown, severity: .high,
        message: "S/M/L/XL/XXL 預算與驗證規則在 core 內，實際 fan-out 需另外授權",
        remediation: "run the contract-bound Ultrawork selftest before XL/XXL host rollout"),
      proMCPCheck,
      DoctorCheck(
        id: "colima-sandbox-runner", title: "Colima optional sandbox runner", status: .skipped,
        severity: .medium, message: "Colima 是 L/XL 可選隔離驗證器；缺少時只降級，不阻塞 Tatwo core/doctor",
        remediation:
          "run tatwo-ultrawork colima preflight --json; install/start only after human approval"),
      DoctorCheck(
        id: "safe-memory", title: "GBrain safe memory", status: .installed, severity: .high,
        message: "v1 只允許收據、偏好、權重、契合度、失敗模式；不存 raw log/token/私密路徑"),
      DoctorCheck(
        id: "ui-validation-gate", title: "UI 驗收 gate", status: .installed, severity: .critical,
        message: "UI/UX 沒有視覺證據、hash 與獨立 verifier 不可 pass"),
    ]
    return DoctorReport(
      summary: "sandbox-first wrapper app; host install still requires preflight", checks: checks)
  }

  private static func gatewayContractCheck(_ live: TatwoGatewayLiveStatus?) -> DoctorCheck {
    guard let live else {
      return DoctorCheck(
        id: "gateway-contract", title: "Gateway contract", status: .unknown, severity: .critical,
        message: "需要只讀 live healthz + /v1/models 驗證 model_gateway",
        remediation: "refresh the read-only gateway probe; do not restart or edit host state")
    }
    switch live.runtimeState {
    case .healthy:
      return DoctorCheck(
        id: "gateway-contract", title: "Gateway contract", status: .installed, severity: .critical,
        message: "healthz 正常，catalog 已讀取 \(live.catalogModelCount) 個模型",
        remediation: nil)
    case .degraded:
      return DoctorCheck(
        id: "gateway-contract", title: "Gateway contract", status: .missing, severity: .critical,
        message: live.runtimeSummary,
        remediation: "先修正 health/catalog degraded；Tatwo 不會自動修改 gateway")
    case .unknown:
      return DoctorCheck(
        id: "gateway-contract", title: "Gateway contract", status: .unknown, severity: .critical,
        message: live.runtimeSummary,
        remediation: "重試只讀 gateway probe；不要重啟 gateway")
    }
  }

  private static func gatewayRouteHealthCheck(_ live: TatwoGatewayLiveStatus?) -> DoctorCheck {
    guard let live else {
      return DoctorCheck(
        id: "gateway-route-health", title: "Gateway route health", status: .unknown, severity: .critical,
        message: "尚未讀取 healthz 內嵌 routes；總 health 綠燈不代表每條 route 通過",
        remediation: "refresh route state and inspect has_error / error_kind / last_ok_at")
    }
    switch live.routeState {
    case .healthy:
      return DoctorCheck(
        id: "gateway-route-health", title: "Gateway route health", status: .installed, severity: .critical,
        message: live.directRouteSummary,
        remediation: nil)
    case .degraded:
      return DoctorCheck(
        id: "gateway-route-health", title: "Gateway route health", status: .missing, severity: .critical,
        message: live.directRouteSummary,
        remediation: "保留 degraded；先處理 route error，不要把 gateway 重啟當修復")
    case .unknown:
      return DoctorCheck(
        id: "gateway-route-health", title: "Gateway route health", status: .unknown, severity: .critical,
        message: live.directRouteSummary,
        remediation: "只讀重試 route probe")
    }
  }
}

public struct SandboxPreflightReport: Codable, Sendable, Equatable {
  public let schema: String
  public let mode: WorkModeID
  public let safeToMutateHost: Bool
  public let requiredBeforeHostInstall: [String]
  public let checks: [DoctorCheck]

  public init(
    mode: WorkModeID, safeToMutateHost: Bool, requiredBeforeHostInstall: [String],
    checks: [DoctorCheck]
  ) {
    self.schema = "TatwoSandboxPreflightV1"
    self.mode = mode
    self.safeToMutateHost = safeToMutateHost
    self.requiredBeforeHostInstall = requiredBeforeHostInstall
    self.checks = checks
  }

  public static let defaults = SandboxPreflightReport(
    mode: .xl,
    safeToMutateHost: false,
    requiredBeforeHostInstall: [
      "swift test",
      "swift build --product tatwo-ultrawork",
      "tatwo-ultrawork doctor --json",
      "gateway preflight / post-update-check",
      "open-ultrawork selftest",
      "ChatGPT Pro MCP install/status/bridge health check",
      "redaction scan",
      "backup Codex config/state/cache before any host install",
    ],
    checks: [
      DoctorCheck(
        id: "no-host-config", title: "不改主機 Codex 設定", status: .installed, severity: .critical,
        message: "sandbox preflight 不碰 ~/.codex、signed Codex App bundle 或 LaunchAgent"),
      DoctorCheck(
        id: "temp-workspace", title: "臨時 workspace", status: .unknown, severity: .high,
        message: "實際 sandbox run 應使用臨時 workspace/app data/測試 gateway port"),
      DoctorCheck(
        id: "rollback", title: "回滾點", status: .unknown, severity: .high,
        message: "host install 前必須先備份 config/state/models cache"),
    ]
  )
}

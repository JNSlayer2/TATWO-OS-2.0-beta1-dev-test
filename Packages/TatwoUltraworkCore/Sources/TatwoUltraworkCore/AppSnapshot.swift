import Foundation

public enum TatwoAppPhase: String, Codable, Sendable, CaseIterable, Equatable {
  case appFirstReview = "app_first_review"
  case discussionReady = "discussion_ready"
  case syncDeferred = "sync_deferred"
}

public enum TatwoDashboardSurface: String, Codable, Sendable, CaseIterable, Equatable {
  case usage
  case modes
  case scenarios
  case compatibility
  case plugins
  case workflow
}

public enum TatwoEnvironmentKind: String, Codable, Sendable, CaseIterable, Equatable {
  case app
  case cli
  case skill
  case legacyArchive = "legacy_archive"
  case localRuntime = "local_runtime"
  case mcp
  case plugin
  case receipt
  case safetyGate = "safety_gate"
}

public struct TatwoEnvironmentComponent: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let kind: TatwoEnvironmentKind
  public let status: InstallState
  public let severity: SafetyLevel
  public let surface: TatwoDashboardSurface
  public let healthState: TatwoGatewayHealthState?
  public let plainStatus: String
  public let nextAction: String

  public init(
    id: String,
    title: String,
    kind: TatwoEnvironmentKind,
    status: InstallState,
    severity: SafetyLevel,
    surface: TatwoDashboardSurface,
    healthState: TatwoGatewayHealthState? = nil,
    plainStatus: String,
    nextAction: String
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.status = status
    self.severity = severity
    self.surface = surface
    self.healthState = healthState
    self.plainStatus = TatwoPrivacyRedactor.redacted(
      plainStatus.trimmingCharacters(in: .whitespacesAndNewlines))
    self.nextAction = TatwoPrivacyRedactor.redacted(
      nextAction.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public struct TatwoEnvironmentDashboard: Codable, Sendable, Equatable {
  public let schema: String
  public let readOnly: Bool
  public let liveRefreshRequiresUserAction: Bool
  public let plainSummary: String
  public let components: [TatwoEnvironmentComponent]
  public let blockedUntilReceipts: [String]
  public let safeRefreshCommands: [String]

  public init(
    schema: String = "TatwoEnvironmentDashboardV1",
    readOnly: Bool,
    liveRefreshRequiresUserAction: Bool,
    plainSummary: String,
    components: [TatwoEnvironmentComponent],
    blockedUntilReceipts: [String],
    safeRefreshCommands: [String]
  ) {
    self.schema = schema
    self.readOnly = readOnly
    self.liveRefreshRequiresUserAction = liveRefreshRequiresUserAction
    self.plainSummary = TatwoPrivacyRedactor.redacted(
      plainSummary.trimmingCharacters(in: .whitespacesAndNewlines))
    self.components = components
    self.blockedUntilReceipts = blockedUntilReceipts.map { TatwoPrivacyRedactor.redacted($0) }
    self.safeRefreshCommands = safeRefreshCommands.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct TatwoEnvironmentProbe {
  public let projectRoot: URL
  public let skillRoot: URL
  public let archiveRoot: URL
  public let gatewayRoot: URL?
  public let gatewayLiveStatus: TatwoGatewayLiveStatus?
  public let fileManager: FileManager

  public init(
    projectRoot: URL,
    skillRoot: URL,
    archiveRoot: URL,
    gatewayRoot: URL? = nil,
    gatewayLiveStatus: TatwoGatewayLiveStatus? = nil,
    fileManager: FileManager = .default
  ) {
    self.projectRoot = projectRoot
    self.skillRoot = skillRoot
    self.archiveRoot = archiveRoot
    self.gatewayRoot = gatewayRoot
    self.gatewayLiveStatus = gatewayLiveStatus
    self.fileManager = fileManager
  }

  public static var emptyForTests: TatwoEnvironmentProbe {
    TatwoEnvironmentProbe(
      projectRoot: URL(fileURLWithPath: "/__tatwo_ultrawork_empty_project__"),
      skillRoot: URL(fileURLWithPath: "/__tatwo_ultrawork_empty_skills__"),
      archiveRoot: URL(fileURLWithPath: "/__tatwo_ultrawork_empty_archives__"),
      gatewayRoot: nil
    )
  }

  public static func current(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> TatwoEnvironmentProbe
  {
    let supportRoot = safeSupportRoot(environment: environment)
    let home =
      environment["HOME"].map(URL.init(fileURLWithPath:))
      ?? FileManager.default.homeDirectoryForCurrentUser
    let capabilitySkillRoot = URL(
      fileURLWithPath: TatwoCapabilityRootsV1.current(environment: environment).canonicalSkillRoot,
      isDirectory: true)
    let legacyCodexSkillRoot = home.appendingPathComponent(".codex/skills", isDirectory: true)
    let project =
      environment["TATWO_ULTRAWORK_PROJECT_ROOT"].map(URL.init(fileURLWithPath:))
      ?? supportRoot.appendingPathComponent("project-cache", isDirectory: true)
    let skills =
      environment["TATWO_SKILL_ROOT"].map(URL.init(fileURLWithPath:))
      ?? capabilitySkillRoot
    let archives =
      environment["TATWO_SKILL_ARCHIVE_ROOT"].map(URL.init(fileURLWithPath:))
      ?? supportRoot.appendingPathComponent("skill-archives-cache", isDirectory: true)
    let gateway = environment["MODEL_GATEWAY_DIR"].map(URL.init(fileURLWithPath:))
      ?? discoverGatewayRoot(homeSkillRoot: legacyCodexSkillRoot, fileManager: .default)

    return TatwoEnvironmentProbe(
      projectRoot: project, skillRoot: skills, archiveRoot: archives, gatewayRoot: gateway)
  }

  public func withGatewayLiveStatus(_ status: TatwoGatewayLiveStatus?) -> TatwoEnvironmentProbe {
    TatwoEnvironmentProbe(
      projectRoot: projectRoot,
      skillRoot: skillRoot,
      archiveRoot: archiveRoot,
      gatewayRoot: gatewayRoot,
      gatewayLiveStatus: status,
      fileManager: fileManager
    )
  }

  private static func discoverGatewayRoot(homeSkillRoot: URL, fileManager: FileManager) -> URL? {
    let candidate = homeSkillRoot.appendingPathComponent(
      "codex-app-model-gateway", isDirectory: true)
    let marker = candidate.appendingPathComponent("scripts/post-update-check.sh")
    return fileManager.fileExists(atPath: marker.path) ? candidate : nil
  }

  private static func safeSupportRoot(environment: [String: String]) -> URL {
    if let homePath = environment["HOME"] {
      let base = URL(fileURLWithPath: homePath, isDirectory: true)
        .appendingPathComponent("Library/Application Support", isDirectory: true)
      return TatwoRuntimeLayout.applicationSupportRoot(
        environment: environment,
        applicationSupportBase: base)
    }
    return TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
  }

  private static func pointsToExternalVolume(_ url: URL) -> Bool {
    url.path.hasPrefix("/Volumes/")
      || url.resolvingSymlinksInPath().path.hasPrefix("/Volumes/")
  }
}

public struct TatwoAppSnapshot: Codable, Sendable, Equatable {
  public let schema: String
  public let generatedAt: Date
  public let phase: TatwoAppPhase
  public let selectedMode: WorkModeID
  public let selectedScenario: ScenarioID
  public let hostMutationAllowed: Bool
  public let skillSyncAllowed: Bool
  public let mcpSyncAllowed: Bool
  public let plainSummary: String
  public let catalog: TatwoCatalog
  public let workflow: WorkflowTemplate
  public let workflowPlan: WorkflowRunPlan
  public let workOSDashboard: TatwoWorkOSDashboardSnapshot
  public let teamDashboard: TeamReadinessDashboard
  public let environment: TatwoEnvironmentDashboard
  public let doctor: DoctorReport
  public let sandboxPreflight: SandboxPreflightReport
  public let hostPreflight: HostPreflightReport
  public let hostReceiptFlow: HostReceiptFlow
  public let integrationPlan: IntegrationPlan
  public let stabilityPlan: StabilityPlan
  public let discussionPrompts: [String]
  public let nextBoundaries: [String]

  public init(
    schema: String = "TatwoAppSnapshotV1",
    generatedAt: Date = Date(),
    phase: TatwoAppPhase,
    selectedMode: WorkModeID,
    selectedScenario: ScenarioID,
    hostMutationAllowed: Bool,
    skillSyncAllowed: Bool,
    mcpSyncAllowed: Bool,
    plainSummary: String,
    catalog: TatwoCatalog,
    workflow: WorkflowTemplate,
    workflowPlan: WorkflowRunPlan,
    workOSDashboard: TatwoWorkOSDashboardSnapshot,
    teamDashboard: TeamReadinessDashboard,
    environment: TatwoEnvironmentDashboard,
    doctor: DoctorReport,
    sandboxPreflight: SandboxPreflightReport,
    hostPreflight: HostPreflightReport,
    hostReceiptFlow: HostReceiptFlow,
    integrationPlan: IntegrationPlan,
    stabilityPlan: StabilityPlan,
    discussionPrompts: [String],
    nextBoundaries: [String]
  ) {
    self.schema = schema
    self.generatedAt = generatedAt
    self.phase = phase
    self.selectedMode = selectedMode
    self.selectedScenario = selectedScenario
    self.hostMutationAllowed = hostMutationAllowed
    self.skillSyncAllowed = skillSyncAllowed
    self.mcpSyncAllowed = mcpSyncAllowed
    self.plainSummary = TatwoPrivacyRedactor.redacted(
      plainSummary.trimmingCharacters(in: .whitespacesAndNewlines))
    self.catalog = catalog
    self.workflow = workflow
    self.workflowPlan = workflowPlan
    self.workOSDashboard = workOSDashboard
    self.teamDashboard = teamDashboard
    self.environment = environment
    self.doctor = doctor
    self.sandboxPreflight = sandboxPreflight
    self.hostPreflight = hostPreflight
    self.hostReceiptFlow = hostReceiptFlow
    self.integrationPlan = integrationPlan
    self.stabilityPlan = stabilityPlan
    self.discussionPrompts = discussionPrompts.map { TatwoPrivacyRedactor.redacted($0) }
    self.nextBoundaries = nextBoundaries.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

	public enum TatwoAppSnapshotFactory {
		public static func makeCurrent(
		    environment: [String: String] = ProcessInfo.processInfo.environment,
		    gatewayLiveStatus: TatwoGatewayLiveStatus? = nil
		  ) -> TatwoAppSnapshot {
	    let preferences =
	      (try? TatwoPreferenceStore(fileURL: defaultPreferenceURL(environment: environment)).load())
	      ?? TatwoUserPreferences()
	    let goalRunStore = TatwoGoalRunStore.default(environment: environment)
	    let pluginEntries = TatwoPluginRegistryStore.loadDefaultEntries(environment: environment)
		    return make(
		      preferences: preferences,
		      probe: .current(environment: environment).withGatewayLiveStatus(gatewayLiveStatus),
	      catalog: TatwoCatalog.defaults.replacingPlugins(pluginEntries),
	      goalRunStore: goalRunStore,
	      sessionStore: TatwoSessionStore(directoryURL: goalRunStore.directoryURL),
	      dispatchRegistry: TatwoDispatchRegistry(directoryURL: goalRunStore.directoryURL))
	  }

	  public static func make(
	    preferences: TatwoUserPreferences,
	    probe: TatwoEnvironmentProbe = .current(),
	    catalog: TatwoCatalog = .defaults,
	    goalRunStore: TatwoGoalRunStore? = nil,
	    sessionStore: TatwoSessionStore? = nil,
	    dispatchRegistry: TatwoDispatchRegistry? = nil
	  ) -> TatwoAppSnapshot {
    let mode = preferences.selectedMode
    let scenario = preferences.selectedScenario
    let workflow = WorkflowFactory.make(mode: mode, scenario: scenario)
    let workflowPlan = WorkflowRunFactory.makePlan(
      objective: "Tatwo App-first collaboration review",
      mode: mode,
      scenario: scenario,
      dryRunOnly: true,
      catalog: catalog
    )
	    // Prefer the current OS session's validated, side-effect-free projection (Q1) so the
	    // dashboard reflects canonical GoalRun status/receipts and runtime workers (B2).
	    // A missing pointer may use a planning preview; an existing but invalid pointer must
	    // fail closed and must never be replaced by a synthetic `begin()` contract.
	    let resolvedGoalRunStore = goalRunStore ?? TatwoGoalRunStore.default()
	    let resolvedSessionStore =
	      sessionStore ?? TatwoSessionStore(directoryURL: resolvedGoalRunStore.directoryURL)
	    let resolvedDispatchRegistry =
	      dispatchRegistry ?? TatwoDispatchRegistry(directoryURL: resolvedGoalRunStore.directoryURL)
	    let sessionAttachment: TatwoSessionAttachmentV1?
	    let sessionIntegrityIssue: String?
	    do {
	      sessionAttachment = try resolvedSessionStore.inspectCurrent(
	        goalStore: resolvedGoalRunStore)
	      sessionIntegrityIssue = nil
	    } catch {
	      sessionAttachment = nil
	      sessionIntegrityIssue =
	        "current-session validation failed: \(error.localizedDescription)"
	    }
	    let workOSDashboard: TatwoWorkOSDashboardSnapshot
	    if let sessionIntegrityIssue {
	      workOSDashboard = TatwoWorkOSDashboardFactory.makeSessionIntegrityFailure(
	        mode: mode,
	        scenario: scenario.rawValue,
	        reason: sessionIntegrityIssue)
	    } else {
	      // With no pointer, a side-effect-free control-surface preview remains useful. A
	      // validated pointer always uses its exact stored contract and receipts.
	      let workOSContract =
	        sessionAttachment?.contract
	        ?? (try? WorkOSFactory.preview(
	          mode: mode,
	          scenarioProfileID: scenario.rawValue,
	          objective: "Tatwo dashboard control surface",
	          catalog: catalog))
	        ?? (try! WorkOSFactory.preview(
	          mode: .m,
	          scenarioProfileID: "coding",
	          objective: "Tatwo dashboard control surface fallback",
	          catalog: catalog))
	      let submittedReceiptIDs =
	        sessionAttachment?.goalRecord.receipts.map(\.receiptID) ?? []
	      workOSDashboard = TatwoWorkOSDashboardFactory.make(
	        contract: workOSContract,
	        submittedReceiptIDs: submittedReceiptIDs,
	        registry: resolvedDispatchRegistry)
	    }
    let workOSTruth = makeWorkOSTruthSummary(workOSDashboard)
    let teamDashboard = TeamRoutingCatalog.readinessDashboard(mode: mode, scenario: scenario)
    let environment = makeEnvironmentDashboard(probe: probe)
    let doctor = DoctorFactory.staticReport(
      catalog: catalog,
      gatewayLiveStatus: probe.gatewayLiveStatus
    )
    let hostPreflight = HostPreparationFactory.preflightTemplate()
    let hostReceiptFlow = HostPreparationFactory.receiptFlow()
    let integrationPlan = IntegrationPlanner.makePlan()
    let stabilityPlan = IntegrationPlanner.stabilityPlan()

    return TatwoAppSnapshot(
      phase: .appFirstReview,
      selectedMode: mode,
      selectedScenario: scenario,
      hostMutationAllowed: false,
      skillSyncAllowed: false,
      mcpSyncAllowed: false,
      plainSummary:
        "\(workOSTruth) App-first 只呈現工作流、模型分工、插件/技能、主機安全 gate 與環境缺口；研討完成後才同步 skill 與 MCP。",
      catalog: catalog,
      workflow: workflow,
      workflowPlan: workflowPlan,
      workOSDashboard: workOSDashboard,
      teamDashboard: teamDashboard,
      environment: environment,
      doctor: doctor,
      sandboxPreflight: .defaults,
      hostPreflight: hostPreflight,
      hostReceiptFlow: hostReceiptFlow,
      integrationPlan: integrationPlan,
      stabilityPlan: stabilityPlan,
      discussionPrompts: discussionPrompts(mode: mode, scenario: scenario),
      nextBoundaries: [
        workOSTruth,
        "先用 App 看目前協作流、模型分工、環境健康與缺口，不先改 skill/MCP。",
        "App 研討後若要調整模型權重、驗收 gate、插件觸發條件，先形成 adjustment plan。",
        "最後再同步 tatwo-ultrawork skill 與 MCP schema/tools；沒有 App review 收據前不同步。",
      ]
    )
  }

  private static func makeWorkOSTruthSummary(
    _ dashboard: TatwoWorkOSDashboardSnapshot
  ) -> String {
    if dashboard.sessionIntegrityIssue != nil {
      return
        "Session 驗證受阻：current-session 與 canonical GoalRun 無法建立可信投影；"
        + "未建立替代 Goal、未派發 Loops。"
    }
    let workers = dashboard.runningWorkers
    let queued = workers.filter { $0.status == .queued }.count
    let running = workers.filter { $0.status == .running }.count
    let completed = workers.filter {
      $0.status == .completed || $0.status == .verified
    }.count
    let failed = workers.filter { $0.status == .failed }.count
    let runtimeReceiptCount = workers.compactMap {
      $0.receiptID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }.count

    if failed > 0 {
      return
        "執行受阻：runtime ledger 有 \(failed) 筆失敗；"
        + "\(runtimeReceiptCount) 份 runtime receipt，規劃列與預估 receipt 不算進度。"
    }
    if running > 0 {
      return
        "執行中：\(running) 個 runtime worker；"
        + "\(runtimeReceiptCount == 0 ? "無 runtime receipt" : "\(runtimeReceiptCount) 份 runtime receipt")。"
    }
    if queued > 0 {
      return
        "已派發：\(queued) 個 runtime worker 已排隊、尚未執行；"
        + "\(runtimeReceiptCount == 0 ? "無 runtime receipt" : "\(runtimeReceiptCount) 份 runtime receipt")。"
    }
    if completed > 0 {
      return
        "已有 terminal 產出：\(completed) 個 runtime worker；"
        + "\(runtimeReceiptCount == 0 ? "無 runtime receipt，仍待 receipt gate" : "\(runtimeReceiptCount) 份 runtime receipt，仍待 Goal Judge")。"
    }
    if dashboard.goal.status == .passed && dashboard.receiptRail.missingCount == 0 {
      return "Goal 已通過 receipt gate；App 僅呈現已存證結果，不自行 promotion。"
    }
    return
      "規劃預覽：Goal／Loops／identity rows 只是 contract 投影，尚未派發，"
      + "無 runtime receipt；planned agents、預估輪次與 receipt requirements 不算實際進度。"
  }

  public static func makeEnvironmentDashboard(probe: TatwoEnvironmentProbe = .current())
    -> TatwoEnvironmentDashboard
  {
    let components = environmentComponents(probe: probe)
    let missingCritical = components.filter {
      ($0.status == .missing || $0.status == .unknown) && $0.severity >= .critical
    }
    let summary =
      missingCritical.isEmpty
      ? "App-first 環境盤點可讀；主機實裝仍保持關閉，live refresh 需使用者動作。"
      : "App-first 環境盤點可讀，但仍有 critical unknown/missing，不能進入主機實裝。"
    return TatwoEnvironmentDashboard(
      readOnly: true,
      liveRefreshRequiresUserAction: true,
      plainSummary: summary,
      components: components,
      blockedUntilReceipts: [
        "sandbox evidence bundle",
        "host preflight clear",
        "host backup receipt",
        "rollback receipt",
        "live same-thread smoke receipt",
        "host MCP registration smoke receipt",
        "human approval receipt",
      ],
      safeRefreshCommands: [
        "swift run tatwo-ultrawork doctor --json",
        "swift run tatwo-ultrawork teams dashboard --mode XL --scenario coding --json",
        "swift run tatwo-ultrawork integration stability --json",
        "swift run tatwo-ultrawork colima preflight --json",
        "swift run tatwo-ultrawork colima run --mode XL --scenario coding --objective '<objective>' --dry-run --json",
        "bash scripts/tatwo-ultrawork-sandbox-check.sh",
      ]
    )
  }

  private static func environmentComponents(probe: TatwoEnvironmentProbe)
    -> [TatwoEnvironmentComponent]
  {
    let fm = probe.fileManager
    let project = probe.projectRoot
    let skillRoot = probe.skillRoot
    let archiveRoot = probe.archiveRoot
    let gatewayRoot = probe.gatewayRoot
    let gatewayLiveStatus = probe.gatewayLiveStatus

    let hasProjectPackage = exists(project.appendingPathComponent("Package.swift"), fm)
    let projectScanConnected = hasProjectPackage || !project.lastPathComponent.contains("project-cache")
    let hasMacApp = exists(
      project.appendingPathComponent(
        "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoUltraworkMacApp.swift"), fm)
    let hasMCP = exists(project.appendingPathComponent("scripts/tatwo-ultrawork-mcp.mjs"), fm)
    let hasSandbox = exists(
      project.appendingPathComponent("scripts/tatwo-ultrawork-sandbox-check.sh"), fm)
    let hasRunway = exists(
      project.appendingPathComponent("scripts/tatwo-host-install-runway.mjs"), fm)
    let tatwoSkill = exists(skillRoot.appendingPathComponent("tatwo-ultrawork/SKILL.md"), fm)
    let openActiveHidden = !exists(skillRoot.appendingPathComponent("open-ultrawork/SKILL.md"), fm)
    let gatewayActiveHidden = !exists(
      skillRoot.appendingPathComponent("codex-app-model-gateway/SKILL.md"), fm)
    let openArchive = exists(archiveRoot.appendingPathComponent("open-ultrawork/SKILL.md"), fm)
    let gatewayArchive = exists(
      archiveRoot.appendingPathComponent("codex-app-model-gateway/SKILL.md"), fm)
    let archiveScanConnected =
      openArchive || gatewayArchive || !archiveRoot.lastPathComponent.contains("skill-archives-cache")
    let gatewayPostCheck =
      gatewayRoot.map { exists($0.appendingPathComponent("scripts/post-update-check.sh"), fm) }
      ?? false
    let colima = ColimaSandboxFactory.preflight()

    return [
      component(
        id: "tatwo-app-project",
        title: "App 專案",
        kind: .app,
        status: hasProjectPackage ? .installed : (projectScanConnected ? .missing : .unknown),
        severity: .critical,
        surface: .usage,
        plainStatus: hasProjectPackage
          ? "App / CLI 可共用同一份專案。"
          : (projectScanConnected
            ? "找不到 Package.swift；App 只能顯示降級資訊。"
            : "尚未連接 live repo；App 先顯示安全狀態。"),
        nextAction: hasProjectPackage
          ? "保持 project 作為 App / CLI / MCP 的共同入口。"
          : (projectScanConnected
            ? "先修 App 專案入口，再談 skill/MCP 同步。"
            : "需要完整環境時，由啟動腳本或安裝器授權 live scan。")
      ),
      component(
        id: "tatwo-menu-bar-app",
        title: "工具列 App",
        kind: .app,
        status: hasMacApp ? .installed : (projectScanConnected ? .missing : .unknown),
        severity: .critical,
        surface: .usage,
        plainStatus: hasMacApp
          ? "上方工具列小窗已存在。"
          : (projectScanConnected ? "找不到 TatwoUltraworkMacApp.swift。" : "live repo 未連接；App shell 以目前 bundle 為準。"),
        nextAction: hasMacApp
          ? "保持工具列小窗；大型流程圖只進正常 App 視窗。"
          : (projectScanConnected
            ? "把 snapshot 接進 menu-bar panel，而不是另開大型主視窗。"
            : "若要檢查原始碼，啟用 live scan。")
      ),
      component(
        id: "tatwo-skill",
        title: "主線 skill",
        kind: .skill,
        ok: tatwoSkill,
        severity: .critical,
        surface: .plugins,
        okText: "$tatwo-ultrawork 是目前唯一主線。",
        failText: "找不到主線 skill；不能把舊 skill 復活當主線。",
        next: "最後同步時只同步主線 skill。"
      ),
      component(
        id: "legacy-open-active-hidden",
        title: "open 回滾保護",
        kind: .legacyArchive,
        ok: openActiveHidden,
        severity: .critical,
        surface: .plugins,
        okText: "open-ultrawork 只保留回滾參考，不出現在主線選單。",
        failText: "open-ultrawork 又成為 active skill，會干擾主線。",
        next: "保持封存；只在回滾對照時讀 archive。"
      ),
      component(
        id: "legacy-gateway-active-hidden",
        title: "gateway 回滾保護",
        kind: .legacyArchive,
        ok: gatewayActiveHidden,
        severity: .critical,
        surface: .plugins,
        okText: "model-gateway skill 只保留回滾參考，不出現在主線選單。",
        failText: "model-gateway skill 又成為 active skill，會干擾主線。",
        next: "保持封存；gateway runtime 可留，但主線依 tatwo-ultrawork。"
      ),
      component(
        id: "legacy-open-archive",
        title: "open 回滾封存",
        kind: .legacyArchive,
        status: openArchive ? .installed : (archiveScanConnected ? .missing : .unknown),
        severity: .high,
        surface: .plugins,
        plainStatus: openArchive
          ? "open-ultrawork 封存可供回滾對照。"
          : (archiveScanConnected ? "找不到 open-ultrawork 封存，回滾對照缺資料。" : "封存掃描未連接；不影響目前主線。"),
        nextAction: openArchive
          ? "只做回滾/遷移對照，不再當新工作入口。"
          : (archiveScanConnected ? "補封存只為回滾對照，不恢復 active skill。" : "需要回滾對照時再授權封存掃描。")
      ),
      component(
        id: "legacy-gateway-archive",
        title: "gateway 回滾封存",
        kind: .legacyArchive,
        status: gatewayArchive ? .installed : (archiveScanConnected ? .missing : .unknown),
        severity: .high,
        surface: .plugins,
        plainStatus: gatewayArchive
          ? "model-gateway 封存可供回滾對照。"
          : (archiveScanConnected ? "找不到 model-gateway 封存，回滾對照缺資料。" : "封存掃描未連接；不影響目前主線。"),
        nextAction: gatewayArchive
          ? "保留給回滾與差異對照；不要恢復成 active skill。"
          : (archiveScanConnected ? "補封存只為回滾對照，不恢復 active skill。" : "需要回滾對照時再授權封存掃描。")
      ),
      component(
        id: "model-gateway-runtime",
        title: "模型 gateway",
        kind: .localRuntime,
        status: gatewayLiveStatus?.runtimeState.installState
          ?? (gatewayRoot == nil ? .unknown : .unknown),
        severity: .critical,
        surface: .plugins,
        healthState: gatewayLiveStatus?.runtimeState,
        plainStatus: gatewayLiveStatus?.runtimeSummary
          ?? (gatewayPostCheck
            ? "gateway script 已找到；live health 尚未驗證。"
            : "尚未確認 gateway runtime；不能把 dropdown 當通過。"),
        nextAction: gatewayLiveStatus?.runtimeState == .healthy
          ? "runtime 健康；仍要分開看 route 與 same-thread。"
          : "只讀刷新 gateway health/catalog；不重啟、不改 host 設定。"
      ),
      component(
        id: "gateway-direct-routes",
        title: "Gateway direct routes",
        kind: .localRuntime,
        status: gatewayLiveStatus?.routeState.installState ?? .unknown,
        severity: .critical,
        surface: .plugins,
        healthState: gatewayLiveStatus?.routeState,
        plainStatus: gatewayLiveStatus?.directRouteSummary
          ?? "尚未讀取 route state；總 health 綠燈不代表每條模型路線都通過。",
        nextAction: gatewayLiveStatus?.routeState == .degraded
          ? "保留 degraded；先處理已知 route error，再談 host install。"
          : "只讀確認每條 route 的 last_ok / has_error；不把 direct smoke 當 same-thread。"
      ),
      component(
        id: "gateway-thread-continuity",
        title: "Codex App same-thread",
        kind: .receipt,
        status: .unknown,
        severity: .high,
        surface: .plugins,
        healthState: .unknown,
        plainStatus: "尚未取得同一 Codex App thread 的連續切模收據；direct route PASS 不等於 thread PASS。",
        nextAction: "用 same-thread harness 分類 PASS / expected-fail；不要用新 request 代替同 thread。"
      ),
      component(
        id: "tatwo-mcp-script",
        title: "MCP 腳本",
        kind: .mcp,
        status: hasMCP ? .installed : (projectScanConnected ? .missing : .unknown),
        severity: .high,
        surface: .plugins,
        plainStatus: hasMCP
          ? "MCP stdio 腳本存在；主機註冊尚未放行。"
          : (projectScanConnected ? "找不到 MCP 腳本，agents 尚不能接。" : "live repo 未連接；MCP 原始碼待檢。"),
        nextAction: hasMCP
          ? "App 研討後再同步 MCP schema/tools。"
          : (projectScanConnected ? "補上 MCP script 後再接 agents。" : "需要完整檢查時啟用 live scan。")
      ),
      component(
        id: "sandbox-check",
        title: "沙盒檢查",
        kind: .safetyGate,
        status: hasSandbox ? .installed : (projectScanConnected ? .missing : .unknown),
        severity: .critical,
        surface: .workflow,
        plainStatus: hasSandbox
          ? "沙盒總檢入口存在。"
          : (projectScanConnected ? "找不到沙盒總檢腳本，不能證明先沙盒再實裝。" : "live repo 未連接；沙盒腳本待檢查。"),
        nextAction: hasSandbox
          ? "補齊 sandbox evidence 後才談 host install。"
          : (projectScanConnected ? "補齊 sandbox evidence 後才談 host install。" : "啟用 live scan 或安裝器檢查 sandbox 入口。")
      ),
      component(
        id: "colima-sandbox-runner",
        title: "Colima optional sandbox runner",
        kind: .localRuntime,
        status: colima.status,
        severity: colima.severityIfMissing,
        surface: .workflow,
        plainStatus: colima.available
          ? "Colima/Docker 可見；可作 L/XL 額外隔離驗證，但仍需人工授權才執行。"
          : "Colima/Docker 未就緒；這是可選驗證器，缺少時不阻塞 Tatwo core。",
        nextAction: colima.available
          ? "先跑 colima run --dry-run 留計畫收據；需要實跑時再由人明確允許。"
          : "若之後要更強隔離，再手動安裝/啟動 Colima；目前用既有 sandbox checks。"
      ),
      component(
        id: "host-runway",
        title: "host install runway",
        kind: .safetyGate,
        ok: hasRunway,
        severity: .critical,
        surface: .workflow,
        okText: "host runway 腳本存在，可顯示缺哪些收據。",
        failText: "找不到 host runway，容易裝了才知道缺項。",
        next: "保持 hostMutationAllowed=false，直到 receipt gate 全齊。"
      ),
      TatwoEnvironmentComponent(
        id: "sync-deferred",
        title: "Skill / MCP sync deferred",
        kind: .safetyGate,
        status: .skipped,
        severity: .high,
        surface: .workflow,
        plainStatus: "依使用者指示：先 App 可視化與研討，最後才同步 skill/MCP。",
        nextAction: "App review 形成調整清單後再同步 canonical skill 與 MCP。"
      ),
    ]
  }

  private static func discussionPrompts(mode: WorkModeID, scenario: ScenarioID) -> [String] {
    [
      "目前 \(mode.rawValue) / \(scenario.rawValue) 的主導、監督、顧問、sub、消息、驗收身份組是否太重或太輕？",
      "UI/UX 驗收是否已要求 screenshot / visual diff / checklist / judge，避免 GPT 自己說過就過？",
      "哪些 engine/model 只該做 brain/review/news，不該碰工具或主機？",
      "哪些 plugin/skill 應該固定在 M/L/XL 自動提醒，哪些只在特定情境出現？",
      "目前環境缺哪些收據才可從 sandbox 走到 host install？",
    ]
  }

  private static func defaultPreferenceURL(environment: [String: String]) -> URL {
    if let explicit = environment["TATWO_ULTRAWORK_PREFERENCES"] {
      return URL(fileURLWithPath: explicit)
    }
    if let stateDir = environment["TATWO_ULTRAWORK_STATE_DIR"],
      !stateDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: stateDir, isDirectory: true).appendingPathComponent(
        "preferences.json")
    }
    if let projectRoot = environment["TATWO_ULTRAWORK_PROJECT_ROOT"],
      !projectRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(
        ".tatwo-ultrawork/state/preferences.json")
    }
    let home =
      environment["HOME"].map(URL.init(fileURLWithPath:))
      ?? FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(
      "Library/Application Support/Tatwo Ultrawork/preferences.json")
  }

  private static func exists(_ url: URL, _ fm: FileManager) -> Bool {
    fm.fileExists(atPath: url.path)
  }

  private static func component(
    id: String,
    title: String,
    kind: TatwoEnvironmentKind,
    ok: Bool,
    severity: SafetyLevel,
    surface: TatwoDashboardSurface,
    okText: String,
    failText: String,
    next: String
  ) -> TatwoEnvironmentComponent {
    TatwoEnvironmentComponent(
      id: id,
      title: title,
      kind: kind,
      status: ok ? .installed : .missing,
      severity: severity,
      surface: surface,
      plainStatus: ok ? okText : failText,
      nextAction: next
    )
  }

  private static func component(
    id: String,
    title: String,
    kind: TatwoEnvironmentKind,
    status: InstallState,
    severity: SafetyLevel,
    surface: TatwoDashboardSurface,
    healthState: TatwoGatewayHealthState? = nil,
    plainStatus: String,
    nextAction: String
  ) -> TatwoEnvironmentComponent {
    TatwoEnvironmentComponent(
      id: id,
      title: title,
      kind: kind,
      status: status,
      severity: severity,
      surface: surface,
      healthState: healthState,
      plainStatus: plainStatus,
      nextAction: nextAction
    )
  }
}

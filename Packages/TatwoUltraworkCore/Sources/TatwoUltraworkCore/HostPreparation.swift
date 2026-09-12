import Foundation

public struct HostPreflightCheck: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let status: InstallState
  public let severity: SafetyLevel
  public let plainWhyItMatters: String
  public let verificationHint: String
  public let remediation: String?

  public init(
    id: String,
    title: String,
    status: InstallState,
    severity: SafetyLevel,
    plainWhyItMatters: String,
    verificationHint: String,
    remediation: String? = nil
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.severity = severity
    self.plainWhyItMatters = plainWhyItMatters
    self.verificationHint = verificationHint
    self.remediation = remediation
  }
}

public struct HostPreflightReport: Codable, Sendable, Equatable {
  public let schema: String
  public let readOnly: Bool
  public let hostMutationAllowed: Bool
  public let checks: [HostPreflightCheck]
  public let deniedActions: [String]
  public let requiredBeforeHostInstall: [String]
  public let plainSummary: String

  public init(
    schema: String = "TatwoHostPreflightV1",
    readOnly: Bool,
    hostMutationAllowed: Bool,
    checks: [HostPreflightCheck],
    deniedActions: [String],
    requiredBeforeHostInstall: [String],
    plainSummary: String
  ) {
    self.schema = schema
    self.readOnly = readOnly
    self.hostMutationAllowed = hostMutationAllowed
    self.checks = checks
    self.deniedActions = deniedActions
    self.requiredBeforeHostInstall = requiredBeforeHostInstall
    self.plainSummary = plainSummary
  }
}

public struct HostBackupTarget: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let label: String
  public let sourceHint: String
  public let required: Bool
  public let includeContent: Bool
  public let plainSafetyRule: String

  public init(
    id: String, label: String, sourceHint: String, required: Bool, includeContent: Bool,
    plainSafetyRule: String
  ) {
    self.id = id
    self.label = label
    self.sourceHint = sourceHint
    self.required = required
    self.includeContent = includeContent
    self.plainSafetyRule = plainSafetyRule
  }
}

public struct HostBackupPlanReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let dryRun: Bool
  public let hostMutationAllowed: Bool
  public let humanApprovalRequiredForConfirm: Bool
  public let backupRootHint: String
  public let targets: [HostBackupTarget]
  public let copyCommands: [String]
  public let restoreCommands: [String]
  public let deniedContent: [String]
  public let plainSummary: String

  public init(
    schema: String = "TatwoHostBackupPlanV1",
    dryRun: Bool,
    hostMutationAllowed: Bool,
    humanApprovalRequiredForConfirm: Bool,
    backupRootHint: String,
    targets: [HostBackupTarget],
    copyCommands: [String],
    restoreCommands: [String],
    deniedContent: [String],
    plainSummary: String
  ) {
    self.schema = schema
    self.dryRun = dryRun
    self.hostMutationAllowed = hostMutationAllowed
    self.humanApprovalRequiredForConfirm = humanApprovalRequiredForConfirm
    self.backupRootHint = backupRootHint
    self.targets = targets
    self.copyCommands = copyCommands
    self.restoreCommands = restoreCommands
    self.deniedContent = deniedContent
    self.plainSummary = plainSummary
  }
}

public struct HostLiveSmokePlan: Codable, Sendable, Equatable {
  public let schema: String
  public let hostMutationAllowed: Bool
  public let mustRunAfterBackup: Bool
  public let requiredReceipts: [String]
  public let commands: [String]
  public let failClosedRules: [String]
  public let plainSummary: String

  public init(
    schema: String = "TatwoHostLiveSmokePlanV1",
    hostMutationAllowed: Bool,
    mustRunAfterBackup: Bool,
    requiredReceipts: [String],
    commands: [String],
    failClosedRules: [String],
    plainSummary: String
  ) {
    self.schema = schema
    self.hostMutationAllowed = hostMutationAllowed
    self.mustRunAfterBackup = mustRunAfterBackup
    self.requiredReceipts = requiredReceipts
    self.commands = commands
    self.failClosedRules = failClosedRules
    self.plainSummary = plainSummary
  }
}

public struct HostInstallReceiptSet: Codable, Sendable, Equatable {
  public let schema: String
  public let sandboxValidated: Bool
  public let hostSandboxRehearsalReceiptID: String?
  public let preflightClear: Bool
  public let humanApprovalReceiptID: String?
  public let backupReceiptID: String?
  public let liveSameThreadSmokeReceiptID: String?
  public let mcpRegistrationSmokeReceiptID: String?
  public let rollbackReceiptID: String?

  public init(
    schema: String = "TatwoHostInstallReceiptSetV1",
    sandboxValidated: Bool,
    hostSandboxRehearsalReceiptID: String? = nil,
    preflightClear: Bool,
    humanApprovalReceiptID: String?,
    backupReceiptID: String?,
    liveSameThreadSmokeReceiptID: String?,
    mcpRegistrationSmokeReceiptID: String?,
    rollbackReceiptID: String?
  ) {
    self.schema = schema
    self.sandboxValidated = sandboxValidated
    self.hostSandboxRehearsalReceiptID = Self.clean(hostSandboxRehearsalReceiptID)
    self.preflightClear = preflightClear
    self.humanApprovalReceiptID = Self.clean(humanApprovalReceiptID)
    self.backupReceiptID = Self.clean(backupReceiptID)
    self.liveSameThreadSmokeReceiptID = Self.clean(liveSameThreadSmokeReceiptID)
    self.mcpRegistrationSmokeReceiptID = Self.clean(mcpRegistrationSmokeReceiptID)
    self.rollbackReceiptID = Self.clean(rollbackReceiptID)
  }

  private static func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = TatwoPrivacyRedactor.redacted(
      value.trimmingCharacters(in: .whitespacesAndNewlines))
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct HostInstallGateDecision: Codable, Sendable, Equatable {
  public let schema: String
  public let hostInstallAllowed: Bool
  public let hostMutationPerformed: Bool
  public let blockedBy: [String]
  public let requiredReceipts: [String]
  public let nextActions: [String]
  public let plainSummary: String

  public init(
    schema: String = "TatwoHostInstallGateDecisionV1",
    hostInstallAllowed: Bool,
    hostMutationPerformed: Bool,
    blockedBy: [String],
    requiredReceipts: [String],
    nextActions: [String],
    plainSummary: String
  ) {
    self.schema = schema
    self.hostInstallAllowed = hostInstallAllowed
    self.hostMutationPerformed = hostMutationPerformed
    self.blockedBy = blockedBy
    self.requiredReceipts = requiredReceipts
    self.nextActions = nextActions
    self.plainSummary = plainSummary
  }
}

public struct HostInstallPhase: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let ownerTeam: String
  public let mayMutateHost: Bool
  public let commands: [String]
  public let requiredReceipts: [String]
  public let doneCondition: String
  public let failClosedRule: String

  public init(
    id: String,
    title: String,
    ownerTeam: String,
    mayMutateHost: Bool,
    commands: [String],
    requiredReceipts: [String],
    doneCondition: String,
    failClosedRule: String
  ) {
    self.id = id
    self.title = title
    self.ownerTeam = ownerTeam
    self.mayMutateHost = mayMutateHost
    self.commands = commands
    self.requiredReceipts = requiredReceipts
    self.doneCondition = doneCondition
    self.failClosedRule = failClosedRule
  }
}

public struct HostInstallReceiptSpec: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let ownerTeam: String
  public let producer: String
  public let proves: String
  public let acceptedEvidence: [String]
  public let cannotContain: [String]
  public let blocksHostInstallIfMissing: Bool

  public init(
    id: String,
    title: String,
    ownerTeam: String,
    producer: String,
    proves: String,
    acceptedEvidence: [String],
    cannotContain: [String],
    blocksHostInstallIfMissing: Bool = true
  ) {
    self.id = id
    self.title = title
    self.ownerTeam = ownerTeam
    self.producer = producer
    self.proves = proves
    self.acceptedEvidence = acceptedEvidence
    self.cannotContain = cannotContain
    self.blocksHostInstallIfMissing = blocksHostInstallIfMissing
  }
}

public struct HostReceiptFlow: Codable, Sendable, Equatable {
  public let schema: String
  public let hostMutationDefault: Bool
  public let hostInstallGateIsOnlyDecision: Bool
  public let phases: [HostInstallPhase]
  public let receiptSpecs: [HostInstallReceiptSpec]
  public let stabilityRules: [String]
  public let plainSummary: String

  public init(
    schema: String = "TatwoHostReceiptFlowV1",
    hostMutationDefault: Bool,
    hostInstallGateIsOnlyDecision: Bool,
    phases: [HostInstallPhase],
    receiptSpecs: [HostInstallReceiptSpec],
    stabilityRules: [String],
    plainSummary: String
  ) {
    self.schema = schema
    self.hostMutationDefault = hostMutationDefault
    self.hostInstallGateIsOnlyDecision = hostInstallGateIsOnlyDecision
    self.phases = phases
    self.receiptSpecs = receiptSpecs
    self.stabilityRules = stabilityRules
    self.plainSummary = plainSummary
  }
}

public enum HostPreparationFactory {
  public static func preflightTemplate() -> HostPreflightReport {
    HostPreflightReport(
      readOnly: true,
      hostMutationAllowed: false,
      checks: [
        HostPreflightCheck(
          id: "codex-app-bundle",
          title: "Codex App bundle",
          status: .unknown,
          severity: .critical,
          plainWhyItMatters:
            "最後真實 dropdown 與 app-server 行為只能在主機 App 上 smoke；但不能 patch signed bundle。",
          verificationHint: "只檢查 App 是否存在與版本來源，不寫入 bundle。"
        ),
        HostPreflightCheck(
          id: "codex-cli-path",
          title: "Codex CLI path",
          status: .unknown,
          severity: .critical,
          plainWhyItMatters: "Codex 斷線常見原因是 App bundle binary 與 PATH 上 app-server 版本不同源。",
          verificationHint: "記錄 codex command path；app-server 必須偏向 App bundle 來源。"
        ),
        HostPreflightCheck(
          id: "node",
          title: "Node.js",
          status: .unknown,
          severity: .high,
          plainWhyItMatters: "MCP、gateway smoke 與 host readiness gate 都需要 Node。",
          verificationHint: "command -v node && node --version"
        ),
        HostPreflightCheck(
          id: "swift",
          title: "Swift toolchain",
          status: .unknown,
          severity: .high,
          plainWhyItMatters: "CLI/App build 與 Swift tests 是沙盒驗收基本線。",
          verificationHint: "swift --version"
        ),
        HostPreflightCheck(
          id: "colima-optional-verifier",
          title: "Colima optional verifier",
          status: .unknown,
          severity: .medium,
          plainWhyItMatters: "Colima 可強化 L/XL 沙盒隔離，但不是 Tatwo 必備模型 lane；缺少時只能降級，不能讓專案崩潰。",
          verificationHint:
            "tatwo-ultrawork colima preflight --json；不自動 install/start，不掛 HOME/Secrets"
        ),
        HostPreflightCheck(
          id: "codex-model-provider-single-gateway",
          title: "Codex 單一 model_gateway provider",
          status: .unknown,
          severity: .critical,
          plainWhyItMatters:
            "Tatwo Ultrawork 要包住 gateway 與 ultrawork，但不能讓 Codex thread 在多個 provider 之間斷開；同 thread 只能切 model。",
          verificationHint: "只讀檢查 Codex config 中 model_provider=model_gateway；不得為每個模型建立獨立 provider。"
        ),
        HostPreflightCheck(
          id: "model-gateway-health",
          title: "model_gateway health",
          status: .unknown,
          severity: .critical,
          plainWhyItMatters: "同 thread 多模型切換需要單一 provider；gateway 不健康會造成 dropdown 或 stream 問題。",
          verificationHint: "只讀查 http://127.0.0.1:4177/healthz；不可寫 config。"
        ),
        HostPreflightCheck(
          id: "gateway-route-error-state",
          title: "Gateway route error state",
          status: .unknown,
          severity: .medium,
          plainWhyItMatters:
            "gateway 本身 ok 不代表每條模型路線都乾淨；route 若有 stale error 或從未成功過，host install 前要靠 live same-thread smoke 清掉或說明。",
          verificationHint:
            "只讀解析 /healthz.routes 的 has_error、error_kind、last_ok_at；不讀 raw error，不重啟 gateway。"
        ),
        HostPreflightCheck(
          id: "codex-app-server-version-source",
          title: "Codex app-server 同源",
          status: .unknown,
          severity: .critical,
          plainWhyItMatters: "避免 initialize handshake timed out / reconnect storm。",
          verificationHint: "檢查 app-server/proxy 來源；不 kill process，不重啟。"
        ),
        HostPreflightCheck(
          id: "fast-defaults",
          title: "全模型 fast 預設",
          status: .unknown,
          severity: .high,
          plainWhyItMatters: "速度預設 fast，避免日常切模型時跑成慢速；思考深度則跟隨 Codex App/CLI 或使用者當下選擇。",
          verificationHint:
            "檢查 service_tier=fast；model_reasoning_effort 只作觀測，不作 Tatwo host install blocker。"
        ),
        HostPreflightCheck(
          id: "auto-compact-scope",
          title: "auto-compaction scope",
          status: .unknown,
          severity: .high,
          plainWhyItMatters: "長 thread 不壓縮會撞 context window，表現成卡住或斷線。",
          verificationHint: "檢查 model_auto_compact_token_limit_scope=total 的收據。"
        ),
      ],
      deniedActions: [
        "不得修改 signed Codex App bundle",
        "不得寫入或載入真實 LaunchAgent",
        "不得修改 ~/.codex config/state/models cache",
        "不得讀取或輸出 auth/session/token 內容",
        "不得讓外部模型直接執行 shell 或寫檔",
      ],
      requiredBeforeHostInstall: [
        "sandbox evidence bundle",
        "host sandbox rehearsal receipt",
        "host preflight receipt",
        "host backup receipt",
        "human approval receipt",
        "live same-thread smoke receipt",
        "host MCP registration smoke receipt",
        "rollback receipt",
      ],
      plainSummary: "主機接入前只做讀取與收據；任何會改 Codex/App/gateway 狀態的動作都留到備份與人工授權後。"
    )
  }

  public static func backupPlan() -> HostBackupPlanReceipt {
    let backupRoot = "$HOME/.codex/backups/tatwo-ultrawork-$TS"
    let targets = [
      HostBackupTarget(
        id: "codex-config", label: "Codex config", sourceHint: "$HOME/.codex/config.toml",
        required: true, includeContent: true, plainSafetyRule: "只備份設定檔；不包含登入憑證。"),
      HostBackupTarget(
        id: "codex-state-db", label: "Codex state database",
        sourceHint: "$HOME/.codex/state_5.sqlite", required: true, includeContent: true,
        plainSafetyRule: "只在本機備份，不提交 GitHub。"),
      HostBackupTarget(
        id: "codex-models-cache", label: "Codex models cache",
        sourceHint: "$HOME/.codex/models_cache.json", required: false, includeContent: true,
        plainSafetyRule: "可還原 dropdown cache；不當真相來源。"),
      HostBackupTarget(
        id: "codex-global-state", label: "Codex global state",
        sourceHint: "$HOME/.codex-global-state.json", required: false, includeContent: true,
        plainSafetyRule: "用於 sidebar/project grouping 回復；不輸出內容到報告。"),
      HostBackupTarget(
        id: "gateway-launchagent-plist", label: "model gateway LaunchAgent plist",
        sourceHint: "$HOME/Library/LaunchAgents/com.$USER.codex-model-gateway.plist",
        required: false, includeContent: true, plainSafetyRule: "只備份 plist；不得直接改寫或載入。"),
      HostBackupTarget(
        id: "tatwo-app-data", label: "Tatwo Ultrawork app data",
        sourceHint: "$HOME/Library/Application Support/Tatwo Ultrawork", required: false,
        includeContent: true, plainSafetyRule: "只保存偏好/收據；不得包含 raw log 或私密路徑。"),
    ]

    return HostBackupPlanReceipt(
      dryRun: true,
      hostMutationAllowed: false,
      humanApprovalRequiredForConfirm: true,
      backupRootHint: backupRoot,
      targets: targets,
      copyCommands: [
        "TS=$(date +%Y%m%d-%H%M%S); mkdir -p \(backupRoot)",
        "cp \"$HOME/.codex/config.toml\" \"\(backupRoot)/config.toml\"",
        "cp \"$HOME/.codex/state_5.sqlite\" \"\(backupRoot)/state_5.sqlite\"",
        "cp \"$HOME/.codex/models_cache.json\" \"\(backupRoot)/models_cache.json\" 2>/dev/null || true",
        "cp \"$HOME/.codex-global-state.json\" \"\(backupRoot)/codex-global-state.json\" 2>/dev/null || true",
        "cp \"$HOME/Library/LaunchAgents/com.$USER.codex-model-gateway.plist\" \"\(backupRoot)/codex-model-gateway.plist\" 2>/dev/null || true",
      ],
      restoreCommands: [
        "cp \"<backup>/config.toml\" \"$HOME/.codex/config.toml\"",
        "cp \"<backup>/state_5.sqlite\" \"$HOME/.codex/state_5.sqlite\"",
        "cp \"<backup>/models_cache.json\" \"$HOME/.codex/models_cache.json\" 2>/dev/null || true",
        "cp \"<backup>/codex-global-state.json\" \"$HOME/.codex-global-state.json\" 2>/dev/null || true",
        "cp \"<backup>/codex-model-gateway.plist\" \"$HOME/Library/LaunchAgents/com.$USER.codex-model-gateway.plist\" 2>/dev/null || true",
      ],
      deniedContent: [
        "auth.json",
        "raw logs",
        "browser profiles/cookies/localStorage",
        "private thread ids or full rollout content",
        "API keys or provider secrets",
      ],
      plainSummary: "預設只產生 dry-run 備份計畫；真正 copy 需要人類授權，不備份登入憑證或可重放 session。"
    )
  }

  public static func liveSmokePlan() -> HostLiveSmokePlan {
    HostLiveSmokePlan(
      hostMutationAllowed: false,
      mustRunAfterBackup: true,
      requiredReceipts: [
        "doctor --json receipt",
        "gateway same-thread smoke receipt",
        "host MCP registration smoke receipt",
        "post-install rollback receipt",
      ],
      commands: [
        "tatwo-ultrawork doctor --json",
        "MODEL_GATEWAY_DIR=<gateway-dir> bash <gateway-dir>/scripts/post-update-check.sh --full",
        "node scripts/tatwo-ultrawork-mcp-smoke.mjs",
        "node scripts/tatwo-host-readiness-gate.mjs --latest",
      ],
      failClosedRules: [
        "same-thread smoke skipped is not pass",
        "MCP registration smoke skipped is not pass",
        "backend auth/quota/session issues must become visible completed notices, not retry storms",
        "任何 reconnect/stream disconnect 風險未解前不實裝",
      ],
      plainSummary: "主機 smoke 是實裝前後的最後 gate；必須證明同 thread 切模型與 MCP 入口可用，且沒有 Codex retry/斷線型錯誤。"
    )
  }

  public static func receiptFlow() -> HostReceiptFlow {
    let secretWords = [
      "auth/session/token",
      "raw logs",
      "browser profile/cookies",
      "private thread ids",
      "local absolute paths in public output",
    ]
    return HostReceiptFlow(
      hostMutationDefault: false,
      hostInstallGateIsOnlyDecision: true,
      phases: [
        HostInstallPhase(
          id: "sandbox-evidence",
          title: "沙盒證據包",
          ownerTeam: "環境穩定團隊 + Codex executor",
          mayMutateHost: false,
          commands: [
            "MODEL_GATEWAY_DIR=<gateway-dir> OPEN_ULTRAWORK_DIR=<open-ultrawork-dir> bash scripts/tatwo-ultrawork-sandbox-check.sh",
            "node scripts/tatwo-host-readiness-gate.mjs --latest",
          ],
          requiredReceipts: [
            "sandbox validated receipt", "redaction scan", "mcp adversarial smoke",
          ],
          doneCondition: "sandboxValidated=true，且 hostInstallAllowed 仍然是 false。",
          failClosedRule: "沙盒缺任何必要 log，就不進主機實裝。"
        ),
        HostInstallPhase(
          id: "host-readonly-preflight",
          title: "主機只讀 preflight",
          ownerTeam: "環境穩定團隊",
          mayMutateHost: false,
          commands: ["node scripts/tatwo-host-preflight.mjs --json"],
          requiredReceipts: ["host preflight receipt"],
          doneCondition:
            "critical/high unknown 皆有明確處理方式；model_provider 仍是單一 model_gateway；gateway route error state 已可觀測；不讀 token，不 kill process。",
          failClosedRule:
            "Codex App/CLI/gateway/app-server 任一 critical unknown 未解，或 route error 未經 live smoke 清掉/說明，就不安裝。"
        ),
        HostInstallPhase(
          id: "host-sandbox-rehearsal",
          title: "主機實裝沙盒演練",
          ownerTeam: "環境穩定團隊 + Codex executor",
          mayMutateHost: false,
          commands: [
            "node scripts/tatwo-host-sandbox-rehearsal.mjs --json"
          ],
          requiredReceipts: ["host sandbox rehearsal receipt"],
          doneCondition:
            "在 fake HOME/CODEX_HOME 內完成備份、MCP 註冊演練、stdio smoke、rollback hash 還原；realHostMutationPerformed=false。",
          failClosedRule: "演練未通過或報告出現私密路徑/token，就不准進入真實 host install。"
        ),
        HostInstallPhase(
          id: "backup-and-rollback",
          title: "備份與回滾收據",
          ownerTeam: "Human + Codex executor",
          mayMutateHost: false,
          commands: [
            "TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json",
            "node scripts/tatwo-host-rollback-plan.mjs --backup-dir <backup-dir> --json",
          ],
          requiredReceipts: ["host backup receipt", "rollback receipt"],
          doneCondition: "備份檔在本機存在，rollback plan 可指出每個還原目標。",
          failClosedRule: "沒有備份或 rollback receipt，即使測試全綠也不准 host mutation。"
        ),
        HostInstallPhase(
          id: "host-smoke",
          title: "主機 live smoke",
          ownerTeam: "環境穩定團隊 + Codex executor",
          mayMutateHost: false,
          commands: [
            "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
            "node scripts/tatwo-host-mcp-registration-smoke.mjs --expect-host-registration --host-config \"$HOME/.codex/config.toml\" --json",
          ],
          requiredReceipts: [
            "gateway same-thread smoke receipt", "host MCP registration smoke receipt",
          ],
          doneCondition: "同一 thread 能 GPT → 外部模型 → GPT，MCP tools/list 與工具呼叫可用。",
          failClosedRule: "same-thread 或 MCP host registration 只能 plan/dry-run 時，不得當成主機已實裝。"
        ),
        HostInstallPhase(
          id: "human-gated-install",
          title: "人工 gate 後才實裝",
          ownerTeam: "Human + Codex executor",
          mayMutateHost: true,
          commands: [
            "tatwo-ultrawork host install-gate --sandbox-validated --host-rehearsal <id> --preflight-clear --human-approval <id> --backup-receipt <id> --same-thread-smoke <id> --mcp-registration-smoke <id> --rollback-receipt <id> --json"
          ],
          requiredReceipts: ["all required receipts"],
          doneCondition: "install-gate 只允許進入人工實裝步驟；gate 本身仍不寫主機。",
          failClosedRule: "缺任一收據就 blocked；不使用 watcher、不 patch signed App。"
        ),
      ],
      receiptSpecs: [
        HostInstallReceiptSpec(
          id: "sandbox-validated", title: "Sandbox validated receipt", ownerTeam: "環境穩定團隊",
          producer: "scripts/tatwo-ultrawork-sandbox-check.sh + readiness gate",
          proves: "專案在沙盒內 build/test/MCP/redaction 全部可重跑。",
          acceptedEvidence: [
            "host-readiness-gate.log status=passed", "swift-test.log", "mcp-adversarial-smoke.log",
          ], cannotContain: secretWords),
        HostInstallReceiptSpec(
          id: "host-sandbox-rehearsal", title: "Host sandbox rehearsal receipt",
          ownerTeam: "環境穩定團隊", producer: "scripts/tatwo-host-sandbox-rehearsal.mjs",
          proves: "真實主機前，先在 fake HOME/CODEX_HOME 內演練 MCP 註冊、備份與 rollback，證明流程不會一裝就崩。",
          acceptedEvidence: [
            "passed=true", "realHostMutationPerformed=false", "rollbackValidated=true",
            "mcpCompatibilityPassed=true", "liveSameThreadReceiptProduced=false",
          ], cannotContain: secretWords),
        HostInstallReceiptSpec(
          id: "preflight-clear", title: "Host preflight clear receipt", ownerTeam: "環境穩定團隊",
          producer: "scripts/tatwo-host-preflight.mjs",
          proves: "主機只讀盤點無未處理 critical/high unknown，且 gateway route error state 可觀測。",
          acceptedEvidence: [
            "failedCriticalCheckIDs=[]",
            "unknownHighOrCriticalCheckIDs=[] or acknowledged non-blocker",
            "gateway-route-error-state observed",
          ], cannotContain: secretWords),
        HostInstallReceiptSpec(
          id: "human-approval", title: "Human approval receipt", ownerTeam: "Human",
          producer: "人類明確輸入本次授權 ID", proves: "人類知道將進入 host install，而且接受備份/回滾策略。",
          acceptedEvidence: ["short approval id", "timestamp", "scope"], cannotContain: secretWords),
        HostInstallReceiptSpec(
          id: "host-backup", title: "Host backup receipt", ownerTeam: "Human + Codex executor",
          producer: "scripts/tatwo-host-backup-plan.mjs --confirm",
          proves: "Codex config/state/cache 已本機備份，且不含 auth/session。",
          acceptedEvidence: ["backupExecuted=true", "backupRootHint", "executedCopies"],
          cannotContain: secretWords),
        HostInstallReceiptSpec(
          id: "same-thread-smoke", title: "Gateway same-thread smoke receipt", ownerTeam: "環境穩定團隊",
          producer: "scripts/tatwo-host-same-thread-smoke.mjs --run",
          proves: "Codex App/gateway 同 thread 切模型不斷線。",
          acceptedEvidence: [
            "sameThreadSmokeExecuted=true", "passed=true", "post-update-check --full exit 0",
          ], cannotContain: secretWords),
        HostInstallReceiptSpec(
          id: "mcp-registration-smoke", title: "Host MCP registration smoke receipt",
          ownerTeam: "環境穩定團隊",
          producer:
            "scripts/tatwo-host-mcp-registration-smoke.mjs --expect-host-registration --host-config <codex-config>",
          proves: "Tatwo MCP 在 host 入口可 tools/list 與 tools/call，且只讀觀測到 Codex host config 已註冊。",
          acceptedEvidence: [
            "passed=true", "receiptID starts with mcp-host-", "hostRegistrationObserved=true",
          ], cannotContain: secretWords),
        HostInstallReceiptSpec(
          id: "rollback", title: "Rollback receipt", ownerTeam: "Human + Codex executor",
          producer: "scripts/tatwo-host-rollback-plan.mjs --backup-dir <backup-dir>",
          proves: "若裝了出問題，可以按備份還原。",
          acceptedEvidence: ["rollbackPlanValidated=true", "required backup files observed"],
          cannotContain: secretWords),
      ],
      stabilityRules: [
        "同一 provider model_gateway；不要 per-model provider。",
        "gateway route state 必須可觀測；route 有 error_kind/has_error 時，不能靠 gateway ok 就放行 host install。",
        "長 turn 必須有 data-bearing response.in_progress，避免 Codex idle disconnect。",
        "backend auth/quota/session 問題變成可見 completed notice，不用 response.failed 引發 retry storm。",
        "App bundle 不 patch、不逆向 renderer、不寫真實 LaunchAgent 直到人工 gate。",
        "所有外部模型只能 brain/patch intent；Codex executor 才能寫檔、shell、安裝、回滾。",
      ],
      plainSummary:
        "這是 host 實裝前的收據流水線：先沙盒、再只讀 preflight、再備份/回滾、再 live smoke，最後才由 install-gate 判斷能否進人工實裝。"
    )
  }

  public static func evaluateHostInstall(receipts: HostInstallReceiptSet) -> HostInstallGateDecision
  {
    let required = [
      "sandbox validated receipt",
      "host sandbox rehearsal receipt",
      "preflight clear receipt",
      "human approval receipt",
      "host backup receipt",
      "gateway same-thread smoke receipt",
      "host MCP registration smoke receipt",
      "rollback receipt",
    ]
    var blockers: [String] = []
    if !receipts.sandboxValidated { blockers.append("sandbox_not_validated") }
    if receipts.hostSandboxRehearsalReceiptID == nil {
      blockers.append("host_sandbox_rehearsal_not_observed")
    }
    if !receipts.preflightClear { blockers.append("host_preflight_not_clear") }
    if receipts.humanApprovalReceiptID == nil { blockers.append("human_approval_required") }
    if receipts.backupReceiptID == nil { blockers.append("host_backup_not_observed") }
    if receipts.liveSameThreadSmokeReceiptID == nil {
      blockers.append("live_same_thread_smoke_not_observed")
    }
    if receipts.mcpRegistrationSmokeReceiptID == nil {
      blockers.append("mcp_registration_on_host_not_observed")
    }
    if receipts.rollbackReceiptID == nil { blockers.append("rollback_receipt_not_observed") }
    if let id = receipts.hostSandboxRehearsalReceiptID, !isHashedReceipt(id, prefix: "rehearsal-") {
      blockers.append("invalid_host_sandbox_rehearsal_receipt")
    }
    if let id = receipts.humanApprovalReceiptID, !isHumanApprovalReceipt(id) {
      blockers.append("invalid_human_approval_receipt")
    }
    if let id = receipts.backupReceiptID, !isHashedReceipt(id, prefix: "backup-") {
      blockers.append("invalid_host_backup_receipt")
    }
    if let id = receipts.liveSameThreadSmokeReceiptID, !isHashedReceipt(id, prefix: "same-thread-")
    {
      blockers.append("invalid_live_same_thread_smoke_receipt")
    }
    if let id = receipts.mcpRegistrationSmokeReceiptID, !isHashedReceipt(id, prefix: "mcp-host-") {
      blockers.append("invalid_mcp_registration_smoke_receipt")
    }
    if let id = receipts.rollbackReceiptID, !isHashedReceipt(id, prefix: "rollback-") {
      blockers.append("invalid_rollback_receipt")
    }

    let allowed = blockers.isEmpty
    return HostInstallGateDecision(
      hostInstallAllowed: allowed,
      hostMutationPerformed: false,
      blockedBy: blockers,
      requiredReceipts: required,
      nextActions: allowed
        ? [
          "Run the approved installer step only in the host environment.",
          "Immediately run doctor --json, gateway same-thread smoke, and MCP registration smoke again.",
          "Keep rollback receipt and backup path local-only.",
        ]
        : [
          "Stay in sandbox/dry-run mode.",
          "Collect the missing receipts before any host mutation.",
          "Do not patch signed Codex App bundle or write LaunchAgent from this gate.",
        ],
      plainSummary: allowed
        ? "所有必要收據都存在；這只代表可進入人工批准的主機實裝步驟，本 gate 本身沒有執行任何主機修改。"
        : "主機實裝仍被擋下；缺任一收據或收據不像正確來源就 fail-closed，避免 Codex 斷線或不可回滾。"
    )
  }

  private static func isHashedReceipt(_ id: String, prefix: String) -> Bool {
    guard id.hasPrefix(prefix) else { return false }
    let suffix = id.dropFirst(prefix.count)
    guard suffix.count >= 12 else { return false }
    return suffix.unicodeScalars.allSatisfy { scalar in
      (48...57).contains(Int(scalar.value)) || (97...102).contains(Int(scalar.value))
    }
  }

  private static func isHumanApprovalReceipt(_ id: String) -> Bool {
    let lower = id.lowercased()
    guard lower.hasPrefix("human-") || lower.hasPrefix("approval-") else { return false }
    guard (8...96).contains(id.count) else { return false }
    return id.allSatisfy { character in
      character.isLetter || character.isNumber || character == "-" || character == "_"
        || character == "."
    }
  }
}

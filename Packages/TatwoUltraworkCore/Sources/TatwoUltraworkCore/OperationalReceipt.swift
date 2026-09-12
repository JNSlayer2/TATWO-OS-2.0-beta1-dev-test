import Foundation

public enum ReceiptClass: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case sandbox
  case dryRun = "dry_run"
  case hostLive = "host_live"
  case hostBackup = "host_backup"
  case rollback
  case mcpHostRegistration = "mcp_host_registration"
  case humanApproval = "human_approval"
  case uiVisual = "ui_visual"
  case operational
}

public enum EvidenceOrigin: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case deterministicCommand = "deterministic_command"
  case codexToolTrace = "codex_tool_trace"
  case scriptReceipt = "script_receipt"
  case hostConfigObservation = "host_config_observation"
  case mcpClientSmoke = "mcp_client_smoke"
  case mcpServerSelfReport = "mcp_server_self_report"
  case modelText = "model_text"
  case humanApproval = "human_approval"
}

public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case dryRun = "dry_run"
  case sandbox
  case hostReadOnly = "host_read_only"
  case hostLive = "host_live"
  case hostMutation = "host_mutation"
}

public enum TransportKind: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case none
  case localShell = "local_shell"
  case mcpStdio = "mcp_stdio"
  case modelGateway = "model_gateway"
  case codexAppGateway = "codex_app_gateway"
  case codexMCPHost = "codex_mcp_host"
  case browserUI = "browser_ui"
}

public enum ReceiptResultState: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case pass
  case fail
  case blocked
  case running
  case timeout
  case disconnected
  case partial
  case circuitOpen = "circuit_open"
}

public enum TerminalEvent: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case none
  case responseCompleted = "response.completed"
  case responseInProgress = "response.in_progress"
  case responseOutputDelta = "response.output_text.delta"
  case responseFailed = "response.failed"
  case timeout
  case disconnected
}

public enum ApprovalEffect: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case none
  case hostInstall = "host_install"
  case hostMutation = "host_mutation"
  case modelSwitch = "model_switch"
  case rollback
}

public struct OperationalReceipt: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let id: String
  public let receiptClass: ReceiptClass
  public let evidenceOrigin: EvidenceOrigin
  public let executionMode: ExecutionMode
  public let transportKind: TransportKind
  public let resultState: ReceiptResultState
  public let terminalEvent: TerminalEvent
  public let approvalEffect: ApprovalEffect
  public let operation: String
  public let observedAt: Date
  public let dryRun: Bool
  public let hostStateObserved: Bool
  public let hostMutationPerformed: Bool
  public let sameThreadContinuityObserved: Bool
  public let mcpHostRegistrationObserved: Bool
  public let approvalEpoch: Int?
  public let currentModelEpoch: Int?
  public let retryCount: Int
  public let circuitOpen: Bool
  public let evidenceIDs: [String]
  public let proves: [String]

  public init(
    schema: String = "TatwoOperationalReceiptV1",
    id: String,
    receiptClass: ReceiptClass,
    evidenceOrigin: EvidenceOrigin,
    executionMode: ExecutionMode,
    transportKind: TransportKind,
    resultState: ReceiptResultState,
    terminalEvent: TerminalEvent,
    approvalEffect: ApprovalEffect = .none,
    operation: String,
    observedAt: Date = Date(timeIntervalSince1970: 1_782_086_400),
    dryRun: Bool,
    hostStateObserved: Bool = false,
    hostMutationPerformed: Bool = false,
    sameThreadContinuityObserved: Bool = false,
    mcpHostRegistrationObserved: Bool = false,
    approvalEpoch: Int? = nil,
    currentModelEpoch: Int? = nil,
    retryCount: Int = 0,
    circuitOpen: Bool = false,
    evidenceIDs: [String] = [],
    proves: [String] = []
  ) {
    self.schema = schema
    self.id = TatwoPrivacyRedactor.redacted(id.trimmingCharacters(in: .whitespacesAndNewlines))
    self.receiptClass = receiptClass
    self.evidenceOrigin = evidenceOrigin
    self.executionMode = executionMode
    self.transportKind = transportKind
    self.resultState = resultState
    self.terminalEvent = terminalEvent
    self.approvalEffect = approvalEffect
    self.operation = TatwoPrivacyRedactor.redacted(
      operation.trimmingCharacters(in: .whitespacesAndNewlines))
    self.observedAt = observedAt
    self.dryRun = dryRun
    self.hostStateObserved = hostStateObserved
    self.hostMutationPerformed = hostMutationPerformed
    self.sameThreadContinuityObserved = sameThreadContinuityObserved
    self.mcpHostRegistrationObserved = mcpHostRegistrationObserved
    self.approvalEpoch = approvalEpoch
    self.currentModelEpoch = currentModelEpoch
    self.retryCount = retryCount
    self.circuitOpen = circuitOpen
    self.evidenceIDs = evidenceIDs.map { TatwoPrivacyRedactor.redacted($0) }
    self.proves = proves.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct OperationalReceiptRequirement: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let plainPurpose: String
  public let allowedReceiptClasses: Set<ReceiptClass>
  public let allowedOrigins: Set<EvidenceOrigin>
  public let allowedExecutionModes: Set<ExecutionMode>
  public let allowedTransports: Set<TransportKind>
  public let requiresHostLive: Bool
  public let requiresHostStateObservation: Bool
  public let requiresSameThreadContinuity: Bool
  public let requiresMCPHostRegistration: Bool
  public let allowHostMutation: Bool
  public let requiredApprovalEffect: ApprovalEffect?
  public let requiredApprovalEpoch: Int?
  public let maxRetryCountBeforeStorm: Int

  public init(
    id: String,
    plainPurpose: String,
    allowedReceiptClasses: Set<ReceiptClass>,
    allowedOrigins: Set<EvidenceOrigin>,
    allowedExecutionModes: Set<ExecutionMode>,
    allowedTransports: Set<TransportKind>,
    requiresHostLive: Bool = false,
    requiresHostStateObservation: Bool = false,
    requiresSameThreadContinuity: Bool = false,
    requiresMCPHostRegistration: Bool = false,
    allowHostMutation: Bool = false,
    requiredApprovalEffect: ApprovalEffect? = nil,
    requiredApprovalEpoch: Int? = nil,
    maxRetryCountBeforeStorm: Int = 2
  ) {
    self.id = id
    self.plainPurpose = plainPurpose
    self.allowedReceiptClasses = allowedReceiptClasses
    self.allowedOrigins = allowedOrigins
    self.allowedExecutionModes = allowedExecutionModes
    self.allowedTransports = allowedTransports
    self.requiresHostLive = requiresHostLive
    self.requiresHostStateObservation = requiresHostStateObservation
    self.requiresSameThreadContinuity = requiresSameThreadContinuity
    self.requiresMCPHostRegistration = requiresMCPHostRegistration
    self.allowHostMutation = allowHostMutation
    self.requiredApprovalEffect = requiredApprovalEffect
    self.requiredApprovalEpoch = requiredApprovalEpoch
    self.maxRetryCountBeforeStorm = maxRetryCountBeforeStorm
  }

  public static func hostLiveSameThread() -> Self {
    Self(
      id: "host-live-same-thread",
      plainPurpose: "證明 Codex/gateway 在真實 host live 路線同 thread 切模型完成，不是 dry-run 或模型口頭說法。",
      allowedReceiptClasses: [.hostLive],
      allowedOrigins: [.deterministicCommand, .codexToolTrace, .scriptReceipt],
      allowedExecutionModes: [.hostLive],
      allowedTransports: [.modelGateway, .codexAppGateway],
      requiresHostLive: true,
      requiresHostStateObservation: true,
      requiresSameThreadContinuity: true
    )
  }

  public static func mcpHostRegistration() -> Self {
    Self(
      id: "mcp-host-registration",
      plainPurpose: "證明 Codex host config 只讀觀測到 MCP 註冊，且 MCP tools/list 與 tools/call 可用。",
      allowedReceiptClasses: [.mcpHostRegistration],
      allowedOrigins: [.hostConfigObservation, .scriptReceipt],
      allowedExecutionModes: [.hostReadOnly],
      allowedTransports: [.codexMCPHost],
      requiresHostStateObservation: true,
      requiresMCPHostRegistration: true
    )
  }

  public static func hostInstallApproval(requiredEpoch: Int) -> Self {
    Self(
      id: "host-install-approval",
      plainPurpose: "證明人工批准仍對應目前模型/模式 epoch；切模型後舊批准失效。",
      allowedReceiptClasses: [.humanApproval],
      allowedOrigins: [.humanApproval],
      allowedExecutionModes: [.hostReadOnly],
      allowedTransports: [.none],
      requiredApprovalEffect: .hostInstall,
      requiredApprovalEpoch: requiredEpoch
    )
  }

  public static func sandboxOperational() -> Self {
    Self(
      id: "sandbox-operational",
      plainPurpose: "證明沙盒內 deterministic command 完成；此收據不能升級成 host live。",
      allowedReceiptClasses: [.sandbox],
      allowedOrigins: [.deterministicCommand, .scriptReceipt],
      allowedExecutionModes: [.sandbox],
      allowedTransports: [.localShell]
    )
  }
}

public struct OperationalGateReport: Codable, Sendable, Equatable {
  public let schema: String
  public let receiptID: String
  public let requirementID: String
  public let status: GateStatus
  public let hostInstallEvidenceAllowed: Bool
  public let reasons: [String]
  public let plainSummary: String

  public init(
    schema: String = "TatwoOperationalGateReportV1",
    receiptID: String,
    requirementID: String,
    status: GateStatus,
    hostInstallEvidenceAllowed: Bool,
    reasons: [String],
    plainSummary: String
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.requirementID = requirementID
    self.status = status
    self.hostInstallEvidenceAllowed = hostInstallEvidenceAllowed
    self.reasons = reasons
    self.plainSummary = plainSummary
  }
}

public enum OperationalReceiptGate {
  public static func evaluate(
    _ receipt: OperationalReceipt,
    requirement: OperationalReceiptRequirement
  ) -> OperationalGateReport {
    var reasons: [String] = []

    if receipt.schema != "TatwoOperationalReceiptV1" {
      reasons.append("unsupported_operational_schema")
    }
    if receipt.id.isEmpty {
      reasons.append("missing_receipt_id")
    }
    if receipt.operation.isEmpty {
      reasons.append("missing_operation")
    }
    if !requirement.allowedReceiptClasses.contains(receipt.receiptClass) {
      reasons.append("wrong_receipt_class:\(receipt.receiptClass.rawValue)")
    }
    if !requirement.allowedOrigins.contains(receipt.evidenceOrigin) {
      reasons.append("wrong_evidence_origin:\(receipt.evidenceOrigin.rawValue)")
    }
    if !requirement.allowedExecutionModes.contains(receipt.executionMode) {
      reasons.append("wrong_execution_mode:\(receipt.executionMode.rawValue)")
    }
    if !requirement.allowedTransports.contains(receipt.transportKind) {
      reasons.append("wrong_transport:\(receipt.transportKind.rawValue)")
    }

    if receipt.resultState != .pass {
      reasons.append("result_state_not_pass:\(receipt.resultState.rawValue)")
    }
    if receipt.resultState == .partial || receipt.terminalEvent == .responseOutputDelta
      || receipt.terminalEvent == .responseInProgress
    {
      reasons.append("partial_stream_cannot_pass")
    }
    if receipt.resultState == .timeout || receipt.terminalEvent == .timeout {
      reasons.append("timeout_cannot_pass")
    }
    if receipt.resultState == .disconnected || receipt.terminalEvent == .disconnected
      || receipt.terminalEvent == .responseFailed
    {
      reasons.append("disconnect_cannot_pass")
    }
    if receipt.resultState == .circuitOpen || receipt.circuitOpen
      || receipt.retryCount > requirement.maxRetryCountBeforeStorm
    {
      reasons.append("retry_storm_or_circuit_open")
    }

    let responseTransports: Set<TransportKind> = [.modelGateway, .codexAppGateway, .browserUI]
    if requirement.requiresHostLive || responseTransports.contains(receipt.transportKind) {
      if receipt.terminalEvent != .responseCompleted {
        reasons.append("terminal_event_not_completed:\(receipt.terminalEvent.rawValue)")
      }
    }

    if requirement.requiresHostLive {
      if receipt.dryRun || receipt.executionMode == .dryRun {
        reasons.append("dry_run_cannot_satisfy_host_live")
      }
      if receipt.executionMode != .hostLive {
        reasons.append("host_live_required")
      }
    }
    if requirement.requiresHostStateObservation && !receipt.hostStateObserved {
      reasons.append("host_state_not_observed")
    }
    if requirement.requiresSameThreadContinuity && !receipt.sameThreadContinuityObserved {
      reasons.append("same_thread_continuity_not_observed")
    }
    if requirement.requiresMCPHostRegistration && !receipt.mcpHostRegistrationObserved {
      reasons.append("mcp_host_registration_not_observed")
    }
    if requirement.requiresMCPHostRegistration && receipt.transportKind == .mcpStdio {
      reasons.append("mcp_stdio_not_host_registration")
    }

    if receipt.evidenceOrigin == .mcpServerSelfReport && requirement.requiresHostStateObservation {
      reasons.append("mcp_server_self_report_cannot_prove_host_state")
    }
    if receipt.evidenceOrigin == .modelText {
      reasons.append("model_text_cannot_approve_install")
    }
    if !requirement.allowHostMutation && receipt.hostMutationPerformed {
      reasons.append("host_mutation_not_allowed_by_gate")
    }
    if let requiredEffect = requirement.requiredApprovalEffect,
      receipt.approvalEffect != requiredEffect
    {
      reasons.append("approval_effect_mismatch:\(receipt.approvalEffect.rawValue)")
    }
    if let requiredEpoch = requirement.requiredApprovalEpoch {
      if receipt.approvalEpoch != requiredEpoch {
        reasons.append("approval_epoch_mismatch")
      }
    }
    if let approvalEpoch = receipt.approvalEpoch {
      if let currentModelEpoch = receipt.currentModelEpoch {
        if approvalEpoch != currentModelEpoch {
          reasons.append("approval_epoch_stale_after_model_switch")
        }
      } else {
        reasons.append("approval_epoch_current_model_unknown")
      }
    }

    let passed = reasons.isEmpty
    return OperationalGateReport(
      receiptID: receipt.id,
      requirementID: requirement.id,
      status: passed ? .passed : .failed,
      hostInstallEvidenceAllowed: passed
        && (requirement.requiresHostLive || requirement.requiresMCPHostRegistration
          || requirement.requiredApprovalEffect == .hostInstall),
      reasons: reasons,
      plainSummary: passed
        ? "收據通過：這是由正確來源、正確模式與完整 terminal event 支撐的證據。"
        : "收據被擋下：dry-run、模型口頭說法、stdio 自報、partial stream、斷線、舊批准或 retry storm 都不能升級成 host 實裝證據。"
    )
  }
}

public enum OperationalReceiptSampleCase: String, Codable, Sendable, CaseIterable {
  case hostLiveGood = "host-live-good"
  case hostMCPGood = "host-mcp-good"
  case partialStream = "partial-stream"
  case stdioFakeHost = "stdio-fake-host"
  case dryRunHostLive = "dry-run-host-live"
  case disconnected
  case retryStorm = "retry-storm"
  case oldApprovalEpoch = "old-approval-epoch"
  case modelTextApproval = "model-text-approval"
}

public struct OperationalReceiptSample: Codable, Sendable, Equatable {
  public let sampleCase: OperationalReceiptSampleCase
  public let expectedPass: Bool
  public let receipt: OperationalReceipt
  public let requirement: OperationalReceiptRequirement

  public static func make(_ sampleCase: OperationalReceiptSampleCase) -> Self {
    switch sampleCase {
    case .hostLiveGood:
      return Self(
        sampleCase: sampleCase,
        expectedPass: true,
        receipt: OperationalReceipt(
          id: "same-thread-abcdef123456",
          receiptClass: .hostLive,
          evidenceOrigin: .deterministicCommand,
          executionMode: .hostLive,
          transportKind: .modelGateway,
          resultState: .pass,
          terminalEvent: .responseCompleted,
          operation: "gateway same-thread smoke",
          dryRun: false,
          hostStateObserved: true,
          sameThreadContinuityObserved: true,
          evidenceIDs: ["post-update-check", "response.completed"],
          proves: ["same-thread", "host-live", "model-switch"]
        ),
        requirement: .hostLiveSameThread()
      )
    case .hostMCPGood:
      return Self(
        sampleCase: sampleCase,
        expectedPass: true,
        receipt: OperationalReceipt(
          id: "mcp-host-abcdef123456",
          receiptClass: .mcpHostRegistration,
          evidenceOrigin: .hostConfigObservation,
          executionMode: .hostReadOnly,
          transportKind: .codexMCPHost,
          resultState: .pass,
          terminalEvent: .none,
          operation: "read-only MCP host registration observation",
          dryRun: false,
          hostStateObserved: true,
          mcpHostRegistrationObserved: true,
          evidenceIDs: ["host-config-observed", "tools-list", "tools-call"],
          proves: ["mcp-host-registration"]
        ),
        requirement: .mcpHostRegistration()
      )
    case .partialStream:
      return Self(
        sampleCase: sampleCase,
        expectedPass: false,
        receipt: OperationalReceipt(
          id: "same-thread-partial",
          receiptClass: .hostLive,
          evidenceOrigin: .scriptReceipt,
          executionMode: .hostLive,
          transportKind: .modelGateway,
          resultState: .partial,
          terminalEvent: .responseOutputDelta,
          operation: "gateway emitted deltas but never completed",
          dryRun: false,
          hostStateObserved: true,
          sameThreadContinuityObserved: true,
          evidenceIDs: ["delta-only"]
        ),
        requirement: .hostLiveSameThread()
      )
    case .stdioFakeHost:
      return Self(
        sampleCase: sampleCase,
        expectedPass: false,
        receipt: OperationalReceipt(
          id: "mcp-stdio-abcdef123456",
          receiptClass: .mcpHostRegistration,
          evidenceOrigin: .mcpServerSelfReport,
          executionMode: .hostReadOnly,
          transportKind: .mcpStdio,
          resultState: .pass,
          terminalEvent: .none,
          operation: "MCP server claimed it was installed",
          dryRun: false,
          hostStateObserved: false,
          mcpHostRegistrationObserved: false,
          evidenceIDs: ["server-self-report"]
        ),
        requirement: .mcpHostRegistration()
      )
    case .dryRunHostLive:
      return Self(
        sampleCase: sampleCase,
        expectedPass: false,
        receipt: OperationalReceipt(
          id: "same-thread-dryrun",
          receiptClass: .hostLive,
          evidenceOrigin: .scriptReceipt,
          executionMode: .dryRun,
          transportKind: .modelGateway,
          resultState: .pass,
          terminalEvent: .responseCompleted,
          operation: "same-thread dry-run plan",
          dryRun: true,
          hostStateObserved: false,
          sameThreadContinuityObserved: false
        ),
        requirement: .hostLiveSameThread()
      )
    case .disconnected:
      return Self(
        sampleCase: sampleCase,
        expectedPass: false,
        receipt: OperationalReceipt(
          id: "same-thread-disconnect",
          receiptClass: .hostLive,
          evidenceOrigin: .scriptReceipt,
          executionMode: .hostLive,
          transportKind: .codexAppGateway,
          resultState: .disconnected,
          terminalEvent: .disconnected,
          operation: "Codex App stream disconnected before completion",
          dryRun: false,
          hostStateObserved: true,
          sameThreadContinuityObserved: false
        ),
        requirement: .hostLiveSameThread()
      )
    case .retryStorm:
      return Self(
        sampleCase: sampleCase,
        expectedPass: false,
        receipt: OperationalReceipt(
          id: "same-thread-retry-storm",
          receiptClass: .hostLive,
          evidenceOrigin: .scriptReceipt,
          executionMode: .hostLive,
          transportKind: .modelGateway,
          resultState: .circuitOpen,
          terminalEvent: .responseFailed,
          operation: "gateway retry storm opened circuit",
          dryRun: false,
          hostStateObserved: true,
          sameThreadContinuityObserved: false,
          retryCount: 7,
          circuitOpen: true
        ),
        requirement: .hostLiveSameThread()
      )
    case .oldApprovalEpoch:
      return Self(
        sampleCase: sampleCase,
        expectedPass: false,
        receipt: OperationalReceipt(
          id: "human-approval-old-epoch",
          receiptClass: .humanApproval,
          evidenceOrigin: .humanApproval,
          executionMode: .hostReadOnly,
          transportKind: .none,
          resultState: .pass,
          terminalEvent: .none,
          approvalEffect: .hostInstall,
          operation: "human approved before model switch",
          dryRun: false,
          approvalEpoch: 1,
          currentModelEpoch: 2
        ),
        requirement: .hostInstallApproval(requiredEpoch: 2)
      )
    case .modelTextApproval:
      return Self(
        sampleCase: sampleCase,
        expectedPass: false,
        receipt: OperationalReceipt(
          id: "model-text-approval",
          receiptClass: .humanApproval,
          evidenceOrigin: .modelText,
          executionMode: .hostReadOnly,
          transportKind: .none,
          resultState: .pass,
          terminalEvent: .none,
          approvalEffect: .hostInstall,
          operation: "model said install is approved",
          dryRun: false,
          approvalEpoch: 2,
          currentModelEpoch: 2
        ),
        requirement: .hostInstallApproval(requiredEpoch: 2)
      )
    }
  }
}

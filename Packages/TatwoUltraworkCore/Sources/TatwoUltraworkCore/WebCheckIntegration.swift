import CryptoKit
import Foundation

public enum TatwoWebCheckTargetKind: String, Codable, Sendable, CaseIterable, Equatable {
  case localProject = "local-project"
  case publicURL = "public-url"
}

public enum TatwoWebCheckScanType: String, Codable, Sendable, CaseIterable, Equatable {
  case focused
  case full
  case category
  case publicURL = "public-url"
  case why
  case ruleExplain = "rule-explain"
}

public enum TatwoWebCheckBlockingPolicy: String, Codable, Sendable, CaseIterable, Equatable {
  case noNewError = "no-new-error"
  case noCritical = "no-critical"
  case reportOnly = "report-only"
}

public enum TatwoWebCheckDecision: String, Codable, Sendable, CaseIterable, Equatable {
  case passed
  case failed
  case blocked
  case reportOnly = "report_only"
}

public struct TatwoWebCheckRuleParity: Codable, Sendable, Equatable {
  public let officialRules: Int
  public let implementedSubstitutes: Int
  public let plannedDetectors: Int
  public let activeLocalDetectorIDs: Int?

  public init(
    officialRules: Int,
    implementedSubstitutes: Int,
    plannedDetectors: Int,
    activeLocalDetectorIDs: Int? = nil
  ) {
    self.officialRules = officialRules
    self.implementedSubstitutes = implementedSubstitutes
    self.plannedDetectors = plannedDetectors
    self.activeLocalDetectorIDs = activeLocalDetectorIDs
  }
}

public struct TatwoWebCheckSummary: Codable, Sendable, Equatable {
  public let errors: Int
  public let warnings: Int
  public let total: Int
  public let topCategories: [String]

  public init(errors: Int, warnings: Int, total: Int, topCategories: [String]) {
    self.errors = errors
    self.warnings = warnings
    self.total = total
    self.topCategories = topCategories
  }
}

public struct TatwoWebCheckPreflight: Codable, Sendable, Equatable {
  public let schema: String
  public let available: Bool
  public let toolName: String
  public let executableHint: String
  public let rootHint: String
  public let ruleParity: TatwoWebCheckRuleParity?
  public let localOnlyPolicy: [String]
  public let smokeCommand: String
  public let degradedReason: String?

  public init(
    schema: String = "TatwoWebCheckPreflightV1",
    available: Bool,
    toolName: String = "tatwo-frontend-doctor",
    executableHint: String,
    rootHint: String,
    ruleParity: TatwoWebCheckRuleParity?,
    localOnlyPolicy: [String],
    smokeCommand: String,
    degradedReason: String?
  ) {
    self.schema = schema
    self.available = available
    self.toolName = toolName
    self.executableHint = executableHint
    self.rootHint = rootHint
    self.ruleParity = ruleParity
    self.localOnlyPolicy = localOnlyPolicy
    self.smokeCommand = smokeCommand
    self.degradedReason = degradedReason
  }
}

public struct TatwoWebCheckPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let mode: WorkModeID
  public let scenario: String
  public let targetKind: TatwoWebCheckTargetKind
  public let targetLabel: String
  public let scanType: TatwoWebCheckScanType
  public let blockingPolicy: TatwoWebCheckBlockingPolicy
  public let requiredForPass: Bool
  public let command: String
  public let expectedReceiptKind: String
  public let osReceiptIDs: [String]
  public let localOnlyRules: [String]
  public let humanGateNote: String

  public init(
    schema: String = "TatwoWebCheckPlanV1",
    mode: WorkModeID,
    scenario: String,
    targetKind: TatwoWebCheckTargetKind,
    targetLabel: String,
    scanType: TatwoWebCheckScanType,
    blockingPolicy: TatwoWebCheckBlockingPolicy,
    requiredForPass: Bool,
    command: String,
    expectedReceiptKind: String,
    osReceiptIDs: [String],
    localOnlyRules: [String],
    humanGateNote: String
  ) {
    self.schema = schema
    self.mode = mode
    self.scenario = scenario
    self.targetKind = targetKind
    self.targetLabel = targetLabel
    self.scanType = scanType
    self.blockingPolicy = blockingPolicy
    self.requiredForPass = requiredForPass
    self.command = command
    self.expectedReceiptKind = expectedReceiptKind
    self.osReceiptIDs = osReceiptIDs
    self.localOnlyRules = localOnlyRules
    self.humanGateNote = humanGateNote
  }
}

public struct TatwoWebCheckReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let receiptID: String
  public let contractID: String
  public let goalID: String?
  public let target: TatwoWebCheckTargetKind
  public let scanType: TatwoWebCheckScanType
  public let command: String
  public let reportPath: String
  public let reportSHA256: String
  public let ruleParity: TatwoWebCheckRuleParity
  public let summary: TatwoWebCheckSummary
  public let blockingPolicy: TatwoWebCheckBlockingPolicy
  public let externalUploadAvoided: Bool
  public let projectFilesModified: Bool
  public let decision: TatwoWebCheckDecision
  public let notes: [String]

  public init(
    schema: String = "TatwoWebCheckReceiptV1",
    receiptID: String,
    contractID: String,
    goalID: String?,
    target: TatwoWebCheckTargetKind,
    scanType: TatwoWebCheckScanType,
    command: String,
    reportPath: String,
    reportSHA256: String,
    ruleParity: TatwoWebCheckRuleParity,
    summary: TatwoWebCheckSummary,
    blockingPolicy: TatwoWebCheckBlockingPolicy,
    externalUploadAvoided: Bool,
    projectFilesModified: Bool,
    decision: TatwoWebCheckDecision,
    notes: [String]
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.contractID = contractID
    self.goalID = goalID
    self.target = target
    self.scanType = scanType
    self.command = command
    self.reportPath = reportPath
    self.reportSHA256 = reportSHA256
    self.ruleParity = ruleParity
    self.summary = summary
    self.blockingPolicy = blockingPolicy
    self.externalUploadAvoided = externalUploadAvoided
    self.projectFilesModified = projectFilesModified
    self.decision = decision
    self.notes = notes
  }
}

public struct TatwoWebCheckImportResult: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let receipt: TatwoWebCheckReceipt?
  public let decision: WorkOSGateDecision
  public let nextAction: String

  public init(
    schema: String = "TatwoWebCheckImportResultV1",
    ok: Bool,
    receipt: TatwoWebCheckReceipt?,
    decision: WorkOSGateDecision,
    nextAction: String
  ) {
    self.schema = schema
    self.ok = ok
    self.receipt = receipt
    self.decision = decision
    self.nextAction = nextAction
  }
}

public enum TatwoWebCheckFactory {
  public static let expectedRuleParity = TatwoWebCheckRuleParity(
    officialRules: 429,
    implementedSubstitutes: 429,
    plannedDetectors: 0,
    activeLocalDetectorIDs: 426)

  public static let localOnlyRules = [
    "web-check 只產生前端驗收收據；不當模型、不當最終 UI 美感裁判。",
    "不把 source、JSON report、secrets、private logs、local paths 上傳到 hosted service。",
    "不自動修檔、不部署 production；修復與實裝仍需 Work OS contract 與 host 授權。",
    "UI/UJ 即使 web-check 通過，仍需要截圖、互動 smoke 或人類確認。",
  ]

  public static func preflight(
    available: Bool = false,
    executableHint: String = "<web-check-root>/bin/tatwo-frontend-doctor",
    rootHint: String = "TATWO_WEB_CHECK_ROOT or local 前端健檢 root",
    ruleParity: TatwoWebCheckRuleParity? = nil,
    degradedReason: String? = "live preflight not run"
  ) -> TatwoWebCheckPreflight {
    TatwoWebCheckPreflight(
      available: available,
      executableHint: executableHint,
      rootHint: rootHint,
      ruleParity: ruleParity,
      localOnlyPolicy: localOnlyRules,
      smokeCommand: "./bin/tatwo-frontend-doctor rules list --json",
      degradedReason: available ? nil : degradedReason)
  }

  public static func plan(
    mode: WorkModeID,
    scenarioProfileID: String,
    target rawTarget: String,
    scanType requestedScanType: TatwoWebCheckScanType? = nil,
    blockingPolicy requestedBlockingPolicy: TatwoWebCheckBlockingPolicy? = nil
  ) -> TatwoWebCheckPlan {
    let targetKind = inferTargetKind(rawTarget)
    let scanType = requestedScanType ?? defaultScanType(mode: mode, targetKind: targetKind)
    let blockingPolicy = requestedBlockingPolicy ?? defaultBlockingPolicy(mode: mode)
    let required = requiredForPass(mode: mode, scenarioProfileID: scenarioProfileID)
    let targetLabel = sanitizedTargetLabel(rawTarget, targetKind: targetKind)
    let commandTarget = targetKind == .publicURL ? targetLabel : "<local-frontend-project>"
    let command: String
    if targetKind == .publicURL {
      command = "pnpm scan:url \(commandTarget) --max-scripts 8 --no-desktop-report"
    } else if scanType == .focused {
      command = "./bin/tatwo-frontend-doctor \(commandTarget) --json --json-compact --blocking none"
    } else {
      command =
        "./bin/tatwo-frontend-doctor \(commandTarget) --json --json-compact --blocking none > <local-web-check-report.json>"
    }
    return TatwoWebCheckPlan(
      mode: mode,
      scenario: scenarioProfileID,
      targetKind: targetKind,
      targetLabel: targetLabel,
      scanType: scanType,
      blockingPolicy: blockingPolicy,
      requiredForPass: required,
      command: command,
      expectedReceiptKind: "web-check",
      osReceiptIDs: receiptRequirements(mode: mode, scenarioProfileID: scenarioProfileID).map(\.id),
      localOnlyRules: localOnlyRules,
      humanGateNote: "web-check 只證明前端風險掃描；UI 美感、互動與最終 promotion 還要 visual/human receipt。")
  }

  public static func receiptTemplate(
    contractID: String,
    goalID: String? = nil,
    targetKind: TatwoWebCheckTargetKind = .localProject,
    scanType: TatwoWebCheckScanType = .full,
    blockingPolicy: TatwoWebCheckBlockingPolicy = .noNewError
  ) -> TatwoWebCheckReceipt {
    TatwoWebCheckReceipt(
      receiptID: "web-check-template",
      contractID: contractID,
      goalID: goalID,
      target: targetKind,
      scanType: scanType,
      command:
        "./bin/tatwo-frontend-doctor <local-frontend-project> --json --json-compact --blocking none",
      reportPath: "local-only:<report.json>",
      reportSHA256: "pending",
      ruleParity: expectedRuleParity,
      summary: TatwoWebCheckSummary(errors: 0, warnings: 0, total: 0, topCategories: []),
      blockingPolicy: blockingPolicy,
      externalUploadAvoided: true,
      projectFilesModified: false,
      decision: .blocked,
      notes: ["template only; import a real local JSON report before closing the goal"])
  }

  public static func importReceipt(
    reportData: Data,
    reportPath: String,
    contractID: String?,
    goalID: String?,
    targetKind: TatwoWebCheckTargetKind,
    scanType: TatwoWebCheckScanType,
    blockingPolicy: TatwoWebCheckBlockingPolicy,
    command: String
  ) -> TatwoWebCheckImportResult {
    let contractGate = WorkOSFactory.requireContractID(contractID)
    guard contractGate.ok, let contractID else {
      return TatwoWebCheckImportResult(
        ok: false,
        receipt: nil,
        decision: contractGate,
        nextAction: "先用 tatwo.os.begin 建立 contract，再匯入 web-check report。")
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: reportData, options: [])
        as? [String: Any]
    else {
      let decision = WorkOSGateDecision(
        ok: false,
        code: "web_check_report_parse_failed",
        message: "web-check report 不是可解析 JSON；不可當驗收收據。")
      return TatwoWebCheckImportResult(
        ok: false,
        receipt: nil,
        decision: decision,
        nextAction: "重新產生 --json --json-compact report。")
    }

    let summary = parseSummary(object)
    let reportHash = sha256(reportData)
    let decisionValue = decide(summary: summary, blockingPolicy: blockingPolicy)
    let ok = decisionValue == .passed || decisionValue == .reportOnly
    let receipt = TatwoWebCheckReceipt(
      receiptID: "web-check-\(String(reportHash.prefix(12)))",
      contractID: contractID,
      goalID: goalID,
      target: targetKind,
      scanType: scanType,
      command: command,
      reportPath: localOnlyReportLabel(reportPath),
      reportSHA256: reportHash,
      ruleParity: expectedRuleParity,
      summary: summary,
      blockingPolicy: blockingPolicy,
      externalUploadAvoided: true,
      projectFilesModified: false,
      decision: decisionValue,
      notes: notes(for: decisionValue, summary: summary))
    return TatwoWebCheckImportResult(
      ok: ok,
      receipt: receipt,
      decision: WorkOSGateDecision(
        ok: ok,
        code: ok ? "web_check_receipt_ready" : "web_check_blocking_findings",
        message: ok
          ? "web-check receipt 可提交到 Work OS；仍不取代 visual/human UI 驗收。"
          : "web-check 發現 blocking finding；不可關閉 goal，需修復或明確降級為 report-only。"),
      nextAction: ok
        ? "用 tatwo.os.receipt.submit --kind web-check --receipt \(receipt.receiptID) 提交到 contract。"
        : "修復 finding 後重跑 web-check，或由人類明確改為 report-only。")
  }

  public static func receiptRequirements(
    mode: WorkModeID,
    scenarioProfileID: String
  ) -> [WorkOSReceiptRequirement] {
    let frontendStrict = isFrontendStrictScenario(scenarioProfileID)
    let frontendLikely = frontendStrict || ["coding", "debug"].contains(scenarioProfileID)
    guard frontendLikely else { return [] }
    switch mode {
    case .s:
      return [
        WorkOSReceiptRequirement(
          id: "web-check-focused",
          title: "web-check focused scan",
          kind: "web-check",
          requiredForPass: false,
          plainPurpose: "S 可選：針對前端小修跑 focused scan；不是必要 gate。")
      ]
    case .m:
      return [
        WorkOSReceiptRequirement(
          id: "web-check-json-scan",
          title: "web-check JSON scan",
          kind: "web-check",
          requiredForPass: false,
          plainPurpose: "M 建議：若改到 frontend，產生 local JSON scan receipt。")
      ]
    case .l:
      return [
        WorkOSReceiptRequirement(
          id: "web-check-full-scan",
          title: "web-check full frontend scan",
          kind: "web-check",
          requiredForPass: frontendStrict,
          plainPurpose: frontendStrict
            ? "L UI/frontend 任務必跑本地 full scan；不通過不可 promotion。"
            : "L coding/debug 若目標是 frontend，應匯入 full scan receipt。")
      ]
    case .xl, .xxl:
      return [
        WorkOSReceiptRequirement(
          id: "web-check-baseline-scan",
          title: "web-check baseline scan",
          kind: "web-check",
          requiredForPass: frontendStrict,
          plainPurpose: "XL frontend 先留下 baseline，避免把舊問題誤算成新成果。"),
        WorkOSReceiptRequirement(
          id: "web-check-after-scan",
          title: "web-check after scan",
          kind: "web-check",
          requiredForPass: frontendStrict,
          plainPurpose: "XL frontend 完工後需 no-new-error / no-critical，再交 visual/human gate。"),
      ]
    }
  }

  public static func domainReceiptRequirements(
    mode: WorkModeID,
    scenarioProfileID: String,
    domain: WorkOSDomainKind
  ) -> [WorkOSReceiptRequirement] {
    guard [.ui, .code, .debug, .ops].contains(domain) else { return [] }
    return receiptRequirements(mode: mode, scenarioProfileID: scenarioProfileID)
  }

  private static func parseSummary(_ object: [String: Any]) -> TatwoWebCheckSummary {
    let summary = object["summary"] as? [String: Any] ?? [:]
    let errors = intValue(summary["errorCount"])
    let warnings = intValue(summary["warningCount"])
    let total = intValue(summary["total"])
    let categories = summary["categories"] as? [String: Any] ?? [:]
    let ranked = categories.compactMap { key, value -> (String, Int)? in
      let category = value as? [String: Any] ?? [:]
      return (key, intValue(category["total"]))
    }
    .sorted { lhs, rhs in (lhs.1, lhs.0) > (rhs.1, rhs.0) }
    .prefix(5)
    .map { $0.0 }
    return TatwoWebCheckSummary(
      errors: errors, warnings: warnings, total: total, topCategories: Array(ranked))
  }

  private static func decide(
    summary: TatwoWebCheckSummary,
    blockingPolicy: TatwoWebCheckBlockingPolicy
  ) -> TatwoWebCheckDecision {
    switch blockingPolicy {
    case .reportOnly:
      return .reportOnly
    case .noCritical, .noNewError:
      return summary.errors == 0 ? .passed : .failed
    }
  }

  private static func notes(
    for decision: TatwoWebCheckDecision,
    summary: TatwoWebCheckSummary
  ) -> [String] {
    var result = [
      "local-only JSON imported; external upload avoided",
      "project files not modified by import",
      "web-check does not replace screenshot / interactive / human UI validation",
    ]
    if decision == .failed {
      result.append("blocking errors: \(summary.errors); warnings: \(summary.warnings)")
    }
    return result
  }

  private static func defaultScanType(mode: WorkModeID, targetKind: TatwoWebCheckTargetKind)
    -> TatwoWebCheckScanType
  {
    if targetKind == .publicURL { return .publicURL }
    switch mode {
    case .s: return .focused
    case .m, .l, .xl, .xxl: return .full
    }
  }

  private static func defaultBlockingPolicy(mode: WorkModeID) -> TatwoWebCheckBlockingPolicy {
    switch mode {
    case .s, .m: return .reportOnly
    case .l, .xl, .xxl: return .noNewError
    }
  }

  private static func requiredForPass(mode: WorkModeID, scenarioProfileID: String) -> Bool {
    isFrontendStrictScenario(scenarioProfileID) && (mode >= .l)
  }

  private static func isFrontendStrictScenario(_ scenarioProfileID: String) -> Bool {
    let normalized = scenarioProfileID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "ui-ux" || normalized == "design" || normalized == "editing"
  }

  private static func inferTargetKind(_ rawTarget: String) -> TatwoWebCheckTargetKind {
    let normalized = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.hasPrefix("http://") || normalized.hasPrefix("https://")
      ? .publicURL : .localProject
  }

  private static func sanitizedTargetLabel(_ rawTarget: String, targetKind: TatwoWebCheckTargetKind)
    -> String
  {
    let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if targetKind == .publicURL { return trimmed.isEmpty ? "https://example.invalid" : trimmed }
    return trimmed.isEmpty ? "<local-frontend-project>" : "<local-frontend-project>"
  }

  private static func localOnlyReportLabel(_ path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? "local-only:<report.json>" : "local-only:\(name)"
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func intValue(_ value: Any?) -> Int {
    switch value {
    case let value as Int: return value
    case let value as NSNumber: return value.intValue
    case let value as String: return Int(value) ?? 0
    default: return 0
    }
  }
}

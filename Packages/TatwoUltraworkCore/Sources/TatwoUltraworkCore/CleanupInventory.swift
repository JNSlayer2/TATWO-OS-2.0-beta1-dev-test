import CryptoKit
import Foundation

public struct PostValidationCleanupCandidateV1: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let relativePath: String
  public let origin: String
  public let removalReason: String
  public let producedByReceiptID: String?
  public let safeToRemove: Bool
  public let mustKeep: Bool
  public let deletionRisk: String

  public init(
    id: String,
    relativePath: String,
    origin: String,
    removalReason: String,
    producedByReceiptID: String? = nil,
    safeToRemove: Bool,
    mustKeep: Bool = false,
    deletionRisk: String
  ) {
    self.id = TatwoPrivacyRedactor.redacted(id.trimmingCharacters(in: .whitespacesAndNewlines))
    self.relativePath = TatwoPrivacyRedactor.redacted(
      relativePath.trimmingCharacters(in: .whitespacesAndNewlines))
    self.origin = TatwoPrivacyRedactor.redacted(origin.trimmingCharacters(in: .whitespacesAndNewlines))
    self.removalReason = TatwoPrivacyRedactor.redacted(
      removalReason.trimmingCharacters(in: .whitespacesAndNewlines))
    self.producedByReceiptID = producedByReceiptID.map {
      TatwoPrivacyRedactor.redacted($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    self.safeToRemove = safeToRemove
    self.mustKeep = mustKeep
    self.deletionRisk = TatwoPrivacyRedactor.redacted(
      deletionRisk.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public struct PostValidationCleanupInventoryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let runID: String
  public let createdAt: Date
  public let validatedGoalID: String
  public let validatedContractID: String?
  public let candidateFiles: [PostValidationCleanupCandidateV1]
  public let mustKeep: [String]
  public let markdownPath: String
  public let markdownSHA256: String
  public let trashBundlePath: String
  public let deletionRequiresHumanApproval: Bool
  public let summary: String
  public let redactionPolicy: String

  public init(
    schema: String = "TatwoPostValidationCleanupInventoryV1",
    runID: String,
    createdAt: Date = Date(),
    validatedGoalID: String,
    validatedContractID: String? = nil,
    candidateFiles: [PostValidationCleanupCandidateV1],
    mustKeep: [String],
    markdownPath: String,
    markdownSHA256: String,
    trashBundlePath: String,
    deletionRequiresHumanApproval: Bool = true,
    summary: String,
    redactionPolicy: String = "public-safe: no tokens, auth, raw logs, full chats, private absolute paths, or local-only screenshots"
  ) {
    self.schema = schema
    self.runID = TatwoPrivacyRedactor.redacted(runID.trimmingCharacters(in: .whitespacesAndNewlines))
    self.createdAt = createdAt
    self.validatedGoalID = TatwoPrivacyRedactor.redacted(
      validatedGoalID.trimmingCharacters(in: .whitespacesAndNewlines))
    self.validatedContractID = validatedContractID.map {
      TatwoPrivacyRedactor.redacted($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    self.candidateFiles = candidateFiles
    self.mustKeep = mustKeep.map {
      TatwoPrivacyRedactor.redacted($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    self.markdownPath = TatwoPrivacyRedactor.redacted(
      markdownPath.trimmingCharacters(in: .whitespacesAndNewlines))
    self.markdownSHA256 = TatwoPrivacyRedactor.redacted(
      markdownSHA256.trimmingCharacters(in: .whitespacesAndNewlines))
    self.trashBundlePath = TatwoPrivacyRedactor.redacted(
      trashBundlePath.trimmingCharacters(in: .whitespacesAndNewlines))
    self.deletionRequiresHumanApproval = deletionRequiresHumanApproval
    self.summary = TatwoPrivacyRedactor.redacted(summary.trimmingCharacters(in: .whitespacesAndNewlines))
    self.redactionPolicy = TatwoPrivacyRedactor.redacted(
      redactionPolicy.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public enum PostValidationCleanupInventoryFactory {
  public static let receiptID = "cleanup-inventory"

  public static var receiptRequirement: WorkOSReceiptRequirement {
    WorkOSReceiptRequirement(
      id: receiptID,
      title: "驗收後可移除檔案盤點",
      kind: "cleanup_inventory",
      requiredForPass: true,
      plainPurpose: "驗收通過後先盤點可刪檔案，寫 Markdown 說明並放入待刪/垃圾桶審核包；未經人工核准不真刪。")
  }

  public static func defaultTrashBundlePath(runID: String) -> String {
    ".tatwo-ultrawork/待刪垃圾檔案/\(safePathComponent(runID))"
  }

  public static func defaultMarkdownPath(runID: String) -> String {
    "\(defaultTrashBundlePath(runID: runID))/README-待刪檔案來源.md"
  }

  public static func noCandidateInventory(
    runID: String,
    validatedGoalID: String,
    validatedContractID: String? = nil,
    mustKeep: [String] = [],
    summary: String = "驗收通過後已完成清理盤點；目前沒有建議移除檔案。"
  ) -> PostValidationCleanupInventoryV1 {
    make(
      runID: runID,
      validatedGoalID: validatedGoalID,
      validatedContractID: validatedContractID,
      candidateFiles: [],
      mustKeep: mustKeep,
      summary: summary)
  }

  public static func make(
    runID: String,
    validatedGoalID: String,
    validatedContractID: String? = nil,
    candidateFiles: [PostValidationCleanupCandidateV1],
    mustKeep: [String] = [],
    markdownPath: String? = nil,
    trashBundlePath: String? = nil,
    summary: String
  ) -> PostValidationCleanupInventoryV1 {
    let bundle = trashBundlePath ?? defaultTrashBundlePath(runID: runID)
    let markdown = markdownPath ?? "\(bundle)/README-待刪檔案來源.md"
    let preview = PostValidationCleanupInventoryV1(
      runID: runID,
      validatedGoalID: validatedGoalID,
      validatedContractID: validatedContractID,
      candidateFiles: candidateFiles,
      mustKeep: mustKeep,
      markdownPath: markdown,
      markdownSHA256: "pending",
      trashBundlePath: bundle,
      deletionRequiresHumanApproval: true,
      summary: summary)
    let body = markdownBody(for: preview)
    return PostValidationCleanupInventoryV1(
      runID: runID,
      validatedGoalID: validatedGoalID,
      validatedContractID: validatedContractID,
      candidateFiles: candidateFiles,
      mustKeep: mustKeep,
      markdownPath: markdown,
      markdownSHA256: sha256Hex(Data(body.utf8)),
      trashBundlePath: bundle,
      deletionRequiresHumanApproval: true,
      summary: summary)
  }

  public static func markdownBody(for inventory: PostValidationCleanupInventoryV1) -> String {
    var lines: [String] = [
      "# TATWO 驗收後待刪檔案盤點",
      "",
      "- Schema: \(inventory.schema)",
      "- Run ID: \(inventory.runID)",
      "- Goal ID: \(inventory.validatedGoalID)",
      "- Contract ID: \(inventory.validatedContractID ?? "none")",
      "- Trash review bundle: \(inventory.trashBundlePath)",
      "- Deletion requires human approval: \(inventory.deletionRequiresHumanApproval ? "yes" : "no")",
      "",
      "## 來源與用途",
      inventory.summary.isEmpty ? "驗收通過後建立，用於未來刪除前確認來源與合理性。" : inventory.summary,
      "",
      "## 可移除候選",
    ]

    if inventory.candidateFiles.isEmpty {
      lines.append("- 目前沒有建議移除檔案；此 Markdown 作為已盤點收據。")
    } else {
      for candidate in inventory.candidateFiles {
        lines.append(
          "- `\(candidate.relativePath)` — 來源：\(candidate.origin)；原因：\(candidate.removalReason)；風險：\(candidate.deletionRisk)；可移除：\(candidate.safeToRemove ? "yes" : "no")")
      }
    }

    lines.append("")
    lines.append("## 必須保留")
    if inventory.mustKeep.isEmpty {
      lines.append("- 無特別列名；仍需人工確認後才可刪除候選。")
    } else {
      for path in inventory.mustKeep {
        lines.append("- `\(path)`")
      }
    }

    lines.append("")
    lines.append("## 刪除規則")
    lines.append("1. 此清單只代表候選盤點，不代表已刪除。")
    lines.append("2. 真正移除前必須由人類確認。")
    lines.append("3. 若檔案可能包含 token、auth、raw log、完整聊天、私有絕對路徑或本機截圖，不得放入公開報告。")
    lines.append("")
    return lines.joined(separator: "\n")
  }

  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func safePathComponent(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = trimmed.map { char -> Character in
      if char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." {
        return char
      }
      return "-"
    }
    let value = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return value.isEmpty ? "run" : value
  }
}

public struct PostValidationCleanupInventoryWriteResultV1: Codable, Sendable, Equatable {
  public let schema: String
  public let runID: String
  public let markdownPath: String
  public let jsonPath: String
  public let trashBundlePath: String
  public let candidateCount: Int
  public let mustKeepCount: Int
  public let markdownSHA256: String
  public let dryRun: Bool
  public let deletionRequiresHumanApproval: Bool
  public let nextAction: String
}

public enum PostValidationCleanupInventoryWriter {
  public static func write(
    _ inventory: PostValidationCleanupInventoryV1,
    root: URL,
    dryRun: Bool = false
  ) throws -> PostValidationCleanupInventoryWriteResultV1 {
    let markdownURL = try resolveReviewURL(root: root, relativePath: inventory.markdownPath)
    let bundleURL = try resolveReviewURL(root: root, relativePath: inventory.trashBundlePath)
    let jsonURL = bundleURL.appendingPathComponent("cleanup-inventory.json", isDirectory: false)

    if !dryRun {
      try FileManager.default.createDirectory(
        at: bundleURL, withIntermediateDirectories: true, attributes: nil)
      try Data(PostValidationCleanupInventoryFactory.markdownBody(for: inventory).utf8)
        .write(to: markdownURL, options: [.atomic])

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(inventory).write(to: jsonURL, options: [.atomic])
    }

    return PostValidationCleanupInventoryWriteResultV1(
      schema: "TatwoPostValidationCleanupInventoryWriteResultV1",
      runID: inventory.runID,
      markdownPath: inventory.markdownPath,
      jsonPath: "\(inventory.trashBundlePath)/cleanup-inventory.json",
      trashBundlePath: inventory.trashBundlePath,
      candidateCount: inventory.candidateFiles.count,
      mustKeepCount: inventory.mustKeep.count,
      markdownSHA256: inventory.markdownSHA256,
      dryRun: dryRun,
      deletionRequiresHumanApproval: inventory.deletionRequiresHumanApproval,
      nextAction: dryRun
        ? "dry-run only；確認候選清單後再用 cleanup-inventory write 寫入待刪審核包。"
        : "Markdown 與 JSON 收據已寫入待刪審核包；真刪除仍需人工確認。")
  }

  private static func resolveReviewURL(root: URL, relativePath: String) throws -> URL {
    let normalized = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.hasPrefix("~") else {
      throw CleanupInventoryWriterError.invalidReviewPath
    }
    guard normalized.split(separator: "/").allSatisfy({ $0 != ".." }) else {
      throw CleanupInventoryWriterError.invalidReviewPath
    }
    guard normalized.hasPrefix(".tatwo-ultrawork/待刪垃圾檔案/")
      || normalized.hasPrefix(".tatwo-ultrawork/trash-review/")
    else {
      throw CleanupInventoryWriterError.invalidReviewPath
    }
    return root.appendingPathComponent(normalized, isDirectory: false)
  }
}

public enum CleanupInventoryWriterError: Error, LocalizedError {
  case invalidReviewPath

  public var errorDescription: String? {
    switch self {
    case .invalidReviewPath:
      return "cleanup inventory path must stay under .tatwo-ultrawork/待刪垃圾檔案/ or .tatwo-ultrawork/trash-review/"
    }
  }
}

public enum PostValidationCleanupInventoryGate {
  public static func evaluate(
    _ inventory: PostValidationCleanupInventoryV1,
    fileSystem: EvidenceFileSystem = LocalEvidenceFileSystem()
  ) -> GateResult {
    var reasons: [String] = []

    if inventory.schema != "TatwoPostValidationCleanupInventoryV1" {
      reasons.append("cleanup_inventory_unsupported_schema")
    }
    if inventory.runID.isEmpty { reasons.append("cleanup_inventory_missing_run_id") }
    if inventory.validatedGoalID.isEmpty { reasons.append("cleanup_inventory_missing_goal_id") }
    if !inventory.deletionRequiresHumanApproval {
      reasons.append("cleanup_inventory_requires_human_delete_approval")
    }
    if inventory.summary.isEmpty { reasons.append("cleanup_inventory_missing_summary") }
    if inventory.markdownPath.isEmpty || !inventory.markdownPath.hasSuffix(".md") {
      reasons.append("cleanup_inventory_markdown_path_invalid")
    }
    if inventory.markdownSHA256.isEmpty || inventory.markdownSHA256 == "pending" {
      reasons.append("cleanup_inventory_markdown_hash_missing")
    }
    if inventory.trashBundlePath.isEmpty { reasons.append("cleanup_inventory_missing_trash_bundle") }

    let scannedStrings = [
      inventory.runID,
      inventory.validatedGoalID,
      inventory.validatedContractID ?? "",
      inventory.markdownPath,
      inventory.trashBundlePath,
      inventory.summary,
      inventory.redactionPolicy,
    ] + inventory.mustKeep
      + inventory.candidateFiles.flatMap { candidate in
        [
          candidate.id, candidate.relativePath, candidate.origin, candidate.removalReason,
          candidate.producedByReceiptID ?? "", candidate.deletionRisk,
        ]
      }

    if scannedStrings.contains(where: containsPrivateMaterial) {
      reasons.append("cleanup_inventory_contains_private_or_secret_material")
    }

    if !isAllowedReviewPath(inventory.markdownPath) {
      reasons.append("cleanup_inventory_markdown_outside_review_root")
    }
    if !isAllowedReviewPath(inventory.trashBundlePath) {
      reasons.append("cleanup_inventory_bundle_outside_review_root")
    }

    for candidate in inventory.candidateFiles {
      if candidate.id.isEmpty { reasons.append("cleanup_candidate_missing_id") }
      if candidate.relativePath.isEmpty {
        reasons.append("cleanup_candidate_missing_path:\(candidate.id)")
      }
      if candidate.origin.isEmpty { reasons.append("cleanup_candidate_missing_origin:\(candidate.id)") }
      if candidate.removalReason.isEmpty {
        reasons.append("cleanup_candidate_missing_reason:\(candidate.id)")
      }
      if candidate.deletionRisk.isEmpty {
        reasons.append("cleanup_candidate_missing_risk:\(candidate.id)")
      }
      if candidate.safeToRemove && candidate.mustKeep {
        reasons.append("cleanup_candidate_conflicting_keep_remove:\(candidate.id)")
      }
    }

    guard fileSystem.fileExists(atPath: inventory.markdownPath) else {
      reasons.append("cleanup_inventory_markdown_file_missing")
      return GateResult(status: reasons.isEmpty ? .passed : .failed, reasons: reasons)
    }

    do {
      let markdownData = try fileSystem.data(atPath: inventory.markdownPath)
      let actual = PostValidationCleanupInventoryFactory.sha256Hex(markdownData)
      if actual.lowercased() != inventory.markdownSHA256.lowercased() {
        reasons.append("cleanup_inventory_markdown_hash_mismatch")
      }
      if let body = String(data: markdownData, encoding: .utf8), containsPrivateMaterial(body) {
        reasons.append("cleanup_inventory_markdown_contains_private_or_secret_material")
      }
    } catch {
      reasons.append("cleanup_inventory_markdown_unreadable")
    }

    return GateResult(status: reasons.isEmpty ? .passed : .failed, reasons: reasons)
  }

  private static func isAllowedReviewPath(_ path: String) -> Bool {
    let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.hasPrefix(".tatwo-ultrawork/待刪垃圾檔案/")
      || normalized.hasPrefix(".tatwo-ultrawork/trash-review/")
  }

  private static func containsPrivateMaterial(_ raw: String) -> Bool {
    guard !raw.isEmpty else { return false }
    let redacted = TatwoPrivacyRedactor.redacted(raw)
    if redacted != raw { return true }
    let denied = [
      #"(?i)authorization\s*:"#,
      #"(?i)access[_-]?token"#,
      #"(?i)refresh[_-]?token"#,
      #"(?i)api[_-]?key"#,
      #"(?i)cookie"#,
    ]
    return denied.contains { pattern in
      raw.range(of: pattern, options: .regularExpression) != nil
    }
  }
}

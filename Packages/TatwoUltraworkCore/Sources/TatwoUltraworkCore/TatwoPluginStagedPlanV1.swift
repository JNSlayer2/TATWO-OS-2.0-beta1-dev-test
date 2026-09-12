import Foundation

// MARK: - Plan action

/// Per-entry staged plan action for one brand surface.
///
/// - `create`: registry wants server; readback missing it.
/// - `update`: differs from registry and last-known controller-owned (S3 receipt set).
/// - `unchanged`: managed fields match projected desired.
/// - `conflict`: differs from registry and **not** proven controller-owned (fail-closed).
public enum TatwoPluginStagedPlanActionV1: String, Codable, Sendable, CaseIterable, Equatable {
  case create
  case update
  case unchanged
  case conflict
  case notProjectable = "not_projectable"
}

public enum TatwoPluginOwnershipStateV1: String, Codable, Sendable, Equatable, Hashable {
  case active
  case rolledBack = "rolled_back"
}

/// Provenance for one successful S3 apply.  A server ID alone is not
/// ownership evidence: the record is bound to brand, logical target, the
/// exact applied fragment hash, and the registry revision/time that produced
/// it.
public struct TatwoPluginOwnershipRecordV1: Codable, Sendable, Equatable, Hashable {
  public let serverID: String
  public let brand: TatwoPluginProjectionBrandV1
  public let targetPath: String
  public let appliedFragmentSHA256: String
  public let appliedAtRevision: String
  public let appliedAt: String
  /// Rollback provenance is explicit so a later plan cannot treat a restored
  /// target as an unchanged controller-owned apply.
  public let state: TatwoPluginOwnershipStateV1

  public init(
    serverID: String,
    brand: TatwoPluginProjectionBrandV1,
    targetPath: String,
    appliedFragmentSHA256: String,
    appliedAtRevision: String,
    appliedAt: String,
    state: TatwoPluginOwnershipStateV1 = .active
  ) {
    self.serverID = serverID
    self.brand = brand
    self.targetPath = targetPath
    self.appliedFragmentSHA256 = appliedFragmentSHA256.lowercased()
    self.appliedAtRevision = appliedAtRevision
    self.appliedAt = appliedAt
    self.state = state
  }

  private enum CodingKeys: String, CodingKey {
    case serverID, brand, targetPath, appliedFragmentSHA256, appliedAtRevision, appliedAt, state
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.serverID = try container.decode(String.self, forKey: .serverID)
    self.brand = try container.decode(TatwoPluginProjectionBrandV1.self, forKey: .brand)
    self.targetPath = try container.decode(String.self, forKey: .targetPath)
    self.appliedFragmentSHA256 = try container.decode(String.self, forKey: .appliedFragmentSHA256).lowercased()
    self.appliedAtRevision = try container.decode(String.self, forKey: .appliedAtRevision)
    self.appliedAt = try container.decode(String.self, forKey: .appliedAt)
    self.state = try container.decodeIfPresent(TatwoPluginOwnershipStateV1.self, forKey: .state) ?? .active
  }
}

// MARK: - Plan items + document

public struct TatwoPluginStagedPlanItemV1: Codable, Sendable, Equatable, Identifiable {
  public var id: String { "\(brand.rawValue):\(entryID)" }

  public let entryID: String
  public let entryType: TatwoPluginEntryTypeV1
  public let brand: TatwoPluginProjectionBrandV1
  public let action: TatwoPluginStagedPlanActionV1
  public let logicalPath: String?
  public let templateID: String?
  public let projectedBody: String?
  public let observedManagedText: String?
  public let desiredManagedText: String?
  public let unifiedDiff: String
  public let requiresHumanGate: Bool
  public let reason: String?

  public init(
    entryID: String,
    entryType: TatwoPluginEntryTypeV1,
    brand: TatwoPluginProjectionBrandV1,
    action: TatwoPluginStagedPlanActionV1,
    logicalPath: String? = nil,
    templateID: String? = nil,
    projectedBody: String? = nil,
    observedManagedText: String? = nil,
    desiredManagedText: String? = nil,
    unifiedDiff: String,
    requiresHumanGate: Bool = true,
    reason: String? = nil
  ) {
    self.entryID = entryID
    self.entryType = entryType
    self.brand = brand
    self.action = action
    self.logicalPath = logicalPath
    self.templateID = templateID
    self.projectedBody = projectedBody
    self.observedManagedText = observedManagedText
    self.desiredManagedText = desiredManagedText
    self.unifiedDiff = unifiedDiff
    // S2 never applies; human gate is always required before S3 apply.
    self.requiresHumanGate = requiresHumanGate
    self.reason = reason
  }
}

public struct TatwoPluginStagedPlanDocumentV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoPluginStagedPlanV1"

  public let schema: String
  public let registryRevision: String
  public let rendererVersion: String
  public let brands: [TatwoPluginProjectionBrandV1]
  public let items: [TatwoPluginStagedPlanItemV1]
  /// Always true in S2; S3 is the only apply stage.
  public let requiresHumanGate: Bool
  public let writesNativeConfig: Bool
  public let notes: [String]

  public init(
    schema: String = TatwoPluginStagedPlanDocumentV1.schemaName,
    registryRevision: String,
    rendererVersion: String = TatwoPluginProjectionV1.rendererVersion,
    brands: [TatwoPluginProjectionBrandV1],
    items: [TatwoPluginStagedPlanItemV1],
    requiresHumanGate: Bool = true,
    writesNativeConfig: Bool = false,
    notes: [String] = TatwoPluginStagedPlanDocumentV1.defaultNotes
  ) {
    self.schema = schema
    self.registryRevision = registryRevision
    self.rendererVersion = rendererVersion
    self.brands = brands
    self.items = items
    self.requiresHumanGate = true
    self.writesNativeConfig = false
    self.notes = notes
  }

  public static let defaultNotes: [String] = [
    "S2 staged projection + diff only; no native apply",
    "requiresHumanGate is always true; S3 owns per-apply human gate",
    "conflict = observed differs from registry and server is not proven controller-owned",
    "Paths are logical (~/.codex|~/.claude); real IO uses injected fixture paths only",
  ]

  public var itemsByAction: [TatwoPluginStagedPlanActionV1: [TatwoPluginStagedPlanItemV1]] {
    Dictionary(grouping: items, by: \.action)
  }
}

// MARK: - Planner

public enum TatwoPluginStagedPlanErrorV1: Error, LocalizedError, Sendable, Equatable {
  case emptyBrands
  case projectionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .emptyBrands:
      return "Staged plan requires at least one brand"
    case .projectionFailed(let detail):
      return "Staged plan projection failed: \(detail)"
    }
  }
}

/// Build staged plan from OS registry + injected readback inventory.
///
/// Does not read or write `~/.codex` / `~/.claude`. Supply observed servers
/// from `TatwoPluginConfigReadback` fixture paths, or empty arrays.
public enum TatwoPluginStagedPlanV1 {
  /// Per-target provenance records previously produced by S3 apply receipts.
  /// Missing, cross-brand, wrong-target, stale-hash, or malformed provenance
  /// never grants update authority; managed-field differences are `conflict`.
  public static func build(
    registry: TatwoPluginControllerRegistryDocumentV1,
    brands: [TatwoPluginProjectionBrandV1] = TatwoPluginProjectionBrandV1.allCases,
    codexServers: [TatwoPluginObservedMcpServerV1] = [],
    claudeServers: [TatwoPluginObservedMcpServerV1] = [],
    ownershipRecords: [TatwoPluginOwnershipRecordV1] = []
  ) throws -> TatwoPluginStagedPlanDocumentV1 {
    let uniqueBrands = orderedUniqueBrands(brands)
    guard !uniqueBrands.isEmpty else {
      throw TatwoPluginStagedPlanErrorV1.emptyBrands
    }

    let codexByID = Dictionary(
      uniqueKeysWithValues: codexServers.map { ($0.serverID, $0) })
    let claudeByID = Dictionary(
      uniqueKeysWithValues: claudeServers.map { ($0.serverID, $0) })

    var items: [TatwoPluginStagedPlanItemV1] = []

    for entry in registry.entries.sorted(by: { $0.id < $1.id }) {
      for brand in uniqueBrands {
        let outcome: TatwoPluginProjectionOutcomeV1
        do {
          outcome = try TatwoPluginProjectionV1.project(entry: entry, brand: brand)
        } catch {
          throw TatwoPluginStagedPlanErrorV1.projectionFailed(
            "\(entry.id)/\(brand.rawValue): \(error.localizedDescription)")
        }

        switch outcome {
        case .notProjectable(let reason):
          // Only emit one not_projectable row per entry (first brand) to avoid noise,
          // but keep brand for schema symmetry when type is non-portable.
          if brand == uniqueBrands.first {
            items.append(
              TatwoPluginStagedPlanItemV1(
                entryID: entry.id,
                entryType: entry.type,
                brand: brand,
                action: .notProjectable,
                unifiedDiff: "",
                requiresHumanGate: true,
                reason: reason))
          }

        case .projected(let fragment):
          if entry.desiredState == .disabled {
            // Disabled entries do not stage create/update of native MCP in S2.
            items.append(
              TatwoPluginStagedPlanItemV1(
                entryID: entry.id,
                entryType: entry.type,
                brand: brand,
                action: .unchanged,
                logicalPath: fragment.logicalPath,
                templateID: fragment.templateID,
                projectedBody: fragment.body,
                desiredManagedText: fragment.managed.stableManagedText(),
                unifiedDiff: "",
                requiresHumanGate: true,
                reason: "desiredState=disabled; S2 does not stage native disable apply"))
            continue
          }

          let observedServer: TatwoPluginObservedMcpServerV1?
          switch brand {
          case .codex: observedServer = codexByID[entry.id]
          case .claude: observedServer = claudeByID[entry.id]
          }

          let desiredText = fragment.managed.stableManagedText()
          let observedManaged = observedServer.map { TatwoPluginManagedMcpFieldsV1.fromObserved($0) }
          let observedText = observedManaged?.stableManagedText()

          let action: TatwoPluginStagedPlanActionV1
          let reason: String?
          let matchingOwnership = ownershipRecords.filter {
            $0.serverID == entry.id
              && $0.brand == brand
              && $0.targetPath == fragment.logicalPath
          }
          let ownership = matchingOwnership.first(where: { $0.state == .active })
          if matchingOwnership.contains(where: { $0.state == .rolledBack }) {
            action = .conflict
            reason =
              "managed fields are associated with rolled-back provenance; re-approval required (fail-closed)"
          } else if observedServer == nil {
            action = .create
            reason = "registry portable_mcp missing from \(brand.rawValue) readback"
          } else if let observedManaged, fragment.managed.managedEquals(observedManaged) {
            action = .unchanged
            reason = "managed fields match projected desired"
          } else {
            let currentHash = observedManaged.flatMap {
              try? TatwoPluginProjectionV1.fragmentSHA256(managed: $0, brand: brand)
            }
            if let ownership,
               ownership.state == .active,
               let currentHash,
               currentHash.caseInsensitiveCompare(ownership.appliedFragmentSHA256) == .orderedSame
            {
              action = .update
              reason =
                "managed fields differ; current fragment matches last-applied hash \(ownership.appliedAtRevision)"
            } else if ownership == nil {
              action = .conflict
              reason =
                "managed fields differ and no matching brand/target ownership record exists (fail-closed; human gate)"
            } else {
              action = .conflict
              reason =
                "managed fields differ; current fragment hash does not match last-applied ownership (user edit; fail-closed)"
            }
          }

          let pathLabel = fragment.logicalPath
          let unifiedDiff: String
          switch action {
          case .unchanged:
            unifiedDiff = ""
          case .create:
            unifiedDiff = TatwoPluginUnifiedDiffV1.diff(
              path: pathLabel,
              oldText: "",
              newText: desiredText)
          case .update, .conflict:
            unifiedDiff = TatwoPluginUnifiedDiffV1.diff(
              path: pathLabel,
              oldText: observedText ?? "",
              newText: desiredText)
          case .notProjectable:
            unifiedDiff = ""
          }

          items.append(
            TatwoPluginStagedPlanItemV1(
              entryID: entry.id,
              entryType: entry.type,
              brand: brand,
              action: action,
              logicalPath: fragment.logicalPath,
              templateID: fragment.templateID,
              projectedBody: fragment.body,
              observedManagedText: observedText,
              desiredManagedText: desiredText,
              unifiedDiff: unifiedDiff,
              requiresHumanGate: true,
              reason: reason))
        }
      }
    }

    return TatwoPluginStagedPlanDocumentV1(
      registryRevision: registry.registryRevision,
      brands: uniqueBrands,
      items: items)
  }

  /// Convenience: build from registry + readback report (+ optional ownership records).
  public static func build(
    registry: TatwoPluginControllerRegistryDocumentV1,
    readback: TatwoPluginConfigReadbackReportV1,
    brands: [TatwoPluginProjectionBrandV1] = TatwoPluginProjectionBrandV1.allCases,
    ownershipRecords: [TatwoPluginOwnershipRecordV1] = []
  ) throws -> TatwoPluginStagedPlanDocumentV1 {
    try build(
      registry: registry,
      brands: brands,
      codexServers: readback.codexServers,
      claudeServers: readback.claudeServers,
      ownershipRecords: ownershipRecords)
  }

  /// Load registry + fixture configs (injected paths only), then plan.
  public static func buildFromInjectedPaths(
    registryURL: URL,
    codexConfigURL: URL?,
    claudeMcpJSONURL: URL?,
    brands: [TatwoPluginProjectionBrandV1] = TatwoPluginProjectionBrandV1.allCases,
    ownershipRecords: [TatwoPluginOwnershipRecordV1] = [],
    allowedRootURL: URL? = nil
  ) throws -> TatwoPluginStagedPlanDocumentV1 {
    let registry = try TatwoPluginControllerRegistryLoaderV1.load(from: registryURL)
    let report = try TatwoPluginConfigReadback.readback(
      registry: registry,
      codexConfigURL: codexConfigURL,
      claudeMcpJSONURL: claudeMcpJSONURL,
      allowedRootURL: allowedRootURL)
    return try build(
      registry: registry,
      readback: report,
      brands: brands,
      ownershipRecords: ownershipRecords)
  }

  private static func orderedUniqueBrands(
    _ brands: [TatwoPluginProjectionBrandV1]
  ) -> [TatwoPluginProjectionBrandV1] {
    var seen = Set<TatwoPluginProjectionBrandV1>()
    var out: [TatwoPluginProjectionBrandV1] = []
    for brand in brands {
      if seen.insert(brand).inserted {
        out.append(brand)
      }
    }
    return out
  }
}

// MARK: - Unified diff (stable)

public enum TatwoPluginUnifiedDiffV1 {
  /// Minimal stable unified diff. Same inputs always produce the same string.
  public static func diff(path: String, oldText: String, newText: String) -> String {
    let oldLines = splitLines(oldText)
    let newLines = splitLines(newText)
    if oldLines == newLines {
      return ""
    }

    var out: [String] = []
    out.append("--- a/\(path)")
    out.append("+++ b/\(path)")
    // Single hunk covering full managed text (small fragments; stable, no context heuristics).
    let oldCount = max(oldLines.count, 0)
    let newCount = max(newLines.count, 0)
    let oldStart = oldCount == 0 ? 0 : 1
    let newStart = newCount == 0 ? 0 : 1
    out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
    for line in oldLines {
      out.append("-\(line)")
    }
    for line in newLines {
      out.append("+\(line)")
    }
    return out.joined(separator: "\n") + "\n"
  }

  private static func splitLines(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Drop trailing empty line produced by final newline so "+line\n" ↔ ["line"]
    if text.hasSuffix("\n"), let last = lines.last, last.isEmpty {
      lines.removeLast()
    }
    return lines
  }
}

// MARK: - S1 protocol adapter (writesNativeConfig stays false)

public struct TatwoPluginStagedProjectionPlannerV1: TatwoPluginStagedProjectionPlanningV1 {
  public init() {}

  public func planProjection(
    registry: TatwoPluginControllerRegistryDocumentV1,
    entryID: String
  ) throws -> TatwoPluginStagedProjectionPlanV1 {
    guard let entry = registry.entries.first(where: { $0.id == entryID }) else {
      return TatwoPluginStagedProjectionPlanV1(
        registryRevision: registry.registryRevision,
        entryID: entryID,
        targets: [],
        writesNativeConfig: false)
    }

    var targets: [TatwoPluginStagedProjectionTargetV1] = []
    for brand in TatwoPluginProjectionBrandV1.allCases {
      let outcome = try TatwoPluginProjectionV1.project(entry: entry, brand: brand)
      if case .projected(let fragment) = outcome {
        targets.append(
          TatwoPluginStagedProjectionTargetV1(
            brand: brand.rawValue,
            logicalPath: fragment.logicalPath,
            templateID: fragment.templateID))
      }
    }
    return TatwoPluginStagedProjectionPlanV1(
      registryRevision: registry.registryRevision,
      entryID: entryID,
      targets: targets,
      writesNativeConfig: false)
  }
}

import CryptoKit
import Foundation

/// B2 (真分工橋) — the binding→dispatch bridge.
///
/// `contract.identityBindings` names which model each identity role (主導/副審/sub/驗收)
/// should run on, but nothing turned that into an actual dispatch — the bindings were
/// display-only. This manifest is the missing link: `begin()` derives, from the contract's
/// bindings, a per-binding dispatch plan whose eligibility uses the SAME allowlist the real
/// `gateway.dispatch` gate uses (so the manifest never claims a model is dispatchable when
/// the gateway would reject it). The manifest is persisted via `TatwoDispatchRegistry`; the
/// Node MCP layer (which owns the live HTTP dispatch) is its executor.
public enum TatwoExecutionManifestStatus: String, Codable, Sendable, Equatable {
  /// Has a modelID that normalizes into the gateway allowlist — ready for gateway.dispatch.
  case planned
  /// No modelID, or the model isn't gateway-allowlisted — not dispatchable, shown as skipped.
  case skipped
}

public struct TatwoExecutionManifestEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let bindingID: String
  public let sourceSlotID: String
  public let identity: IdentityKind
  public let modelID: String?
  public let subtask: String
  public let status: TatwoExecutionManifestStatus

  public init(
    id: String,
    bindingID: String,
    sourceSlotID: String,
    identity: IdentityKind,
    modelID: String?,
    subtask: String,
    status: TatwoExecutionManifestStatus
  ) {
    self.id = id
    self.bindingID = bindingID
    self.sourceSlotID = sourceSlotID
    self.identity = identity
    self.modelID = modelID
    self.subtask = subtask
    self.status = status
  }
}

public struct TatwoExecutionManifestV1: Codable, Sendable, Equatable {
  public let schema: String
  public let contractID: String
  public let goalID: String
  public let generatedAt: Date
  public let entries: [TatwoExecutionManifestEntry]

  public init(
    schema: String = "TatwoExecutionManifestV1",
    contractID: String,
    goalID: String,
    generatedAt: Date,
    entries: [TatwoExecutionManifestEntry]
  ) {
    self.schema = schema
    self.contractID = contractID
    self.goalID = goalID
    self.generatedAt = Date(
      timeIntervalSince1970:
        generatedAt.timeIntervalSince1970.rounded(.down))
    self.entries = entries
  }

  /// Canonical digest persisted beside the complete manifest.
  ///
  /// The digest covers the full dispatch plan, not only entry IDs. JSON keys
  /// are sorted and dates are whole-second ISO-8601 so a durable readback has
  /// the same identity as the in-memory value.
  public func canonicalSHA256() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let digest = SHA256.hash(data: try encoder.encode(self))
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }

  public func validateAuthorityBinding(
    contract: TatwoWorkOSContractV1
  ) throws {
    guard schema == "TatwoExecutionManifestV1",
      contractID == contract.contractID,
      goalID == contract.goalID
    else {
      throw TatwoExecutionManifestValidationError.contractMismatch
    }
    let expected = TatwoExecutionManifestFactory.make(
      contract: contract,
      generatedAt: generatedAt)
    guard entries == expected.entries else {
      throw TatwoExecutionManifestValidationError.entryBindingMismatch
    }
    let ids = entries.map(\.id)
    guard Set(ids).count == ids.count else {
      throw TatwoExecutionManifestValidationError.duplicateEntryID
    }
  }
}

public enum TatwoExecutionManifestValidationError:
  Error, LocalizedError, Sendable, Equatable
{
  case contractMismatch
  case entryBindingMismatch
  case duplicateEntryID

  public var errorDescription: String? {
    switch self {
    case .contractMismatch:
      return "Execution manifest contract/Goal identity mismatch."
    case .entryBindingMismatch:
      return "Execution manifest entries do not match issued identity bindings."
    case .duplicateEntryID:
      return "Execution manifest contains duplicate entry IDs."
    }
  }
}

public enum TatwoExecutionManifestFactory {
  /// Is this binding's model actually dispatchable through the gateway? Reuses the same
  /// allowlist + normalizer as `gateway.dispatch` (widened to `internal` for this reason).
  public static func isDispatchable(modelID: String?) -> Bool {
    let normalized = TatwoMCPRegistry.normalizeGatewayModel(modelID)
    return !normalized.isEmpty
      && TatwoMCPRegistry.gatewayAllowedModels.contains(normalized)
      && TatwoModelIdentityRegistry.isActiveDispatchEligible(normalized)
  }

  public static func make(
    contract: TatwoWorkOSContractV1,
    generatedAt: Date = Date()
  ) -> TatwoExecutionManifestV1 {
    let objective = contract.objective.trimmingCharacters(in: .whitespacesAndNewlines)
    let entries = contract.identityBindings.map { binding -> TatwoExecutionManifestEntry in
      let dispatchable = isDispatchable(modelID: binding.modelID)
      // WorkOSIdentityBinding has no per-binding `responsibility` text (that lives on
      // TatwoScenarioIdentityBinding), so the subtask is synthesized from the goal + role.
      // Trim + fall back so an empty objective/label never yields a bare " — 分工".
      let label = binding.label.trimmingCharacters(in: .whitespacesAndNewlines)
      let goalPart = objective.isEmpty ? "Work OS goal" : objective
      let rolePart = label.isEmpty ? binding.identity.chineseName : label
      return TatwoExecutionManifestEntry(
        id: "dispatch-plan-\(binding.id)",
        bindingID: binding.id,
        sourceSlotID: binding.sourceSlotID,
        identity: binding.identity,
        modelID: binding.modelID,
        subtask: "\(goalPart) — \(rolePart) 分工",
        status: dispatchable ? .planned : .skipped)
    }
    return TatwoExecutionManifestV1(
      contractID: contract.contractID,
      goalID: contract.goalID,
      generatedAt: generatedAt,
      entries: entries)
  }
}

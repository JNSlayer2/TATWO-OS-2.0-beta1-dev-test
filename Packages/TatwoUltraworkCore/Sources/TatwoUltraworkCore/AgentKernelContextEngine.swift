import Foundation

public enum AgentKernelTokenCounter {
  /// A deterministic kernel token unit counter. This deliberately counts
  /// bounded lexical units and punctuation. Bounding a lexical unit prevents
  /// adversarial or generated no-whitespace blobs from collapsing to one token.
  public static func count(_ value: String) -> Int {
    var count = 0
    var lexicalUnitLength = 0
    let maximumLexicalUnitScalars = 8
    for scalar in value.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar)
          || scalar == "_" {
        if lexicalUnitLength == 0
            || lexicalUnitLength == maximumLexicalUnitScalars {
          count += 1
          lexicalUnitLength = 1
        } else {
          lexicalUnitLength += 1
        }
      } else {
        lexicalUnitLength = 0
        if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
          count += 1
        }
      }
    }
    return count
  }
}

public enum AgentContextItemKind: String, Codable, Sendable, Hashable {
  case goal
  case prohibition
  case approval
  case pendingSideEffect
  case humanCorrection
  case decision
  case fact
  case toolSummary
  case artifactReference
  case recentTurn
}

public enum AgentContextProvenance: Codable, Sendable, Equatable {
  case human(turnID: String)
  case checkpoint(hash: String, field: String)
  case kernel(eventSequence: Int)
}

public struct AgentContextItem: Codable, Sendable, Equatable {
  public let id: String
  public let kind: AgentContextItemKind
  public let payload: String
  public let provenance: AgentContextProvenance
  public let freshness: Int
  public let priority: Int
  public let tokenCount: Int
  public let required: Bool
  public let pinned: Bool

  public init(
    id: String,
    kind: AgentContextItemKind,
    payload: String,
    provenance: AgentContextProvenance,
    freshness: Int,
    priority: Int,
    tokenCount: Int,
    required: Bool,
    pinned: Bool
  ) {
    self.id = id
    self.kind = kind
    self.payload = payload
    self.provenance = provenance
    self.freshness = freshness
    self.priority = priority
    self.tokenCount = tokenCount
    self.required = required
    self.pinned = pinned
  }
}

public struct AgentContextSelectionInput: Sendable, Equatable {
  public let recentWindow: [AgentContextItem]
  public let checkpoint: [AgentContextItem]
  public let pinned: [AgentContextItem]
  public let tokenBudget: Int

  public init(
    recentWindow: [AgentContextItem],
    checkpoint: [AgentContextItem],
    pinned: [AgentContextItem],
    tokenBudget: Int
  ) {
    self.recentWindow = recentWindow
    self.checkpoint = checkpoint
    self.pinned = pinned
    self.tokenBudget = tokenBudget
  }
}

public enum AgentContextSelectionError: Error, Sendable, Equatable {
  case stopped(reason: AgentKernelStopReason)
}

public struct AgentAssembledContext: Sendable, Equatable {
  public let items: [AgentContextItem]
  public let assembledInputTokens: Int
  public let payload: Data
  public let bytes: Int
  public let payloadDigest: String
  public let receipt: AgentContextSelectorReceipt

  public init(
    items: [AgentContextItem],
    assembledInputTokens: Int,
    payload: Data,
    bytes: Int,
    payloadDigest: String,
    receipt: AgentContextSelectorReceipt
  ) {
    self.items = items
    self.assembledInputTokens = assembledInputTokens
    self.payload = payload
    self.bytes = bytes
    self.payloadDigest = payloadDigest
    self.receipt = receipt
  }
}

public enum AgentContextSelectionReason: String, Codable, Sendable {
  case pinned
  case required
  case allocatedByPriority
  case budgetExceeded
}

public enum AgentContextSelectionDecision: Codable, Sendable, Equatable {
  case selected(reason: AgentContextSelectionReason)
  case evicted(reason: AgentContextSelectionReason)
}

public struct AgentContextSelectorReceipt: Codable, Sendable, Equatable {
  public let candidateIDs: [String]
  public let decisions: [String: AgentContextSelectionDecision]
  public let tokenBudget: Int
  public let assembledInputTokens: Int
  public let remainingTokens: Int
  public let bytes: Int
  public let payloadDigest: String
}

public struct AgentPromptManifestV1: Codable, Sendable, Equatable {
  public let windowTurnIDs: [String]
  public let checkpointHash: String
  public let assembledInputTokens: Int
  public let bytes: Int
  public let payloadDigest: String

  public init(
    windowTurnIDs: [String],
    checkpointHash: String,
    assembledInputTokens: Int,
    bytes: Int,
    payloadDigest: String
  ) {
    self.windowTurnIDs = windowTurnIDs
    self.checkpointHash = checkpointHash
    self.assembledInputTokens = assembledInputTokens
    self.bytes = bytes
    self.payloadDigest = payloadDigest
  }

  private enum CodingKeys: String, CodingKey {
    case windowTurnIDs
    case checkpointHash
    case assembledInputTokens = "assembled_input_tokens"
    case bytes
    case payloadDigest
  }
}

public enum AgentPromptManifestWriter {
  public static func write(
    _ manifest: AgentPromptManifestV1,
    turnID: String,
    runDirectory: URL
  ) throws -> URL {
    let safeTurnID = turnID.map {
      $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_"
    }
    let directory = runDirectory
      .appendingPathComponent("turns", isDirectory: true)
      .appendingPathComponent(String(safeTurnID), isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let url = directory.appendingPathComponent("prompt_manifest.json")
    try encoder.encode(manifest).write(to: url, options: .atomic)
    return url
  }
}

public struct AgentContextSelector: Sendable {
  public init() {}

  public func select(
    _ input: AgentContextSelectionInput
  ) throws -> AgentAssembledContext {
    let candidates = deduplicated(
      input.pinned + input.checkpoint + input.recentWindow)
    let latestCorrection = candidates
      .filter { $0.kind == .humanCorrection }
      .max {
        if $0.freshness != $1.freshness {
          return $0.freshness < $1.freshness
        }
        return $0.id > $1.id
      }
    let pinned = candidates.filter {
      $0.required || $0.pinned || Self.alwaysPinnedKinds.contains($0.kind)
        || ($0.kind == .humanCorrection && $0.id == latestCorrection?.id)
    }.sorted(by: preferred)
    let pinnedTokens = pinned.reduce(0) { $0 + $1.tokenCount }
    guard pinnedTokens <= input.tokenBudget else {
      throw AgentContextSelectionError.stopped(
        reason: .tokenBudgetExceeded)
    }

    var selected = pinned
    var used = pinnedTokens
    let selectedIDs = Set(pinned.map(\.id))
    let optional = candidates
      .filter({ !selectedIDs.contains($0.id) })
      .sorted(by: preferred)
    for candidate in optional {
      if used + candidate.tokenCount <= input.tokenBudget {
        selected.append(candidate)
        used += candidate.tokenCount
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(selected)
    let digest = AgentKernelDigest.sha256Hex(payload)
    let finalIDs = Set(selected.map(\.id))
    var decisions: [String: AgentContextSelectionDecision] = [:]
    for candidate in candidates {
      if finalIDs.contains(candidate.id) {
        let reason: AgentContextSelectionReason
        if candidate.required {
          reason = .required
        } else if pinned.contains(where: { $0.id == candidate.id }) {
          reason = .pinned
        } else {
          reason = .allocatedByPriority
        }
        decisions[candidate.id] = .selected(reason: reason)
      } else {
        decisions[candidate.id] = .evicted(reason: .budgetExceeded)
      }
    }
    let receipt = AgentContextSelectorReceipt(
      candidateIDs: candidates.map(\.id).sorted(),
      decisions: decisions,
      tokenBudget: input.tokenBudget,
      assembledInputTokens: used,
      remainingTokens: input.tokenBudget - used,
      bytes: payload.count,
      payloadDigest: digest)
    return AgentAssembledContext(
      items: selected,
      assembledInputTokens: used,
      payload: payload,
      bytes: payload.count,
      payloadDigest: digest,
      receipt: receipt)
  }

  private static let alwaysPinnedKinds: Set<AgentContextItemKind> = [
    .goal, .prohibition, .approval, .pendingSideEffect,
  ]

  private func deduplicated(
    _ items: [AgentContextItem]
  ) -> [AgentContextItem] {
    var byID: [String: AgentContextItem] = [:]
    for item in items {
      if let existing = byID[item.id] {
        if preferred(item, existing) {
          byID[item.id] = item
        }
      } else {
        byID[item.id] = item
      }
    }
    return Array(byID.values)
  }

  private func preferred(
    _ lhs: AgentContextItem,
    _ rhs: AgentContextItem
  ) -> Bool {
    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
    if lhs.freshness != rhs.freshness { return lhs.freshness > rhs.freshness }
    return lhs.id < rhs.id
  }

}

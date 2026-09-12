import CryptoKit
import Foundation

public enum AgentKernelDigest {
  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public struct PortableCheckpointArtifactRef: Codable, Sendable, Equatable {
  public let path: String
  public let digest: String

  public init(path: String, digest: String) {
    self.path = path
    self.digest = digest
  }
}

public struct PortableCheckpointEventRange: Codable, Sendable, Equatable {
  public let first: Int
  public let last: Int

  public init(first: Int, last: Int) {
    self.first = first
    self.last = last
  }
}

public enum PortableCheckpointLossClass: String, Codable, Sendable {
  case omitted
  case reconstructable
  case requiredMissing
  case untrusted
}

public struct PortableCheckpointLoss: Codable, Sendable, Equatable {
  public let item: String
  public let classification: PortableCheckpointLossClass

  public init(
    item: String,
    classification: PortableCheckpointLossClass
  ) {
    self.item = item
    self.classification = classification
  }

  private enum CodingKeys: String, CodingKey {
    case item
    case classification = "class"
  }
}

public enum PortableCheckpointRestoreBlockReason: String, Codable, Sendable {
  case missingDependency
}

public enum PortableCheckpointValidationError: Error, Sendable, Equatable {
  case unsupportedMajorVersion(Int)
  case contentHashMismatch
  case artifactUnavailable(path: String)
  case artifactDigestMismatch(path: String)
  case restoreBlocked(reason: PortableCheckpointRestoreBlockReason)
}

public struct PortableCheckpointV1: Codable, Sendable, Equatable {
  public static let supportedMajorVersion = 1

  public let schemaVersion: Int
  public let goals: [String]
  public let decisions: [String]
  public let facts: [String]
  public let toolSummaries: [String]
  public let pending: [String]
  public let artifactRefs: [PortableCheckpointArtifactRef]
  public let contentHash: String
  public let parentCheckpointHash: String?
  public let sourceEventRange: PortableCheckpointEventRange
  public let lossLedger: [PortableCheckpointLoss]

  public init(
    goals: [String],
    decisions: [String],
    facts: [String],
    toolSummaries: [String],
    pending: [String],
    artifactRefs: [PortableCheckpointArtifactRef],
    parentCheckpointHash: String?,
    sourceEventRange: PortableCheckpointEventRange,
    lossLedger: [PortableCheckpointLoss]
  ) throws {
    schemaVersion = Self.supportedMajorVersion
    self.goals = goals
    self.decisions = decisions
    self.facts = facts
    self.toolSummaries = toolSummaries
    self.pending = pending
    self.artifactRefs = artifactRefs
    self.parentCheckpointHash = parentCheckpointHash
    self.sourceEventRange = sourceEventRange
    self.lossLedger = lossLedger
    contentHash = try Self.hash(
      schemaVersion: schemaVersion,
      goals: goals,
      decisions: decisions,
      facts: facts,
      toolSummaries: toolSummaries,
      pending: pending,
      artifactRefs: artifactRefs,
      parentCheckpointHash: parentCheckpointHash,
      sourceEventRange: sourceEventRange,
      lossLedger: lossLedger)
  }

  public static func decodeAndValidate(
    _ data: Data
  ) throws -> PortableCheckpointV1 {
    let checkpoint = try JSONDecoder().decode(Self.self, from: data)
    guard checkpoint.schemaVersion == supportedMajorVersion else {
      throw PortableCheckpointValidationError.unsupportedMajorVersion(
        checkpoint.schemaVersion)
    }
    try checkpoint.validateForRestore()
    return checkpoint
  }

  public func recomputedContentHash() throws -> String {
    try Self.hash(
      schemaVersion: schemaVersion,
      goals: goals,
      decisions: decisions,
      facts: facts,
      toolSummaries: toolSummaries,
      pending: pending,
      artifactRefs: artifactRefs,
      parentCheckpointHash: parentCheckpointHash,
      sourceEventRange: sourceEventRange,
      lossLedger: lossLedger)
  }

  public func validateForRestore() throws {
    guard schemaVersion == Self.supportedMajorVersion else {
      throw PortableCheckpointValidationError.unsupportedMajorVersion(
        schemaVersion)
    }
    guard try recomputedContentHash() == contentHash else {
      throw PortableCheckpointValidationError.contentHashMismatch
    }
    guard !lossLedger.contains(where: {
      $0.classification == .requiredMissing
    }) else {
      throw PortableCheckpointValidationError.restoreBlocked(
        reason: .missingDependency)
    }
  }

  public func validateForRestore(artifactRoot: URL) throws {
    try validateForRestore()
    let root = artifactRoot.standardizedFileURL.resolvingSymlinksInPath()
    for artifact in artifactRefs {
      let candidate = root.appendingPathComponent(artifact.path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      guard candidate.path == root.path
              || candidate.path.hasPrefix(root.path + "/"),
            FileManager.default.fileExists(atPath: candidate.path),
            let data = try? Data(contentsOf: candidate)
      else {
        throw PortableCheckpointValidationError.artifactUnavailable(
          path: artifact.path)
      }
      guard AgentKernelDigest.sha256Hex(data) == artifact.digest else {
        throw PortableCheckpointValidationError.artifactDigestMismatch(
          path: artifact.path)
      }
    }
  }

  private static func hash(
    schemaVersion: Int,
    goals: [String],
    decisions: [String],
    facts: [String],
    toolSummaries: [String],
    pending: [String],
    artifactRefs: [PortableCheckpointArtifactRef],
    parentCheckpointHash: String?,
    sourceEventRange: PortableCheckpointEventRange,
    lossLedger: [PortableCheckpointLoss]
  ) throws -> String {
    let material = HashMaterial(
      schemaVersion: schemaVersion,
      goals: goals,
      decisions: decisions,
      facts: facts,
      toolSummaries: toolSummaries,
      pending: pending,
      artifactRefs: artifactRefs,
      parentCheckpointHash: parentCheckpointHash,
      sourceEventRange: sourceEventRange,
      lossLedger: lossLedger)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return AgentKernelDigest.sha256Hex(try encoder.encode(material))
  }

  private struct HashMaterial: Encodable {
    let schemaVersion: Int
    let goals: [String]
    let decisions: [String]
    let facts: [String]
    let toolSummaries: [String]
    let pending: [String]
    let artifactRefs: [PortableCheckpointArtifactRef]
    let parentCheckpointHash: String?
    let sourceEventRange: PortableCheckpointEventRange
    let lossLedger: [PortableCheckpointLoss]
  }
}

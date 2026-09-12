import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeChatThreadSourceMarker {
  public static let codexAppMirror = "codex-app-mirror"
  public static let userOwned = "tatwo-user-owned"
}

public enum TatwoNativeThreadBindingInvalidationReasonV1:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case loopsConfigChanged
  case contractSuperseded
  case goalRevisionChanged
}

public struct TatwoNativeThreadBindingIdentityV1: Codable, Sendable, Equatable, Hashable {
  public let contractID: String
  public let goalID: String
  public let goalRevision: UInt64

  public init(
    contractID: String,
    goalID: String,
    goalRevision: UInt64
  ) {
    self.contractID = contractID
    self.goalID = goalID
    self.goalRevision = goalRevision
  }
}

public struct TatwoNativeThreadBindingAuthorityProvenanceV1:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  public let provider: String
  public let externalProviderSessionID: String
  public let workspacePathSHA256: String

  public init(
    provider: String,
    externalProviderSessionID: String,
    workspacePath: String
  ) {
    self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    self.externalProviderSessionID = externalProviderSessionID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedWorkspace = workspacePath.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let canonicalWorkspace = normalizedWorkspace.isEmpty
      ? ""
      : URL(
        fileURLWithPath: normalizedWorkspace,
        isDirectory: true
      ).standardizedFileURL.path
    self.workspacePathSHA256 = TatwoLoopJobDigest.sha256(
      Data(canonicalWorkspace.utf8))
  }
}

/// Durable row-local proof that a previous Work OS binding was intentionally
/// invalidated. The row keeps this marker across the unbound crash window and
/// clears it only in the same persisted commit that installs the exact
/// successor binding.
public struct TatwoNativeThreadBindingInvalidationV1:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  public let schema: String
  public let id: UUID
  public let reason: TatwoNativeThreadBindingInvalidationReasonV1
  public let threadID: UUID
  public let projectID: UUID?
  public let previousBinding: TatwoNativeThreadBindingIdentityV1
  public let previousPointerGeneration: UInt64?
  public let previousLoopsConfigSHA256: String?
  public let desiredLoopsConfigSHA256: String?
  public let expectedSuccessor: TatwoNativeThreadBindingIdentityV1?
  public let authorityProvenance:
    TatwoNativeThreadBindingAuthorityProvenanceV1?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    reason: TatwoNativeThreadBindingInvalidationReasonV1,
    threadID: UUID,
    projectID: UUID?,
    previousBinding: TatwoNativeThreadBindingIdentityV1,
    previousPointerGeneration: UInt64? = nil,
    previousLoopsConfig: TatwoNativeThreadLoopsConfig?,
    desiredLoopsConfig: TatwoNativeThreadLoopsConfig?,
    expectedSuccessor: TatwoNativeThreadBindingIdentityV1? = nil,
    authorityProvenance:
      TatwoNativeThreadBindingAuthorityProvenanceV1? = nil,
    createdAt: Date = Date()
  ) {
    self.schema = "TatwoNativeThreadBindingInvalidationV1"
    self.id = id
    self.reason = reason
    self.threadID = threadID
    self.projectID = projectID
    self.previousBinding = previousBinding
    self.previousPointerGeneration = previousPointerGeneration
    self.previousLoopsConfigSHA256 = Self.loopsConfigSHA256(
      previousLoopsConfig)
    self.desiredLoopsConfigSHA256 = Self.loopsConfigSHA256(
      desiredLoopsConfig)
    self.expectedSuccessor = expectedSuccessor
    self.authorityProvenance = authorityProvenance
    self.createdAt = Date(
      timeIntervalSince1970:
        createdAt.timeIntervalSince1970.rounded(.down))
  }

  public func expectingSuccessor(
    _ successor: TatwoNativeThreadBindingIdentityV1
  ) -> Self {
    Self(
      id: id,
      reason: reason,
      threadID: threadID,
      projectID: projectID,
      previousBinding: previousBinding,
      previousPointerGeneration: previousPointerGeneration,
      previousLoopsConfigSHA256: previousLoopsConfigSHA256,
      desiredLoopsConfigSHA256: desiredLoopsConfigSHA256,
      expectedSuccessor: successor,
      authorityProvenance: authorityProvenance,
      createdAt: createdAt)
  }

  public func retargetingDesiredLoopsConfig(
    _ desiredLoopsConfig: TatwoNativeThreadLoopsConfig
  ) -> Self? {
    guard schema == "TatwoNativeThreadBindingInvalidationV1",
          reason == .loopsConfigChanged,
          expectedSuccessor == nil,
          let desiredLoopsConfigSHA256 = Self.loopsConfigSHA256(
            desiredLoopsConfig)
    else {
      return nil
    }
    return Self(
      id: id,
      reason: reason,
      threadID: threadID,
      projectID: projectID,
      previousBinding: previousBinding,
      previousPointerGeneration: previousPointerGeneration,
      previousLoopsConfigSHA256: previousLoopsConfigSHA256,
      desiredLoopsConfigSHA256: desiredLoopsConfigSHA256,
      expectedSuccessor: nil,
      authorityProvenance: authorityProvenance,
      createdAt: createdAt)
  }

  public static func loopsConfigSHA256(
    _ config: TatwoNativeThreadLoopsConfig?
  ) -> String? {
    guard let config else { return nil }
    return try? TatwoLoopJobDigest.canonicalJSONDigest(config)
  }

  private init(
    id: UUID,
    reason: TatwoNativeThreadBindingInvalidationReasonV1,
    threadID: UUID,
    projectID: UUID?,
    previousBinding: TatwoNativeThreadBindingIdentityV1,
    previousPointerGeneration: UInt64?,
    previousLoopsConfigSHA256: String?,
    desiredLoopsConfigSHA256: String?,
    expectedSuccessor: TatwoNativeThreadBindingIdentityV1?,
    authorityProvenance:
      TatwoNativeThreadBindingAuthorityProvenanceV1?,
    createdAt: Date
  ) {
    self.schema = "TatwoNativeThreadBindingInvalidationV1"
    self.id = id
    self.reason = reason
    self.threadID = threadID
    self.projectID = projectID
    self.previousBinding = previousBinding
    self.previousPointerGeneration = previousPointerGeneration
    self.previousLoopsConfigSHA256 = previousLoopsConfigSHA256
    self.desiredLoopsConfigSHA256 = desiredLoopsConfigSHA256
    self.expectedSuccessor = expectedSuccessor
    self.authorityProvenance = authorityProvenance
    self.createdAt = createdAt
  }
}

public struct TatwoNativeChatThread: Codable, Sendable, Equatable, Identifiable, Hashable {
  public var id: UUID
  public var title: String
  public var cliSessionID: String?
  public var codexSessionID: String?
  public var codexCLISessionID: String?
  public var claudeSessionID: String?
  /// Durable provenance for a row mirrored from Codex App. This is metadata,
  /// not a runtime working-directory override.
  public var mirroredCodexWorkspacePath: String?
  public var sourceMarker: String?
  public var adapterSessionHandles: [TatwoNativeAdapterSessionHandle]
  public var gatewayConversationHandles: [TatwoGatewayConversationHandleV1]
  public var createdAt: Date
  public var updatedAt: Date
  public var isPinned: Bool
  public var isArchived: Bool
  public var isPlanModeEnabled: Bool
  public var lastPreview: String
  public var loopsConfig: TatwoNativeThreadLoopsConfig?
  public var workOSGoalID: String?
  public var workOSContractID: String?
  public var selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2?
  public var bindingInvalidation: TatwoNativeThreadBindingInvalidationV1?
  public var threadPluginIDs: [String]?
  public var discussions: [TatwoNativeDiscussion]
  /// App-local, read-only PLG projection used to restore the visible card after relaunch.
  public var activePLGRunProjection: TatwoPLGRun?
  /// #16 該 thread 底下的 loops session（右列收納串）；監工繼承自 thread 主導。
  public var loopsSessions: [TatwoLoopsSession]
  public var messages: [TatwoNativeChatStoredMessage]?

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case cliSessionID
    case codexSessionID
    case codexCLISessionID
    case claudeSessionID
    case mirroredCodexWorkspacePath
    case sourceMarker
    case adapterSessionHandles
    case gatewayConversationHandles
    case createdAt
    case updatedAt
    case isPinned
    case isArchived
    case isPlanModeEnabled
    case lastPreview
    case loopsConfig
    case workOSGoalID
    case workOSContractID
    case selectedThreadWorkOSContext
    case bindingInvalidation
    case threadPluginIDs
    case discussions
    case activePLGRunProjection
    case loopsSessions
    case messages
  }

  public init(
    id: UUID = UUID(),
    title: String,
    cliSessionID: String? = nil,
    codexSessionID: String? = nil,
    codexCLISessionID: String? = nil,
    claudeSessionID: String? = nil,
    mirroredCodexWorkspacePath: String? = nil,
    sourceMarker: String? = nil,
    adapterSessionHandles: [TatwoNativeAdapterSessionHandle] = [],
    gatewayConversationHandles: [TatwoGatewayConversationHandleV1] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    isPinned: Bool = false,
    isArchived: Bool = false,
    isPlanModeEnabled: Bool = false,
    lastPreview: String = "",
    loopsConfig: TatwoNativeThreadLoopsConfig? = nil,
    workOSGoalID: String? = nil,
    workOSContractID: String? = nil,
    selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2? = nil,
    bindingInvalidation: TatwoNativeThreadBindingInvalidationV1? = nil,
    threadPluginIDs: [String]? = nil,
    discussions: [TatwoNativeDiscussion] = [],
    activePLGRunProjection: TatwoPLGRun? = nil,
    loopsSessions: [TatwoLoopsSession] = [],
    messages: [TatwoNativeChatStoredMessage]? = nil
  ) {
    self.id = id
    self.title = title
    self.cliSessionID = cliSessionID
    self.codexSessionID = codexSessionID
    self.codexCLISessionID = codexCLISessionID
    self.claudeSessionID = claudeSessionID
    self.mirroredCodexWorkspacePath = mirroredCodexWorkspacePath
    self.sourceMarker = sourceMarker
    self.adapterSessionHandles = adapterSessionHandles
    self.gatewayConversationHandles = gatewayConversationHandles
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.isPinned = isPinned
    self.isArchived = isArchived
    self.isPlanModeEnabled = isPlanModeEnabled
    self.lastPreview = lastPreview
    self.loopsConfig = loopsConfig
    self.workOSGoalID = workOSGoalID
    self.workOSContractID = workOSContractID
    self.selectedThreadWorkOSContext = selectedThreadWorkOSContext
    self.bindingInvalidation = bindingInvalidation
    self.threadPluginIDs = threadPluginIDs
    self.discussions = discussions
    self.activePLGRunProjection = activePLGRunProjection
    self.loopsSessions = loopsSessions
    self.messages = messages
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedThreadID = try container.decode(UUID.self, forKey: .id)
    self.id = decodedThreadID
    self.title = try container.decode(String.self, forKey: .title)
    self.cliSessionID = try container.decodeIfPresent(String.self, forKey: .cliSessionID)
    self.codexSessionID = try container.decodeIfPresent(String.self, forKey: .codexSessionID)
    self.codexCLISessionID = try container.decodeIfPresent(String.self, forKey: .codexCLISessionID)
    self.claudeSessionID = try container.decodeIfPresent(String.self, forKey: .claudeSessionID)
    self.mirroredCodexWorkspacePath = try container.decodeIfPresent(
      String.self,
      forKey: .mirroredCodexWorkspacePath)
    self.sourceMarker = try container.decodeIfPresent(String.self, forKey: .sourceMarker)
    let decodedHandles = try container.decodeIfPresent(
      [TatwoNativeAdapterSessionHandle].self,
      forKey: .adapterSessionHandles) ?? []
    self.adapterSessionHandles = decodedHandles.isEmpty
      ? TatwoNativeSessionTree.legacyAdapterHandles(
        codexCLISessionID: self.codexCLISessionID,
        codexSessionID: self.codexSessionID,
        claudeSessionID: self.claudeSessionID)
      : decodedHandles
    self.gatewayConversationHandles = try container.decodeIfPresent(
      [TatwoGatewayConversationHandleV1].self,
      forKey: .gatewayConversationHandles) ?? []
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    self.isPlanModeEnabled = try container.decodeIfPresent(
      Bool.self,
      forKey: .isPlanModeEnabled) ?? false
    self.lastPreview = try container.decodeIfPresent(String.self, forKey: .lastPreview) ?? ""
    self.loopsConfig = try container.decodeIfPresent(TatwoNativeThreadLoopsConfig.self, forKey: .loopsConfig)
    self.workOSGoalID = try container.decodeIfPresent(String.self, forKey: .workOSGoalID)
    self.workOSContractID = try container.decodeIfPresent(String.self, forKey: .workOSContractID)
    self.selectedThreadWorkOSContext = try container.decodeIfPresent(
      TatwoStoredObjectiveContextV2.self,
      forKey: .selectedThreadWorkOSContext)
    self.bindingInvalidation = try container.decodeIfPresent(
      TatwoNativeThreadBindingInvalidationV1.self,
      forKey: .bindingInvalidation)
    self.threadPluginIDs = try container.decodeIfPresent([String].self, forKey: .threadPluginIDs)
    let decodedDiscussions = try container.decodeIfPresent(
      [TatwoNativeDiscussion].self,
      forKey: .discussions) ?? []
    self.activePLGRunProjection = try container.decodeIfPresent(
      TatwoPLGRun.self,
      forKey: .activePLGRunProjection)
    self.loopsSessions = try container.decodeIfPresent([TatwoLoopsSession].self, forKey: .loopsSessions) ?? []
    let decodedMessages = try container.decodeIfPresent(
      [TatwoNativeChatStoredMessage].self,
      forKey: .messages)
    self.messages = decodedMessages
    self.discussions = decodedDiscussions.map {
      TatwoNativeSessionTree.migratedDiscussion(
        $0,
        parentThreadID: decodedThreadID,
        parentMessages: decodedMessages ?? [])
    }
  }
}

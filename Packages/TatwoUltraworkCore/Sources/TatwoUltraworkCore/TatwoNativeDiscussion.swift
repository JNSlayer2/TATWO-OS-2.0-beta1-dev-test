import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeChatSessionKind: String, Codable, Sendable, Equatable, Hashable {
  case thread
  case discussion
}

public struct TatwoNativeChatSessionReference:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let kind: TatwoNativeChatSessionKind
  public let id: UUID

  public init(kind: TatwoNativeChatSessionKind, id: UUID) {
    self.kind = kind
    self.id = id
  }

  public var stableKey: String {
    "\(kind.rawValue):\(id.uuidString.lowercased())"
  }
}

/// Provider-native handles are resumability hints only. The Tatwo thread or
/// discussion UUID remains the canonical conversation identity.
public struct TatwoNativeAdapterSessionHandle:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public var adapterID: String
  public var modelID: String?
  public var providerSessionID: String
  public var updatedISO: String

  public init(
    adapterID: String,
    modelID: String? = nil,
    providerSessionID: String,
    updatedISO: String = ISO8601DateFormatter().string(from: Date())
  ) {
    self.adapterID = adapterID
    self.modelID = modelID
    self.providerSessionID = providerSessionID
    self.updatedISO = updatedISO
  }

  public var id: String {
    "\(adapterID)|\(modelID ?? "legacy")|\(providerSessionID)"
  }
}

/// Immutable parent transcript material captured when a discussion forks.
/// Keeping the snapshot alongside its digest prevents later parent activity
/// from silently rewriting a child's inherited context.
public struct TatwoNativeSessionForkCheckpoint:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let id: UUID
  public let parentSession: TatwoNativeChatSessionReference
  public let parentMessageCount: Int
  public let parentTranscriptSHA256: String
  public let parentMessages: [TatwoNativeChatStoredMessage]
  public let createdISO: String

  public init(
    id: UUID = UUID(),
    parentSession: TatwoNativeChatSessionReference,
    parentMessageCount: Int,
    parentTranscriptSHA256: String,
    parentMessages: [TatwoNativeChatStoredMessage],
    createdISO: String = ISO8601DateFormatter().string(from: Date())
  ) {
    self.id = id
    self.parentSession = parentSession
    self.parentMessageCount = parentMessageCount
    self.parentTranscriptSHA256 = parentTranscriptSHA256
    self.parentMessages = parentMessages
    self.createdISO = createdISO
  }

}

/// A deterministic checkpoint replaces the old discussion compression
/// placeholder. It is a receipt, not a destructive transcript rewrite.
public struct TatwoNativeDiscussionCheckpointReceipt:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let id: UUID
  public let discussionID: UUID
  public let transcriptSHA256: String
  public let messageCount: Int
  public let snapshotMessages: [TatwoNativeChatStoredMessage]
  public let summary: String
  public let createdISO: String

  public init(
    id: UUID = UUID(),
    discussionID: UUID,
    transcriptSHA256: String,
    messageCount: Int,
    snapshotMessages: [TatwoNativeChatStoredMessage],
    summary: String,
    createdISO: String = ISO8601DateFormatter().string(from: Date())
  ) {
    self.id = id
    self.discussionID = discussionID
    self.transcriptSHA256 = transcriptSHA256
    self.messageCount = messageCount
    self.snapshotMessages = snapshotMessages
    self.summary = summary
    self.createdISO = createdISO
  }

}

/// Mainline receives a child result only through this explicit receipt.
public struct TatwoNativeDiscussionMergeReceipt:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let id: UUID
  public let sourceSession: TatwoNativeChatSessionReference
  public let targetSession: TatwoNativeChatSessionReference
  public let forkCheckpointID: UUID
  public let sourceCheckpointID: UUID
  public let sourceTranscriptSHA256: String
  public let summary: String
  public let createdISO: String

  public init(
    id: UUID = UUID(),
    sourceSession: TatwoNativeChatSessionReference,
    targetSession: TatwoNativeChatSessionReference,
    forkCheckpointID: UUID,
    sourceCheckpointID: UUID,
    sourceTranscriptSHA256: String,
    summary: String,
    createdISO: String = ISO8601DateFormatter().string(from: Date())
  ) {
    self.id = id
    self.sourceSession = sourceSession
    self.targetSession = targetSession
    self.forkCheckpointID = forkCheckpointID
    self.sourceCheckpointID = sourceCheckpointID
    self.sourceTranscriptSHA256 = sourceTranscriptSHA256
    self.summary = summary
    self.createdISO = createdISO
  }

  /// Identifies the same child content merged into the same parent even when
  /// a repeated click creates a fresh checkpoint receipt UUID.
  public var deduplicationKey: String {
    [
      sourceSession.stableKey,
      targetSession.stableKey,
      forkCheckpointID.uuidString.lowercased(),
      sourceTranscriptSHA256,
    ].joined(separator: "|")
  }
}

public struct TatwoNativeDiscussion: Codable, Sendable, Equatable, Hashable, Identifiable {
  public enum Status: String, Codable, Sendable, Equatable, Hashable {
    case active
    case compressed
  }

  public var id: UUID
  public var title: String
  public var inheritedSnapshot: String
  public var parentSession: TatwoNativeChatSessionReference?
  public var forkCheckpoint: TatwoNativeSessionForkCheckpoint?
  public var adapterSessionHandles: [TatwoNativeAdapterSessionHandle]
  public var gatewayConversationHandles: [TatwoGatewayConversationHandleV1]
  public var messages: [TatwoNativeChatStoredMessage]
  public var loopsSessions: [TatwoLoopsSession]
  public var checkpointReceipt: TatwoNativeDiscussionCheckpointReceipt?
  public var mergeReceipts: [TatwoNativeDiscussionMergeReceipt]
  public var lastPreview: String
  public var status: Status
  public var compressedSummary: String?
  public var createdISO: String
  public var isArchived: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case inheritedSnapshot
    case parentSession
    case forkCheckpoint
    case adapterSessionHandles
    case gatewayConversationHandles
    case messages
    case loopsSessions
    case checkpointReceipt
    case mergeReceipts
    case lastPreview
    case status
    case compressedSummary
    case createdISO
    case isArchived
  }

  public init(
    id: UUID = UUID(),
    title: String,
    inheritedSnapshot: String,
    parentSession: TatwoNativeChatSessionReference? = nil,
    forkCheckpoint: TatwoNativeSessionForkCheckpoint? = nil,
    adapterSessionHandles: [TatwoNativeAdapterSessionHandle] = [],
    gatewayConversationHandles: [TatwoGatewayConversationHandleV1] = [],
    messages: [TatwoNativeChatStoredMessage] = [],
    loopsSessions: [TatwoLoopsSession] = [],
    checkpointReceipt: TatwoNativeDiscussionCheckpointReceipt? = nil,
    mergeReceipts: [TatwoNativeDiscussionMergeReceipt] = [],
    lastPreview: String = "",
    status: Status = .active,
    compressedSummary: String? = nil,
    createdISO: String = ISO8601DateFormatter().string(from: Date()),
    isArchived: Bool = false
  ) {
    self.id = id
    self.title = title
    self.inheritedSnapshot = inheritedSnapshot
    self.parentSession = parentSession
    self.forkCheckpoint = forkCheckpoint
    self.adapterSessionHandles = adapterSessionHandles
    self.gatewayConversationHandles = gatewayConversationHandles
    self.messages = messages
    self.loopsSessions = loopsSessions
    self.checkpointReceipt = checkpointReceipt
    self.mergeReceipts = mergeReceipts
    self.lastPreview = lastPreview
    self.status = status
    self.compressedSummary = compressedSummary
    self.createdISO = createdISO
    self.isArchived = isArchived
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.inheritedSnapshot = try container.decodeIfPresent(String.self, forKey: .inheritedSnapshot) ?? ""
    self.parentSession = try container.decodeIfPresent(
      TatwoNativeChatSessionReference.self,
      forKey: .parentSession)
    self.forkCheckpoint = try container.decodeIfPresent(
      TatwoNativeSessionForkCheckpoint.self,
      forKey: .forkCheckpoint)
    self.adapterSessionHandles = try container.decodeIfPresent(
      [TatwoNativeAdapterSessionHandle].self,
      forKey: .adapterSessionHandles) ?? []
    self.gatewayConversationHandles = try container.decodeIfPresent(
      [TatwoGatewayConversationHandleV1].self,
      forKey: .gatewayConversationHandles) ?? []
    self.messages = try container.decodeIfPresent(
      [TatwoNativeChatStoredMessage].self,
      forKey: .messages) ?? []
    self.loopsSessions = try container.decodeIfPresent(
      [TatwoLoopsSession].self,
      forKey: .loopsSessions) ?? []
    self.checkpointReceipt = try container.decodeIfPresent(
      TatwoNativeDiscussionCheckpointReceipt.self,
      forKey: .checkpointReceipt)
    self.mergeReceipts = try container.decodeIfPresent(
      [TatwoNativeDiscussionMergeReceipt].self,
      forKey: .mergeReceipts) ?? []
    self.lastPreview = try container.decodeIfPresent(String.self, forKey: .lastPreview) ?? ""
    self.status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .active
    self.compressedSummary = try container.decodeIfPresent(String.self, forKey: .compressedSummary)
    self.createdISO = try container.decodeIfPresent(String.self, forKey: .createdISO)
      ?? ISO8601DateFormatter().string(from: Date())
    self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
  }
}

import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeChatEventKind: String, Codable, Sendable, Equatable, Hashable {
  case session
  case continuation
  case message
  case toolUse
  case thinking
  case raw
  case exit
  case failure
}

public struct TatwoNativeChatReconnectProgress: Codable, Sendable, Equatable, Hashable {
  public let attempt: Int
  public let maximumAttempts: Int
  public let detail: String

  public init(attempt: Int, maximumAttempts: Int, detail: String) {
    self.attempt = attempt
    self.maximumAttempts = maximumAttempts
    self.detail = detail
  }
}

public struct TatwoNativeChatStoredMessage: Codable, Sendable, Equatable, Identifiable, Hashable {
  public var id: String
  public var role: String
  public var text: String
  public var status: String?
  public var modelID: String?
  public var eventKind: TatwoNativeChatEventKind
  public var runtimeAdapterID: String?
  public var runtimeFallbackReason: TatwoChatRuntimeFallbackReason?
  public var createdAt: Date

  public init(
    id: String = UUID().uuidString,
    role: String,
    text: String,
    status: String? = nil,
    modelID: String? = nil,
    eventKind: TatwoNativeChatEventKind = .message,
    runtimeAdapterID: String? = nil,
    runtimeFallbackReason: TatwoChatRuntimeFallbackReason? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.status = status
    self.modelID = modelID
    self.eventKind = eventKind
    self.runtimeAdapterID = runtimeAdapterID
    self.runtimeFallbackReason = runtimeFallbackReason
    self.createdAt = createdAt
  }
}

public struct TatwoNativeChatEvent: Codable, Sendable, Equatable, Hashable {
  public let engine: TatwoNativeChatEngine
  public let kind: TatwoNativeChatEventKind
  public let text: String
  public let sessionID: String?
  public let rawType: String?
  public let reconnectProgress: TatwoNativeChatReconnectProgress?

  public init(
    engine: TatwoNativeChatEngine,
    kind: TatwoNativeChatEventKind,
    text: String,
    sessionID: String? = nil,
    rawType: String? = nil,
    reconnectProgress: TatwoNativeChatReconnectProgress? = nil
  ) {
    self.engine = engine
    self.kind = kind
    self.text = text
    self.sessionID = sessionID
    self.rawType = rawType
    self.reconnectProgress = reconnectProgress
  }
}

public enum TatwoNativeChatStreamFormat:
  String, Codable, Sendable, Equatable, Hashable
{
  case genericJSONL
  case grokStreamingJSON
}

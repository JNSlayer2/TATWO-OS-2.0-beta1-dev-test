import Foundation

/// Canonical, vendor-neutral in-process session protocol.
public enum SessionProtocolV1 {
  public static let majorVersion = 1
  public static let minorVersion = 0

  public enum EnvelopeKind: String, Codable, Sendable, Equatable, CaseIterable {
    case request
    case notification
    case serverRequest
    case response
  }

  public enum Method: String, Codable, Sendable, Equatable, CaseIterable {
    case threadStarted = "tatwo.thread.started"
    case turnStarted = "tatwo.turn.started"
    case itemDelta = "tatwo.item.delta"
    case approvalRequested = "tatwo.approval.requested"
    case approvalResolved = "tatwo.approval.resolved"
    case runStateChanged = "tatwo.turn.runState.changed"
  }

  public struct Thread: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
      self.id = id
    }
  }

  public struct Turn: Codable, Sendable, Equatable {
    public let id: String
    public let threadID: String

    public init(id: String, threadID: String) {
      self.id = id
      self.threadID = threadID
    }
  }

  public struct Item: Codable, Sendable, Equatable {
    public let id: String
    public let turnID: String
    public let kind: AgentItemKind
    public let delta: String?

    public init(id: String, turnID: String, kind: AgentItemKind, delta: String? = nil) {
      self.id = id
      self.turnID = turnID
      self.kind = kind
      self.delta = delta
    }
  }

  public enum ApprovalStatus: String, Codable, Sendable, Equatable {
    case requested
    case approved
    case denied
  }

  public struct Approval: Codable, Sendable, Equatable {
    public let id: String
    public let runID: String
    public let status: ApprovalStatus

    public init(id: String, runID: String, status: ApprovalStatus) {
      self.id = id
      self.runID = runID
      self.status = status
    }
  }

  public struct RunState: Codable, Sendable, Equatable {
    public let runID: String
    public let phase: AgentRunPhase

    public init(runID: String, phase: AgentRunPhase) {
      self.runID = runID
      self.phase = phase
    }
  }

  /// Transport/vendor vocabulary is allowed only in this adapter boundary record.
  public struct AdapterMetadata: Codable, Sendable, Equatable {
    public let source: String
    public let vendor: String?
    public let vendorMethod: String?

    public init(source: String, vendor: String? = nil, vendorMethod: String? = nil) {
      self.source = source
      self.vendor = vendor
      self.vendorMethod = vendorMethod
    }
  }

  public enum ClientKind: String, Codable, Sendable, Equatable, CaseIterable {
    case localChat
    case cli
    case futureBot
    case channelAdapter
    case cloudRunner
  }

  public enum ExecutionLocation: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case remoteDevice
    case cloudWorker
    case privateComputeCapability
  }

  public enum AuthorityLease: String, Codable, Sendable, Equatable {
    case never
    case processBound
  }

  public struct Budget: Codable, Sendable, Equatable {
    public let maxTokens: Int

    public init(maxTokens: Int) {
      self.maxTokens = maxTokens
    }
  }

  public enum ClientError: Error, Equatable {
    case cloudRunnerRequiresBudget
    case cloudRunnerRequiresPositiveTTL
    case invariantMismatch
  }

  public struct Client: Codable, Sendable, Equatable {
    public let kind: ClientKind
    public let executionLocation: ExecutionLocation
    public let authorityLease: AuthorityLease
    public let budget: Budget?
    public let ttlSeconds: Int?
    public let ownsDurableRun: Bool

    public init(
      kind: ClientKind,
      executionLocation: ExecutionLocation,
      budget: Budget? = nil,
      ttlSeconds: Int? = nil
    ) throws {
      if kind == .cloudRunner {
        guard budget != nil else { throw ClientError.cloudRunnerRequiresBudget }
        guard let ttlSeconds, ttlSeconds > 0 else {
          throw ClientError.cloudRunnerRequiresPositiveTTL
        }
        self.authorityLease = .never
        self.ownsDurableRun = false
      } else {
        self.authorityLease = .processBound
        self.ownsDurableRun = false
      }
      self.kind = kind
      self.executionLocation = executionLocation
      self.budget = budget
      self.ttlSeconds = ttlSeconds
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let kind = try container.decode(ClientKind.self, forKey: .kind)
      let executionLocation =
        try container.decode(ExecutionLocation.self, forKey: .executionLocation)
      let budget = try container.decodeIfPresent(Budget.self, forKey: .budget)
      let ttlSeconds = try container.decodeIfPresent(Int.self, forKey: .ttlSeconds)
      let decodedAuthority =
        try container.decode(AuthorityLease.self, forKey: .authorityLease)
      let decodedOwnership = try container.decode(Bool.self, forKey: .ownsDurableRun)
      try self.init(
        kind: kind,
        executionLocation: executionLocation,
        budget: budget,
        ttlSeconds: ttlSeconds)
      guard decodedAuthority == authorityLease, decodedOwnership == ownsDurableRun else {
        throw ClientError.invariantMismatch
      }
    }
  }

  public enum AuthorityEffect: String, Codable, Sendable, Equatable {
    case none
    case approvalRequested
    case approvalResolved
  }

  public enum CodecError: Error, Equatable {
    case unsupportedMajorVersion(Int)
  }

  public struct Envelope: Codable, Sendable, Equatable {
    public let majorVersion: Int
    public let minorVersion: Int
    public let kind: EnvelopeKind
    public let id: String?
    public let method: String?
    public let payload: JSONValue
    public let client: Client?
    public let adapterMetadata: AdapterMetadata?

    public var knownMethod: Method? {
      method.flatMap(Method.init(rawValue:))
    }

    public var authorityEffect: AuthorityEffect {
      switch knownMethod {
      case .approvalRequested: return .approvalRequested
      case .approvalResolved: return .approvalResolved
      default: return .none
      }
    }

    public static func notification<Payload: Encodable>(
      method: Method,
      payload: Payload,
      client: Client? = nil,
      adapterMetadata: AdapterMetadata? = nil
    ) throws -> Envelope {
      Envelope(
        kind: .notification,
        method: method.rawValue,
        payload: try JSONValue.fromEncodable(payload),
        client: client,
        adapterMetadata: adapterMetadata)
    }

    public init(
      kind: EnvelopeKind,
      id: String? = nil,
      method: String? = nil,
      payload: JSONValue,
      client: Client? = nil,
      adapterMetadata: AdapterMetadata? = nil
    ) {
      self.majorVersion = SessionProtocolV1.majorVersion
      self.minorVersion = SessionProtocolV1.minorVersion
      self.kind = kind
      self.id = id
      self.method = method
      self.payload = payload
      self.client = client
      self.adapterMetadata = adapterMetadata
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let majorVersion = try container.decode(Int.self, forKey: .majorVersion)
      guard majorVersion == SessionProtocolV1.majorVersion else {
        throw CodecError.unsupportedMajorVersion(majorVersion)
      }
      self.majorVersion = majorVersion
      self.minorVersion = try container.decode(Int.self, forKey: .minorVersion)
      self.kind = try container.decode(EnvelopeKind.self, forKey: .kind)
      self.id = try container.decodeIfPresent(String.self, forKey: .id)
      self.method = try container.decodeIfPresent(String.self, forKey: .method)
      self.payload = try container.decode(JSONValue.self, forKey: .payload)
      self.client = try container.decodeIfPresent(Client.self, forKey: .client)
      self.adapterMetadata =
        try container.decodeIfPresent(AdapterMetadata.self, forKey: .adapterMetadata)
    }
  }

  public enum JSONCodec {
    public static func encode(_ envelope: Envelope) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> Envelope {
      try JSONDecoder().decode(Envelope.self, from: data)
    }
  }

  public enum ConsumerError: Error, Equatable {
    case payloadMismatch(String)
  }

  private static func decodePayload<Value: Decodable>(
    _ type: Value.Type,
    from envelope: Envelope
  ) throws -> Value {
    let data = try JSONEncoder().encode(envelope.payload)
    return try JSONDecoder().decode(type, from: data)
  }

  /// In-process kernel-driver consumer. It reuses the existing kernel event payload
  /// for approval authority instead of defining a second durable event vocabulary.
  public struct KernelDriverConsumer: Sendable, Equatable {
    public private(set) var activeTurnID: String?
    public private(set) var itemDeltas: [String: String] = [:]
    public private(set) var kernelEvents: [AgentKernelEventPayload] = []

    public init() {}

    public mutating func consume(_ envelope: Envelope) throws {
      switch envelope.knownMethod {
      case .turnStarted:
        let turn = try SessionProtocolV1.decodePayload(Turn.self, from: envelope)
        activeTurnID = turn.id
      case .itemDelta:
        let item = try SessionProtocolV1.decodePayload(Item.self, from: envelope)
        itemDeltas[item.id, default: ""] += item.delta ?? ""
      case .approvalRequested:
        let approval = try SessionProtocolV1.decodePayload(Approval.self, from: envelope)
        guard approval.status == .requested else {
          throw ConsumerError.payloadMismatch(Method.approvalRequested.rawValue)
        }
        kernelEvents.append(.approvalRequested(id: approval.id))
      default:
        break
      }
    }
  }

  /// Minimal UI-neutral projection proving Chat can consume the canonical stream.
  public struct ChatProjectionReducer: Sendable, Equatable {
    public private(set) var activeTurnID: String?
    public private(set) var visibleItems: [String: String] = [:]
    public private(set) var pendingApprovalIDs: [String] = []

    public init() {}

    public mutating func consume(_ envelope: Envelope) throws {
      switch envelope.knownMethod {
      case .turnStarted:
        activeTurnID = try SessionProtocolV1.decodePayload(Turn.self, from: envelope).id
      case .itemDelta:
        let item = try SessionProtocolV1.decodePayload(Item.self, from: envelope)
        visibleItems[item.id, default: ""] += item.delta ?? ""
      case .approvalRequested:
        let approval = try SessionProtocolV1.decodePayload(Approval.self, from: envelope)
        guard approval.status == .requested else {
          throw ConsumerError.payloadMismatch(Method.approvalRequested.rawValue)
        }
        pendingApprovalIDs.append(approval.id)
      default:
        break
      }
    }
  }
}

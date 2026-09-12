import Foundation

public enum AgentToolLifecycle: String, Codable, Sendable, Equatable {
  case proposed
  case executing
  case completed
  case failed
}

public enum AgentToolContractError: Error, Sendable, Equatable {
  case invalidProposal
  case unknownTool(String)
  case modelClaimedExecution
  case duplicateCallID(String)
}

public struct AgentCanonicalToolCall: Codable, Sendable, Equatable {
  public let callID: String
  public let name: String
  public let canonicalArgs: Data
  public let argsHash: String
  public let resultDigest: String?
  public let lifecycle: AgentToolLifecycle

  public func completed(result: Data) -> Self {
    Self(
      callID: callID,
      name: name,
      canonicalArgs: canonicalArgs,
      argsHash: argsHash,
      resultDigest: AgentKernelDigest.sha256Hex(result),
      lifecycle: .completed)
  }
}

public enum AgentToolProposalDecoder {
  public static func decode(
    _ data: Data,
    allowlistedTools: Set<String>
  ) throws -> AgentCanonicalToolCall {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let callID = object["callID"] as? String, !callID.isEmpty,
          let name = object["name"] as? String, !name.isEmpty,
          let args = object["args"],
          JSONSerialization.isValidJSONObject(args)
    else {
      throw AgentToolContractError.invalidProposal
    }
    guard allowlistedTools.contains(name) else {
      throw AgentToolContractError.unknownTool(name)
    }
    if object["resultDigest"] != nil
        || (object["lifecycle"] as? String).map({ $0 != AgentToolLifecycle.proposed.rawValue }) == true
        || object["result"] != nil {
      throw AgentToolContractError.modelClaimedExecution
    }
    let canonicalArgs = try JSONSerialization.data(
      withJSONObject: args,
      options: [.sortedKeys, .withoutEscapingSlashes])
    return AgentCanonicalToolCall(
      callID: callID,
      name: name,
      canonicalArgs: canonicalArgs,
      argsHash: AgentKernelDigest.sha256Hex(canonicalArgs),
      resultDigest: nil,
      lifecycle: .proposed)
  }
}

public final class AgentToolCallLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var callIDs: Set<String> = []

  public init() {}

  public func accept(_ call: AgentCanonicalToolCall) throws {
    try lock.withLock {
      guard callIDs.insert(call.callID).inserted else {
        throw AgentToolContractError.duplicateCallID(call.callID)
      }
    }
  }
}

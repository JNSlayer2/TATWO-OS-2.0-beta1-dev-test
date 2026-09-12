import CryptoKit
import Darwin
import Foundation

public struct TatwoNativeThreadLoopsConfig: Codable, Sendable, Equatable, Hashable {
  public var scenarioID: String
  public var mode: WorkModeID
  public var identitySummary: String
  public var tokenBudget: String
  public var primaryModelID: String?
  public var secondaryModelID: String?

  public init(
    scenarioID: String,
    mode: WorkModeID,
    identitySummary: String,
    tokenBudget: String,
    primaryModelID: String? = nil,
    secondaryModelID: String? = nil
  ) {
    self.scenarioID = scenarioID
    self.mode = mode
    self.identitySummary = identitySummary
    self.tokenBudget = tokenBudget
    self.primaryModelID = primaryModelID
    self.secondaryModelID = secondaryModelID
  }

  public var summaryLine: String {
    var parts = [
      "scenario=\(scenarioID)",
      "mode=\(mode.rawValue)",
      "budget=\(tokenBudget)",
      identitySummary,
    ]
    if let primaryModelID, !primaryModelID.isEmpty {
      parts.append("主=\(primaryModelID)")
    }
    if let secondaryModelID, !secondaryModelID.isEmpty {
      parts.append("輔=\(secondaryModelID)")
    }
    return parts.joined(separator: " · ")
  }
}

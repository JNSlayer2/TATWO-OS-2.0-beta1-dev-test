import Foundation

public enum AgentKernelStopReason: String, Codable, Sendable, Equatable {
  case ttlExpired
  case tokenBudgetExceeded
  case consecutiveFailureLimit
  case humanDisabled
}

public struct AgentKernelStopPolicy: Sendable, Equatable {
  public let ttl: TimeInterval
  public let tokenBudget: Int
  public let consecutiveFailureLimit: Int

  public init(
    ttl: TimeInterval,
    tokenBudget: Int,
    consecutiveFailureLimit: Int
  ) {
    self.ttl = ttl
    self.tokenBudget = tokenBudget
    self.consecutiveFailureLimit = consecutiveFailureLimit
  }

  public func reason(
    startedAt: Date,
    now: Date,
    usage: Int,
    failures: Int,
    disabled: Bool
  ) -> AgentKernelStopReason? {
    if disabled {
      return .humanDisabled
    }
    if now.timeIntervalSince(startedAt) >= ttl {
      return .ttlExpired
    }
    if usage > tokenBudget {
      return .tokenBudgetExceeded
    }
    if failures >= consecutiveFailureLimit {
      return .consecutiveFailureLimit
    }
    return nil
  }
}

public enum AgentTransportUsageReport: Sendable, Equatable {
  case codex(
    source: AgentUsageSource = .reported,
    inputTokens: Int?,
    outputTokens: Int?,
    unavailableReason: String? = nil)
  case claude(
    source: AgentUsageSource = .reported,
    inputTokens: Int?,
    outputTokens: Int?,
    unavailableReason: String? = nil)
  case grok(
    source: AgentUsageSource = .reported,
    inputTokens: Int?,
    outputTokens: Int?,
    unavailableReason: String? = nil)

  public var canonical: AgentUsage {
    let normalized: (
      AgentUsageSource, Int?, Int?, String?
    )
    switch self {
    case let .codex(source, input, output, reason),
         let .claude(source, input, output, reason),
         let .grok(source, input, output, reason):
      normalized = (source, input, output, reason)
    }
    if normalized.0 == .unavailable {
      return AgentUsage(
        source: .unavailable,
        input: nil,
        output: nil,
        unavailableReason: normalized.3 ?? "missing token counts")
    }
    guard let input = normalized.1,
          let output = normalized.2,
          input >= 0,
          output >= 0
    else {
      return AgentUsage(
        source: .unavailable,
        input: nil,
        output: nil,
        unavailableReason: normalized.3 ?? "missing token counts")
    }
    return AgentUsage(
      source: normalized.0,
      input: input,
      output: output)
  }
}

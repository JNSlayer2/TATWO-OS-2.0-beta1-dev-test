import Foundation

public enum TatwoBrowserActionPlanTargetRisk:
  String,
  Codable,
  Sendable,
  Hashable
{
  case sensitiveInput
  case externalSideEffect
  case irreversible
  case forbidden
}

public struct TatwoBrowserActionPlanTarget:
  Identifiable,
  Codable,
  Sendable,
  Equatable
{
  public let id: String
  public let role: String
  public let accessibleName: String
  public let isVisible: Bool
  public let isEnabled: Bool
  public let risks: Set<TatwoBrowserActionPlanTargetRisk>

  public init(
    id: String,
    role: String,
    accessibleName: String,
    isVisible: Bool,
    isEnabled: Bool,
    risks: Set<TatwoBrowserActionPlanTargetRisk> = []
  ) {
    self.id = id
    self.role = role
    self.accessibleName = accessibleName
    self.isVisible = isVisible
    self.isEnabled = isEnabled
    self.risks = risks
  }
}

public struct TatwoBrowserActionPlanObservation:
  Codable,
  Sendable,
  Equatable
{
  public let sessionID: String
  public let observationID: String
  public let origin: String
  public let documentFingerprint: String
  public let targets: [TatwoBrowserActionPlanTarget]

  public init(
    sessionID: String,
    observationID: String,
    origin: String,
    documentFingerprint: String,
    targets: [TatwoBrowserActionPlanTarget]
  ) {
    self.sessionID = sessionID
    self.observationID = observationID
    self.origin = origin
    self.documentFingerprint = documentFingerprint
    self.targets = targets
  }
}

public enum TatwoBrowserActionPlanInputSensitivity:
  String,
  Codable,
  Sendable,
  Equatable
{
  case ordinary
  case personalData
  case password
  case oneTimeCode
  case payment

  fileprivate var isSensitive: Bool {
    self != .ordinary
  }
}

public struct TatwoBrowserActionPlanInput:
  Codable,
  Sendable,
  Equatable
{
  public let redactedSummary: String
  public let characterCount: Int
  public let sensitivity: TatwoBrowserActionPlanInputSensitivity

  public init(
    redactedSummary: String,
    characterCount: Int,
    sensitivity: TatwoBrowserActionPlanInputSensitivity
  ) {
    self.redactedSummary = redactedSummary
    self.characterCount = characterCount
    self.sensitivity = sensitivity
  }
}

public enum TatwoBrowserActionPlanScrollDirection:
  String,
  Codable,
  Sendable,
  Equatable
{
  case up
  case down
}

public enum TatwoBrowserActionPlanIntent:
  Codable,
  Sendable,
  Equatable
{
  case scroll(
    direction: TatwoBrowserActionPlanScrollDirection,
    distance: Int)
  case click(targetID: String)
  case typeText(
    targetID: String,
    input: TatwoBrowserActionPlanInput)
}

public struct TatwoBrowserActionPlanRequest:
  Identifiable,
  Codable,
  Sendable,
  Equatable
{
  public let id: String
  public let intent: TatwoBrowserActionPlanIntent

  public init(
    id: String,
    intent: TatwoBrowserActionPlanIntent
  ) {
    self.id = id
    self.intent = intent
  }
}

public enum TatwoBrowserActionPlanRisk:
  String,
  Codable,
  Sendable,
  Comparable
{
  case lowInteraction
  case sensitiveInput
  case externalSideEffect
  case irreversible
  case forbidden

  public static func < (
    lhs: TatwoBrowserActionPlanRisk,
    rhs: TatwoBrowserActionPlanRisk
  ) -> Bool {
    lhs.rank < rhs.rank
  }

  private var rank: Int {
    switch self {
    case .lowInteraction:
      0
    case .sensitiveInput:
      1
    case .externalSideEffect:
      2
    case .irreversible:
      3
    case .forbidden:
      4
    }
  }
}

public enum TatwoBrowserActionPlanGateRequirement:
  String,
  Codable,
  Sendable,
  Equatable
{
  case none
  case perActionApproval
  case perActionApprovalWithWarning
  case forbidden
}

public enum TatwoBrowserActionPlanBlocker:
  String,
  Codable,
  Sendable,
  Equatable
{
  case targetMissing
  case targetNotVisible
  case targetDisabled
  case forbiddenTarget
}

public struct TatwoBrowserActionPlanStep:
  Identifiable,
  Codable,
  Sendable,
  Equatable
{
  public let id: String
  public let intent: TatwoBrowserActionPlanIntent
  public let risk: TatwoBrowserActionPlanRisk
  public let gateRequirement: TatwoBrowserActionPlanGateRequirement
  public let blocker: TatwoBrowserActionPlanBlocker?

  public init(
    id: String,
    intent: TatwoBrowserActionPlanIntent,
    risk: TatwoBrowserActionPlanRisk,
    gateRequirement: TatwoBrowserActionPlanGateRequirement,
    blocker: TatwoBrowserActionPlanBlocker?
  ) {
    self.id = id
    self.intent = intent
    self.risk = risk
    self.gateRequirement = gateRequirement
    self.blocker = blocker
  }
}

public struct TatwoBrowserActionPlan:
  Codable,
  Sendable,
  Equatable
{
  public let sessionID: String
  public let observationID: String
  public let origin: String
  public let documentFingerprint: String
  public let steps: [TatwoBrowserActionPlanStep]

  public init(
    sessionID: String,
    observationID: String,
    origin: String,
    documentFingerprint: String,
    steps: [TatwoBrowserActionPlanStep]
  ) {
    self.sessionID = sessionID
    self.observationID = observationID
    self.origin = origin
    self.documentFingerprint = documentFingerprint
    self.steps = steps
  }

  public var gatedStepIDs: [String] {
    steps.compactMap { step in
      switch step.gateRequirement {
      case .perActionApproval, .perActionApprovalWithWarning:
        step.id
      case .none, .forbidden:
        nil
      }
    }
  }

  public var blockedStepIDs: [String] {
    steps.compactMap { step in
      step.blocker == nil ? nil : step.id
    }
  }

  public var highestRisk: TatwoBrowserActionPlanRisk? {
    steps.map(\.risk).max()
  }
}

public enum TatwoBrowserActionPlanner {
  public static func propose(
    observation: TatwoBrowserActionPlanObservation,
    requests: [TatwoBrowserActionPlanRequest]
  ) -> TatwoBrowserActionPlan {
    TatwoBrowserActionPlan(
      sessionID: observation.sessionID,
      observationID: observation.observationID,
      origin: observation.origin,
      documentFingerprint: observation.documentFingerprint,
      steps: requests.map { request in
        classify(request: request, targets: observation.targets)
      })
  }

  private static func classify(
    request: TatwoBrowserActionPlanRequest,
    targets: [TatwoBrowserActionPlanTarget]
  ) -> TatwoBrowserActionPlanStep {
    switch request.intent {
    case .scroll:
      TatwoBrowserActionPlanStep(
        id: request.id,
        intent: request.intent,
        risk: .lowInteraction,
        gateRequirement: .none,
        blocker: nil)

    case let .click(targetID):
      classifyTargeted(
        request: request,
        targetID: targetID,
        inputSensitivity: nil,
        targets: targets)

    case let .typeText(targetID, input):
      classifyTargeted(
        request: request,
        targetID: targetID,
        inputSensitivity: input.sensitivity,
        targets: targets)
    }
  }

  private static func classifyTargeted(
    request: TatwoBrowserActionPlanRequest,
    targetID: String,
    inputSensitivity: TatwoBrowserActionPlanInputSensitivity?,
    targets: [TatwoBrowserActionPlanTarget]
  ) -> TatwoBrowserActionPlanStep {
    guard let target = targets.first(where: { $0.id == targetID }) else {
      return blocked(request: request, blocker: .targetMissing)
    }
    guard target.isVisible else {
      return blocked(request: request, blocker: .targetNotVisible)
    }
    guard target.isEnabled else {
      return blocked(request: request, blocker: .targetDisabled)
    }
    guard !target.risks.contains(.forbidden) else {
      return blocked(request: request, blocker: .forbiddenTarget)
    }

    let risk: TatwoBrowserActionPlanRisk
    let gate: TatwoBrowserActionPlanGateRequirement
    if target.risks.contains(.irreversible) {
      risk = .irreversible
      gate = .perActionApprovalWithWarning
    } else if target.risks.contains(.externalSideEffect) {
      risk = .externalSideEffect
      gate = .perActionApprovalWithWarning
    } else if target.risks.contains(.sensitiveInput)
                || inputSensitivity?.isSensitive == true {
      risk = .sensitiveInput
      gate = .perActionApprovalWithWarning
    } else {
      risk = .lowInteraction
      gate = .perActionApproval
    }

    return TatwoBrowserActionPlanStep(
      id: request.id,
      intent: request.intent,
      risk: risk,
      gateRequirement: gate,
      blocker: nil)
  }

  private static func blocked(
    request: TatwoBrowserActionPlanRequest,
    blocker: TatwoBrowserActionPlanBlocker
  ) -> TatwoBrowserActionPlanStep {
    TatwoBrowserActionPlanStep(
      id: request.id,
      intent: request.intent,
      risk: .forbidden,
      gateRequirement: .forbidden,
      blocker: blocker)
  }
}

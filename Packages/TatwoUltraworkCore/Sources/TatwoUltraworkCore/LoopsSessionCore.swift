import Foundation

public struct TatwoLoopsPLG:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let plan: String
  public let loops: String
  public let goal: String

  public var id: String {
    "\(plan.utf8.count):\(plan)\(loops.utf8.count):\(loops)\(goal.utf8.count):\(goal)"
  }

  public init(
    plan: String,
    loops: String,
    goal: String
  ) {
    self.plan = plan
    self.loops = loops
    self.goal = goal
  }
}

public enum TatwoLoopsParentKind:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  case mainChat
  case thread
  case discussion

  public var id: String { rawValue }
}

public enum TatwoLoopsStatus:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  case planned
  case running
  case blocked
  case passed
  case rollbackRequired

  public var id: String { rawValue }
}

public struct TatwoLoopsSubAgent:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let id: UUID
  public let label: String
  public let modelID: String
  public var status: TatwoLoopsStatus

  public init(
    id: UUID = UUID(),
    label: String,
    modelID: String,
    status: TatwoLoopsStatus
  ) {
    self.id = id
    self.label = label
    self.modelID = modelID
    self.status = status
  }
}

public struct TatwoLoopsCycleProgress:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let round: Int
  public let totalRounds: Int
  public let producedCount: Int
  public let verifiedCount: Int
  public let blockedCount: Int

  public var id: Int { round }

  public init(
    round: Int,
    totalRounds: Int,
    producedCount: Int,
    verifiedCount: Int,
    blockedCount: Int
  ) {
    self.round = round
    self.totalRounds = totalRounds
    self.producedCount = producedCount
    self.verifiedCount = verifiedCount
    self.blockedCount = blockedCount
  }
}

public struct TatwoLoopsMessage:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let id: UUID
  public let role: String
  public let authorModelID: String?
  public let text: String
  public let createdISO: String

  public init(
    id: UUID = UUID(),
    role: String,
    authorModelID: String?,
    text: String,
    createdISO: String
  ) {
    self.id = id
    self.role = role
    self.authorModelID = authorModelID
    self.text = text
    self.createdISO = createdISO
  }
}

public struct TatwoLoopsSession:
  Codable,
  Sendable,
  Equatable,
  Hashable,
  Identifiable
{
  public let id: UUID
  public let parentKind: TatwoLoopsParentKind
  public let parentID: UUID
  public let projectID: UUID
  public var title: String
  public var plg: TatwoLoopsPLG
  public let supervisorModelID: String
  public var reviewerModelID: String?
  public var subAgents: [TatwoLoopsSubAgent]
  public var status: TatwoLoopsStatus
  public var cycles: [TatwoLoopsCycleProgress]
  public let createdISO: String
  public var messages: [TatwoLoopsMessage]
  public var archivedISO: String? = nil

  public var isArchived: Bool {
    archivedISO != nil
  }

  fileprivate init(
    id: UUID,
    parentKind: TatwoLoopsParentKind,
    parentID: UUID,
    projectID: UUID,
    title: String,
    plg: TatwoLoopsPLG,
    supervisorModelID: String,
    reviewerModelID: String?,
    subAgents: [TatwoLoopsSubAgent],
    status: TatwoLoopsStatus,
    cycles: [TatwoLoopsCycleProgress],
    createdISO: String,
    messages: [TatwoLoopsMessage]
  ) {
    self.id = id
    self.parentKind = parentKind
    self.parentID = parentID
    self.projectID = projectID
    self.title = title
    self.plg = plg
    self.supervisorModelID = supervisorModelID
    self.reviewerModelID = reviewerModelID
    self.subAgents = subAgents
    self.status = status
    self.cycles = cycles
    self.createdISO = createdISO
    self.messages = messages
  }
}

public enum TatwoLoopsSupervisorRule {
  public static func make(
    parentSupervisorModelID: String,
    parentKind: TatwoLoopsParentKind,
    parentID: UUID,
    projectID: UUID,
    title: String,
    plg: TatwoLoopsPLG,
    reviewerModelID: String?
  ) -> TatwoLoopsSession {
    TatwoLoopsSession(
      id: UUID(),
      parentKind: parentKind,
      parentID: parentID,
      projectID: projectID,
      title: title,
      plg: plg,
      supervisorModelID: parentSupervisorModelID,
      reviewerModelID: reviewerModelID,
      subAgents: [],
      status: .planned,
      cycles: [],
      createdISO: ISO8601DateFormatter().string(from: Date()),
      messages: [])
  }

  public static func validateInheritance(
    child: TatwoLoopsSession,
    parentSupervisorModelID: String
  ) -> Bool {
    child.supervisorModelID == parentSupervisorModelID
  }
}

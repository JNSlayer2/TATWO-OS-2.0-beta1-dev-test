import Foundation

// MARK: - 討論串 tree + asymmetric three-phase (os.md §9.4 / §5 P2)
//
// Hierarchy: project → thread → #討論串.
// The `#` prefix is a structural marker. `TatwoDiscussionMarkerTitleV1` always
// exposes a marked title; no public API returns an unmarked form.
//
// Asymmetric lifecycle (no skip, no reverse):
//   snapshotInherited → inProgress → closed
// - open: inherit parent snapshot
// - inProgress: only metrics (messageCount / lastActiveAt); full text sealed
// - closed: compressed summary shaped for parent-thread injection

// MARK: - Errors

public enum TatwoThreadTreeErrorV1: Error, LocalizedError, Equatable, Sendable {
  case emptyMarkerLabel
  case projectNotFound(String)
  case threadNotFound(String)
  case discussionNotFound(String)
  case invalidTransition(
    from: TatwoDiscussionPhaseKindV1,
    to: TatwoDiscussionPhaseKindV1)
  case fullTextSealedWhileInProgress
  case summaryRequiredToClose
  case emptyProjectTitle
  case emptyThreadTitle
  case schemaMismatch(String)
  case corruptDocument(String)

  public var errorDescription: String? {
    switch self {
    case .emptyMarkerLabel:
      "discussion marker label must be non-empty after normalization"
    case let .projectNotFound(id):
      "project not found: \(id)"
    case let .threadNotFound(id):
      "thread not found: \(id)"
    case let .discussionNotFound(id):
      "discussion not found: \(id)"
    case let .invalidTransition(from, to):
      "discussion phase transition rejected: \(from.rawValue) → \(to.rawValue)"
    case .fullTextSealedWhileInProgress:
      "inProgress discussions expose metrics only; full text is sealed"
    case .summaryRequiredToClose:
      "closing a discussion requires a non-empty compressed summary"
    case .emptyProjectTitle:
      "project title must be non-empty"
    case .emptyThreadTitle:
      "thread title must be non-empty"
    case let .schemaMismatch(schema):
      "thread tree schema mismatch: \(schema)"
    case let .corruptDocument(detail):
      "thread tree document is corrupt: \(detail)"
    }
  }
}

// MARK: - # marker title (type-level: cannot strip)

/// Structural `#討論串` title. Callers only ever see `marked` (always `#…`).
/// There is intentionally no public unmarked / strip / drop-prefix API.
public struct TatwoDiscussionMarkerTitleV1: Codable, Sendable, Equatable, Hashable {
  public static let prefix: Character = "#"

  /// Body stored without the leading `#`. Never exposed publicly.
  private let body: String

  /// Always `#` + normalized body. This is the only public string form.
  public var marked: String {
    "\(Self.prefix)\(body)"
  }

  /// Accepts labels with or without a leading `#`; normalizes to a single `#`.
  public init(label: String) throws {
    var working = label.trimmingCharacters(in: .whitespacesAndNewlines)
    while working.first == Self.prefix {
      working = String(working.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !working.isEmpty else {
      throw TatwoThreadTreeErrorV1.emptyMarkerLabel
    }
    // Reject internal newlines / control for stable UI keys.
    let hasControl = working.unicodeScalars.contains { scalar in
      CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\r"
    }
    guard !hasControl else {
      throw TatwoThreadTreeErrorV1.emptyMarkerLabel
    }
    self.body = working
  }

  private enum CodingKeys: String, CodingKey {
    case marked
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let marked = try container.decode(String.self, forKey: .marked)
    try self.init(label: marked)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(marked, forKey: .marked)
  }
}

// MARK: - Phase kinds / payloads

public enum TatwoDiscussionPhaseKindV1: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case snapshotInherited
  case inProgress
  case closed
}

/// Parent thread material captured at open time (snapshot inheritance).
public struct TatwoParentThreadSnapshotV1: Codable, Sendable, Equatable, Hashable {
  public let parentThreadID: String
  public let parentMessageCount: Int
  public let parentTranscriptDigest: String
  public let inheritedContext: String
  public let capturedAt: Date

  public init(
    parentThreadID: String,
    parentMessageCount: Int,
    parentTranscriptDigest: String,
    inheritedContext: String,
    capturedAt: Date = Date()
  ) {
    self.parentThreadID = parentThreadID
    self.parentMessageCount = max(0, parentMessageCount)
    self.parentTranscriptDigest = parentTranscriptDigest
    self.inheritedContext = inheritedContext
    self.capturedAt = capturedAt
  }
}

/// The only surface exposed while a discussion is `inProgress`.
public struct TatwoDiscussionProgressMetricsV1: Codable, Sendable, Equatable, Hashable {
  public let messageCount: Int
  public let lastActiveAt: Date

  public init(messageCount: Int, lastActiveAt: Date) {
    self.messageCount = max(0, messageCount)
    self.lastActiveAt = lastActiveAt
  }
}

/// Closed-phase payload shaped for injection into the parent thread.
public struct TatwoDiscussionInjectionSummaryV1: Codable, Sendable, Equatable, Hashable {
  public static let schemaName = "TatwoDiscussionInjectionSummaryV1"

  public let schema: String
  public let discussionID: String
  public let markedTitle: String
  public let parentThreadID: String
  public let parentProjectID: String
  public let compressedSummary: String
  public let messageCount: Int
  public let closedAt: Date
  public let sourcePhaseSequence: [TatwoDiscussionPhaseKindV1]

  public init(
    schema: String = TatwoDiscussionInjectionSummaryV1.schemaName,
    discussionID: String,
    markedTitle: String,
    parentThreadID: String,
    parentProjectID: String,
    compressedSummary: String,
    messageCount: Int,
    closedAt: Date,
    sourcePhaseSequence: [TatwoDiscussionPhaseKindV1] = [
      .snapshotInherited, .inProgress, .closed,
    ]
  ) {
    self.schema = schema
    self.discussionID = discussionID
    self.markedTitle = markedTitle
    self.parentThreadID = parentThreadID
    self.parentProjectID = parentProjectID
    self.compressedSummary = compressedSummary
    self.messageCount = max(0, messageCount)
    self.closedAt = closedAt
    self.sourcePhaseSequence = sourcePhaseSequence
  }
}

// MARK: - Discussion node

public struct TatwoThreadTreeDiscussionV1: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let markerTitle: TatwoDiscussionMarkerTitleV1
  public private(set) var phase: TatwoDiscussionPhaseKindV1
  public let openedAt: Date
  public private(set) var lastActiveAt: Date
  public let parentSnapshot: TatwoParentThreadSnapshotV1
  /// Sealed body store. Never returned by public inProgress accessors.
  private var sealedMessages: [String]
  public private(set) var injectionSummary: TatwoDiscussionInjectionSummaryV1?

  public var markedTitle: String { markerTitle.marked }

  public init(
    id: String = UUID().uuidString,
    markerTitle: TatwoDiscussionMarkerTitleV1,
    parentSnapshot: TatwoParentThreadSnapshotV1,
    openedAt: Date = Date()
  ) {
    self.id = id
    self.markerTitle = markerTitle
    self.phase = .snapshotInherited
    self.openedAt = openedAt
    self.lastActiveAt = openedAt
    self.parentSnapshot = parentSnapshot
    self.sealedMessages = []
    self.injectionSummary = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case markerTitle
    case phase
    case openedAt
    case lastActiveAt
    case parentSnapshot
    case sealedMessages
    case injectionSummary
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    markerTitle = try container.decode(TatwoDiscussionMarkerTitleV1.self, forKey: .markerTitle)
    phase = try container.decode(TatwoDiscussionPhaseKindV1.self, forKey: .phase)
    openedAt = try container.decode(Date.self, forKey: .openedAt)
    lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
    parentSnapshot = try container.decode(TatwoParentThreadSnapshotV1.self, forKey: .parentSnapshot)
    sealedMessages = try container.decodeIfPresent([String].self, forKey: .sealedMessages) ?? []
    injectionSummary = try container.decodeIfPresent(
      TatwoDiscussionInjectionSummaryV1.self,
      forKey: .injectionSummary)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(markerTitle, forKey: .markerTitle)
    try container.encode(phase, forKey: .phase)
    try container.encode(openedAt, forKey: .openedAt)
    try container.encode(lastActiveAt, forKey: .lastActiveAt)
    try container.encode(parentSnapshot, forKey: .parentSnapshot)
    try container.encode(sealedMessages, forKey: .sealedMessages)
    try container.encodeIfPresent(injectionSummary, forKey: .injectionSummary)
  }

  /// Metrics-only view. Safe for any phase; does not expose full text.
  public var progressMetrics: TatwoDiscussionProgressMetricsV1 {
    TatwoDiscussionProgressMetricsV1(
      messageCount: sealedMessages.count,
      lastActiveAt: lastActiveAt)
  }

  /// Full sealed messages — only legal after close (or for tests via tree API that
  /// still refuses while inProgress). Direct access throws while inProgress.
  public func fullTextIfAllowed() throws -> [String] {
    if phase == .inProgress {
      throw TatwoThreadTreeErrorV1.fullTextSealedWhileInProgress
    }
    return sealedMessages
  }

  /// Parent snapshot is visible during `snapshotInherited` and remains for audit.
  public var inheritedSnapshot: TatwoParentThreadSnapshotV1 {
    parentSnapshot
  }

  mutating func beginProgress(at date: Date) throws {
    guard phase == .snapshotInherited else {
      throw TatwoThreadTreeErrorV1.invalidTransition(from: phase, to: .inProgress)
    }
    phase = .inProgress
    lastActiveAt = date
  }

  mutating func recordMessage(_ text: String, at date: Date) throws {
    guard phase == .inProgress else {
      // Messages only flow during inProgress; opening must beginProgress first.
      throw TatwoThreadTreeErrorV1.invalidTransition(from: phase, to: .inProgress)
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    sealedMessages.append(trimmed)
    lastActiveAt = date
  }

  mutating func close(
    compressedSummary: String,
    parentProjectID: String,
    at date: Date
  ) throws -> TatwoDiscussionInjectionSummaryV1 {
    guard phase == .inProgress else {
      throw TatwoThreadTreeErrorV1.invalidTransition(from: phase, to: .closed)
    }
    let summary = compressedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summary.isEmpty else {
      throw TatwoThreadTreeErrorV1.summaryRequiredToClose
    }
    let injection = TatwoDiscussionInjectionSummaryV1(
      discussionID: id,
      markedTitle: markerTitle.marked,
      parentThreadID: parentSnapshot.parentThreadID,
      parentProjectID: parentProjectID,
      compressedSummary: summary,
      messageCount: sealedMessages.count,
      closedAt: date)
    phase = .closed
    lastActiveAt = date
    injectionSummary = injection
    // Drop sealed full text after close — only compressed summary remains public.
    sealedMessages = []
    return injection
  }
}

// MARK: - Thread / project nodes

public struct TatwoThreadTreeThreadV1: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public var title: String
  /// Fileprivate setter so `TatwoThreadTreeV1` in this file can mutate children.
  public fileprivate(set) var discussions: [TatwoThreadTreeDiscussionV1]
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: String = UUID().uuidString,
    title: String,
    discussions: [TatwoThreadTreeDiscussionV1] = [],
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw TatwoThreadTreeErrorV1.emptyThreadTitle
    }
    self.id = id
    self.title = trimmed
    self.discussions = discussions
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

public struct TatwoThreadTreeProjectV1: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public var title: String
  /// Fileprivate setter so `TatwoThreadTreeV1` in this file can mutate children.
  public fileprivate(set) var threads: [TatwoThreadTreeThreadV1]
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: String = UUID().uuidString,
    title: String,
    threads: [TatwoThreadTreeThreadV1] = [],
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw TatwoThreadTreeErrorV1.emptyProjectTitle
    }
    self.id = id
    self.title = trimmed
    self.threads = threads
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

// MARK: - Tree (in-memory state machine; optional disk via caller)

/// Core tree + state machine. Persistence is left to callers / later UI wave;
/// this type is pure value-semantic logic so View layers stay thin.
public struct TatwoThreadTreeV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoThreadTreeV1"

  public let schema: String
  public fileprivate(set) var projects: [TatwoThreadTreeProjectV1]

  public init(
    schema: String = TatwoThreadTreeV1.schemaName,
    projects: [TatwoThreadTreeProjectV1] = []
  ) throws {
    guard schema == Self.schemaName else {
      throw TatwoThreadTreeErrorV1.schemaMismatch(schema)
    }
    self.schema = schema
    self.projects = projects
  }

  private enum CodingKeys: String, CodingKey {
    case schema
    case projects
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schema = try container.decode(String.self, forKey: .schema)
    guard schema == Self.schemaName else {
      throw TatwoThreadTreeErrorV1.schemaMismatch(schema)
    }
    self.schema = schema
    self.projects = try container.decodeIfPresent(
      [TatwoThreadTreeProjectV1].self,
      forKey: .projects) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(projects, forKey: .projects)
  }

  // MARK: Structure

  @discardableResult
  public mutating func addProject(
    title: String,
    id: String = UUID().uuidString,
    at date: Date = Date()
  ) throws -> TatwoThreadTreeProjectV1 {
    let project = try TatwoThreadTreeProjectV1(
      id: id,
      title: title,
      createdAt: date,
      updatedAt: date)
    projects.append(project)
    return project
  }

  @discardableResult
  public mutating func addThread(
    projectID: String,
    title: String,
    id: String = UUID().uuidString,
    at date: Date = Date()
  ) throws -> TatwoThreadTreeThreadV1 {
    let projectIndex = try indexOfProject(projectID)
    let thread = try TatwoThreadTreeThreadV1(
      id: id,
      title: title,
      createdAt: date,
      updatedAt: date)
    projects[projectIndex].threads.append(thread)
    projects[projectIndex].updatedAt = date
    return thread
  }

  /// Open a `#討論串` under a thread. Always starts in `snapshotInherited`.
  @discardableResult
  public mutating func openDiscussion(
    projectID: String,
    threadID: String,
    label: String,
    parentSnapshot: TatwoParentThreadSnapshotV1,
    id: String = UUID().uuidString,
    at date: Date = Date()
  ) throws -> TatwoThreadTreeDiscussionV1 {
    let marker = try TatwoDiscussionMarkerTitleV1(label: label)
    var snapshot = parentSnapshot
    // Parent thread id in snapshot must match the hosting thread.
    if snapshot.parentThreadID != threadID {
      snapshot = TatwoParentThreadSnapshotV1(
        parentThreadID: threadID,
        parentMessageCount: snapshot.parentMessageCount,
        parentTranscriptDigest: snapshot.parentTranscriptDigest,
        inheritedContext: snapshot.inheritedContext,
        capturedAt: snapshot.capturedAt)
    }
    let discussion = TatwoThreadTreeDiscussionV1(
      id: id,
      markerTitle: marker,
      parentSnapshot: snapshot,
      openedAt: date)
    let path = try pathToThread(projectID: projectID, threadID: threadID)
    projects[path.project].threads[path.thread].discussions.append(discussion)
    projects[path.project].threads[path.thread].updatedAt = date
    projects[path.project].updatedAt = date
    return discussion
  }

  // MARK: Phase transitions

  @discardableResult
  public mutating func beginProgress(
    projectID: String,
    threadID: String,
    discussionID: String,
    at date: Date = Date()
  ) throws -> TatwoThreadTreeDiscussionV1 {
    let path = try pathToDiscussion(
      projectID: projectID,
      threadID: threadID,
      discussionID: discussionID)
    try projects[path.project].threads[path.thread].discussions[path.discussion]
      .beginProgress(at: date)
    projects[path.project].threads[path.thread].updatedAt = date
    projects[path.project].updatedAt = date
    return projects[path.project].threads[path.thread].discussions[path.discussion]
  }

  /// Append sealed message body while inProgress. Full text never leaves via metrics API.
  @discardableResult
  public mutating func appendSealedMessage(
    projectID: String,
    threadID: String,
    discussionID: String,
    text: String,
    at date: Date = Date()
  ) throws -> TatwoDiscussionProgressMetricsV1 {
    let path = try pathToDiscussion(
      projectID: projectID,
      threadID: threadID,
      discussionID: discussionID)
    try projects[path.project].threads[path.thread].discussions[path.discussion]
      .recordMessage(text, at: date)
    projects[path.project].threads[path.thread].updatedAt = date
    projects[path.project].updatedAt = date
    return projects[path.project].threads[path.thread].discussions[path.discussion]
      .progressMetrics
  }

  @discardableResult
  public mutating func closeDiscussion(
    projectID: String,
    threadID: String,
    discussionID: String,
    compressedSummary: String,
    at date: Date = Date()
  ) throws -> TatwoDiscussionInjectionSummaryV1 {
    let path = try pathToDiscussion(
      projectID: projectID,
      threadID: threadID,
      discussionID: discussionID)
    let injection = try projects[path.project].threads[path.thread]
      .discussions[path.discussion]
      .close(
        compressedSummary: compressedSummary,
        parentProjectID: projectID,
        at: date)
    projects[path.project].threads[path.thread].updatedAt = date
    projects[path.project].updatedAt = date
    return injection
  }

  // MARK: Safe reads

  public func discussion(
    projectID: String,
    threadID: String,
    discussionID: String
  ) throws -> TatwoThreadTreeDiscussionV1 {
    let path = try pathToDiscussion(
      projectID: projectID,
      threadID: threadID,
      discussionID: discussionID)
    return projects[path.project].threads[path.thread].discussions[path.discussion]
  }

  /// Metrics-only read (never full text).
  public func progressMetrics(
    projectID: String,
    threadID: String,
    discussionID: String
  ) throws -> TatwoDiscussionProgressMetricsV1 {
    try discussion(
      projectID: projectID,
      threadID: threadID,
      discussionID: discussionID
    ).progressMetrics
  }

  /// Full text — refused while `inProgress`.
  public func sealedFullText(
    projectID: String,
    threadID: String,
    discussionID: String
  ) throws -> [String] {
    try discussion(
      projectID: projectID,
      threadID: threadID,
      discussionID: discussionID
    ).fullTextIfAllowed()
  }

  /// Injection payload after close; nil if not yet closed.
  public func injectionSummary(
    projectID: String,
    threadID: String,
    discussionID: String
  ) throws -> TatwoDiscussionInjectionSummaryV1? {
    try discussion(
      projectID: projectID,
      threadID: threadID,
      discussionID: discussionID
    ).injectionSummary
  }

  // MARK: - Index helpers

  private struct ThreadPath {
    let project: Int
    let thread: Int
  }

  private struct DiscussionPath {
    let project: Int
    let thread: Int
    let discussion: Int
  }

  private func indexOfProject(_ projectID: String) throws -> Int {
    guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
      throw TatwoThreadTreeErrorV1.projectNotFound(projectID)
    }
    return index
  }

  private func pathToThread(projectID: String, threadID: String) throws -> ThreadPath {
    let projectIndex = try indexOfProject(projectID)
    let threads = projects[projectIndex].threads
    guard let threadIndex = threads.firstIndex(where: { $0.id == threadID }) else {
      throw TatwoThreadTreeErrorV1.threadNotFound(threadID)
    }
    return ThreadPath(project: projectIndex, thread: threadIndex)
  }

  private func pathToDiscussion(
    projectID: String,
    threadID: String,
    discussionID: String
  ) throws -> DiscussionPath {
    let threadPath = try pathToThread(projectID: projectID, threadID: threadID)
    let discussions = projects[threadPath.project].threads[threadPath.thread].discussions
    guard let discussionIndex = discussions.firstIndex(where: { $0.id == discussionID }) else {
      throw TatwoThreadTreeErrorV1.discussionNotFound(discussionID)
    }
    return DiscussionPath(
      project: threadPath.project,
      thread: threadPath.thread,
      discussion: discussionIndex)
  }
}

// MARK: - Explicit schema factory (fail-closed)

extension TatwoThreadTreeV1 {
  public static func empty() -> TatwoThreadTreeV1 {
    // schemaName is constant; init only throws on mismatch.
    try! TatwoThreadTreeV1(projects: [])
  }

  public static func decode(from data: Data) throws -> TatwoThreadTreeV1 {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let tree: TatwoThreadTreeV1
    do {
      tree = try decoder.decode(TatwoThreadTreeV1.self, from: data)
    } catch let treeError as TatwoThreadTreeErrorV1 {
      throw treeError
    } catch {
      throw TatwoThreadTreeErrorV1.corruptDocument(error.localizedDescription)
    }
    guard tree.schema == schemaName else {
      throw TatwoThreadTreeErrorV1.schemaMismatch(tree.schema)
    }
    return tree
  }

  public func encodeDocument() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}

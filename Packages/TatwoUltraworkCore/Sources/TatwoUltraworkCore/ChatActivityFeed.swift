import Foundation

/// Structured activity kinds emitted while a chat turn is running.
///
/// The enum intentionally keeps a small set of stable, UI-agnostic buckets.
/// Providers may preserve their native event name in `sourceType` on
/// `ChatActivityEventV1` when a more specific bucket is not available.
public enum ChatActivityKindV1: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
  case toolUse
  case command
  case fileEdit
  case fileRead
  case webFetch
  case search
  case thinking
  case mcp
  case unknown
}

/// Lifecycle status for one activity/call.
public enum ChatActivityStatusV1: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
  case running
  case succeeded
  case failed

  public var isTerminal: Bool {
    switch self {
    case .running:
      return false
    case .succeeded, .failed:
      return true
    }
  }
}

/// Immutable structured activity input (and the current row value returned by
/// `ChatActivityFeedReducer`).
///
/// `id` is the provider/tool call identifier. Pairing is scoped by
/// `(turnID, attempt, id)`, so a reused provider identifier in another turn
/// **or another launch attempt of the same turn** (e.g. bridge retry = attempt 2)
/// cannot update this row.
public struct ChatActivityEventV1: Codable, Identifiable, Sendable, Equatable, Hashable {
  public let id: String
  public let kind: ChatActivityKindV1
  public let label: String
  public let detail: String?
  public let startedAt: Date
  public let endedAt: Date?
  public let status: ChatActivityStatusV1
  public let turnID: String
  /// Launch attempt / generation within the same user turn. Bridge retry uses 2.
  public let attempt: Int
  public let sourceType: String?

  public var callID: String { id }
  public var sourceTurnID: String { turnID }
  public var generation: Int { attempt }

  public init(
    id: String,
    kind: ChatActivityKindV1,
    label: String,
    detail: String? = nil,
    startedAt: Date,
    endedAt: Date? = nil,
    status: ChatActivityStatusV1,
    turnID: String,
    attempt: Int = 1,
    sourceType: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.detail = detail
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.status = status
    self.turnID = turnID
    self.attempt = max(1, attempt)
    self.sourceType = sourceType
  }
}

/// A reducer snapshot suitable for a future activity strip.
///
/// Running rows are always retained in `activities`. The configured completed
/// limit only controls how many terminal rows are visible; older terminal rows
/// are represented by `completedOverflowCount` rather than silently dropped.
public struct ChatActivityFeedV1: Sendable, Equatable {
  public let activities: [ChatActivityEventV1]
  public let completedOverflowCount: Int

  public init(
    activities: [ChatActivityEventV1],
    completedOverflowCount: Int
  ) {
    self.activities = activities
    self.completedOverflowCount = max(0, completedOverflowCount)
  }

  public var isEmpty: Bool {
    activities.isEmpty && completedOverflowCount == 0
  }

  public var inFlight: [ChatActivityEventV1] {
    activities.filter { $0.status == .running }
  }

  public var completed: [ChatActivityEventV1] {
    activities.filter { $0.status.isTerminal }
  }
}

/// Pure Core reducer for structured chat activity events.
///
/// Events may arrive as starts, updates, or terminal (`succeeded`/`failed`)
/// notifications. A terminal event received before its start is retained and
/// merged when the start arrives later. Unknown/unpaired terminal events are
/// deliberately tolerated and remain visible as terminal rows.
public struct ChatActivityFeedReducer: Sendable {
  public let maxVisibleCompleted: Int

  private struct ActivityKey: Hashable, Sendable {
    let turnID: String
    let attempt: Int
    let activityID: String
  }

  private var rows: [ActivityKey: ChatActivityEventV1] = [:]

  public init(maxVisibleCompleted: Int = 12) {
    self.maxVisibleCompleted = max(0, maxVisibleCompleted)
  }

  /// Applies one event to the in-memory feed.
  public mutating func reduce(_ event: ChatActivityEventV1) {
    let key = ActivityKey(turnID: event.turnID, attempt: event.attempt, activityID: event.id)
    guard let current = rows[key] else {
      rows[key] = normalized(event)
      return
    }
    rows[key] = merged(current: current, incoming: event)
  }

  /// Applies events in source order. The reducer itself remains deterministic
  /// when an end arrives before a start because `reduce(_:)` performs upsert
  /// pairing by `(turnID, attempt, id)`.
  public mutating func reduce<S: Sequence>(
    _ events: S
  ) where S.Element == ChatActivityEventV1 {
    for event in events {
      reduce(event)
    }
  }

  /// All turns combined, with running rows first and terminal rows newest
  /// first. Use `feed(for:)` to render one turn in isolation.
  public var feed: ChatActivityFeedV1 {
    makeFeed(turnID: nil)
  }

  /// Returns the feed for a single turn. Rows from another turn cannot pair
  /// with or reorder this result.
  public func feed(for turnID: String) -> ChatActivityFeedV1 {
    makeFeed(turnID: turnID)
  }

  /// Clears all rows, or only rows belonging to one turn.
  public mutating func reset(turnID: String? = nil) {
    guard let turnID else {
      rows.removeAll(keepingCapacity: true)
      return
    }
    rows = rows.filter { $0.key.turnID != turnID }
  }

  private func makeFeed(turnID: String?) -> ChatActivityFeedV1 {
    let selected = rows.values.filter { event in
      guard let turnID else { return true }
      return event.turnID == turnID
    }

    let running = selected
      .filter { !$0.status.isTerminal }
      .sorted(by: Self.runningOrder)
    let completed = selected
      .filter { $0.status.isTerminal }
      .sorted(by: Self.completedOrder)
    let visibleCompleted = Array(completed.prefix(maxVisibleCompleted))
    return ChatActivityFeedV1(
      activities: running + visibleCompleted,
      completedOverflowCount: completed.count - visibleCompleted.count
    )
  }

  private static func runningOrder(
    _ lhs: ChatActivityEventV1,
    _ rhs: ChatActivityEventV1
  ) -> Bool {
    if lhs.startedAt != rhs.startedAt {
      return lhs.startedAt < rhs.startedAt
    }
    if lhs.turnID != rhs.turnID {
      return lhs.turnID < rhs.turnID
    }
    if lhs.attempt != rhs.attempt {
      return lhs.attempt < rhs.attempt
    }
    return lhs.id < rhs.id
  }

  private static func completedOrder(
    _ lhs: ChatActivityEventV1,
    _ rhs: ChatActivityEventV1
  ) -> Bool {
    let lhsDate = lhs.endedAt ?? lhs.startedAt
    let rhsDate = rhs.endedAt ?? rhs.startedAt
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }
    if lhs.turnID != rhs.turnID {
      return lhs.turnID < rhs.turnID
    }
    if lhs.attempt != rhs.attempt {
      return lhs.attempt > rhs.attempt
    }
    return lhs.id < rhs.id
  }

  private func normalized(_ event: ChatActivityEventV1) -> ChatActivityEventV1 {
    guard event.status.isTerminal else {
      return event
    }
    let end = event.endedAt ?? event.startedAt
    return ChatActivityEventV1(
      id: event.id,
      kind: event.kind,
      label: event.label,
      detail: event.detail,
      startedAt: event.startedAt,
      endedAt: max(end, event.startedAt),
      status: event.status,
      turnID: event.turnID,
      attempt: event.attempt,
      sourceType: event.sourceType
    )
  }

  private func merged(
    current: ChatActivityEventV1,
    incoming: ChatActivityEventV1
  ) -> ChatActivityEventV1 {
    let currentTerminal = current.status.isTerminal
    let incomingTerminal = incoming.status.isTerminal
    let status: ChatActivityStatusV1
    if incomingTerminal {
      status = incoming.status
    } else if currentTerminal {
      // A late/replayed running event must not regress a completed row.
      status = current.status
    } else {
      status = .running
    }

    let startedAt = min(current.startedAt, incoming.startedAt)
    let candidateEnd = incoming.endedAt ?? current.endedAt
    let endedAt: Date?
    if status.isTerminal {
      endedAt = max(candidateEnd ?? startedAt, startedAt)
    } else {
      endedAt = nil
    }

    let label = current.label.isEmpty ? incoming.label : current.label
    let detail = incoming.detail ?? current.detail
    let sourceType = incoming.sourceType ?? current.sourceType
    let kind = current.kind == .unknown ? incoming.kind : current.kind
    return ChatActivityEventV1(
      id: current.id,
      kind: kind,
      label: label,
      detail: detail,
      startedAt: startedAt,
      endedAt: endedAt,
      status: status,
      turnID: current.turnID,
      attempt: current.attempt,
      sourceType: sourceType
    )
  }
}

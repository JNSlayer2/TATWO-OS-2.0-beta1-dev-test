import Foundation

// MARK: - Stream fragment state model
//
// Chat streaming is split into two zones:
// - **stable**: durable, replayable, reconnectable (may hit disk)
// - **tail**: memory-only incomplete stream (must never hit disk)
//
// Persistence is fail-closed: anything still in `.tail` is rejected.

/// Whether a stream fragment may leave process memory.
public enum StreamFragmentState: Sendable, Equatable, Hashable {
  /// Incomplete stream body; memory only — never persist.
  case tail
  /// Promoted checkpoint with a monotonic sequence number.
  case stable(sequence: Int)
}

/// One stream fragment (stable checkpoint or live tail).
public struct StreamFragment: Identifiable, Sendable, Equatable, Hashable {
  public let id: UUID
  public let sessionID: UUID
  public let content: String
  public let state: StreamFragmentState

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    content: String,
    state: StreamFragmentState
  ) {
    self.id = id
    self.sessionID = sessionID
    self.content = content
    self.state = state
  }

  public var isTail: Bool {
    if case .tail = state { return true }
    return false
  }

  public var isStable: Bool {
    if case .stable = state { return true }
    return false
  }

  public var stableSequence: Int? {
    if case .stable(let sequence) = state { return sequence }
    return nil
  }
}

public enum StreamFragmentPersistenceError: Error, Equatable, LocalizedError, Sendable {
  case rejectTail
  case notStable
  case sequenceRegression(current: Int, attempted: Int)
  case emptyPromote
  case noActiveTail

  public var errorDescription: String? {
    switch self {
    case .rejectTail:
      return "stream_fragment_reject_tail"
    case .notStable:
      return "stream_fragment_not_stable"
    case .sequenceRegression(let current, let attempted):
      return "stream_fragment_sequence_regression:\(current)->\(attempted)"
    case .emptyPromote:
      return "stream_fragment_empty_promote"
    case .noActiveTail:
      return "stream_fragment_no_active_tail"
    }
  }
}

// MARK: - Persistence gate (type + runtime seal)

/// Fail-closed helpers that keep unfinished stream tails off durable storage.
public enum ChatStreamPersistence: Sendable {
  /// Status values that mean an assistant message is still an unfinished tail.
  public static let inFlightStatuses: Set<String> = [
    "stream",
    "streaming",
    "thinking",
    "working",
    "checking",
    "queued",
  ]

  /// Rejects a fragment that is not stable. Call before any disk write.
  public static func requireStable(_ fragment: StreamFragment) throws {
    guard case .stable = fragment.state else {
      throw StreamFragmentPersistenceError.rejectTail
    }
  }

  /// Only stable fragments may be written. Order preserved.
  public static func persistableFragments(
    _ fragments: [StreamFragment]
  ) throws -> [StreamFragment] {
    var output: [StreamFragment] = []
    output.reserveCapacity(fragments.count)
    for fragment in fragments {
      try requireStable(fragment)
      output.append(fragment)
    }
    return output
  }

  /// Soft filter used when sealing a transcript of stored messages.
  public static func isInFlightStoredMessage(_ message: TatwoNativeChatStoredMessage) -> Bool {
    guard message.role == "assistant" || message.role == "Assistant" else {
      return false
    }
    let status = message.status?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    if status.isEmpty { return false }
    if inFlightStatuses.contains(status) { return true }
    // Compact activity labels used by ChatPage (`writing`, `building`, …)
    // while a turn is still open are also unfinished tails.
    if status.hasPrefix("failed") || status.hasPrefix("stopped") || status.hasPrefix("error") {
      return false
    }
    // Known terminal-ish statuses that are not in-flight.
    if status == "terminated" { return false }
    // Non-empty status on assistant while stream is open was historically
    // persisted mid-turn; treat plain activity words as in-flight.
    let activityPrefixes = [
      "writing", "building", "testing", "browsing", "viewing",
      "calling-tool", "running-command", "planning", "inspecting",
      "searching", "debugging", "editing", "sent", "session",
    ]
    return activityPrefixes.contains { status == $0 || status.hasPrefix($0 + "|") || status.hasPrefix($0 + " ") }
  }

  /// Messages safe to land on disk / reload after reconnect.
  public static func persistableStoredMessages(
    _ messages: [TatwoNativeChatStoredMessage]
  ) -> [TatwoNativeChatStoredMessage] {
    messages.filter { !isInFlightStoredMessage($0) }
  }

  /// Reconnect / cold start: only stable checkpoint material. Identical to
  /// persistable filter so a crash mid-stream cannot resurrect a tail.
  public static func reconnectStoredMessages(
    _ messages: [TatwoNativeChatStoredMessage]
  ) -> [TatwoNativeChatStoredMessage] {
    persistableStoredMessages(messages)
  }

  /// Seal a whole chat store document before write. Discussions and threads
  /// drop in-flight assistant rows; completed rows stay intact for migration.
  public static func sealing(_ document: TatwoNativeChatStoreDocument) -> TatwoNativeChatStoreDocument {
    var copy = document
    copy.threads = copy.threads.map(sealing(thread:))
    copy.projects = copy.projects.map { project in
      var p = project
      p.threads = p.threads.map(sealing(thread:))
      return p
    }
    return copy
  }

  private static func sealing(thread: TatwoNativeChatThread) -> TatwoNativeChatThread {
    var t = thread
    if let messages = t.messages {
      t.messages = persistableStoredMessages(messages)
    }
    t.discussions = t.discussions.map { discussion in
      var d = discussion
      d.messages = persistableStoredMessages(d.messages)
      return d
    }
    return t
  }
}

// MARK: - In-memory stream ledger

/// Owns stable checkpoints + at most one live tail for a chat session.
///
/// Persistence callers must use `persistableFragments()` / `appendStable`.
/// Tail content is never exposed through those APIs.
public final class StreamTranscriptLedger: @unchecked Sendable {
  public let sessionID: UUID

  private let lock = NSLock()
  private var stable: [StreamFragment] = []
  private var tail: StreamFragment?
  /// Highest assigned stable sequence (0 means none yet).
  private var lastSequence: Int = 0

  public init(sessionID: UUID = UUID()) {
    self.sessionID = sessionID
  }

  /// Last promoted sequence, if any.
  public var lastStableSequence: Int? {
    lock.lock()
    defer { lock.unlock() }
    return lastSequence > 0 ? lastSequence : nil
  }

  /// Stable fragments only — safe to write / reconnect from.
  public var persistableFragments: [StreamFragment] {
    lock.lock()
    defer { lock.unlock() }
    return stable
  }

  /// Stable + optional live tail for UI display.
  public var displayFragments: [StreamFragment] {
    lock.lock()
    defer { lock.unlock() }
    if let tail {
      return stable + [tail]
    }
    return stable
  }

  public var hasTail: Bool {
    lock.lock()
    defer { lock.unlock() }
    return tail != nil
  }

  public var tailContent: String? {
    lock.lock()
    defer { lock.unlock() }
    return tail?.content
  }

  /// Reconnect snapshot: last stable checkpoint material only (never tail).
  public func reconnectSnapshot() -> [StreamFragment] {
    persistableFragments
  }

  /// Begin or replace the memory-only tail for this stream turn.
  @discardableResult
  public func beginTail(
    content: String = "",
    id: UUID = UUID()
  ) -> StreamFragment {
    lock.lock()
    defer { lock.unlock() }
    let fragment = StreamFragment(
      id: id,
      sessionID: sessionID,
      content: content,
      state: .tail)
    tail = fragment
    return fragment
  }

  /// Append a chunk to the live tail (memory only).
  @discardableResult
  public func appendTailChunk(_ chunk: String, id: UUID? = nil) -> StreamFragment {
    lock.lock()
    defer { lock.unlock() }
    if let existing = tail {
      let next = StreamFragment(
        id: existing.id,
        sessionID: sessionID,
        content: existing.content + chunk,
        state: .tail)
      tail = next
      return next
    }
    let fragment = StreamFragment(
      id: id ?? UUID(),
      sessionID: sessionID,
      content: chunk,
      state: .tail)
    tail = fragment
    return fragment
  }

  /// Replace tail body without promoting (still memory only).
  @discardableResult
  public func replaceTailContent(_ content: String, id: UUID? = nil) -> StreamFragment {
    lock.lock()
    defer { lock.unlock() }
    let fragment = StreamFragment(
      id: id ?? tail?.id ?? UUID(),
      sessionID: sessionID,
      content: content,
      state: .tail)
    tail = fragment
    return fragment
  }

  /// Discard unfinished tail (crash / cancel / timeout path). Nothing is written.
  public func discardTail() {
    lock.lock()
    defer { lock.unlock() }
    tail = nil
  }

  /// Atomically promote the current tail into a stable fragment with the next
  /// monotonic sequence. Fails if there is no tail (or empty when `allowEmpty` is false).
  @discardableResult
  public func promoteTail(allowEmpty: Bool = true) throws -> StreamFragment {
    lock.lock()
    defer { lock.unlock() }
    guard let current = tail else {
      throw StreamFragmentPersistenceError.noActiveTail
    }
    let trimmed = current.content
    if !allowEmpty, trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw StreamFragmentPersistenceError.emptyPromote
    }
    let sequence = lastSequence + 1
    let promoted = StreamFragment(
      id: current.id,
      sessionID: sessionID,
      content: current.content,
      state: .stable(sequence: sequence))
    stable.append(promoted)
    lastSequence = sequence
    tail = nil
    return promoted
  }

  /// Append a pre-built **stable** fragment. Rejects tail and sequence regression.
  public func appendStable(_ fragment: StreamFragment) throws {
    try ChatStreamPersistence.requireStable(fragment)
    guard case .stable(let sequence) = fragment.state else {
      throw StreamFragmentPersistenceError.notStable
    }
    lock.lock()
    defer { lock.unlock() }
    if sequence <= lastSequence {
      throw StreamFragmentPersistenceError.sequenceRegression(
        current: lastSequence,
        attempted: sequence)
    }
    guard fragment.sessionID == sessionID else {
      // Foreign session fragments are not accepted into this ledger.
      throw StreamFragmentPersistenceError.notStable
    }
    stable.append(fragment)
    lastSequence = sequence
  }

  /// Seed stable history from durable storage after reconnect (no tails).
  public func restoreStableCheckpoint(_ fragments: [StreamFragment]) throws {
    let onlyStable = try ChatStreamPersistence.persistableFragments(fragments)
    lock.lock()
    defer { lock.unlock() }
    stable = []
    lastSequence = 0
    tail = nil
    for fragment in onlyStable {
      guard case .stable(let sequence) = fragment.state else {
        throw StreamFragmentPersistenceError.rejectTail
      }
      if sequence <= lastSequence {
        throw StreamFragmentPersistenceError.sequenceRegression(
          current: lastSequence,
          attempted: sequence)
      }
      stable.append(fragment)
      lastSequence = sequence
    }
  }
}

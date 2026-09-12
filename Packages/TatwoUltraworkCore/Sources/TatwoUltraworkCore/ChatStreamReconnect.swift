import Foundation

// MARK: - Reconnect degradation (stream / gateway transport)
//
// Explicit state machine for chat stream transport:
//   connected → degraded(retrying, backoff) → offline
//
// Rules:
// - Exponential backoff with a hard upper bound and attempt ceiling (no infinite retry).
// - On disconnect / degrade, only stable checkpoint material may resume
//   (`ChatStreamPersistence.reconnectSnapshot` / ledger.reconnectSnapshot).
// - Live tail is discarded and must never be replayed.
// - User-visible status is a compact token for existing fields (lastPreview /
//   message.status / diagnostics) — no new UI surface required.

/// Transport connectivity phase for a chat/stream session.
public enum ChatStreamConnectionPhase: String, Codable, Sendable, Equatable, Hashable {
  case connected
  case degraded
  case offline
}

/// Policy for automatic reconnect attempts.
public struct ChatStreamReconnectPolicy: Sendable, Equatable, Hashable {
  /// Delay before the first retry.
  public var initialBackoff: TimeInterval
  /// Hard ceiling for any single wait (exponential growth stops here).
  public var maxBackoff: TimeInterval
  /// Multiplier applied per subsequent attempt (`initial * multiplier^(attempt-1)`).
  public var multiplier: Double
  /// Maximum automatic retry attempts before entering `.offline`.
  public var maxAttempts: Int

  public static let `default` = ChatStreamReconnectPolicy(
    initialBackoff: 1,
    maxBackoff: 60,
    multiplier: 2,
    maxAttempts: 5)

  public init(
    initialBackoff: TimeInterval = 1,
    maxBackoff: TimeInterval = 60,
    multiplier: Double = 2,
    maxAttempts: Int = 5
  ) {
    self.initialBackoff = max(0.05, initialBackoff)
    self.maxBackoff = max(self.initialBackoff, maxBackoff)
    self.multiplier = max(1, multiplier)
    self.maxAttempts = max(1, maxAttempts)
  }

  /// Backoff for a 1-based attempt index, clamped to `maxBackoff`.
  public func backoff(forAttempt attempt: Int) -> TimeInterval {
    let index = max(1, attempt)
    let raw = initialBackoff * pow(multiplier, Double(index - 1))
    if raw.isNaN || raw.isInfinite {
      return maxBackoff
    }
    return min(maxBackoff, raw)
  }
}

/// Snapshot of reconnect controller state (value type for tests / projection).
public struct ChatStreamReconnectState: Sendable, Equatable, Hashable {
  public var phase: ChatStreamConnectionPhase
  /// 0 when connected; otherwise the current (or just-completed) attempt number.
  public var attempt: Int
  public var nextRetryAt: Date?
  public var lastReason: String?
  public var lastTransitionAt: Date
  public var lastStableSequence: Int?
  /// Session this controller is bound to (canonical Tatwo session UUID).
  public var sessionID: UUID

  public init(
    sessionID: UUID,
    phase: ChatStreamConnectionPhase = .connected,
    attempt: Int = 0,
    nextRetryAt: Date? = nil,
    lastReason: String? = nil,
    lastTransitionAt: Date = Date(timeIntervalSince1970: 0),
    lastStableSequence: Int? = nil
  ) {
    self.sessionID = sessionID
    self.phase = phase
    self.attempt = attempt
    self.nextRetryAt = nextRetryAt
    self.lastReason = lastReason
    self.lastTransitionAt = lastTransitionAt
    self.lastStableSequence = lastStableSequence
  }

  /// Compact token suitable for existing status / preview fields (no new UI).
  public var statusToken: String {
    switch phase {
    case .connected:
      return "connected"
    case .degraded:
      let backoffPart: String
      if let nextRetryAt {
        backoffPart = String(format: "%.0f", max(0, nextRetryAt.timeIntervalSince(lastTransitionAt)))
      } else {
        backoffPart = "0"
      }
      return "degraded|retrying|attempt=\(attempt)|backoff=\(backoffPart)s"
    case .offline:
      let reason = (lastReason?.isEmpty == false) ? (lastReason ?? "exhausted") : "exhausted"
      return "offline|\(reason)"
    }
  }

  public var isConnected: Bool { phase == .connected }
  public var isDegraded: Bool { phase == .degraded }
  public var isOffline: Bool { phase == .offline }
  public var allowsAutomaticRetry: Bool { phase == .degraded }
}

/// Stable-only material used when re-attaching after disconnect.
public struct ChatStreamReconnectMaterial: Sendable, Equatable {
  public let sessionID: UUID
  public let stableFragments: [StreamFragment]
  public let lastStableSequence: Int?
  public let discardedTail: Bool

  public init(
    sessionID: UUID,
    stableFragments: [StreamFragment],
    lastStableSequence: Int?,
    discardedTail: Bool
  ) {
    self.sessionID = sessionID
    self.stableFragments = stableFragments
    self.lastStableSequence = lastStableSequence
    self.discardedTail = discardedTail
  }

  public var isEmpty: Bool { stableFragments.isEmpty }
}

/// Decision returned by disconnect / retry-failure transitions.
public struct ChatStreamReconnectDecision: Sendable, Equatable {
  public let state: ChatStreamReconnectState
  public let shouldScheduleRetry: Bool
  public let retryDelay: TimeInterval?
  public let material: ChatStreamReconnectMaterial?

  public init(
    state: ChatStreamReconnectState,
    shouldScheduleRetry: Bool,
    retryDelay: TimeInterval? = nil,
    material: ChatStreamReconnectMaterial? = nil
  ) {
    self.state = state
    self.shouldScheduleRetry = shouldScheduleRetry
    self.retryDelay = retryDelay
    self.material = material
  }
}

/// Fail-closed helpers that build reconnect material without replaying tails.
public enum ChatStreamReconnectPersistence: Sendable {
  /// Capture stable checkpoint and drop any live tail. Never returns tail content.
  public static func materialForReconnect(
    from ledger: StreamTranscriptLedger
  ) -> ChatStreamReconnectMaterial {
    let snapshot = ledger.reconnectSnapshot()
    let hadTail = ledger.hasTail
    if hadTail {
      ledger.discardTail()
    }
    // Defense in depth: refuse any fragment that is still marked tail.
    let onlyStable = snapshot.filter(\.isStable)
    return ChatStreamReconnectMaterial(
      sessionID: ledger.sessionID,
      stableFragments: onlyStable,
      lastStableSequence: ledger.lastStableSequence,
      discardedTail: hadTail)
  }

  /// Rebuild a ledger from stable-only material (cold reconnect path).
  public static func restoreLedger(
    from material: ChatStreamReconnectMaterial
  ) throws -> StreamTranscriptLedger {
    let ledger = StreamTranscriptLedger(sessionID: material.sessionID)
    try ledger.restoreStableCheckpoint(material.stableFragments)
    return ledger
  }

  /// Stored-message path: drop in-flight assistant tails (same as Wave 1 seal).
  public static func reconnectStoredMessages(
    _ messages: [TatwoNativeChatStoredMessage]
  ) -> [TatwoNativeChatStoredMessage] {
    ChatStreamPersistence.reconnectStoredMessages(messages)
  }
}

/// Owns the reconnect state machine for one stream/session transport.
public final class ChatStreamReconnectController: @unchecked Sendable {
  public let policy: ChatStreamReconnectPolicy

  private let lock = NSLock()
  private var state: ChatStreamReconnectState

  public init(
    sessionID: UUID,
    policy: ChatStreamReconnectPolicy = .default,
    now: Date = Date()
  ) {
    self.policy = policy
    self.state = ChatStreamReconnectState(
      sessionID: sessionID,
      phase: .connected,
      attempt: 0,
      nextRetryAt: nil,
      lastReason: nil,
      lastTransitionAt: now,
      lastStableSequence: nil)
  }

  public var snapshot: ChatStreamReconnectState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  public var statusToken: String { snapshot.statusToken }

  /// Successful transport / handshake.
  @discardableResult
  public func noteConnected(
    at now: Date = Date(),
    lastStableSequence: Int? = nil
  ) -> ChatStreamReconnectState {
    lock.lock()
    defer { lock.unlock() }
    state.phase = .connected
    state.attempt = 0
    state.nextRetryAt = nil
    state.lastReason = nil
    state.lastTransitionAt = now
    if let lastStableSequence {
      state.lastStableSequence = lastStableSequence
    }
    return state
  }

  /// Transport lost while connected (or mid-retry). Schedules degraded retry
  /// or enters offline when the attempt budget is exhausted.
  @discardableResult
  public func noteDisconnect(
    reason: String,
    at now: Date = Date(),
    ledger: StreamTranscriptLedger? = nil
  ) -> ChatStreamReconnectDecision {
    let material = ledger.map { ChatStreamReconnectPersistence.materialForReconnect(from: $0) }
    lock.lock()
    defer { lock.unlock() }

    if let material {
      state.lastStableSequence = material.lastStableSequence
    }

    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let reasonToken = trimmed.isEmpty ? "disconnect" : trimmed

    switch state.phase {
    case .connected:
      return enterDegradedLocked(
        nextAttempt: 1,
        reason: reasonToken,
        at: now,
        material: material)
    case .degraded:
      // A disconnect while already degraded counts as a failed retry attempt.
      return advanceOrOfflineLocked(
        reason: reasonToken,
        at: now,
        material: material)
    case .offline:
      state.lastReason = reasonToken
      state.lastTransitionAt = now
      return ChatStreamReconnectDecision(
        state: state,
        shouldScheduleRetry: false,
        retryDelay: nil,
        material: material)
    }
  }

  /// Explicit failed reconnect attempt (caller already tried).
  @discardableResult
  public func noteRetryFailed(
    reason: String,
    at now: Date = Date(),
    ledger: StreamTranscriptLedger? = nil
  ) -> ChatStreamReconnectDecision {
    let material = ledger.map { ChatStreamReconnectPersistence.materialForReconnect(from: $0) }
    lock.lock()
    defer { lock.unlock() }
    if let material {
      state.lastStableSequence = material.lastStableSequence
    }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let reasonToken = trimmed.isEmpty ? "retry_failed" : trimmed

    switch state.phase {
    case .connected:
      // Treat as first disconnect if caller skipped noteDisconnect.
      return enterDegradedLocked(
        nextAttempt: 1,
        reason: reasonToken,
        at: now,
        material: material)
    case .degraded:
      return advanceOrOfflineLocked(
        reason: reasonToken,
        at: now,
        material: material)
    case .offline:
      state.lastReason = reasonToken
      state.lastTransitionAt = now
      return ChatStreamReconnectDecision(
        state: state,
        shouldScheduleRetry: false,
        retryDelay: nil,
        material: material)
    }
  }

  /// Successful reconnect after degrade/offline manual recovery.
  @discardableResult
  public func noteRetrySucceeded(
    at now: Date = Date(),
    lastStableSequence: Int? = nil
  ) -> ChatStreamReconnectState {
    noteConnected(at: now, lastStableSequence: lastStableSequence)
  }

  /// From offline, allow one more automatic budget (manual user/action path).
  @discardableResult
  public func requestManualReconnect(
    reason: String = "manual",
    at now: Date = Date()
  ) -> ChatStreamReconnectDecision {
    lock.lock()
    defer { lock.unlock() }
    guard state.phase == .offline || state.phase == .degraded else {
      return ChatStreamReconnectDecision(
        state: state,
        shouldScheduleRetry: false,
        retryDelay: nil,
        material: nil)
    }
    return enterDegradedLocked(
      nextAttempt: 1,
      reason: reason,
      at: now,
      material: nil)
  }

  /// Whether an automatic retry may fire at `now` (phase degraded + backoff elapsed).
  public func shouldAttemptRetry(at now: Date = Date()) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state.phase == .degraded else { return false }
    guard state.attempt >= 1, state.attempt <= policy.maxAttempts else { return false }
    guard let next = state.nextRetryAt else { return true }
    return now >= next
  }

  /// Compute delay for a 1-based attempt (exposed for tests / schedulers).
  public func backoffInterval(forAttempt attempt: Int) -> TimeInterval {
    policy.backoff(forAttempt: attempt)
  }

  // MARK: - Private transitions

  private func enterDegradedLocked(
    nextAttempt: Int,
    reason: String,
    at now: Date,
    material: ChatStreamReconnectMaterial?
  ) -> ChatStreamReconnectDecision {
    if nextAttempt > policy.maxAttempts {
      state.phase = .offline
      state.attempt = policy.maxAttempts
      state.nextRetryAt = nil
      state.lastReason = reason
      state.lastTransitionAt = now
      return ChatStreamReconnectDecision(
        state: state,
        shouldScheduleRetry: false,
        retryDelay: nil,
        material: material)
    }
    let delay = policy.backoff(forAttempt: nextAttempt)
    state.phase = .degraded
    state.attempt = nextAttempt
    state.nextRetryAt = now.addingTimeInterval(delay)
    state.lastReason = reason
    state.lastTransitionAt = now
    return ChatStreamReconnectDecision(
      state: state,
      shouldScheduleRetry: true,
      retryDelay: delay,
      material: material)
  }

  private func advanceOrOfflineLocked(
    reason: String,
    at now: Date,
    material: ChatStreamReconnectMaterial?
  ) -> ChatStreamReconnectDecision {
    let completedAttempt = max(1, state.attempt)
    let nextAttempt = completedAttempt + 1
    if nextAttempt > policy.maxAttempts {
      state.phase = .offline
      state.attempt = completedAttempt
      state.nextRetryAt = nil
      state.lastReason = reason
      state.lastTransitionAt = now
      return ChatStreamReconnectDecision(
        state: state,
        shouldScheduleRetry: false,
        retryDelay: nil,
        material: material)
    }
    return enterDegradedLocked(
      nextAttempt: nextAttempt,
      reason: reason,
      at: now,
      material: material)
  }
}

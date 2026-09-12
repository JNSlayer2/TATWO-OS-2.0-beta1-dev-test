import Foundation

public enum TatwoHostResourceTier: String, Codable, CaseIterable, Sendable, Equatable {
  case ram8GB = "8G"
  case ram16GB = "16G"
  case ram32GB = "32G"
  case ram64GB = "64G"
  case ram128GBPlus = "128G+"

  private static let gibibyte: UInt64 = 1_073_741_824

  public static func detected(physicalMemoryBytes: UInt64) -> Self {
    let thresholds: [(UInt64, Self)] = [
      (8 * gibibyte, .ram8GB),
      (16 * gibibyte, .ram16GB),
      (32 * gibibyte, .ram32GB),
      (64 * gibibyte, .ram64GB),
    ]
    for (nominalBytes, tier) in thresholds
    where physicalMemoryBytes <= nominalBytes + nominalBytes / 10 {
      return tier
    }
    return .ram128GBPlus
  }

  public var concurrentRuntimeLimit: Int {
    switch self {
    case .ram8GB: return 1
    case .ram16GB: return 2
    case .ram32GB: return 4
    case .ram64GB: return 6
    case .ram128GBPlus: return 8
    }
  }

  public var idleReclamationInterval: TimeInterval? {
    switch self {
    case .ram8GB: return 60
    case .ram16GB: return 300
    case .ram32GB: return 600
    case .ram64GB: return 900
    case .ram128GBPlus: return nil
    }
  }

  public var allowsConcurrentBuilds: Bool {
    self != .ram8GB
  }
}

public struct TatwoHostResourceProfile: Codable, Sendable, Equatable {
  public let schema: String
  public let detectedTier: TatwoHostResourceTier
  public let overrideTier: TatwoHostResourceTier?
  public let physicalMemoryBytes: UInt64
  public let detectedAt: Date

  public init(
    schema: String = "TatwoHostResourceProfileV1",
    detectedTier: TatwoHostResourceTier,
    overrideTier: TatwoHostResourceTier?,
    physicalMemoryBytes: UInt64,
    detectedAt: Date = Date()
  ) {
    self.schema = schema
    self.detectedTier = detectedTier
    self.overrideTier = overrideTier
    self.physicalMemoryBytes = physicalMemoryBytes
    self.detectedAt = detectedAt
  }

  public var effectiveTier: TatwoHostResourceTier {
    overrideTier ?? detectedTier
  }
}

public enum TatwoRuntimeWaitReason: Sendable, Equatable {
  case tierConcurrencyLimit(tier: TatwoHostResourceTier)

  public var machineReadableCode: String {
    switch self {
    case .tierConcurrencyLimit(let tier):
      return "tier_concurrency_limit:\(tier.rawValue)"
    }
  }
}

public enum TatwoRuntimeOccupancyKind: String, Codable, Sendable, Equatable {
  case chatPerTurn
  case chatPersistentSession
  case xxlGoalSpawn
}

public struct TatwoRuntimeLease: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let kind: TatwoRuntimeOccupancyKind

  public init(id: UUID, kind: TatwoRuntimeOccupancyKind) {
    self.id = id
    self.kind = kind
  }
}

public struct TatwoRuntimeGovernorSnapshot: Sendable, Equatable {
  public let tier: TatwoHostResourceTier
  public let activeLeases: [TatwoRuntimeLease]
  public let queuedRequestIDs: [UUID]

  public var activeRuntimeCount: Int { activeLeases.count }
  public var queuedRuntimeCount: Int { queuedRequestIDs.count }
}

public enum TatwoRuntimeGovernorError: Error, Sendable, Equatable {
  case cancelled
}

/// Process-local central registry for model runtime occupancy.
///
/// Chat requests obey the host tier and wait FIFO. XXL/goal spawns register as
/// externally governed occupancy: they remain visible and reduce subsequent
/// Chat capacity, but this governor never queues or terminates them.
public final class TatwoRuntimeGovernor: @unchecked Sendable {
  public static let shared = TatwoRuntimeGovernor(
    tier: .detected(
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
    automaticIdleReclamation: true)

  private struct ActiveEntry {
    let lease: TatwoRuntimeLease
    var activeTurnCount: Int
    var lastActiveAt: Date
    let gentleTermination: (@Sendable () -> Void)?
  }

  private struct PendingEntry {
    let requestID: UUID
    let kind: TatwoRuntimeOccupancyKind
    let continuation: CheckedContinuation<TatwoRuntimeLease, Error>
  }

  private let lock = NSLock()
  private let now: @Sendable () -> Date
  private let automaticIdleReclamation: Bool
  private let reclamationQueue = DispatchQueue(
    label: "com.tatwo.ultrawork.runtime-governor-idle")
  private var tier: TatwoHostResourceTier
  private var active: [UUID: ActiveEntry] = [:]
  private var queue: [PendingEntry] = []
  private var idleReclamationTimer: DispatchSourceTimer?

  public init(
    tier: TatwoHostResourceTier,
    now: @escaping @Sendable () -> Date = Date.init,
    automaticIdleReclamation: Bool = false
  ) {
    self.tier = tier
    self.now = now
    self.automaticIdleReclamation = automaticIdleReclamation
  }

  public func configure(tier: TatwoHostResourceTier) {
    lock.lock()
    self.tier = tier
    let admissions = drainFIFOIfPossibleLocked()
    let replacedTimer = rescheduleIdleReclamationLocked()
    lock.unlock()
    replacedTimer?.cancel()
    resume(admissions)
  }

  public func acquireChatRuntime(
    kind: TatwoRuntimeOccupancyKind = .chatPerTurn,
    onWait: @escaping @Sendable (TatwoRuntimeWaitReason) -> Void = { _ in }
  ) async throws -> TatwoRuntimeLease {
    precondition(
      kind != .xxlGoalSpawn,
      "XXL occupancy must use registerExternalRuntime")
    let requestID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var immediate: TatwoRuntimeLease?
        var waitReason: TatwoRuntimeWaitReason?
        lock.lock()
        if queue.isEmpty,
          active.count < tier.concurrentRuntimeLimit
        {
          let lease = TatwoRuntimeLease(id: requestID, kind: kind)
          active[lease.id] = ActiveEntry(
            lease: lease,
            activeTurnCount: 1,
            lastActiveAt: now(),
            gentleTermination: nil)
          immediate = lease
        } else {
          queue.append(PendingEntry(
            requestID: requestID,
            kind: kind,
            continuation: continuation))
          waitReason = .tierConcurrencyLimit(tier: tier)
        }
        lock.unlock()
        if let immediate {
          continuation.resume(returning: immediate)
        } else if let waitReason {
          onWait(waitReason)
        }
      }
    } onCancel: {
      self.cancelQueuedRequest(requestID)
    }
  }

  /// Preserves the existing synchronous Chat launch behavior when capacity
  /// is already free. It never jumps ahead of an existing FIFO waiter.
  public func acquireChatRuntimeIfAvailable(
    kind: TatwoRuntimeOccupancyKind = .chatPerTurn
  ) -> TatwoRuntimeLease? {
    precondition(
      kind != .xxlGoalSpawn,
      "XXL occupancy must use registerExternalRuntime")
    lock.lock()
    defer { lock.unlock() }
    guard queue.isEmpty,
      active.count < tier.concurrentRuntimeLimit
    else {
      return nil
    }
    let lease = TatwoRuntimeLease(id: UUID(), kind: kind)
    active[lease.id] = ActiveEntry(
      lease: lease,
      activeTurnCount: 1,
      lastActiveAt: now(),
      gentleTermination: nil)
    return lease
  }

  @discardableResult
  public func registerExternalRuntime(
    kind: TatwoRuntimeOccupancyKind = .xxlGoalSpawn,
    gentleTermination: (@Sendable () -> Void)? = nil
  ) -> TatwoRuntimeLease {
    let lease = TatwoRuntimeLease(id: UUID(), kind: kind)
    lock.lock()
    active[lease.id] = ActiveEntry(
      lease: lease,
      activeTurnCount: kind == .chatPersistentSession ? 0 : 1,
      lastActiveAt: now(),
      gentleTermination: gentleTermination)
    let replacedTimer = rescheduleIdleReclamationLocked()
    lock.unlock()
    replacedTimer?.cancel()
    return lease
  }

  public func release(_ lease: TatwoRuntimeLease) {
    lock.lock()
    active.removeValue(forKey: lease.id)
    let admissions = drainFIFOIfPossibleLocked()
    let replacedTimer = rescheduleIdleReclamationLocked()
    lock.unlock()
    replacedTimer?.cancel()
    resume(admissions)
  }

  public func markTurnStarted(for lease: TatwoRuntimeLease) {
    lock.lock()
    if var entry = active[lease.id] {
      entry.activeTurnCount += 1
      entry.lastActiveAt = now()
      active[lease.id] = entry
    }
    let replacedTimer = rescheduleIdleReclamationLocked()
    lock.unlock()
    replacedTimer?.cancel()
  }

  public func markTurnEnded(for lease: TatwoRuntimeLease) {
    lock.lock()
    if var entry = active[lease.id] {
      entry.activeTurnCount = max(0, entry.activeTurnCount - 1)
      entry.lastActiveAt = now()
      active[lease.id] = entry
    }
    let replacedTimer = rescheduleIdleReclamationLocked()
    lock.unlock()
    replacedTimer?.cancel()
  }

  @discardableResult
  public func reclaimIdlePersistentSessions() -> [TatwoRuntimeLease] {
    lock.lock()
    guard let idleInterval = tier.idleReclamationInterval else {
      lock.unlock()
      return []
    }
    let current = now()
    let reclaimable = active.values.filter {
      $0.lease.kind == .chatPersistentSession
        && $0.activeTurnCount == 0
        && current.timeIntervalSince($0.lastActiveAt) >= idleInterval
    }
    for entry in reclaimable {
      var terminating = entry
      // Keep the slot occupied until the gentle-termination request has
      // actually been delivered. A concurrent admission must not race ahead
      // of that request and temporarily exceed the host tier.
      terminating.activeTurnCount = -1
      active[entry.lease.id] = terminating
    }
    lock.unlock()

    for entry in reclaimable {
      entry.gentleTermination?()
    }

    // A gentle-termination request is not termination proof. Keep every
    // requested session's slot occupied until its existing lifecycle path
    // observes the real process exit and the owner calls release(_:).
    return reclaimable.map(\.lease)
  }

  public func snapshot() -> TatwoRuntimeGovernorSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return TatwoRuntimeGovernorSnapshot(
      tier: tier,
      activeLeases: active.values.map(\.lease).sorted {
        $0.id.uuidString < $1.id.uuidString
      },
      queuedRequestIDs: queue.map(\.requestID))
  }

  private func cancelQueuedRequest(_ requestID: UUID) {
    lock.lock()
    guard let index = queue.firstIndex(where: { $0.requestID == requestID }) else {
      lock.unlock()
      return
    }
    let pending = queue.remove(at: index)
    lock.unlock()
    pending.continuation.resume(throwing: TatwoRuntimeGovernorError.cancelled)
  }

  private func drainFIFOIfPossibleLocked() -> [(PendingEntry, TatwoRuntimeLease)] {
    var admissions: [(PendingEntry, TatwoRuntimeLease)] = []
    while active.count < tier.concurrentRuntimeLimit, !queue.isEmpty {
      let pending = queue.removeFirst()
      let lease = TatwoRuntimeLease(
        id: pending.requestID,
        kind: pending.kind)
      active[lease.id] = ActiveEntry(
        lease: lease,
        activeTurnCount: 1,
        lastActiveAt: now(),
        gentleTermination: nil)
      admissions.append((pending, lease))
    }
    return admissions
  }

  private func resume(
    _ admissions: [(PendingEntry, TatwoRuntimeLease)]
  ) {
    for (pending, lease) in admissions {
      pending.continuation.resume(returning: lease)
    }
  }

  /// Re-arms one production timer at the earliest idle-session deadline.
  /// Tests keep this disabled and call `reclaimIdlePersistentSessions()`
  /// directly with an injected clock, so no wall-clock sleep is required.
  private func rescheduleIdleReclamationLocked()
    -> DispatchSourceTimer?
  {
    guard automaticIdleReclamation,
      let idleInterval = tier.idleReclamationInterval
    else {
      let replaced = idleReclamationTimer
      idleReclamationTimer = nil
      return replaced
    }
    let current = now()
    let nextDeadline = active.values.compactMap { entry -> Date? in
      guard entry.lease.kind == .chatPersistentSession,
        entry.activeTurnCount == 0
      else {
        return nil
      }
      return entry.lastActiveAt.addingTimeInterval(idleInterval)
    }.min()
    guard let nextDeadline else {
      let replaced = idleReclamationTimer
      idleReclamationTimer = nil
      return replaced
    }

    let replaced = idleReclamationTimer
    let timer = DispatchSource.makeTimerSource(queue: reclamationQueue)
    timer.schedule(
      deadline: .now()
        + max(0.01, nextDeadline.timeIntervalSince(current)))
    timer.setEventHandler { [weak self] in
      _ = self?.reclaimIdlePersistentSessions()
    }
    timer.activate()
    idleReclamationTimer = timer
    return replaced
  }
}

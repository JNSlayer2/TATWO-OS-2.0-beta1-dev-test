import Foundation

public enum TatwoGoalStoreLockKind: String, Codable, Sendable, Equatable {
  case lifecycle
  case global
  case record
  case lifecycleBootstrap
}

public enum TatwoGoalStoreLockOperationMode:
  String, Codable, Sendable, Equatable
{
  case standard
  case globalOnly
  case lifecycleBootstrap
}

public enum TatwoGoalStoreLockOperationPhase:
  String, Codable, Sendable, Equatable
{
  case open
  case closing
  case closed
  case poisoned
}

public enum TatwoGoalStoreLockOrderError:
  Error, LocalizedError, Sendable, Equatable
{
  case missingOperationContext(requested: TatwoGoalStoreLockKind)
  case operationAlreadyActive
  case operationNotOpen(phase: TatwoGoalStoreLockOperationPhase)
  case operationPoisoned
  case wrongOperationState
  case wrongOperation(expected: UUID, actual: UUID)
  case staleGeneration(expected: UInt64, actual: UInt64)
  case unsupportedReentry(kind: TatwoGoalStoreLockKind)
  case outOfOrder(
    requested: TatwoGoalStoreLockKind,
    held: [TatwoGoalStoreLockKind])
  case parentLeaseReleased(kind: TatwoGoalStoreLockKind)
  case parentAlreadyHasActiveChild(parent: TatwoGoalStoreLockKind?)
  case secondRecordLock(existingRecordID: String, requestedRecordID: String)
  case bootstrapNotAllowed(mode: TatwoGoalStoreLockOperationMode)
  case bootstrapRequiresHeldGlobal(held: [TatwoGoalStoreLockKind])
  case nonLIFORelease(
    expected: TatwoGoalStoreLockKind?,
    attempted: TatwoGoalStoreLockKind)
  case doubleRelease(kind: TatwoGoalStoreLockKind)
  case releaseTokenMismatch(kind: TatwoGoalStoreLockKind)
  case parentLeaseMismatch(kind: TatwoGoalStoreLockKind)
  case operationClosedWithActiveLeases(count: Int)

  public var errorDescription: String? {
    switch self {
    case .missingOperationContext(let requested):
      return "Goal-store lock \(requested.rawValue) requires an operation context"
    case .operationAlreadyActive:
      return "A Goal-store lock operation context is already active"
    case .operationNotOpen(let phase):
      return "Goal-store lock operation is \(phase.rawValue), not open"
    case .operationPoisoned:
      return "Goal-store lock operation is poisoned"
    case .wrongOperationState:
      return "Goal-store cursor belongs to a different operation state"
    case let .wrongOperation(expected, actual):
      return "Wrong Goal-store operation \(actual); expected \(expected)"
    case let .staleGeneration(expected, actual):
      return
        "Stale Goal-store operation generation \(actual); expected \(expected)"
    case .unsupportedReentry(let kind):
      return "Goal-store lock \(kind.rawValue) does not support re-entry"
    case let .outOfOrder(requested, held):
      return
        "Goal-store lock \(requested.rawValue) is out of order after "
        + held.map(\.rawValue).joined(separator: ",")
    case .parentLeaseReleased(let kind):
      return "Parent Goal-store \(kind.rawValue) lease is no longer active"
    case .parentAlreadyHasActiveChild(let parent):
      return
        "Goal-store parent \(parent?.rawValue ?? "root") already has an active child"
    case let .secondRecordLock(existingRecordID, requestedRecordID):
      return
        "A second Goal-store record lock is forbidden: first "
        + "\(existingRecordID), requested \(requestedRecordID)"
    case .bootstrapNotAllowed(let mode):
      return "Lifecycle bootstrap is not allowed in \(mode.rawValue) mode"
    case .bootstrapRequiresHeldGlobal(let held):
      return
        "Lifecycle bootstrap requires exactly one held global lock, found "
        + held.map(\.rawValue).joined(separator: ",")
    case let .nonLIFORelease(expected, attempted):
      return
        "Goal-store lock release must be LIFO: expected "
        + "\(expected?.rawValue ?? "none"), attempted \(attempted.rawValue)"
    case .doubleRelease(let kind):
      return "Goal-store \(kind.rawValue) lease was already released"
    case .releaseTokenMismatch(let kind):
      return "Goal-store lock release token mismatch for \(kind.rawValue)"
    case .parentLeaseMismatch(let kind):
      return "Goal-store lock parent mismatch for \(kind.rawValue)"
    case .operationClosedWithActiveLeases(let count):
      return "Goal-store operation closed with \(count) active lease(s)"
    }
  }
}

/// Preserves a primary user-body failure together with a secondary typed
/// lock-scope cleanup failure. A cleanup-only failure is still thrown directly
/// as `TatwoGoalStoreLockOrderError`.
///
/// This type is intentionally non-Sendable because preserving the exact
/// original body error permits arbitrary `Error` payloads.
public struct TatwoGoalStoreLockScopeCompositeError:
  Error, LocalizedError
{
  public let bodyError: any Error
  public let releaseError: TatwoGoalStoreLockOrderError

  public init(
    bodyError: any Error,
    releaseError: TatwoGoalStoreLockOrderError
  ) {
    self.bodyError = bodyError
    self.releaseError = releaseError
  }

  public var errorDescription: String? {
    "Goal-store scope body failed with \(bodyError); "
      + "cleanup also failed with \(releaseError.localizedDescription)"
  }
}

/// A runtime order fence backed by one shared authority per operation.
///
/// The TaskLocal value is an immutable lexical cursor. Every inherited cursor
/// references the same mutex-protected OperationState, so sibling tasks cannot
/// fork independent authority. No state mutex is held while a user body,
/// callback, file operation, `flock(2)`, or suspension point executes.
public enum TatwoGoalStoreLockOrder {
  struct LeaseReference: Sendable, Equatable {
    let token: UUID
    let parentToken: UUID?
    let kind: TatwoGoalStoreLockKind
    let recordID: String?
  }

  struct Cursor: Sendable {
    let state: OperationState
    let operationID: UUID
    let generation: UInt64
    let cursorID: UUID
    let path: [LeaseReference]

    var heldKinds: [TatwoGoalStoreLockKind] {
      path.map(\.kind)
    }
  }

  struct DebugIdentity: Sendable, Equatable {
    let stateID: ObjectIdentifier
    let operationID: UUID
    let generation: UInt64
    let cursorID: UUID
    let heldKinds: [TatwoGoalStoreLockKind]
  }

  struct DebugSnapshot: Sendable, Equatable {
    let stateID: ObjectIdentifier
    let phase: TatwoGoalStoreLockOperationPhase
    let generation: UInt64
    let activeLeaseCount: Int
    let recordLeaseEverIssued: Bool
  }

  final class OperationState: @unchecked Sendable {
    struct LeaseNode {
      let token: UUID
      let parentToken: UUID?
      let kind: TatwoGoalStoreLockKind
      let recordID: String?
      var childToken: UUID?
    }

    let operationID: UUID
    let mode: TatwoGoalStoreLockOperationMode

    private let mutex = NSLock()
    private var phase: TatwoGoalStoreLockOperationPhase = .open
    private var generation: UInt64 = 1
    private var rootChildToken: UUID?
    private var leases: [UUID: LeaseNode] = [:]
    private var retiredTokens: Set<UUID> = []
    private var recordLeaseEverIssued = false
    private var firstRecordID: String?

    init(
      operationID: UUID = UUID(),
      mode: TatwoGoalStoreLockOperationMode
    ) {
      self.operationID = operationID
      self.mode = mode
    }

    func rootCursor() -> Cursor {
      critical {
        Cursor(
          state: self,
          operationID: operationID,
          generation: generation,
          cursorID: UUID(),
          path: [])
      }
    }

    func acquire(
      from cursor: Cursor,
      kind: TatwoGoalStoreLockKind,
      recordID: String? = nil
    ) throws -> Cursor {
      try critical {
        try validateCursorLocked(cursor, requireOpen: true)
        let held = cursor.heldKinds

        if kind == .record, recordLeaseEverIssued {
          throw TatwoGoalStoreLockOrderError.secondRecordLock(
            existingRecordID: firstRecordID ?? "<unknown>",
            requestedRecordID: recordID ?? "<unknown>")
        }
        if held.contains(kind) {
          throw TatwoGoalStoreLockOrderError.unsupportedReentry(kind: kind)
        }
        try validateRankLocked(kind, held: held)

        let parentToken = cursor.path.last?.token
        if let parentToken {
          guard var parent = leases[parentToken] else {
            throw TatwoGoalStoreLockOrderError.parentLeaseReleased(
              kind: cursor.path.last?.kind ?? kind)
          }
          guard parent.childToken == nil else {
            throw TatwoGoalStoreLockOrderError.parentAlreadyHasActiveChild(
              parent: parent.kind)
          }
          let token = UUID()
          parent.childToken = token
          leases[parentToken] = parent
          leases[token] = LeaseNode(
            token: token,
            parentToken: parentToken,
            kind: kind,
            recordID: recordID,
            childToken: nil)
          if kind == .record {
            recordLeaseEverIssued = true
            firstRecordID = recordID ?? "<unknown>"
          }
          return childCursor(
            from: cursor,
            token: token,
            parentToken: parentToken,
            kind: kind,
            recordID: recordID)
        }

        guard rootChildToken == nil else {
          throw TatwoGoalStoreLockOrderError.parentAlreadyHasActiveChild(
            parent: nil)
        }
        let token = UUID()
        rootChildToken = token
        leases[token] = LeaseNode(
          token: token,
          parentToken: nil,
          kind: kind,
          recordID: recordID,
          childToken: nil)
        if kind == .record {
          recordLeaseEverIssued = true
          firstRecordID = recordID ?? "<unknown>"
        }
        return childCursor(
          from: cursor,
          token: token,
          parentToken: nil,
          kind: kind,
          recordID: recordID)
      }
    }

    func release(_ cursor: Cursor) throws {
      try critical {
        try validateIdentityLocked(cursor)
        guard phase == .open else {
          if phase == .poisoned {
            throw TatwoGoalStoreLockOrderError.operationPoisoned
          }
          throw TatwoGoalStoreLockOrderError.operationNotOpen(phase: phase)
        }
        guard let reference = cursor.path.last else {
          throw TatwoGoalStoreLockOrderError.releaseTokenMismatch(
            kind: .lifecycle)
        }
        guard var node = leases[reference.token] else {
          if retiredTokens.contains(reference.token) {
            throw TatwoGoalStoreLockOrderError.doubleRelease(
              kind: reference.kind)
          }
          throw TatwoGoalStoreLockOrderError.releaseTokenMismatch(
            kind: reference.kind)
        }
        guard node.kind == reference.kind,
          node.token == reference.token
        else {
          throw TatwoGoalStoreLockOrderError.releaseTokenMismatch(
            kind: reference.kind)
        }
        guard node.parentToken == reference.parentToken else {
          throw TatwoGoalStoreLockOrderError.parentLeaseMismatch(
            kind: reference.kind)
        }
        if let childToken = node.childToken,
          let child = leases[childToken]
        {
          poisonAndInvalidateLocked()
          throw TatwoGoalStoreLockOrderError.nonLIFORelease(
            expected: child.kind,
            attempted: node.kind)
        }

        if let parentToken = node.parentToken {
          guard var parent = leases[parentToken],
            parent.childToken == node.token
          else {
            throw TatwoGoalStoreLockOrderError.parentLeaseMismatch(
              kind: node.kind)
          }
          parent.childToken = nil
          leases[parentToken] = parent
        } else {
          guard rootChildToken == node.token else {
            throw TatwoGoalStoreLockOrderError.parentLeaseMismatch(
              kind: node.kind)
          }
          rootChildToken = nil
        }
        node.childToken = nil
        leases.removeValue(forKey: node.token)
        retiredTokens.insert(node.token)
      }
    }

    func finishRootAfterSuccess(_ root: Cursor) throws {
      try critical {
        try validateRootIdentityLocked(root)
        switch phase {
        case .open:
          phase = .closing
          let activeCount = leases.count
          guard activeCount == 0, rootChildToken == nil else {
            poisonAndInvalidateLocked()
            throw TatwoGoalStoreLockOrderError
              .operationClosedWithActiveLeases(count: activeCount)
          }
          phase = .closed
          generation &+= 1
        case .poisoned:
          throw TatwoGoalStoreLockOrderError.operationPoisoned
        case .closing, .closed:
          throw TatwoGoalStoreLockOrderError.operationNotOpen(phase: phase)
        }
      }
    }

    func finishRootAfterFailure(_ root: Cursor) throws {
      try critical {
        try validateRootIdentityLocked(root)
        switch phase {
        case .open, .closing:
          if leases.isEmpty, rootChildToken == nil {
            phase = .closed
            generation &+= 1
          } else {
            poisonAndInvalidateLocked()
          }
        case .closed, .poisoned:
          break
        }
      }
    }

    func heldKinds(for cursor: Cursor) -> [TatwoGoalStoreLockKind] {
      critical {
        guard (try? validateCursorLocked(cursor, requireOpen: true)) != nil
        else {
          return []
        }
        return cursor.heldKinds
      }
    }

    func operationMode(for cursor: Cursor) -> TatwoGoalStoreLockOperationMode? {
      critical {
        guard (try? validateCursorLocked(cursor, requireOpen: true)) != nil
        else {
          return nil
        }
        return mode
      }
    }

    func debugSnapshot() -> DebugSnapshot {
      critical {
        DebugSnapshot(
          stateID: ObjectIdentifier(self),
          phase: phase,
          generation: generation,
          activeLeaseCount: leases.count,
          recordLeaseEverIssued: recordLeaseEverIssued)
      }
    }

    private func childCursor(
      from cursor: Cursor,
      token: UUID,
      parentToken: UUID?,
      kind: TatwoGoalStoreLockKind,
      recordID: String?
    ) -> Cursor {
      Cursor(
        state: self,
        operationID: operationID,
        generation: generation,
        cursorID: UUID(),
        path: cursor.path + [
          LeaseReference(
            token: token,
            parentToken: parentToken,
            kind: kind,
            recordID: recordID)
        ])
    }

    private func validateRankLocked(
      _ kind: TatwoGoalStoreLockKind,
      held: [TatwoGoalStoreLockKind]
    ) throws {
      switch kind {
      case .lifecycle:
        guard mode == .standard, held.isEmpty else {
          throw TatwoGoalStoreLockOrderError.outOfOrder(
            requested: kind, held: held)
        }
      case .global:
        switch mode {
        case .standard:
          guard held == [.lifecycle] else {
            throw TatwoGoalStoreLockOrderError.outOfOrder(
              requested: kind, held: held)
          }
        case .globalOnly, .lifecycleBootstrap:
          guard held.isEmpty else {
            throw TatwoGoalStoreLockOrderError.outOfOrder(
              requested: kind, held: held)
          }
        }
      case .record:
        guard mode == .standard, held == [.lifecycle, .global] else {
          throw TatwoGoalStoreLockOrderError.outOfOrder(
            requested: kind, held: held)
        }
      case .lifecycleBootstrap:
        guard mode == .lifecycleBootstrap else {
          throw TatwoGoalStoreLockOrderError.bootstrapNotAllowed(mode: mode)
        }
        guard held == [.global] else {
          throw TatwoGoalStoreLockOrderError.bootstrapRequiresHeldGlobal(
            held: held)
        }
      }
    }

    private func validateCursorLocked(
      _ cursor: Cursor,
      requireOpen: Bool
    ) throws {
      try validateIdentityLocked(cursor)
      if requireOpen {
        guard phase == .open else {
          if phase == .poisoned {
            throw TatwoGoalStoreLockOrderError.operationPoisoned
          }
          throw TatwoGoalStoreLockOrderError.operationNotOpen(phase: phase)
        }
      }

      var expectedParent: UUID?
      for reference in cursor.path {
        guard let node = leases[reference.token] else {
          throw TatwoGoalStoreLockOrderError.parentLeaseReleased(
            kind: reference.kind)
        }
        guard node.token == reference.token,
          node.kind == reference.kind
        else {
          throw TatwoGoalStoreLockOrderError.releaseTokenMismatch(
            kind: reference.kind)
        }
        guard node.parentToken == reference.parentToken,
          reference.parentToken == expectedParent
        else {
          throw TatwoGoalStoreLockOrderError.parentLeaseMismatch(
            kind: reference.kind)
        }
        expectedParent = reference.token
      }
    }

    private func validateIdentityLocked(_ cursor: Cursor) throws {
      guard cursor.state === self else {
        throw TatwoGoalStoreLockOrderError.wrongOperationState
      }
      guard cursor.operationID == operationID else {
        throw TatwoGoalStoreLockOrderError.wrongOperation(
          expected: operationID, actual: cursor.operationID)
      }
      guard cursor.generation == generation else {
        throw TatwoGoalStoreLockOrderError.staleGeneration(
          expected: generation, actual: cursor.generation)
      }
    }

    private func validateRootIdentityLocked(_ root: Cursor) throws {
      try validateIdentityLocked(root)
      guard root.path.isEmpty else {
        throw TatwoGoalStoreLockOrderError.parentLeaseMismatch(
          kind: root.path.last?.kind ?? .lifecycle)
      }
    }

    private func poisonAndInvalidateLocked() {
      phase = .poisoned
      generation &+= 1
      retiredTokens.formUnion(leases.keys)
      leases.removeAll(keepingCapacity: false)
      rootChildToken = nil
    }

    private func critical<T>(_ body: () throws -> T) rethrows -> T {
      mutex.lock()
      defer { mutex.unlock() }
      return try body()
    }
  }

  @TaskLocal private static var cursor: Cursor?

  public static var heldKinds: [TatwoGoalStoreLockKind] {
    guard let cursor else { return [] }
    return cursor.state.heldKinds(for: cursor)
  }

  public static var activeOperationMode: TatwoGoalStoreLockOperationMode? {
    guard let cursor else { return nil }
    return cursor.state.operationMode(for: cursor)
  }

  static var debugIdentity: DebugIdentity? {
    guard let cursor else { return nil }
    return DebugIdentity(
      stateID: ObjectIdentifier(cursor.state),
      operationID: cursor.operationID,
      generation: cursor.generation,
      cursorID: cursor.cursorID,
      heldKinds: cursor.state.heldKinds(for: cursor))
  }

  static var currentStateForTesting: OperationState? {
    cursor?.state
  }

  public static func withOperation<T>(
    mode: TatwoGoalStoreLockOperationMode = .standard,
    _ body: () throws -> T
  ) throws -> T {
    guard cursor == nil else {
      throw TatwoGoalStoreLockOrderError.operationAlreadyActive
    }
    let state = OperationState(mode: mode)
    let root = state.rootCursor()
    return try $cursor.withValue(root) {
      do {
        let result = try body()
        try state.finishRootAfterSuccess(root)
        return result
      } catch {
        try? state.finishRootAfterFailure(root)
        throw error
      }
    }
  }

  public static func withOperation<T>(
    mode: TatwoGoalStoreLockOperationMode = .standard,
    _ body: () async throws -> T
  ) async throws -> T {
    guard cursor == nil else {
      throw TatwoGoalStoreLockOrderError.operationAlreadyActive
    }
    let state = OperationState(mode: mode)
    let root = state.rootCursor()
    return try await $cursor.withValue(root) {
      do {
        let result = try await body()
        try state.finishRootAfterSuccess(root)
        return result
      } catch {
        try? state.finishRootAfterFailure(root)
        throw error
      }
    }
  }

  public static func withLifecycleScope<T>(
    _ body: () throws -> T
  ) throws -> T {
    try withScope(.lifecycle, body)
  }

  public static func withLifecycleScope<T>(
    _ body: () async throws -> T
  ) async throws -> T {
    try await withScope(.lifecycle, body)
  }

  public static func withGlobalScope<T>(
    _ body: () throws -> T
  ) throws -> T {
    try withScope(.global, body)
  }

  public static func withGlobalScope<T>(
    _ body: () async throws -> T
  ) async throws -> T {
    try await withScope(.global, body)
  }

  public static func withRecordScope<T>(
    recordID: String,
    _ body: () throws -> T
  ) throws -> T {
    try withScope(.record, recordID: recordID, body)
  }

  public static func withRecordScope<T>(
    recordID: String,
    _ body: () async throws -> T
  ) async throws -> T {
    try await withScope(.record, recordID: recordID, body)
  }

  static func withLifecycleBootstrapScope<T>(
    _ body: () throws -> T
  ) throws -> T {
    try withScope(.lifecycleBootstrap, body)
  }

  static func withOperationIfNeeded<T>(
    mode: TatwoGoalStoreLockOperationMode,
    _ body: () throws -> T
  ) throws -> T {
    if cursor == nil {
      return try withOperation(mode: mode, body)
    }
    return try body()
  }

  private static func withScope<T>(
    _ kind: TatwoGoalStoreLockKind,
    recordID: String? = nil,
    _ body: () throws -> T
  ) throws -> T {
    guard let parent = cursor else {
      throw TatwoGoalStoreLockOrderError.missingOperationContext(
        requested: kind)
    }
    let child = try parent.state.acquire(
      from: parent, kind: kind, recordID: recordID)
    return try $cursor.withValue(child) {
      let bodyResult: Result<T, Error>
      do {
        bodyResult = .success(try body())
      } catch {
        bodyResult = .failure(error)
      }
      switch (bodyResult, releaseResult(child, from: parent.state)) {
      case let (.success(value), .success):
        return value
      case let (.success, .failure(releaseError)):
        throw releaseError
      case let (.failure(bodyError), .success):
        throw bodyError
      case let (.failure(bodyError), .failure(releaseError)):
        throw TatwoGoalStoreLockScopeCompositeError(
          bodyError: bodyError,
          releaseError: releaseError)
      }
    }
  }

  private static func withScope<T>(
    _ kind: TatwoGoalStoreLockKind,
    recordID: String? = nil,
    _ body: () async throws -> T
  ) async throws -> T {
    guard let parent = cursor else {
      throw TatwoGoalStoreLockOrderError.missingOperationContext(
        requested: kind)
    }
    let child = try parent.state.acquire(
      from: parent, kind: kind, recordID: recordID)
    return try await $cursor.withValue(child) {
      let bodyResult: Result<T, Error>
      do {
        bodyResult = .success(try await body())
      } catch {
        bodyResult = .failure(error)
      }
      switch (bodyResult, releaseResult(child, from: parent.state)) {
      case let (.success(value), .success):
        return value
      case let (.success, .failure(releaseError)):
        throw releaseError
      case let (.failure(bodyError), .success):
        throw bodyError
      case let (.failure(bodyError), .failure(releaseError)):
        throw TatwoGoalStoreLockScopeCompositeError(
          bodyError: bodyError,
          releaseError: releaseError)
      }
    }
  }

  private static func releaseResult(
    _ child: Cursor,
    from state: OperationState
  ) -> Result<Void, TatwoGoalStoreLockOrderError> {
    do {
      try state.release(child)
      return .success(())
    } catch let error as TatwoGoalStoreLockOrderError {
      return .failure(error)
    } catch {
      preconditionFailure(
        "OperationState.release emitted an unexpected error: \(error)")
    }
  }
}

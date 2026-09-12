import Foundation

/// Produces a value-only plan for aligning live terminals with a CLI session book.
public enum TatwoNativeTerminalPoolReconciler {
  public struct TerminalRequest: Sendable, Equatable, Hashable {
    public let id: UUID
    public let engine: TatwoNativeCLISessionBook.Engine

    public init(id: UUID, engine: TatwoNativeCLISessionBook.Engine) {
      self.id = id
      self.engine = engine
    }
  }

  public struct LiveTerminal: Sendable, Equatable, Hashable {
    public let id: UUID
    public let engine: TatwoNativeCLISessionBook.Engine

    public init(id: UUID, engine: TatwoNativeCLISessionBook.Engine) {
      self.id = id
      self.engine = engine
    }
  }

  public struct Plan: Sendable, Equatable {
    public let toSpawn: [TerminalRequest]
    public let toTerminate: [UUID]
    public let toRespawn: [TerminalRequest]
    public let activeToFocus: UUID?

    public init(
      toSpawn: [TerminalRequest],
      toTerminate: [UUID],
      toRespawn: [TerminalRequest],
      activeToFocus: UUID?
    ) {
      self.toSpawn = toSpawn
      self.toTerminate = toTerminate
      self.toRespawn = toRespawn
      self.activeToFocus = activeToFocus
    }
  }

  public static func reconcile(
    book: TatwoNativeCLISessionBook,
    liveTerminals: [LiveTerminal]
  ) -> Plan {
    reconcile(
      sessions: book.sessions,
      activeSessionID: book.activeSessionID,
      liveTerminals: liveTerminals)
  }

  public static func reconcile(
    sessions: [TatwoNativeCLISessionBook.Session],
    activeSessionID: UUID?,
    liveTerminals: [LiveTerminal]
  ) -> Plan {
    var desiredOrder: [TerminalRequest] = []
    var desiredByID: [UUID: TatwoNativeCLISessionBook.Engine] = [:]
    for session in sessions where desiredByID[session.id] == nil {
      desiredByID[session.id] = session.engine
      desiredOrder.append(.init(id: session.id, engine: session.engine))
    }

    var liveByID: [UUID: TatwoNativeCLISessionBook.Engine] = [:]
    for terminal in liveTerminals where liveByID[terminal.id] == nil {
      liveByID[terminal.id] = terminal.engine
    }

    let toSpawn = desiredOrder.filter { liveByID[$0.id] == nil }
    let toRespawn = desiredOrder.filter {
      guard let liveEngine = liveByID[$0.id] else { return false }
      return liveEngine != $0.engine
    }
    let toTerminate = liveByID.keys
      .filter { desiredByID[$0] == nil }
      .sorted { $0.uuidString < $1.uuidString }
    let activeToFocus = activeSessionID.flatMap {
      desiredByID[$0] == nil ? nil : $0
    }

    return Plan(
      toSpawn: toSpawn,
      toTerminate: toTerminate,
      toRespawn: toRespawn,
      activeToFocus: activeToFocus)
  }

  /// ID-only reconciliation assumes every matching live terminal already uses
  /// the desired engine. Use the engine-aware overload to detect respawns.
  public static func reconcile(
    book: TatwoNativeCLISessionBook,
    existingTerminalIDs: Set<UUID>
  ) -> Plan {
    var desiredEngines: [UUID: TatwoNativeCLISessionBook.Engine] = [:]
    for session in book.sessions where desiredEngines[session.id] == nil {
      desiredEngines[session.id] = session.engine
    }
    let liveTerminals = existingTerminalIDs.map {
      LiveTerminal(id: $0, engine: desiredEngines[$0] ?? .generic)
    }
    return reconcile(
      sessions: book.sessions,
      activeSessionID: book.activeSessionID,
      liveTerminals: liveTerminals)
  }
}

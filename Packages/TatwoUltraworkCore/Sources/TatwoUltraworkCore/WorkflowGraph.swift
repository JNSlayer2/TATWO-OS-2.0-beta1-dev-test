import Foundation

// MARK: - WorkflowGraph V0 (simulation only)
//
// Authority: the graph proposes; Loop Governor + contract gate dispose.
// This module must remain free of production dispatch/registry/channel/trust types.
// See docs/protocol/WORKFLOW_GRAPH_DESIGN_V0.md.

// MARK: Node / edge schema

public enum WorkflowGraphNodeKindV1: String, Codable, Sendable, Equatable, CaseIterable {
  case task
  case gate
  case join
  case terminal
}

/// What a ready node would *ask* for. Not a dispatch and not authorisation.
public struct WorkflowGraphProposalV1: Codable, Sendable, Equatable {
  /// Human-readable intent the Loop Governor may accept or reject.
  public let intent: String

  public init(intent: String) {
    self.intent = intent
  }
}

public struct WorkflowGraphNodeV1: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let kind: WorkflowGraphNodeKindV1
  public let title: String
  public let goalCriterionRef: String?
  public let proposal: WorkflowGraphProposalV1?
  public let requiredReceipts: [String]
  public let humanGate: Bool

  public init(
    id: String,
    kind: WorkflowGraphNodeKindV1,
    title: String,
    goalCriterionRef: String? = nil,
    proposal: WorkflowGraphProposalV1? = nil,
    requiredReceipts: [String] = [],
    humanGate: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.goalCriterionRef = goalCriterionRef
    self.proposal = proposal
    self.requiredReceipts = requiredReceipts
    self.humanGate = humanGate
  }
}

public enum WorkflowGraphEdgeConditionV1: Codable, Sendable, Equatable {
  /// Predecessor reached any terminal state.
  case afterCompletion
  /// Predecessor completed without failure.
  case afterSuccess
  /// Recovery lane after predecessor failure.
  case onFailure
  /// A named receipt exists and has already been verified.
  case onReceipt(String)
}

public struct WorkflowGraphEdgeV1: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let from: String
  public let to: String
  public let condition: WorkflowGraphEdgeConditionV1

  public init(
    id: String,
    from: String,
    to: String,
    condition: WorkflowGraphEdgeConditionV1
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.condition = condition
  }
}

// MARK: Recorded facts only (no arbitrary node output)

/// Lifecycle facts that may drive edge conditions.
/// Conditions may not read free-form node output — only these verified terminals
/// and named verified receipts (see design § Conditional branches).
public enum WorkflowGraphNodeLifecycleV1: String, Codable, Sendable, Equatable {
  case notStarted
  case running
  /// Governor rejected a proposal; terminal for the graph, not a failure branch.
  case blocked
  case succeeded
  case failed

  public var isTerminal: Bool {
    switch self {
    case .blocked, .succeeded, .failed:
      return true
    case .notStarted, .running:
      return false
    }
  }

  public var isSuccess: Bool { self == .succeeded }
  public var isFailure: Bool { self == .failed }
}

/// Snapshot of already-recorded, verified facts. Pure input to `ready`.
public struct WorkflowGraphRecordedStateV1: Codable, Sendable, Equatable {
  /// Must match the graph revision or evaluation refuses (stale).
  public let goalHash: String
  public let planHash: String
  /// Node id → recorded lifecycle. Absent ids are treated as `.notStarted`.
  public let nodeStatuses: [String: WorkflowGraphNodeLifecycleV1]
  /// Node ids whose human gate has been passed by a person.
  public let humanGatesPassed: Set<String>
  /// Receipt names that exist and already passed their own verification.
  public let verifiedReceipts: Set<String>

  public init(
    goalHash: String,
    planHash: String,
    nodeStatuses: [String: WorkflowGraphNodeLifecycleV1] = [:],
    humanGatesPassed: Set<String> = [],
    verifiedReceipts: Set<String> = []
  ) {
    self.goalHash = goalHash
    self.planHash = planHash
    self.nodeStatuses = nodeStatuses
    self.humanGatesPassed = humanGatesPassed
    self.verifiedReceipts = verifiedReceipts
  }

  public func status(of nodeID: String) -> WorkflowGraphNodeLifecycleV1 {
    nodeStatuses[nodeID] ?? .notStarted
  }
}

// MARK: Graph revision + load (fail closed)

public enum WorkflowGraphLoadErrorV1: Error, LocalizedError, Sendable, Equatable {
  case duplicateNodeID(String)
  case danglingEdge(edgeID: String, endpoint: String, nodeID: String)
  case cycleDetected
  case emptyGoalHash
  case emptyPlanHash

  public var errorDescription: String? {
    switch self {
    case .duplicateNodeID(let id):
      return "WorkflowGraph load rejected: duplicate node id \(id)"
    case .danglingEdge(let edgeID, let endpoint, let nodeID):
      return "WorkflowGraph load rejected: edge \(edgeID) \(endpoint) points to missing node \(nodeID)"
    case .cycleDetected:
      return "WorkflowGraph load rejected: cycle (not topologically sortable)"
    case .emptyGoalHash:
      return "WorkflowGraph load rejected: goalHash is required"
    case .emptyPlanHash:
      return "WorkflowGraph load rejected: planHash is required"
    }
  }
}

/// Bound graph revision. `goalHash` + `planHash` pin staleness (design § binding).
public struct WorkflowGraphRevisionV1: Codable, Sendable, Equatable {
  public let goalHash: String
  public let planHash: String
  public let nodes: [WorkflowGraphNodeV1]
  public let edges: [WorkflowGraphEdgeV1]

  public init(
    goalHash: String,
    planHash: String,
    nodes: [WorkflowGraphNodeV1],
    edges: [WorkflowGraphEdgeV1]
  ) {
    self.goalHash = goalHash
    self.planHash = planHash
    self.nodes = nodes
    self.edges = edges
  }
}

/// Validated, immutable graph after fail-closed load. Safe to schedule against.
public struct WorkflowGraphLoadedV1: Sendable, Equatable {
  public let revision: WorkflowGraphRevisionV1
  /// Stable node lookup.
  public let nodesByID: [String: WorkflowGraphNodeV1]
  /// Incoming edges keyed by destination node id (deterministic edge-id order).
  public let incomingByTo: [String: [WorkflowGraphEdgeV1]]
  /// Topological order of node ids (deterministic among valid graphs).
  public let topologicalOrder: [String]

  public var goalHash: String { revision.goalHash }
  public var planHash: String { revision.planHash }
  public var nodes: [WorkflowGraphNodeV1] { revision.nodes }
  public var edges: [WorkflowGraphEdgeV1] { revision.edges }
}

public enum WorkflowGraphLoaderV1 {
  /// Fail closed: duplicate ids, dangling edges, or cycles reject the revision.
  public static func load(_ revision: WorkflowGraphRevisionV1) throws -> WorkflowGraphLoadedV1 {
    let goalHash = revision.goalHash.trimmingCharacters(in: .whitespacesAndNewlines)
    let planHash = revision.planHash.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !goalHash.isEmpty else { throw WorkflowGraphLoadErrorV1.emptyGoalHash }
    guard !planHash.isEmpty else { throw WorkflowGraphLoadErrorV1.emptyPlanHash }

    var nodesByID: [String: WorkflowGraphNodeV1] = [:]
    nodesByID.reserveCapacity(revision.nodes.count)
    for node in revision.nodes {
      if nodesByID[node.id] != nil {
        throw WorkflowGraphLoadErrorV1.duplicateNodeID(node.id)
      }
      nodesByID[node.id] = node
    }

    for edge in revision.edges {
      if nodesByID[edge.from] == nil {
        throw WorkflowGraphLoadErrorV1.danglingEdge(
          edgeID: edge.id, endpoint: "from", nodeID: edge.from)
      }
      if nodesByID[edge.to] == nil {
        throw WorkflowGraphLoadErrorV1.danglingEdge(
          edgeID: edge.id, endpoint: "to", nodeID: edge.to)
      }
    }

    let topologicalOrder = try topologicalSort(nodes: revision.nodes, edges: revision.edges)

    var incomingByTo: [String: [WorkflowGraphEdgeV1]] = [:]
    for edge in revision.edges.sorted(by: { $0.id < $1.id }) {
      incomingByTo[edge.to, default: []].append(edge)
    }

    let normalized = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: revision.nodes,
      edges: revision.edges)
    return WorkflowGraphLoadedV1(
      revision: normalized,
      nodesByID: nodesByID,
      incomingByTo: incomingByTo,
      topologicalOrder: topologicalOrder)
  }

  /// Kahn topological sort; edges treated as from → to precedence.
  /// Tie-break: smallest node id first for determinism.
  private static func topologicalSort(
    nodes: [WorkflowGraphNodeV1],
    edges: [WorkflowGraphEdgeV1]
  ) throws -> [String] {
    var indegree: [String: Int] = [:]
    var adjacency: [String: [String]] = [:]
    for node in nodes {
      indegree[node.id] = 0
      adjacency[node.id] = []
    }
    for edge in edges {
      adjacency[edge.from, default: []].append(edge.to)
      indegree[edge.to, default: 0] += 1
    }
    for key in adjacency.keys {
      adjacency[key]?.sort()
    }

    var ready = indegree
      .filter { $0.value == 0 }
      .map(\.key)
      .sorted()
    var order: [String] = []
    order.reserveCapacity(nodes.count)

    while !ready.isEmpty {
      let next = ready.removeFirst()
      order.append(next)
      for neighbor in adjacency[next] ?? [] {
        let remaining = (indegree[neighbor] ?? 0) - 1
        indegree[neighbor] = remaining
        if remaining == 0 {
          ready.append(neighbor)
          ready.sort()
        }
      }
    }

    if order.count != nodes.count {
      throw WorkflowGraphLoadErrorV1.cycleDetected
    }
    return order
  }
}

// MARK: Pure ready-set scheduler (no side effects)

public enum WorkflowGraphStaleErrorV1: Error, LocalizedError, Sendable, Equatable {
  case goalHashMismatch(graph: String, state: String)
  case planHashMismatch(graph: String, state: String)

  public var errorDescription: String? {
    switch self {
    case .goalHashMismatch(let graph, let state):
      return "WorkflowGraph stale: goalHash graph=\(graph) state=\(state)"
    case .planHashMismatch(let graph, let state):
      return "WorkflowGraph stale: planHash graph=\(graph) state=\(state)"
    }
  }
}

/// A ready-node proposal emission. Not a dispatch record.
public struct WorkflowGraphReadyProposalV1: Codable, Sendable, Equatable, Identifiable {
  public var id: String { nodeID }
  public let nodeID: String
  public let kind: WorkflowGraphNodeKindV1
  public let title: String
  public let proposal: WorkflowGraphProposalV1?

  public init(node: WorkflowGraphNodeV1) {
    self.nodeID = node.id
    self.kind = node.kind
    self.title = node.title
    self.proposal = node.proposal
  }
}

public enum WorkflowGraphSchedulerV1 {
  /// Pure ready-set:
  /// `{ n | all incoming edges satisfied ∧ n not started ∧ (humanGate ⇒ gate passed) }`
  /// Deterministic: sorted by node id. Holds no lease/lock/claim. Writes nothing.
  public static func ready(
    graph: WorkflowGraphLoadedV1,
    state: WorkflowGraphRecordedStateV1
  ) -> [WorkflowGraphNodeV1] {
    graph.nodes
      .filter { node in
        isReady(node: node, graph: graph, state: state)
      }
      .sorted { $0.id < $1.id }
  }

  public static func readyProposals(
    graph: WorkflowGraphLoadedV1,
    state: WorkflowGraphRecordedStateV1
  ) -> [WorkflowGraphReadyProposalV1] {
    ready(graph: graph, state: state).map(WorkflowGraphReadyProposalV1.init(node:))
  }

  public static func ensureNotStale(
    graph: WorkflowGraphLoadedV1,
    state: WorkflowGraphRecordedStateV1
  ) throws {
    if state.goalHash != graph.goalHash {
      throw WorkflowGraphStaleErrorV1.goalHashMismatch(
        graph: graph.goalHash, state: state.goalHash)
    }
    if state.planHash != graph.planHash {
      throw WorkflowGraphStaleErrorV1.planHashMismatch(
        graph: graph.planHash, state: state.planHash)
    }
  }

  private static func isReady(
    node: WorkflowGraphNodeV1,
    graph: WorkflowGraphLoadedV1,
    state: WorkflowGraphRecordedStateV1
  ) -> Bool {
    guard state.status(of: node.id) == .notStarted else { return false }
    if node.humanGate, !state.humanGatesPassed.contains(node.id) {
      return false
    }
    let incoming = graph.incomingByTo[node.id] ?? []
    for edge in incoming {
      guard edgeConditionSatisfied(edge.condition, from: edge.from, state: state) else {
        return false
      }
    }
    return true
  }

  /// Conditions read only recorded lifecycle + verified receipt names.
  /// Never inspects free-form node output (design § Conditional branches).
  private static func edgeConditionSatisfied(
    _ condition: WorkflowGraphEdgeConditionV1,
    from predecessorID: String,
    state: WorkflowGraphRecordedStateV1
  ) -> Bool {
    let predecessor = state.status(of: predecessorID)
    switch condition {
    case .afterCompletion:
      return predecessor.isTerminal
    case .afterSuccess:
      return predecessor.isSuccess
    case .onFailure:
      return predecessor.isFailure
    case .onReceipt(let name):
      return state.verifiedReceipts.contains(name)
    }
  }
}

// MARK: Simulation-only structural isolation

/// Empty capability product. Exists so the simulator's type surface can only
/// carry "no dispatch" — there is no field slot for registry/channel/trust.
public struct WorkflowGraphNoDispatchCapabilityV1: Sendable, Equatable {
  public init() {}
}

/// Simulation-only runner. API surface:
/// - accepts a loaded graph + recorded state snapshot
/// - returns proposal sequence
/// - has **no** dispatch, channel, registry, or trust-store parameters or fields
///
/// Constructing this type with live production objects is not expressible in the
/// type system (no such initializer) — failure is compile-time, not a runtime flag.
public struct WorkflowGraphSimulatorV1: Sendable {
  private let graph: WorkflowGraphLoadedV1
  /// Structural: the only capability this type may hold is the empty product.
  private let capability: WorkflowGraphNoDispatchCapabilityV1

  public init(graph: WorkflowGraphLoadedV1) {
    self.graph = graph
    self.capability = WorkflowGraphNoDispatchCapabilityV1()
  }

  /// Deterministic proposal sequence for the current recorded state.
  /// Throws if the snapshot is stale relative to the bound graph revision.
  public func readyProposals(
    state: WorkflowGraphRecordedStateV1
  ) throws -> [WorkflowGraphReadyProposalV1] {
    try WorkflowGraphSchedulerV1.ensureNotStale(graph: graph, state: state)
    return WorkflowGraphSchedulerV1.readyProposals(graph: graph, state: state)
  }

  /// Deterministic ready nodes (same filter as `readyProposals`).
  public func ready(
    state: WorkflowGraphRecordedStateV1
  ) throws -> [WorkflowGraphNodeV1] {
    try WorkflowGraphSchedulerV1.ensureNotStale(graph: graph, state: state)
    return WorkflowGraphSchedulerV1.ready(graph: graph, state: state)
  }

  /// Exposes only the empty capability — never a dispatch handle.
  public var noDispatchCapability: WorkflowGraphNoDispatchCapabilityV1 {
    capability
  }
}

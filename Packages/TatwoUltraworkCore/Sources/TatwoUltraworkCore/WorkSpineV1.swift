import CryptoKit
import Foundation

public struct TatwoWorkSpineV1: Codable, Sendable, Equatable {
  public let schema: String
  public let goalID: String
  public let contractID: String
  public let cycleEpoch: UInt64
  public let agentRunID: String?
  public let threadID: String
  public let loopsSessionID: String?
  public let contentSHA256: String

  public init(goalID: String, contractID: String, cycleEpoch: UInt64, agentRunID: String? = nil, threadID: String, loopsSessionID: String? = nil, contentSHA256: String = "") {
    self.schema = "WorkSpineV1"
    self.goalID = goalID
    self.contractID = contractID
    self.cycleEpoch = cycleEpoch
    self.agentRunID = agentRunID
    self.threadID = threadID
    self.loopsSessionID = loopsSessionID
    self.contentSHA256 = contentSHA256
  }

  public func canonicalContentSHA256() throws -> String {
    let payload = Payload(goalID: goalID, contractID: contractID, cycleEpoch: cycleEpoch, agentRunID: agentRunID, threadID: threadID, loopsSessionID: loopsSessionID)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return "sha256:" + SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate func sealed() throws -> Self {
    .init(goalID: goalID, contractID: contractID, cycleEpoch: cycleEpoch, agentRunID: agentRunID, threadID: threadID, loopsSessionID: loopsSessionID, contentSHA256: try canonicalContentSHA256())
  }

  private struct Payload: Codable { let goalID: String; let contractID: String; let cycleEpoch: UInt64; let agentRunID: String?; let threadID: String; let loopsSessionID: String? }
}

public enum TatwoWorkSpineErrorV1: Error, LocalizedError, Equatable {
  case invalidID(String), collision(String), corrupt(String), notFound(String), nonUnique(String), staleRevision(expected: UInt64, actual: UInt64), terminalGoal(GoalRunStatus), agentRunAlreadyBound(String)
  public var errorDescription: String? { "WorkSpineV1 fail-closed: \(self)" }
}

public struct TatwoWorkSpineStoreV1: Sendable {
  public let directoryURL: URL
  public var rowsDirectoryURL: URL { directoryURL.appendingPathComponent("work-spine-v1", isDirectory: true) }
  private var bindingsDirectoryURL: URL { directoryURL.appendingPathComponent("work-spine-v1-bindings", isDirectory: true) }
  public init(directoryURL: URL) { self.directoryURL = directoryURL }
  public func rowURL(goalID: String) -> URL { rowsDirectoryURL.appendingPathComponent("\(goalID).json") }

  @discardableResult public func create(_ proposed: TatwoWorkSpineV1) throws -> TatwoWorkSpineV1 {
    try validate(proposed)
    let row = try proposed.sealed(); let data = try Self.encode(row)
    try TatwoCreateOnlyFile.write(data, to: rowURL(goalID: row.goalID)) { throw TatwoWorkSpineErrorV1.collision(row.goalID) }
    return try readBase(goalID: row.goalID)
  }

  @discardableResult func ensureForGoalTransaction(_ proposed: TatwoWorkSpineV1) throws -> TatwoWorkSpineV1 {
    do { return try create(proposed) } catch TatwoWorkSpineErrorV1.collision {
      let existing = try readBase(goalID: proposed.goalID)
      guard existing == (try proposed.sealed()) else { throw TatwoWorkSpineErrorV1.collision(proposed.goalID) }
      return existing
    }
  }

  public func bindAgentRun(_ agentRunID: String, goal: TatwoStoredGoalRun, expectedGoalRevision: UInt64) throws -> TatwoWorkSpineV1 {
    guard goal.resolvedRevision == expectedGoalRevision else { throw TatwoWorkSpineErrorV1.staleRevision(expected: expectedGoalRevision, actual: goal.resolvedRevision) }
    guard ![.succeeded, .failed, .cancelled, .passed, .rollbackRequired, .superseded].contains(goal.status) else { throw TatwoWorkSpineErrorV1.terminalGoal(goal.status) }
    let base = try readBase(goalID: goal.goalID)
    guard base.contractID == goal.contractID else { throw TatwoWorkSpineErrorV1.collision(goal.goalID) }
    let bindingURL = bindingsDirectoryURL.appendingPathComponent("\(goal.goalID).json")
    let binding = Binding(goalID: goal.goalID, agentRunID: agentRunID, goalRevision: expectedGoalRevision)
    try TatwoCreateOnlyFile.write(try Self.encode(binding), to: bindingURL) {
      let existing: Binding = try Self.decode(Data(contentsOf: bindingURL), name: bindingURL.lastPathComponent)
      guard existing == binding else { throw TatwoWorkSpineErrorV1.agentRunAlreadyBound(existing.agentRunID) }
    }
    return try resolved(base)
  }

  public func locator() throws -> TatwoWorkSpineLocatorV1 { try .init(rows: allRows()) }
  public func allRows() throws -> [TatwoWorkSpineV1] {
    guard FileManager.default.fileExists(atPath: rowsDirectoryURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: rowsDirectoryURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try resolved(readBase(url: $0)) }
  }

  private func readBase(goalID: String) throws -> TatwoWorkSpineV1 { try readBase(url: rowURL(goalID: goalID)) }
  private func readBase(url: URL) throws -> TatwoWorkSpineV1 {
    guard FileManager.default.fileExists(atPath: url.path) else { throw TatwoWorkSpineErrorV1.notFound(url.lastPathComponent) }
    let row: TatwoWorkSpineV1 = try Self.decode(Data(contentsOf: url), name: url.lastPathComponent)
    try validate(row); guard row.contentSHA256 == (try row.canonicalContentSHA256()) else { throw TatwoWorkSpineErrorV1.corrupt(url.lastPathComponent) }
    return row
  }
  private func resolved(_ base: TatwoWorkSpineV1) throws -> TatwoWorkSpineV1 {
    let url = bindingsDirectoryURL.appendingPathComponent("\(base.goalID).json")
    guard FileManager.default.fileExists(atPath: url.path) else { return base }
    let binding: Binding = try Self.decode(Data(contentsOf: url), name: url.lastPathComponent)
    guard binding.goalID == base.goalID else { throw TatwoWorkSpineErrorV1.corrupt(url.lastPathComponent) }
    return try TatwoWorkSpineV1(goalID: base.goalID, contractID: base.contractID, cycleEpoch: base.cycleEpoch, agentRunID: binding.agentRunID, threadID: base.threadID, loopsSessionID: base.loopsSessionID).sealed()
  }
  private func validate(_ row: TatwoWorkSpineV1) throws { for id in [row.goalID, row.contractID, row.threadID] where id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || id.contains("/") { throw TatwoWorkSpineErrorV1.invalidID(id) }; guard row.cycleEpoch > 0 else { throw TatwoWorkSpineErrorV1.invalidID("cycleEpoch") } }
  private static func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(value) }
  private static func decode<T: Decodable>(_ data: Data, name: String) throws -> T { do { return try JSONDecoder().decode(T.self, from: data) } catch { throw TatwoWorkSpineErrorV1.corrupt(name) } }
  private struct Binding: Codable, Equatable { let goalID: String; let agentRunID: String; let goalRevision: UInt64 }
}

public struct TatwoWorkSpineLocatorV1: Sendable {
  private let rows: [TatwoWorkSpineV1]
  init(rows: [TatwoWorkSpineV1]) throws { self.rows = rows; try Self.assertUnique(rows, key: { $0.goalID }, name: "goalID"); try Self.assertUnique(rows, key: { $0.contractID }, name: "contractID"); try Self.assertUnique(rows.compactMap { $0.agentRunID == nil ? nil : $0 }, key: { $0.agentRunID! }, name: "agentRunID") }
  public func byGoalID(_ id: String) throws -> TatwoWorkSpineV1 { try one { $0.goalID == id } }
  public func byContractID(_ id: String) throws -> TatwoWorkSpineV1 { try one { $0.contractID == id } }
  public func byAgentRunID(_ id: String) throws -> TatwoWorkSpineV1 { try one { $0.agentRunID == id } }
  public func byThreadID(_ id: String) throws -> TatwoWorkSpineV1 { try one { $0.threadID == id } }
  public func byCycle(goalID: String, epoch: UInt64) throws -> TatwoWorkSpineV1 { try one { $0.goalID == goalID && $0.cycleEpoch == epoch } }
  private func one(_ predicate: (TatwoWorkSpineV1) -> Bool) throws -> TatwoWorkSpineV1 { let matches = rows.filter(predicate); guard matches.count == 1, let row = matches.first else { if matches.isEmpty { throw TatwoWorkSpineErrorV1.notFound("locator") }; throw TatwoWorkSpineErrorV1.nonUnique("locator") }; return row }
  private static func assertUnique(_ rows: [TatwoWorkSpineV1], key: (TatwoWorkSpineV1) -> String, name: String) throws { var seen = Set<String>(); for row in rows where !seen.insert(key(row)).inserted { throw TatwoWorkSpineErrorV1.nonUnique(name) } }
}

/// Read-only reference embedded by PLG/Loops projections. It carries no writer.
public struct TatwoWorkSpineProjectionReferenceV1: Codable, Sendable, Equatable {
  public let schema: String
  public let goalID: String
  public let contractID: String
  public let loopsSessionID: String?
  public init(goalID: String, contractID: String, loopsSessionID: String? = nil) {
    schema = "WorkSpineProjectionReferenceV1"; self.goalID = goalID; self.contractID = contractID; self.loopsSessionID = loopsSessionID
  }
}

public struct TatwoWorkSpineAuditEntryV1: Codable, Sendable, Equatable {
  public let goalID: String; public let contractID: String; public let agentRunID: String?; public let threadID: String; public let loopsSessionID: String?
  public let goalRunPresent: Bool; public let plgReferencePresent: Bool; public let loopsReferencePresent: Bool; public let idsAgree: Bool
}

public struct TatwoWorkSpineAuditReportV1: Codable, Sendable, Equatable {
  public let schema: String
  public let entries: [TatwoWorkSpineAuditEntryV1]
  public let spineRowCount: Int
  public let goalRunCount: Int
  public let plgReferenceCount: Int
  public let loopsReferenceCount: Int
  public let migratedLegacyData: Bool

  public init(
    entries: [TatwoWorkSpineAuditEntryV1],
    spineRowCount: Int,
    goalRunCount: Int,
    plgReferenceCount: Int,
    loopsReferenceCount: Int
  ) {
    schema = "WorkSpineAuditReportV1"
    self.entries = entries
    self.spineRowCount = spineRowCount
    self.goalRunCount = goalRunCount
    self.plgReferenceCount = plgReferenceCount
    self.loopsReferenceCount = loopsReferenceCount
    migratedLegacyData = false
  }

  public var isConsistent: Bool {
    let counts = [
      spineRowCount,
      goalRunCount,
      plgReferenceCount,
      loopsReferenceCount,
    ]
    return Set(counts).count == 1
      && entries.count == spineRowCount
      && entries.allSatisfy(\.idsAgree)
  }
}

/// Pure, read-only reconciliation. It never creates, repairs, or migrates rows.
public enum TatwoWorkSpineAuditV1 {
  public static func audit(spineRows: [TatwoWorkSpineV1], goalRuns: [TatwoStoredGoalRun], plgReferences: [TatwoWorkSpineProjectionReferenceV1], loopsReferences: [TatwoWorkSpineProjectionReferenceV1]) -> TatwoWorkSpineAuditReportV1 {
    TatwoWorkSpineAuditReportV1(entries: spineRows.map { row in
      let goals = goalRuns.filter { $0.goalID == row.goalID || $0.contractID == row.contractID }
      let plg = plgReferences.filter { $0.goalID == row.goalID || $0.contractID == row.contractID }
      let loops = loopsReferences.filter { $0.goalID == row.goalID || $0.contractID == row.contractID || ($0.loopsSessionID != nil && $0.loopsSessionID == row.loopsSessionID) }
      let exactGoal = goals.count == 1 && goals[0].goalID == row.goalID && goals[0].contractID == row.contractID
      let exactPLG = plg.count == 1 && plg[0].goalID == row.goalID && plg[0].contractID == row.contractID
      let exactLoops = loops.count == 1 && loops[0].goalID == row.goalID && loops[0].contractID == row.contractID && loops[0].loopsSessionID == row.loopsSessionID
      return .init(goalID: row.goalID, contractID: row.contractID, agentRunID: row.agentRunID, threadID: row.threadID, loopsSessionID: row.loopsSessionID, goalRunPresent: exactGoal, plgReferencePresent: exactPLG, loopsReferencePresent: exactLoops, idsAgree: exactGoal && exactPLG && exactLoops)
    }, spineRowCount: spineRows.count, goalRunCount: goalRuns.count, plgReferenceCount: plgReferences.count, loopsReferenceCount: loopsReferences.count)
  }
}

extension TatwoWorkSpineV1 {
  func sealedForTesting() throws -> Self { try sealed() }
}

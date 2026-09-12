import Foundation

/// One audit entry for a human-facing config mutation.
///
/// The App control console is deliberately contract-free (決策 3A：the human owner
/// clicks and it takes effect), so the compensating control is a durable, readable
/// trail: who changed what, when, and the resulting staging-config hash. This is
/// evidence for after-the-fact review, not a gate — appending never blocks the save.
public struct TatwoConfigAuditEntryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let at: Date
  /// Who performed the mutation, e.g. "app-human" for App UI clicks.
  public let actor: String
  /// Plain-language action, e.g. "新增情境", "綁定模型 gpt-5.5 → 副審".
  public let action: String
  /// Optional extra context such as the scenario ID touched.
  public let detail: String
  /// `stableHash` of the staging config book after the mutation was saved.
  public let configHash: String

  public init(
    schema: String = "TatwoConfigAuditEntryV1",
    at: Date = Date(),
    actor: String,
    action: String,
    detail: String = "",
    configHash: String
  ) {
    self.schema = schema
    self.at = at
    self.actor = actor
    self.action = action
    self.detail = detail
    self.configHash = configHash
  }
}

/// Append-only JSONL audit log stored next to the other Work OS state
/// (`<state>/config-audit.jsonl`), one entry per line so it stays greppable
/// and tail-able by a human without tooling.
public struct TatwoConfigAuditLog: Sendable {
  public let fileURL: URL

  public init(directoryURL: URL) {
    self.fileURL = directoryURL.appendingPathComponent("config-audit.jsonl", isDirectory: false)
  }

  /// Resolve alongside `TatwoGoalRunStore.default()` so App, CLI, and MCP write one trail.
  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoConfigAuditLog {
    TatwoConfigAuditLog(directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL)
  }

  /// Best-effort append: audit must never turn a successful save into a failure,
  /// so errors are swallowed after the atomic-append attempt.
  public func append(actor: String, action: String, detail: String = "", configHash: String) {
    let entry = TatwoConfigAuditEntryV1(
      actor: actor, action: action, detail: detail, configHash: configHash)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(entry) else { return }
    var line = data
    line.append(0x0A)
    try? TatwoFileLock.withExclusiveLock(for: fileURL) {
      try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let handle = try? FileHandle(forWritingTo: fileURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
      } else {
        try? line.write(to: fileURL, options: .atomic)
      }
    }
  }

  /// Read back entries (most recent last). Malformed lines are skipped, not fatal.
  public func entries() -> [TatwoConfigAuditEntryV1] {
    guard let data = try? Data(contentsOf: fileURL),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return text.split(separator: "\n").compactMap { line in
      try? decoder.decode(TatwoConfigAuditEntryV1.self, from: Data(line.utf8))
    }
  }
}

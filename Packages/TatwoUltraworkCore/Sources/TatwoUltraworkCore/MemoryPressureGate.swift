import Foundation

/// Phase 0.5 memory-pressure guard (DEVICE_COMPUTE_SHARING §3).
/// Blocks new remote-loop jobs/runners when free memory is below a threshold.
///
/// Fail-closed on sensor unavailability (R3 batch 2 / C3). The only intentional
/// bypass is `TATWO_ULTRAWORK_MEMORY_GATE_MIN_FREE=0` (explicit disable).
public struct MemoryPressureGate: Sendable {
  public static let minFreeEnvKey = "TATWO_ULTRAWORK_MEMORY_GATE_MIN_FREE"
  public static let defaultMinFreePercent: Double = 20

  public let minFreePercent: Double
  public let freePercentProvider: @Sendable () -> Double?
  public let journalDirectoryURL: URL?

  public enum Decision: Sendable, Equatable {
    case allow
    case blocked(freePercent: Double?, minFreePercent: Double, reason: String)

    public var isAllowed: Bool {
      if case .allow = self { return true }
      return false
    }

    public var failureCode: String? {
      switch self {
      case .allow:
        return nil
      case let .blocked(freePercent, _, _):
        // Distinguish sensor failure from threshold so ops can set MIN_FREE=0.
        return freePercent == nil ? "sensor_unavailable" : "resource_gate_blocked"
      }
    }
  }

  public init(
    minFreePercent: Double = MemoryPressureGate.defaultMinFreePercent,
    freePercentProvider: @escaping @Sendable () -> Double? = {
      MemoryPressureGate.readSystemFreePercent()
    },
    journalDirectoryURL: URL? = nil
  ) {
    self.minFreePercent = max(0, minFreePercent)
    self.freePercentProvider = freePercentProvider
    self.journalDirectoryURL = journalDirectoryURL
  }

  /// Resolve threshold from env; missing/invalid → default 20. `0` disables the gate.
  public static func threshold(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Double {
    guard let raw = environment[minFreeEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty,
      let value = Double(raw),
      value.isFinite,
      value >= 0
    else {
      return defaultMinFreePercent
    }
    return value
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    journalDirectoryURL: URL? = nil,
    freePercentProvider: (@Sendable () -> Double?)? = nil
  ) -> MemoryPressureGate {
    let journal = journalDirectoryURL ?? Self.resolveJournalDirectory(environment: environment)
    return MemoryPressureGate(
      minFreePercent: threshold(environment: environment),
      freePercentProvider: freePercentProvider ?? { MemoryPressureGate.readSystemFreePercent() },
      journalDirectoryURL: journal)
  }

  public func evaluate() -> Decision {
    // Explicit disable via MIN_FREE=0 is the only intentional fail-open path.
    if minFreePercent <= 0 {
      return .allow
    }
    guard let free = freePercentProvider() else {
      // Fail-closed: under memory exhaustion posix_spawn for the sensor fails
      // first — that is exactly when new work must not start.
      return .blocked(
        freePercent: nil,
        minFreePercent: minFreePercent,
        reason:
          "memory sensor unavailable (fail-closed; set \(Self.minFreeEnvKey)=0 to explicitly disable)"
      )
    }
    if free < minFreePercent {
      return .blocked(
        freePercent: free,
        minFreePercent: minFreePercent,
        reason:
          "memory free \(String(format: "%.1f", free))% below gate \(String(format: "%.1f", minFreePercent))%"
      )
    }
    return .allow
  }

  /// Evaluate and, when blocked, append a journal line (best-effort).
  @discardableResult
  public func evaluateAndJournal(surface: String) -> Decision {
    let decision = evaluate()
    if case let .blocked(free, minFree, reason) = decision {
      appendJournal(
        MemoryPressureGateJournalEntryV1(
          code: decision.failureCode ?? "resource_gate_blocked",
          surface: surface,
          freePercent: free,
          minFreePercent: minFree,
          reason: reason))
    }
    return decision
  }

  public func appendJournal(_ entry: MemoryPressureGateJournalEntryV1) {
    guard let directory = journalDirectoryURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(
        "memory-gate-journal.jsonl", isDirectory: false)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      var line = try encoder.encode(entry)
      line.append(contentsOf: "\n".utf8)
      if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      } else {
        try line.write(to: url, options: .atomic)
      }
    } catch {
      // Journal is evidence-only; never throw from the gate path.
    }
  }

  public static func readJournal(
    directoryURL: URL
  ) throws -> [MemoryPressureGateJournalEntryV1] {
    let url = directoryURL.appendingPathComponent(
      "memory-gate-journal.jsonl", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try text
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { try decoder.decode(MemoryPressureGateJournalEntryV1.self, from: Data($0.utf8)) }
  }

  /// Parse `memory_pressure -Q` free percentage, or return nil when unavailable.
  public static func readSystemFreePercent() -> Double? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
    process.arguments = ["-Q"]
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    return parseFreePercent(from: text)
  }

  /// Exposed for unit tests.
  public static func parseFreePercent(from text: String) -> Double? {
    // "System-wide memory free percentage: 60%"
    let pattern = #"memory free percentage:\s*([0-9]+(?:\.[0-9]+)?)\s*%"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      match.numberOfRanges >= 2,
      let capture = Range(match.range(at: 1), in: text),
      let value = Double(text[capture]),
      value.isFinite,
      value >= 0,
      value <= 100
    else {
      return nil
    }
    return value
  }

  private static func resolveJournalDirectory(
    environment: [String: String]
  ) -> URL? {
    if let raw = environment["TATWO_ULTRAWORK_STATE_DIR"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    {
      return URL(fileURLWithPath: raw, isDirectory: true)
    }
    return nil
  }
}

public struct MemoryPressureGateJournalEntryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let code: String
  public let surface: String
  public let freePercent: Double?
  public let minFreePercent: Double
  public let reason: String
  public let occurredAt: Date

  public init(
    schema: String = "MemoryPressureGateJournalEntryV1",
    code: String = "resource_gate_blocked",
    surface: String,
    freePercent: Double?,
    minFreePercent: Double,
    reason: String,
    occurredAt: Date = Date()
  ) {
    self.schema = schema
    self.code = code
    self.surface = surface
    self.freePercent = freePercent
    self.minFreePercent = minFreePercent
    self.reason = String(TatwoPrivacyRedactor.redacted(reason).prefix(512))
    self.occurredAt = occurredAt
  }
}

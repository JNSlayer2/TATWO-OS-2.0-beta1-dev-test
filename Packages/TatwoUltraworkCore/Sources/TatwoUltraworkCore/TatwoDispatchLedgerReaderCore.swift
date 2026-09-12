import Foundation

public enum TatwoDispatchLedgerStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case dispatched
  case running
  case done
  /// Origin acceptance terminal (design「已驗收」); must not fold into `.done`.
  case verified
  case failed

  public var isActive: Bool {
    self == .dispatched || self == .running
  }

  /// Presentation label aligned with design vocabulary where applicable.
  public var designSemanticLabel: String {
    switch self {
    case .dispatched: return "已排隊"
    case .running: return "執行中"
    case .done: return "已完成"
    case .verified: return "已驗收"
    case .failed: return "失敗"
    }
  }
}

public struct TatwoDispatchLedgerEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let label: String
  public let model: String
  public let status: TatwoDispatchLedgerStatus
  public let startedAt: Date
  public let endedAt: Date?
  public let note: String?

  public init(
    id: String,
    label: String,
    model: String,
    status: TatwoDispatchLedgerStatus,
    startedAt: Date,
    endedAt: Date? = nil,
    note: String? = nil
  ) {
    self.id = id
    self.label = label
    self.model = model
    self.status = status
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.note = note
  }
}

public struct TatwoDispatchLedgerReadResult: Codable, Sendable, Equatable {
  public let entries: [TatwoDispatchLedgerEntry]
  public let active: [TatwoDispatchLedgerEntry]
  public let recent: [TatwoDispatchLedgerEntry]

  public init(entries: [TatwoDispatchLedgerEntry]) {
    self.entries = entries
    self.active = entries.filter(\.status.isActive)
    self.recent = entries.filter { !$0.status.isActive }
  }
}

public struct TatwoDispatchLedgerReader {
  public static var defaultLedgerURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".tatwo-ultrawork", isDirectory: true)
      .appendingPathComponent("dispatch-ledger.jsonl")
  }

  public let ledgerURL: URL

  public init(ledgerURL: URL = TatwoDispatchLedgerReader.defaultLedgerURL) {
    self.ledgerURL = ledgerURL.standardizedFileURL
  }

  public func readEntries() -> [TatwoDispatchLedgerEntry] {
    guard let data = try? Data(contentsOf: ledgerURL),
      let contents = String(data: data, encoding: .utf8)
    else {
      return []
    }

    let decoder = Self.makeDecoder()
    return contents
      .split(whereSeparator: \.isNewline)
      .compactMap { line in
        try? decoder.decode(TatwoDispatchLedgerEntry.self, from: Data(line.utf8))
      }
      .sorted {
        if $0.startedAt != $1.startedAt {
          return $0.startedAt > $1.startedAt
        }
        return $0.id.localizedStandardCompare($1.id) == .orderedAscending
      }
  }

  public func read() -> TatwoDispatchLedgerReadResult {
    TatwoDispatchLedgerReadResult(entries: readEntries())
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)

      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: value) {
        return date
      }

      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: value) {
        return date
      }

      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO8601 timestamp.")
    }
    return decoder
  }
}

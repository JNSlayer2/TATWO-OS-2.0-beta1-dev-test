import Foundation

public struct TatwoLocalUsageRecord:
  Codable, Sendable, Equatable, Identifiable
{
  public let id: UUID
  public let provider: String
  public let timestamp: Date
  public let requestCount: Int
  public let inputTokens: Int?
  public let outputTokens: Int?

  public init(
    id: UUID = UUID(),
    provider: String,
    timestamp: Date,
    requestCount: Int = 1,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil
  ) {
    self.id = id
    self.provider = provider
    self.timestamp = timestamp
    self.requestCount = requestCount
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

public struct TatwoLocalUsageAggregate:
  Sendable, Equatable
{
  public let requestCount: Int
  public let inputTokens: Int?
  public let outputTokens: Int?

  public init(
    requestCount: Int,
    inputTokens: Int?,
    outputTokens: Int?
  ) {
    self.requestCount = requestCount
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }

  public var totalTokens: Int? {
    guard inputTokens != nil || outputTokens != nil else { return nil }
    return (inputTokens ?? 0) + (outputTokens ?? 0)
  }
}

public struct TatwoLocalUsageSnapshot:
  Sendable, Equatable
{
  public let provider: String
  public let fiveHour: TatwoLocalUsageAggregate
  public let sevenDay: TatwoLocalUsageAggregate

  public init(
    provider: String,
    fiveHour: TatwoLocalUsageAggregate,
    sevenDay: TatwoLocalUsageAggregate
  ) {
    self.provider = provider
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
  }

  public var hasRecordedUsage: Bool {
    sevenDay.requestCount > 0
  }
}

public actor TatwoLocalUsageMeter {
  public static let fiveHourWindow: TimeInterval = 5 * 60 * 60
  public static let sevenDayWindow: TimeInterval = 7 * 24 * 60 * 60
  public static let retentionWindow: TimeInterval = 30 * 24 * 60 * 60
  public static let shared = TatwoLocalUsageMeter()

  private struct Document: Codable {
    let schema: String
    var records: [TatwoLocalUsageRecord]
  }

  public let fileURL: URL
  private let now: @Sendable () -> Date
  private let logger: @Sendable (String) -> Void
  private var records: [TatwoLocalUsageRecord]

  public init(
    fileURL: URL = TatwoLocalUsageMeter.defaultFileURL(),
    now: @escaping @Sendable () -> Date = Date.init,
    logger: @escaping @Sendable (String) -> Void = {
      NSLog("%@", $0)
    }
  ) {
    self.fileURL = fileURL
    self.now = now
    self.logger = logger
    do {
      let data = try Data(contentsOf: fileURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let document = try decoder.decode(Document.self, from: data)
      records = document.schema == "TatwoLocalUsageMeterV1"
        ? document.records
        : []
    } catch CocoaError.fileReadNoSuchFile {
      records = []
    } catch {
      records = []
      logger("TatwoLocalUsageMeter load failed")
    }
  }

  public static func defaultFileURL(
    environment: [String: String] =
      ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    let root: URL
    if let explicit = environment["TATWO_ULTRAWORK_APP_SUPPORT"],
       explicit.hasPrefix("/")
    {
      root = URL(fileURLWithPath: explicit, isDirectory: true)
    } else {
      root = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask).first?
        .appendingPathComponent(
          TatwoRuntimeLayout.applicationSupportDirectoryName,
          isDirectory: true)
        ?? fileManager.homeDirectoryForCurrentUser
          .appendingPathComponent(
            "Library/Application Support/Tatwo Ultrawork",
            isDirectory: true)
    }
    return root.appendingPathComponent(
      "local-usage-meter.json",
      isDirectory: false)
  }

  public static func recordShared(
    provider: String,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil
  ) {
    Task {
      await shared.record(
        provider: provider,
        inputTokens: inputTokens,
        outputTokens: outputTokens)
    }
  }

  public func record(
    provider: String,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil
  ) {
    let timestamp = now()
    records.append(TatwoLocalUsageRecord(
      provider: provider,
      timestamp: timestamp,
      inputTokens: Self.nonnegative(inputTokens),
      outputTokens: Self.nonnegative(outputTokens)))
    prune(referenceDate: timestamp)
    persist()
  }

  public func snapshot(
    provider: String
  ) -> TatwoLocalUsageSnapshot {
    let referenceDate = now()
    let changed = prune(referenceDate: referenceDate)
    if changed { persist() }
    return TatwoLocalUsageSnapshot(
      provider: provider,
      fiveHour: aggregate(
        provider: provider,
        since: referenceDate.addingTimeInterval(
          -Self.fiveHourWindow),
        through: referenceDate),
      sevenDay: aggregate(
        provider: provider,
        since: referenceDate.addingTimeInterval(
          -Self.sevenDayWindow),
        through: referenceDate))
  }

  func allRecords() -> [TatwoLocalUsageRecord] {
    records
  }

  @discardableResult
  private func prune(referenceDate: Date) -> Bool {
    let cutoff = referenceDate.addingTimeInterval(
      -Self.retentionWindow)
    let originalCount = records.count
    records.removeAll {
      $0.timestamp < cutoff || $0.timestamp > referenceDate
    }
    return records.count != originalCount
  }

  private func aggregate(
    provider: String,
    since: Date,
    through: Date
  ) -> TatwoLocalUsageAggregate {
    let matching = records.filter {
      $0.provider == provider
        && $0.timestamp >= since
        && $0.timestamp <= through
    }
    return TatwoLocalUsageAggregate(
      requestCount: matching.reduce(0) {
        $0 + $1.requestCount
      },
      inputTokens: Self.sumOptional(
        matching.map(\.inputTokens)),
      outputTokens: Self.sumOptional(
        matching.map(\.outputTokens)))
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(Document(
        schema: "TatwoLocalUsageMeterV1",
        records: records))
        .write(to: fileURL, options: [.atomic])
    } catch {
      logger("TatwoLocalUsageMeter persist failed")
    }
  }

  private static func nonnegative(_ value: Int?) -> Int? {
    value.map { max(0, $0) }
  }

  private static func sumOptional(
    _ values: [Int?]
  ) -> Int? {
    let present = values.compactMap { $0 }
    return present.isEmpty ? nil : present.reduce(0, +)
  }
}

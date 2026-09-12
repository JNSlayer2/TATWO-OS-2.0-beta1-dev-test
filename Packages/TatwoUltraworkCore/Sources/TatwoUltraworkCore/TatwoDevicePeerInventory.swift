import Foundation

/// Channel payload written by each device-sync helper cycle.
/// Values must come from that device's live collector — this type never
/// fills missing hardware fields with defaults.
public struct TatwoDevicePeerInventoryReportV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDevicePeerInventoryV1"

  public let schema: String
  public let deviceID: String
  public let hardwareModel: String?
  public let chipName: String?
  public let ramTotalBytes: UInt64?
  public let cpuPercent: Double?
  public let memoryPressureLevel: TatwoHostMemoryPressureLevelV1?
  public let activeLoopCount: Int?
  public let timestamp: Date

  public init(
    schema: String = TatwoDevicePeerInventoryReportV1.schemaName,
    deviceID: String,
    hardwareModel: String? = nil,
    chipName: String? = nil,
    ramTotalBytes: UInt64? = nil,
    cpuPercent: Double? = nil,
    memoryPressureLevel: TatwoHostMemoryPressureLevelV1? = nil,
    activeLoopCount: Int? = nil,
    timestamp: Date
  ) {
    self.schema = schema
    self.deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.hardwareModel = Self.normalized(hardwareModel)
    self.chipName = Self.normalized(chipName)
    self.ramTotalBytes = ramTotalBytes
    self.cpuPercent = cpuPercent
    self.memoryPressureLevel = memoryPressureLevel
    self.activeLoopCount = activeLoopCount
    self.timestamp = timestamp
  }

  public var hostInventory: TatwoDeviceHostInventoryV1 {
    TatwoDeviceHostInventoryV1(
      hardwareModel: hardwareModel,
      chipName: chipName,
      ramTotalBytes: ramTotalBytes,
      cpuPercent: cpuPercent,
      memoryPressureLevel: memoryPressureLevel,
      connectionStatus: .online,
      activeLoopCount: activeLoopCount)
  }

  static func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Ingested device-record row the Devices page reads for remote cards.
public struct TatwoDevicePeerInventoryRecordV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDevicePeerInventoryRecordV1"

  public let schema: String
  public let deviceID: String
  public let registeredName: String?
  public let hardwareModel: String?
  public let chipName: String?
  public let ramTotalBytes: UInt64?
  public let cpuPercent: Double?
  public let memoryPressureLevel: TatwoHostMemoryPressureLevelV1?
  public let activeLoopCount: Int?
  public let timestamp: Date
  public let ingestedAt: Date

  public init(
    schema: String = TatwoDevicePeerInventoryRecordV1.schemaName,
    deviceID: String,
    registeredName: String? = nil,
    hardwareModel: String? = nil,
    chipName: String? = nil,
    ramTotalBytes: UInt64? = nil,
    cpuPercent: Double? = nil,
    memoryPressureLevel: TatwoHostMemoryPressureLevelV1? = nil,
    activeLoopCount: Int? = nil,
    timestamp: Date,
    ingestedAt: Date
  ) {
    self.schema = schema
    self.deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.registeredName = TatwoDevicePeerInventoryReportV1.normalized(registeredName)
    self.hardwareModel = TatwoDevicePeerInventoryReportV1.normalized(hardwareModel)
    self.chipName = TatwoDevicePeerInventoryReportV1.normalized(chipName)
    self.ramTotalBytes = ramTotalBytes
    self.cpuPercent = cpuPercent
    self.memoryPressureLevel = memoryPressureLevel
    self.activeLoopCount = activeLoopCount
    self.timestamp = timestamp
    self.ingestedAt = ingestedAt
  }

  public init(
    report: TatwoDevicePeerInventoryReportV1,
    registeredName: String? = nil,
    ingestedAt: Date
  ) {
    self.init(
      deviceID: report.deviceID,
      registeredName: registeredName,
      hardwareModel: report.hardwareModel,
      chipName: report.chipName,
      ramTotalBytes: report.ramTotalBytes,
      cpuPercent: report.cpuPercent,
      memoryPressureLevel: report.memoryPressureLevel,
      activeLoopCount: report.activeLoopCount,
      timestamp: report.timestamp,
      ingestedAt: ingestedAt)
  }

  public var hostInventory: TatwoDeviceHostInventoryV1 {
    TatwoDeviceHostInventoryV1(
      hardwareModel: hardwareModel,
      chipName: chipName,
      ramTotalBytes: ramTotalBytes,
      cpuPercent: cpuPercent,
      memoryPressureLevel: memoryPressureLevel,
      connectionStatus: .online,
      activeLoopCount: activeLoopCount)
  }
}

public enum TatwoDevicePeerInventoryStalenessV1: Sendable {
  public static let staleAfter: TimeInterval = 30 * 60

  public static func minutesAgo(timestamp: Date, now: Date) -> Int {
    max(0, Int(now.timeIntervalSince(timestamp) / 60))
  }

  public static func isStale(timestamp: Date, now: Date) -> Bool {
    now.timeIntervalSince(timestamp) > staleAfter
  }

  public static func updatedLabel(timestamp: Date, now: Date) -> String {
    "更新於 \(minutesAgo(timestamp: timestamp, now: now)) 分前"
  }
}

public enum TatwoDevicePeerInventoryIngestError: Error, Equatable, LocalizedError {
  case unsafeDeviceID(String)
  case filenameDeviceIDMismatch(file: String, deviceID: String)
  case invalidSchema(String)
  case missingTimestamp
  case invalidCPUPercent(Double)
  case invalidActiveLoopCount(Int)
  case symlinkRefused(String)
  case notRegularFile(String)

  public var errorDescription: String? {
    switch self {
    case .unsafeDeviceID(let value):
      "Peer inventory deviceID is not a safe path component: \(value)."
    case .filenameDeviceIDMismatch(let file, let deviceID):
      "Peer inventory filename \(file) does not match deviceID \(deviceID)."
    case .invalidSchema(let value):
      "Peer inventory schema rejected: \(value)."
    case .missingTimestamp:
      "Peer inventory is missing timestamp."
    case .invalidCPUPercent(let value):
      "Peer inventory cpuPercent out of range: \(value)."
    case .invalidActiveLoopCount(let value):
      "Peer inventory activeLoopCount rejected: \(value)."
    case .symlinkRefused(let path):
      "Refusing symlink peer inventory path: \(path)."
    case .notRegularFile(let path):
      "Peer inventory path is not a regular file: \(path)."
    }
  }
}

/// File-backed device record store for peer inventory reports.
///
/// Channel files live at `device-sync-channel/inventory/<deviceID>.json`.
/// Ingest copies validated reports into `device-peer-inventory/`.
public struct TatwoDevicePeerInventoryStore: Sendable {
  public static let channelDirectoryName = "inventory"
  public static let storeDirectoryName = "device-peer-inventory"

  public let storeURL: URL
  public let now: @Sendable () -> Date

  public init(
    storeURL: URL,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.storeURL = storeURL.standardizedFileURL
    self.now = now
  }

  public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) -> TatwoDevicePeerInventoryStore {
    let root = TatwoRuntimeLayout.applicationSupportRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase)
    return TatwoDevicePeerInventoryStore(
      storeURL: root.appendingPathComponent(storeDirectoryName, isDirectory: true),
      now: now)
  }

  public static func channelInventoryDirectory(
    channelRoot: URL
  ) -> URL {
    channelRoot.appendingPathComponent(channelDirectoryName, isDirectory: true)
  }

  public func load() throws -> [TatwoDevicePeerInventoryRecordV1] {
    try jsonFiles(in: storeURL).compactMap { url in
      try? decodeRecord(from: url)
    }
    .sorted { $0.deviceID < $1.deviceID }
  }

  public func record(
    deviceID: String?,
    displayName: String? = nil
  ) -> TatwoDevicePeerInventoryRecordV1? {
    let records = (try? load()) ?? []
    return Self.match(
      records: records,
      deviceID: deviceID,
      displayName: displayName)
  }

  public static func match(
    records: [TatwoDevicePeerInventoryRecordV1],
    deviceID: String?,
    displayName: String? = nil
  ) -> TatwoDevicePeerInventoryRecordV1? {
    if let deviceID = TatwoDevicePeerInventoryReportV1.normalized(deviceID),
      let exact = records.first(where: { $0.deviceID == deviceID })
    {
      return exact
    }
    guard let displayName = TatwoDevicePeerInventoryReportV1.normalized(displayName) else {
      return nil
    }
    let named = records.filter {
      $0.registeredName?.caseInsensitiveCompare(displayName) == .orderedSame
        || $0.deviceID.caseInsensitiveCompare(displayName) == .orderedSame
    }
    return named.count == 1 ? named[0] : nil
  }

  /// Ingest peer reports from `device-sync-channel/inventory/`.
  /// Never seeds missing hardware fields. Older reports do not replace newer ones.
  @discardableResult
  public func ingest(
    channelInventoryDirectory: URL,
    registeredDevicesDirectory: URL? = nil
  ) throws -> [TatwoDevicePeerInventoryRecordV1] {
    let names = try loadRegisteredNames(from: registeredDevicesDirectory)
    var existing = Dictionary(
      uniqueKeysWithValues: ((try? load()) ?? []).map { ($0.deviceID, $0) })
    let ingestedAt = now()
    for url in try jsonFiles(in: channelInventoryDirectory) {
      let report: TatwoDevicePeerInventoryReportV1
      do {
        report = try decodeReport(from: url)
      } catch {
        continue
      }
      if let current = existing[report.deviceID], current.timestamp > report.timestamp {
        continue
      }
      let record = TatwoDevicePeerInventoryRecordV1(
        report: report,
        registeredName: names[report.deviceID],
        ingestedAt: ingestedAt)
      existing[report.deviceID] = record
      try persist(record)
    }
    return existing.values.sorted { $0.deviceID < $1.deviceID }
  }

  public static func decodeReport(
    from data: Data,
    fileName: String
  ) throws -> TatwoDevicePeerInventoryReportV1 {
    let decoder = decoder()
    let report = try decoder.decode(TatwoDevicePeerInventoryReportV1.self, from: data)
    try validate(report, fileName: fileName)
    return report
  }

  public static func isSafeDeviceID(_ value: String) -> Bool {
    guard !value.isEmpty,
      value != ".",
      value != "..",
      !value.contains("/"),
      !value.contains("\\")
    else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 45, 46, 48...57, 65...90, 95, 97...122:
        return true
      default:
        return false
      }
    }
  }

  private static func validate(
    _ report: TatwoDevicePeerInventoryReportV1,
    fileName: String
  ) throws {
    guard report.schema == TatwoDevicePeerInventoryReportV1.schemaName else {
      throw TatwoDevicePeerInventoryIngestError.invalidSchema(report.schema)
    }
    guard isSafeDeviceID(report.deviceID) else {
      throw TatwoDevicePeerInventoryIngestError.unsafeDeviceID(report.deviceID)
    }
    let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    if !stem.isEmpty, stem != report.deviceID {
      throw TatwoDevicePeerInventoryIngestError.filenameDeviceIDMismatch(
        file: fileName,
        deviceID: report.deviceID)
    }
    if let cpu = report.cpuPercent, !(cpu.isFinite && cpu >= 0 && cpu <= 100) {
      throw TatwoDevicePeerInventoryIngestError.invalidCPUPercent(cpu)
    }
    if let loops = report.activeLoopCount, loops < 0 {
      throw TatwoDevicePeerInventoryIngestError.invalidActiveLoopCount(loops)
    }
  }

  private func persist(_ record: TatwoDevicePeerInventoryRecordV1) throws {
    try FileManager.default.createDirectory(
      at: storeURL,
      withIntermediateDirectories: true)
    let url = storeURL.appendingPathComponent(
      "\(record.deviceID).json",
      isDirectory: false)
    try refuseSymlink(url)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: url, options: [.atomic])
  }

  private func decodeReport(from url: URL) throws -> TatwoDevicePeerInventoryReportV1 {
    let data = try readRegularFile(url)
    return try Self.decodeReport(from: data, fileName: url.lastPathComponent)
  }

  private func decodeRecord(from url: URL) throws -> TatwoDevicePeerInventoryRecordV1 {
    let data = try readRegularFile(url)
    return try Self.decoder().decode(TatwoDevicePeerInventoryRecordV1.self, from: data)
  }

  private func loadRegisteredNames(from directory: URL?) throws -> [String: String] {
    guard let directory else { return [:] }
    var names: [String: String] = [:]
    for url in try jsonFiles(in: directory) {
      guard let data = try? readRegularFile(url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      let name = (object["name"] as? String)
        .flatMap(TatwoDevicePeerInventoryReportV1.normalized)
      guard let name else { continue }
      for key in ["deviceID", "deviceId"] {
        if let id = TatwoDevicePeerInventoryReportV1.normalized(object[key] as? String),
          Self.isSafeDeviceID(id)
        {
          names[id] = name
        }
      }
    }
    return names
  }

  private func jsonFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let values = try directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw TatwoDevicePeerInventoryIngestError.symlinkRefused(directory.path)
    }
    guard values.isDirectory == true else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func readRegularFile(_ url: URL) throws -> Data {
    let values = try url.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw TatwoDevicePeerInventoryIngestError.symlinkRefused(url.path)
    }
    guard values.isRegularFile == true else {
      throw TatwoDevicePeerInventoryIngestError.notRegularFile(url.path)
    }
    return try Data(contentsOf: url)
  }

  private func refuseSymlink(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw TatwoDevicePeerInventoryIngestError.symlinkRefused(url.path)
    }
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let standard = ISO8601DateFormatter()
      standard.formatOptions = [.withInternetDateTime]
      if let date = fractional.date(from: value) ?? standard.date(from: value) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "date must be ISO-8601")
    }
    return decoder
  }
}

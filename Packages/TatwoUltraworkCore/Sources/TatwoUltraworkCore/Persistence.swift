import Foundation

public struct TatwoUserPreferences: Codable, Sendable, Equatable {
  public let schema: String
  public var selectedMode: WorkModeID
  public var selectedScenario: ScenarioID
  public var pluginDecisions: [String: InstallAction]
  public var safeMemories: [SafeMemoryReceipt]
  public var codexThreadMirrorExternalVolumeOptIn: Bool
  public var hostResourceTierOverride: TatwoHostResourceTier?
  public var detectedHostResourceTier: TatwoHostResourceTier?
  public var detectedPhysicalMemoryBytes: UInt64?
  public var hostResourceTierDetectedAt: Date?
  public var updatedAt: Date

  public init(
    schema: String = "TatwoUserPreferencesV1",
    selectedMode: WorkModeID = .m,
    selectedScenario: ScenarioID = .coding,
    pluginDecisions: [String: InstallAction] = [:],
    safeMemories: [SafeMemoryReceipt] = [],
    codexThreadMirrorExternalVolumeOptIn: Bool = false,
    hostResourceTierOverride: TatwoHostResourceTier? = nil,
    detectedHostResourceTier: TatwoHostResourceTier? = nil,
    detectedPhysicalMemoryBytes: UInt64? = nil,
    hostResourceTierDetectedAt: Date? = nil,
    updatedAt: Date = Date()
  ) {
    self.schema = schema
    self.selectedMode = selectedMode
    self.selectedScenario = selectedScenario
    self.pluginDecisions = pluginDecisions
    self.safeMemories = safeMemories
    self.codexThreadMirrorExternalVolumeOptIn = codexThreadMirrorExternalVolumeOptIn
    self.hostResourceTierOverride = hostResourceTierOverride
    self.detectedHostResourceTier = detectedHostResourceTier
    self.detectedPhysicalMemoryBytes = detectedPhysicalMemoryBytes
    self.hostResourceTierDetectedAt = hostResourceTierDetectedAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case schema
    case selectedMode
    case selectedScenario
    case pluginDecisions
    case safeMemories
    case codexThreadMirrorExternalVolumeOptIn
    case hostResourceTierOverride
    case detectedHostResourceTier
    case detectedPhysicalMemoryBytes
    case hostResourceTierDetectedAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decodeIfPresent(String.self, forKey: .schema)
      ?? "TatwoUserPreferencesV1"
    selectedMode = try container.decodeIfPresent(WorkModeID.self, forKey: .selectedMode) ?? .m
    selectedScenario = try container.decodeIfPresent(ScenarioID.self, forKey: .selectedScenario) ?? .coding
    pluginDecisions = try container.decodeIfPresent(
      [String: InstallAction].self, forKey: .pluginDecisions) ?? [:]
    safeMemories = try container.decodeIfPresent(
      [SafeMemoryReceipt].self, forKey: .safeMemories) ?? []
    codexThreadMirrorExternalVolumeOptIn = try container.decodeIfPresent(
      Bool.self, forKey: .codexThreadMirrorExternalVolumeOptIn) ?? false
    hostResourceTierOverride = try container.decodeIfPresent(
      TatwoHostResourceTier.self, forKey: .hostResourceTierOverride)
    detectedHostResourceTier = try container.decodeIfPresent(
      TatwoHostResourceTier.self, forKey: .detectedHostResourceTier)
    detectedPhysicalMemoryBytes = try container.decodeIfPresent(
      UInt64.self, forKey: .detectedPhysicalMemoryBytes)
    hostResourceTierDetectedAt = try container.decodeIfPresent(
      Date.self, forKey: .hostResourceTierDetectedAt)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(selectedMode, forKey: .selectedMode)
    try container.encode(selectedScenario, forKey: .selectedScenario)
    try container.encode(pluginDecisions, forKey: .pluginDecisions)
    try container.encode(safeMemories, forKey: .safeMemories)
    try container.encode(
      codexThreadMirrorExternalVolumeOptIn,
      forKey: .codexThreadMirrorExternalVolumeOptIn)
    try container.encodeIfPresent(
      hostResourceTierOverride,
      forKey: .hostResourceTierOverride)
    try container.encodeIfPresent(
      detectedHostResourceTier,
      forKey: .detectedHostResourceTier)
    try container.encodeIfPresent(
      detectedPhysicalMemoryBytes,
      forKey: .detectedPhysicalMemoryBytes)
    try container.encodeIfPresent(
      hostResourceTierDetectedAt,
      forKey: .hostResourceTierDetectedAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }
}

public struct TatwoPreferenceStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    if let explicit = environment["TATWO_ULTRAWORK_PREFERENCES"],
       !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return Self(fileURL: URL(fileURLWithPath: explicit))
    }
    if let stateDir = environment["TATWO_ULTRAWORK_STATE_DIR"],
       !stateDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return Self(
        fileURL: URL(fileURLWithPath: stateDir, isDirectory: true)
          .appendingPathComponent("preferences.json"))
    }
    if let projectRoot = environment["TATWO_ULTRAWORK_PROJECT_ROOT"],
       !projectRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return Self(
        fileURL: URL(fileURLWithPath: projectRoot, isDirectory: true)
          .appendingPathComponent(".tatwo-ultrawork/state/preferences.json"))
    }
    // 2026-08-27：staging bundle 的 HOME 是真實家目錄（Foundation/Keychain 需要），
    // 隔離根改由 TATWO_STAGING_SCRATCH_HOME 明示。staging 一旦落到 HOME fallback，
    // 必須 fail-closed 導回 scratch home，不得寫進正式 Application Support。
    if let scratchHome = environment["TATWO_STAGING_SCRATCH_HOME"],
       !scratchHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return Self(
        fileURL: URL(fileURLWithPath: scratchHome, isDirectory: true)
          .appendingPathComponent(
            "Library/Application Support/Tatwo Ultrawork/preferences.json"))
    }
    let home = environment["HOME"].map(URL.init(fileURLWithPath:))
      ?? FileManager.default.homeDirectoryForCurrentUser
    return Self(
      fileURL: home.appendingPathComponent(
        "Library/Application Support/Tatwo Ultrawork/preferences.json"))
  }

  /// 2026-08-28（staging 65）：啟動期同一個 preferences 檔會被 launch reconcile 與
  /// 面板 hydration 併發讀取。`fileExists` + `Data(contentsOf:)` 是兩次 `open()`，
  /// 在外接卷／TCC 同意流程下等於兩次可被同步擋住的 syscall。改成單次讀取並把
  /// 「檔案不存在」映射回預設值：語意與舊版相同，但啟動期開檔次數減半。
  public func load() throws -> TatwoUserPreferences {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return TatwoUserPreferences()
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    {
      return TatwoUserPreferences()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoUserPreferences.self, from: data)
  }

  public func save(_ preferences: TatwoUserPreferences) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var copy = preferences
    copy.updatedAt = Date()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(copy).write(to: fileURL, options: [.atomic])
  }

  public func updateMode(_ mode: WorkModeID, scenario: ScenarioID? = nil) throws
    -> TatwoUserPreferences
  {
    var preferences = try load()
    preferences.selectedMode = mode
    if let scenario { preferences.selectedScenario = scenario }
    try save(preferences)
    return try load()
  }

  public func setPluginDecision(pluginID: String, action: InstallAction) throws
    -> TatwoUserPreferences
  {
    var preferences = try load()
    preferences.pluginDecisions[pluginID] = action
    try save(preferences)
    return try load()
  }

  public func setCodexThreadMirrorExternalVolumeOptIn(_ enabled: Bool) throws
    -> TatwoUserPreferences
  {
    var preferences = try load()
    preferences.codexThreadMirrorExternalVolumeOptIn = enabled
    try save(preferences)
    return try load()
  }

  /// M3a 更新：App 每次啟動都以當前主機實體 RAM 更新偵測值，並保留
  /// storage-only 手動覆寫欄位，避免同步到另一台 Mac 後沿用舊機等級。
  public func reconcileHostResourceProfileAtLaunch(
    physicalMemoryBytes: UInt64,
    detectedAt: Date = Date()
  ) throws -> TatwoHostResourceProfile {
    var preferences = try load()
    let detectedTier = TatwoHostResourceTier.detected(
      physicalMemoryBytes: physicalMemoryBytes)
    preferences.detectedHostResourceTier = detectedTier
    preferences.detectedPhysicalMemoryBytes = physicalMemoryBytes
    preferences.hostResourceTierDetectedAt = detectedAt
    try save(preferences)
    return TatwoHostResourceProfile(
      detectedTier: detectedTier,
      overrideTier: preferences.hostResourceTierOverride,
      physicalMemoryBytes: physicalMemoryBytes,
      detectedAt: detectedAt)
  }

  public func setHostResourceTierOverride(
    _ overrideTier: TatwoHostResourceTier?
  ) throws -> TatwoHostResourceProfile? {
    var preferences = try load()
    preferences.hostResourceTierOverride = overrideTier
    try save(preferences)
    guard let detectedTier = preferences.detectedHostResourceTier,
      let physicalMemoryBytes = preferences.detectedPhysicalMemoryBytes
    else {
      return nil
    }
    return TatwoHostResourceProfile(
      detectedTier: detectedTier,
      overrideTier: overrideTier,
      physicalMemoryBytes: physicalMemoryBytes,
      detectedAt: preferences.hostResourceTierDetectedAt ?? Date())
  }

  public func appendSafeMemory(_ receipt: SafeMemoryReceipt) throws -> TatwoUserPreferences {
    let gate = SafeMemoryGate.evaluate(receipt)
    guard gate.passed else {
      throw TatwoPersistenceError.unsafeMemory(gate.reasons)
    }
    var preferences = try load()
    if !preferences.safeMemories.contains(where: { $0.id == receipt.id }) {
      preferences.safeMemories.append(receipt)
    }
    try save(preferences)
    return try load()
  }
}

public enum TatwoPersistenceError: Error, LocalizedError, Sendable, Equatable {
  case unsafeMemory([String])

  public var errorDescription: String? {
    switch self {
    case .unsafeMemory(let reasons):
      return "Unsafe memory rejected: \(reasons.joined(separator: ","))"
    }
  }
}

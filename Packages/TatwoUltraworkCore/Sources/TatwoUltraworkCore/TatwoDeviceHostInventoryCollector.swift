import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum TatwoHostMemoryPressureLevelV1: String, Codable, Sendable, Equatable {
  case normal
  case warn
  case urgent
  case critical
  case unknown
}

public enum TatwoDeviceConnectionStatusV1: String, Codable, Sendable, Equatable {
  case local
  case online
  case offline
  case unknown
}

/// Display/readiness inventory the Devices visual round can bind without
/// changing admission classification. All fields are optional so an older
/// snapshot without this object keeps the same canonical digest.
public struct TatwoDeviceHostInventoryV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDeviceHostInventoryV1"

  public let schema: String
  /// `hw.model` (e.g. Mac15,9).
  public let hardwareModel: String?
  /// `machdep.cpu.brand_string` or a conservative Apple/Intel fallback.
  public let chipName: String?
  /// `hw.memsize` bytes.
  public let ramTotalBytes: UInt64?
  /// Busy CPU percent from two `HOST_CPU_LOAD_INFO` samples (nil on first tick).
  public let cpuPercent: Double?
  public let memoryPressureLevel: TatwoHostMemoryPressureLevelV1?
  public let connectionStatus: TatwoDeviceConnectionStatusV1?
  public let activeLoopCount: Int?

  public init(
    schema: String = TatwoDeviceHostInventoryV1.schemaName,
    hardwareModel: String? = nil,
    chipName: String? = nil,
    ramTotalBytes: UInt64? = nil,
    cpuPercent: Double? = nil,
    memoryPressureLevel: TatwoHostMemoryPressureLevelV1? = nil,
    connectionStatus: TatwoDeviceConnectionStatusV1? = nil,
    activeLoopCount: Int? = nil
  ) {
    self.schema = schema
    self.hardwareModel = Self.normalized(hardwareModel)
    self.chipName = Self.normalized(chipName)
    self.ramTotalBytes = ramTotalBytes
    self.cpuPercent = cpuPercent
    self.memoryPressureLevel = memoryPressureLevel
    self.connectionStatus = connectionStatus
    self.activeLoopCount = activeLoopCount
  }

  public var isEmpty: Bool {
    hardwareModel == nil
      && chipName == nil
      && ramTotalBytes == nil
      && cpuPercent == nil
      && memoryPressureLevel == nil
      && connectionStatus == nil
      && activeLoopCount == nil
  }

  public static func activeLoopCount(
    workers: [TatwoPressureWorkerV1],
    activeLoopID: String?
  ) -> Int {
    var ids = Set(workers.compactMap(\.loopID))
    if let activeLoopID, !activeLoopID.isEmpty {
      ids.insert(activeLoopID)
    }
    if ids.isEmpty {
      return workers.isEmpty ? 0 : workers.count
    }
    return ids.count
  }

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

/// Local sysctl / host_statistics collector for Devices-page host facts.
///
/// Stateful only for CPU% (needs a previous tick). First `collect()` may leave
/// `cpuPercent` nil. Admission sensors stay in `TatwoDevicePressureSensorReadingsV1`.
public struct TatwoDeviceHostInventoryCollector: Sendable {
  private var previousCPU: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

  public init() {}

  public mutating func collect(
    activeLoopCount: Int? = nil,
    connectionStatus: TatwoDeviceConnectionStatusV1 = .local
  ) -> TatwoDeviceHostInventoryV1? {
    let inventory = TatwoDeviceHostInventoryV1(
      hardwareModel: Self.sysctlString("hw.model"),
      chipName: Self.chipName(),
      ramTotalBytes: Self.sysctlUInt64("hw.memsize"),
      cpuPercent: sampleCPUPercent(),
      memoryPressureLevel: Self.memoryPressureLevel(),
      connectionStatus: connectionStatus,
      activeLoopCount: activeLoopCount)
    return inventory.isEmpty ? nil : inventory
  }

  public static func collectOnce(
    activeLoopCount: Int? = nil,
    connectionStatus: TatwoDeviceConnectionStatusV1 = .local
  ) -> TatwoDeviceHostInventoryV1? {
    var collector = TatwoDeviceHostInventoryCollector()
    return collector.collect(
      activeLoopCount: activeLoopCount,
      connectionStatus: connectionStatus)
  }

  public static func memoryPressureLevel(
    fromRawValue raw: Int32
  ) -> TatwoHostMemoryPressureLevelV1 {
    switch raw {
    case 0: return .normal
    case 1: return .warn
    case 2: return .urgent
    case 4: return .critical
    default: return .unknown
    }
  }

#if canImport(Darwin)
  private mutating func sampleCPUPercent() -> Double? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let current = (
      user: info.cpu_ticks.0,
      system: info.cpu_ticks.1,
      idle: info.cpu_ticks.2,
      nice: info.cpu_ticks.3)
    defer { previousCPU = current }
    guard let previous = previousCPU else { return nil }
    let user = UInt64(current.user &- previous.user)
    let system = UInt64(current.system &- previous.system)
    let idle = UInt64(current.idle &- previous.idle)
    let nice = UInt64(current.nice &- previous.nice)
    let total = user + system + idle + nice
    guard total > 0 else { return nil }
    let busy = user + system + nice
    let percent = (Double(busy) / Double(total)) * 100
    guard percent.isFinite, percent >= 0, percent <= 100 else { return nil }
    return percent
  }

  private static func memoryPressureLevel() -> TatwoHostMemoryPressureLevelV1? {
    guard let raw = sysctlInt32("kern.memorystatus_vm_pressure_level") else {
      return nil
    }
    return memoryPressureLevel(fromRawValue: raw)
  }

  private static func chipName() -> String? {
    if let brand = sysctlString("machdep.cpu.brand_string") {
      return brand
    }
    if sysctlInt32("hw.optional.arm64") == 1 {
      return "Apple Silicon"
    }
    if let machine = sysctlString("hw.machine"), !machine.isEmpty {
      return machine
    }
    return nil
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let raw = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let value = String(decoding: raw, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private static func sysctlUInt64(_ name: String) -> UInt64? {
    var value = UInt64(0)
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
  }

  private static func sysctlInt32(_ name: String) -> Int32? {
    var value = Int32(0)
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
  }
#else
  private mutating func sampleCPUPercent() -> Double? { nil }

  private static func memoryPressureLevel() -> TatwoHostMemoryPressureLevelV1? { nil }

  private static func chipName() -> String? { nil }
#endif
}
